const REFERENCES_REGISTRATION_ID = "jetls-references"
const REFERENCES_REGISTRATION_METHOD = "textDocument/references"

struct ReferencesProgressCaller <: RequestCaller
    uri::URI
    fi::FileInfo
    pos::Position
    include_declaration::Bool
    msg_id::MessageId
    token::ProgressToken
end

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

    result = get_file_info(server.state, uri, cancel_flag)
    if result isa ResponseError
        return send(server,
            ReferencesResponse(;
                id = msg.id,
                result = nothing,
                error = result))
    end
    fi = result

    workDoneToken = msg.params.workDoneToken
    if workDoneToken !== nothing
        do_find_references_with_progress(server, uri, fi, pos, include_declaration, msg.id, workDoneToken)
    elseif supports(server, :window, :workDoneProgress)
        id = String(gensym(:WorkDoneProgressCreateRequest_references))
        token = String(gensym(:ReferencesProgress))
        addrequest!(server, id => ReferencesProgressCaller(uri, fi, pos, include_declaration, msg.id, token))
        params = WorkDoneProgressCreateParams(; token)
        send(server, WorkDoneProgressCreateRequest(; id, params))
    else
        do_find_references(server, uri, fi, pos, include_declaration, msg.id)
    end

    return nothing
end

function handle_references_progress_response(
        server::Server, msg::Dict{Symbol,Any}, request_caller::ReferencesProgressCaller)
    if handle_response_error(server, msg, "create work done progress")
        return
    end
    (; uri, fi, pos, include_declaration, msg_id, token) = request_caller
    do_find_references_with_progress(server, uri, fi, pos, include_declaration, msg_id, token)
end

function do_find_references_with_progress(
        server::Server, uri::URI, fi::FileInfo, pos::Position,
        include_declaration::Bool, msg_id::MessageId, token::ProgressToken)
    locations = find_references(server, uri, fi, pos; token, include_declaration)
    return send(server, ReferencesResponse(;
        id = msg_id,
        result = @somereal locations null))
end

function do_find_references(
        server::Server, uri::URI, fi::FileInfo, pos::Position,
        include_declaration::Bool, msg_id::MessageId)
    locations = find_references(server, uri, fi, pos; include_declaration)
    return send(server, ReferencesResponse(;
        id = msg_id,
        result = @somereal locations null))
end

function find_references(
        server::Server, uri::URI, fi::FileInfo, pos::Position;
        token::Union{Nothing,ProgressToken} = nothing,
        include_declaration::Bool = true,
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
        find_global_references!(locations, server, uri, fi, st0_top, binfo, token;
            include_declaration)
    else
        find_local_references!(locations, server, uri, fi, ctx3, st3, binfo; include_declaration)
    end

    return locations
end

function find_global_references!(
        locations::Vector{Location}, server::Server,
        uri::URI, fi::FileInfo, st0_top::JS.SyntaxTree, binfo::JL.BindingInfo,
        token::Union{Nothing,ProgressToken};
        include_declaration::Bool=true,
    )
    uris_to_search = collect_search_uris(server, uri)

    n_files = length(uris_to_search)
    if token !== nothing && n_files > 1
        send_progress(server, token,
            WorkDoneProgressBegin(; title="Finding references", percentage=0))
    end

    seen_locations = Set{Tuple{URI,Range}}()
    for (i, search_uri) in enumerate(uris_to_search)
        if search_uri == uri
            search_fi = fi
        else
            search_fi = get_file_info(server.state, search_uri)
            if search_fi === nothing
                search_fi = create_dummy_file_info(search_uri, fi)
            end
        end

        if token !== nothing && n_files > 1
            percentage = round(Int, 100 * (i - 1) / n_files)
            message = "Searching $(basename(uri2filename(search_uri))) ($i/$n_files)"
            send_progress(server, token,
                WorkDoneProgressReport(; message, percentage))
        end

        search_st0_top = build_syntax_tree(search_fi)
        global_find_references_in_file!(
            seen_locations, server.state, search_uri, search_fi, search_st0_top, binfo;
            include_declaration)
    end

    if token !== nothing && n_files > 1
        send_progress(server, token,
            WorkDoneProgressEnd(; message="Found $(length(seen_locations)) references"))
    end

    for (loc_uri, range) in seen_locations
        push!(locations, Location(; uri=loc_uri, range))
    end
    return locations
end

function global_find_references_in_file!(
        seen_locations::Set{Tuple{URI,Range}}, state::ServerState, uri::URI, fi::FileInfo,
        st0_top::JS.SyntaxTree, binfo::JL.BindingInfo;
        include_declaration::Bool=true,
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
        include_declaration::Bool=true,
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
