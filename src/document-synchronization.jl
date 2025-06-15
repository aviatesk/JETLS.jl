function ParseStream!(s::AbstractString)
    stream = JS.ParseStream(s)
    JS.parse!(stream; rule=:all)
    return stream
end
function FileInfo(version::Int, text::String)
    return FileInfo(version, ParseStream!(text))
end
function SavedFileInfo(text::String)
    return SavedFileInfo(ParseStream!(text))
end

function cache_file_info!(state::ServerState, uri::URI, version::Int, text::String)
    return cache_file_info!(state, uri, FileInfo(version, text))
end
function cache_file_info!(state::ServerState, uri::URI, file_info::FileInfo)
    return state.file_cache[uri] = file_info
end

function cache_saved_file_info!(state::ServerState, uri::URI, text::String)
    return cache_saved_file_info!(state, uri, SavedFileInfo(text))
end
function cache_saved_file_info!(state::ServerState, uri::URI, file_info::SavedFileInfo)
    return state.saved_file_cache[uri] = file_info
end

function handle_DidOpenTextDocumentNotification(server::Server, msg::DidOpenTextDocumentNotification)
    textDocument = msg.params.textDocument
    @assert textDocument.languageId == "julia"
    uri = textDocument.uri

    parsed_stream = ParseStream!(textDocument.text)
    cache_file_info!(server.state, uri, FileInfo(textDocument.version, parsed_stream))
    cache_saved_file_info!(server.state, uri, SavedFileInfo(parsed_stream))

    if supports(server, :window, :workDoneProgress)
        id = String(gensym(:WorkDoneProgressCreateRequest_run_full_analysis!))
        token = String(gensym(:WorkDoneProgressCreateRequest_run_full_analysis!))
        server.state.currently_requested[id] = RunFullAnalysisCaller(uri, #=onsave=#false, token)
        send(server,
            WorkDoneProgressCreateRequest(;
                id,
                params = WorkDoneProgressCreateParams(;
                    token = token)))
    else
        run_full_analysis!(server, uri)
    end
end

function handle_DidChangeTextDocumentNotification(server::Server, msg::DidChangeTextDocumentNotification)
    (; textDocument, contentChanges) = msg.params
    uri = textDocument.uri
    for contentChange in contentChanges
        @assert contentChange.range === contentChange.rangeLength === nothing # since `change = TextDocumentSyncKind.Full`
    end
    text = last(contentChanges).text

    cache_file_info!(server.state, uri, textDocument.version, text)
end

function handle_DidSaveTextDocumentNotification(server::Server, msg::DidSaveTextDocumentNotification)
    uri = msg.params.textDocument.uri
    if !haskey(server.state.saved_file_cache, uri)
        # Some language client implementations (in this case Zed) appear to be
        # sending `textDocument/didSave` notifications for arbitrary text documents,
        # so we add a save guard for such cases.
        JETLS_DEV_MODE && @warn "Received textDocument/didSave for unopened or unsupported document" uri
        return nothing
    end
    text = msg.params.text
    if !(text isa String)
        @warn """
        The client is not respecting the `capabilities.textDocumentSync.save.includeText`
        option specified by this server during initialization. Without the document text
        content in save notifications, the diagnostics feature cannot function properly.
        """
        return nothing
    end
    cache_saved_file_info!(server.state, uri, text)

    if supports(server, :window, :workDoneProgress)
        id = String(gensym(:WorkDoneProgressCreateRequest_run_full_analysis!))
        token = String(gensym(:WorkDoneProgressCreateRequest_run_full_analysis!))
        server.state.currently_requested[id] = RunFullAnalysisCaller(uri, #=onsave=#true, token)
        send(server,
            WorkDoneProgressCreateRequest(;
                id,
                params = WorkDoneProgressCreateParams(;
                    token = token)))
    else
        run_full_analysis!(server, uri; onsave=true)
    end
end

function handle_DidCloseTextDocumentNotification(server::Server, msg::DidCloseTextDocumentNotification)
    delete!(server.state.file_cache, msg.params.textDocument.uri)
    delete!(server.state.saved_file_cache, msg.params.textDocument.uri)
    nothing
end
