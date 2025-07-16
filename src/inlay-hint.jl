const INLAY_HINT_REGISTRATION_ID = "jetls-inlay-hint"
const INLAY_HINT_REGISTRATION_METHOD = "textDocument/inlayHint"

function inlay_hint_options()
    return InlayHintOptions(;
        resolveProvider = false)
end

function inlay_hint_registration(static::Bool)
    return Registration(;
        id = INLAY_HINT_REGISTRATION_ID,
        method = INLAY_HINT_REGISTRATION_METHOD,
        registerOptions = InlayHintRegistrationOptions(;
            documentSelector = DEFAULT_DOCUMENT_SELECTOR,
            resolveProvider = false,
            id = static ? INLAY_HINT_REGISTRATION_ID : nothing))
end

# For dynamic registrations during development
# unregister(currently_running, Unregistration(;
#     id = INLAY_HINT_REGISTRATION_ID,
#     method = INLAY_HINT_REGISTRATION_METHOD))
# register(currently_running, inlay_hint_registration(#=static=#true))

function handle_InlayHintRequest(server::Server, msg::InlayHintRequest)
    uri = msg.params.textDocument.uri
    range = msg.params.range

    fi = @something get_file_info(server.state, uri) begin
        return send(server,
            InlayHintResponse(;
                id = msg.id,
                result = nothing,
                error = file_cache_error(uri)))
    end

    inlay_hints = InlayHint[]
    syntactic_inlay_hints!(inlay_hints, fi, range)
    return_type_inlay_hints!(inlay_hints, server.state, uri, fi)

    return send(server, InlayHintResponse(;
        id = msg.id,
        result = isempty(inlay_hints) ? null : inlay_hints))
end

function syntactic_inlay_hints!(inlay_hints::Vector{InlayHint}, fi::FileInfo, range::Range)
    traverse(build_tree!(JL.SyntaxTree, fi)) do st::SyntaxTree0
        if JS.kind(st) === JS.K"module" && JS.numchildren(st) ≥ 2
            modrange = get_source_range(st)
            endpos = modrange.var"end"
            if endpos ∉ range
                return # this inlay hint isn't visible
            elseif modrange.start.line == endpos.line
                return # don't add module inlay hint when module is defined as one linear
            else
                # If there's already a comment like `end # module ModName`, don't display the inlay hint
                modname = JS.sourcetext(st[1])
                bstart = xy_to_offset(fi, endpos) + 1
                nexttc = next_nontrivia(fi.parsed_stream, bstart)
                if isnothing(nexttc) # no non-trivial token left - include everything left
                    commentrange = bstart:length(fi.parsed_stream.textbuf)
                elseif JS.kind(this(nexttc)) === JS.K"NewlineWs"
                    commentrange = bstart:length(fi.parsed_stream.textbuf)
                else
                    commentrange = bstart:first_byte(nexttc)-1
                end
                commentstr = String(fi.parsed_stream.textbuf[commentrange])
                if occursin(modname, commentstr)
                    return
                elseif startswith(lstrip(commentstr), "# module")
                    return
                elseif startswith(lstrip(commentstr), "#= module")
                    return
                end
                label = " #= module $modname =#"
                offset = sizeof(label)
                textEdits = TextEdit[TextEdit(;
                    range = Range(;
                        start = Position(endpos; character = endpos.character+1),
                        var"end" = Position(endpos; character = endpos.character+1+offset)),
                    newText = label)]
                push!(inlay_hints, InlayHint(;
                    position = endpos,
                    textEdits,
                    label))
            end
        end
    end
    return inlay_hints
end
syntactic_inlay_hints(args...) = syntactic_inlay_hints!(InlayHint[], args...) # used by tests

function return_type_inlay_hints!(inlay_hints::Vector{InlayHint}, state::ServerState, uri::URI, fi::FileInfo)
    sfi = @something get_saved_file_info(state, uri) return nothing
    if JS.sourcetext(fi.parsed_stream) ≠ JS.sourcetext(sfi.parsed_stream)
        return nothing
    end

    filename = uri2filename(uri)
    analysis_unit = find_analysis_unit_for_uri(state, uri)
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
    return inlay_hints
end
return_type_inlay_hints(args...) = return_type_inlay_hints!(InlayHint[], args...) # used by tests
