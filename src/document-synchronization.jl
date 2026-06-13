function ParseStream!(s::Union{AbstractString,Vector{UInt8}})
    stream = JS.ParseStream(s)
    JS.parse!(stream; rule=:all)
    return stream
end

# Drop every per-file cache entry for `uri`. Called whenever a file's content
# changes (didChange/didOpen, notebook cell edits, watched-file events).
# Full-analysis updates invalidate semantic caches separately because not all
# per-file caches depend on module context.
function invalidate_per_file_caches!(state::ServerState, uri::URI)
    invalidate_document_symbol_cache!(state, uri)
    invalidate_binding_occurrences_cache!(state, uri)
    invalidate_per_file_diagnostics_cache!(state, uri)
end

function clear_inferred_context_cache!(state::ServerState, uri::URI)
    uri = canonical_cache_uri(state, uri)
    store!(state.file_cache) do cache
        fi = @something get(cache, uri, nothing) return cache, nothing
        fi.inferred_context_cache === nothing && return cache, nothing
        new_fi = FileInfo(fi; inferred_context_cache=InferredContextCache())
        return Base.PersistentDict(cache, uri => new_fi), nothing
    end
end

"""
    cache_file_info!(server::Server, uri::URI, version::Int, text::Union{AbstractString,Vector{UInt8}})
    cache_file_info!(server::Server, uri::URI, version::Int, parsed_stream::JS.ParseStream)

Cache or update file information in the server state's file cache.
Computes testsetinfos atomically as part of the caching operation,
preserving test results from previous testsetinfos where possible.
"""
cache_file_info!(server::Server, uri::URI, version::Int, text::Union{AbstractString,Vector{UInt8}}) =
    cache_file_info!(server, uri, version, ParseStream!(text))
function cache_file_info!(
        server::Server, uri::URI, version::Int, parsed_stream::JS.ParseStream
    )
    state = server.state
    prev_fi = get_file_info(state, uri)
    prev_testsetinfos = prev_fi === nothing ? EMPTY_TESTSETINFOS : prev_fi.testsetinfos

    filename = uri2filename(uri)
    st0 = JS.build_tree(JS.SyntaxTree, parsed_stream; filename)
    testsetinfos, any_deleted = compute_testsetinfos!(server, st0, prev_testsetinfos)

    fi = FileInfo(version, parsed_stream, filename, state.encoding, testsetinfos;
        syntax_tree0=st0, inferred_context_cache=InferredContextCache())
    store!(state.file_cache) do cache
        Base.PersistentDict(cache, uri => fi), nothing
    end

    invalidate_per_file_caches!(state, uri)

    if !state.suppress_notifications && any_deleted
        notify_diagnostics!(server; ensure_cleared=uri)
    end

    return fi
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
    sfi = SavedFileInfo(parsed_stream, uri, state.encoding)
    store!(state.saved_file_cache) do cache
        Base.PersistentDict(cache, uri => sfi), sfi
    end
end

function handle_DidOpenTextDocumentNotification(server::Server, msg::DidOpenTextDocumentNotification)
    textDocument = msg.params.textDocument
    uri = textDocument.uri
    # `jetls:` documents are server-provided, read-only virtual documents
    # (`workspace/textDocumentContent`); they carry no Julia source, so skip the
    # Julia-only path below. Record that the view is open so subsequent content
    # updates refresh it.
    is_text_document_content_uri(uri) &&
        return mark_text_document_content_opened!(server, uri)
    @assert textDocument.languageId == "julia"
    parsed_stream = ParseStream!(textDocument.text)
    cache_file_info!(server, uri, textDocument.version, parsed_stream)
    cache_saved_file_info!(server.state, uri, parsed_stream)
    invalidate_unsynced_file_cache!(server.state, uri)
    request_analysis!(server, uri, #=invalidate=#false)
end

function handle_DidChangeTextDocumentNotification(server::Server, msg::DidChangeTextDocumentNotification)
    (; textDocument, contentChanges) = msg.params
    uri = textDocument.uri
    # Read-only `jetls:` virtual documents never carry user edits to sync (see
    # `handle_DidOpenTextDocumentNotification`).
    is_text_document_content_uri(uri) && return nothing
    for contentChange in contentChanges
        @assert contentChange.range === contentChange.rangeLength === nothing # since `change = TextDocumentSyncKind.Full`
    end
    text = last(contentChanges).text
    cache_file_info!(server, uri, textDocument.version, text)
    # Unsaved buffers (untitled: scheme) never receive didSave, so trigger analysis
    # on every content change with a longer debounce to avoid excessive re-analysis.
    isunsaveduri(uri) && request_analysis!(server, uri, #=invalidate=#true; debounce=3.0)
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
    request_analysis!(server, uri, #=invalidate=#true)
end

function handle_DidCloseTextDocumentNotification(server::Server, msg::DidCloseTextDocumentNotification)
    uri = msg.params.textDocument.uri
    # `jetls:` virtual documents are never tracked in the Julia caches (see
    # `handle_DidOpenTextDocumentNotification`), so skip the file-backed cleanup;
    # just record that the view closed so we stop refreshing it.
    is_text_document_content_uri(uri) &&
        return mark_text_document_content_closed!(server, uri)
    store!(server.state.file_cache) do cache
        Base.delete(cache, uri), nothing
    end
    store!(server.state.saved_file_cache) do cache
        Base.delete(cache, uri), nothing
    end
    # Extra diagnostics should only be published for open files
    clear_extra_diagnostics!(server, uri)
    # Republish textDocument/publishDiagnostics for cases with `diagnostic.all_files === false`,
    # where diagnostics for this file must be suppressed.
    # This must run before `cleanup_analysis_state!` below, since the suppression
    # branch in `notify_diagnostics!` only emits the clearing notification when the
    # analysis cache still reports non-empty diagnostics for this URI.
    notify_diagnostics!(server; ensure_cleared=uri)
    if isunsaveduri(uri)
        cleanup_analysis_state!(server, uri)
    end
    # Retrigger workspace/diagnostic to recalculate diagnostics for this closed file
    request_diagnostic_refresh!(server)
end
