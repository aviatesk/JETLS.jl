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

# For dynamic registrations during development
# unregister(currently_running, Unregistration(;
#     id = HOVER_REGISTRATION_ID,
#     method = HOVER_REGISTRATION_METHOD))
# register(currently_running, hover_registration())

function local_binding_hover(fi::FileInfo, uri::URI, st0_top::JL.SyntaxTree, offset::Int, mod::Module)
    target_binding, definitions = @something begin
        select_target_binding_definitions(st0_top, offset, mod)
    end return nothing
    contents = MarkupContent(;
        kind = MarkupKind.Markdown,
        value = local_binding_hover_info(fi, uri, definitions))
    return Hover(;
        contents,
        range = jsobj_to_range(target_binding, fi))
end

function local_binding_hover_info(fi::FileInfo, uri::URI, definitions::JL.SyntaxList)
    io = IOBuffer()
    n = length(definitions)
    for (i, definition) in enumerate(definitions)
        println(io, "``````julia")
        JL.showprov(io, definition; include_location=false)
        println(io)
        println(io, "``````")
        (; line, character) = jsobj_to_range(definition, fi).start
        line += 1; character += 1
        showtext = "`@ " * simple_loc_text(uri; line) * "`"
        println(io, create_source_location_link(uri, showtext; line, character))
        if i ≠ n
            println(io, "\n---\n") # separator
        else
            println(io)
        end
    end
    return String(take!(io))
end

function handle_HoverRequest(server::Server, msg::HoverRequest, cancel_flag::CancelFlag)
    if is_cancelled(cancel_flag)
        return send(server,
            HoverResponse(;
                id = msg.id,
                result = nothing,
                error = request_cancelled_error()))
    end
    pos = msg.params.position
    uri = msg.params.textDocument.uri

    fi = @something get_file_info(server.state, uri) begin
        return send(server,
            HoverResponse(;
                id = msg.id,
                result = nothing,
                error = file_cache_error(uri)))
    end

    st0_top = build_syntax_tree(fi)
    offset = xy_to_offset(fi, pos)
    (; mod, analyzer, postprocessor) = get_context_info(server.state, uri, pos)

    local_hover = local_binding_hover(fi, uri, st0_top, offset, mod)
    isnothing(local_hover) || return send(server, HoverResponse(;
        id = msg.id,
        result = local_hover))

    node = @something select_target_node(st0_top, offset) begin
        return send(server, HoverResponse(; id = msg.id, result = null))
    end

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
    value = postprocessor(documentation)

    contents = MarkupContent(;
        kind = MarkupKind.Markdown,
        value)
    range = jsobj_to_range(node, fi)
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
