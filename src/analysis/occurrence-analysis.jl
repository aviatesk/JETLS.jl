"""
    compute_binding_occurrences(
            ctx3::JL.VariableAnalysisContext, st3::SyntaxTreeC, is_generated::Bool;
            include_global_bindings::Bool = false
        ) -> binding_occurrences::Dict{JL.BindingInfo,Set{BindingOccurrence}}

Analyze a lowered syntax tree to find all occurrences of local and argument bindings.

This function traverses the syntax tree `st3` and records `occurrence::BindingOccurrence`s
for each local and argument binding within `st3`, where `occurrence` have the following
information:
- `occurrence.tree::SyntaxTreeC`: Syntax tree for this occurrence of the binding
- `occurrence.kind::Symbol`
  - `:decl` - explicit declarations like `local x`
  - `:def` - assignments or function arguments
  - `:use` - references to the binding

# Arguments
- `ctx3`: Variable analysis context from JuliaLowering containing binding information
- `st3`: Lowered syntax tree (after scope resolution) to analyze

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
        ctx3::JL.VariableAnalysisContext, st3::SyntaxTreeC, is_generated::Bool;
        include_global_bindings::Bool = false
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

    # In `@generated` functions, arguments are typically used only inside returned
    # quoted expressions (`:(...)`) which appear as `inert` nodes after lowering.
    # Scope resolution doesn't look inside `inert` nodes, so these arguments appear
    # unused. We scan `inert` nodes for identifiers matching argument names and
    # record them as `:use` occurrences.
    if is_generated
        inert_ids = collect_inert_identifiers(st3)
        for (binfo, _) in occurrences
            binfo.kind === :argument || continue
            id_nodes = get(inert_ids, binfo.name, nothing)
            if id_nodes !== nothing
                for id_node in id_nodes
                    push!(occurrences[binfo], BindingOccurrence(id_node, :use))
                end
            end
        end
    end

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
    # (struct / abstract type / primitive type) onto the matching hidden
    # `:global (is_internal=true)` binding in the same `ctx3`. This normalizes
    # struct-alias occurrences so they appear under a concrete-module `:global`
    # entry like ordinary globals, letting downstream consumers match on
    # `(mod, name, :global)` exactly without a nothing-mod fallback.
    alias_remaps = Pair{JL.BindingInfo,JL.BindingInfo}[]
    for binfo in keys(occurrences)
        binfo.kind === :local || continue
        isnothing(binfo.mod) || continue
        for other in ctx3.bindings.info
            other.kind === :global || continue
            other.is_internal || continue
            other.name == binfo.name || continue
            push!(alias_remaps, binfo => other)
            break
        end
    end
    for (local_binfo, global_binfo) in alias_remaps
        local_occs = pop!(occurrences, local_binfo)
        existing = get!(Set{BindingOccurrence}, occurrences, global_binfo)
        union!(existing, local_occs)
    end

    return occurrences
end

function collect_inert_identifiers(st3::SyntaxTreeC)
    result = Dict{String,Vector{SyntaxTreeC}}()
    foreach_inert_identifier(st3) do id_node::SyntaxTreeC
        JS.hasattr(id_node, :name_val) || return true
        name_val = id_node.name_val
        name_val isa AbstractString || return true
        push!(get!(Vector{SyntaxTreeC}, result, name_val), id_node)
        return true
    end
    return result
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
        kind::Symbol, st::SyntaxTreeC, ctx3::JL.VariableAnalysisContext;
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
        kind::Symbol, st::SyntaxTreeC, binfo::JL.BindingInfo;
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
        ctx3::JL.VariableAnalysisContext, st3::SyntaxTreeC;
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
            if nc ≥ 1 && may_record_occurrence!(occurrences, :def, st[1], ctx3)
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
        elseif k === JS.K"lambda"
            # All blocks except the last one define arguments and static parameters,
            # so we recurse to avoid counting them as usage
            if nc ≥ 2
                arglist = st[1]
                for i = 1:JS.numchildren(arglist)
                    may_record_occurrence!(occurrences, :def, arglist[i], ctx3)
                end
                start_idx = 2
                if nc ≥ 3
                    sparamlist = st[2]
                    for i = 1:JS.numchildren(sparamlist)
                        may_record_occurrence!(occurrences, :def, sparamlist[i], ctx3)
                    end
                    start_idx = 3
                end
            end
        elseif k === JS.K"="
            start_idx = 2 # the left hand side, i.e. "definition", does not account for usage
            if nc ≥ 1
                may_record_occurrence!(occurrences, :def, st[1], ctx3)
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
        state::ServerState, uri::URI, fi::FileInfo, st0_top::SyntaxTreeC, binfo::JL.BindingInfo;
        lookup_func = gen_lookup_out_of_scope!(state, uri),
    )
    ret = Set{CachedBindingOccurrence}()
    iterate_toplevel_tree(st0_top) do st0::SyntaxTreeC
        binding_occurrences = @something get_binding_occurrences!(
            state, uri, fi, st0; lookup_func) return
        for (binfo′, occurrences) in binding_occurrences
            if is_matching_global_binding(binfo′, binfo)
                for occurrence in occurrences
                    push!(ret, occurrence)
                end
            end
        end
    end
    return ret
end

# Cached entry point. The cache key is only the byte range — `lookup_func`
# is *not* part of the key. Production callers all rely on the default
# `gen_lookup_out_of_scope!`, so they share the cache safely. Tests that
# pass a custom `lookup_func` use isolated `ServerState` instances and
# therefore don't collide with the production cache.
function get_binding_occurrences!(
        state::ServerState, uri::URI, fi::FileInfo, st0::SyntaxTreeC;
        lookup_func = gen_lookup_out_of_scope!(state, uri),
    )
    cache_uri = canonical_cache_uri(state, uri)
    range_key = JS.byte_range(st0)
    return store!(state.binding_occurrences_cache) do cache::BindingOccurrencesCacheData
        file_cache = get(cache, cache_uri, nothing)
        if file_cache !== nothing && haskey(file_cache, range_key)
            return cache, file_cache[range_key]
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
        if file_cache === nothing
            file_cache = BindingOccurrencesCacheEntry(range_key => cache_result)
        else
            file_cache = BindingOccurrencesCacheEntry(file_cache, range_key => cache_result)
        end
        return BindingOccurrencesCacheData(cache, cache_uri => file_cache), cache_result
    end
end

function compute_full_binding_occurrences(
        state::ServerState, uri::URI, fi::FileInfo, st0::SyntaxTreeC;
        lookup_func = gen_lookup_out_of_scope!(state, uri),
    )
    soft_scope = is_notebook_cell_uri(state, uri) ||
        # Handlers like References and Rename receive notebook cell URIs, just like
        # other LSP handlers. However, when performing a global search over an analysis
        # unit using `collect_search_uris`, the notebook URI is used instead, and its
        # lowering requires `soft_scope`.
        is_notebook_uri(state, uri)
    (; mod) = get_context_info(state, uri, offset_to_xy(fi, JS.first_byte(st0)); lookup_func)

    # Lowering `export`/`public`/`import`/`using` statements collapses their listed
    # identifiers into opaque `K"Value"` nodes and records no `BindingInfo` for them,
    # so the usual traversal finds nothing. Handle them directly:
    # - `export foo`/`public foo`: record `foo` as a `:use` of the corresponding global
    #   binding in the surrounding module.
    # - `using M: foo`/`import M: foo`/`import M.foo`: record the local alias identifier
    #   (`foo`, or `bar` in `foo as bar`) as a `:def` of the local global binding.
    k0 = JS.kind(st0)
    if k0 in JS.KSet"export public"
        binding_occurrences = Dict{JL.BindingInfo,Set{BindingOccurrence}}()
        collect_export_public_occurrences!(binding_occurrences, st0, mod)
        return binding_occurrences
    elseif k0 in JS.KSet"import using"
        binding_occurrences = Dict{JL.BindingInfo,Set{BindingOccurrence}}()
        collect_import_using_occurrences!(binding_occurrences, st0, mod)
        return binding_occurrences
    end

    (; ctx3, st3) = try
        # Remove macros to preserve precise source locations.
        # TODO: This won't be necessary once JuliaLowering can preserve precise
        # source locations for old macro-expanded code.
        jl_lower_for_scope_resolution(mod, remove_macrocalls(st0); soft_scope)
    catch
        return nothing
    end
    is_generated = is_generated0(st0)
    binding_occurrences = compute_binding_occurrences(ctx3, st3, is_generated;
        include_global_bindings = true)

    collect_macrocall_occurrences!(binding_occurrences, mod, st0; soft_scope)
    # Global bindings used inside inert nodes (quoted expressions) are not
    # resolved by scope analysis. This applies to `@generated` functions,
    # macro definitions, and any function that constructs quoted expressions.
    # Run independent scope resolution on inert content to collect them.
    collect_inert_global_occurrences!(binding_occurrences, ctx3, st3, mod; soft_scope)

    return binding_occurrences
end

function collect_export_public_occurrences!(
        occurrences::Dict{JL.BindingInfo,Set{BindingOccurrence}},
        st0::SyntaxTreeC, mod::Module
    )
    JS.kind(st0) in JS.KSet"export public" || return occurrences
    for i = 1:JS.numchildren(st0)
        child = st0[i]
        JS.kind(child) === JS.K"Identifier" || continue
        name = get(child, :name_val, nothing)
        name isa AbstractString || continue
        binfo = JL.BindingInfo(0, name, :global, 0; mod)
        target_set = get!(Set{BindingOccurrence}, occurrences, binfo)
        push!(target_set, BindingOccurrence(child, :use))
    end
    return occurrences
end

function collect_import_using_occurrences!(
        occurrences::Dict{JL.BindingInfo,Set{BindingOccurrence}},
        st0::SyntaxTreeC, mod::Module
    )
    foreach_local_import_identifier(st0) do id_st::SyntaxTreeC
        name = get(id_st, :name_val, nothing)
        name isa AbstractString || return
        binfo = JL.BindingInfo(0, name, :global, 0; mod)
        target_set = get!(Set{BindingOccurrence}, occurrences, binfo)
        push!(target_set, BindingOccurrence(id_st, :decl))
        return
    end
    return occurrences
end

function collect_macrocall_occurrences!(
        occurrences::Dict{JL.BindingInfo,Set{BindingOccurrence}},
        mod::Module, st0::SyntaxTreeC;
        soft_scope::Bool = false
    )
    traverse(st0) do st::SyntaxTreeC
        JS.kind(st) === JS.K"macrocall" || return nothing
        JS.numchildren(st) ≥ 1 || return nothing
        macrocall_name = st[1]
        (; ctx3) = try
            jl_lower_for_scope_resolution(mod, macrocall_name; soft_scope)
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

"""
    collect_inert_global_occurrences!

Collect global bindings used inside `K"inert"` nodes by running independent
scope resolution on each inert subtree and recording any non-internal
`:global` bindings it finds as `:use` occurrences. The inert subtree is
lowered with `mod` — the enclosing module at the inert's position — as
the resolution module.

# Approximation

This is a pragmatic approximation, not a precise analysis. The enclosing
module is correct for the cases where quoted code is eventually evaluated
there:

- `@eval body` — `body` is `eval`'d in the module where `@eval` appears.
- User-defined macro bodies — free identifiers in a macro's returned AST
  are hygienically resolved in the macro's defining module.
- `@generated` function bodies — the returned AST becomes the generated
  method's body, compiled in the function's module; global references
  inside thus resolve in that module.

The approximation breaks down whenever the inert content is ultimately
evaluated somewhere other than `mod`. Detecting these cases would
require cross-function / whole-program analysis that we don't currently
perform:

- The inert content is spliced into another quote that introduces a
  new local scope — e.g. a builder that returns
  `quote function f(x); \$body; end end`, where identifiers inside
  `body` are meant to resolve against `f`'s arguments, not globals in
  `mod`.
- The resulting `Expr`/`SyntaxTree` is handed off to `Core.eval` in a
  different module — e.g. `g() = :(foo())` later called as
  `Core.eval(SomeOtherModule, g())`, so `foo` resolves in
  `SomeOtherModule` rather than `g`'s defining module.

These cases may produce orphan entries (recorded in the wrong module) or
miss real references. They are accepted as a known limitation.

# Argument-name handling

Free identifiers inside inert content that match an enclosing
function/macro argument name are filtered out to avoid false
`:global :use` occurrences. Two independent reasons motivate this:

- `@generated` bodies — plain identifiers in the returned quote are
  compile-time references to the function's parameters.
  `compute_binding_occurrences` already records them as
  `:argument :use` via `collect_inert_identifiers` when
  `is_generated=true`; the filter prevents duplicating those as
  `:global :use` here.
- `quote ... \$arg ... end` inside any function or macro body —
  scope resolution handles `\$arg` correctly (the argument `arg` is
  used as an interpolation value, recorded as `:argument :use` in
  the usual walk), and the inert template itself is not a reference
  to `arg`. But `unwrap_interpolations` strips the `\$` node for
  lowering, turning `\$arg` into a bare `arg` identifier which the
  fresh resolution then classifies as `:global`. The filter
  compensates for this unwrap artifact.
"""
function collect_inert_global_occurrences!(
        occurrences::Dict{JL.BindingInfo,Set{BindingOccurrence}},
        ctx3::JL.VariableAnalysisContext, st3::SyntaxTreeC, mod::Module;
        soft_scope::Bool = false
    )
    arg_names = Set{String}()
    for binfo in ctx3.bindings.info
        if binfo.kind === :argument && !binfo.is_internal
            push!(arg_names, binfo.name)
        end
    end
    st3_range = JS.byte_range(st3)
    traverse(st3) do st3′::SyntaxTreeC
        JS.kind(st3′) === JS.K"inert" || return nothing
        JS.numchildren(st3′) >= 1 || return nothing
        # Skip the outer inert that wraps the entire generator template
        JS.byte_range(st3′) == st3_range && return nothing
        ires = try
            # Inert nodes with `$` (interpolation) fail to lower directly.
            # Unwrap `$` nodes (replace with their content) instead of removing
            # them, so that parent nodes like dot expressions (`x.$name`)
            # remain well-formed and non-interpolated identifiers are resolved.
            jl_lower_for_scope_resolution(mod, unwrap_interpolations(st3′[1]); soft_scope)
        catch
            return nothing
        end
        for binfo in ires.ctx3.bindings.info
            if binfo.kind === :global && !binfo.is_internal && !(binfo.name in arg_names)
                # Use the inert ctx's BindingInfo as key; when cached via
                # BindingInfoKey(mod, name, :global) it matches the import.
                occ_set = get!(Set{BindingOccurrence}, occurrences, binfo)
                push!(occ_set, BindingOccurrence(
                    JL.binding_ex(ires.ctx3, binfo.id), :use))
            end
        end
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
