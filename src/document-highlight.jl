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
    document_highlights!(highlights, fi, pos, (state, uri))
    return send(server, DocumentHighlightResponse(;
        id = msg.id,
        result = @somereal highlights null
    ))
end

function document_highlights!(
        highlights::Vector{DocumentHighlight}, fi::FileInfo, pos::Position,
        module_info::Union{Tuple{ServerState,URI},Module},
    )
    st0_top = build_syntax_tree(fi)
    offset = xy_to_offset(fi, pos)
    if module_info isa Module
        mod = module_info
        location_info = nothing
    else
        (; mod) = get_context_info(module_info..., pos)
        location_info = module_info
    end

    (; ctx3, st3, binding) = @something begin
        _select_target_binding(st0_top, offset, mod; caller="document_highlights!")
    end return highlights

    binfo = JL.get_binding(ctx3, binding)

    highlights′ = Dict{Range,DocumentHighlightKind.Ty}()
    if binfo.kind === :global
        global_document_highlights!(highlights′, fi, st0_top, binfo, module_info)
    else
        local_document_highlights!(highlights′, fi, ctx3, st3, binfo, location_info)
    end

    for (range, kind) in highlights′
        push!(highlights, DocumentHighlight(; range, kind))
    end
    return highlights
end

function add_highlight_for_occurrence!(
        highlights′::Dict{Range,DocumentHighlightKind.Ty},
        fi::FileInfo, occurrence::BindingOccurence,
        location_info::Union{Tuple{ServerState,URI},Nothing} = nothing
    )
    range = jsobj_to_range(occurrence.tree, fi)
    if location_info !== nothing
        range, _ = unadjust_range(location_info..., range)
    end
    kind = document_highlight_kind(occurrence)
    highlights′[range] = max(kind, get(highlights′, range, DocumentHighlightKind.Text))
end

document_highlight_kind(occurrence::BindingOccurence) =
    occurrence.kind === :def ? DocumentHighlightKind.Write :
    occurrence.kind === :use ? DocumentHighlightKind.Read :
    DocumentHighlightKind.Text

function global_document_highlights!(
        highlights′::Dict{Range,DocumentHighlightKind.Ty},
        fi::FileInfo, st0_top::JS.SyntaxTree, binfo::JL.BindingInfo,
        module_info::Union{Tuple{ServerState,URI},Module},
    )
    location_info = module_info isa Module ? nothing : module_info
    iterate_toplevel_tree(st0_top) do st0::JS.SyntaxTree
        if module_info isa Module
            mod = module_info
        else
            (; mod) = get_context_info(module_info..., offset_to_xy(fi, JS.first_byte(st0)))
        end
        (; ctx3, st3) = try
            # Remove macros to preserve precise source locations
            jl_lower_for_scope_resolution(mod, remove_macrocalls(st0))
        catch
            return
        end
        binding_occurrences = compute_binding_occurrences(ctx3, st3; include_global_bindings=true)
        for (binfo′, occurrences) in binding_occurrences
            if binfo′.mod === binfo.mod && binfo′.name == binfo.name
                for occurrence in occurrences
                    add_highlight_for_occurrence!(highlights′, fi, occurrence, location_info)
                end
            end
        end
    end
    return highlights′
end

function local_document_highlights!(
        highlights′::Dict{Range,DocumentHighlightKind.Ty},
        fi::FileInfo, ctx3, st3, binfo::JL.BindingInfo,
        location_info::Union{Tuple{ServerState,URI},Nothing} = nothing
    )
    binding_occurrences = compute_binding_occurrences(ctx3, st3)
    if haskey(binding_occurrences, binfo)
        for occurrence in binding_occurrences[binfo]
            add_highlight_for_occurrence!(highlights′, fi, occurrence, location_info)
        end
    end
    return highlights′
end

# used by tests
document_highlights(fi::FileInfo, pos::Position, mod::Module) =
    document_highlights!(DocumentHighlight[], fi, pos, mod)
document_highlights(args...) = document_highlights(args..., Main)
