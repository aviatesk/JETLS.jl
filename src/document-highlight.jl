const DOCUMENT_HIGHLIGHT_REGISTRATION_ID = "jetls-document-highlight"
const DOCUMENT_HIGHLIGHT_REGISTRATION_METHOD = "textDocument/documentHighlight"

function document_highlight_options()
    return DocumentHighlightOptions()
end

function document_highlight_registration()
    return Registration(;
        id = DOCUMENT_HIGHLIGHT_REGISTRATION_ID,
        method = DOCUMENT_HIGHLIGHT_REGISTRATION_METHOD,
        registerOptions = DocumentHighlightRegistrationOptions(;
            documentSelector = DEFAULT_DOCUMENT_SELECTOR,
        )
    )
end

# For dynamic registrations during development
# unregister(currently_running, Unregistration(;
#     id = DOCUMENT_HIGHLIGHT_REGISTRATION_ID,
#     method = DOCUMENT_HIGHLIGHT_REGISTRATION_METHOD))
# register(currently_running, document_highlight_registration())

# TODO Add some syntactic highlight feature?

function handle_DocumentHighlightRequest(server::Server, msg::DocumentHighlightRequest)
    uri = msg.params.textDocument.uri
    pos = msg.params.position

    fi = @something get_file_info(server.state, uri) begin
        return send(server,
            DocumentHighlightResponse(;
                id = msg.id,
                result = nothing,
                error = file_cache_error(uri)))
    end

    highlights = DocumentHighlight[]

    offset = xy_to_offset(fi, pos)

    (; mod) = get_context_info(server.state, uri, pos)
    lowering_document_highlights!(highlights, fi, offset, mod)

    return send(server, DocumentHighlightResponse(;
        id = msg.id,
        result = highlights
    ))
end

function lowering_document_highlights!(highlights::Vector{DocumentHighlight}, fi::FileInfo, offset::Int, mod::Module)
    st0_top = build_tree!(JL.SyntaxTree, fi)

    st0, _ = @something greatest_local(st0_top, offset) return highlights
    (; ctx3, st3) = try
        jl_lower_for_scope_resolution(mod, st0)
    catch err
        JETLS_DEBUG_LOWERING && @warn "Error in lowering (lowering_document_highlights!)" err
        JETLS_DEBUG_LOWERING && Base.show_backtrace(stderr, catch_backtrace())
        return highlights
    end

    binding = @something __select_target_binding(ctx3, st3, offset) return highlights
    binfo = JL.lookup_binding(ctx3, binding)

    binding_occurrences = compute_binding_occurrences(ctx3, st3)
    if haskey(binding_occurrences, binfo)
        highlights′ = Dict{Range,DocumentHighlightKind.Ty}()
        for occurrence in binding_occurrences[binfo]
            range = jsobj_to_range(occurrence.tree, fi)
            kind =
                occurrence.kind === :def ? DocumentHighlightKind.Write :
                occurrence.kind === :use ? DocumentHighlightKind.Read :
                DocumentHighlightKind.Text
            highlights′[range] = max(kind, get(highlights′, range, DocumentHighlightKind.Text))
        end
        for (range, kind) in highlights′
            push!(highlights, DocumentHighlight(; range, kind))
        end
    end
    return highlights
end
lowering_document_highlights(fi::FileInfo, offset::Int, mod::Module) = # used by tests
    lowering_document_highlights!(DocumentHighlight[], fi, offset, mod)
lowering_document_highlights(fi::FileInfo, pos::Position, mod::Module) = # used by tests
    lowering_document_highlights(fi, xy_to_offset(fi, pos), mod)
