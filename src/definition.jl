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
# register(currently_running, definition_resistration())

is_location_unknown(m) = Base.updated_methodloc(m)[2] <= 0

"""
Get the range of a method. (will be deprecated in the future)

TODO (later): get the correct range of the method definition.
For now, it just returns the first line of the method
"""
function method_definition_range(m::Method)
    file, line = functionloc(m)
    file = to_full_path(file)
    return Location(;
        uri = filename2uri(file),
        range = Range(;
            start = Position(; line = line - 1, character = 0),
            var"end" = Position(; line = line - 1, character = Int(typemax(Int32)))))
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

    (; mod, analyzer) = get_context_info(server.state, uri, origin_position)
    objtyp = resolve_type(analyzer, mod, node)
    if !(objtyp isa Core.Const)
        return send(server, DefinitionResponse(; id = msg.id, result = null))
    end

    # TODO modify this aggregation logic when we start to use more precise location informaiton
    ms = filter(!is_location_unknown, unique(Base.updated_methodloc, methods(objtyp.val)))

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
end
