---
file-created: 2025-08-23T23:27
file-modified: 2025-09-12T21:05
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
        # Process synchronously (processed within the main server loop thread `:default`)
        # N.B. Each message handling should be fast: ~1-2ms
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

## 3. Component-Specific Design

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
| `workspaceFolders` | None needed* | - | Only updated during initialization |
| `analysis_manager` | Queue | Very heavy | Complex multi-URI analysis |

Key insight: Most updates are lightweight dict/set/vector operations
(ns-range), making `CASContainer` optimal. Only `config_manager` (file I/O,
parsing) and `analysis_manager` (full analysis) require heavier synchronization.

```julia
mutable struct ServerState
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

    # Lifecycle fields (written once at initialization, no locking needed)
    workspaceFolders::Vector{URI}
    encoding::PositionEncodingKind.Ty
    root_path::String
    root_env_path::String
    init_params::InitializeParams
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

#### 3.2.1 `file_cache` / `saved_file_cache` / `testsetinfos_cache`

These fields are updated during document synchronization, but since
document-synchronization notifications are handled sequentially,
writes can be assumed to occur sequentially.
Due to frequent writes, we adopt the most efficient `SWContainer`.
```julia
# Type aliases
const FileCache         = SWContainer{Base.PersistentDict{URI,FileInfo}}
const SavedFileCache    = SWContainer{Base.PersistentDict{URI,SavedFileInfo}}
const TestsetInfosCache = SWContainer{Base.PersistentDict{URI,Vector{TestsetInfo}}}
```

> [!note]
> For future extensions, it's possible to add caches for lowered/inferred code to `FileInfo`.
> Even in that case, these fields would continue to be managed with `SWContainer`, while using
> `CWContainer` for those code caches to ensure safety against parallel writes.

#### 3.2.2 `config_manager`

Update operations involve:
- TOML file parsing (`TOML.tryparsefile`)
- Unknown key validation (recursive traversal)
- Configuration merging (recursive dict operations)
- User notification via `show_warning_message` (side effect)

Use `LWContainer` for update operations as the retry should be avoided.

```julia
struct ConfigManagerData # Renamed from ConfigManager, immutable now
    static_settings::ConfigDict
    watched_files::WatchedConfigFiles
end

const ConfigManager = LWContainer{ConfigManagerData, LWStats}
```

#### 3.2.3 `extra_diagnostics`

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

#### 3.2.4 `currently_requested`

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

#### 3.2.5 `currently_registered`

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

#### 3.2.6 `completion_resolver_info`

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

#### 3.2.7 Lifecycle fields

Lifecycle fields like `workspaceFolders` currently only gets written during
initialization, thus no locking needed.
If we implement `workspace/didChangeWorkspaceFolders` notification or
`workspace/workspaceFolders` request handling in the future,
the `workspaceFolders` field for example will need thread-safe container.

#### 3.2.8 `debounce`/`throttle`

These features are used exclusively in full-analysis, but the current
implementation is not thread-safe.
When implementing concurrent full-analysis with a queue-based `AnalysisManager`,
these features will be implemented as part of the `AnalysisManager` functionality,
so the existing implementation will simply be deleted.

### 3.3 Global State

No additional thread safety measures needed for these global states,
because these objects are either completely constant or used for debugging only:
- `DEFAULT_CONFIG::ConfigDict`
- `STATIC_CONFIG::ConfigDict`
- `currently_running::Server`

> [!note]
> `LS_ANALYZER_CACHE` is another global constant which maybe be modified during
> full analysis, but `LS_ANALYZER_CACHE` is only referenced within full analysis,
> and full analysis execution itself is performed in an independently
> thread-safe manner, so there is no need to worry about conflicts with other
> parallel executions.

### 3.4 External Resources

[Design under consideration]

- Formatter process
- TestRunner process

## 4. Multithreading Full-Analysis

This section describes the design for parallelizing full analyses, which are the
most computationally intensive operations in JETLS.

### 4.1 Overview

Full analysis involves analyzing an entire codebase starting from an `AnalysisEntry`
(script, package source, or test suite). The challenge is to:
- Allow multiple analyses to run concurrently for different entries
- Maintain consistent view of analysis results during updates
- Handle duplicate analysis requests efficiently
- Provide lock-free read access to analysis results

### 4.2 `AnalysisManager` Architecture

The `AnalysisManager` coordinates all full analyses using a queue-based architecture:
1. Queue-based execution: All analysis requests go through a central queue,
   ensuring controlled concurrency and preventing resource exhaustion.
2. Per-entry serialization: Multiple analyses for the same `AnalysisEntry`
   are serialized to avoid duplicate work and ensure consistency.
3. Atomic cache updates: The entire cache is updated atomically, ensuring
   readers always see a consistent state.
4. Duplicate request coalescing: When multiple requests arrive for the same
   entry while it's being analyzed, only the latest request is kept as pending
   and processed after the current analysis completes.

> [!note] Single-threaded Implementation First
>
> Initially, `AnalysisManager` will run with a single worker task. This is because:
> - Julia's compiler infrastructure and JET are not yet fully thread-safe
> - Full analysis involves type inference which modifies global compiler state
>
> However, the architecture is designed to easily scale to multiple workers once
> thread-safety is achieved. The per-entry serialization mechanism ensures
> correctness regardless of the number of workers.

```julia
abstract type AnalysisEntry end

struct FullAnalysisResult # immutable now
    actual2virtual::JET.Actual2Virtual
    analyzer::LSAnalyzer
    uri2diagnostics::URI2Diagnostics                     # new instance for each result
    analyzed_file_infos::Dict{URI,JET.AnalyzedFileInfo}  # new instance for each result
end

struct AnalysisUnit
    entry::AnalysisEntry
    result::FullAnalysisResult
end

struct OutOfScope
    module_context::Module
end

const AnalysisInfo = Union{Set{AnalysisUnit},OutOfScope}

struct AnalysisManager
    # Current analysis results (lock-free reads, heavy updates)
    cache::LWContainer{Dict{URI,AnalysisInfo}}

    # Track running analyses (lightweight updates)
    analyzing::CASContainer{Dict{AnalysisEntry,Union{Nothing,AnalysisRequest}}}

    # Analysis queue (serial execution per AnalysisEntry)
    queue::Channel{AnalysisRequest}
    worker_tasks::Vector{Task}  # Currently single task, future: multiple workers

    # Track analyzed entries (lightweight updates)
    analyzed_entries::CASContainer{Set{AnalysisEntry}}

    # Debouncing management (timer close has side effects)
    debounced::LWContainer{Dict{AnalysisEntry,Timer}}
end

# Constructor: initially single-threaded
function AnalysisManager()
    manager = AnalysisManager(
        LWContainer(Dict{URI,AnalysisInfo}()),
        CASContainer(Dict{AnalysisEntry,Union{Nothing,AnalysisRequest}}()),
        Channel{AnalysisRequest}(Inf),
        Task[],  # Will contain single worker initially
        CASContainer(Set{AnalysisEntry}()),
        LWContainer(Dict{AnalysisEntry,Timer}())
    )
    # Start single worker (future: parameterize worker count)
    worker = Threads.@spawn :default analysis_worker(manager)
    push!(manager.worker_tasks, worker)
    return manager
end

struct AnalysisRequest
    server::Server                      # Server instance for sending notifications
    entry::AnalysisEntry
    token::Union{Nothing,ProgressToken} # Progress notification token
    onsave::Bool                        # i.e. "reanalyze"
end
```

### 4.3 Per-Entry Serialization

The `AnalysisManager` ensures that multiple analyses for the same `AnalysisEntry`
are properly serialized:

- When a request arrives for an entry that's currently being analyzed, it replaces
  any existing pending request in the `analyzing` dictionary
- Only the latest pending request is kept (newer requests replace older ones)
- After an analysis completes, the pending request (if any) is re-queued
- This naturally prevents duplicate analyses without complex timing mechanisms

### 4.4 Debouncing and Throttling

In the queue-based architecture, throttling becomes unnecessary while debouncing
remains valuable:

Why throttling is unnecessary:
- Per-entry serialization naturally prevents overlapping analyses
- Pending requests automatically coalesce (only the latest is kept)
- No risk of multiple concurrent timers for the same analysis unit

Why debouncing is still useful:
- Rapid save events can flood the queue with redundant requests
- Debouncing at the request level prevents unnecessary queueing
- Reduces worker wake-ups and improves overall efficiency

> [!note]
> The key insight: throttling was a workaround for the inability to cancel
> obsolete analyses once they started. The queue-based design solves this > fundamentally.
>
> Problem in the old timer-based system:
> - Events:
>   * 0s: Save event → `Timer` A created for analysis unit X
>   * 0.1s: Analysis 1 starts from `Timer` A (takes 10s)
>   * 1s: Save event → `Timer` B created for same unit X
>   * 2s: Save event → `Timer` C created for same unit X
>   * 10.1s: Analysis 1 completes
>   * 10.2s: Analysis 2 starts from `Timer` B (takes 10s) [stale - fi  * ged at 2s!]
>   * 20.2s: Analysis 2 completes
>   * 20.3s: Analysis 3 starts from Timer C (takes 10s)
>   * 30.3s: Analysis 3 completes (finally current)
> - Result: 3 full analyses ran sequentially, but the analysis 2 was obsolete when it started.
> - Workaround: By setting e.g. `throttling == 5.0`, we can skip the analysis 2 and 3.
>   But we actually don't want to skip analysis 3.
>
> Solution in the queue-based system:
> - Events:
>   * 0s: Save event → Request A queued for analysis unit X
>   * 0.1s: Worker takes Request A → Starts Analysis 1 (takes 10s)
>   * 1s: Save event → Request B queued
>   * 1s: Worker sees unit X is analyzing → Request B becomes pending
>   * 2s: Save event → Request C queued
>   * 2s: Worker sees unit X is analyzing → Request C replaces B (B discarded)
>   * 10.1s: Analysis 1 completes → Request C (latest) is re-queued
>   * 10.1s: Worker takes Request C → Starts Analysis 2 with latest state
>   * 20.1s: Analysis 2 completes (current state analyzed)
> - Result: Only 2 analyses ran, intermediate request was properly discarded.

### 4.5 Cache Invalidation Mechanism

The cache invalidation mechanism replaces the mutable `staled` field:

```julia
# Called from request_analysis! when onsave=true (triggered by DidSave notification)
function invalidate_cache!(manager::AnalysisManager, uri::URI)
    analysis_info = get_analysis_info(manager, uri)
    if analysis_info isa Set{AnalysisUnit}
        # Remove entries from analyzed set - will trigger re-analysis
        store!(manager.analyzed_entries) do entries
            new_entries = copy(entries)
            for au in analysis_info
                delete!(new_entries, au.entry)
            end
            return new_entries, nothing
        end
    end
end

# Check if analysis is needed (called in worker after dequeuing but before execute_analysis)
should_analyze(manager::AnalysisManager, entry::AnalysisEntry) =
    !(entry in load(manager.analyzed_entries))  # Analyze if not in set

# Mark entry as analyzed after successful analysis
function mark_analyzed!(manager::AnalysisManager, entry::AnalysisEntry)
    store!(manager.analyzed_entries) do entries
        new_entries = copy(entries)
        push!(new_entries, entry)
        return new_entries, nothing
    end
end
```

### 4.6 Operations

#### Read Operation (Lock-free)
```julia
get_analysis_info(manager::AnalysisManager, uri::URI) =
    get(load(manager.cache), uri, nothing)
```

#### Request Analysis

```julia
function request_analysis!(
        server::Server, uri::URI;
        onsave::Bool = false, # meaning `reanalyze`
        token::Union{Nothing,ProgressToken} = nothing
    )
    manager = server.state.analysis_manager
    entry = get_analysis_entry(server, uri)

    # Handle special cases where analysis cannot proceed
    if isnothing(entry)
        # Parse error or other issue - cannot analyze
        return nothing
    end

    if entry isa OutOfScope
        # Record as out of scope in cache
        store!(manager.cache) do cache
            merge(cache, Dict(uri => entry)), nothing
        end
        return nothing
    end

    # Invalidate cache if this is a save event
    if onsave
        invalidate_cache!(manager, uri)
    end

    # Apply debouncing for save events
    if onsave && (debounce_delay = get_config(server.state.config_manager, "full_analysis", "debounce")) > 0
        store!(manager.debounced) do timers
            new_timers = copy(timers)
            # Cancel existing timer if any
            if haskey(new_timers, entry)
                close(new_timers[entry])
            end
            # Set new debounced request
            new_timers[entry] = Timer(debounce_delay) do _
                store!(manager.debounced) do t
                    new_t = copy(t)
                    delete!(new_t, entry)
                    return new_t, nothing
                end
                # Queue the request after debounce period
                put!(manager.queue, AnalysisRequest(server, entry, token, onsave))
            end
            return new_timers, nothing
        end
    else
        # Immediate queueing for non-save or no-debounce
        put!(manager.queue, AnalysisRequest(server, entry, token, onsave))
    end

    return nothing
end
```

#### Determining Analysis Entry

The key motivation for separating entry determination from analysis execution is,
by computing the `AnalysisEntry` before queueing, multiple URIs that map to the
same analysis unit (e.g., different files in the same package) will produce
identical entries before analysis for each is executed. The queue mechanism then
naturally deduplicates these requests, preventing redundant analyses.

```julia
function get_analysis_entry(server::Server, uri::URI)::Union{Nothing,AnalysisEntry,OutOfScope}
    state = server.state

    # Check if saved file info exists and is parseable
    fi = get_saved_file_info(state, uri)
    if isnothing(fi) || !isempty(fi.parsed_stream.diagnostics)
        return nothing
    end

    # Determine analysis environment
    env_path = find_analysis_env_path(state, uri)
    if env_path isa OutOfScope
        # Return OutOfScope marker - caller will handle cache update
        return env_path
    end

    # Special cases
    if uri.scheme == "untitled"
        return ScriptAnalysisEntry(uri)
    end

    # No environment or no package name -> standalone script
    if isnothing(env_path)
        return ScriptAnalysisEntry(uri)
    end

    pkgname = find_pkg_name(env_path)
    if isnothing(pkgname)
        return ScriptInEnvAnalysisEntry(env_path, uri)
    end

    # Package analysis - determine file kind
    filepath = uri2filepath(uri)::String
    filekind, filedir = find_package_directory(filepath, env_path)

    if filekind === :src
        # Package source files - find main module file
        pkgenv = Base.identify_package_env(pkgname)
        if isnothing(pkgenv)
            # Failed to identify package - treat as script
            return ScriptInEnvAnalysisEntry(env_path, uri)
        end
        pkgid, _ = pkgenv
        pkgfile = Base.locate_package(pkgid, env_path)
        if isnothing(pkgfile)
            # No main file found - treat as script
            return ScriptInEnvAnalysisEntry(env_path, uri)
        end
        # Important: All source files map to the same PackageSourceAnalysisEntry
        # with the main module file as the entry point
        return PackageSourceAnalysisEntry(env_path, filepath2uri(pkgfile), pkgid)

    elseif filekind === :test
        # Test files - use runtests.jl as entry point
        runtestsfile = joinpath(filedir, "runtests.jl")
        if !isfile(runtestsfile)
            return ScriptInEnvAnalysisEntry(env_path, uri)
        end
        # Important: All test files map to the same PackageTestAnalysisEntry
        return PackageTestAnalysisEntry(env_path, filepath2uri(runtestsfile))

    elseif filekind === :docs
        # Documentation files - currently treated as scripts
        # TODO: Could analyze doc examples
        return ScriptInEnvAnalysisEntry(env_path, uri)

    elseif filekind === :ext
        # Extension files - currently treated as scripts
        # TODO: Could analyze as package extensions
        return ScriptInEnvAnalysisEntry(env_path, uri)

    else
        # Unknown file kind - treat as script in environment
        return ScriptInEnvAnalysisEntry(env_path, uri)
    end
end
```

#### Worker Task
```julia
function analysis_worker(manager::AnalysisManager)
    # Note: Currently single worker, but designed for future multi-worker scaling
    # When multiple workers exist, the per-entry locking ensures correctness

    while true
        request = take!(manager.queue)

        # Check if already analyzing this entry
        is_analyzing = store!(manager.analyzing) do analyzing
            if haskey(analyzing, request.entry)
                # Keep only the latest request as pending
                new_analyzing = copy(analyzing)
                new_analyzing[request.entry] = request
                return new_analyzing, true  # Already analyzing
            end
            # Mark as analyzing (no pending request yet)
            new_analyzing = copy(analyzing)
            new_analyzing[request.entry] = nothing
            return new_analyzing, false  # Not analyzing
        end

        if is_analyzing
            continue  # Skip to next request
        end

        server = request.server

        # Check if analysis is actually needed
        if !should_analyze(manager, request.entry)
            # Skip analysis - already up to date
            @goto next
        end

        if request.token !== nothing
            title = request.onsave ? "Reanalyzing" : "Analyzing"
            filename = basename(uri2filename(entryuri(request.entry)))
            send_progress_begin(server, request.token,
                               "$title $filename [$(entrykind(request.entry))]")
        end

        # Execute the analysis with error handling
        result = try
            execute_analysis(manager, request)
        catch err
            @error "Analysis failed" exception=(err, catch_backtrace()) entry=request.entry
            nothing  # Return nothing on error
        end

        if request.token !== nothing
            send_progress_end(server, request.token)
        end

        if result !== nothing
            update_analysis_cache!(manager, request.entry, result)
            mark_analyzed!(manager, request.entry)
            notify_diagnostics!(server)
        end

        @label next

        # Check for pending request and re-queue if needed
        pending_request = store!(manager.analyzing) do analyzing
            if haskey(analyzing, request.entry)
                new_analyzing = copy(analyzing)
                pending = delete!(new_analyzing, request.entry)
                return new_analyzing, pending
            end
            return analyzing, nothing
        end
        if pending_request !== nothing
            # Re-queue the pending request for processing
            put!(manager.queue, pending_request)
        end
    end
end
```

> [!note] Future Multi-threading Support
>
> When Julia's compiler and JET become thread-safe, scaling to multiple workers is trivial:
> ```julia
> function start_analysis_workers(manager::AnalysisManager, n_workers::Int)
>     for i in 1:n_workers
>         worker = Threads.@spawn :default analysis_worker(manager)
>         push!(manager.worker_tasks, worker)
>     end
> end
> ```

#### Cache Update
```julia
function update_analysis_cache!(manager::AnalysisManager, entry::AnalysisEntry, result::FullAnalysisResult)
    analysis_unit = AnalysisUnit(entry, result)
    analyzed_uris = keys(result.analyzed_file_infos)

    # Update cache atomically
    store!(manager.cache) do cache
        new_cache = copy(cache)

        for uri in analyzed_uris
            analysis_info = get(new_cache, uri, nothing)

            if analysis_info === nothing || analysis_info isa OutOfScope
                new_cache[uri] = Set{AnalysisUnit}([analysis_unit])
            else
                # Copy and update existing Set with subset management
                new_info = copy(analysis_info)

                # Manage subset relationships for correct file association
                afiles = analyzed_uris
                should_record = true
                for au in collect(new_info)  # Collect to avoid mutation during iteration
                    if au.entry == analysis_unit.entry
                        delete!(new_info, au)  # Remove old version
                        continue
                    end

                    bfiles = keys(au.result.analyzed_file_infos)
                    if afiles ≠ bfiles
                        if afiles ⊆ bfiles
                            should_record = false  # Don't record subset
                        elseif bfiles ⊆ afiles
                            delete!(new_info, au)  # Remove old subset
                        end
                    end
                end

                # Add new version if it's not a subset
                if should_record
                    push!(new_info, analysis_unit)
                end
                new_cache[uri] = new_info
            end
        end

        return new_cache, nothing  # Return updated cache
    end
end
```

### 4.7 File Deletion and Cache Cleanup

When files are deleted or removed from the project scope:

```julia
# Called when a file is deleted (from didClose or file system watch)
function remove_from_cache!(manager::AnalysisManager, uri::URI)
    # Remove from analyzed entries
    store!(manager.analyzed_entries) do entries
        analysis_info = get_analysis_info(manager, uri)
        if analysis_info isa Set{AnalysisUnit}
            new_entries = copy(entries)
            for au in analysis_info
                delete!(new_entries, au.entry)
            end
            return new_entries, nothing
        end
        return entries, nothing
    end

    # Remove from cache
    store!(manager.cache) do cache
        new_cache = copy(cache)
        delete!(new_cache, uri)
        return new_cache, nothing
    end
end
```

This ensures proper cleanup when:
- Files are deleted from the file system
- Files are closed and no longer tracked
- Files move out of project scope

> [!note]
> Currently JETLS doesn't subscribe to `workspace/didDeleteFiles` notification,
> so there's no place to call `remove_from_cache!` yet. This should be implemented
> in the future to properly handle file deletions.

### 4.8 Implementation Considerations

The following points need to be addressed when implementing the new design:

1. Progress notification integration
   - Caller creates token and passes it to `request_analysis!`
   - Worker sends progress notifications using the provided token
   - No special handling needed for async token creation

2. Error handling
   - Wrap `execute_analysis` with try/catch to prevent worker crash
   - Log errors with `@error` for debugging
   - Return `nothing` on failure (skip cache update)
   - User notification to be addressed in future

3. Initial vs re-analysis unification
   - `execute_analysis` will handle both initial and re-analysis cases
   - Check if entry exists in cache to determine which case

## 5. Implementation Strategy

Proceed with parallelization safely by confirming tests pass at each step through phased implementation:
- Phase 1: Implement and test basic data structures
- Phase 2: `ServerState` parallelization
- Phase 3: Full-analysis parallelization
- Phase 4: Message handler parallelization

### 5.1 Phase 1: Implement `AtomicContainers`

Implement thread-safe data structures as the foundation for parallelization:
- `SWContainer`: Generic container with lock-free reads and sequential writes
- `LWContainer`: Generic container with lock-free reads and lock-serialized writes
- `CASContainer`: Generic container with lock-free reads and writes with CAS loop (will be used in the future)
- `AnalysisManager`: Queuing system to serialize analysis execution

Create unit tests for each data structure to verify concurrent access safety.

### 5.2 Phase 2: `ServerState` Parallelization

Migrate each `ServerState` field to new data structures (except `analysis_cache`).
At this phase, message handling remains serial. Confirm all existing tests pass.

### 5.3 Phase 3: Full-Analysis Parallelization

Migrate `analysis_cache` to `AnalysisManager` to enable concurrent full analyses.
See [[#4 Multithreading Full-Analysis]] for detailed design and implementation.

### 5.4 Phase 4: Message Handler Parallelization

Classify messages into sequential and parallel processing:
- Sequential: lifecycle, document synchronization, cancellation
- Parallel: read-only operations like completion, hover, definition
