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

is_location_unknown(m::Method) = Base.updated_methodloc(m)[2] ≤ 0
function is_location_unknown(mod::Module)
    (; file, line) = Base.moduleloc(mod)
    return line ≤ 0 || file === Symbol("")
end

"""
Get the range of a method. (will be deprecated in the future)

TODO (later): get the correct range of the method definition.
For now, it just returns the first line of the method
"""
function get_location(m::Method)
    file, line = functionloc(m)
    file = to_full_path(file)
    return Location(;
        uri = filename2uri(file),
        range = Range(;
            start = Position(; line = line - 1, character = 0),
            var"end" = Position(; line = line - 1, character = Int(typemax(Int32)))))
end

function get_location(mod::Module)
    (; file, line) = Base.moduleloc(mod)
    uri = filename2uri(to_full_path(file))
    return Location(;
        uri,
        range = Range(;
            start = Position(; line = line - 1, character = 0),
            var"end" = Position(; line = line - 1, character = Int(typemax(Int32)))))
end

get_location(bind::Tuple{JL.SyntaxTree, URI}) = Location(; uri = bind[2], range = get_source_range(bind[1]))

function definition_target_localbindings(offset, st, node, uri)
    # We can skip lookups including access of outer modules
    # because we only look for local bindings
    kind(node) !== K"Identifier" && return nothing
    cbs = cursor_bindings(st, offset)
    (cbs === nothing || isempty(cbs)) && return nothing
    matched_binding = findfirst(b -> b[1].name == node.name_val, cbs)
    matched_binding === nothing && return nothing

    # Will return multiple results when we support tracking of multiple assignments.
    # `SyntaxTree` does not retain URI information because `ParseStream` does not store it
    # so we explicitly keep it.
    return [(cbs[matched_binding][2], uri)]
end

function create_definition(objects, origin_range::Range, locationlink_support::Bool)
    if locationlink_support
        return map(objects) do obj
            loc = @inline get_location(obj)
            LocationLink(;
                targetUri = loc.uri,
                targetRange = loc.range,
                targetSelectionRange = loc.range,
                originSelectionRange = origin_range)
        end
    else
        get_location.(objects)
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

    st = JS.build_tree(JL.SyntaxTree, fi.parsed_stream)
    offset = xy_to_offset(fi, origin_position)
    node = select_target_node(st, offset)
    if node === nothing
        return send(server, DefinitionResponse(; id = msg.id, result = null))
    end

    locationlink_support = supports(server, :textDocument, :definition, :linkSupport)
    originSelectionRange = get_source_range(node)

    lbs = definition_target_localbindings(offset, st, node, uri)
    if !isnothing(lbs)
        return send(server,
            DefinitionResponse(;
                id = msg.id,
                result = create_definition(lbs,
                originSelectionRange,
                locationlink_support)))
    end

    (; mod, analyzer) = get_context_info(server.state, uri, origin_position)
    objtyp = resolve_type(analyzer, mod, node)

    objtyp === nothing && return send(server, DefinitionResponse(; id = msg.id, result = null))
    objtyp isa Core.Const || return send(server, DefinitionResponse(; id = msg.id, result = null))

    if objtyp.val isa Module
        if is_location_unknown(objtyp.val)
            return send(server, DefinitionResponse(; id = msg.id, result = null))
        else
            return send(server,
                DefinitionResponse(;
                    id = msg.id,
                    result = create_definition([objtyp.val],
                    originSelectionRange,
                    locationlink_support)))
        end
    else
        target_methods = filter(!is_location_unknown, unique(Base.updated_methodloc, methods(objtyp.val)))
        if isempty(target_methods)
            return send(server, DefinitionResponse(; id = msg.id, result = null))
        else
            return send(server,
                DefinitionResponse(;
                    id = msg.id,
                    result = create_definition(target_methods,
                    originSelectionRange,
                    locationlink_support)))
        end
    end
end
