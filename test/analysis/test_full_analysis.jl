module test_full_analysis

using Test
using JETLS: JETLS
using JETLS.URIs2: filepath2uri

@testset "immediate invalidation supersedes older requests" begin
    server = JETLS.Server()
    manager = server.state.analysis_manager
    script_uri = filepath2uri(joinpath(@__DIR__, "superseded-analysis.jl"))
    entry = JETLS.ScriptAnalysisEntry(script_uri)

    # `Server()` has no analysis worker. Manually dequeue generation 0 while
    # leaving its marker in `pending_analyses`, as happens during active analysis.
    JETLS.schedule_analysis!(server, script_uri, entry, #=invalidate=#false;
        debounce=0.0, notify_diagnostics=false)
    active_request = take!(manager.queue)::JETLS.AnalysisRequest
    @test JETLS.load(manager.pending_analyses)[entry] === nothing

    # Generation 1 represents a save-triggered request waiting on its debounce.
    JETLS.schedule_analysis!(server, script_uri, entry, #=invalidate=#true;
        debounce=60.0, notify_diagnostics=false)
    debounced_generation = JETLS.get_generation(manager, entry)
    debounce_timer, debounce_completion = JETLS.load(manager.debounced)[entry]
    debounce_completion_waiter = Threads.@spawn wait(debounce_completion)

    # Generation 2 is an immediate invalidation. It should cancel generation 1
    # and become the pending request behind the active generation 0 request.
    JETLS.schedule_analysis!(server, script_uri, entry, #=invalidate=#true;
        debounce=0.0, notify_diagnostics=false)
    @test JETLS.get_generation(manager, entry) == debounced_generation + 1
    @test !haskey(JETLS.load(manager.debounced), entry)
    @test !isopen(debounce_timer)
    @test timedwait(() -> istaskdone(debounce_completion_waiter), 1.0) == :ok

    immediate_request = JETLS.load(manager.pending_analyses)[entry]
    @test immediate_request isa JETLS.AnalysisRequest
    @test immediate_request.generation == debounced_generation + 1

    # A timer callback can race with cancellation and reach the queue late.
    # Such a generation 1 request must not replace the pending generation 2.
    late_completion = Base.Event()
    late_debounced_request = JETLS.AnalysisRequest(
        entry, script_uri, debounced_generation, nothing, false, late_completion)
    late_completion_waiter = Threads.@spawn wait(late_completion)
    JETLS.queue_request!(server, late_debounced_request)
    @test timedwait(() -> istaskdone(late_completion_waiter), 1.0) == :ok
    @test JETLS.load(manager.pending_analyses)[entry] === immediate_request

    # Finishing generation 0 should skip it without updating analysis state,
    # then promote the pending generation 2 request to the worker queue.
    JETLS.resolve_analysis_request(server, active_request)
    @test JETLS.get_analysis_info(manager, script_uri) === nothing
    @test !haskey(JETLS.load(manager.analyzed_generations), entry)
    @test take!(manager.queue) === immediate_request
end

end # module test_full_analysis
