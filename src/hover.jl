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

    st0_top = JS.build_tree(JL.SyntaxTree, fi.parsed_stream)
    offset = xy_to_offset(fi, pos)

    target_binding_definitions = select_target_binding_definitions(st0_top, offset)
    if !isnothing(target_binding_definitions)
        # TODO Ideally we would want to show the type of this local binding,
        # but for now we'll just show the location of the local binding
        target_binding, definitions = target_binding_definitions
        io = IOBuffer()
        println(io, "```julia")
        for definition in definitions
            JL.showprov(io, definition)
            println(io)
        end
        println(io, "```")
        value = String(take!(io))
        contents = MarkupContent(;
            kind = MarkupKind.Markdown,
            value)
        return send(server, HoverResponse(;
            id = msg.id,
            result = Hover(;
                contents,
                range = get_source_range(target_binding))))
    end

    node = select_target_node(st0_top, offset)
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
    documentation = Base.Docs.doc(DocsBinding(parentmod, identifier))
    value = postprocessor(string(documentation))

    contents = MarkupContent(;
        kind = MarkupKind.Markdown,
        value)
    range = get_source_range(node)
    return send(server, HoverResponse(;
        id = msg.id,
        result = Hover(; contents, range)))
end

@eval function DocsBinding(parentmod::Module, identifier::Symbol)
    if invokelatest(isdefinedglobal, parentmod, identifier)
        x = invokelatest(getglobal, parentmod, identifier)
        if x isa Module && nameof(x) !== identifier
            # HACK: skip the binding resolution logic performed by the `Base.Docs.Binding` constructor
            # for modules that are given different names within this context
            return $(Expr(:new, Base.Docs.Binding, :parentmod, :identifier))
        end
    end
    return Base.Docs.Binding(parentmod, identifier)
end
