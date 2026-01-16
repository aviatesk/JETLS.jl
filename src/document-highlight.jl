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

function handle_DocumentHighlightRequest(
        server::Server, msg::DocumentHighlightRequest, cancel_flag::CancelFlag)
    state = server.state
    uri = msg.params.textDocument.uri
    pos = adjust_position(state, uri, msg.params.position)

    result = get_file_info(state, uri, cancel_flag)
    if isnothing(result)
        return send(server, DocumentHighlightResponse(; id = msg.id, result = null))
    elseif result isa ResponseError
        return send(server, DocumentHighlightResponse(; id = msg.id, result = nothing, error = result))
    end
    fi = result

    highlights = DocumentHighlight[]
    document_highlights!(highlights, state, uri, fi, pos)
    return send(server, DocumentHighlightResponse(;
        id = msg.id,
        result = @somereal highlights null
    ))
end

function document_highlights!(
        highlights::Vector{DocumentHighlight}, state::ServerState, uri::URI,
        fi::FileInfo, pos::Position,
    )
    st0_top = build_syntax_tree(fi)
    offset = xy_to_offset(fi, pos)
    (; mod) = get_context_info(state, uri, pos)

    (; ctx3, st3, binding) = @something begin
        _select_target_binding(st0_top, offset, mod; caller="document_highlights!")
    end return highlights

    binfo = JL.get_binding(ctx3, binding)

    highlights′ = Dict{Range,DocumentHighlightKind.Ty}()
    if binfo.kind === :global
        global_document_highlights!(highlights′, state, uri, fi, st0_top, binfo)
    else
        local_document_highlights!(highlights′, state, uri, fi, ctx3, st3, binfo)
    end

    for (range, kind) in highlights′
        push!(highlights, DocumentHighlight(; range, kind))
    end
    return highlights
end

function add_highlight_for_occurrence!(
        highlights′::Dict{Range,DocumentHighlightKind.Ty},
        state::ServerState, uri::URI, fi::FileInfo, occurrence::AnyBindingOccurrence,
    )
    range = jsobj_to_range(occurrence.tree, fi)
    range, _ = unadjust_range(state, uri, range)
    kind = document_highlight_kind(occurrence)
    highlights′[range] = max(kind, get(highlights′, range, DocumentHighlightKind.Text))
end

document_highlight_kind(occurrence::AnyBindingOccurrence) =
    occurrence.kind === :def ? DocumentHighlightKind.Write :
    occurrence.kind === :use ? DocumentHighlightKind.Read :
    DocumentHighlightKind.Text

function global_document_highlights!(
        highlights′::Dict{Range,DocumentHighlightKind.Ty},
        state::ServerState, uri::URI, fi::FileInfo, st0_top::JS.SyntaxTree,
        binfo::JL.BindingInfo,
    )
    for occurrence in find_global_binding_occurrences!(state, uri, fi, st0_top, binfo)
        add_highlight_for_occurrence!(highlights′, state, uri, fi, occurrence)
    end
    return highlights′
end

function local_document_highlights!(
        highlights′::Dict{Range,DocumentHighlightKind.Ty},
        state::ServerState, uri::URI, fi::FileInfo, ctx3, st3, binfo::JL.BindingInfo,
    )
    binding_occurrences = compute_binding_occurrences(ctx3, st3)
    if haskey(binding_occurrences, binfo)
        for occurrence in binding_occurrences[binfo]
            add_highlight_for_occurrence!(highlights′, state, uri, fi, occurrence)
        end
    end
    return highlights′
end

# used by tests
function document_highlights(fi::FileInfo, pos::Position, mod::Module=Main)
    state = ServerState()
    uri = filepath2uri(fi.filename)
    store!(state.file_cache) do cache
        Base.PersistentDict(cache, uri => fi), nothing
    end
    return document_highlights!(DocumentHighlight[], state, uri, fi, pos)
end
