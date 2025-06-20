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

    target = first(bas)
    if kind(target) !== K"Identifier"
        offset > 0 || return nothing
        # Support cases like `var│`, `func│(5)`
        bas = byte_ancestors(st, offset - 1)
        target = first(bas)
        if kind(target) !== K"Identifier"
            return nothing
        end
    end

    for i in 2:length(bas)
        basᵢ = bas[i]
        if (kind(basᵢ) === K"." &&
            basᵢ[1] !== target) # e.g. don't allow jumps to `tmeet` from `Base.Compi│ler.tmeet`
            target = basᵢ
        else
            return target
        end
    end

    # Unreachable: we always have toplevel node
    return nothing
end

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

const empty_methods = Method[]

function definition_target_methods(state::ServerState, uri::URI, pos::Position, fi::FileInfo)
    offset = xy_to_offset(fi, pos)

    st = JS.build_tree(JL.SyntaxTree, fi.parsed_stream)
    node = select_target_node(st, offset)
    node === nothing && return empty_methods

    (; mod, analyzer) = get_context_info(state, uri, pos)
    objtyp = resolve_type(analyzer, mod, node)
    objtyp isa Core.Const || return empty_methods

    # TODO modify this aggregation logic when we start to use more precise location informaiton
    return filter(!is_location_unknown, unique(Base.updated_methodloc, methods(objtyp.val)))
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

    ms = definition_target_methods(server.state, uri, origin_position, fi)

    if isempty(ms)
        send(server, DefinitionResponse(; id = msg.id, result = null))
    elseif supports(server, :textDocument, :definition, :linkSupport)
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
