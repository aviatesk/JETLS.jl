const WORKSPACE_SYMBOL_REGISTRATION_ID = "jetls-workspace-symbol"
const WORKSPACE_SYMBOL_REGISTRATION_METHOD = "workspace/symbol"

struct WorkspaceSymbolProgressCaller <: RequestCaller
    msg_id::MessageId
    params::WorkspaceSymbolParams
    token::ProgressToken
    cancel_flag::CancelFlag
end
cancellable_token(caller::WorkspaceSymbolProgressCaller) = caller.token

function workspace_symbol_options(server::Server)
    return WorkspaceSymbolOptions(;
        workDoneProgress = supports(server, :window, :workDoneProgress))
end

function workspace_symbol_registration(server::Server)
    return Registration(;
        id = WORKSPACE_SYMBOL_REGISTRATION_ID,
        method = WORKSPACE_SYMBOL_REGISTRATION_METHOD,
        registerOptions = WorkspaceSymbolRegistrationOptions(;
            workDoneProgress = supports(server, :window, :workDoneProgress)))
end

# For dynamic registrations during development
# unregister(currently_running, Unregistration(;
#     id = WORKSPACE_SYMBOL_REGISTRATION_ID,
#     method = WORKSPACE_SYMBOL_REGISTRATION_METHOD))
# register(currently_running, workspace_symbol_registration(currently_running))

function handle_WorkspaceSymbolRequest(
        server::Server, msg::WorkspaceSymbolRequest, cancel_flag::CancelFlag)
    params = msg.params
    token = params.workDoneToken
    if token !== nothing
        do_workspace_symbol(server, msg.id, params; token, cancel_flag)
    elseif supports(server, :window, :workDoneProgress)
        id = String(gensym(:WorkDoneProgressCreateRequest_workspace_symbol))
        token = String(gensym(:WorkspaceSymbolProgress))
        addrequest!(server, id => WorkspaceSymbolProgressCaller(msg.id, params, token, cancel_flag))
        send(server, WorkDoneProgressCreateRequest(; id, params = WorkDoneProgressCreateParams(; token)))
    else
        do_workspace_symbol(server, msg.id, params; cancel_flag)
    end
    return nothing
end

function handle_workspace_symbol_progress_response(
        server::Server, msg::Dict{Symbol,Any},
        request_caller::WorkspaceSymbolProgressCaller, progress_cancel_flag::CancelFlag)
    if handle_response_error(server, msg, "create work done progress")
        return
    end
    (; msg_id, params, token, cancel_flag) = request_caller
    combined_flag = CombinedCancelFlag(cancel_flag, progress_cancel_flag)
    do_workspace_symbol(server, msg_id, params; token, cancel_flag=combined_flag)
end

function do_workspace_symbol(
        server::Server, msg_id::MessageId, params::WorkspaceSymbolParams;
        kwargs...)
    symbols = workspace_symbol(server, params; kwargs...)
    if symbols isa ResponseError
        return send(server, WorkspaceSymbolResponse(; id = msg_id, result = nothing, error = request_cancelled_error()))
    else
        return send(server, WorkspaceSymbolResponse(; id = msg_id, result = symbols))
    end
end

function workspace_symbol(
        server::Server, params::WorkspaceSymbolParams;
        token::Union{Nothing,ProgressToken} = nothing,
        kwargs...
    )
    symbols = WorkspaceSymbol[]
    uris_to_search = collect(collect_workspace_uris(server))
    if token !== nothing
        send_progress(server, token,
            WorkDoneProgressBegin(;
                title = "Collecting workspace symbols",
                cancellable = true,
                percentage = 0))
    end
    local errored = completed = false
    try
        completed = collect_symbols_from_files!(symbols, server, uris_to_search, params; token, kwargs...)
    catch err
        @error "Error in `workspace_symbol`"
        Base.display_error(stderr, err, catch_backtrace())
        errored = true
    finally
        if token !== nothing
            send_progress(server, token,
                WorkDoneProgressEnd(;
                    message = errored ? "Failed collecting Workspace symbols" :
                        !completed ? "Cancelled collecting Workspace symbols" :
                        "Found $(length(symbols)) symbols"))
        end
    end
    if errored
        request_failed_error("workspace_symbol failed")
    elseif !completed
        request_cancelled_error("workspace_symbol cancelled")
    else
        return symbols
    end
end

function collect_symbols_from_files!(
        symbols::Vector{WorkspaceSymbol}, server::Server, uris::Vector{URI},
        _params::WorkspaceSymbolParams;
        token::Union{Nothing,ProgressToken} = nothing,
        cancel_flag::AbstractCancelFlag = DUMMY_CANCEL_FLAG
    )
    state = server.state
    n_files = length(uris)
    for (i, uri) in enumerate(uris)
        if is_cancelled(cancel_flag)
            # @info "Cancelled" _params.query
            return false
        end
        if token !== nothing
            percentage = round(Int, 100 * (i - 1) / n_files)
            message = "Searching $(basename(uri2filename(uri))) ($i/$n_files)"
            send_progress(server, token,
                WorkDoneProgressReport(; cancellable = true, message, percentage))
        end
        collect_symbols_from_file!(symbols, state, uri)
    end
    return true
end

function collect_symbols_from_file!(
        symbols::Vector{WorkspaceSymbol}, state::ServerState, uri::URI)
    fi = @something get_file_info(state, uri) get_unsynced_file_info(state, uri) return
    doc_symbols = get_document_symbols!(state, uri, fi)
    flatten_document_symbols!(symbols, doc_symbols, state, uri)
end

function flatten_document_symbols!(
        workspace_symbols::Vector{WorkspaceSymbol}, doc_symbols::Vector{DocumentSymbol},
        state::ServerState, uri::URI
    )
    notebook_info = get_notebook_info(state, uri)
    flatten_document_symbols!(workspace_symbols, doc_symbols, uri, notebook_info)
end

function flatten_document_symbols!(
        workspace_symbols::Vector{WorkspaceSymbol}, doc_symbols::Vector{DocumentSymbol},
        uri::URI, notebook_info::Union{Nothing,NotebookInfo};
        parent_detail::Union{Nothing,String} = nothing
    )
    for doc_sym in doc_symbols
        location = if notebook_info !== nothing
            result = global_to_cell_range(notebook_info.concat, doc_sym.range)
            result === nothing ? nothing : Location(; uri = result[1], range = result[2])
        else
            nothing
        end
        if location === nothing
            location = Location(; uri, range = doc_sym.range)
        end
        if (doc_sym.kind == SymbolKind.Object || # this means "argument" (see document-symbol.jl)
            doc_sym.kind == SymbolKind.Field)
            push!(workspace_symbols, WorkspaceSymbol(;
                name = doc_sym.name,
                kind = doc_sym.kind,
                location,
                containerName = parent_detail))
        else
            push!(workspace_symbols, WorkspaceSymbol(;
                name = doc_sym.name,
                kind = doc_sym.kind,
                location,
                containerName = doc_sym.detail))
        end
        children = doc_sym.children
        if children !== nothing
            flatten_document_symbols!(workspace_symbols, children, uri, notebook_info;
                parent_detail = doc_sym.detail)
        end
    end
end
