const RENAME_REGISTRATION_ID = "jetls-rename"
const RENAME_REGISTRATION_METHOD = "textDocument/rename"

function is_macrocall_use_site(fi::FileInfo, tree)
    fb = JS.first_byte(tree)
    return !iszero(fb) && fi.parsed_stream.textbuf[fb] == UInt8('@')
end

struct RenameProgressCaller <: RequestCaller
    uri::URI
    fi::FileInfo
    pos::Position
    newName::String
    msg_id::MessageId
    token::ProgressToken
    cancel_flag::CancelFlag
end
cancellable_token(caller::RenameProgressCaller) = caller.token

function rename_options(server::Server)
    return RenameOptions(;
        prepareProvider = true,
        workDoneProgress = supports(server, :window, :workDoneProgress))
end

function rename_registration(server::Server)
    return Registration(;
        id = RENAME_REGISTRATION_ID,
        method = RENAME_REGISTRATION_METHOD,
        registerOptions = RenameRegistrationOptions(;
            documentSelector = DEFAULT_DOCUMENT_SELECTOR,
            prepareProvider = true,
            workDoneProgress = supports(server, :window, :workDoneProgress)))
end

# # For dynamic registrations during development
# unregister(currently_running, Unregistration(;
#     id = RENAME_REGISTRATION_ID,
#     method = RENAME_REGISTRATION_METHOD))
# register(currently_running, rename_registration(currently_running))

function handle_PrepareRenameRequest(
        server::Server, msg::PrepareRenameRequest, cancel_flag::CancelFlag)
    state = server.state
    uri = msg.params.textDocument.uri
    pos = adjust_position(state, uri, msg.params.position)

    result = get_file_info(state, uri, cancel_flag)
    if isnothing(result)
        return send(server, PrepareRenameResponse(; id = msg.id, result = null))
    elseif result isa ResponseError
        return send(server, PrepareRenameResponse(; id = msg.id, result = nothing, error = result))
    end
    fi = result

    (; mod) = get_context_info(state, uri, pos)
    return send(server,
        PrepareRenameResponse(;
            id = msg.id,
            result = @something(
                local_binding_rename_preparation(state, uri, fi, pos, mod),
                global_binding_rename_preparation(state, uri, fi, pos, mod),
                file_rename_preparation(state, uri, fi, pos),
                null)))
end

function local_binding_rename_preparation(
        state::ServerState, uri::URI, fi::FileInfo, pos::Position, mod::Module
    )
    st0_top = build_syntax_tree(fi)
    offset = xy_to_offset(fi, pos)

    (; ctx3, binding) = @something begin
        _select_target_binding(st0_top, offset, mod; caller="local_binding_rename_preparation")
    end return nothing

    binfo = JL.get_binding(ctx3, binding)
    if is_local_binding(binfo)
        range, _ = unadjust_range(state, uri, jsobj_to_range(binding, fi))
        return (; range, placeholder = binfo.name)
    else
        return nothing
    end
end

function global_binding_rename_preparation(
        state::ServerState, uri::URI, fi::FileInfo, pos::Position, mod::Module
    )
    st0_top = build_syntax_tree(fi)
    offset = xy_to_offset(fi, pos)

    (; ctx3, binding) = @something begin
        _select_target_binding(st0_top, offset, mod; caller="global_binding_rename_preparation")
    end return nothing

    binfo = JL.get_binding(ctx3, binding)
    if binfo.kind === :global
        ismacro = startswith(binfo.name, '@')
        is_macro_use = ismacro && is_macrocall_use_site(fi, binding)
        adjust_first = is_macro_use ? 1 : 0
        range, _ = unadjust_range(state, uri, jsobj_to_range(binding, fi; adjust_first))
        placeholder = ismacro ? String(lstrip(binfo.name, '@')) : binfo.name
        return (; range, placeholder)
    else
        return nothing
    end
end

function file_rename_preparation(
        state::ServerState, uri::URI, fi::FileInfo, pos::Position,
    )
    st0_top = build_syntax_tree(fi)
    offset = xy_to_offset(fi, pos)

    string_node = @something begin
        select_target_string(st0_top, offset)
    end return nothing

    JS.hasattr(string_node, :value) || return nothing
    str = string_node.value
    ispath(joinpath(dirname(uri2filename(uri)), str)) || return nothing
    range, _ = unadjust_range(state, uri, jsobj_to_range(string_node, fi))
    return (; range, placeholder = str)
end

function handle_RenameRequest(
        server::Server, msg::RenameRequest, cancel_flag::CancelFlag)
    state = server.state
    uri = msg.params.textDocument.uri
    pos = adjust_position(state, uri, msg.params.position)
    newName = msg.params.newName

    result = get_file_info(state, uri, cancel_flag)
    if isnothing(result)
        return send(server, RenameResponse(; id = msg.id, result = null))
    elseif result isa ResponseError
        return send(server, RenameResponse(; id = msg.id, result = nothing, error = result))
    end
    fi = result

    workDoneToken = msg.params.workDoneToken
    if workDoneToken !== nothing
        do_rename(server, uri, fi, pos, newName, msg.id, cancel_flag; token = workDoneToken)
    elseif supports(server, :window, :workDoneProgress)
        id = String(gensym(:WorkDoneProgressCreateRequest_rename))
        token = String(gensym(:RenameProgress))
        addrequest!(server, id => RenameProgressCaller(uri, fi, pos, newName, msg.id, token, cancel_flag))
        params = WorkDoneProgressCreateParams(; token)
        send(server, WorkDoneProgressCreateRequest(; id, params))
    else
        do_rename(server, uri, fi, pos, newName, msg.id, cancel_flag)
    end

    return nothing
end

function handle_rename_progress_response(
        server::Server, msg::Dict{Symbol,Any}, request_caller::RenameProgressCaller,
        progress_cancel_flag::CancelFlag)
    if handle_response_error(server, msg, "create work done progress")
        return
    end
    (; uri, fi, pos, newName, msg_id, token, cancel_flag) = request_caller
    combined_flag = CombinedCancelFlag(cancel_flag, progress_cancel_flag)
    do_rename(server, uri, fi, pos, newName, msg_id, combined_flag; token)
end

function do_rename(
        server::Server, uri::URI, fi::FileInfo, pos::Position,
        newName::String, msg_id::MessageId, cancel_flag::AbstractCancelFlag;
        token::Union{Nothing,ProgressToken} = nothing)
    (; result, error) = rename(server, uri, fi, pos, newName; token, cancel_flag)
    return send(server, RenameResponse(; id = msg_id, result, error))
end

function rename(
        server::Server, uri::URI, fi::FileInfo, pos::Position, newName::String;
        token::Union{Nothing,ProgressToken} = nothing,
        cancel_flag::AbstractCancelFlag = DUMMY_CANCEL_FLAG)
    (; mod) = get_context_info(server.state, uri, pos)
    return @something(
        local_binding_rename(server, uri, fi, pos, mod, newName),
        global_binding_rename(server, uri, fi, pos, mod, newName; token, cancel_flag),
        file_rename(server, uri, fi, pos, newName),
        (; result = null, error = nothing))
end

function local_binding_rename(
        server::Server, uri::URI, fi::FileInfo, pos::Position, mod::Module, newName::String
    )
    state = server.state
    st0_top = build_syntax_tree(fi)
    offset = xy_to_offset(fi, pos)

    (; ctx3, st3, binding) = @something begin
        _select_target_binding(st0_top, offset, mod; caller="local_binding_rename")
    end return nothing

    binfo = JL.get_binding(ctx3, binding)
    is_local_binding(binfo) || return nothing
    if !Base.isidentifier(newName)
        error = ResponseError(;
            code = ErrorCodes.RequestFailed,
            message = "This variable name cannot be used. Change the name or use var\"...\" syntax.")
        pt = @something(
            prev_nontrivia(fi.parsed_stream, JS.first_byte(binding); strict=true),
            return (; result = nothing, error))
        ppt = @something prev_tok(pt) return (; result = nothing, error)
        if !(JS.kind(pt) === JS.K"\"" && JS.kind(ppt) === JS.K"var")
            return (; result = nothing, error)
        end
    end

    binding_occurrences = compute_binding_occurrences(ctx3, st3)
    haskey(binding_occurrences, binfo) ||
        return (; result = nothing,
            error = ResponseError(;
                code = ErrorCodes.RequestFailed,
                message = "Could not compute information for this local binding."))
    rename_ranges = Set{Range}()
    for occurrence in binding_occurrences[binfo]
        range, _ = unadjust_range(state, uri, jsobj_to_range(occurrence.tree, fi))
        push!(rename_ranges, range)
    end
    edits = TextEdit[TextEdit(; range, newText = newName) for range in rename_ranges]

    if supports(server, :workspace, :workspaceEdit, :documentChanges)
        textDocument = OptionalVersionedTextDocumentIdentifier(; uri, fi.version)
        result = WorkspaceEdit(; documentChanges = TextDocumentEdit[TextDocumentEdit(; textDocument, edits)])
    else
        result = WorkspaceEdit(; changes = Dict(uri => edits))
    end

    return (; result, error = nothing)
end

function global_binding_rename(
        server::Server, uri::URI, fi::FileInfo, pos::Position, mod::Module, newName::String;
        token::Union{Nothing,ProgressToken} = nothing,
        cancel_flag::AbstractCancelFlag = DUMMY_CANCEL_FLAG
    )
    st0_top = build_syntax_tree(fi)
    offset = xy_to_offset(fi, pos)

    (; ctx3, binding) = @something begin
        _select_target_binding(st0_top, offset, mod; caller="global_binding_rename")
    end return nothing

    binfo = JL.get_binding(ctx3, binding)
    binfo.kind === :global || return nothing

    if startswith(binfo.name, '@') && startswith(newName, '@')
        newName = String(lstrip(newName, '@'))
    end

    if !Base.isidentifier(newName)
        error = ResponseError(;
            code = ErrorCodes.RequestFailed,
            message = "This variable name cannot be used. Change the name or use var\"...\" syntax.")
        pt = @something(
            prev_nontrivia(fi.parsed_stream, JS.first_byte(binding); strict=true),
            return (; result = nothing, error))
        ppt = @something prev_tok(pt) return (; result = nothing, error)
        if !(JS.kind(pt) === JS.K"\"" && JS.kind(ppt) === JS.K"var")
            return (; result = nothing, error)
        end
    end

    uris_to_search = collect_search_uris(server, uri)
    if token !== nothing
        send_progress(server, token,
            WorkDoneProgressBegin(; title = "Renaming symbol", cancellable = true, percentage = 0))
    end
    if supports(server, :workspace, :workspaceEdit, :documentChanges)
        changes = TextDocumentEdit[]
    else
        changes = Dict{URI,Vector{TextEdit}}()
    end
    local completed = errored = false
    try
        completed = collect_global_rename_edits!(
            changes, server, uris_to_search, binfo, newName, cancel_flag, token)
    catch err
        @error "Error in `global_binding_rename`"
        Base.display_error(stderr, err, catch_backtrace())
        errored = true
    finally
        if token !== nothing
            send_progress(server, token,
                WorkDoneProgressEnd(;
                    message = errored ? "Failed renaming symbol" :
                        !completed ? "Cancelled renaming symbol" :
                        "Completed renaming symbol"))
        end
    end
    if errored
        return (; result = nothing, error = request_failed_error("global_binding_rename failed"))
    elseif !completed
        return (; result = nothing, error = request_cancelled_error("global_binding_rename cancelled"))
    end
    if changes isa Vector{TextDocumentEdit}
        result = WorkspaceEdit(; documentChanges = changes)
    else
        result = WorkspaceEdit(; changes)
    end
    return (; result, error = nothing)
end

function collect_global_rename_edits!(
        changes::Union{Vector{TextDocumentEdit},Dict{URI,Vector{TextEdit}}},
        server::Server, uris_to_search::Set{URI}, binfo::JL.BindingInfo, newName::String,
        cancel_flag::AbstractCancelFlag, token::Union{Nothing,ProgressToken}
    )
    state = server.state
    n_files = length(uris_to_search)
    seen_ranges = Set{Range}()
    for (i, uri) in enumerate(uris_to_search)
        if is_cancelled(cancel_flag)
            return false
        end

        if token !== nothing
            percentage = round(Int, 100 * (i - 1) / n_files)
            message = "Searching $(basename(uri2filename(uri))) ($i/$n_files)"
            send_progress(server, token,
                WorkDoneProgressReport(; cancellable = true, message, percentage))
        end

        fi = get_file_info(state, uri)
        if fi === nothing
            fi = get_unsynced_file_info!(server.state, uri)
            fi === nothing && continue
            version = null
        else
            version = fi.version
        end
        search_st0_top = build_syntax_tree(fi)
        empty!(seen_ranges)
        collect_global_rename_ranges_in_file!(
            seen_ranges, state, uri, fi, search_st0_top, binfo)

        if !isempty(seen_ranges)
            edits = TextEdit[TextEdit(; range, newText = newName) for range in seen_ranges]
            if changes isa Vector{TextDocumentEdit}
                textDocument = OptionalVersionedTextDocumentIdentifier(; uri, version)
                push!(changes, TextDocumentEdit(; textDocument, edits))
            else
                changes[uri] = edits
            end
        end
    end
    return true
end

function collect_global_rename_ranges_in_file!(
        seen_ranges::Set{Range}, state::ServerState, uri::URI, fi::FileInfo,
        st0_top::JS.SyntaxTree, binfo::JL.BindingInfo
    )
    ismacro = startswith(binfo.name, '@')
    for occurrence in find_global_binding_occurrences!(state, uri, fi, st0_top, binfo)
        adjust_first = ismacro && is_macrocall_use_site(fi, occurrence.tree) ? 1 : 0
        range, _ = unadjust_range(state, uri, jsobj_to_range(occurrence.tree, fi; adjust_first))
        push!(seen_ranges, range)
    end
    return seen_ranges
end

function file_rename(
        server::Server, uri::URI, fi::FileInfo, pos::Position, newName::String
    )
    state = server.state
    st0_top = build_syntax_tree(fi)
    offset = xy_to_offset(fi, pos)

    string_node = @something begin
        select_target_string(st0_top, offset)
    end return nothing

    JS.hasattr(string_node, :value) || return nothing
    oldName = string_node.value
    basedir = dirname(uri2filename(uri))
    oldPath = joinpath(basedir, oldName)
    ispath(oldPath) || return nothing
    newPath = joinpath(basedir, newName)

    oldUri = filename2uri(oldPath)
    newUri = filename2uri(newPath)
    renameFile = RenameFile(; oldUri, newUri)

    range, _ = unadjust_range(state, uri, jsobj_to_range(string_node, fi))
    textEdit = TextEdit(; range, newText = newName)

    if supports(server, :workspace, :workspaceEdit, :documentChanges)
        textDocument = OptionalVersionedTextDocumentIdentifier(; uri, fi.version)
        textDocumentEdit = TextDocumentEdit(; textDocument, edits = [textEdit])
        result = WorkspaceEdit(; documentChanges = [textDocumentEdit, renameFile])
    else
        result = WorkspaceEdit(; changes = Dict(uri => [textEdit]))
    end

    return (; result, error = nothing)
end
