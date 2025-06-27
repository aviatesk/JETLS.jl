function analyze_lowered_code!(diagnostics::Vector{Diagnostic},
                               ctx3::JL.VariableAnalysisContext, st3::JL.SyntaxTree,
                               sourcefile::JS.SourceFile)
    binding_usages = compute_binding_usages(ctx3, st3)
    for (binfo, used) in binding_usages
        used && continue
        binding = JL.binding_ex(ctx3, binfo.id)
        if binfo.kind === :argument
            message = "Unused argument `$(binfo.name)`"
        else
            message = "Unused local binding `$(binfo.name)`"
        end
        diagnostic = jsobj_to_diagnostic(binding, sourcefile,
            message,
            #=severity=#DiagnosticSeverity.Information,
            #=source=#LOWERING_DIAGNOSTIC_SOURCE)
        push!(diagnostics, diagnostic)
    end
    return diagnostics
end

function compute_binding_usages(ctx3::JL.VariableAnalysisContext, st3::JL.SyntaxTree)
    tracked = Dict{JL.BindingInfo,Bool}()

    for binfo = ctx3.bindings.info
        binfo.is_internal && continue
        binfo.kind === :argument || binfo.kind === :local || continue
        tracked[binfo] = false
    end

    if isempty(tracked)
        return tracked
    end

    stack = [st3]
    while !isempty(stack)
        st = pop!(stack)
        k = JS.kind(st)
        if k === JS.K"local" # || k === JS.K"function_decl"
            continue
        end

        if k === JS.K"BindingId"
            binfo = JL.lookup_binding(ctx3, st)
            if haskey(tracked, binfo)
                tracked[binfo] |= true
            end
        end

        i = 1
        if k === JS.K"lambda"
            i = 2 # the first block, i.e. the argument declaration does not account for usage
        elseif k === JS.K"="
            i = 2 # the left hand side, i.e. "definition", does not account for usage
        end
        for j = i:JS.numchildren(st)
            push!(stack, st[j])
        end
    end

    tracked
end
