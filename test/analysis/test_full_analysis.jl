module test_full_analysis

using Test
using JETLS: JETLS
using JETLS.URIs2: URI, filepath2uri

struct ShutdownTestEntry <: JETLS.AnalysisEntry end

struct ActiveShutdownTestEntry <: JETLS.AnalysisEntry
    uri::URI
    started::Base.Event
    release::Base.Event
end

struct QueuedSignatureShutdownTestEntry <: JETLS.AnalysisEntry
    uri::URI
    first_started::Base.Event
    release_first::Base.Event
    first_ran::Base.RefValue{Bool}
    queued_ran::Base.RefValue{Bool}
end

struct ShutdownSignatureJob <: JETLS.AbstractSignatureAnalysisJob
    completion::Base.Event
end

struct CancellableShutdownSignatureJob <: JETLS.AbstractSignatureAnalysisJob
    execution::JETLS.AnalysisExecution
    started::Union{Nothing,Base.Event}
    release::Union{Nothing,Base.Event}
    ran::Base.RefValue{Bool}
    completion::Base.Event
end

JETLS.progress_title_impl(::ShutdownTestEntry) = "shutdown test"
JETLS.progress_title_impl(::ActiveShutdownTestEntry) = "active shutdown test"
JETLS.progress_title_impl(::QueuedSignatureShutdownTestEntry) =
    "queued signature shutdown test"
(::ShutdownSignatureJob)(::JETLS.Server) = nothing
JETLS.signature_analysis_execution_impl(job::CancellableShutdownSignatureJob) =
    job.execution
function (job::CancellableShutdownSignatureJob)(::JETLS.Server)
    job.ran[] = true
    job.started === nothing || notify(job.started)
    job.release === nothing || wait(job.release)
    return nothing
end

const ShutdownAnalysisTestEntry =
    Union{ActiveShutdownTestEntry,QueuedSignatureShutdownTestEntry}

function active_shutdown_analysis_result(entry::ShutdownAnalysisTestEntry)
    return JETLS.AnalysisResult(
        entry,
        JETLS.URI2Diagnostics(entry.uri => JETLS.LSP.Diagnostic[]),
        JETLS.LSAnalyzer(entry),
        Dict(entry.uri => JETLS.JET.AnalyzedFileInfo()),
        Main => Main,
        Base.get_world_counter())
end

function JETLS.execute_analysis_impl(
        server::JETLS.Server, execution::JETLS.AnalysisExecution,
        entry::ActiveShutdownTestEntry,
    )
    analysis_result = active_shutdown_analysis_result(entry)
    @assert JETLS.cache_intermediate_analysis_result!(
        server, execution, analysis_result)
    notify(entry.started)
    wait(entry.release)
    return JETLS.CompletedAnalysis(analysis_result, false)
end

function JETLS.execute_analysis_impl(
        server::JETLS.Server, execution::JETLS.AnalysisExecution,
        entry::QueuedSignatureShutdownTestEntry,
    )
    jobs = [
        CancellableShutdownSignatureJob(
            execution, entry.first_started, entry.release_first,
            entry.first_ran, Base.Event()),
        CancellableShutdownSignatureJob(
            execution, nothing, nothing, entry.queued_ran, Base.Event()),
    ]
    JETLS.run_signature_analysis_jobs!(server, jobs)
    return JETLS.CompletedAnalysis(active_shutdown_analysis_result(entry), false)
end
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

@testset "shutdown waits without started workers" begin
    server = JETLS.Server()
    manager = server.state.analysis_manager
    script_uri = filepath2uri(joinpath(@__DIR__, "shutdown-without-worker.jl"))
    entry = ShutdownTestEntry()
    completion = Base.Event()
    completion_waiter = Threads.@spawn wait(completion)
    request = JETLS.AnalysisRequest(
        entry, script_uri, #=generation=#0, nothing, false, completion)

    JETLS.queue_request!(server, request)
    @test isnothing(JETLS.wait_analysis_workers(server))

    @test timedwait(() -> istaskdone(completion_waiter), 1.0) == :ok
    @test !haskey(JETLS.load(manager.pending_analyses), entry)
    @test !isready(manager.queue)
    @test !isassigned(manager.worker_task)
    @test isempty(manager.signature_worker_tasks)
    @test isnothing(JETLS.wait_analysis_workers(server))
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
    JETLS.wait_analysis_workers(server)

    @test timedwait(() -> istaskdone(completion_waiter), 1.0) == :ok
    @test !haskey(JETLS.load(manager.pending_analyses), entry)
    @test !isready(manager.queue)
end

@testset "shutdown cancels active analysis" begin
    recorder = JETLS.ServerMessageRecorder()
    endpoint = JETLS.LSP.Endpoint(IOBuffer(), IOBuffer())
    server = JETLS.Server(endpoint; callback=recorder)
    manager = server.state.analysis_manager
    capabilities = JETLS.LSP.ClientCapabilities(;
        workspace = JETLS.LSP.WorkspaceClientCapabilities(;
            diagnostics = JETLS.LSP.DiagnosticWorkspaceClientCapabilities(;
                refreshSupport = true),
            codeLens = JETLS.LSP.CodeLensWorkspaceClientCapabilities(;
                refreshSupport = true)))
    server.state.init_params = JETLS.LSP.InitializeParams(;
        processId = nothing, rootUri = nothing, capabilities)

    script_uri = filepath2uri(joinpath(@__DIR__, "shutdown-active.jl"))
    entry = ActiveShutdownTestEntry(script_uri, Base.Event(), Base.Event())
    previous_result = active_shutdown_analysis_result(entry)
    JETLS.update_analysis_cache!(server.state, previous_result)
    previous_request = JETLS.AnalysisRequest(
        entry, script_uri, #=generation=#0, nothing, false)
    JETLS.mark_analyzed_generation!(manager, previous_request)

    completion = Base.Event()
    completion_waiter = Threads.@spawn wait(completion)
    request = JETLS.AnalysisRequest(
        entry, script_uri, #=generation=#1, nothing, true, completion)

    JETLS.queue_request!(server, request)
    JETLS.start_analysis_worker!(server)
    wait(entry.started)
    intermediate_result = JETLS.get_analysis_info(manager, script_uri)
    @test intermediate_result isa JETLS.AnalysisResult
    @test intermediate_result !== previous_result

    active_execution = manager.active_analysis[]
    @test active_execution isa JETLS.AnalysisExecution
    JETLS.begin_analysis_shutdown!(server)
    @test JETLS.is_analysis_cancelled(active_execution)
    @test JETLS.get_analysis_info(manager, script_uri) === previous_result

    notify(entry.release)
    JETLS.wait_analysis_workers(server)

    @test timedwait(() -> istaskdone(completion_waiter), 1.0) == :ok
    @test JETLS.get_analysis_info(manager, script_uri) === previous_result
    @test JETLS.load(manager.analyzed_generations)[entry] == 0
    @test !haskey(JETLS.load(manager.pending_analyses), entry)
    @test manager.active_analysis[] === nothing
    @test isempty(recorder.sent_queue)
    close(endpoint)
    wait(endpoint.read_task)
end

@testset "shutdown rejects signature job admission" begin
    server = JETLS.Server()
    manager = server.state.analysis_manager
    script_uri = filepath2uri(joinpath(@__DIR__, "shutdown-signature-admission.jl"))
    request = JETLS.AnalysisRequest(
        JETLS.ScriptAnalysisEntry(script_uri), script_uri,
        #=generation=#0, nothing, false)
    maybe_execution = JETLS.begin_analysis_execution!(manager, request, nothing)
    @test maybe_execution isa JETLS.AnalysisExecution
    execution = maybe_execution::JETLS.AnalysisExecution
    ran = Ref(false)
    job = CancellableShutdownSignatureJob(
        execution, nothing, nothing, ran, Base.Event())
    completion_waiter = Threads.@spawn wait(job.completion)

    JETLS.begin_analysis_shutdown!(server)
    JETLS.run_signature_analysis_jobs!(server, [job])

    @test JETLS.is_analysis_cancelled(execution)
    @test !ran[]
    @test timedwait(() -> istaskdone(completion_waiter), 1.0) == :ok
    @test !isready(manager.signature_queue)
    JETLS.finish_analysis_execution!(manager, execution)
end

@testset "shutdown skips queued signature jobs" begin
    server = JETLS.Server()
    manager = server.state.analysis_manager
    signature_task = Threads.@spawn :default JETLS.signature_analysis_worker(server)
    push!(manager.signature_worker_tasks, signature_task)

    script_uri = filepath2uri(joinpath(@__DIR__, "shutdown-signatures.jl"))
    entry = QueuedSignatureShutdownTestEntry(
        script_uri, Base.Event(), Base.Event(), Ref(false), Ref(false))
    completion = Base.Event()
    completion_waiter = Threads.@spawn wait(completion)
    request = JETLS.AnalysisRequest(
        entry, script_uri, #=generation=#0, nothing, false, completion)

    JETLS.queue_request!(server, request)
    JETLS.start_analysis_worker!(server)
    wait(entry.first_started)
    @test entry.first_ran[]
    @test !entry.queued_ran[]

    JETLS.begin_analysis_shutdown!(server)
    notify(entry.release_first)
    JETLS.wait_analysis_workers(server)

    @test timedwait(() -> istaskdone(completion_waiter), 1.0) == :ok
    @test !entry.queued_ran[]
    @test JETLS.get_analysis_info(manager, script_uri) === nothing
    @test !haskey(JETLS.load(manager.analyzed_generations), entry)
    @test !haskey(JETLS.load(manager.pending_analyses), entry)
    @test manager.active_analysis[] === nothing
    @test istaskdone(signature_task)
    @test !isready(manager.signature_queue)
end

@testset "shutdown joins full analysis before signature workers" begin
    server = JETLS.Server()
    manager = server.state.analysis_manager
    release_full_analysis = Base.Event()
    signature_job = ShutdownSignatureJob(Base.Event())

    signature_task = Threads.@spawn :default JETLS.signature_analysis_worker(server)
    push!(manager.signature_worker_tasks, signature_task)
    manager.worker_task[] = Threads.@spawn :default begin
        wait(release_full_analysis)
        JETLS.run_signature_analysis_jobs!(server, [signature_job])
    end

    shutdown_task = Threads.@spawn JETLS.wait_analysis_workers(server)
    @test timedwait(() -> isready(manager.queue), 1.0) == :ok
    @test !istaskdone(signature_task)

    notify(release_full_analysis)
    @test timedwait(() -> istaskdone(shutdown_task), 1.0) == :ok
    @test fetch(shutdown_task) === nothing
    @test istaskdone(manager.worker_task[])
    @test istaskdone(signature_task)
    @test !isready(manager.queue)
    @test !isready(manager.signature_queue)
end

@testset "runserver starts analysis shutdown" begin
    input_pipe = Pipe()
    output_pipe = Pipe()
    Base.link_pipe!(input_pipe; reader_supports_async=true, writer_supports_async=true)
    Base.link_pipe!(output_pipe; reader_supports_async=true, writer_supports_async=true)
    recorder = JETLS.ServerMessageRecorder()
    endpoint = JETLS.LSP.Endpoint(input_pipe.out, output_pipe.in)
    server = JETLS.Server(endpoint; callback=recorder)
    server_task = Threads.@spawn :interactive JETLS.runserver(server)

    try
        JETLS.LSP.writelsp(input_pipe.in, JETLS.LSP.ShutdownRequest(; id=1))
        @test take!(recorder.received_queue) isa JETLS.LSP.ShutdownRequest
        @test take!(recorder.sent_queue) isa JETLS.LSP.ShutdownResponse
        @test timedwait(
            () -> JETLS.is_analysis_stopping(server.state.analysis_manager), 1.0) == :ok

        JETLS.LSP.writelsp(input_pipe.in, JETLS.LSP.ExitNotification())
        @test take!(recorder.received_queue) isa JETLS.LSP.ExitNotification
        @test fetch(server_task) == 0
    finally
        close(input_pipe.in)
        wait(endpoint.read_task)
        close(input_pipe.out)
        close(output_pipe.in)
        close(output_pipe.out)
    end
end

@testset "transport EOF starts analysis shutdown" begin
    server = JETLS.Server()
    @test JETLS.runserver(server) == 1
    @test JETLS.is_analysis_stopping(server.state.analysis_manager)
    wait(server.endpoint.read_task)
end

end # module test_full_analysis
