const TYPE_DEFINITION_REGISTRATION_ID = "jetls-type-definition"
const TYPE_DEFINITION_REGISTRATION_METHOD = "textDocument/typeDefinition"

function type_definition_options()
    return TypeDefinitionOptions()
end

function type_definition_registration()
    return Registration(;
        id = TYPE_DEFINITION_REGISTRATION_ID,
        method = TYPE_DEFINITION_REGISTRATION_METHOD,
        registerOptions = TypeDefinitionRegistrationOptions(;
            documentSelector = DEFAULT_DOCUMENT_SELECTOR,
        )
    )
end

# For dynamic registrations during development
# unregister(currently_running, Unregistration(;
#     id = TYPE_DEFINITION_REGISTRATION_ID,
#     method = TYPE_DEFINITION_REGISTRATION_METHOD))
# register(currently_running, type_definition_registration())

function handle_TypeDefinitionRequest(
        server::Server, msg::TypeDefinitionRequest, cancel_flag::CancelFlag
    )
    state = server.state
    uri = msg.params.textDocument.uri
    origin_position = adjust_position(state, uri, msg.params.position)

    result = get_file_info(state, uri, cancel_flag)
    if isnothing(result)
        return send(server, TypeDefinitionResponse(; id = msg.id, result = null))
    elseif result isa ResponseError
        return send(server, TypeDefinitionResponse(; id = msg.id, result = nothing, error = result))
    end
    fi = result

    locations, origin_node = @something(
        find_type_definition(server, uri, fi, origin_position),
        return send(server, TypeDefinitionResponse(; id = msg.id, result = null)))
    if supports(server, :textDocument, :typeDefinition, :linkSupport)
        origin_selection_range, _ =
            unadjust_range(state, uri, jsobj_to_range(origin_node, fi))
        result = LocationLink[LocationLink(loc, origin_selection_range) for loc in locations]
    else
        result = locations
    end
    return send(server, TypeDefinitionResponse(; id = msg.id, result))
end

"""
    find_type_definition(server, uri, fi, pos) ->
        (locations::Vector{Location}, origin_node::SyntaxTreeC) or nothing

Core routine behind `textDocument/typeDefinition`. Returns the locations of the
type definition for the expression at `pos` together with the origin node used
by callers to compute `LocationLink.originSelectionRange`.

The inferred type of the expression at `pos` is obtained from the [`TypeAnnotation`](@ref)
pipeline. The resulting lattice element is converted to a concrete `Type`, then mapped to
constructor method locations — the same reflection fallback `find_definition` uses for the
value-side jump.
"""
function find_type_definition(server::Server, uri::URI, fi::FileInfo, pos::Position)
    state = server.state
    st0_top = build_syntax_tree(fi)
    offset = xy_to_offset(fi, pos)
    node = @something select_target_for_type_query(st0_top, offset) return nothing

    rng = JS.byte_range(node)
    (; mod) = get_context_info(state, uri, pos)
    typ = @something infer_type_at_range(st0_top, mod, rng) return nothing

    target_type = @something extract_target_type(typ) return nothing
    return type_locations(state, uri, target_type), node
end

# Run inference on the toplevel subtree that contains `rng` and look up its
# inferred type. Returns `nothing` if lowering/inference fails or no `:type`
# annotation exists at `rng`.
function infer_type_at_range(st0_top::SyntaxTreeC, mod::Module, rng::UnitRange{<:Integer})
    return iterate_toplevel_tree(st0_top) do st0::SyntaxTreeC
        rng ⊆ JS.byte_range(st0) || return nothing
        result = @something(
            get_inferrable_tree(st0, mod; caller="find_type_definition"),
            return traversal_terminator)
        (; ctx3, st3) = result
        inferred = @something infer_toplevel_tree(ctx3, st3, mod) return traversal_terminator
        ctx = InferredTreeContext(inferred, st3)
        return TraversalReturn(get_type_for_range(ctx, rng); terminate=true)
    end
end

# Convert a lattice element to a concrete `Type` whose definition the user wants
# to navigate to. For `Core.Const(v)`, prefer `v` itself when it's already a
# `Type` (so clicking on a type name jumps to that type), otherwise return
# `Core.Typeof(v)` (so clicking on a value jumps to the value's type).
function extract_target_type(@nospecialize typ)
    widened = CC.widenconst(typ)
    if CC.isType(widened)
        return widened.parameters[1]
    elseif widened === Union{}
        return nothing
    else
        return widened
    end
end

function type_locations(state::ServerState, origin_uri::URI, @nospecialize(T))
    if T isa Union
        locations = Location[]
        for sub in Base.uniontypes(T)
            append!(locations, type_locations(state, origin_uri, sub))
        end
        return locations
    end

    # Primary: look up the type's `struct` / `abstract type` / `primitive type`
    # declaration via the document symbol cache. This lands directly on the
    # declaration site rather than on a constructor's first line.
    locations = type_locations_from_document_symbols(state, origin_uri, T)
    isempty(locations) || return locations

    return type_locations_from_reflection(state, origin_uri, T)
end

# Search the document symbol cache for a type-declaration symbol whose name
# matches `T` and whose enclosing module is `parentmodule(T)`. Each analyzed
# file is checked: `module_range_infos` tells us which line ranges of the file
# map to which module, so a name-only collision in another module is filtered
# via `get_context_module`.
function type_locations_from_document_symbols(
        state::ServerState, origin_uri::URI, @nospecialize(T)
    )
    Tu = Base.unwrap_unionall(T)
    Tu isa DataType || return Location[]
    target_module = parentmodule(Tu)
    target_name = String(Tu.name.name)

    locations = Location[]
    for (uri, info) in load(state.analysis_manager.cache)
        info isa AnalysisResult || continue
        afi = @something analyzed_file_info(info, uri) continue
        any(p -> last(p) === target_module, afi.module_range_infos) || continue

        fi = @something begin
            get_file_info(state, uri)
        end begin
            get_unsynced_file_info!(state, uri)
        end continue
        symbols = get_document_symbols!(state, uri, fi)
        collect_type_symbol_locations!(
            locations, symbols, info, uri, target_module, target_name,
            state, origin_uri)
    end
    return locations
end

function collect_type_symbol_locations!(
        locations::Vector{Location}, symbols::Vector{DocumentSymbol}, info::AnalysisResult,
        uri::URI, target_module::Module, target_name::AbstractString, state::ServerState,
        origin_uri::URI
    )
    for sym in symbols
        if is_type_definition_symbol_kind(sym.kind) && sym.name == target_name &&
                get_context_module(info, uri, sym.range.start) === target_module
            push!(locations, unadjust_location(state, origin_uri,
                Location(; uri, range = sym.selectionRange)))
        end
        children = @something sym.children continue
        collect_type_symbol_locations!(
            locations, children, info, uri, target_module, target_name,
            state, origin_uri)
    end
    return locations
end

is_type_definition_symbol_kind(kind::SymbolKind.Ty) =
    kind === SymbolKind.Struct || kind === SymbolKind.Interface || kind === SymbolKind.Number

# Fallback when the document symbol cache lookup yields nothing — e.g. types
# defined outside the workspace (`Base`/`Core`/installed packages). Locates
# `T`'s constructor methods via reflection, falling back to the unwrapped
# wrapper for parametric types like `Vector{Int}`.
function type_locations_from_reflection(
        state::ServerState, origin_uri::URI, @nospecialize(T)
    )
    candidates = try; methods(T); catch; Method[]; end
    # Parametric types like `Vector{Int}` usually have no constructor methods
    # of their own; fall back to the unwrapped wrapper (`Vector`) to recover
    # the `struct` definition site.
    if isempty(candidates)
        Tu = Base.unwrap_unionall(T)
        if Tu isa DataType
            candidates = try; methods(Tu.name.wrapper); catch; Method[]; end
        end
    end

    return Location[unadjust_location(state, origin_uri, Location(m))
        for m in filter(!is_location_unknown, unique(Base.updated_methodloc, candidates))]
end
