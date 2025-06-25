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
    parentmod = mod
    identifier_node = node

    # TODO replace this AST hack with a proper abstract interpretation to resolve binding information
    if JS.kind(node) === JS.K"." && JS.numchildren(node) ≥ 2
        dotprefix = node[1]
        dotprefixtyp = resolve_type(analyzer, mod, dotprefix)
        if dotprefixtyp isa Core.Const
            dotprefixval = dotprefixtyp.val
            if dotprefixval isa Module
                parentmod = dotprefixval
                identifier_node = node[2]
            end
        end
    end
    if !JS.is_identifier(identifier_node)
        return send(server, HoverResponse(; id = msg.id, result = null))
    end
    identifier = Expr(identifier_node)
    if !(identifier isa Symbol)
        return send(server, HoverResponse(; id = msg.id, result = null))
    end
    documentation = Base.Docs.doc(Base.Docs.Binding(parentmod, identifier))
    value = postprocessor(string(documentation))

    contents = MarkupContent(;
        kind = MarkupKind.Markdown,
        value)
    range = get_source_range(node)
    return send(server, HoverResponse(;
        id = msg.id,
        result = Hover(; contents, range)))
end
