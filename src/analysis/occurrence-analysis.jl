"""
    compute_binding_occurrences(
            ctx3::JL.VariableAnalysisContext, st3::Tree3, is_generated::Bool;
            include_global_bindings::Bool = false
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
        ctx3::JL.VariableAnalysisContext, st3::Tree3, is_generated::Bool;
        include_global_bindings::Bool = false
    ) where Tree3<:JS.SyntaxTree
    occurrences = Dict{JL.BindingInfo,Set{BindingOccurrence{Tree3}}}()

    same_arg_bindings = Dict{Symbol,Vector{Int}}() # group together argument bindings with the same name
    same_location_bindings = Dict{Tuple{Symbol,Int,Int},Vector{Int}}() # group together local bindings with the same location and name

    for (i, binfo) = enumerate(ctx3.bindings.info)
        binfo.is_internal && continue
        if binfo.kind === :global
            include_global_bindings || continue
        else
            if binfo.kind === :argument
                push!(get!(Vector{Int}, same_arg_bindings, Symbol(binfo.name)), i)
            end
            # Include arguments in location-based merging to unify them with
            # `:local` bindings at the same location. This is needed for:
            # - `@generated` functions: type parameters become actual arguments
            #   that must be unified with their `:static_parameter` counterparts.
            # - Keyword arguments with dependent defaults: JuliaLowering's
            #   `scope_nest` creates `:local` bindings in `let` blocks that
            #   must be unified with the `:argument` binding in the body method.
            lockey = (Symbol(binfo.name), JS.source_location(JL.binding_ex(ctx3, binfo.id))...)
            push!(get!(Vector{Int}, same_location_bindings, lockey), i)
        end
        occurrences[binfo] = Set{BindingOccurrence{Tree3}}()
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

    # Type definitions emit two bindings at the same source token: a
    # `:local (mod=nothing)` alias and a `:global`. The local collects
    # user-written `:use` occurrences from inside the type body (e.g.
    # self-recursive field types like `next::Union{Node, Nothing}`
    # resolve to the local). Merge its bucket into the global so those
    # uses surface under a single `(mod, name, :global)` entry.
    #
    # Discriminator: matching declaration `byte_range`. An unrelated
    # `local Foo` / `let Foo = 1` that happens to share a name with a
    # `:global Foo` has a different decl byte_range and is not merged.
    alias_remaps = Pair{JL.BindingInfo,JL.BindingInfo}[]
    for binfo in keys(occurrences)
        binfo.kind === :local || continue
        isnothing(binfo.mod) || continue
        local_decl_range = JS.byte_range(JL.binding_ex(ctx3, binfo))
        for other in ctx3.bindings.info
            other.kind === :global || continue
            other.name == binfo.name || continue
            JS.byte_range(JL.binding_ex(ctx3, other)) == local_decl_range || continue
            push!(alias_remaps, binfo => other)
            break
        end
    end
    for (local_binfo, global_binfo) in alias_remaps
        local_occs = pop!(occurrences, local_binfo)
        existing = get!(Set{BindingOccurrence{Tree3}}, occurrences, global_binfo)
        union!(existing, local_occs)
    end

    # Fix up usedness information of arguments that are only used within the argument list.
    # to avoid reporting "unused variable diagnostics" for `x` in cases like:
    # ```julia
    # hasmatch(x::RegexMatch, y::Bool=isempty(x.matches)) = y
    # ```
    # Note: argument bindings are included in `same_location_bindings` above to bridge
    # `:argument` and `:local` bindings for keyword arguments with dependent defaults.
    # This is safe because `compute_binding_occurrences!` skips both `:argument` and
    # `:local` bindings in self/kwsorter calls, preventing internal call machinery from
    # being counted as usage.
    for (_, idxs) in same_arg_bindings
        length(idxs) == 1 && continue
        newoccurrences = union!((occurrences[ctx3.bindings.info[idx]] for idx in idxs)...)
        for idx in idxs
            occurrences[ctx3.bindings.info[idx]] = newoccurrences
        end
    end

    return occurrences
end

function collect_inert_identifiers(st3::JS.SyntaxTree)
    result = Dict{String,Vector{JS.SyntaxTree}}()
    foreach_inert_identifier(st3) do id_node::JS.SyntaxTree
        JS.hasattr(id_node, :name_val) || return true
        name_val = id_node.name_val
        name_val isa AbstractString || return true
        push!(get!(Vector{JS.SyntaxTree}, result, name_val), id_node)
        return true
    end
    return result
end

function may_record_occurrence!(occurrences::Dict{JL.BindingInfo,Set{BindingOccurrence{Tree3}}},
        kind::Symbol, st::Tree3, ctx3::JL.VariableAnalysisContext,
    ) where Tree3<:JS.SyntaxTree
    if JS.kind(st) === JS.K"BindingId"
        binfo = JL.get_binding(ctx3, st)
        _may_record_occurrence!(occurrences, kind, st, binfo)
        return true
    end
    return false
end

function _may_record_occurrence!(occurrences::Dict{JL.BindingInfo,Set{BindingOccurrence{Tree3}}},
        kind::Symbol, st::Tree3, binfo::JL.BindingInfo,
    ) where Tree3<:JS.SyntaxTree
    haskey(occurrences, binfo) || return
    push!(occurrences[binfo], BindingOccurrence(st, kind))
    occurrences
end

function compute_binding_occurrences!(
        occurrences::Dict{JL.BindingInfo,Set{BindingOccurrence{Tree3}}},
        ctx3::JL.VariableAnalysisContext, st3::Tree3;
        include_global_bindings::Bool = false,
    ) where Tree3<:JS.SyntaxTree
    stack = JS.SyntaxList(st3)
    while !isempty(stack)
        st = pop!(stack)
        k = JS.kind(st)
        nc = JS.numchildren(st)
        if k === JS.K"BindingId"
            # JL marks synthetic machinery references (e.g. function self-refs
            # inside `K"method"`/`K"function_type"`, type self-refs inside
            # `_typebody!`/`_equiv_typedef` calls) with `:synthetic_ref`. Those
            # are not user-visible uses of the binding.
            if !JL.getmeta(st, :synthetic_ref, false)::Bool
                may_record_occurrence!(occurrences, :use, st, ctx3)
            end
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
        state::ServerState, uri::URI, fi::FileInfo, st0_top::JS.SyntaxTree,
        binfo::JL.BindingInfo;
        kwargs...
    )
    ret = Set{CachedBindingOccurrence}()
    iterate_toplevel_tree(st0_top) do st0::JS.SyntaxTree
        binding_occurrences = @something get_binding_occurrences!(
            state, uri, fi, st0; include_global_bindings = true, kwargs...) return
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

function get_binding_occurrences!(
        state::ServerState, uri::URI, fi::FileInfo, st0::JS.SyntaxTree; kwargs...
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
        result = compute_binding_occurrences_st0(state, uri, fi, st0; kwargs...)
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

function compute_binding_occurrences_st0(
        state::ServerState, uri::URI, fi::FileInfo, st0::JS.SyntaxTree;
        lookup_func = gen_lookup_out_of_scope!(state, uri),
        include_global_bindings::Bool = false
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
    if include_global_bindings
        k0 = JS.kind(st0)
        if k0 in JS.KSet"export public"
            binding_occurrences = Dict{JL.BindingInfo,Set{BindingOccurrence{typeof(st0)}}}()
            collect_export_public_occurrences!(binding_occurrences, st0, mod)
            return binding_occurrences
        elseif k0 in JS.KSet"import using"
            binding_occurrences = Dict{JL.BindingInfo,Set{BindingOccurrence{typeof(st0)}}}()
            collect_import_using_occurrences!(binding_occurrences, st0, mod)
            return binding_occurrences
        end
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
        include_global_bindings)

    if include_global_bindings
        collect_macrocall_occurrences!(binding_occurrences, mod, st0; soft_scope)
        # Global bindings used inside inert nodes (quoted expressions) are not
        # resolved by scope analysis. This applies to `@generated` functions,
        # macro definitions, and any function that constructs quoted expressions.
        # Run independent scope resolution on inert content to collect them.
        collect_inert_global_occurrences!(binding_occurrences, ctx3, st3, mod; soft_scope)
    end

    return binding_occurrences
end

function collect_export_public_occurrences!(
        occurrences::Dict{JL.BindingInfo,Set{BindingOccurrence{Tree3}}},
        st0::Tree3, mod::Module
    ) where Tree3<:JS.SyntaxTree
    JS.kind(st0) in JS.KSet"export public" || return occurrences
    for i = 1:JS.numchildren(st0)
        child = st0[i]
        JS.kind(child) === JS.K"Identifier" || continue
        name = get(child, :name_val, nothing)
        name isa AbstractString || continue
        binfo = JL.BindingInfo(0, name, :global, 0; mod)
        target_set = get!(Set{BindingOccurrence{Tree3}}, occurrences, binfo)
        push!(target_set, BindingOccurrence{Tree3}(child, :use))
    end
    return occurrences
end

function collect_import_using_occurrences!(
        occurrences::Dict{JL.BindingInfo,Set{BindingOccurrence{Tree3}}},
        st0::Tree3, mod::Module
    ) where Tree3<:JS.SyntaxTree
    foreach_local_import_identifier(st0) do id_st::Tree3
        name = get(id_st, :name_val, nothing)
        name isa AbstractString || return
        binfo = JL.BindingInfo(0, name, :global, 0; mod)
        target_set = get!(Set{BindingOccurrence{Tree3}}, occurrences, binfo)
        push!(target_set, BindingOccurrence{Tree3}(id_st, :decl))
        return
    end
    return occurrences
end

function collect_macrocall_occurrences!(
        occurrences::Dict{JL.BindingInfo,Set{BindingOccurrence{Tree3}}},
        mod::Module, st0::JS.SyntaxTree;
        soft_scope::Bool = false
    ) where Tree3<:JS.SyntaxTree
    traverse(st0) do st::JS.SyntaxTree
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
                target_set = get!(Set{BindingOccurrence{Tree3}}, occurrences, binfo)
                push!(target_set, BindingOccurrence{Tree3}(JL.binding_ex(ctx3, binfo), :use))
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
        occurrences::Dict{JL.BindingInfo,Set{BindingOccurrence{Tree3}}},
        ctx3::JL.VariableAnalysisContext, st3::JS.SyntaxTree, mod::Module;
        soft_scope::Bool = false
    ) where Tree3<:JS.SyntaxTree
    arg_names = Set{String}()
    for binfo in ctx3.bindings.info
        if binfo.kind === :argument && !binfo.is_internal
            push!(arg_names, binfo.name)
        end
    end
    st3_range = JS.byte_range(st3)
    traverse(st3) do st3′::JS.SyntaxTree
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
                occ_set = get!(Set{BindingOccurrence{Tree3}}, occurrences, binfo)
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
