const INLAY_HINT_REGISTRATION_ID = "jetls-inlay-hint"
const INLAY_HINT_REGISTRATION_METHOD = "textDocument/inlayHint"

function inlay_hint_options()
    return InlayHintOptions(;
        resolveProvider = false)
end

function inlay_hint_registration()
    return Registration(;
        id = INLAY_HINT_REGISTRATION_ID,
        method = INLAY_HINT_REGISTRATION_METHOD,
        registerOptions = InlayHintRegistrationOptions(;
            documentSelector = DEFAULT_DOCUMENT_SELECTOR,
            resolveProvider = false))
end

function handle_InlayHintRequest(server::Server, msg::InlayHintRequest)
    uri = msg.params.textDocument.uri
    range = msg.params.range

    fi = get_file_info(server.state, uri)
    if fi === nothing
        return send(server,
            InlayHintResponse(;
                id = msg.id,
                result = nothing,
                error = file_cache_error(uri)))
    end
    sfi = get_saved_file_info(server.state, uri)
    if sfi === nothing
        return send(server,
            InlayHintResponse(;
                id = msg.id,
                result = nothing,
                error = file_cache_error(uri)))
    elseif JS.sourcetext(fi.parsed_stream) ≠ JS.sourcetext(sfi.parsed_stream)
        return send(server, InlayHintResponse(;
            id = msg.id,
            result = null))
    end

    inlay_hints = InlayHint[]

    filename = uri2filename(uri)
    analysis_unit = find_analysis_unit_for_uri(server.state, uri)
    interp = get_context_interpreter(analysis_unit)
    postprocessor = get_post_processor(analysis_unit)
    if !isnothing(interp)
        for result in interp.results
            filename == result.filename || continue
            isdefined(result, :result) || continue
            methodnode = result.node
            if JS.kind(methodnode) === JS.K"doc"
                JS.numchildren(methodnode) ≥ 2 || continue
                methodnode = methodnode[2]
            end
            JS.kind(methodnode) === JS.K"function" || continue
            JS.numchildren(methodnode) ≥ 2 || continue
            arglist = methodnode[1]
            JS.kind(arglist) === JS.K"call" || continue
            overlap(get_source_range(arglist), range) || continue
            position = offset_to_xy(fi, JS.last_byte(arglist)+1)
            label = "::" * postprocessor(string(CC.widenconst(result.result.result)))
            tooltip = let codeinfostr =
                postprocessor(sprint(io->show(io, result.result.src; debuginfo=:none)))
                value = "```\n" * codeinfostr * "\n```"
                MarkupContent(;
                    kind = MarkupKind.Markdown,
                    value)
            end
            push!(inlay_hints, InlayHint(;
                position,
                label,
                tooltip,
                kind = InlayHintKind.Type,
                paddingLeft = true))
        end
    end

    return send(server, InlayHintResponse(;
        id = msg.id,
        result = isempty(inlay_hints) ? null : inlay_hints))
end
