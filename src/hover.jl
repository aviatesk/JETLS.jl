const HOVER_REGISTRATION_ID = "jetls-hover"
const HOVER_REGISTRATION_METHOD = "textDocument/hover"

function hover_options()
    return HoverOptions()
end

function hover_registration()
    return Registration(;
        id = HOVER_REGISTRATION_ID,
        method = HOVER_REGISTRATION_METHOD,
        registerOptions = HoverRegistrationOptions(;
            documentSelector = DEFAULT_DOCUMENT_SELECTOR,
        )
    )
end

function handle_HoverRequest(server::Server, msg::HoverRequest)
    pos = msg.params.position
    uri = msg.params.textDocument.uri

    fi = get_fileinfo(server.state, uri)
    if fi === nothing
        return send(server,
            HoverResponse(;
                id = msg.id,
                result = nothing,
                error = file_cache_error(uri)))
    end

    st = JS.build_tree(JL.SyntaxTree, fi.parsed_stream)
    offset = xy_to_offset(fi, pos)
    node = select_target_node(st, offset)
    if node === nothing
        return send(server, HoverResponse(; id = msg.id, result = null))
    end

    (; mod, analyzer, postprocessor) = get_context_info(server.state, uri, pos)
    objtyp = resolve_type(analyzer, mod, node)

    if !(objtyp isa Core.Const)
        return send(server, HoverResponse(; id = msg.id, result = null))
    end

    contents = MarkupContent(;
        kind = MarkupKind.Markdown,
        value = postprocessor(string(Base.Docs.doc(objtyp.val))))
    range = get_source_range(node)
    return send(server, HoverResponse(;
        id = msg.id,
        result = Hover(; contents, range)))
end
