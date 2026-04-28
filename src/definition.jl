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

"""
Get the range of a method. (will be deprecated in the future)

TODO (later): get the correct range of the method definition.
For now, it just returns the first line of the method
"""
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

    locations, origin_node = find_definition(server, uri, fi, origin_position)
    if origin_node === nothing || isempty(locations)
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
        (locations::Vector{Location}, origin_node::Union{JS.SyntaxTree,Nothing})

Core routine behind `textDocument/definition`. Returns the definition locations for
the symbol at `pos` together with the syntax-tree node that represents the cursor's
origin (used by callers to compute `LocationLink.originSelectionRange`).
An empty `locations` paired with a non-`nothing` `origin_node` means
"a binding/identifier was found, but no definition location could be produced" — callers
can treat this the same as "no result".
`isnothing(origin_node)` means we could not even identify a binding or identifier at `pos`.

Lookup order:
1. `select_target_binding` → source-level `:def` occurrences
   (globals via workspace-wide search, locals via the local lowering context).
2. Reflection fallback via `select_target_identifier` and `resolve_type`:
   for modules, jump to `Base.moduleloc`; for other values, jump to each method's `functionloc`.
"""
function find_definition(
        server::Server, uri::URI, fi::FileInfo, pos::Position;
        soft_scope::Bool = is_notebook_cell_uri(server.state, uri),
    )
    state = server.state
    st0 = build_syntax_tree(fi)
    offset = xy_to_offset(fi, pos)
    (; mod, analyzer) = get_context_info(state, uri, pos)

    binding_result = select_target_binding(st0, offset, mod; caller="find_definition", soft_scope)
    if !isnothing(binding_result)
        (; ctx3, st3, binding) = binding_result
        binfo = JL.get_binding(ctx3, binding)
        if binfo.kind === :global
            global_definitions = find_global_binding_definitions(server, uri, binfo)
            isempty(global_definitions) || return global_definitions, binding
        else
            definitions = lookup_binding_definitions(st3, binfo)
            if !isempty(definitions)
                locations = Location[]
                for definition in definitions
                    range, def_uri = unadjust_range(state, uri, jsobj_to_range(definition, fi))
                    push!(locations, Location(; uri = def_uri, range))
                end
                return locations, binding
            end
        end
    end

    node = @something select_target_identifier(st0, offset) return Location[], nothing
    objtyp = resolve_type(analyzer, mod, node)
    objtyp isa Core.Const || return Location[], node
    objval = objtyp.val
    if objval isa Module
        is_location_unknown(objval) && return Location[], node
        return [unadjust_location(state, uri, Location(objval))], node
    else
        target_methods = filter(!is_location_unknown, unique(Base.updated_methodloc, methods(objval)))
        isempty(target_methods) && return Location[], node
        locations = unadjust_location.(Ref(state), Ref(uri), Location.(target_methods))
        return locations, node
    end
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
