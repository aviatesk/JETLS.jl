module AtomicContainers

export SWContainer, LWContainer, CASContainer, store!, load, getstats, resetstats!

abstract type AtomicContainer end
function load(::AtomicContainer) end
function store!(::AtomicContainer) end

abstract type AtomicStats end
function getstats(::AtomicStats) end
function resetstats!(::AtomicStats) end

# SWContainer
# ===========

"""
    SWStats

Statistics tracking for `SWContainer` operations. Collects performance metrics
about simple atomic store operations.
"""
mutable struct SWStats <: AtomicStats
    "Number of `store!` calls made to the container"
    @atomic attempts::Int
    "Total time spent in all `store!` operations (nanoseconds)"
    @atomic total_ns::UInt64
    "Total time spent executing the user function `f(old)` (nanoseconds)"
    @atomic f_ns::UInt64
    SWStats() = new(0, 0, 0)
end

"""
    getstats(stats::SWStats)

Retrieves performance statistics for simple atomic store operations.

# Returns
NamedTuple with fields:
- `attempts`: Total number of `store!` calls
- `total_ms`: Total time spent in all `store!` operations (milliseconds)
- `overhead_ms`: Total overhead time (total - f_time) in milliseconds
- `f_ms`: Total time spent executing user functions (milliseconds)
- `avg_total_ms`: Average time per `store!` call (milliseconds)
- `avg_overhead_ms`: Average overhead time per `store!` call (milliseconds)
- `avg_f_ms`: Average time per function execution (milliseconds)
- `overhead_share`: Fraction of time spent on overhead vs function execution
"""
function getstats(stats::SWStats)
    attempts = @atomic :monotonic stats.attempts
    total_ms = (@atomic :monotonic stats.total_ns) / 10^6
    f_ms = (@atomic :monotonic stats.f_ns) / 10^6
    avg_total_ms = attempts == 0 ? 0.0 : total_ms / attempts
    avg_f_ms = attempts == 0 ? 0.0 : f_ms / attempts
    overhead_ms = total_ms - f_ms
    avg_overhead_ms = attempts == 0 ? 0.0 : overhead_ms / attempts
    overhead_share = total_ms == 0.0 ? 0.0 : overhead_ms / total_ms
    return (; attempts, total_ms, overhead_ms, f_ms,
              avg_total_ms, avg_overhead_ms, avg_f_ms,
              overhead_share)
end

function resetstats!(stats::SWStats)
    @atomic :monotonic stats.attempts = 0
    @atomic :monotonic stats.total_ns = 0
    @atomic :monotonic stats.f_ns = 0
    return stats
end

"""
    SWContainer{T}

Simple atomic container providing atomic reads and writes without locks or CAS loops.
Fastest option for sequential or non-contended updates.

!!! warning
    Concurrent writes are NOT safe.
    If correctness under contention is needed,
    use [`LWContainer`](@ref) or [`CASContainer`](@ref) containers instead.
"""
mutable struct SWContainer{T,Stats<:Union{Nothing,SWStats}} <: AtomicContainer
    @atomic data::T
    const stats::Stats
    SWContainer(data::T; withstats::Bool=false) where T =
        new{T, withstats ? SWStats : Nothing}(data, withstats ? SWStats() : nothing)
end

load(c::SWContainer) = @atomic :acquire c.data

"""
    store!(f, c::SWContainer{T}) -> new::T

Updates the data stored in an SWContainer.

## Arguments
- `f`: A function that takes the current value `old::T` and returns a new value `new::T`.

!!! warning
    This provides NO protection against concurrent writes. If multiple threads
    call `store!` simultaneously, updates may be lost. Use `CASContainer` or
    `LWContainer` for concurrent write safety.
"""
function store!(f, c::SWContainer) end

function store!(f, c::SWContainer{T,Nothing}) where T
    old = @atomic :acquire c.data
    new = f(old)::T
    @atomic :release c.data = new
    return new
end

function store!(f, c::SWContainer{T,SWStats}) where T
    t0 = time_ns()
    stats = c.stats
    @atomic :monotonic stats.attempts += 1
    old = @atomic :acquire c.data
    t_f_start = time_ns()
    new = f(old)::T
    t_f_end = time_ns()
    @atomic :release c.data = new
    @atomic :monotonic stats.f_ns += (t_f_end - t_f_start)
    @atomic :monotonic stats.total_ns += (time_ns() - t0)
    return new
end

getstats(c::SWContainer) = getstats(@something c.stats return nothing)
resetstats!(c::SWContainer) = resetstats!(@something c.stats return nothing)

# LWContainer
# ===========

"""
    LWStats

Statistics tracking for LWContainer operations. Collects performance metrics
about lock-based updates including contention and timing information.
"""
mutable struct LWStats <: AtomicStats
    "Number of times lock acquisition was blocked (had to wait)"
    @atomic contended::Int
    "Number of `store!` calls made to the container"
    @atomic attempts::Int
    "Total time spent in all `store!` operations (nanoseconds)"
    @atomic total_ns::UInt64
    "Total time spent waiting for lock acquisition (nanoseconds)"
    @atomic wait_ns::UInt64
    LWStats() = new(0, 0, 0, 0)
end

"""
    getstats(stats::LWStats)

Retrieve performance statistics for lock-based container operations.

- `attempts::Int`: Total number of `store!` calls
- `contended::Int`: Number of times lock acquisition was blocked
- `contention_rate::Float64`: Fraction of operations that had to wait (`contended/attempts`)
- `total_ms::Float64`: Total time spent in all `store!` operations (milliseconds)
- `wait_ms::Float64`: Total time spent waiting for lock acquisition (milliseconds)
- `f_ms::Float64`: Total time spent in successful `store!` operations (milliseconds)
- `avg_total_ms::Float64`: Average time spent in single `store!` operation (milliseconds)
- `avg_wait_ms::Float64`: Average time spent waiting for lock acquisition (milliseconds)
- `avg_f_ms::Float64`: Average time spent in successful `store!` operation (milliseconds)
- `lock_share::Float64`: Fraction of total time spent waiting (`wait_ms/total_ms`)
"""
function getstats(stats::LWStats)
    attempts = @atomic :monotonic stats.attempts
    contended = @atomic :monotonic stats.contended
    contention_rate = attempts == 0 ? 0.0 : contended / attempts
    total_ms = (@atomic :monotonic stats.total_ns) / 10^6
    wait_ms = (@atomic :monotonic stats.wait_ns) / 10^6
    f_ms = total_ms - wait_ms
    avg_total_ms = attempts == 0 ? 0.0 : total_ms / attempts
    avg_wait_ms = attempts == 0 ? 0.0 : wait_ms / attempts
    avg_f_ms = attempts == 0 ? 0.0 : f_ms / attempts
    lock_share = total_ms == 0.0 ? 0.0 : wait_ms / total_ms
    return (; attempts, contended, contention_rate,
              total_ms, wait_ms, f_ms, avg_total_ms, avg_wait_ms, avg_f_ms,
              lock_share)
end

function resetstats!(stats::LWStats)
    @atomic :monotonic stats.attempts = 0
    @atomic :monotonic stats.contended = 0
    @atomic :monotonic stats.total_ns = 0
    @atomic :monotonic stats.wait_ns = 0
    return stats
end

"""
    LWContainer{T}

Locked-Write Container: lock-free reads (atomic load), lock-serialized writes.

# When to use LW
- Heavy `f` function: (ms range, susceptible to interrupts/IO/allocations/GC)
- Functions with side effects that must run exactly once (lock ensures single execution)

# When to avoid
- High write frequency with lightweight `f` (ns-range): Consider `CASContainer`
- Strict fairness requirements (`ReentrantLock` is not strictly FIFO)

Note: While inspired by RCU (Read-Copy-Update) patterns, this implementation uses
locks for write serialization rather than classic RCU's grace period mechanism.
"""
mutable struct LWContainer{T,Stats<:Union{Nothing,LWStats}} <: AtomicContainer
    @atomic data::T
    const update_lock::ReentrantLock
    const stats::Stats
    LWContainer(data::T; withstats::Bool=false) where T =
        new{T, withstats ? LWStats : Nothing}(data, ReentrantLock(), withstats ? LWStats() : nothing)
end

load(c::LWContainer) = @atomic :acquire c.data

"""
    store!(f, c::LWContainer{T}) -> new::T

Atomically update the data stored in an [`LWContainer`](@ref) using a lock for serialization.
`f(old::T) -> new::T` must not modify `old` in-place.
"""
function store!(f, c::LWContainer) end

function store!(f, c::LWContainer{T,Nothing}) where T
    @lock c.update_lock begin
        old = @atomic :acquire c.data
        new = f(old)::T
        @atomic :release c.data = new
        return new
    end
end

function store!(f, c::LWContainer{T,LWStats}) where T
    t0 = time_ns()
    stats = c.stats
    @atomic :monotonic stats.attempts += 1
    if !trylock(c.update_lock)
        @atomic :monotonic stats.contended += 1
        lock(c.update_lock)
        waited = time_ns() - t0
        @atomic :monotonic stats.wait_ns += waited
    end
    try
        old = @atomic :acquire c.data
        new = f(old)::T
        @atomic :release c.data = new
        return new
    finally
        unlock(c.update_lock)
        @atomic :monotonic stats.total_ns += time_ns() - t0
    end
end

getstats(c::LWContainer) = getstats(@something c.stats return nothing)
resetstats!(c::LWContainer) = resetstats!(@something c.stats return nothing)

# CASContainer
# ============

"""
    CASStats

Statistics tracking for CASContainer operations. Collects performance metrics
about compare-and-swap operations including retry behavior and timing information.
"""
mutable struct CASStats <: AtomicStats
    "Number of `store!` calls made to the container"
    @atomic attempts::Int
    "Total number of retries across all `store!` calls (cumulative sum)"
    @atomic retries::Int
    "Maximum number of retries observed in any single `store!` call"
    @atomic max_retries::Int
    "Total time spent in all `store!` operations (nanoseconds)"
    @atomic total_ns::UInt
    "Total time spent executing the user function `f(old)` (nanoseconds)"
    @atomic f_ns::UInt
    CASStats() = new(0, 0, 0, 0, 0)
end

"""
    getstats(stats::CASStats)

Get performance statistics for compare-and-swap operations.

# Returns
NamedTuple with fields:
- `attempts`: Total number of `store!` calls
- `retries`: Total cumulative retries across all attempts
- `max_retries`: Maximum retries seen in any single `store!` call
- `avg_retries`: Average retries per `store!` call
- `total_ms`: Total time in all `store!` operations (milliseconds)
- `f_ms`: Total time executing user functions (milliseconds)
- `spin_ms`: Total time spent on spin/retry (milliseconds)
- `avg_total_ms`: Average total time per `store!` call (milliseconds)
- `avg_f_ms`: Average time executing user functions per `store!` call (milliseconds)
- `avg_spin_ms`: Average spin/retry time per `store!` call (milliseconds)
- `spin_share`: Fraction of time spent spinning vs executing `f`

# Hints
- `avg_retries < 1`: Low contention, CAS is efficient
- `avg_retries > 5`: Moderate contention
- `avg_retries > 20`: High contention, consider LW container
- `spin_share > 0.5`: Majority of time spent retrying, not in useful work
- `max_retries` spikes indicate occasional severe contention
"""
function getstats(stats::CASStats)
    attempts = @atomic :monotonic stats.attempts
    retries = @atomic :monotonic stats.retries
    max_retries = @atomic :monotonic stats.max_retries
    avg_retries = attempts == 0 ? 0.0 : retries / attempts
    total_ms = (@atomic :monotonic stats.total_ns) / 10^6
    f_ms = (@atomic :monotonic stats.f_ns) / 10^6
    spin_ms = total_ms - f_ms
    avg_total_ms = attempts == 0 ? 0.0 : total_ms / attempts
    avg_f_ms = attempts == 0 ? 0.0 : f_ms / attempts
    avg_spin_ms = attempts == 0 ? 0.0 : spin_ms / attempts
    spin_share = total_ms == 0.0 ? 0.0 : spin_ms / total_ms
    return (; attempts, retries, max_retries, avg_retries,
              total_ms, f_ms, avg_total_ms, avg_f_ms, avg_spin_ms,
              spin_share)
end

function resetstats!(stats::CASStats)
    @atomic :monotonic stats.attempts = 0
    @atomic :monotonic stats.retries = 0
    @atomic :monotonic stats.max_retries = 0
    @atomic :monotonic stats.total_ns = 0
    @atomic :monotonic stats.f_ns = 0
    return stats
end

"""
    CASContainer{T}

Compare-And-Swap (CAS) container using lock-free retry loops for updates.

# When to use CAS
- Lightweight `f` function (tens to hundreds of ns) that's safe to retry (pure function)
- High write frequency or low-to-moderate contention needing high throughput

# When to avoid
- Heavy `f` or functions with side effects: wasted re-evaluation on failure → Use LW
- High contention: excessive retries cause spin time and cache line bouncing
"""
mutable struct CASContainer{T,Stats<:Union{Nothing,CASStats}} <: AtomicContainer
    @atomic data::T
    const stats::Stats
    CASContainer(data::T; withstats::Bool=false) where T =
        new{T, withstats ? CASStats : Nothing}(data, withstats ? CASStats() : nothing)
end

load(c::CASContainer) = @atomic :acquire c.data

"""
    store!(f, c::CASContainer{T}; backoff::Union{Nothing,Unsigned}=nothing) -> new::T

Atomically update using CAS with retry on failure.
`f(old::T) -> new::T` must be pure (no side effects and safe to retry,
including not modifying `old` in-place).
`backoff::Union{Nothing,Unsigned}` controls the retry behavior:
- `backoff == nothing` (default): Adaptive (yields after 16 retries)
- `backoff == 0`: Immediate retry (fastest for low contention)
- `backoff > 0`: Yield every N retries
"""
function store!(f, c::CASContainer; backoff::Union{Nothing,Unsigned}) end

function store!(f, c::CASContainer{T,Nothing}; backoff::Union{Nothing,Unsigned}=nothing) where T
    local retries = 0
    old = @atomic :acquire c.data
    while true
        new = f(old)::T
        old, success = @atomicreplace :acquire_release :monotonic c.data old => new
        if success
            return new
        else
            # Failure. Increment locally and apply throttled backoff if needed
            retries += 1
            if isnothing(backoff)
                retries < 16 && continue
                backoff = 16
            elseif backoff == 0
                continue
            else
                backoff = Int(backoff)
            end
            if (retries % backoff) == 0
                yield()
            end
        end
    end
end

function store!(f, c::CASContainer{T,CASStats}; backoff::Union{Nothing,Unsigned}=nothing) where T
    local retries = 0
    local f_time = zero(UInt64)
    local t_loop0 = time_ns()
    stats = c.stats
    @atomic :monotonic stats.attempts += 1
    old = @atomic :acquire c.data
    while true
        t0 = time_ns()
        new = f(old)::T
        f_time += time_ns() - t0
        old, success = @atomicreplace :acquire_release :monotonic c.data old => new
        if success
            if retries != 0
                @atomic :monotonic stats.retries += retries
                _atomic_max!(stats, retries)
            end
            @atomic :monotonic stats.f_ns += f_time
            @atomic :monotonic stats.total_ns += (time_ns() - t_loop0)
            return new
        else
            # Failure. Increment locally and apply throttled backoff if needed
            retries += 1
            if isnothing(backoff)
                retries < 16 && continue
                backoff = 16
            elseif backoff == 0
                continue
            else
                backoff = Int(backoff)
            end
            if (retries % backoff) == 0
                yield()
            end
        end
    end
end

@inline function _atomic_max!(stats::CASStats, x::Int)
    old = @atomic :monotonic stats.max_retries
    while x > old
        old, success = @atomicreplace :monotonic stats.max_retries old => x
        success && return x
    end
    return old
end

getstats(c::CASContainer) = getstats(@something c.stats return nothing)
resetstats!(c::CASContainer) = resetstats!(@something c.stats return nothing)

end # module AtomicContainers
