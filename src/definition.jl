const DEFINITION_REGISTRATION_ID = "jetls-definition"
const DEFINITION_REGISTRATION_METHOD = "textDocument/definition"

function definition_options()
    return DefinitionOptions()
end

function definition_registration()
    return Registration(;
        id = DEFINITION_REGISTRATION_ID,
        method = DEFINITION_REGISTRATION_METHOD,
        registerOptions = DefinitionRegistrationOptions(;
            documentSelector = DEFAULT_DOCUMENT_SELECTOR,
        )
    )
end

# For dynamic registrations during development
# unregister(currently_running, Unregistration(;
#     id = DEFINITION_REGISTRATION_ID,
#     method = DEFINITION_REGISTRATION_METHOD))
# register(currently_running, definition_registration())

function is_location_unknown(m::Method)
    _, line = Base.updated_methodloc(m)
    line ≤ 0 && return true
    file, _ = functionloc(m)
    if isnothing(file)
        isunsavedfile(String(m.file)) && return false
        return true
    end
    return false
end
function is_location_unknown(mod::Module)
    (; file, line) = Base.moduleloc(mod)
    return line ≤ 0 || file === Symbol("")
end

function locations_from_methods(state::ServerState, uri::URI, methods::Vector{Method})
    return Location[unadjust_location(state, uri, Location(m)) for m in methods]
end

# Get the range of a method via reflection.
# For now, it just returns the first line of the method
function LSP.Location(m::Method)
    file, line = functionloc(m)
    if file === nothing
        file = String(m.file) # method defined in unsaved buffer
    else
        file = file::String
        file = to_full_path(file)
    end
    return Location(;
        uri = filename2uri(file),
        range = Range(;
            start = Position(; line = line - 1, character = 0),
            var"end" = Position(; line = line - 1, character = Int(typemax(Int32)))))
end

function LSP.Location(mod::Module)
    (; file, line) = Base.moduleloc(mod)
    uri = filename2uri(to_full_path(file))
    return Location(;
        uri,
        range = Range(;
            start = Position(; line = line - 1, character = 0),
            var"end" = Position(; line = line - 1, character = Int(typemax(Int32)))))
end

LSP.LocationLink(loc::Location, origin_selection_range::Range) =
    LocationLink(;
        targetUri = loc.uri,
        targetRange = loc.range,
        targetSelectionRange = loc.range,
        originSelectionRange = origin_selection_range)

function handle_DefinitionRequest(
        server::Server, msg::DefinitionRequest, cancel_flag::CancelFlag
    )
    state = server.state
    uri = msg.params.textDocument.uri
    origin_position = adjust_position(state, uri, msg.params.position)

    result = get_file_info(state, uri, cancel_flag)
    if isnothing(result)
        return send(server, DefinitionResponse(; id = msg.id, result = null))
    elseif result isa ResponseError
        return send(server, DefinitionResponse(; id = msg.id, result = nothing, error = result))
    end
    fi = result

    locations, origin_node = @something find_definition(server, uri, fi, origin_position) begin
        return send(server, DefinitionResponse(; id = msg.id, result = null))
    end
    if supports(server, :textDocument, :definition, :linkSupport)
        origin_selection_range, _ =
            unadjust_range(state, uri, jsobj_to_range(origin_node, fi))
        result = LocationLink[LocationLink(loc, origin_selection_range) for loc in locations]
    else
        result = locations
    end
    return send(server, DefinitionResponse(; id = msg.id, result))
end

"""
    find_definition(server, uri, fi, pos; soft_scope) ->
        Union{Tuple{Vector{Location}, SyntaxTreeC}, Nothing}

Core routine behind `textDocument/definition`. On success returns
`(locations, origin_node)` where `origin_node` is the syntax-tree node that
represents the cursor's origin (used by callers to compute
`LocationLink.originSelectionRange`).
Returns `nothing` when no definition could be produced at `pos`.

Lookup order:
1. Call-site matches via the [`TypeAnnotation`](@ref) pipeline: when the cursor is on
   (or right after) a call site, jump to just the methods CC's dispatch picked for the
   inferred argtypes (`func│(1.0)` and `func(1.0)│` → `func(::Float64)` only). Runs
   before the binding pass so same-module call sites still narrow — otherwise the
   binding pass would short-circuit to all of `func`'s workspace `:def`s.
2. `select_target_binding` → source-level `:def` occurrences (globals via workspace-wide
   search, locals via the local lowering context). Handles non-call cursor positions
   (`x│` on a local, the `func` declaration site itself, …) and call sites where
   inference couldn't supply matches.
3. Value-based fallback via [`get_type_for_range`](@ref) (with [`resolve_global_const`](@ref)
   as a static fallback when lowering fails or the surface identifier doesn't survive
   macroexpansion): for modules, jump to `Base.moduleloc`; for other values, jump to each
   method's `functionloc`. Call-like surface forms whose value path doesn't yield a jump
   (`K"ref"` → `getindex`, `K"tuple"` → `Core.tuple`, `K"vect"` → `Base.vect`,
   `K"vcat"` / `K"hcat"` / comprehensions and their typed variants → `Base.{vcat,hcat,collect}`)
   additionally fall back to the matched dispatch.
"""
function find_definition(
        server::Server, uri::URI, fi::FileInfo, pos::Position;
        soft_scope::Bool = is_notebook_cell_uri(server.state, uri),
        context_module::Union{Nothing,Module} = nothing
    )
    state = server.state
    st0 = build_syntax_tree(fi)
    offset = xy_to_offset(fi, pos)
    (; world) = ctx_info = get_context_info(state, uri, pos)
    # `context_module` kwarg overrides the analysis-derived module — exposed
    # for tests so they can seed the lookup with a pre-populated module
    # without running full-analysis on the test source.
    context_module = something(context_module, ctx_info.context_module)

    # `node` / `ctx` feed both the matches-narrowing and the value-based
    # fallback below. Building the inferred context once is also cheaper than
    # rebuilding it per phase.
    node = select_target_for_type_query(st0, offset)
    if node === nothing
        rng = ctx = nothing
    else
        rng = JS.byte_range(node)
        ctx = build_inferred_context_for_range(st0, context_module, rng;
            world, caller="find_definition", cache=fi.inferred_context_cache)
    end

    # Phase 1: matches-narrowing. Runs *before* the binding pass so
    # same-module `func(1.0)│` narrows to `func(::Float64)` rather than
    # short-circuiting to all of `func`'s workspace `:def`s.
    if node !== nothing && ctx !== nothing
        call_locations = find_call_dispatch_definitions(state, uri, st0, node, ctx)
        call_locations === nothing || return call_locations, node
    end

    # Phase 2: source-level binding pass.
    binding_jump = find_binding_definitions(server, uri, fi, st0, offset, context_module, soft_scope)
    binding_jump === nothing || return binding_jump

    node === nothing && return nothing
    rng === nothing && return nothing

    # Phase 3: value-based fallback (Module → `moduleloc`, callable → all method `functionloc`s).
    # For K"call" surfaces this is reached only when Phase 1's matches narrowing didn't
    # return a result; falling through is consistent with `some(sin).value│`
    # (also a non-K"call" surface that resolves to `Const(sin)` → `methods(sin)`),
    # just applied to the call's result type.
    value_locations = find_value_definitions(state, uri, context_module, node, rng, ctx, world)
    value_locations === nothing || return value_locations, node

    # Phase 4: operator-dispatch fallback for non-K"call" surface forms
    # in `_OPERATOR_CALL_KINDS` (`K"ref"`, `K"tuple"`, `K"vect"`, `K"vcat"`,
    # `K"hcat"`, `K"comprehension"`, and their typed variants).
    if ctx !== nothing
        op_locations = find_operator_dispatch_definitions(state, uri, node, rng, ctx)
        op_locations === nothing || return op_locations, node
    end

    return nothing
end

# Phase 1: jump to the methods CC's dispatch picked at a call site —
# `func│(1.0)` → `func(::Float64)` only. Returns `nothing` when the user's call
# is unresolvable (e.g. typo, or rename without re-running full-analysis), so
# Phase 2's binding pass takes over.
function find_call_dispatch_definitions(
        state::ServerState, uri::URI, st0::SyntaxTreeC,
        node::SyntaxTreeC, ctx::InferredTreeContext,
    )
    call_node = @something enclosing_call_for_matches(st0, node) return nothing
    matches = @something get_matches_for_range(ctx, JS.byte_range(call_node)) return nothing
    target_methods = filter(!is_location_unknown,
        unique(Base.updated_methodloc, Method[m.method for m in matches]))
    isempty(target_methods) && return nothing
    return locations_from_methods(state, uri, target_methods)
end

# Source-level binding-occurrence pass: if `select_target_binding` finds a
# binding at the cursor, jump to its `:def` occurrences (workspace-wide for
# globals, the local lowering context for everything else). Returns the
# `(locations, binding_node)` pair that `find_definition` propagates, or
# `nothing` when no binding was selected or no `:def` was reachable from
# the binding info.
function find_binding_definitions(
        server::Server, uri::URI, fi::FileInfo, st0::SyntaxTreeC,
        offset::Int, context_module::Module, soft_scope::Bool,
    )
    binding_result = @something select_target_binding(
        st0, offset, context_module; caller="find_definition", soft_scope) return nothing
    (; ctx3, st3, binding) = binding_result
    binfo = JL.get_binding(ctx3, binding)
    if binfo.kind === :global
        global_definitions = find_global_binding_definitions(server, uri, binfo)
        isempty(global_definitions) && return nothing
        return global_definitions, binding
    end
    definitions = lookup_binding_definitions(st3, binfo)
    isempty(definitions) && return nothing
    state = server.state
    locations = Location[]
    for definition in definitions
        range, def_uri = unadjust_range(state, uri, jsobj_to_range(definition, fi))
        push!(locations, Location(; uri = def_uri, range))
    end
    return locations, binding
end

function find_global_binding_definitions(
        server::Server, uri::URI, binfo::JL.BindingInfo
    )
    locations = Location[]
    state = server.state
    uris_to_search = collect_search_uris(server, uri)
    seen_locations = Set{Tuple{URI,Range}}()
    for search_uri in uris_to_search
        fi = @something begin
            get_file_info(state, search_uri)
        end begin
            get_unsynced_file_info!(state, search_uri)
        end continue
        search_st0_top = build_syntax_tree(fi)
        for occurrence in find_global_binding_occurrences!(state, search_uri, fi, search_st0_top, binfo)
            if occurrence.kind === :def
                range, adjusted_uri = unadjust_range(state, search_uri, jsobj_to_range(occurrence.tree, fi))
                push!(seen_locations, (adjusted_uri, range))
            end
        end
    end
    for (loc_uri, range) in seen_locations
        push!(locations, Location(; uri = loc_uri, range))
    end
    return locations
end

# Phase 3: resolve `node` to a `Core.Const` and surface its definition.
# - Module value → `Base.moduleloc`. Returns `nothing` when the location is unknown.
# - Other value → all methods' `functionloc`s. Returns `nothing` when no
#   resolvable methods remain, letting Phase 4 try the operator dispatch
#   for call-like surfaces.
function find_value_definitions(
        state::ServerState, uri::URI, context_module::Module,
        node::SyntaxTreeC, rng::UnitRange{Int},
        ctx::Union{Nothing,InferredTreeContext}, world::UInt,
    )
    if ctx === nothing
        objtyp = resolve_global_const(context_module, node, world)
    else
        objtyp = get_type_for_range(ctx, rng)
    end
    objtyp isa Core.Const || return nothing
    objval = objtyp.val
    if objval isa Module
        is_location_unknown(objval) && return nothing
        return Location[unadjust_location(state, uri, Location(objval))]
    end
    target_methods = filter(!is_location_unknown,
        unique(Base.updated_methodloc, methods_at_world(world, objval)))
    isempty(target_methods) && return nothing
    return locations_from_methods(state, uri, target_methods)
end

# Phase 4: when a call-like surface form (`xs[i]│` → `getindex`, `(a, b)│`
# → `Core.tuple`, `[a, b]│` → `Base.vect`, `[a for x in xs]│` →
# `Base.collect`, `[a; b]│` → `Base.vcat`, …) didn't surface a Const value
# at Phase 3, jump to the matched operator dispatch instead.
function find_operator_dispatch_definitions(
        state::ServerState, uri::URI,
        node::SyntaxTreeC, rng::UnitRange{Int},
        ctx::InferredTreeContext,
    )
    JS.kind(node) in _OPERATOR_CALL_KINDS || return nothing
    matches = @something get_matches_for_range(ctx, rng) return nothing
    target_methods = filter(!is_location_unknown,
        unique(Base.updated_methodloc, Method[m.method for m in matches]))
    isempty(target_methods) && return nothing
    return locations_from_methods(state, uri, target_methods)
end
