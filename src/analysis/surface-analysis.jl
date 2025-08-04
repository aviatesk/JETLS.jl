function analyze_lowered_code!(diagnostics::Vector{Diagnostic},
                               ctx3::JL.VariableAnalysisContext, st3::JL.SyntaxTree,
                               sourcefile::JS.SourceFile)
    binding_usages, ismacro = compute_binding_usages(ctx3, st3)
    for (binfo, used) in binding_usages
        used && continue
        binding = JL.binding_ex(ctx3, binfo.id)
        if iszero(JS.first_byte(binding)) || iszero(JS.last_byte(binding))
            continue
        elseif ismacro && (binfo.name == "__module__" || binfo.name == "__source__")
            continue
        end
        if binfo.kind === :argument
            message = "Unused argument `$(binfo.name)`"
        else
            message = "Unused local binding `$(binfo.name)`"
        end
        push!(diagnostics, jsobj_to_diagnostic(binding, sourcefile,
            message,
            #=severity=#DiagnosticSeverity.Information,
            #=source=#LOWERING_DIAGNOSTIC_SOURCE;
            tags = DiagnosticTag.Ty[DiagnosticTag.Unnecessary]))
    end
    return diagnostics
end

function compute_binding_usages(ctx3::JL.VariableAnalysisContext, st3::JL.SyntaxTree)
    tracked = Dict{JL.BindingInfo,Bool}()
    ismacro = Ref(false)

    # group together argument bindings with the same name
    same_arg_bindings = Dict{Symbol,Vector{Int}}()

    for (i, binfo) = enumerate(ctx3.bindings.info)
        binfo.is_internal && continue
        if binfo.kind === :argument
            push!(get!(Vector{Int}, same_arg_bindings, Symbol(binfo.name)), i)
        elseif binfo.kind !== :local
            continue
        end
        tracked[binfo] = false
    end

    if !isempty(tracked)
        compute_binding_usages!(tracked, ismacro, ctx3, st3)

        # Fix up usedness information of arguments that are only used within the argument list.
        # E.g. this is necessary to avoid reporting "unused variable diagnostics" for `a` in cases like:
        # ```julia
        # hasmatch(x::RegexMatch, y::Bool=isempty(x.matches)) = y
        # ```
        for (_, idxs) in same_arg_bindings
            used = any(idx::Int->tracked[ctx3.bindings.info[idx]], idxs)
            for idx in idxs
                tracked[ctx3.bindings.info[idx]] = used
            end
        end
    end

    return tracked, ismacro[]
end

function compute_binding_usages!(tracked::Dict{JL.BindingInfo,Bool}, ismacro::Base.RefValue{Bool},
                                 ctx3::JL.VariableAnalysisContext, st3::JL.SyntaxTree;
                                 include_decls::Bool = false,
                                 skip_tracking::Union{Nothing,Set{JL.BindingInfo}}=nothing)
    stack = JL.SyntaxList(st3)
    push!(stack, st3)
    infunc = false
    while !isempty(stack)
        st = pop!(stack)
        k = JS.kind(st)
        if k === JS.K"local" # || k === JS.K"function_decl"
            if !include_decls
                continue
            end
        end

        if k === JS.K"BindingId"
            binfo = JL.lookup_binding(ctx3, st)
            if haskey(tracked, binfo) && (isnothing(skip_tracking) || binfo ∉ skip_tracking)
                tracked[binfo] |= true
            end
        end

        i = 1
        n = JS.numchildren(st)
        if k === JS.K"function_decl"
            infunc = true
            if n ≥ 1
                local func = st[1]
                if JS.kind(func) === JS.K"BindingId"
                    if startswith(JL.lookup_binding(ctx3, func).name, "@")
                        ismacro[] = true
                    end
                end
            end
        elseif infunc && k === JS.K"block" && n ≥ 1
            blk1 = st[1]
            if JS.kind(blk1) === JS.K"function_decl" && infunc && JS.numchildren(blk1) ≥ 1
                # This is an inner function definition -- the binding of this inner function
                # is "used" in the language constructs required to define the method,
                # but what we're interested in is whether it's actually used in the outer scope.
                # We add this inner function to `skip_tracking` and recurse.
                local func = blk1[1]
                if JS.kind(func) === JS.K"BindingId"
                    innerfuncinfo = JL.lookup_binding(ctx3, func)
                    compute_binding_usages!(tracked, ismacro, ctx3, st;
                        skip_tracking = Set((innerfuncinfo,)))
                    continue
                end
            end
        elseif k === JS.K"lambda"
            i = 2 # the first block, i.e. the argument declaration does not account for usage
            if n ≥ 1
                arglist = st[1]
                is_kwcall = JS.numchildren(arglist) ≥ 3 &&
                    JS.kind(arglist[1]) === JS.K"BindingId" &&
                    let arg1info = JL.lookup_binding(ctx3, arglist[1])
                        arg1info.is_internal && arg1info.name == "#self#"
                    end &&
                    JS.kind(arglist[2]) === JS.K"BindingId" &&
                    let arg2info = JL.lookup_binding(ctx3, arglist[2])
                        arg2info.is_internal && arg2info.name == "kws"
                    end &&
                    JS.kind(arglist[3]) === JS.K"BindingId" &&
                    let arg3info = JL.lookup_binding(ctx3, arglist[3])
                        arg3info.is_internal && (arg3info.name == "#self#" || arg3info.name == "#ctor-self#")
                    end
                if is_kwcall
                    # This is `kwcall` method -- now need to perform some special case
                    # Julia checks whether keyword arguments are assigned in `kwcall` methods,
                    # but JL actually introduces local bindings for those keyword arguments for reflection purposes:
                    # https://github.com/c42f/JuliaLowering.jl/blob/4b12ab19dad40c64767558be0a8a338eb4cc9172/src/desugaring.jl#L2633-L2637
                    # These bindings are never actually used, so simply recursing would cause
                    # this pass to report them as unused local bindings.
                    # We avoid this problem by setting `include_decls` when recursing.
                    for j = 1:n
                        compute_binding_usages!(tracked, ismacro, ctx3, st[j]; include_decls=true)
                    end
                    continue
                end
            end
        elseif k === JS.K"="
            i = 2 # the left hand side, i.e. "definition", does not account for usage
            if n ≥ 2
                eq2 = st[2]
                # In struct definitions, `local struct_name` is somehow introduced,
                # so special case it here: https://github.com/c42f/JuliaLowering.jl/blob/4b12ab19dad40c64767558be0a8a338eb4cc9172/src/desugaring.jl#L3833
                # TODO investigate why this local binding introduction is necessary on the JL side
                if JS.kind(eq2) === JS.K"BindingId" && JL.lookup_binding(ctx3, eq2).name == "struct_type"
                    i = 1
                end
            end
        end
        for j = n:-1:i # since we use `pop!`
            push!(stack, st[j])
        end
    end

    return tracked, ismacro
end
