using .JS

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

# TODO: memorize this?
is_definition_links_supported(server::Server) =
    getobjpath(server.state.init_params.capabilities,
        :textDocument, :definition, :linkSupport) === true

"""
Determines the node that the user most likely intends to navigate to.
Returns `nothing` if no suitable one is found.

Currently, it simply checks the ancestors of the node located at the given offset.

TODO: Apply a heuristic similar to rust-analyzer
refs: https://github.com/rust-lang/rust-analyzer/blob/6acff6c1f8306a0a1d29be8fd1ffa63cff1ad598/crates/ide/src/goto_definition.rs#L47-L62
      https://github.com/aviatesk/JETLS.jl/pull/61#discussion_r2134707773
"""
function select_target_node(st::JL.SyntaxTree, offset::Int)
    bas = byte_ancestors(st, offset)

    (kind(first(bas)) !== K"Identifier") && return nothing

    for i in 2:length(bas)
        if kind(bas[i]) === K"."
            # doesn't follow child module chain
            if bas[i][1] === bas[i - 1]
                return bas[i - 1]
            end
        else
            # finish of module chain
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

const empty_methods = Method[]

function definition_target_methods(state::ServerState, uri::URI, pos::Position)
    fi = get_fileinfo(state, uri)
    offset = xy_to_offset(fi, pos)

    st = JS.build_tree(JL.SyntaxTree, fi.parsed_stream)
    node = select_target_node(st, offset)
    node === nothing && return empty_methods

    mod = find_file_module(state, uri, pos)
    context = find_context_for_uri(state, uri)
    analyzer = isnothing(context) ? LSAnalyzer() : context.result.analyzer
    objtyp = resolve_type(analyzer, mod, node)
    objtyp isa Core.Const || return empty_methods

    return methods(objtyp.val)
end

function handle_DefinitionRequest(server::Server, msg::DefinitionRequest)
    origin_position = msg.params.position

    ms = definition_target_methods(server.state, msg.params.textDocument.uri, origin_position)

    if isempty(ms)
        send(server, DefinitionResponse(; id = msg.id, result = null))
    elseif is_definition_links_supported(server)
        send(server,
            DefinitionResponse(;
                id = msg.id,
                result = map(ms) do m
                    loc = @inline method_definition_range(m)
                    LocationLink(;
                        targetUri = loc.uri,
                        targetRange = loc.range,
                        targetSelectionRange = loc.range,
                        originSelectionRange = Range(;
                            start = origin_position,
                            var"end" = origin_position))
                end))
    else
        send(server, DefinitionResponse(; id = msg.id, result = method_definition_range.(ms)))
    end
end
