module test_full_analysis

using Test
using JETLS: JETLS
using JETLS.URIs2: URI, filepath2uri

struct ShutdownTestEntry <: JETLS.AnalysisEntry end

JETLS.progress_title_impl(::ShutdownTestEntry) = "shutdown test"
# Tripwire: `is_abandoned_analysis_target` is only reached when `resolve_analysis_request`
# executes the analysis body, so any queued request that is not skipped during shutdown
# fails the test with this error.
JETLS.is_abandoned_analysis_target(::JETLS.Server, ::URI, ::ShutdownTestEntry) =
    error("queued analysis executed during shutdown")

include(normpath(pkgdir(JETLS), "test", "setup.jl"))

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

@testset "instantiation_needs" begin
    withpackage("TestInstantiationNeeds", "module TestInstantiationNeeds end";
                pkg_setup = Returns(nothing)) do pkgpath
        env_path = joinpath(pkgpath, "Project.toml")
        manifest_path = joinpath(pkgpath, "Manifest.toml")

        @test !isfile(manifest_path)
        @test JETLS.instantiation_needs(env_path) == (; resolve=true, instantiate=true)

        withenv("JULIA_PKG_PRECOMPILE_AUTO" => "0") do
            Pkg.activate(pkgpath) do
                Pkg.instantiate(; io=devnull)
            end
        end
        @test isfile(manifest_path)
        @test JETLS.instantiation_needs(env_path) == (; resolve=false, instantiate=false)

        # adding a dependency to `Project.toml` leaves the manifest stale
        open(env_path, "a") do io
            println(io, "\n[deps]\nTest = \"8dfed614-e22c-5e08-85e1-65c5234f0b40\"")
        end
        @test JETLS.instantiation_needs(env_path) == (; resolve=true, instantiate=true)

        Pkg.activate(pkgpath) do
            Pkg.resolve(; io=devnull)
        end
        @test JETLS.instantiation_needs(env_path) == (; resolve=false, instantiate=false)
    end
end

@testset "ensure_instantiated!" begin
    withpackage("TestEnsureInstantiated", "module TestEnsureInstantiated end";
                pkg_setup = Returns(nothing)) do pkgpath
        env_path = joinpath(pkgpath, "Project.toml")
        manifest_path = joinpath(pkgpath, "Manifest.toml")
        sent_queue = Channel{Any}(Inf)
        server = JETLS.Server(;
            callback = JETLS.ServerMessageRecorder(Channel{Any}(Inf), sent_queue))
        function set_auto_instantiate!(auto_instantiate)
            JETLS.store!(server.state.config_manager) do old_data
                lsp_config = JETLS.JETLSConfig(;
                    full_analysis = JETLS.FullAnalysisConfig(; auto_instantiate))
                return JETLS.ConfigManagerData(old_data; lsp_config), nothing
            end
        end
        ensure_instantiated!() = JETLS.activate_do(env_path) do
            JETLS.ensure_instantiated!(server, env_path)
        end

        # disabled: only warn, never touch the environment
        set_auto_instantiate!(false)
        ensure_instantiated!()
        @test !isfile(manifest_path)
        let msg = take!(sent_queue)
            @test msg isa ShowMessageNotification
            @test msg.params.type == MessageType.Warning
        end
        @test isempty(sent_queue)

        set_auto_instantiate!(true)
        withenv("JULIA_PKG_PRECOMPILE_AUTO" => "0") do
            ensure_instantiated!()
        end
        @test isfile(manifest_path)
        @test isempty(sent_queue)

        # An instantiated environment must be left untouched even when its manifest was
        # written by another Julia version, which `Pkg.resolve` would rewrite.
        manifest = read(manifest_path, String)
        tampered = replace(manifest, r"julia_version = \"[^\"]*\"" => "julia_version = \"1.0.0\"")
        @test tampered != manifest
        write(manifest_path, tampered)
        ensure_instantiated!()
        @test read(manifest_path, String) == tampered
        @test isempty(sent_queue)
    end
end

@testset "shutdown rejects scheduling" begin
    server = JETLS.Server()
    manager = server.state.analysis_manager
    script_uri = filepath2uri(joinpath(@__DIR__, "shutdown-scheduling.jl"))
    entry = JETLS.ScriptAnalysisEntry(script_uri)
    completion = Base.Event()
    completion_waiter = Threads.@spawn wait(completion)

    JETLS.begin_analysis_shutdown!(server)
    JETLS.schedule_analysis!(server, script_uri, entry, #=invalidate=#true;
        completion, debounce=60.0, notify_diagnostics=false)

    @test timedwait(() -> istaskdone(completion_waiter), 1.0) == :ok
    @test isempty(JETLS.load(manager.tracked_entries))
    @test isempty(JETLS.load(manager.current_generations))
    @test isempty(JETLS.load(manager.debounced))
    @test isempty(JETLS.load(manager.pending_analyses))
    @test !isready(manager.queue)
end

@testset "shutdown cancels debounced analysis" begin
    server = JETLS.Server()
    manager = server.state.analysis_manager
    script_uri = filepath2uri(joinpath(@__DIR__, "shutdown-debounced.jl"))
    entry = JETLS.ScriptAnalysisEntry(script_uri)
    completion = Base.Event()
    completion_waiter = Threads.@spawn wait(completion)

    JETLS.schedule_analysis!(server, script_uri, entry, #=invalidate=#true;
        completion, debounce=60.0, notify_diagnostics=false)
    timer, _ = JETLS.load(manager.debounced)[entry]
    @test isopen(timer)

    JETLS.begin_analysis_shutdown!(server)

    @test timedwait(() -> istaskdone(completion_waiter), 1.0) == :ok
    @test !isopen(timer)
    @test isempty(JETLS.load(manager.debounced))
    @test !isready(manager.queue)
    @test isnothing(JETLS.begin_analysis_shutdown!(server))
end

@testset "shutdown rejects late queue admission" begin
    server = JETLS.Server()
    manager = server.state.analysis_manager
    script_uri = filepath2uri(joinpath(@__DIR__, "shutdown-queueing.jl"))
    entry = JETLS.ScriptAnalysisEntry(script_uri)

    JETLS.schedule_analysis!(server, script_uri, entry, #=invalidate=#false;
        debounce=0.0, notify_diagnostics=false)
    take!(manager.queue)
    @test JETLS.load(manager.pending_analyses)[entry] === nothing

    completion = Base.Event()
    completion_waiter = Threads.@spawn wait(completion)
    late_request = JETLS.AnalysisRequest(
        entry, script_uri, #=generation=#0, nothing, false, completion)
    JETLS.begin_analysis_shutdown!(server)
    JETLS.queue_request!(server, late_request)

    @test timedwait(() -> istaskdone(completion_waiter), 1.0) == :ok
    @test JETLS.load(manager.pending_analyses)[entry] === nothing
    @test !isready(manager.queue)
end

@testset "shutdown cancels pending requeue" begin
    server = JETLS.Server()
    manager = server.state.analysis_manager
    script_uri = filepath2uri(joinpath(@__DIR__, "shutdown-pending.jl"))
    entry = JETLS.ScriptAnalysisEntry(script_uri)

    JETLS.schedule_analysis!(server, script_uri, entry, #=invalidate=#false;
        debounce=0.0, notify_diagnostics=false)
    active_request = take!(manager.queue)::JETLS.AnalysisRequest
    active_waiter = Threads.@spawn wait(active_request.completion)

    pending_completion = Base.Event()
    pending_waiter = Threads.@spawn wait(pending_completion)
    JETLS.schedule_analysis!(server, script_uri, entry, #=invalidate=#true;
        completion=pending_completion, debounce=0.0, notify_diagnostics=false)
    @test JETLS.load(manager.pending_analyses)[entry] isa JETLS.AnalysisRequest

    JETLS.begin_analysis_shutdown!(server)
    JETLS.resolve_analysis_request(server, active_request)

    @test timedwait(() -> istaskdone(active_waiter), 1.0) == :ok
    @test timedwait(() -> istaskdone(pending_waiter), 1.0) == :ok
    @test !haskey(JETLS.load(manager.pending_analyses), entry)
    @test !isready(manager.queue)
end

@testset "shutdown skips queued analysis" begin
    server = JETLS.Server()
    manager = server.state.analysis_manager
    script_uri = filepath2uri(joinpath(@__DIR__, "shutdown-queued.jl"))
    entry = ShutdownTestEntry()
    completion = Base.Event()
    completion_waiter = Threads.@spawn wait(completion)
    request = JETLS.AnalysisRequest(
        entry, script_uri, #=generation=#0, nothing, false, completion)

    JETLS.queue_request!(server, request)
    @test JETLS.load(manager.pending_analyses)[entry] === nothing

    JETLS.begin_analysis_shutdown!(server)
    JETLS.start_analysis_worker!(server)
    JETLS.stop_analysis_worker(server)

    @test timedwait(() -> istaskdone(completion_waiter), 1.0) == :ok
    @test !haskey(JETLS.load(manager.pending_analyses), entry)
    @test !isready(manager.queue)
end

end # module test_full_analysis
