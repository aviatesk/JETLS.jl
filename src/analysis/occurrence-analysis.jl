# Like `union!`, but treats occurrences with the same kind and byte range as
# equal even when they are backed by distinct tree nodes.
function union_occurrences_by_range!(
        target::Set{BindingOccurrence}, occurrences::Set{BindingOccurrence}
    )
    for occ in occurrences
        any(target) do existing
            existing.kind === occ.kind &&
                JS.byte_range(existing.tree) == JS.byte_range(occ.tree)
        end && continue
        push!(target, occ)
    end
    return target
end

"""
    compute_binding_occurrences(
            ctx3::JL.VariableAnalysisContext, st3::SyntaxTree, world::UInt;
            include_global_bindings::Bool = false,
            generated_resolutions::Union{Nothing,Vector{InertResolution}} = nothing
        ) -> binding_occurrences::Dict{JL.BindingInfo,Set{BindingOccurrence}}

Analyze a lowered syntax tree to find all occurrences of local and argument bindings.

This function traverses the syntax tree `st3` and records `occurrence::BindingOccurrence`s
for each local and argument binding within `st3`, where `occurrence` have the following
information:
- `occurrence.tree::SyntaxTree`: Syntax tree for this occurrence of the binding
- `occurrence.kind::Symbol`
  - `:decl` - explicit declarations like `local x`
  - `:def` - assignments or function arguments
  - `:method_def` - method definition names
  - `:use` - references to the binding

# Arguments
- `ctx3`: Variable analysis context from JuliaLowering containing binding information
- `st3`: Lowered syntax tree (after scope resolution) to analyze
- `include_global_bindings`: Whether to include global bindings in the result
- `generated_resolutions`: Optional precomputed generated inert resolutions. When
  provided, they are reused instead of lowering generated inert templates again.
- `world`: World age used when lowering generated inert templates

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
        ctx3::JL.VariableAnalysisContext, st3::SyntaxTree, world::UInt;
        include_global_bindings::Bool = false,
        generated_resolutions::Union{Nothing,Vector{InertResolution}} = nothing
    )
    occurrences = Dict{JL.BindingInfo,Set{BindingOccurrence}}()

    same_location_bindings = Dict{Tuple{Symbol,Int,Int},Vector{Int}}() # group together local bindings with the same location and name

    for (i, binfo) = enumerate(ctx3.bindings.info)
        binfo.is_internal && continue
        if binfo.kind === :global
            include_global_bindings || continue
        else
            # Include arguments in location-based merging to unify them with
            # `:local` bindings at the same location. This is needed for:
            # - `@generated` functions: type parameters become actual arguments
            #   that must be unified with their `:static_parameter` counterparts.
            # - Keyword arguments with dependent defaults: JuliaLowering's
            #   `scope_nest` creates `:local` bindings in `let` blocks that
            #   must be unified with the `:argument` binding in the body method.
            # - Arguments referenced in another argument's default: JL creates
            #   duplicate `:argument` bindings at the same source location for
            #   the body method and the default-eval helper.
            lockey = (Symbol(binfo.name), JS.source_location(JL.binding_ex(ctx3, binfo.id))...)
            push!(get!(Vector{Int}, same_location_bindings, lockey), i)
        end
        occurrences[binfo] = Set{BindingOccurrence}()
    end

    isempty(occurrences) && return occurrences

    compute_binding_occurrences!(occurrences, ctx3, st3; include_global_bindings)

    generated_resolutions = if generated_resolutions === nothing
        collect_generated_inert_resolutions(ctx3, st3, world)
    else
        generated_resolutions
    end
    record_generated_inert_argument_uses!(
        occurrences, ctx3, generated_resolutions, world)

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

    # Re-key `:local (mod=nothing)` aliases introduced by type definitions
    # (struct / abstract type / primitive type) onto the matching `:global`
    # binding in the same `ctx3`: the hidden `:global (is_internal=true)`
    # binding for struct definitions, or — for abstract/primitive types, which
    # have no hidden global — the `:global` binding anchored at the same name
    # identifier. Unrelated same-name globals are anchored at distinct
    # definition sites, so the anchor comparison never conflates them. This
    # normalizes type-alias occurrences so they appear under a concrete-module
    # `:global` entry like ordinary globals, letting downstream consumers match
    # on `(mod, name, :global)` exactly without a nothing-mod fallback.
    alias_remaps = Pair{JL.BindingInfo,JL.BindingInfo}[]
    for binfo in keys(occurrences)
        binfo.kind === :local || continue
        isnothing(binfo.mod) || continue
        definition_range = JS.byte_range(JL.binding_ex(ctx3, binfo))
        target = nothing
        for other in ctx3.bindings.info
            other.kind === :global || continue
            other.name == binfo.name || continue
            if other.is_internal
                target = other
                break
            elseif target === nothing &&
                   JS.byte_range(JL.binding_ex(ctx3, other)) == definition_range
                target = other
            end
        end
        target === nothing || push!(alias_remaps, binfo => target)
    end
    for (local_binfo, global_binfo) in alias_remaps
        local_occs = pop!(occurrences, local_binfo)
        definition_tree = JL.binding_ex(ctx3, local_binfo)
        definition_range = JS.byte_range(definition_tree)
        # Typedef lowering assigns this alias and reads it in internal
        # scaffolding at the definition range — and when the target global is
        # the user-visible one, its entry carries the same scaffolding too.
        # Canonicalize that range to a single `:def` (plus any `:decl`s) while
        # retaining user-written self-references at distinct ranges.
        target_occs = get!(Set{BindingOccurrence}, occurrences, global_binfo)
        union!(local_occs, target_occs)
        filter!(local_occs) do occ
            JS.byte_range(occ.tree) != definition_range || occ.kind ∉ (:def, :use)
        end
        push!(local_occs, BindingOccurrence(definition_tree, :def))
        empty!(target_occs)
        union_occurrences_by_range!(target_occs, local_occs)
    end

    # Typedef lowering also emits an explicit `global` decl for the type name
    # (JuliaLang/julia#62862) that resolves to a binding distinct from the alias
    # target above. Fold such same-`(mod, name)` global entries into the alias
    # target, skipping occurrences it already covers at the same range.
    for (_, global_binfo) in alias_remaps
        target_occs = occurrences[global_binfo]
        duplicates = JL.BindingInfo[]
        for binfo in keys(occurrences)
            binfo === global_binfo && continue
            is_matching_global_binding(binfo, global_binfo) || continue
            push!(duplicates, binfo)
        end
        for binfo in duplicates
            union_occurrences_by_range!(target_occs, pop!(occurrences, binfo))
        end
    end

    return occurrences
end

function record_generated_inert_argument_uses!(
        occurrences::Dict{JL.BindingInfo,Set{BindingOccurrence}},
        ctx3::JL.VariableAnalysisContext,
        generated_resolutions::Vector{InertResolution}, world::UInt
    )
    for resolution in generated_resolutions
        isempty(resolution.argument_remap) && continue
        resolved_occurrences = compute_binding_occurrences(
            resolution.ctx3, resolution.st3, world)
        for (resolved_binfo, source) in resolution.argument_remap
            source_binfo = JL.get_binding(ctx3, source)
            haskey(occurrences, source_binfo) || continue
            resolved_boccs = get(resolved_occurrences, resolved_binfo, nothing)
            resolved_boccs === nothing && continue
            for occurrence in resolved_boccs
                occurrence.kind === :use || continue
                JS.byte_range(occurrence.tree) ⊆ resolution.source_range || continue
                source_occurrences = occurrences[source_binfo]
                any(source_occurrences) do existing
                    existing.kind === occurrence.kind &&
                        JS.byte_range(existing.tree) == JS.byte_range(occurrence.tree)
                end && continue
                push!(source_occurrences, occurrence)
            end
        end
    end
    return occurrences
end

"""
`skip_recording` maps a binding to a byte range. A BindingId is skipped only if
both its binding and its byte range match an entry. This distinguishes synthetic
BindingIds that lowering inserts at the definition-site range (e.g., inside
`method`, `function_type`, or `removable` nodes) from genuine uses such as
self-recursive calls, which have distinct byte ranges.
"""
const SkipRecording = Dict{JL.BindingInfo,UnitRange{Int}}

function may_record_occurrence!(occurrences::Dict{JL.BindingInfo,Set{BindingOccurrence}},
        kind::Symbol, st::SyntaxTree, ctx3::JL.VariableAnalysisContext;
        skip_recording::Union{Nothing,SkipRecording} = nothing
    )
    if JS.kind(st) === JS.K"BindingId"
        binfo = JL.get_binding(ctx3, st)
        _may_record_occurrence!(occurrences, kind, st, binfo; skip_recording)
        return true
    end
    return false
end

function _may_record_occurrence!(occurrences::Dict{JL.BindingInfo,Set{BindingOccurrence}},
        kind::Symbol, st::SyntaxTree, binfo::JL.BindingInfo;
        skip_recording::Union{Nothing,SkipRecording} = nothing
    )
    haskey(occurrences, binfo) || return
    if !isnothing(skip_recording)
        skip_range = get(skip_recording, binfo, nothing)
        if skip_range !== nothing && JS.byte_range(st) == skip_range
            return
        end
    end
    push!(occurrences[binfo], BindingOccurrence(st, kind))
    occurrences
end

is_selffunc(b::JL.BindingInfo) = b.name == "#self#"
is_kwsorter_func(b::JL.BindingInfo) = startswith(b.name, '#') && endswith(b.name, r"#\d+$")

function compute_binding_occurrences!(
        occurrences::Dict{JL.BindingInfo,Set{BindingOccurrence}},
        ctx3::JL.VariableAnalysisContext, st3::SyntaxTree;
        include_global_bindings::Bool = false,
        skip_recording_uses::Union{Nothing,SkipRecording} = nothing
    )
    stack = JS.SyntaxList(st3)
    while !isempty(stack)
        st = pop!(stack)
        k = JS.kind(st)
        nc = JS.numchildren(st)
        if k === JS.K"BindingId"
            may_record_occurrence!(occurrences, :use, st, ctx3; skip_recording=skip_recording_uses)
        end

        start_idx = 1
        if k in JS.KSet"local function_decl" || (include_global_bindings && k === JS.K"global")
            if nc ≥ 1 && may_record_occurrence!(occurrences, :decl, st[1], ctx3)
                start_idx = 2 # skip recording use
            end
        elseif k in JS.KSet"method_defs constdecl"
            occurrence_kind = k === JS.K"method_defs" ? :method_def : :def
            if nc ≥ 1 && may_record_occurrence!(occurrences, occurrence_kind, st[1], ctx3)
                start_idx = 2
            end
        elseif k === JS.K"block" && nc ≥ 1 && JS.kind(st[1]) === JS.K"function_decl"
            # This block wraps a function definition. Each function's own binding
            # appears as BindingId in internal lowering nodes (`method`,
            # `function_type`, `removable`, or as the trailing "return value" of
            # the definition) that are not user-visible uses. We collect the
            # bindings of all leading `function_decl` children (a single block
            # may declare multiple functions, e.g., a keyword function generates
            # both the user-visible function and a `#kw_body#…` helper) and map
            # each to its definition-site byte range in `skip_recording_uses`
            # before recursing. BindingIds whose range matches are skipped, while
            # genuine uses at different ranges (e.g., self-recursive calls) are
            # still recorded. Bindings already present in `skip_recording_uses`
            # are used as a termination condition to avoid infinite recursion.
            newly_added = Pair{JL.BindingInfo,UnitRange{Int}}[]
            for i = 1:nc
                child = st[i]
                JS.kind(child) === JS.K"function_decl" || continue
                JS.numchildren(child) ≥ 1 || continue
                funcnode = child[1]
                JS.kind(funcnode) === JS.K"BindingId" || continue
                funcinfo = JL.get_binding(ctx3, funcnode)
                if isnothing(skip_recording_uses) || !haskey(skip_recording_uses, funcinfo)
                    push!(newly_added, funcinfo => JS.byte_range(funcnode))
                end
            end
            if !isempty(newly_added)
                if isnothing(skip_recording_uses)
                    compute_binding_occurrences!(occurrences, ctx3, st;
                        skip_recording_uses = SkipRecording(newly_added))
                else
                    for br in newly_added; push!(skip_recording_uses, br); end
                    compute_binding_occurrences!(occurrences, ctx3, st;
                        skip_recording_uses)
                    for (b, _) in newly_added; delete!(skip_recording_uses, b); end
                end
                continue
            end
        elseif k in JS.KSet"lambda toplevel_lambda"
            # All blocks except the last one define arguments and static parameters,
            # so we recurse to avoid counting them as usage
            start_idx = 2 # skip the K"LambdaBindings" leaf
            if nc ≥ 3
                arglist = st[2]
                for i = 1:JS.numchildren(arglist)
                    may_record_occurrence!(occurrences, :def, arglist[i], ctx3)
                end
                start_idx = 3
                if nc ≥ 4
                    sparamlist = st[3]
                    for i = 1:JS.numchildren(sparamlist)
                        may_record_occurrence!(occurrences, :def, sparamlist[i], ctx3)
                    end
                    start_idx = 4
                end
            end
        elseif k === JS.K"="
            start_idx = 2 # the left hand side, i.e. "definition", does not account for usage
            if nc ≥ 1
                may_record_occurrence!(occurrences, :def, st[1], ctx3)
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
            elseif JS.kind(arg1) === JS.K"top" && get_name_val(arg1) == "kwerr"
                # Skip argument uses for `kwerr` calls as well
                skip_arguments = true
            end
            if skip_arguments
                for i = nc:-1:2 # reversed since we use `pop!`
                    argⱼ = st[i]
                    if JS.kind(argⱼ) === JS.K"BindingId"
                        bkind = JL.get_binding(ctx3, argⱼ).kind
                        # Skip both `:argument` and `:local` bindings.
                        # `:local` bindings appear in kwsorter calls when
                        # `scope_nest` is used for dependent keyword defaults.
                        if bkind === :argument || bkind === :local
                            continue
                        end
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

    return occurrences
end

function is_matching_global_binding(
        a::Union{BindingInfoKey,JL.BindingInfo},
        b::Union{BindingInfoKey,JL.BindingInfo},
    )
    return a.kind === :global && b.kind === :global && a.name == b.name && a.mod === b.mod
end

function find_global_binding_occurrences!(
        state::ServerState, uri::URI, fi::FileInfo, binfo::JL.BindingInfo;
        lookup_func = gen_lookup_out_of_scope!(state, uri),
    )
    cached = get_cached_global_binding_occurrences(state, uri, binfo)
    cached === nothing || return cached
    st0_top = build_syntax_tree(fi)
    return find_global_binding_occurrences_from_tree!(
        state, uri, fi, st0_top, binfo; lookup_func)
end

function get_cached_global_binding_occurrences(
        state::ServerState, uri::URI, binfo::JL.BindingInfo
    )
    cache_uri = canonical_cache_uri(state, uri)
    file_cache = get(load(state.binding_occurrences_cache), cache_uri, nothing)
    file_cache === nothing && return nothing
    globals = @something file_cache.globals return nothing
    return lookup_global_binding_occurrences(globals, binfo)
end

function find_global_binding_occurrences_from_tree!(
        state::ServerState, uri::URI, fi::FileInfo, st0_top::SyntaxTree, binfo::JL.BindingInfo;
        lookup_func = gen_lookup_out_of_scope!(state, uri),
    )
    cached = get_cached_global_binding_occurrences(state, uri, binfo)
    cached === nothing || return cached
    globals = BindingOccurrencesResult()
    iterate_toplevel_tree(st0_top) do st0::SyntaxTree
        binding_occurrences = @something get_binding_occurrences!(
            state, uri, fi, st0; lookup_func) return
        add_global_binding_occurrences!(globals, binding_occurrences)
    end
    store_global_binding_occurrences!(state, uri, globals)
    return lookup_global_binding_occurrences(globals, binfo)
end

function lookup_global_binding_occurrences(
        globals::BindingOccurrencesResult, binfo::JL.BindingInfo
    )
    ret = Set{CachedBindingOccurrence}()
    for (binfo′, occurrences) in globals
        is_matching_global_binding(binfo′, binfo) || continue
        union!(ret, occurrences)
    end
    return ret
end

function add_global_binding_occurrences!(
        globals::BindingOccurrencesResult, result::BindingOccurrencesResult
    )
    for (binfo, occurrences) in result
        binfo.kind === :global || continue
        union!(get!(Set{CachedBindingOccurrence}, globals, binfo), occurrences)
    end
    return globals
end

function store_global_binding_occurrences!(
        state::ServerState, uri::URI, globals::BindingOccurrencesResult
    )
    cache_uri = canonical_cache_uri(state, uri)
    store!(state.binding_occurrences_cache) do cache::BindingOccurrencesCacheData
        file_cache = get(cache, cache_uri, nothing)
        by_range = file_cache === nothing ? BindingOccurrencesRangeCache() : file_cache.by_range
        new_file_cache = BindingOccurrencesCacheEntry(by_range, globals)
        return BindingOccurrencesCacheData(cache, cache_uri => new_file_cache), nothing
    end
end

# Cached entry point. The cache key is only the byte range — `lookup_func`
# is *not* part of the key. Production callers all rely on the default
# `gen_lookup_out_of_scope!`, so they share the cache safely. Tests that
# pass a custom `lookup_func` use isolated `ServerState` instances and
# therefore don't collide with the production cache.
function get_binding_occurrences!(
        state::ServerState, uri::URI, fi::FileInfo, st0::SyntaxTree;
        lookup_func = gen_lookup_out_of_scope!(state, uri),
    )
    cache_uri = canonical_cache_uri(state, uri)
    range_key = JS.byte_range(st0)
    return store!(state.binding_occurrences_cache) do cache::BindingOccurrencesCacheData
        file_cache = get(cache, cache_uri, nothing)
        if file_cache !== nothing && haskey(file_cache.by_range, range_key)
            return cache, file_cache.by_range[range_key]
        end
        # Cache lowering failures as empty results so repeated calls for the same statement
        cache_result = BindingOccurrencesResult()
        result = compute_full_binding_occurrences(state, uri, fi, st0; lookup_func)
        if result !== nothing
            for (binfo, occurrences) in result
                cached_set = get!(Set{CachedBindingOccurrence}, cache_result, BindingInfoKey(binfo))
                for occurrence in occurrences
                    push!(cached_set, CachedBindingOccurrence(occurrence))
                end
            end
        end
        by_range = file_cache === nothing ?
            BindingOccurrencesRangeCache(range_key => cache_result) :
            BindingOccurrencesRangeCache(file_cache.by_range, range_key => cache_result)
        file_cache = BindingOccurrencesCacheEntry(by_range, nothing)
        return BindingOccurrencesCacheData(cache, cache_uri => file_cache), cache_result
    end
end

function compute_full_binding_occurrences(
        state::ServerState, uri::URI, fi::FileInfo, st0::SyntaxTree;
        lookup_func = gen_lookup_out_of_scope!(state, uri),
    )
    soft_scope = is_notebook_cell_uri(state, uri) ||
        # Handlers like References and Rename receive notebook cell URIs, just like
        # other LSP handlers. However, when performing a global search over an analysis
        # unit using `collect_search_uris`, the notebook URI is used instead, and its
        # lowering requires `soft_scope`.
        is_notebook_uri(state, uri)
    pos = offset_to_xy(fi, JS.first_byte(st0))
    (; context_module, world) = get_context_info(state, uri, pos; lookup_func)

    if JS.kind(st0) in JS.KSet"export public import using"
        # `import`/`using`/`export`/`public` declarations are collected from the source tree
        # by `collect_import_export_occurrences!` below (lowering doesn't surface them).
        # A statement that is *only* such a declaration has no other code, so skip lowering it.
        binding_occurrences = Dict{JL.BindingInfo,Set{BindingOccurrence}}()
    else
        # Remove macros to preserve precise source locations. `strip_static=true` keeps
        # every `@static` branch as a plain conditional, so identifiers used in the
        # condition and in branches not taken on this platform are still collected —
        # scope-aware, since each branch is resolved within its enclosing scope.
        # TODO: This won't be necessary once JuliaLowering can preserve precise
        # source locations for old macro-expanded code.
        st0′ = remove_macrocalls(context_module, world, st0; strip_static=true)
        (; ctx3, st3) = try
            jl_lower_for_scope_resolution(context_module, world, st0′; soft_scope)
        catch
            return nothing
        end
        generated_resolutions = collect_generated_inert_resolutions(ctx3, st3, world)
        occs = compute_binding_occurrences(ctx3, st3, world;
            include_global_bindings=true, generated_resolutions)
        collect_struct_inner_constructor_occurrences!(occs, ctx3, st0)
        collect_macrocall_occurrences!(
            occs, context_module, world, st0; soft_scope)
        # Add generated-body and policy-approved inert occurrences.
        collect_inert_global_occurrences!(occs, st3, st0, context_module, world,
            generated_resolutions; soft_scope)
        binding_occurrences = occs
    end
    collect_import_export_occurrences!(binding_occurrences, st0, context_module)
    return binding_occurrences
end

function collect_struct_inner_constructor_occurrences!(
        occurrences::Dict{JL.BindingInfo,Set{BindingOccurrence}},
        ctx3::JL.VariableAnalysisContext, st0::SyntaxTree
    )
    foreach_struct_inner_constructor(st0) do name_node::SyntaxTree, constructor_node::SyntaxTree
        binding = @something _find_internal_global_binding_at_source(ctx3, name_node) return true
        binfo = JL.get_binding(ctx3, binding)
        boccs = get!(Set{BindingOccurrence}, occurrences, binfo)
        occ = BindingOccurrence(constructor_node, :method_def)
        push!(boccs, occ)
        return true
    end
    return occurrences
end

# Standalone `BindingInfo` key (id 0, never registered with a `Bindings`) for
# surface-only occurrences that lowering doesn't produce bindings for.
surface_global_binfo(name::String, node::SyntaxTree, mod::Module) =
    JL.BindingInfo(JL.IdTag(0), name, :global, node, mod, nothing, 0,
        false, false, false, false, false, false, false, false, false, false,
        false, false, false)

function collect_export_public_occurrences!(
        occurrences::Dict{JL.BindingInfo,Set{BindingOccurrence}},
        st0::SyntaxTree, context_module::Module
    )
    JS.kind(st0) in JS.KSet"export public" || return occurrences
    for i = 1:JS.numchildren(st0)
        child = st0[i]
        JS.kind(child) === JS.K"Identifier" || continue
        name = @something get_name_val(child) continue
        binfo = surface_global_binfo(name, child, context_module)
        target_set = get!(Set{BindingOccurrence}, occurrences, binfo)
        push!(target_set, BindingOccurrence(child, :use))
    end
    return occurrences
end

function collect_import_using_occurrences!(
        occurrences::Dict{JL.BindingInfo,Set{BindingOccurrence}},
        st0::SyntaxTree, context_module::Module
    )
    foreach_local_import_identifier(st0) do id_st::SyntaxTree
        name = @something get_name_val(id_st) return
        binfo = surface_global_binfo(name, id_st, context_module)
        target_set = get!(Set{BindingOccurrence}, occurrences, binfo)
        push!(target_set, BindingOccurrence(id_st, :decl))
        return
    end
    return occurrences
end

# Collect occurrences for every `import`/`using`/`export`/`public` statement in `st0`,
# whether it is the whole statement or nested in a block (`if`/`begin`/`@static if`/…).
# Lowering doesn't surface these declarations — `export`/`public` collapse their names
# into a runtime call argument, and `import`/`using` desugar their module paths into
# `K"inert"` calls that `collect_inert_global_occurrences!` skips — so collect them from
# the source tree instead:
# - `export foo`/`public foo`: `foo` as a `:use` of the surrounding module's global.
# - `using M: foo`/`import M.foo`/`foo as bar`: the local name (`foo`/`bar`) as a `:decl`.
# `K"module"` (a distinct binding scope) and `K"quote"` (quoted, non-executed code) are
# not descended into.
function collect_import_export_occurrences!(
        occurrences::Dict{JL.BindingInfo,Set{BindingOccurrence}},
        st0::SyntaxTree, context_module::Module
    )
    traverse(st0) do st::SyntaxTree
        k = JS.kind(st)
        if k in JS.KSet"module quote"
            return traversal_no_recurse
        elseif k in JS.KSet"export public"
            collect_export_public_occurrences!(occurrences, st, context_module)
            return traversal_no_recurse
        elseif k in JS.KSet"import using"
            collect_import_using_occurrences!(occurrences, st, context_module)
            return traversal_no_recurse
        end
        return nothing
    end
    return occurrences
end

function collect_macrocall_occurrences!(
        occurrences::Dict{JL.BindingInfo,Set{BindingOccurrence}},
        context_module::Module, world::UInt, st0::SyntaxTree;
        soft_scope::Bool = false,
    )
    traverse(st0) do st::SyntaxTree
        JS.kind(st) === JS.K"macrocall" || return nothing
        JS.numchildren(st) ≥ 1 || return nothing
        should_resolve_macrocall(
            context_module, world, st0, JS.byte_range(st)) || return traversal_no_recurse
        macrocall_name = st[1]
        (; ctx3) = try
            jl_lower_for_scope_resolution(
                context_module, world, macrocall_name; soft_scope)
        catch
            return traversal_no_recurse
        end
        for binfo in ctx3.bindings.info
            if binfo.kind === :global
                target_set = get!(Set{BindingOccurrence}, occurrences, binfo)
                push!(target_set, BindingOccurrence(JL.binding_ex(ctx3, binfo), :use))
            end
        end
        return nothing # Don't TraversalNoRecurse since macro calls can be nested
    end
    return occurrences
end

function collect_resolved_inert_globals!(
        occurrences::Dict{JL.BindingInfo,Set{BindingOccurrence}},
        resolution::InertResolution, world::UInt
    )
    resolved_occurrences = compute_binding_occurrences(
        resolution.ctx3, resolution.st3, world; include_global_bindings=true)
    for (binfo, boccs) in resolved_occurrences
        binfo.kind === :global || continue
        binfo.is_internal && continue
        binfo.name == resolution.placeholder_name && continue
        target = get!(Set{BindingOccurrence}, occurrences, binfo)
        for occurrence in boccs
            JS.byte_range(occurrence.tree) ⊆ resolution.source_range || continue
            push!(target, occurrence)
        end
    end
    return occurrences
end

"""
    collect_inert_global_occurrences!

Collect globals from generated bodies and inert ranges accepted by
[`inert_resolution_policy`](@ref). This keeps the workspace occurrence index in
sync with target selection for references and rename.
"""
function collect_inert_global_occurrences!(
        occurrences::Dict{JL.BindingInfo,Set{BindingOccurrence}},
        st3::SyntaxTree, st0::SyntaxTree, context_module::Module, world::UInt,
        generated_resolutions::Vector{InertResolution};
        soft_scope::Bool = false,
    )
    # Generated bodies need their function arguments remapped into runtime scope.
    for resolution in generated_resolutions
        collect_resolved_inert_globals!(occurrences, resolution, world)
    end

    seen = Set{Tuple{JS.Kind,UnitRange{Int}}}()
    traverse(st3) do inert_tree::SyntaxTree
        is_import_eval_call(inert_tree) && return traversal_no_recurse
        JS.kind(inert_tree) in JS.KSet"inert syntaxinert" || return nothing
        JS.numchildren(inert_tree) >= 1 || return nothing
        range = JS.byte_range(inert_tree)
        key = (JS.kind(inert_tree), range)
        key in seen && return traversal_no_recurse
        push!(seen, key)
        # Generated ranges were handled above with their dedicated argument scope.
        is_generated_inert_range(context_module, world, st0, range) && return traversal_no_recurse
        policy = inert_resolution_policy(context_module, world, st0, range)
        policy === :unresolved && return traversal_no_recurse
        hard_scope = policy === :macro
        resolution = resolve_inert_tree(context_module, world, inert_tree; hard_scope, soft_scope)
        resolution === nothing || collect_resolved_inert_globals!(occurrences, resolution, world)
        return nothing
    end
    return occurrences
end

function invalidate_binding_occurrences_cache!(state::ServerState, uri::URI)
    cache_uri = canonical_cache_uri(state, uri)
    store!(state.binding_occurrences_cache) do cache::BindingOccurrencesCacheData
        if haskey(cache, cache_uri)
            Base.delete(cache, cache_uri), nothing
        else
            cache, nothing
        end
    end
end
