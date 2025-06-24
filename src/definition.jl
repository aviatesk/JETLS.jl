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
#     id=DEFINITION_REGISTRATION_ID,
#     method=DEFINITION_REGISTRATION_METHOD))
# register(currently_running, definition_registration())

const empty_methods = Method[]
const empty_bindings = JL.BindingInfo[]
is_location_unknown(m) = Base.updated_methodloc(m)[2] <= 0

"""
Get the range of a method. (will be deprecated in the future)

TODO (later): get the correct range of the method definition.
For now, it just returns the first line of the method
"""
function get_method_location(m::Method)
    file, line = functionloc(m)
    file = to_full_path(file)
    return Location(;
        uri = filename2uri(file),
        range = Range(;
            start = Position(; line = line - 1, character = 0),
            var"end" = Position(; line = line - 1, character = Int(typemax(Int32)))))
end

function module_definition_location(mod::Module)
    (; file, line) = Base.moduleloc(mod)
    line ≤ 0 && return nothing
    file === Symbol("") && return nothing
    uri = filename2uri(to_full_path(file))
    return Location(;
        uri,
        range = Range(;
            start = Position(; line = line - 1, character = 0),
            var"end" = Position(; line = line - 1, character = Int(typemax(Int32)))))

function definition_target_methods(state::ServerState, uri::URI, pos::Position, offset, node)
    (; mod, analyzer) = get_context_info(state, uri, pos)
    objtyp = resolve_type(analyzer, mod, node)
    objtyp isa Core.Const || return empty_methods

    # TODO modify this aggregation logic when we start to use more precise location information
    return filter(!is_location_unknown, unique(Base.updated_methodloc, methods(objtyp.val)))
end

function get_binding_location(b::JL.SyntaxTree, uri::URI)
    return Location(; uri = uri, range = get_source_range(b))
end

function definition_target_localbindings(offset, st, node)
    # We can skip lookups including access of outer modules
    # because we only look for local bindings
    kind(node) !== K"Identifier" && return empty_bindings

    cbs = cursor_bindings(st, offset)
    (cbs === nothing || isempty(cbs)) && return empty_bindings

    # TODO: track all assignments to the same name in the current scope
    matched_bindings = findall(b -> b[1].name == node.name_val, cbs)
    isempty(matched_bindings) && return empty_bindings

    @assert length(matched_bindings) <= 1 "Multiple bindings found for the same name"
    return [cbs[first(matched_bindings)][2]]
end

function create_definition(@nospecialize(objects), obj_to_targetloc, origin_range::Range, locationlink_support::Bool)
    if locationlink_support
        return map(objects) do obj
            loc = @inline obj_to_targetloc(obj)
            LocationLink(;
                targetUri = loc.uri,
                targetRange = loc.range,
                targetSelectionRange = loc.range,
                originSelectionRange = origin_range)
        end
    else
        return obj_to_targetloc.(objects)
    end
end

function handle_DefinitionRequest(server::Server, msg::DefinitionRequest)
    origin_position = msg.params.position
    uri = msg.params.textDocument.uri

    fi = get_fileinfo(server.state, uri)
    if fi === nothing
        return send(server,
            DefinitionResponse(;
                id = msg.id,
                result = nothing,
                error = file_cache_error(uri)))
    end

    offset = xy_to_offset(fi, origin_position)
    st = JS.build_tree(JL.SyntaxTree, fi.parsed_stream)
    node = select_target_node(st, offset)
    if node === nothing
        return send(server, DefinitionResponse(; id = msg.id, result = null))
    end
    originSelectionRange = get_source_range(node)

    ms = definition_target_methods(server.state, uri, origin_position, offset, node)
    lbs = definition_target_localbindings(offset, st, node)

    location_link_support = supports(server, :textDocument, :definition, :linkSupport)

    if isempty(ms) && isempty(lbs)
        return send(server, DefinitionResponse(; id = msg.id, result = null))
    end


    obj = objtyp.val
    if obj isa Module
        modloc = module_definition_location(obj)
        if modloc === nothing
            return send(server, DefinitionResponse(; id = msg.id, result = null))
        elseif supports(server, :textDocument, :definition, :linkSupport)
            originSelectionRange = get_source_range(node)
            result = LocationLink[LocationLink(;
                targetUri = modloc.uri,
                targetRange = modloc.range,
                targetSelectionRange = modloc.range,
                originSelectionRange)]
            return send(server, DefinitionResponse(; id = msg.id, result))
        else
            return send(server, DefinitionResponse(; id = msg.id, result = modloc))
        end
    end

    # TODO modify this aggregation logic when we start to use more precise location informaiton
    ms = filter(!is_location_unknown, unique(Base.updated_methodloc, methods(obj)))

    if isempty(ms)
        send(server, DefinitionResponse(; id = msg.id, result = null))
    elseif supports(server, :textDocument, :definition, :linkSupport)
        originSelectionRange = get_source_range(node)
        send(server,
            DefinitionResponse(;
                id = msg.id,
                result = map(ms) do m
                    loc = @inline method_definition_range(m)
                    LocationLink(;
                        targetUri = loc.uri,
                        targetRange = loc.range,
                        targetSelectionRange = loc.range,
                        originSelectionRange)
                end))
    else
        send(server, DefinitionResponse(; id = msg.id, result = method_definition_range.(ms)))
    end

    send(
        server,
        DefinitionResponse(;
            id = msg.id,
            result = vcat(
                create_definition(ms,
                    get_method_location,
                    originSelectionRange,
                    location_link_support),
                create_definition(lbs,
                    Base.Fix2(get_binding_location, uri),
                    originSelectionRange,
                    location_link_support),
            )),
    )
end
