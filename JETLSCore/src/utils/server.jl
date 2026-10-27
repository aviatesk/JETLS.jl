# server interaction utilities
# ===========================

const UNIQUE_ID_COUNTER = Threads.Atomic{UInt64}(0)

"""
    unique_id(prefix::AbstractString) -> String

Generate a process-wide, thread-safe ID without interning a new `Symbol`.
The counter is shared across request IDs, progress tokens, and completion resolvers.
"""
function unique_id(prefix::AbstractString)
    id = Threads.atomic_add!(UNIQUE_ID_COUNTER, UInt64(1))
    return string("jetls/", prefix, "/", string(id))
end

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
    LSP.Communication.send(server.endpoint, msg) || return nothing
    server.callback !== nothing && server.callback(:sent, msg)
    # Mark request as handled when sending a response
    if isdefined(msg, :id) && isdefined(msg, :result) && isdefined(msg, :error) # i.e. msg isa ResponseMessage
        enqueue_message!(server, HandledToken(msg.id::MessageId))
    end
    nothing
end

"""
    enqueue_message!(server::Server, msg) -> Bool

Queue an internal message (e.g. `HandledToken`) for `handler_concurrent_message`.
Returns `false` if the queue is closed before or during enqueueing, otherwise `true`.
"""
function enqueue_message!(server::Server, @nospecialize msg)
    queue = server.message_queue
    isopen(queue) || return false
    try
        put!(queue, msg)
    catch err
        err isa InvalidStateException && !isopen(queue) || rethrow()
        return false
    end
    return true
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
- `id::String`: A unique identifier for the request (generated with [`unique_id`](@ref))
- `caller::RequestCaller`: An instance of a `RequestCaller` subtype containing the
  context information needed to handle the client's response

# Example
```julia
# When creating a progress token
id = unique_id("WorkDoneProgressCreateRequest_formatting")
token = unique_id("FormattingProgress")
caller = FormattingProgressCaller(uri, msg.id, token)
addrequest!(server, id=>caller)
send(server, WorkDoneProgressCreateRequest(; id, params))
```

# See also
- [`poprequest!`](@ref) - Retrieve and remove a registered `RequestCaller` when handling the response
- [`handler_concurrent_message`](@ref) - The main handler that uses these request callers
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
- [`handler_concurrent_message`](@ref) - The main handler that processes client responses
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
    isdefined(state, :init_params) || return nothing
    return getobjpath(state.init_params.capabilities, paths...)
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
        # Shorten `timeout` and polling `sleep` under `JETLS_TEST_MODE` so tests
        # that intentionally exercise the timeout path (e.g. "File cache error
        # handling") don't block for the full production timeout.
        timeout::Float64 = @static(JETLS_TEST_MODE ? 1.0 : 10.),
        cancelled_error_data = nothing
    )
    # No `didOpen` will arrive for a URI that cannot be backed by a `FileInfo`,
    # so polling would only waste the full timeout before returning `nothing`.
    may_have_file_info(s, uri) || return nothing
    start = time()
    request_id = objectid(cancel_flag) # Each request uses a unique `cancel_flag`, so this objectid can be used as a request-unique ID
    while true
        may_have_file_info(s, uri) || return nothing
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
            @static JETLS_TEST_MODE || @warn "File cache not found" uri _id=uri maxlog=1 # Some tests intentionally call this path, so this log is probably not necessary.
            return nothing
        end
        @static JETLS_DEV_MODE && @info "Waiting for file cache" uri _id=request_id maxlog=1
        # Shorten the polling interval under `JETLS_TEST_MODE` (paired with the
        # shortened `timeout` above) so the timeout-exercising tests finish fast.
        sleep(@static JETLS_TEST_MODE ? 0.05 : 0.5)
    end
end
get_file_info(s::ServerState, t::TextDocumentIdentifier, cancel_flag::AbstractCancelFlag; kwargs...) =
    get_file_info(s, t.uri, cancel_flag; kwargs...)

"""
Capture document state on the document-sync worker, after preceding edits and
before later ones. Never poll here: this worker also processes `didOpen`/`didChange`,
so waiting would block the updates that populate the cache. Positions and ranges
remain request inputs and are converted using the captured notebook layout.
"""
function get_document_snapshot(state::ServerState, uri::URI)
    may_have_file_info(state, uri) || return nothing
    cache_uri = canonical_cache_uri(state, uri)
    fi = @something get_file_info(state, cache_uri) return nothing
    notebook_info = get_notebook_info(state, cache_uri)
    notebook = notebook_info === nothing ? nothing : notebook_info.concat
    return DocumentSnapshot(fi, cache_uri, notebook)
end

function snapshot_request_message(state::ServerState, @nospecialize(msg), uri::URI)
    snapshot = get_document_snapshot(state, uri)
    return SnapshotRequestMessage(msg, snapshot)
end

function is_workspace_root_file(
        s::ServerState, filepath::AbstractString, filename::AbstractString
    )
    isdefined(s, :root_path) || return false
    expected = joinpath(s.root_path, filename)
    return paths_equal(filepath, expected)
end

function is_workspace_file(s::ServerState, filepath::AbstractString)
    isdefined(s, :root_path) || return false
    return issubdir(filepath, s.root_path)
end

"""
    may_have_file_info(s::ServerState, uri::URI) -> Bool

Return `true` if `uri` could ever be backed by a `FileInfo`, i.e. it is a saved (`file:`)
or unsaved (`untitled:`/`buffer:`) document, or an already-registered notebook cell.
Text documents explicitly rejected by `textDocument/didOpen` and any other URI that cannot
receive a `FileInfo` return `false`, so polling [`get_file_info`](@ref) exits without
waiting for its timeout.
"""
function may_have_file_info(s::ServerState, uri::URI)
    is_rejected_text_document(s, uri) && return false
    is_config_document_uri(s, uri) && return false
    uri.scheme == "file" && return true
    isunsaveduri(uri) && return true
    return get_notebook_uri_for_cell(s, uri) !== nothing
end

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
get_unsynced_file_info!(state::ServerState, uri::URI) =
    _store_unsynced_file_info!(state, uri)

store_unsynced_file_info!(state::ServerState, uri::URI) =
    _store_unsynced_file_info!(state, uri; force=true)
function _store_unsynced_file_info!(state::ServerState, uri::URI; force::Bool=false)
    return store!(state.unsynced_file_cache) do cache::UnsyncedFileCacheData
        if !force && haskey(cache, uri)
            return cache, cache[uri]
        end
        version = time_ns() % Int
        # Notebook URIs can reach this path during the race window in
        # `handle_DidCloseNotebookDocumentNotification` between clearing `file_cache`
        # and `cleanup_analysis_state!` evicting `analysis_manager.cache`, when
        # a concurrent workspace iteration still has the URI in its `uris_to_search`.
        # Reading the raw `.ipynb` as Julia would otherwise parse the JSON literal
        # and emit bogus `lowering/error` diagnostics (aviatesk/JETLS.jl#703).
        is_notebook_uri(uri) && return cache, nothing
        filename = uri2filename(uri)
        isfile(filename) || return cache, nothing
        parsed_stream = try
            ParseStream!(read(filename))
        catch e
            @static JETLS_DEV_MODE && @error "Error parsing file $(filename)"
            @static JETLS_DEV_MODE && locked_showerror(stderr, e, catch_backtrace())
            return cache, nothing
        end
        fi = FileInfo(version, parsed_stream, filename, state.encoding)
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
    get_context_info(state::ServerState, uri::URI, pos::Union{Nothing,Position}) ->
        (; context_module, world, analyzer, postprocessor)

Extract context information for a given position in a file, or for the top level of the
file, outside any `module` block, when `pos` is `nothing`.

Returns a named tuple containing:
- `context_module::Module`: The module context at the given position
- `world::UInt`: The world age to pin reflection and inference to. When an `AnalysisResult`
  is cached for this URI, this is the world at which that analysis context was produced —
  pinning to it keeps a request consistent with the cached analysis even if a concurrent
  update has advanced `Base.get_world_counter()`. When there is no cached analysis (i.e.
  `Nothing` / `OutOfScope`), this falls back to the current world counter.
- `analyzer::LSAnalyzer`: The analyzer instance for the file
- `postprocessor::JET.PostProcessor`: The post-processor for fixing `var"..."` strings that users don't need
  to recognize, which are caused by JET implementation details
"""
function get_context_info(
        state::ServerState, uri::URI, pos::Union{Nothing,Position}; lookup_func=nothing
    )
    lookup_uri = canonical_cache_uri(state, uri)
    if lookup_func !== nothing
        analysis_info = get_analysis_info(lookup_func, state.analysis_manager, lookup_uri)
    else
        analysis_info = get_analysis_info(state.analysis_manager, lookup_uri)
    end
    context_module = get_context_module(analysis_info, lookup_uri, pos)
    world = get_context_world(analysis_info)
    analyzer = get_context_analyzer(analysis_info, lookup_uri)
    postprocessor = get_post_processor(analysis_info)
    return (; context_module, world, analyzer, postprocessor)
end

get_context_module(::Nothing, ::URI, ::Union{Nothing,Position}) = FallbackAnalysisContext
# Use `@something` instead of `something` due to https://github.com/JuliaLang/julia/pull/60857
# `something` can be used after 1.12.5
get_context_module(oos::OutOfScope, ::URI, ::Union{Nothing,Position}) =
    something(oos.module_context, FallbackAnalysisContext)
function get_context_module(
        analysis_result::AnalysisResult, uri::URI, pos::Union{Nothing,Position}
    )
    _has_analyzed_context(analysis_result, uri) || return FallbackAnalysisContext
    safi = analyzed_file_info(analysis_result, uri)::JET.AnalyzedFileInfo
    curmod = Main
    if pos === nothing
        # the range of the top level of the file contains the ranges of the modules in it
        currange = 1:0
        for (range, mod) in safi.module_range_infos
            if currange ⊆ range
                curmod = mod
                currange = range
            end
        end
    else
        curline = Int(pos.line) + 1
        currange = 0:typemax(Int)
        for (range, mod) in safi.module_range_infos
            curline in range || continue
            if range ⊆ currange
                curmod = mod
                currange = range
            end
        end
    end
    return curmod
end
function get_context_module(state::ServerState, uri::URI, pos::Position; lookup_func=nothing)
    lookup_uri = canonical_cache_uri(state, uri)
    if lookup_func !== nothing
        analysis_info = get_analysis_info(lookup_func, state.analysis_manager, lookup_uri)
    else
        analysis_info = get_analysis_info(state.analysis_manager, lookup_uri)
    end
    return get_context_module(analysis_info, lookup_uri, pos)
end

"""
    get_file_modules(analysis_info, uri::URI) -> Vector{Module}

Return the modules that the top level of the file at `uri` belongs to, i.e. the modules
that the file is `include`d into, regardless of the `module` blocks within the file.
"""
get_file_modules(::Nothing, ::URI) = Module[FallbackAnalysisContext]
get_file_modules(oos::OutOfScope, ::URI) =
    Module[something(oos.module_context, FallbackAnalysisContext)]
function get_file_modules(analysis_result::AnalysisResult, uri::URI)
    _has_analyzed_context(analysis_result, uri) || return Module[FallbackAnalysisContext]
    safi = analyzed_file_info(analysis_result, uri)::JET.AnalyzedFileInfo
    # The range of the top level of the file contains the ranges of the modules in it, and
    # is the widest one even when JET records no whole-file range, e.g. for an included
    # file with a syntax error.
    toprange = 1:0
    for (range, _) in safi.module_range_infos
        toprange ⊆ range && (toprange = range)
    end
    filemods = Module[]
    for (range, mod) in safi.module_range_infos
        range == toprange && push!(filemods, mod)
    end
    return filemods
end

"""
    get_file_module(analysis_info, uri::URI) -> Module

Return the module that the top level of the file at `uri` belongs to (see
[`get_file_modules`](@ref)). For a file `include`d into multiple modules, this is the module
that full analysis loaded it into last.
"""
get_file_module(analysis_info::Union{Nothing,AnalysisInfo}, uri::URI) =
    last(get_file_modules(analysis_info, uri))

"""
    SourceModule

The module that code belongs to according to the `module` blocks enclosing it in the
current source. `mod` is the innermost of those modules that exists in the analysis world,
and `path` holds the names of the `module` blocks nested in it that do not, e.g. modules
that full analysis has not loaded yet, or any `module` block of a file analyzed in the
fallback context.
"""
struct SourceModule
    mod::Module
    path::Vector{Symbol}
end
Base.:(==)(a::SourceModule, b::SourceModule) = a.mod === b.mod && a.path == b.path
Base.hash(sm::SourceModule, h::UInt) = hash(sm.path, hash(sm.mod, hash(SourceModule, h)))

"""
    collect_source_modules(st0_top::SyntaxTree, filemod::Module, world::UInt)
        -> Vector{Pair{UnitRange{Int},SourceModule}}

Collect the byte range of each `module` block that `iterate_toplevel_tree` descends into,
from its docstring to the end of its body, paired with its [`SourceModule`](@ref) resolved
from `filemod`, the module that the top level of the file belongs to. Enclosing blocks
come before nested ones.
"""
function collect_source_modules(st0_top::SyntaxTree, filemod::Module, world::UInt)
    blocks = collect_module_blocks(st0_top)
    source_modules = Pair{UnitRange{Int},SourceModule}[]
    for (index, block) in enumerate(blocks)
        parent = block.parent == 0 ?
            SourceModule(filemod, Symbol[]) : last(source_modules[block.parent])
        submod = isempty(parent.path) && !is_ambiguous_module_block(blocks, index) ?
            resolve_submodule(parent.mod, block.name, world) : nothing
        source_module = submod === nothing ?
            SourceModule(parent.mod, Symbol[parent.path; block.name]) :
            SourceModule(submod, Symbol[])
        push!(source_modules, (first(block.range):last(block.body)) => source_module)
    end
    return source_modules
end

# The current binding comes from only one of the sibling `module` blocks of the same name,
# e.g. of a module redefined in the same file, but which one is unknown.
function is_ambiguous_module_block(blocks::Vector{ModuleBlock}, index::Int)
    (; parent, name) = blocks[index]
    return count(block::ModuleBlock -> block.parent == parent && block.name === name,
        blocks) > 1
end

# The module that a `module` block named `name` defines in `mod`, if it exists at `world`.
# A module merely visible in `mod`, e.g. `Base` or one that `mod` imports, does not count.
function resolve_submodule(mod::Module, name::Symbol, world::UInt)
    Base.invoke_in_world(world, isdefinedglobal, mod, name)::Bool || return nothing
    owner = try
        Base.invoke_in_world(world, Base.binding_module, mod, name)::Module
    catch # thrown for a name that `mod` imports from multiple modules
        return nothing
    end
    owner === mod || return nothing
    submod = Base.invoke_in_world(world, getglobal, mod, name)
    return submod isa Module ? submod : nothing
end

"""
    collect_module_blocks(st0_top::SyntaxTree) -> Vector{ModuleBlock}

Collect the `module` blocks in `st0_top` that `iterate_toplevel_tree` descends into, where
enclosing blocks come before nested ones.
"""
collect_module_blocks(st0_top::SyntaxTree) = collect_module_blocks!(ModuleBlock[], st0_top, 0)

function collect_module_blocks!(
        blocks::Vector{ModuleBlock}, st0::SyntaxTree, parent::Int;
        range_st0::SyntaxTree = st0
    )
    if JS.head(st0) === :toplevel
        for i = 1:JS.numchildren(st0)
            collect_module_blocks!(blocks, st0[i], parent)
        end
    elseif is_doc0_any(st0)
        for i = 3:JS.numchildren(st0)
            # the docstring of a module is evaluated within the module
            collect_module_blocks!(blocks, st0[i], parent; range_st0 = st0)
        end
    elseif JS.head(st0) === :module
        module_name = @something module_name_node(st0) return blocks
        bodyidx = @something findlast(
            i -> JS.head(st0[i]) === :block, 1:JS.numchildren(st0)) return blocks
        name = @something get_name_val(module_name) return blocks
        body = st0[bodyidx]
        range = JS.first_byte(range_st0):JS.last_byte(st0)
        push!(blocks, ModuleBlock(range, JS.byte_range(body), Symbol(name), parent))
        index = length(blocks)
        for i = 1:JS.numchildren(body)
            collect_module_blocks!(blocks, body[i], index)
        end
    end
    return blocks
end

function source_module_at(
        source_modules::Vector{Pair{UnitRange{Int},SourceModule}}, offset::Int,
        filemod::Module
    )
    for i = length(source_modules):-1:1
        range, source_module = source_modules[i]
        # At an unfinished module's EOF, the cursor is just past the body's last byte.
        first(range) ≤ offset ≤ last(range) + 1 && return source_module
    end
    return SourceModule(filemod, Symbol[])
end

get_context_analyzer(::Nothing, uri::URI) = LSAnalyzer(uri)
get_context_analyzer(::OutOfScope, uri::URI) = LSAnalyzer(uri)
get_context_analyzer(analysis_result::AnalysisResult, ::URI) = analysis_result.analyzer

get_post_processor(::Nothing) = LSPostProcessor(JET.PostProcessor())
get_post_processor(::OutOfScope) = LSPostProcessor(JET.PostProcessor())
get_post_processor(analysis_result::AnalysisResult) = LSPostProcessor(JET.PostProcessor(analysis_result.actual2virtual))

get_context_world(::Nothing) = Base.get_world_counter()
get_context_world(::OutOfScope) = Base.get_world_counter()
get_context_world(analysis_result::AnalysisResult) = analysis_result.world

function has_analyzed_context(state::ServerState, uri::URI; lookup_func=nothing)
    lookup_uri = canonical_cache_uri(state, uri)
    if lookup_func !== nothing
        analysis_info = get_analysis_info(lookup_func, state.analysis_manager, lookup_uri)
    else
        analysis_info = get_analysis_info(state.analysis_manager, lookup_uri)
    end
    return _has_analyzed_context(analysis_info, lookup_uri)
end
_has_analyzed_context(::Nothing, ::URI) = false
# TODO Remove `JETLSTestModule` entirely.
# Pseudo contexts supply imports, not real analysis, so context-requiring features
# (e.g. `analyze_unused_imports!`) must be skipped even though `module_context` is set.
_has_analyzed_context(outofscope::OutOfScope, ::URI) =
    !isnothing(outofscope.module_context) &&
    outofscope.module_context !== JETLSTestModule &&
    outofscope.module_context !== FallbackAnalysisContext
function _has_analyzed_context(analysis_result::AnalysisResult, uri::URI)
    analysis_result.entry isa PackageExtensionAnalysisEntry && return false
    safi = @something analyzed_file_info(analysis_result, uri) return false
    return !isempty(safi.module_range_infos)
end

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

function relative_workspace_path_for_config(server::Server, filename::AbstractString)
    isdefined(server.state, :root_path) || return nothing
    root_path = server.state.root_path
    issubdir(filename, root_path) || return nothing
    return glob_candidate_path(filename, root_path)
end
