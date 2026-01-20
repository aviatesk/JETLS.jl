# server interaction utilities
# ===========================

const DEFAULT_FLUSH_INTERVAL = 0.05
function yield_to_endpoint(interval=DEFAULT_FLUSH_INTERVAL)
    # HACK: allow LSP endpoint to process queued messages (e.g. work done progress report)
    yield()
    sleep(interval)
end

"""
    send(server::Server, msg)

Send a message to the client through the `server.state.endpoint`.

This function is used by each handler that processes messages sent from the client,
as well as for sending requests and notifications from the server to the client.
"""
function send(server::Server, @nospecialize msg)
    LSP.Communication.send(server.endpoint, msg)
    server.callback !== nothing && server.callback(:sent, msg)
    # Mark request as handled when sending a response
    if isdefined(msg, :id) && isdefined(msg, :result) && isdefined(msg, :error) # i.e. msg isa ResponseMessage
        put!(server.message_queue, HandledToken(msg.id::MessageId))
    end
    nothing
end

"""
    addrequest!(server::Server, id=>caller)
    addrequest!(server::Server, id::String, caller::RequestCaller)

Register a `RequestCaller` for tracking an outgoing request from the server to the client.

When the server sends a request to the client (e.g., `window/workDoneProgress/create`,
`window/showMessageRequest`, `workspace/applyEdit`), it needs to track which handler
should process the client's response. This function associates a unique request ID with
a `RequestCaller` subtype that encapsulates the context needed to handle the response.

# Arguments
- `server::Server`: The language server instance
- `id::String`: A unique identifier for the request (typically generated with `gensym`)
- `caller::RequestCaller`: An instance of a `RequestCaller` subtype containing the
  context information needed to handle the client's response

# Example
```julia
# When creating a progress token
id = String(gensym(:WorkDoneProgressCreateRequest_formatting))
token = String(gensym(:FormattingProgress))
caller = FormattingProgressCaller(uri, msg.id, token)
addrequest!(server, id=>caller)
send(server, WorkDoneProgressCreateRequest(; id, params))
```

# See also
- [`poprequest!`](@ref) - Retrieve and remove a registered `RequestCaller` when handling the response
- [`handle_ResponseMessage`](@ref) - The main handler that uses these request callers
"""
addrequest!(server::Server, (id, caller)) = addrequest!(server, id, caller)
function addrequest!(server::Server, id::String, caller::RequestCaller)
    return store!(server.state.currently_requested) do data
        Base.PersistentDict(data, id => caller), caller
    end
end

"""
    poprequest!(server::Server, id) -> Union{Nothing,RequestCaller}

Retrieve and remove a registered `RequestCaller` for a completed request.

When the client sends a response to a server-initiated request, this function retrieves
the associated `RequestCaller` that contains the context needed to handle the response.
The caller is removed from the tracking dictionary after retrieval.

# Arguments
- `server::Server`: The language server instance
- `id`: The unique identifier of the request (typically a `String` or `nothing`)

# Returns
- The `RequestCaller` instance if found, or `nothing` if no matching request exists

# Example
```julia
# In handle_ResponseMessage
request_caller = @something poprequest!(server, get(msg, :id, nothing)) return false
handle_requested_response(server, msg, request_caller)
```

# See also
- [`addrequest!`](@ref) - Register a `RequestCaller` when sending a request to the client
- [`handle_ResponseMessage`](@ref) - The main handler that processes client responses
"""
function poprequest!(server::Server, @nospecialize id)
    id isa String || return nothing
    return store!(server.state.currently_requested) do data
        if haskey(data, id)
            caller = data[id]
            return Base.delete(data, id), caller
        end
        return data, nothing
    end
end

"""
    supports(server::Server, paths::Symbol...) -> Bool
    supports(state::ServerState, paths::Symbol...) -> Bool

Check if the client supports a specific capability.

# Arguments
- `server::Server` or `state::ServerState`: The server or state containing client capabilities
- `paths::Symbol...`: Path of symbols to traverse in the client capabilities object

# Returns
`true` if the capability exists and is explicitly set to `true`, `false` otherwise.

# Examples
```julia
supports(server, :textDocument, :completion, :completionItem, :snippetSupport)
supports(state, :textDocument, :synchronization, :dynamicRegistration)
```

# See also
[`getcapability`](@ref) - Get the actual capability value instead of just checking if it's true
"""
supports(args...) = getcapability(args...) === true

"""
    getcapability(server::Server, paths::Symbol...) -> capability
    getcapability(state::ServerState, paths::Symbol...) -> capability

Get a client capability value by traversing the capability object hierarchy.

# Arguments
- `server::Server` or `state::ServerState`: The server or state containing client capabilities
- `paths::Symbol...`: Path of symbols to traverse in the client capabilities object

# Returns
The capability value at the specified path, or `nothing` if not found.

# Examples
```julia
getcapability(server, :textDocument, :completion, :completionItem, :snippetSupport)
getcapability(state, :general, :positionEncodings)
```

# See also
[`supports`](@ref) - Check if a capability is explicitly set to `true`
"""
getcapability(server::Server, paths::Symbol...) = getcapability(server.state, paths...)
function getcapability(state::ServerState, paths::Symbol...)
    return isdefined(state, :init_params) &&
        getobjpath(state.init_params.capabilities, paths...)
end

"""
    get_file_info(s::ServerState, uri::URI) -> Union{Nothing,FileInfo}

Fetch cached `FileInfo` immediately without waiting. Returns `nothing` if unavailable.

Use this version only when waiting for cache is not necessary, e.g.: for formatting,
if the file was closed, failing fast is appropriate rather than waiting for cache that
might have already gone.

For most request handlers, prefer the 3-argument version which waits for cache population.
"""
get_file_info(s::ServerState, uri::URI) = get(load(s.file_cache), uri, nothing)
get_file_info(s::ServerState, t::TextDocumentIdentifier) = get_file_info(s, t.uri)

"""
    get_file_info(
        s::ServerState, uri::URI, cancel_flag::AbstractCancelFlag;
        timeout = 10., cancelled_error_data = nothing
    ) -> Union{FileInfo,ResponseError,Nothing}

Wait for cached `FileInfo` to become available, with cancellation and timeout support.
This is the recommended version for request handlers.

Unlike the 2-argument version which returns `nothing` immediately if the cache is not
available, this version polls until the cache is populated. This is useful for request
handlers where the file cache may not yet be ready (e.g., immediately after file open).

Returns:
- `FileInfo`: when cache is available
- `ResponseError`: when request is cancelled (`request_cancelled_error(; data=cancelled_error_data)`)
- `nothing`: when timeout is reached (file not synced via `textDocument/didOpen`)
"""
function get_file_info(
        s::ServerState, uri::URI, cancel_flag::AbstractCancelFlag;
        timeout::Float64 = 10., cancelled_error_data = nothing
    )
    start = time()
    request_id = objectid(cancel_flag) # Each request uses a unique `cancel_flag`, so this objectid can be used as a request-unique ID
    while true
        is_cancelled(cancel_flag) && return request_cancelled_error(;
            data = cancelled_error_data)
        cache = get(load(s.file_cache), uri, nothing)
        cache !== nothing && return cache
        notebook_uri = get_notebook_uri_for_cell(s, uri)
        if notebook_uri !== nothing
            cache = get(load(s.file_cache), notebook_uri, nothing)
            cache !== nothing && return cache
        end
        if time() - start > timeout
            JETLS_TEST_MODE || @warn "File cache not found" uri _id=uri maxlog=1 # Some tests intentionally call this path, so this log is probably not necessary.
            return nothing
        end
        JETLS_DEV_MODE && @info "Waiting for file cache" uri _id=request_id maxlog=1
        sleep(0.5)
    end
    return nothing
end
get_file_info(s::ServerState, t::TextDocumentIdentifier, cancel_flag::AbstractCancelFlag; kwargs...) =
    get_file_info(s, t.uri, cancel_flag; kwargs...)

"""
    get_saved_file_info(s::ServerState, uri::URI) -> fi::Union{Nothing,SavedFileInfo}
    get_saved_file_info(s::ServerState, t::TextDocumentIdentifier) -> fi::Union{Nothing,SavedFileInfo}

Fetch cached saved FileInfo given an LSclient-provided structure with a URI
"""
function get_saved_file_info(s::ServerState, uri::URI)
    cache = get(load(s.saved_file_cache), uri, nothing)
    if cache !== nothing
        return cache
    end
    notebook_uri = get_notebook_uri_for_cell(s, uri)
    if notebook_uri !== nothing
        return get(load(s.saved_file_cache), notebook_uri, nothing)
    end
    return nothing
end
get_saved_file_info(s::ServerState, t::TextDocumentIdentifier) = get_saved_file_info(s, t.uri)

"""
    get_unsynced_file_info!(state::ServerState, uri::URI) -> Union{Nothing,FileInfo}

Get `FileInfo` for a file not synced via document-synchronization.
The file may have been analyzed by full-analysis but not yet opened in the editor,
or simply be outside the active workspace scope.
Results are cached in `state.unsynced_file_cache` and invalidated via
`workspace/didChangeWatchedFiles`.
"""
function get_unsynced_file_info!(state::ServerState, uri::URI)
    cache = load(state.unsynced_file_cache)
    if haskey(cache, uri)
        return cache[uri]
    end
    return store_unsynced_file_info!(state, uri)
end

function store_unsynced_file_info!(state::ServerState, uri::URI)
    return store!(state.unsynced_file_cache) do cache::UnsyncedFileCacheData
        version = time_ns() % Int
        filename = uri2filename(uri)
        isfile(filename) || return cache, nothing
        parsed_stream = try
            ParseStream!(read(filename))
        catch e
            JETLS_DEV_MODE && @error "Error parsing file $(filename)"
            JETLS_DEV_MODE && Base.showerror(stderr, e, catch_backtrace)
            return cache, nothing
        end
        fi = FileInfo(version, parsed_stream, filename, state.encoding; cache_tree=true)
        return UnsyncedFileCacheData(cache, uri => fi), fi
    end
end

function invalidate_unsynced_file_cache!(state::ServerState, uri::URI)
    store!(state.unsynced_file_cache) do cache::UnsyncedFileCacheData
        if haskey(cache, uri)
            return Base.delete(cache, uri), nothing
        else
            return cache, nothing
        end
    end
end

is_synchronized(s::ServerState, uri::URI) = haskey(load(s.file_cache), uri)

"""
    get_context_info(state::ServerState, uri::URI, pos::Position) -> (; mod, analyzer, postprocessor)

Extract context information for a given position in a file.

Returns a named tuple containing:
- `mod::Module`: The module context at the given position
- `analyzer::LSAnalyzer`: The analyzer instance for the file
- `postprocessor::JET.PostProcessor`: The post-processor for fixing `var"..."` strings that users don't need
  to recognize, which are caused by JET implementation details
"""
function get_context_info(state::ServerState, uri::URI, pos::Position; lookup_func=nothing)
    lookup_uri = @something get_notebook_uri_for_cell(state, uri) uri
    if lookup_func !== nothing
        analysis_info = get_analysis_info(lookup_func, state.analysis_manager, lookup_uri)
    else
        analysis_info = get_analysis_info(state.analysis_manager, lookup_uri)
    end
    mod = get_context_module(analysis_info, lookup_uri, pos)
    analyzer = get_context_analyzer(analysis_info, lookup_uri)
    postprocessor = get_post_processor(analysis_info)
    return (; mod, analyzer, postprocessor)
end

get_context_module(::Nothing, ::URI, ::Position) = Main
get_context_module(oos::OutOfScope, ::URI, ::Position) = something(oos.module_context, Main)
function get_context_module(analysis_result::AnalysisResult, uri::URI, pos::Position)
    safi = @something analyzed_file_info(analysis_result, uri) return Main
    curline = Int(pos.line) + 1
    curmod = Main
    for (range, mod) in safi.module_range_infos
        curline in range || continue
        curmod = mod
    end
    return curmod
end

get_context_analyzer(::Nothing, uri::URI) = LSAnalyzer(uri)
get_context_analyzer(::OutOfScope, uri::URI) = LSAnalyzer(uri)
get_context_analyzer(analysis_result::AnalysisResult, ::URI) = analysis_result.analyzer

get_post_processor(::Nothing) = LSPostProcessor(JET.PostProcessor())
get_post_processor(::OutOfScope) = LSPostProcessor(JET.PostProcessor())
get_post_processor(analysis_result::AnalysisResult) = LSPostProcessor(JET.PostProcessor(analysis_result.actual2virtual))

function has_analyzed_context(state::ServerState, uri::URI)
    lookup_uri = @something get_notebook_uri_for_cell(state, uri) uri
    analysis_info = get_analysis_info(state.analysis_manager, lookup_uri)
    return _has_analyzed_context(analysis_info, lookup_uri)
end
_has_analyzed_context(::Nothing, ::URI) = false
_has_analyzed_context(outofscope::OutOfScope, ::URI) = !isnothing(outofscope.module_context)
_has_analyzed_context(analysis_result::AnalysisResult, uri::URI) =
    analyzed_file_info(analysis_result, uri) !== nothing

function collect_workspace_uris(server::Server)
    uris = Set{URI}()
    for (_, info) in load(server.state.analysis_manager.cache)
        if info isa AnalysisResult
            for uri in analyzed_file_uris(info)
                push!(uris, uri)
            end
        end
    end
    return uris
end
