# JETLS Multithreading Design Document

*This document was written with assistance from Claude.*

## Overview

This document outlines the multithreading design for JETLS, focusing on thread safety requirements and implementation strategies. The goal is to enable parallel processing of LSP requests while maintaining data consistency and correctness.

## `FileInfo` Thread Safety (Mostly Resolved)

[aviatesk/JETLS.jl#229](https://github.com/aviatesk/JETLS.jl/pull/229) made `FileInfo` immutable and introduced pre-computed AST construction, resolving the major multithreading issues:

**Resolved Issues**:
- Data races from concurrent updates to `mutable struct FileInfo`
- Duplicate computation and race conditions from lazy AST construction
- Non-atomic field updates in `cache_file_info!`
- GC issues with old `FileInfo` instances

```julia
struct FileInfo
    version::Int
    encoding::LSP.PositionEncodingKind.Ty
    parsed_stream::JS.ParseStream
    syntax_node::JS.SyntaxNode
    syntax_tree0::SyntaxTree0
    testsetinfos::Vector{_TestsetInfo{FileInfo}}  # Note: mutable Vector
end
```

**Known Minor Issue**:
The `testsetinfos` field contains a mutable `Vector` that can be modified during document synchronization while being read by other requests (e.g., writes in document-sync, reads in code lens requests). In practice, this rarely causes issues since test detection is relatively infrequent. This will be properly resolved when introducing the thread-safe lowering cache.

## `ServerState` Thread Safety Requirements

### 1. Shared Data Structures

The current `ServerState` contains several mutable collections accessed concurrently:

```julia
mutable struct ServerState
    const file_cache::Dict{URI,FileInfo}           # Needs protection
    const saved_file_cache::Dict{URI,SavedFileInfo} # Needs protection
    const analysis_cache::Dict{URI,AnalysisInfo}   # Needs protection
    const extra_diagnostics::ExtraDiagnostics      # Needs protection
    const currently_requested::Dict{String,RequestCaller} # Needs protection
    const config_manager::ConfigManager            # Needs protection if modified
    # ... other fields
end
```

### 2. Solution: MustLock Pattern for Thread Safety

We use a `MustLock` wrapper pattern that enforces explicit locking at compile time:

```julia
"""
    MustLock{T}

A wrapper that requires explicit locking before accessing the wrapped value.
This ensures thread-safe access to shared data structures by making it impossible
to accidentally access protected fields without proper synchronization.

# Usage
\`\`\`julia
# Cannot access directly - will cause MethodError
state.file_cache[uri] = fi  # Error!

# Must use withlock pattern
withlock(state.file_cache) do file_cache
    file_cache[uri] = fi  # OK
end
\`\`\`
"""
struct MustLock{T}
    lock::ReentrantLock
    val::T
end

"""
    withlock(func, ml::MustLock)

Execute `func` with exclusive access to the value wrapped in `MustLock`.
The lock is automatically acquired before calling `func` and released afterwards.
"""
function withlock(func, ml::MustLock)
    @lock ml.lock func(ml.val)
end
```

### 3. Updated ServerState Definition

```julia
mutable struct ServerState
    # Fields that require locking (wrapped with MustLock automatically)
    const workspaceFolders::Vector{URI}
    const file_cache::Dict{URI,FileInfo}
    const saved_file_cache::Dict{URI,SavedFileInfo}
    const analysis_cache::Dict{URI,AnalysisInfo}
    const extra_diagnostics::ExtraDiagnostics
    const currently_requested::Dict{String,RequestCaller}
    const currently_registered::Set{Registered}
    const config_manager::ConfigManager
    const completion_resolver_info::Base.RefValue{CompletionResolverInfo}

    const __state_lock__::ReentrantLock  # Shared lock for all fields above

    # Fields that don't require locking (set once during initialization)
    encoding::PositionEncodingKind.Ty
    root_path::String
    root_env_path::String
    init_params::InitializeParams
end

# Custom getproperty automatically wraps fields before __state_lock__ with MustLock
let __state_lock__idx = Base.fieldindex(ServerState, :__state_lock__)
    global function Base.getproperty(state::ServerState, name::Symbol)
        if name === :__state_lock__
            return getfield(state, :__state_lock__)
        end
        idx = Base.fieldindex(ServerState, name)
        if idx < __state_lock__idx
            # Fields before __state_lock__ require locking
            return MustLock(getfield(state, :__state_lock__), getfield(state, name))
        else
            # Fields after __state_lock__ don't require locking
            return getfield(state, name)
        end
    end
end
```

### 4. Protected Access Patterns with MustLock

```julia
# File cache operations
function cache_file_info!(state::ServerState, uri::URI, version::Int, parsed_stream::JS.ParseStream)
    new_fi = FileInfo(version, parsed_stream, uri, state.encoding)
    withlock(state.file_cache) do file_cache
        file_cache[uri] = new_fi
    end
    return new_fi
end

function get_file_info(state::ServerState, uri::URI)::Union{FileInfo,Nothing}
    withlock(state.file_cache) do file_cache
        get(file_cache, uri, nothing)
    end
end

function addrequest!(state::ServerState, id::String, caller::RequestCaller)
    withlock(state.currently_requested) do currently_requested
        currently_requested[id] = caller
    end
end

function rmrequest!(state::ServerState, id::String)
    withlock(state.currently_requested) do currently_requested
        pop!(currently_requested, id, nothing)
    end
end

# Accessing ConfigManager (composite type)
function update_config!(state::ServerState, key::String, value)
    withlock(state.config_manager) do config_manager
        config_manager.reload_required_setting[key] = value
    end
end

# Iteration example
function get_all_file_uris(state::ServerState)
    withlock(state.file_cache) do file_cache
        # Iteration happens within a single lock
        return collect(keys(file_cache))
    end
end
```

### 5. Advantages of the `MustLock` Pattern

**Compile-time Safety**:
- Direct access to protected fields causes `MethodError`
- Forces explicit locking through `withlock`
- Prevents accidental unsynchronized access

**Clear Lock Boundaries**:
- Lock scope is visually obvious in the code
- No hidden or automatic locking
- Avoids double-locking issues

**Performance**:
- No overhead from redundant locks
- Lock held only for necessary duration
- Clean separation between protected and unprotected fields

### 6. Why Single Lock is Sufficient

- **Fast operations**: `Dict` operations take microseconds, `FileInfo` creation ~1ms
- **Short critical sections**: Locks are held only for data structure updates
- **Simpler implementation**: No risk of deadlocks from lock ordering issues
- **Easier maintenance**: New fields automatically protected without additional locks

## JSONRPC Layer Thread Safety

### 1. Design Philosophy

The JSONRPC layer should remain a simple, sequential message delivery mechanism:
- **No parallelization at JSONRPC level** - It's just a "dumb pipe" that delivers messages in order
- **Parallelization belongs in the LSP layer** - JETLS decides what can be parallelized
- **Preserve message ordering** - Critical for protocol correctness

### 2. Minimal Required Changes

The JSONRPC layer needs only one change for thread safety:

**Endpoint State Management**:
```julia
mutable struct Endpoint
    # ... existing fields ...
    @atomic state::Symbol  # Make state field atomic for thread-safe access
end

# Access to @atomic fields is automatically atomic
function check_dead_endpoint!(endpoint::Endpoint)
    endpoint.state === :open || error("Endpoint is $(endpoint.state)")
end

function Base.close(endpoint::Endpoint)
    @atomic endpoint.state = :closing
    # ... existing close logic ...
    @atomic endpoint.state = :closed
    return endpoint
end
```

### 3. Why This is Sufficient

- **No IO locking needed**: Each IO stream (input/output) is accessed by only one component
- **No read/write task spawning needed**: Synchronous processing is fine for message delivery
- **Channel handles synchronization**: The existing `Channel{Any}(Inf)` provides thread-safe queuing
- **State is the only shared field**: Multiple threads might check endpoint state concurrently

The JSONRPC layer continues to deliver messages sequentially, while JETLS handles parallelization.

## Message Handler Concurrency

### 1. Messages Requiring Sequential Processing

#### Lifecycle Messages
Must be processed sequentially to maintain protocol correctness:
- `initialize` → `initialized` sequence
- `shutdown` → `exit` sequence
- After `shutdown`, all requests except `exit` must be rejected

#### Document Synchronization (Per-URI)
Must be processed sequentially per URI to maintain file consistency:
- `textDocument/didOpen`
- `textDocument/didChange`
- `textDocument/didClose`

#### Cancellation Requests
- `$/cancelRequest` notifications should interrupt ongoing operations

(Unused currently)

### 2. Messages Safe for Parallel Processing

Most user-facing requests can be processed in parallel:
- `textDocument/completion`
- `textDocument/hover`
- `textDocument/definition`
- `textDocument/references`
- `textDocument/documentHighlight`
- `textDocument/formatting`
- etc.

### 3. Implementation Strategy

#### Thread Pool Usage Guidelines
- **`:interactive` pool**: Truly lightweight, low-latency operations
  - Document synchronization (just updating state)
  - Simple notifications processing
  - Tasks that yield frequently (I/O operations automatically yield)
- **`:default` pool**: Any operation involving analysis or computation
  - Regular requests (completion, hover, etc.) that involve lowering/type inference
  - Full analysis (can take seconds)
  - Any CPU-intensive or potentially blocking operations

#### Message Handling in `runserver` Loop
```julia
function runserver(server::Server)
    # ...
    for msg in server.endpoint  # Sequential message processing
        # Lifecycle messages (already handled sequentially in runserver)
        if msg isa InitializeRequest
            handle_InitializeRequest(server, msg)
        elseif msg isa ShutdownRequest
            # ... shutdown handling ...
        # Regular message handling
        else
            handle_message(server, msg)
        end
    end
end

function handle_message(server::Server, @nospecialize msg)
    if is_sequential_message(msg)
        # Process synchronously (fast: ~1-2ms)
        handle_sequential_message(server, msg)
        # Heavy operations like run_full_analysis! are spawned internally
    else
        # Default: spawn for parallel processing
        Threads.@spawn handle_message_concurrent(server, msg)
    end
end

# Messages that must be processed sequentially
function is_sequential_message(@nospecialize msg)
    msg isa DidOpenTextDocumentNotification ||
    msg isa DidChangeTextDocumentNotification ||
    msg isa DidSaveTextDocumentNotification ||
    msg isa DidCloseTextDocumentNotification ||
    msg isa CancelNotification
end
```

#### Document Synchronization Handling
Document sync operations are processed synchronously in the main loop because:
- **Very fast**: Parse + cache update takes only ~1-2ms
- **Heavy work spawned separately**: `run_full_analysis!` is already spawned internally
- **Simpler design**: No additional synchronization mechanisms needed
- **Preserves ordering**: Diagnostics notifications maintain correct order

```julia
# In document-synchronization.jl handlers
function handle_DidOpenTextDocumentNotification(server, msg)
    # Fast operations (~1-2ms)
    cache_file_info!(...)
    cache_saved_file_info!(...)

    # Heavy operation spawned internally
    Threads.@spawn run_full_analysis!(server, uri)
end

function handle_DidChangeTextDocumentNotification(server, msg)
    # Fast operations only
    cache_file_info!(...)
    update_testsetinfos!(...)
    notify_diagnostics!(...)  # Keep synchronous for ordering
end
```

## Utility Functions Thread Safety

### Debounce/Throttle Functions

Current implementation in `utils/general.jl` lacks thread safety:

```julia
# Current: Shared Dict without locks
let debounced = Dict{UInt, Timer}()  # Not thread-safe!
    global function debounce(f, id::UInt, delay)
        # ... Dict operations without locks ...
    end
end
```

**Solution**:
```julia
let debounced = Dict{UInt, Timer}(),
    debounce_lock = ReentrantLock()
    global function debounce(f, id::UInt, delay)
        lock(debounce_lock) do
            # ... existing implementation ...
        end
    end
end
```

## Implementation Roadmap

### Phase 1: Foundation (Required)
1. Add locks to `ServerState` for all shared collections
2. Protect all `Dict`/collection operations with appropriate locks
3. Fix thread safety in utility functions (`debounce`/`throttle`)

### Phase 2: Basic Parallelization
1. Spawn handlers for independent requests (completions, hover, etc.)
2. Maintain sequential processing for document changes per URI
3. Preserve lifecycle message ordering

### Phase 3: Optimization (Optional)
1. Fine-grained locking strategies where beneficial
2. Lock-free data structures for hot paths
3. Performance profiling and tuning

## Performance Considerations

### Lock Granularity
- `Dict` operations: microseconds (negligible overhead)
- `FileInfo` creation: ~1ms (AST construction)
- Analysis operations: ~40ms (lowering)
- Lock contention minimal due to short critical sections

### Expected Parallelism
- **Different files**: Full parallelism (independent processing)
- **Same file**: Parallel analysis after `FileInfo` retrieval
- **Requests**: Most user requests can be processed in parallel

## Summary

The multithreading implementation requires:

1. **`FileInfo`** (✓ Resolved): Already immutable via PR #229
2. **`ServerState`**: Add locks for shared collections
3. **JSONRPC**: Fix endpoint state management
4. **Message Handlers**: Selective parallelization with ordering constraints
5. **Utilities**: Thread-safe `debounce`/`throttle`

With `FileInfo` immutability resolved, the remaining work focuses on protecting shared state and carefully parallelizing message handlers while respecting LSP ordering requirements.
