const REFERENCES_REGISTRATION_ID = "jetls-references"
const REFERENCES_REGISTRATION_METHOD = "textDocument/references"

struct ReferencesProgressCaller <: RequestCaller
    uri::URI
    fi::FileInfo
    pos::Position
    include_declaration::Bool
    msg_id::MessageId
    token::ProgressToken
    cancel_flag::CancelFlag
end
cancellable_token(caller::ReferencesProgressCaller) = caller.token

function references_options(server::Server)
    return ReferenceOptions(;
        workDoneProgress = supports(server, :window, :workDoneProgress))
end

function references_registration(server::Server)
    return Registration(;
        id = REFERENCES_REGISTRATION_ID,
        method = REFERENCES_REGISTRATION_METHOD,
        registerOptions = ReferenceRegistrationOptions(;
            documentSelector = DEFAULT_DOCUMENT_SELECTOR,
            workDoneProgress = supports(server, :window, :workDoneProgress)))
end

function handle_ReferencesRequest(
        server::Server, msg::ReferencesRequest, cancel_flag::CancelFlag)
    uri = msg.params.textDocument.uri
    pos = adjust_position(server.state, uri, msg.params.position)
    include_declaration = msg.params.context.includeDeclaration
    token = msg.params.workDoneToken

    result = get_file_info(server.state, uri, cancel_flag)
    if isnothing(result)
        return send(server, ReferencesResponse(; id = msg.id, result = null))
    elseif result isa ResponseError
        return send(server, ReferencesResponse(; id = msg.id, result = nothing, error = result))
    end
    fi = result

    if token !== nothing
        do_find_references(server, uri, fi, pos, msg.id; include_declaration, token, cancel_flag)
    elseif supports(server, :window, :workDoneProgress)
        id = String(gensym(:WorkDoneProgressCreateRequest_references))
        token = String(gensym(:ReferencesProgress))
        addrequest!(server, id => ReferencesProgressCaller(uri, fi, pos, include_declaration, msg.id, token, cancel_flag))
        params = WorkDoneProgressCreateParams(; token)
        send(server, WorkDoneProgressCreateRequest(; id, params))
    else
        do_find_references(server, uri, fi, pos, msg.id; include_declaration, cancel_flag)
    end

    return nothing
end

function handle_references_progress_response(
        server::Server, msg::Dict{Symbol,Any}, request_caller::ReferencesProgressCaller,
        progress_cancel_flag::CancelFlag)
    if handle_response_error(server, msg, "create work done progress")
        return
    end
    (; uri, fi, pos, include_declaration, msg_id, token, cancel_flag) = request_caller
    combined_flag = CombinedCancelFlag(cancel_flag, progress_cancel_flag)
    do_find_references(server, uri, fi, pos, msg_id; include_declaration, token, cancel_flag=combined_flag)
end

function do_find_references(
        server::Server, uri::URI, fi::FileInfo, pos::Position, msg_id::MessageId;
        kwargs...)
    result = find_references(server, uri, fi, pos; kwargs...)
    if result isa ResponseError
        return send(server, ReferencesResponse(; id = msg_id, result = nothing, error = result))
    else
        return send(server, ReferencesResponse(; id = msg_id, result = @somereal result null))
    end
end

function find_references(
        server::Server, uri::URI, fi::FileInfo, pos::Position;
        include_declaration::Bool = true, kwargs...
    )
    st0_top = build_syntax_tree(fi)
    offset = xy_to_offset(fi, pos)
    (; mod) = get_context_info(server.state, uri, pos)
    locations = Location[]

    (; ctx3, st3, binding) = @something begin
        _select_target_binding(st0_top, offset, mod; caller="find_references!")
    end return locations

    binfo = JL.get_binding(ctx3, binding)
    if binfo.kind === :global
        error = find_global_references!(locations, server, uri, binfo; include_declaration, kwargs...)
        error !== nothing && return error
    else
        find_local_references!(locations, server, uri, fi, ctx3, st3, binfo; include_declaration)
    end

    return locations
end

function find_global_references!(
        locations::Vector{Location}, server::Server, uri::URI, binfo::JL.BindingInfo;
        token::Union{Nothing,ProgressToken} = nothing,
        kwargs...
    )
    uris_to_search = collect_search_uris(server, uri)
    if token !== nothing
        send_progress(server, token,
            WorkDoneProgressBegin(; title = "Finding references", cancellable = true, percentage = 0))
    end
    seen_locations = Set{Tuple{URI,Range}}()
    local completed = errored = false
    try
        completed = collect_global_references!(
            seen_locations, server, uris_to_search, binfo; token, kwargs...)
    catch err
        @error "Error in `find_global_references!`"
        Base.display_error(stderr, err, catch_backtrace())
        errored = true
    finally
        if token !== nothing
            send_progress(server, token,
                WorkDoneProgressEnd(;
                    message = errored ? "Failed finding references" :
                        !completed ? "Cancelled finding references" :
                        "Found $(length(seen_locations)) references"))
        end
    end
    if errored
        return request_failed_error("find_global_references! failed")
    elseif !completed
        return request_cancelled_error("find_global_references! cancelled")
    end
    for (loc_uri, range) in seen_locations
        push!(locations, Location(; uri = loc_uri, range))
    end
    return nothing
end

function collect_global_references!(
        seen_locations::Set{Tuple{URI,Range}}, server::Server,
        uris_to_search::Set{URI}, binfo::JL.BindingInfo;
        include_declaration::Bool = true,
        token::Union{Nothing,ProgressToken} = nothing,
        cancel_flag::AbstractCancelFlag = DUMMY_CANCEL_FLAG
    )
    state = server.state
    n_files = length(uris_to_search)
    for (i, uri) in enumerate(uris_to_search)
        if is_cancelled(cancel_flag)
            return false
        end

        if token !== nothing
            percentage = round(Int, 100 * (i - 1) / n_files)
            message = "Searching $(basename(uri2filename(uri))) ($i/$n_files)"
            send_progress(server, token,
                WorkDoneProgressReport(; message, cancellable = true, percentage))
        end

        fi = @something begin
            get_file_info(state, uri)
        end begin
            get_unsynced_file_info!(server.state, uri)
        end continue
        search_st0_top = build_syntax_tree(fi)
        global_find_references_in_file!(
            seen_locations, state, uri, fi, search_st0_top, binfo;
            include_declaration)
    end
    return true
end

function global_find_references_in_file!(
        seen_locations::Set{Tuple{URI,Range}}, state::ServerState, uri::URI, fi::FileInfo,
        st0_top::JS.SyntaxTree, binfo::JL.BindingInfo;
        include_declaration::Bool = true,
    )
    for occurrence in find_global_binding_occurrences!(state, uri, fi, st0_top, binfo)
        is_def = occurrence.kind === :def
        if !is_def || include_declaration
            range, _ = unadjust_range(state, uri, jsobj_to_range(occurrence.tree, fi))
            push!(seen_locations, (uri, range))
        end
    end
    return seen_locations
end

function find_local_references!(
        locations::Vector{Location}, server::Server, uri::URI, fi::FileInfo,
        ctx3, st3, binfo::JL.BindingInfo;
        include_declaration::Bool = true,
    )
    ranges = Set{Range}()
    binding_occurrences = compute_binding_occurrences(ctx3, st3)
    if haskey(binding_occurrences, binfo)
        for occurrence in binding_occurrences[binfo]
            is_def = occurrence.kind === :def
            if !is_def || include_declaration
                range, _ = unadjust_range(server.state, uri, jsobj_to_range(occurrence.tree, fi))
                push!(ranges, range)
            end
        end
    end
    for range in ranges
        push!(locations, Location(; uri, range))
    end
    return locations
end
