# server interaction utilities
# ===========================

const DEFAULT_FLUSH_INTERVAL = 0.05
function yield_to_endpoint(interval=DEFAULT_FLUSH_INTERVAL)
    # HACK: allow JSONRPC endpoint to process queued messages (e.g. work done progress report)
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
    JSONRPC.send(server.endpoint, msg)
    server.callback !== nothing && server.callback(:sent, msg)
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

# Usage
The function supports both syntaxes for convenience:
- `addrequest!(server, id=>caller)` - Using Pair syntax
- `addrequest!(server, id, caller)` - Using separate arguments

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
    return server.state.currently_requested[id] = caller
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

# Usage
This function is primarily used in `handle_ResponseMessage` to retrieve the appropriate
handler context when processing client responses. The retrieved `RequestCaller` is then
dispatched to the appropriate handler based on its type.

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
    currently_requested = server.state.currently_requested
    if id isa String && haskey(currently_requested, id)
        return pop!(currently_requested, id)
    end
    return nothing
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
    get_file_info(s::ServerState, uri::URI) -> fi::Union{Nothing,FileInfo}
    get_file_info(s::ServerState, t::TextDocumentIdentifier) -> fi::Union{Nothing,FileInfo}

Fetch cached FileInfo given an LSclient-provided structure with a URI
"""
get_file_info(s::ServerState, uri::URI) = get(load(s.file_cache), uri, nothing)
get_file_info(s::ServerState, t::TextDocumentIdentifier) = get_file_info(s, t.uri)

"""
    get_saved_file_info(s::ServerState, uri::URI) -> fi::Union{Nothing,SavedFileInfo}
    get_saved_file_info(s::ServerState, t::TextDocumentIdentifier) -> fi::Union{Nothing,SavedFileInfo}

Fetch cached saved FileInfo given an LSclient-provided structure with a URI
"""
get_saved_file_info(s::ServerState, uri::URI) = get(load(s.saved_file_cache), uri, nothing)
get_saved_file_info(s::ServerState, t::TextDocumentIdentifier) = get_saved_file_info(s, t.uri)

get_testsetinfos(s::ServerState, uri::URI) = get(load(s.testsetinfos_cache), uri, nothing)

"""
    get_context_info(state::ServerState, uri::URI, pos::Position) -> (; mod, analyzer, postprocessor)

Extract context information for a given position in a file.

Returns a named tuple containing:
- `mod::Module`: The module context at the given position
- `analyzer::LSAnalyzer`: The analyzer instance for the file
- `postprocessor::JET.PostProcessor`: The post-processor for fixing `var"..."` strings that users don't need
  to recognize, which are caused by JET implementation details
"""
function get_context_info(state::ServerState, uri::URI, pos::Position)
    analysis_unit = find_analysis_unit_for_uri(state, uri)
    mod = get_context_module(analysis_unit, uri, pos)
    analyzer = get_context_analyzer(analysis_unit, uri)
    postprocessor = get_post_processor(analysis_unit)
    return (; mod, analyzer, postprocessor)
end

get_context_module(::Nothing, ::URI, ::Position) = Main
get_context_module(oos::OutOfScope, ::URI, ::Position) = isdefined(oos, :module_context) ? oos.module_context : Main
function get_context_module(analysis_unit::AnalysisUnit, uri::URI, pos::Position)
    safi = @something successfully_analyzed_file_info(analysis_unit, uri) return Main
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
get_context_analyzer(analysis_unit::AnalysisUnit, ::URI) = analysis_unit.result.analyzer

get_post_processor(::Nothing) = LSPostProcessor(JET.PostProcessor())
get_post_processor(::OutOfScope) = LSPostProcessor(JET.PostProcessor())
get_post_processor(analysis_unit::AnalysisUnit) = LSPostProcessor(JET.PostProcessor(analysis_unit.result.actual2virtual))

function find_analysis_unit_for_uri(state::ServerState, uri::URI)
    haskey(state.analysis_cache, uri) || return nothing
    analysis_info = state.analysis_cache[uri]
    if analysis_info isa OutOfScope
        return analysis_info
    end
    analysis_unit = first(analysis_info)
    for analysis_unit′ in analysis_info
        # prioritize `PackageSourceAnalysisEntry` if exists
        if isa(analysis_unit.entry, PackageSourceAnalysisEntry)
            analysis_unit = analysis_unit′
            break
        end
    end
    return analysis_unit
end
