---
file-created: 2025-08-23T23:27
file-modified: 2025-09-09T20:40
status: x
due: 2025-09-05
---

JETLS Multithreading Design Document
====================================

*This document was created with assistance from Claude.*

## 1. Overview

Enable concurrent processing of multiple LSP messages to significantly improve server responsiveness:
- Data consistency guarantee: Maintain data integrity even under concurrent processing
- Concurrent message processing: Process multiple requests simultaneously to reduce response time
- Non-blocking operation: Respond immediately to lightweight requests (completion, hover, etc.) even during heavy processing (full analysis)

### Scope of this document
- Identification of thread-safety issues and design of solutions
- Development of phased implementation plan

## 2. Basic Principles

### 2.1 Thread-Safety Strategy

Select appropriate synchronization mechanisms based on update function
weight and access patterns:

1. Sequential writes only → `SWContainer` (no concurrency protection)
2. Lightweight updates (ns-range, pure) → `CASContainer` (lock-free)
3. Heavy updates (µs-ms, I/O, side effects) → `LWContainer` (locks)
4. Complex multi-URI updates → `AnalysisManager` (queuing)

Key decision factor: Weight of update function `f`
- Lightweight `f` (dict/set operations, assignments) → `CASContainer`
- Heavy `f` (file I/O, analysis, computation) → `LWContainer`

Principles:
- Lock-free reads whenever possible
- Choose container based on `f` weight
- Always guarantee data consistency

### 2.2 Message Processing Parallelization Strategy

#### Sequential processing required:
- Lifecycle: `initialize`, `shutdown`, `exit`
- Document synchronization (per URI): `didOpen`, `didChange`, `didSave`, `didClose`
- Cancellation: `$/cancelRequest`

#### Parallelizable:
- Read-only operations: `completion`, `hover`, `definition`, `references`, `documentHighlight`, `formatting`, etc.

#### Implementation pattern:
```julia
function handle_message(server::Server, @nospecialize msg)
    if is_sequential_message(msg)
        # Process synchronously (fast: ~1-2ms)
        # N.B. Full-analysis triggered by document synchronization uses `Threads.@spawn` internally
        handle_message_sequentially(server, msg)
    else
        # Default: spawn for parallel processing
        Threads.@spawn handle_message_concurrently(server, msg)
    end
end
```

### 2.3 Thread Pool Usage Guidelines
- `:interactive` pool: Truly lightweight, low-latency operations
  - Document synchronization (state updates only)
  - Simple notification processing
- `:default` pool: Any operations involving analysis or computation
  - Regular requests including lowering/type inference
  - Full analysis (may take several seconds)

### 2.4 Common Thread-Safe Data Structures

#### `AtomicContainer` interface
```julia
abstract type AtomicContainer end
function load(::AtomicContainer) end
function store!(f, ::AtomicContainer) end

abstract type AtomicStats end
function getstats(::AtomicStats) end
function resetstats!(::AtomicStats) end
```

#### `SWContainer`
Simple atomic container providing atomic reads and writes without locks or CAS loops.
Fastest option for sequential or non-contended updates.

> [!warning]
> Concurrent writes are NOT safe.
> If correctness under contention is needed,
> use [`LWContainer`](@ref) or [`CASContainer`](@ref) containers instead.
```julia
mutable struct SWContainer{T,Stats<:Union{Nothing,AtomicStats}}
    @atomic data::T
end

load(c::SWContainer) = @atomic :acquire c.data

@inline function store!(f, c::SWContainer{T}) where T
    old = @atomic :acquire c.data
    new, ret = @inline f(old)
    @atomic :release c.data = new::T
    return ret
end
```

#### `LWContainer`
Locked-Write Container: lock-free reads (atomic load), lock-serialized writes.

When to use LW:
- Heavy `f` function: (ms range, susceptible to interrupts/IO/allocations/GC)
- Functions with side effects that must run exactly once (lock ensures single execution)

When to avoid:
- High write frequency with lightweight `f` (ns-range): Consider [`CASContainer`](@ref)
- Strict fairness requirements (`ReentrantLock` is not strictly FIFO)

> [!warning]
> `LWContainer` does not protect the internal state of `data` itself.
> Always use immutable data structures and avoid in-place mutations.
> The function `f` in `store!` must return a new object, not modify the existing one.

> [!note]
> While inspired by RCU (Read-Copy-Update) patterns, this implementation uses
> locks for write serialization rather than classic RCU's grace period mechanism.
```julia
mutable struct LWContainer{T,Stats<:Union{Nothing,LWStats}}
    @atomic data::T
    const update_lock::ReentrantLock
    LWContainer(data::T) where T = new{T}(data, ReentrantLock())
end

load(c::LWContainer) = @atomic :acquire c.data

function store!(f, c::LWContainer{T}) where T
    @lock c.update_lock begin
        old = @atomic :acquire c.data
        new, ret = f(old)
        @atomic :release c.data = new::T
        return ret
    end
end
```

#### `CASContainer`
Compare-And-Swap (CAS) container using lock-free retry loops for updates.

When to use CAS:
- Lightweight `f` function (tens to hundreds of ns) that's safe to retry (pure function)
- High write frequency or low-to-moderate contention needing high throughput

When to avoid:
- Heavy `f` or functions with side effects: wasted re-evaluation on failure → Use LW
- High contention: excessive retries cause spin time and cache line bouncing

> [!warning]
> `CASContainer` does not protect the internal state of `data` itself.
> Always use immutable data structures and avoid in-place mutations.
> The function `f` in `store!` must be pure and return a new object, not modify the existing one.
```julia
mutable struct CASContainer{T,Stats<:Union{Nothing,CASStats}}
    @atomic data::T
end

load(c::CASContainer) = @atomic :acquire c.data

@inline function store!(f, c::CASContainer{T}; backoff::Union{Nothing,Unsigned}=nothing) where T
    old = @atomic :acquire c.data
    while true
        new, ret = @inline f(old)
        old, success = @atomicreplace :acquire_release :monotonic c.data old => (new::T)
        if success
            return ret
        else
            # Failure. Increment locally and apply throttled backoff if needed
            ...
        end
    end
end
```

## 3. Component-Specific Problems and Solutions

### 3.1 `FileInfo`

Problem: Concurrent access to mutable fields, duplicate computation from lazy AST construction

Solution: Immutability and pre-computed AST construction ([aviatesk/JETLS.jl#229](https://github.com/aviatesk/JETLS.jl/pull/229))
```julia
struct FileInfo
    version::Int
    encoding::LSP.PositionEncodingKind.Ty
    parsed_stream::JS.ParseStream
    syntax_node::JS.SyntaxNode
    syntax_tree0::SyntaxTree0
end
```

### 3.2 `ServerState`

`ServerState` is the central structure managing all shared server state.
Each field uses an appropriate synchronization mechanism based on the
weight of its update function and access pattern.

#### Container Selection Summary

| Component | Container | Update Weight | Rationale |
|-----------|-----------|--------------|-----------|
| `file_cache`, `saved_file_cache`, `testsetinfos_cache` | `SWContainer` | Light | Sequential-only updates |
| `config_manager` | `LWContainer` | Heavy | TOML parsing, file I/O, validation |
| `extra_diagnostics` | `CASContainer` | Light | Simple dict copy/update |
| `currently_requested` | `CASContainer` | Light | Simple dict operations |
| `currently_registered` | `CASContainer` | Light | Simple set operations |
| `completion_resolver_info` | `CASContainer` | Light | Simple replacement |
| `workspaceFolders` | `CASContainer` | Light | Vector replacement |
| `analysis_manager` | Queue | Very heavy | Complex multi-URI analysis |

Key insight: Most updates are lightweight dict/set/vector operations
(ns-range), making `CASContainer` optimal. Only `config_manager` (file I/O,
parsing) and `analysis_manager` (full analysis) require heavier synchronization.

```julia
mutable struct ServerState
    # Lifecycle fields (written once at initialization, no locking needed)
    encoding::PositionEncodingKind.Ty
    root_path::String
    root_env_path::String
    init_params::InitializeParams

    # Document synchronization (sequential writes, concurrent reads)
    const file_cache::FileCache                                     # SWContainer (sequential only)
    const saved_file_cache::SavedFileCache                          # SWContainer (sequential only)
    const testsetinfos_cache::TestsetInfosCache                     # SWContainer (sequential only)

    # Analysis management (queue-based serialization)
    const analysis_manager::AnalysisManager                         # Queue (complex multi-URI)

    # Configuration management (heavy updates, frequent reads)
    const config_manager::ConfigManager                             # LWContainer (TOML parsing, file I/O)

    # Diagnostics (lightweight updates, medium frequency)
    const extra_diagnostics::ExtraDiagnostics                       # CASContainer (dict operations)

    # Request tracking (lightweight updates, high frequency)
    const currently_requested::CurrentlyRequested                   # CASContainer (dict operations)

    # Registration tracking (lightweight updates, infrequent)
    const currently_registered::CurrentlyRegistered                 # CASContainer (set operations)

    # Completion context (lightweight updates, high frequency)
    const completion_resolver_info::CompletionResolverInfo          # CASContainer (simple replacement)

    # Workspace folders (lightweight updates, very infrequent)
    const workspaceFolders::WorkspaceFolders                        # CASContainer (vector replacement)
end
```

Design principles:
1. Synchronization mechanism selection based on update function weight
   - Sequential writes → `SWContainer` (no concurrency needed)
   - Lightweight `f` (ns-range operations) → `CASContainer` (lock-free)
   - Heavy `f` (µs-ms operations, I/O) → `LWContainer` (lock serialization)
   - Complex multi-URI updates → `AnalysisManager` (queuing)

2. Maximizing lock-free reads
   - All read operations are lock-free
   - Atomic operations ensure consistent state

3. Clear separation of responsibilities
   - Each field has a single responsibility
   - Update patterns are clearly defined

#### 3.2.1 `FileCache` / `SavedFileCache` / `TestsetInfosCache`

Problem: Conflicts when updating per-URI values

Solution: Use `SWContainer` (see Section 2.4)
```julia
# Type aliases
const FileCache         = SWContainer{Base.PersistentDict{URI,FileInfo}}
const SavedFileCache    = SWContainer{Base.PersistentDict{URI,SavedFileInfo}}
const TestsetInfosCache = SWContainer{Base.PersistentDict{URI,Vector{TestsetInfo}}}
```

These are only updated by document synchronization messages (`didOpen`, `didChange`, `didSave`, `didClose`), ensuring sequential processing.

#### 3.2.2 `ConfigManager`

Problem: Updates occurring during configuration reads

Solution: Use `LWContainer` for heavy update operations

Update operations involve:
- TOML file parsing (`TOML.tryparsefile`)
- Unknown key validation (recursive traversal)
- Configuration merging (recursive dict operations)
- User notification via `show_warning_message` (side effect)

```julia
mutable struct ConfigManager
    container::LWContainer{ConfigManagerData}
end

struct ConfigManagerData
    reload_required_setting::Dict{String,Any}
    watched_files::WatchedConfigFiles  # Priority-sorted config files
end

# Read: lock-free, very frequent
function get_config(manager::ConfigManager, key_path::String...)
    data = load(manager.container)
    # Search in priority order through watched_files
    for config in values(data.watched_files)
        v = access_nested_dict(config, key_path...)
        v !== nothing && return v
    end
    return nothing
end

# Update: heavy operations with file I/O and side effects
function merge_config!(manager::ConfigManager, filepath::String, new_config::Dict)
    store!(manager.container) do old_data
        # 1. Parse TOML file (file I/O)
        parsed = TOML.tryparsefile(filepath)
        # 2. Validate unknown keys (recursive traversal)
        unknown_keys = collect_unmatched_keys(parsed)
        # 3. Merge configuration (recursive dict operations)
        new_data = copy_and_merge(old_data, filepath, parsed)
        # 4. Send warnings if needed (side effect)
        return new_data, nothing
    end
end
```

#### 3.2.3 `ExtraDiagnostics`

Problem: Concurrent access to test execution result diagnostics

Solution: Use `CASContainer`
```julia
mutable struct ExtraDiagnostics
    container::CASContainer{ExtraDiagnosticsData}
end

struct ExtraDiagnosticsData
    keys::Dict{UInt,ExtraDiagnosticsKey}
    values::Dict{UInt,URI2Diagnostics}
end

# Read: lock-free
function Base.values(extra_diagnostics::ExtraDiagnostics)
    data = load(extra_diagnostics.container)
    return values(data.values)
end

# Update: add/update diagnostics
function Base.setindex!(extra_diagnostics::ExtraDiagnostics, val::URI2Diagnostics, key::ExtraDiagnosticsKey)
    store!(extra_diagnostics.container) do old_data
        # Simple dict copy and update - lightweight operation
        new_data = copy_and_update(old_data, key, val)
        return new_data, nothing
    end
end
```

#### 3.2.4 `AnalysisManager` and `analysis_cache`

Problems:
- `AnalysisEntry` performs analysis across multiple URIs
- Need to allow read access during analysis
- Multiple analyses may execute concurrently
- Need to handle duplicate requests for the same `AnalysisEntry`

Solution: Serialization and queuing of analysis execution with `AnalysisManager`

```julia
mutable struct AnalysisManager
    # Current analysis results (read-only)
    @atomic cache::Dict{URI,AnalysisInfo}

    # Track running analyses (per AnalysisEntry)
    const analyzing::Dict{AnalysisEntry,AnalysisTask}
    const analyzing_lock::ReentrantLock

    # Analysis queue (serial execution per AnalysisEntry)
    const queue::Channel{AnalysisRequest}
    const worker_task::Task
end

struct AnalysisTask
    started_at::Float64
    pending_requests::Vector{AnalysisRequest}  # Hold duplicate requests
end

struct AnalysisRequest
    entry::AnalysisEntry
    reanalyze::Bool
    token::Union{Nothing,ProgressToken}
    callback::Union{Nothing,Channel{AnalysisResult}}  # For completion notification
end

# Read: completely lock-free
function get_analysis_info(manager::AnalysisManager, uri::URI)
    cache = manager.cache  # Atomic read
    return get(cache, uri, nothing)
end

# Analysis request: add to queue
function request_analysis!(manager::AnalysisManager, entry::AnalysisEntry;
                          reanalyze::Bool=false,
                          token::Union{Nothing,ProgressToken}=nothing,
                          wait::Bool=false)
    callback = wait ? Channel{AnalysisResult}(1) : nothing
    request = AnalysisRequest(entry, reanalyze, token, callback)
    put!(manager.queue, request)

    if wait
        result = take!(callback)
        return result.success ? result.result : nothing
    end
    return nothing
end

# Worker task: process queue sequentially
function analysis_worker(manager::AnalysisManager)
    while true
        request = take!(manager.queue)

        # Check if already analyzing
        @lock manager.analyzing_lock begin
            if haskey(manager.analyzing, request.entry)
                # Hold duplicate request
                push!(manager.analyzing[request.entry].pending_requests, request)
                continue
            end
            # Record analysis start
            manager.analyzing[request.entry] = AnalysisTask(time(), AnalysisRequest[])
        end

        # Execute analysis (outside lock)
        result = execute_analysis(request)

        # Publish results
        if result.success
            update_analysis_cache!(manager, result)
        end

        # Process pending requests
        pending = @lock manager.analyzing_lock begin
            task = pop!(manager.analyzing, request.entry)
            task.pending_requests
        end

        # Callback notification
        request.callback !== nothing && put!(request.callback, result)

        # Queue reanalysis if pending requests exist
        if !isempty(pending)
            latest = last(pending)
            put!(manager.queue, AnalysisRequest(
                latest.entry, true, latest.token, latest.callback
            ))
        end
    end
end

# Cache update: atomically publish new cache
function update_analysis_cache!(manager::AnalysisManager, result::AnalysisResult)
    analysis_unit = AnalysisUnit(result.entry, result.result)
    analyzed_uris = keys(result.result.analyzed_file_infos)

    # Prepare new cache
    new_cache = copy(manager.cache)

    for uri in analyzed_uris
        analysis_info = get(new_cache, uri, nothing)

        if analysis_info === nothing || analysis_info isa OutOfScope
            new_cache[uri] = Set{AnalysisUnit}([analysis_unit])
        else
            # Copy and update existing Set
            new_info = copy(analysis_info)
            # Remove old version
            filter!(au -> au.entry != analysis_unit.entry, new_info)
            # Add new version
            push!(new_info, analysis_unit)
            new_cache[uri] = new_info
        end
    end

    # Atomically publish
    @atomic manager.cache = new_cache
end
```

#### 3.2.5 `AnalysisUnit` and `FullAnalysisResult`

Problems:
- Consistency during concurrent access to analysis results
- Avoid showing intermediate states during updates

Solution: Immutable design
```julia
# Completely immutable analysis result
struct FullAnalysisResult
    actual2virtual::JET.Actual2Virtual
    analyzer::LSAnalyzer
    uri2diagnostics::URI2Diagnostics
    analyzed_file_infos::Dict{URI,JET.AnalyzedFileInfo}
    successfully_analyzed_file_infos::Dict{URI,JET.AnalyzedFileInfo}
end

struct AnalysisUnit
    entry::AnalysisEntry
    result::FullAnalysisResult
end

# Updates create new instances
function create_updated_result(old_result::FullAnalysisResult, jet_result)
    new_uri2diagnostics = copy(old_result.uri2diagnostics)
    # ... diagnostic update processing

    return FullAnalysisResult(
        jet_result.actual2virtual,
        update_analyzer_world(jet_result.analyzer),
        new_uri2diagnostics,
        new_analyzed_file_infos,
        new_successfully_analyzed_file_infos
    )
end
```

Design advantages:
1. Complete serialization: Analysis executes serially per `AnalysisEntry`
2. Lock-free reads: Atomic operations always read consistent state
3. Duplicate request handling: Properly manages concurrent requests for same Entry
4. Immutable design: `AnalysisResult` is immutable, safe for concurrent access
5. Clear separation of responsibilities: `AnalysisManager` handles execution, cache handles result lookup

#### 3.2.6 `currently_requested`

Problem: Concurrent access to server→client request ID management

Usage pattern:
- High-frequency request additions/deletions
- Assign unique IDs to track `RequestCaller`
- Retrieve and delete corresponding `RequestCaller` on response reception

Solution: Use `CASContainer` (lightweight dict operations)

```julia
const CurrentlyRequested = CASContainer{Base.PersistentDict{String,RequestCaller}}

function addrequest!(cr::CurrentlyRequested, id::String, caller::RequestCaller)
    return store!(cr) do data
        Base.PersistentDict(data, id=>caller), caller
    end
end

function poprequest!(cr::CurrentlyRequested, id::String)
    return store!(cr) do data
        if haskey(data, id)
            caller = data[id]
            return Base.delete(data, id), caller
        end
        return data, nothing
    end
end
```

#### 3.2.7 `currently_registered`

Problem: Concurrent access to dynamic capability registration duplicate management

Usage pattern:
- Infrequent registration/unregistration
- Duplicate registration prevention needed
- Used by LSP dynamic registration feature

Solution: Use `CASContainer` (lightweight set operations)

```julia
const CurrentlyRegistered = CASContainer{Set{Registered}}

function register!(cr::CurrentlyRegistered, reg::Registered)
    return store!(cr) do data
        if reg ∉ data
            new_data = copy(data)
            push!(new_data, reg)
            return new_data, true
        end
        return data, false
    end
end

function unregister!(cr::CurrentlyRegistered, reg::Registered)
    return store!(cr) do data
        if reg ∈ data
            new_data = copy(data)
            delete!(new_data, reg)
            return new_data, true
        end
        return data, false
    end
end
```

#### 3.2.8 `completion_resolver_info`

Problem: Concurrent access to completion resolution information

Usage pattern:
- Set module and postprocessor during completion list generation (frequent)
- Reference during completion item resolution (frequent)

Solution: Use `CASContainer`

```julia
const CompletionResolverInfo = CASContainer{Union{Nothing,CompletionResolverInfo}}

# Write: during completion list generation
function set_resolver_info!(container::CompletionResolverInfo, info::CompletionResolverInfo)
    store!(container) do _
        info, nothing
    end
end

# Read: during completion item resolution (lock-free)
function get_resolver_info(container::CompletionResolverInfo)
    return load(container)
end
```

#### 3.2.9 `workspaceFolders`

Problem: Concurrent access to workspace folder list

Usage pattern:
- Very infrequent updates (modified only on initialization and workspace folder changes notification)
- Read during file path resolution

Solution: Use `CASContainer` (simple vector replacement)

```julia
const WorkspaceFolders = CASContainer{Vector{URI}}
```

#### 3.2.10 `debounce`/`throttle`

Solution: Current implementation already uses `ReentrantLock`

```julia
# Current implementation in src/utils/general.jl
begin
    local debounced_lock, debounced
    global debounce
    debounced_lock = ReentrantLock()
    debounced = Dict{UInt, Timer}()
    function debounce(f, id::UInt, delay)
        lock(debounced_lock) do
            if haskey(debounced, id)
                close(debounced[id])
            end
            debounced[id] = Timer(delay) do _
                f()
                lock(debounced_lock) do
                    delete!(debounced, id)
                end
            end
        end
        nothing
    end
end
```

Design evaluation:
- Current implementation is already thread-safe
- Uses global lock, which is reasonable because:
  - Lock-held processing is very lightweight
  - Timer management inherently requires synchronization
- Lock acquisition in timer callback is properly implemented

Recommendation: Maintain current implementation

### 3.3 Global State

- `currently_running::Server`: Global server instance
- `DEFAULT_CONFIG::Dict`: Global configuration dictionary
- `CONFIG_RELOAD_REQUIRED::Dict`: Configuration requiring reload
- `LS_ANALYZER_CACHE::Dict`: Analyzer cache

No additional thread safety measures needed for these global states

#### 3.3.1 `currently_running`
- Purpose: Global reference for debugging (e.g., `currently_running.documents[uri]`)
- Thread safety: Not used in normal server loop, so no synchronization needed

#### 3.3.2 Configuration-related global variables
- `DEFAULT_CONFIG`: Default configuration dictionary
- `CONFIG_RELOAD_REQUIRED`: Definition of configuration keys requiring reload
- Thread safety:
  - Read-only during normal server operation
  - Only modified during test execution
  - Tests run single-threaded, so no conflicts

#### 3.3.3 `LS_ANALYZER_CACHE`
- Purpose: `AnalysisToken` cache (`src/analysis/Analyzer.jl:113`)
- Access pattern:
  ```julia
  analysis_cache_key = JET.compute_hash(entry, state.inf_params)
  analysis_token = get!(AnalysisToken, LS_ANALYZER_CACHE, analysis_cache_key)
  ```
- Thread safety:
  - Full analyses each run single-threaded and serially
  - Cache keys computed from analysis target and inference parameters, no collisions
  - No conflicts in current architecture

Design evaluation:
- Current global state usage patterns are thread-safe
- Only used for debugging, testing, or serially executed processing
- No additional synchronization mechanisms needed

### 3.4 External Resources

#### 3.4.1 Formatter

Problem: External process conflicts
```julia
proc = open(`$exe`; read = true, write = true)
write(proc, text)
ret = read(proc)
```

Solution: [Design under consideration]

#### 3.4.2 TestRunner

Problems:
- Background task management
- Temporary file collisions
- Insufficient cleanup of hung tests

Solution: [Design under consideration]

#### 3.4.3 File I/O

Problem: TOCTOU (Time-of-Check-Time-of-Use) race conditions
```julia
if !isfile(config_path)  # Check
    # Another thread might create/delete file here
    # Later use
```

Solution: [Design under consideration]

## 4. Implementation Strategy

Proceed with parallelization safely by confirming tests pass at each step through phased implementation:
- Phase 1: Implement and test basic data structures
- Phase 2: Component parallelization
- Phase 3: Message handler parallelization

### 4.1 Phase 1: Implement `AtomicContainers`

Implement thread-safe data structures as the foundation for parallelization:
- `SWContainer`: Generic container with lock-free reads and sequential writes
- `LWContainer`: Generic container with lock-free reads and lock-serialized writes
- `CASContainer`: Generic container with lock-free reads and writes with CAS loop (will be used in the future)
- `AnalysisManager`: Queuing system to serialize analysis execution

Create unit tests for each data structure to verify concurrent access safety.

### 4.2 Phase 2: Component Parallelization

Migrate each `ServerState` field to new data structures:
- `file_cache`, `saved_file_cache`, `testsetinfos_cache`
- `config_manager`, `extra_diagnostics`
- `analysis_cache` → `AnalysisManager`

At this phase, message handling remains serial. Confirm all existing tests pass.

### 4.3 Phase 3: Message Handler Parallelization

Classify messages into sequential and parallel processing:
- Sequential: lifecycle, document synchronization, cancellation
- Parallel: read-only operations like completion, hover, definition
