function ParseStream!(s::Union{AbstractString,Vector{UInt8}})
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
    fi = FileInfo(version, parsed_stream, uri, state.encoding)
    return store!(state.file_cache) do cache
        Base.PersistentDict(cache, uri => fi), fi
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
    sfi = SavedFileInfo(parsed_stream, uri)
    store!(state.saved_file_cache) do cache
        Base.PersistentDict(cache, uri => sfi), sfi
    end
end

function handle_DidOpenTextDocumentNotification(server::Server, msg::DidOpenTextDocumentNotification)
    textDocument = msg.params.textDocument
    @assert textDocument.languageId == "julia"
    uri = textDocument.uri

    parsed_stream = ParseStream!(textDocument.text)
    fi = cache_file_info!(server.state, uri, textDocument.version, parsed_stream)
    update_testsetinfos!(server, uri, fi)
    cache_saved_file_info!(server.state, uri, parsed_stream)

    request_analysis_on_open!(server, uri)
end

function handle_DidChangeTextDocumentNotification(server::Server, msg::DidChangeTextDocumentNotification)
    (; textDocument, contentChanges) = msg.params
    uri = textDocument.uri
    for contentChange in contentChanges
        @assert contentChange.range === contentChange.rangeLength === nothing # since `change = TextDocumentSyncKind.Full`
    end
    text = last(contentChanges).text
    fi = cache_file_info!(server.state, uri, textDocument.version, text)
    update_testsetinfos!(server, uri, fi)
end

function handle_DidSaveTextDocumentNotification(server::Server, msg::DidSaveTextDocumentNotification)
    uri = msg.params.textDocument.uri
    cache = load(server.state.saved_file_cache)
    if !haskey(cache, uri)
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

    request_analysis_on_save!(server, uri)
end

function handle_DidCloseTextDocumentNotification(server::Server, msg::DidCloseTextDocumentNotification)
    uri = msg.params.textDocument.uri

    store!(server.state.file_cache) do cache
        Base.delete(cache, uri), nothing
    end
    store!(server.state.saved_file_cache) do cache
        Base.delete(cache, uri), nothing
    end
    store!(server.state.testsetinfos_cache) do cache
        Base.delete(cache, uri), nothing
    end
    if clear_extra_diagnostics!(server, uri)
        notify_diagnostics!(server)
    end

    nothing
end
