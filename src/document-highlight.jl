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

# TODO Add some syntactic highlight feature?

function handle_DocumentHighlightRequest(
        server::Server, msg::DocumentHighlightRequest, snapshot::DocumentSnapshot,
        cancel_flag::CancelFlag,
    )
    if is_cancelled(cancel_flag)
        return send(server, DocumentHighlightResponse(;
            id = msg.id, result = nothing, error = request_cancelled_error()))
    end
    state = server.state
    uri = msg.params.textDocument.uri
    pos = adjust_position(snapshot, uri, msg.params.position)
    highlights = DocumentHighlight[]
    document_highlights!(highlights, state, uri, snapshot, pos)
    return send(server, DocumentHighlightResponse(;
        id = msg.id,
        result = highlights))
end

function document_highlights!(
        highlights::Vector{DocumentHighlight}, state::ServerState, uri::URI,
        snapshot::DocumentSnapshot, pos::Position,
    )
    (; fi, cache_uri) = snapshot
    st0_top = build_syntax_tree(fi)
    offset = xy_to_offset(fi, pos)
    (; context_module, world) = get_context_info(state, cache_uri, pos)
    soft_scope = snapshot.notebook !== nothing

    (; ctx3, st3, binding) = @something begin
        select_target_binding(st0_top, offset, context_module, world;
            caller="document_highlights!", soft_scope)
    end return highlights

    binfo = JL.get_binding(ctx3, binding)

    highlights′ = Dict{Range,DocumentHighlightKind.Ty}()
    if binfo.kind === :global
        global_document_highlights!(highlights′, state, uri, snapshot, st0_top, binfo)
    else
        local_document_highlights!(highlights′, uri, snapshot, ctx3, st3, binfo, world)
    end

    for (range, kind) in highlights′
        push!(highlights, DocumentHighlight(; range, kind))
    end
    return highlights
end

function add_highlight_for_occurrence!(
        highlights′::Dict{Range,DocumentHighlightKind.Ty},
        uri::URI, snapshot::DocumentSnapshot, occurrence::AnyBindingOccurrence,
    )
    range = jsobj_to_range(occurrence.tree, snapshot.fi)
    occurrence_uri, range = unadjust_range(snapshot, snapshot.cache_uri, range)
    occurrence_uri == uri || return nothing
    kind = document_highlight_kind(occurrence)
    highlights′[range] = max(kind, get(highlights′, range, DocumentHighlightKind.Text))
end

document_highlight_kind(occurrence::AnyBindingOccurrence) =
    is_definition_occurrence(occurrence) ? DocumentHighlightKind.Write :
    occurrence.kind === :use ? DocumentHighlightKind.Read :
    DocumentHighlightKind.Text

function global_document_highlights!(
        highlights′::Dict{Range,DocumentHighlightKind.Ty},
        state::ServerState, uri::URI, snapshot::DocumentSnapshot, st0_top::SyntaxTree,
        binfo::JL.BindingInfo,
    )
    (; fi, cache_uri) = snapshot
    if snapshot.notebook !== nothing
        return notebook_global_document_highlights!(
            highlights′, state, uri, snapshot, st0_top, binfo)
    end
    for occurrence in find_global_binding_occurrences_from_tree!(state, cache_uri, fi, st0_top, binfo)
        add_highlight_for_occurrence!(highlights′, uri, snapshot, occurrence)
    end
    return highlights′
end

# The shared occurrence cache lowers using live notebook membership, which may have
# disappeared since capture. Lower notebook snapshots with their captured soft scope.
function notebook_global_document_highlights!(
        highlights′::Dict{Range,DocumentHighlightKind.Ty},
        state::ServerState, uri::URI, snapshot::DocumentSnapshot, st0_top::SyntaxTree,
        binfo::JL.BindingInfo,
    )
    (; fi, cache_uri) = snapshot
    lookup_func = gen_lookup_out_of_scope!(state, cache_uri)
    iterate_toplevel_tree(st0_top) do st0::SyntaxTree
        occurrences = @something compute_full_binding_occurrences(
            state, cache_uri, fi, st0; lookup_func, soft_scope=true) return
        for (binfo′, binding_occurrences) in occurrences
            is_matching_global_binding(binfo′, binfo) || continue
            for occurrence in binding_occurrences
                add_highlight_for_occurrence!(highlights′, uri, snapshot, occurrence)
            end
        end
    end
    return highlights′
end

function local_document_highlights!(
        highlights′::Dict{Range,DocumentHighlightKind.Ty},
        uri::URI, snapshot::DocumentSnapshot,
        ctx3::JL.VariableAnalysisContext, st3::SyntaxTree,
        binfo::JL.BindingInfo, world::UInt,
    )
    binding_occurrences = compute_binding_occurrences(ctx3, st3, world)
    if haskey(binding_occurrences, binfo)
        for occurrence in binding_occurrences[binfo]
            add_highlight_for_occurrence!(highlights′, uri, snapshot, occurrence)
        end
    end
    return highlights′
end

# used by tests
function document_highlights(fi::FileInfo, pos::Position)
    state = ServerState()
    uri = filepath2uri(fi.filename)
    store!(state.file_cache) do cache
        Base.PersistentDict(cache, uri => fi), nothing
    end
    snapshot = get_document_snapshot(state, uri)::DocumentSnapshot
    return document_highlights!(DocumentHighlight[], state, uri, snapshot, pos)
end
