using .JS

const DEFINITION_REGISTRATION_ID = "textDocument-definition"
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


# TODO: memorize this?
is_definition_links_supported(server::Server) =
        getobjpath(server.state.init_params.capabilities,
        :textDocument, :definition, :linkSupport) === true


"""
Determines the "best" node at a given offset in a file.
No suitable node is found at the offset, it returns `nothing`.

TODO: some heuristic approach like in rust-analyzer?
ref: https://github.com/rust-lang/rust-analyzer/blob/6acff6c1f8306a0a1d29be8fd1ffa63cff1ad598/crates/ide/src/goto_definition.rs#L47-L62
"""
function get_best_node(fi::FileInfo, offset::Int)
    st = JS.build_tree(JL.SyntaxTree, fi.parsed_stream)
    bas = byte_ancestors(st, offset)

    (kind(first(bas)) !== K"Identifier") && return nothing

    for i in 2:length(bas)
        if kind(bas[i]) !== K"."
            return bas[i - 1]
        end
    end

    # Unreachable: we always have toplevel node
    return nothing
end

"""
Get the range of a method. (will be deprecated in the future)

TODO (later): get the correct range of the method definition.
For now, it just returns the first line of the method
"""
function method_definition_range(m::Method)
    file, line = functionloc(m)
    return Location(;
        uri = filename2uri(file),
        range = Range(;
            start = Position(; line = line - 1, character = 0),
            var"end" = Position(; line = line - 1, character = Int(typemax(Int32)))))
end

function definition_locations(mod::Module, fi::FileInfo, uri::URI, offset::Int, state::ServerState)
    node = get_best_node(fi, offset)
    node === nothing && return nothing
    obj = resolve_property(mod, node)

    # TODO (later): support other objects
    if isa(obj, Function)
        return method_definition_range.(methods(obj))
    else
        return nothing
    end
end

function handle_DefinitionRequest(server::Server, msg::DefinitionRequest)
    state = server.state
    origin_position = msg.params.position
    uri = URI(msg.params.textDocument.uri)
    fi = get_fileinfo(state, uri)
    offset = xy_to_offset(fi, origin_position)
    mod = find_file_module(state, uri, origin_position)

    locations = definition_locations(mod, fi, uri, offset, state)

    if locations === nothing
        send(server, DefinitionResponse(; id = msg.id, result = null))
        return
    end

    if is_definition_links_supported(server)
        return send(server,
            DefinitionResponse(;
                id = msg.id,
                result = map(
                    loc -> LocationLink(;
                        targetUri = loc.uri,
                        targetRange = loc.range,
                        targetSelectionRange = loc.range,
                        originSelectionRange = Range(;
                            start = origin_position,
                            var"end" = origin_position
                        )
                    ), locations)))
    else
        send(server, DefinitionResponse(; id = msg.id, result = locations))
    end
end