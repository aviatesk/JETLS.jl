"""
    clear_file_info_cache!(fi::Union{FileInfo,SavedFileInfo})

Clear the cached syntax node and syntax tree from the given file info object.
This should be called when the underlying parsed stream is updated to ensure
that stale cached representations are removed.
"""
function clear_file_info_cache!(fi::Union{FileInfo,SavedFileInfo})
    empty!(fi.syntax_node)
    empty!(fi.syntax_tree0)
    return fi
end

function cleanup_file_info!(fi::FileInfo)
    clear_file_info_cache!(fi)
    empty!(fi.testsetinfos)
end
cleanup_file_info!(fi::SavedFileInfo) = clear_file_info_cache!(fi)

"""
    build_tree!(::Type{JS.SyntaxNode}, fi::Union{FileInfo,SavedFileInfo}; kwargs...)

Build and cache a `JS.SyntaxNode` for the given file info object.
Returns the cached syntax node if it already exists, otherwise builds a new one
from the parsed stream and caches it.
The cache is separated by `kwargs`.
"""
function build_tree!(::Type{JS.SyntaxNode}, fi::Union{FileInfo,SavedFileInfo}; kwargs...)
    return get!(fi.syntax_node, kwargs) do
        JS.build_tree(JS.SyntaxNode, fi.parsed_stream; kwargs...)
    end
end

"""
    build_tree!(::Type{JL.SyntaxTree}, fi::Union{FileInfo,SavedFileInfo}; kwargs...)

Build and cache a `JL.SyntaxTree` for the given file info object.
Returns the cached syntax tree if it already exists, otherwise builds a new one
from the parsed stream and caches it.
The cache is separated by `kwargs`.
"""
function build_tree!(::Type{JL.SyntaxTree}, fi::Union{FileInfo,SavedFileInfo}; kwargs...)
    return get!(fi.syntax_tree0, kwargs) do
        JS.build_tree(JL.SyntaxTree, fi.parsed_stream; kwargs...)
    end
end

function ParseStream!(s::AbstractString)
    stream = JS.ParseStream(s)
    JS.parse!(stream; rule=:all)
    return stream
end

"""
    cache_file_info!(state::ServerState, uri::URI, version::Int, text::String)
    cache_file_info!(state::ServerState, uri::URI, version::Int, parsed_stream::JS.ParseStream)

Cache or update file information in the server state's file cache.
If the file already exists in the cache, updates its version and parsed stream,
then clears any cached syntax representations. Otherwise, creates a new `FileInfo`
entry in the cache.
"""
cache_file_info!(state::ServerState, uri::URI, version::Int, text::String) =
    cache_file_info!(state, uri, version, ParseStream!(text))
function cache_file_info!(state::ServerState, uri::URI, version::Int, parsed_stream::JS.ParseStream)
    if haskey(state.file_cache, uri)
        fi = state.file_cache[uri]
        fi.version = version
        fi.parsed_stream = parsed_stream
        return clear_file_info_cache!(fi)
    else
        return state.file_cache[uri] = FileInfo(version, parsed_stream)
    end
end

"""
    cache_saved_file_info!(state::ServerState, uri::URI, text::String)
    cache_saved_file_info!(state::ServerState, uri::URI, parsed_stream::JS.ParseStream)

Cache or update saved file information in the server state's saved file cache.
This is used to track the last saved state of a file. If the file already exists
in the cache, updates its parsed stream and clears cached syntax representations.
Otherwise, creates a new `SavedFileInfo` entry in the cache.
"""
cache_saved_file_info!(state::ServerState, uri::URI, text::String) =
    cache_saved_file_info!(state, uri, ParseStream!(text))
function cache_saved_file_info!(state::ServerState, uri::URI, parsed_stream::JS.ParseStream)
    if haskey(state.saved_file_cache, uri)
        fi = state.saved_file_cache[uri]
        fi.parsed_stream = parsed_stream
        return clear_file_info_cache!(fi)
    else
        return state.saved_file_cache[uri] = SavedFileInfo(parsed_stream)
    end
end

function handle_DidOpenTextDocumentNotification(server::Server, msg::DidOpenTextDocumentNotification)
    textDocument = msg.params.textDocument
    @assert textDocument.languageId == "julia"
    uri = textDocument.uri

    parsed_stream = ParseStream!(textDocument.text)
    cache_file_info!(server.state, uri, textDocument.version, parsed_stream)
    cache_saved_file_info!(server.state, uri, parsed_stream)

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
    fi = cache_file_info!(server.state, uri, textDocument.version, text)
    update_testsetinfos!(server, fi)
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
    uri = msg.params.textDocument.uri
    fi = get(server.state.file_cache, uri, nothing)
    if !isnothing(fi)
        delete!(server.state.file_cache, fi)
        if clear_extra_diagnostics!(server, fi)
            notify_diagnostics!(server)
        end
        cleanup_file_info!(fi)
    end
    sfi = get(server.state.saved_file_cache, uri, nothing)
    if !isnothing(sfi)
        delete!(server.state.saved_file_cache, fi)
        cleanup_file_info!(sfi)
    end
    nothing
end
