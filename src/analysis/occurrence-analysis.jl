"""
    compute_binding_occurrences(
            ctx3::JL.VariableAnalysisContext, st3::Tree3;
            ismacro::Union{Nothing,Base.RefValue{Bool}} = nothing
        ) where Tree3<:JS.SyntaxTree
        -> binding_occurrences::Dict{JL.BindingInfo,Set{BindingOccurrence{Tree3}}}

Analyze a lowered syntax tree to find all occurrences of local and argument bindings.

This function traverses the syntax tree `st3` and records `occurrence::BindingOccurrence`s
for each local and argument binding within `st3`, where `occurrence` have the following
information:
- `occurrence.tree::JS.SyntaxTree`: Syntax tree for this occurrence of the binding
- `occurrence.kind::Symbol`
  - `:decl` - explicit declarations like `local x`
  - `:def` - assignments or function arguments
  - `:use` - references to the binding

# Arguments
- `ctx3`: Variable analysis context from JuliaLowering containing binding information
- `st3`: Lowered syntax tree (after scope resolution) to analyze
- `ismacro`: Optional mutable reference to track if any function binding is a macro

# Returns
`binding_occurrences` is a dictionary mapping each non-internal local/argument binding to
a set of `BindingOccurrence` objects that record where and how the binding appears.

!!! note "Comparison with `select_target_binding_definitions`"
    While [`select_target_binding_definitions`](@ref) traces definitions from a specific use
    point (cursor position), `compute_binding_occurrences` is a more general routine that
    analyzes all bindings in the entire syntax tree. Use this function when you need
    comprehensive information about binding declarations and uses, such as for unused
    variable diagnostics or comprehensive binding analysis.
"""
function compute_binding_occurrences(
        ctx3::JL.VariableAnalysisContext, st3::Tree3;
        ismacro::Union{Nothing,Base.RefValue{Bool}} = nothing,
        include_global_bindings::Bool = false
    ) where Tree3<:JS.SyntaxTree
    occurrences = Dict{JL.BindingInfo,Set{BindingOccurrence{Tree3}}}()

    same_arg_bindings = Dict{Symbol,Vector{Int}}() # group together argument bindings with the same name
    same_location_bindings = Dict{Tuple{Symbol,Int,Int},Vector{Int}}() # group together local bindings with the same location and name

    for (i, binfo) = enumerate(ctx3.bindings.info)
        binfo.is_internal && continue
        if binfo.kind === :argument
            push!(get!(Vector{Int}, same_arg_bindings, Symbol(binfo.name)), i)
        elseif binfo.kind === :static_parameter || binfo.kind === :local
            lockey = (Symbol(binfo.name), JS.source_location(JL.binding_ex(ctx3, binfo.id))...)
            push!(get!(Vector{Int}, same_location_bindings, lockey), i)
        elseif binfo.kind === :global
            include_global_bindings || continue
        else
            error(lazy"Unknown binding kind: $(binfo.kind)")
        end
        occurrences[binfo] = Set{BindingOccurrence{Tree3}}()
    end

    isempty(occurrences) && return occurrences

    compute_binding_occurrences!(occurrences, ctx3, st3; ismacro)

    # Aggregate occurrences for bindings that have the same name and location.
    # JL sometimes represents bindings that are considered "identical" at the source level
    # as multiple copies for the sake of the actual semantics of the lowered code.
    # Therefore, such aggregation is necessary to map occurrences in the lowered representation
    # to usage information at the source level.
    for (_, idxs) in same_location_bindings
        length(idxs) == 1 && continue
        newoccurrences = union!((occurrences[ctx3.bindings.info[idx]] for idx in idxs)...)
        for idx in idxs
            occurrences[ctx3.bindings.info[idx]] = newoccurrences
        end
    end

    # Fix up usedness information of arguments that are only used within the argument list.
    # to avoid reporting "unused variable diagnostics" for `x` in cases like:
    # ```julia
    # hasmatch(x::RegexMatch, y::Bool=isempty(x.matches)) = y
    # ```
    # N.B. This needs to be done separately from `same_location_bindings`.
    # This is because if argument lists were also aggregated by "name & location" key,
    # then even when `x` is truly unused, the usage in methods that fill default parameters
    # and call the full-argument list method would be aggregated, causing us to miss reports
    # in such cases, e.g.
    # ```julia
    # hasmatch(x::RegexMatch, y::Bool=false) = nothing
    # ```
    for (_, idxs) in same_arg_bindings
        length(idxs) == 1 && continue
        newoccurrences = union!((occurrences[ctx3.bindings.info[idx]] for idx in idxs)...)
        for idx in idxs
            occurrences[ctx3.bindings.info[idx]] = newoccurrences
        end
    end

    return occurrences
end

function record_occurrence!(occurrences::Dict{JL.BindingInfo,Set{BindingOccurrence{Tree3}}},
        kind::Symbol, st::Tree3, ctx3::JL.VariableAnalysisContext;
        skip_recording::Union{Nothing,Set{JL.BindingInfo}} = nothing
    ) where Tree3<:JS.SyntaxTree
    if JS.kind(st) === JS.K"BindingId"
        binfo = JL.get_binding(ctx3, st)
        record_occurrence!(occurrences, kind, st, binfo; skip_recording)
    end
    return occurrences
end

function record_occurrence!(occurrences::Dict{JL.BindingInfo,Set{BindingOccurrence{Tree3}}},
        kind::Symbol, st::Tree3, binfo::JL.BindingInfo;
        skip_recording::Union{Nothing,Set{JL.BindingInfo}} = nothing
    ) where Tree3<:JS.SyntaxTree
    if haskey(occurrences, binfo) && (binfo ∉ @something skip_recording ())
        push!(occurrences[binfo], BindingOccurrence(st, kind))
    end
    return occurrences
end

is_selffunc(b::JL.BindingInfo) = b.name == "#self#"
is_kwsorter_func(b::JL.BindingInfo) = startswith(b.name, '#') && endswith(b.name, r"#\d+$")

function compute_binding_occurrences!(
        occurrences::Dict{JL.BindingInfo,Set{BindingOccurrence{Tree3}}},
        ctx3::JL.VariableAnalysisContext, st3::Tree3;
        ismacro::Union{Nothing,Base.RefValue{Bool}} = nothing,
        skip_recording_uses::Union{Nothing,Set{JL.BindingInfo}} = nothing
    ) where Tree3<:JS.SyntaxTree
    stack = JS.SyntaxList(st3)
    push!(stack, st3)
    infunc = false
    while !isempty(stack)
        st = pop!(stack)
        k = JS.kind(st)
        nc = JS.numchildren(st)
        if k === JS.K"local" # || k === JS.K"function_decl"
            if nc ≥ 1
                record_occurrence!(occurrences, :decl, st[1], ctx3)
                continue # avoid to recurse to skip recording use
            end
        end

        if k === JS.K"BindingId"
            record_occurrence!(occurrences, :use, st, ctx3; skip_recording=skip_recording_uses)
        end

        start_idx = 1
        if k === JS.K"function_decl"
            infunc = true
            if nc ≥ 1
                local func = st[1]
                if JS.kind(func) === JS.K"BindingId"
                    binfo = JL.get_binding(ctx3, func)
                    record_occurrence!(occurrences, :decl, func, binfo)
                    if !isnothing(ismacro)
                        ismacro[] |= startswith(binfo.name, "@")
                    end
                    start_idx = 2
                end
            end
        elseif k === JS.K"method_defs" || k === JS.K"constdecl"
            if nc ≥ 1
                local global_binding = st[1]
                if JS.kind(global_binding) === JS.K"BindingId"
                    binfo = JL.get_binding(ctx3, global_binding)
                    record_occurrence!(occurrences, :def, global_binding, binfo)
                    start_idx = 2
                end
            end
        elseif infunc && k === JS.K"block" && nc ≥ 1
            blk1 = st[1]
            if JS.kind(blk1) === JS.K"function_decl" && JS.numchildren(blk1) ≥ 1
                # This is an inner function definition -- the binding of this inner function
                # is "used" in the language constructs required to define the method,
                # but what we're interested in is whether it's actually used in the outer scope.
                # We add this inner function to `skip_recording_uses` and recurse.
                local func = blk1[1]
                if JS.kind(func) === JS.K"BindingId"
                    innerfuncinfo = JL.get_binding(ctx3, func)
                    compute_binding_occurrences!(occurrences, ctx3, st; ismacro,
                        skip_recording_uses = Set((innerfuncinfo,)))
                    continue
                end
            end
        elseif k === JS.K"lambda"
            # All blocks except the last one define arguments and static parameters,
            # so we recurse to avoid counting them as usage
            if nc ≥ 2
                arglist = st[1]
                for i = 1:JS.numchildren(arglist)
                    record_occurrence!(occurrences, :def, arglist[i], ctx3)
                end
                start_idx = 2
                if nc ≥ 3
                    sparamlist = st[2]
                    for i = 1:JS.numchildren(sparamlist)
                        record_occurrence!(occurrences, :def, sparamlist[i], ctx3)
                    end
                    start_idx = 3
                end
            end
        elseif k === JS.K"="
            start_idx = 2 # the left hand side, i.e. "definition", does not account for usage
            if nc ≥ 1
                record_occurrence!(occurrences, :def, st[1], ctx3)
                if nc ≥ 2
                    rhs = st[2]
                    # In struct definitions, `local struct_name` is somehow introduced,
                    # so special case it here: https://github.com/c42f/JuliaLowering.jl/blob/4b12ab19dad40c64767558be0a8a338eb4cc9172/src/desugaring.jl#L3833
                    # TODO investigate why this local binding introduction is necessary on the JL side
                    if JS.kind(rhs) === JS.K"BindingId" && JL.get_binding(ctx3, rhs).name == "struct_type"
                        start_idx = 1
                    end
                end
            end
        elseif k === JS.K"call" && nc ≥ 1
            arg1 = st[1]
            skip_arguments = false
            if JS.kind(arg1) === JS.K"BindingId"
                funcbind = JL.get_binding(ctx3, arg1)
                if is_selffunc(funcbind)
                    # Don't count self arguments used in self calls as "usage".
                    # This is necessary to issue unused argument diagnostics for `x` in cases like:
                    # ```julia
                    # hasmatch(x::RegexMatch, y::Bool=false) = nothing
                    # ```
                    skip_arguments = true
                elseif is_kwsorter_func(funcbind)
                    # Argument uses in keyword function calls also need to be skipped for the same reason.
                    # Without this, `:use` of `a` in `func(a; x) = x` would be counted.
                    skip_arguments = true
                end
            elseif JS.kind(arg1) === JS.K"top" && get(arg1, :name_val, "") == "kwerr"
                # Skip argument uses for `kwerr` calls as well
                skip_arguments = true
            end
            if skip_arguments
                for i = nc:-1:2 # reversed since we use `pop!`
                    argⱼ = st[i]
                    if JS.kind(argⱼ) === JS.K"BindingId" && JL.get_binding(ctx3, argⱼ).kind === :argument
                        continue # skip this argument
                    end
                    push!(stack, st[i])
                end
                push!(stack, arg1)
                continue
            end
        end
        for i = nc:-1:start_idx # reversed since we use `pop!`
            push!(stack, st[i])
        end
    end

    return occurrences, ismacro
end

function find_global_binding_occurrences!(
        state::ServerState, uri::URI, fi::FileInfo, st0_top::JS.SyntaxTree,
        binfo::JL.BindingInfo;
        kwargs...
    )
    ret = Set{CachedBindingOccurrence}()
    iterate_toplevel_tree(st0_top) do st0::JS.SyntaxTree
        binding_occurrences = @something get_binding_occurrences!(
            state, uri, fi, st0; include_global_bindings = true, kwargs...) return
        for (binfo′, occurrences) in binding_occurrences
            if binfo′.mod === binfo.mod && binfo′.name == binfo.name
                for occurrence in occurrences
                    push!(ret, occurrence)
                end
            end
        end
    end
    return ret
end

function get_binding_occurrences!(
        state::ServerState, uri::URI, fi::FileInfo, st0::JS.SyntaxTree; kwargs...
    )
    range_key = JS.byte_range(st0)
    return store!(state.binding_occurrences_cache) do cache::BindingOccurrencesCacheData
        file_cache = get(cache, uri, nothing)
        if file_cache !== nothing && haskey(file_cache, range_key)
            return cache, file_cache[range_key]
        end
        result = @something compute_binding_occurrences_st0(state, uri, fi, st0; kwargs...) begin
            return cache, nothing
        end
        cache_result = BindingOccurrencesResult()
        for (binfo, occurrences) in result
            cached_set = get!(Set{CachedBindingOccurrence}, cache_result, BindingInfoKey(binfo))
            for occurrence in occurrences
                push!(cached_set, CachedBindingOccurrence(occurrence))
            end
        end
        if file_cache === nothing
            file_cache = BindingOccurrencesCacheEntry(range_key => cache_result)
        else
            file_cache = BindingOccurrencesCacheEntry(file_cache, range_key => cache_result)
        end
        return BindingOccurrencesCacheData(cache, uri => file_cache), cache_result
    end
end

function compute_binding_occurrences_st0(
        state::ServerState, uri::URI, fi::FileInfo, st0::JS.SyntaxTree;
        lookup_func = gen_lookup_out_of_scope!(state, uri),
        include_global_bindings::Bool = false
    )
    (; mod) = get_context_info(state, uri, offset_to_xy(fi, JS.first_byte(st0)); lookup_func)
    (; ctx3, st3) = try
        # Remove macros to preserve precise source locations.
        # TODO: This won't be necessary once JuliaLowering can preserve precise
        # source locations for old macro-expanded code.
        jl_lower_for_scope_resolution(mod, remove_macrocalls(st0))
    catch
        return nothing
    end
    binding_occurrences = compute_binding_occurrences(ctx3, st3; include_global_bindings)

    if include_global_bindings
        collect_macrocall_occurrences!(binding_occurrences, mod, st0)
    end

    return binding_occurrences
end

function collect_macrocall_occurrences!(
        occurrences::Dict{JL.BindingInfo,Set{BindingOccurrence{Tree3}}},
        mod::Module, st0::JS.SyntaxTree
    ) where Tree3<:JS.SyntaxTree
    traverse(st0) do st::JS.SyntaxTree
        JS.kind(st) === JS.K"macrocall" || return nothing
        JS.numchildren(st) ≥ 1 || return nothing
        macrocall_name = st[1]
        (; ctx3) = try
            jl_lower_for_scope_resolution(mod, macrocall_name)
        catch
            return TraversalNoRecurse()
        end
        for binfo in ctx3.bindings.info
            if binfo.kind === :global
                target_set = get!(Set{BindingOccurrence{Tree3}}, occurrences, binfo)
                push!(target_set, BindingOccurrence{Tree3}(JL.binding_ex(ctx3, binfo), :use))
            end
        end
        return nothing # Don't TraversalNoRecurse since macro calls can be nested
    end
    return occurrences
end

function invalidate_binding_occurrences_cache!(state::ServerState, uri::URI)
    store!(state.binding_occurrences_cache) do cache::BindingOccurrencesCacheData
        if haskey(cache, uri)
            Base.delete(cache, uri), nothing
        else
            cache, nothing
        end
    end
end
