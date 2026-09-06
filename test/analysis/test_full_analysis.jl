module test_full_analysis

using Test
using JETLS: JETLS
using JETLS.URIs2: filepath2uri

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
    mktempdir() do env_dir
        env_path = joinpath(env_dir, "Project.toml")
        manifest_path = joinpath(env_dir, "Manifest.toml")
        write(env_path, "")

        @test !isfile(manifest_path)
        @test JETLS.instantiation_needs(env_path) == (; resolve=true, instantiate=true)

        withenv("JULIA_PKG_PRECOMPILE_AUTO" => "0") do
            Pkg.activate(env_dir) do
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

        Pkg.activate(env_dir) do
            Pkg.resolve(; io=devnull)
        end
        @test JETLS.instantiation_needs(env_path) == (; resolve=false, instantiate=false)

        manifest = read(manifest_path, String)
        manifest_without_test = replace(manifest,
            r"(?ms)^\[\[deps\.Test\]\]\n.*?(?=^\[\[deps\.|\z)" => "")
        @test manifest_without_test != manifest
        write(manifest_path, manifest_without_test)

        env = Pkg.Types.EnvCache(env_path)
        @test Pkg.Operations.is_manifest_current(env) === true
        @test Pkg.Operations.is_instantiated(env)
        @test JETLS.instantiation_needs(env_path) == (; resolve=true, instantiate=true)

        Pkg.activate(env_dir) do
            Pkg.resolve(; io=devnull)
        end
        @test JETLS.instantiation_needs(env_path) == (; resolve=false, instantiate=false)

        manifest = read(manifest_path, String)
        hashless_manifest = replace(manifest, r"(?m)^project_hash = .*\n" => "")
        @test hashless_manifest != manifest
        write(manifest_path, hashless_manifest)
        @test JETLS.instantiation_needs(env_path) == (; resolve=true, instantiate=true)

        Pkg.activate(env_dir) do
            Pkg.resolve(; io=devnull)
        end
        @test JETLS.instantiation_needs(env_path) == (; resolve=false, instantiate=false)

        write(manifest_path, "")
        @test JETLS.instantiation_needs(env_path) == (; resolve=true, instantiate=true)
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
        set_auto_instantiate!(JETLS.AUTO_INSTANTIATE_NEVER)
        ensure_instantiated!()
        @test !isfile(manifest_path)
        let msg = take!(sent_queue)
            @test msg isa ShowMessageNotification
            @test msg.params.type == MessageType.Warning
        end
        @test isempty(sent_queue)

        # "prompt" without a client decision behaves like "never"
        set_auto_instantiate!(JETLS.AUTO_INSTANTIATE_PROMPT)
        ensure_instantiated!()
        @test !isfile(manifest_path)
        @test take!(sent_queue) isa ShowMessageNotification
        @test isempty(sent_queue)

        set_auto_instantiate!(JETLS.AUTO_INSTANTIATE_ALWAYS)
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

    # `jetls check` has no client to ask, so "prompt" instantiates like "always"
    withpackage("TestEnsureInstantiatedCLI", "module TestEnsureInstantiatedCLI end";
                pkg_setup = Returns(nothing)) do pkgpath
        env_path = joinpath(pkgpath, "Project.toml")
        manifest_path = joinpath(pkgpath, "Manifest.toml")
        sent_queue = Channel{Any}(Inf)
        server = JETLS.Server(; cli_mode = true,
            callback = JETLS.ServerMessageRecorder(Channel{Any}(Inf), sent_queue))
        JETLS.store!(server.state.config_manager) do old_data
            lsp_config = JETLS.JETLSConfig(;
                full_analysis = JETLS.FullAnalysisConfig(;
                    auto_instantiate = JETLS.AUTO_INSTANTIATE_PROMPT))
            return JETLS.ConfigManagerData(old_data; lsp_config), nothing
        end
        withenv("JULIA_PKG_PRECOMPILE_AUTO" => "0") do
            @test_logs (:info, "Resolving package environment") (:info, "Instantiating package environment") match_mode=:any begin
                JETLS.activate_do(env_path) do
                    JETLS.ensure_instantiated!(server, env_path)
                end
            end
        end
        @test isfile(manifest_path)
        @test isempty(sent_queue)
    end
end

@testset "auto_instantiate = \"prompt\"" begin
    settings = Dict{String,Any}(
        "full_analysis" => Dict{String,Any}(
            "auto_instantiate" => JETLS.AUTO_INSTANTIATE_PROMPT))
    progress_capabilities = ClientCapabilities(;
        window = WindowClientCapabilities(; workDoneProgress = true))
    pkgname = "TestInstantiationPrompt"
    pkgcode = "module $pkgname end"

    # "Skip" leaves the environment untouched. Requests for the same environment share the
    # prompt, and repeated requests for one URI are coalesced until it is answered.
    withpackage(pkgname, pkgcode; pkg_setup = Returns(nothing)) do pkgpath
        manifest_path = joinpath(pkgpath, "Manifest.toml")
        pkg_uri = filepath2uri(joinpath(pkgpath, "src", "$pkgname.jl"))
        script_code = "1 + 1\n"
        script_path = joinpath(pkgpath, "script.jl")
        write(script_path, script_code)
        script_uri = filepath2uri(script_path)
        withserver(; rootUri = filepath2uri(pkgpath), settings) do (;
                server, writemsg, writereadmsg, readmsg)
            (; raw_res) = writereadmsg(make_DidOpenTextDocumentNotification(pkg_uri, pkgcode))
            @test raw_res isa ShowMessageRequest
            @test raw_res.params.type == MessageType.Info
            @test [action.title for action in raw_res.params.actions] == ["Instantiate", "Skip"]

            writereadmsg(make_DidOpenTextDocumentNotification(script_uri, script_code); read = 0)
            prompts = server.state.analysis_manager.instantiation_prompts
            @test timedwait(5.0) do
                length(only(values(JETLS.load(prompts))).waiters) == 2
            end == :ok
            @test only(values(JETLS.load(prompts))).decision === :pending

            for debounce in (1.0, 2.0, 0.0)
                JETLS.request_analysis!(server, script_uri, #=invalidate=#true; debounce)
            end
            waiters = only(values(JETLS.load(prompts))).waiters
            @test length(waiters) == 2
            script_waiter = only(waiter for waiter in waiters if waiter.uri == script_uri)
            @test script_waiter.invalidate
            @test script_waiter.debounce == 0.0

            writemsg(ResponseMessage(; id = raw_res.id, result = Dict{String,Any}("title" => "Skip")); check = false)
            # The first completed analysis publishes one URI; the second republishes both.
            (; raw_msg) = readmsg(; read = 3)
            @test all(msg -> msg isa PublishDiagnosticsNotification, raw_msg)
            @test Set(msg.params.uri for msg in raw_msg) == Set([pkg_uri, script_uri])
            @test only(values(JETLS.load(prompts))).decision === :declined
            @test !isfile(manifest_path)
        end
    end

    # Manual instantiation while the prompt is open is picked up after choosing "Skip".
    withpackage(pkgname, pkgcode; pkg_setup = Returns(nothing)) do pkgpath
        env_path = joinpath(pkgpath, "Project.toml")
        manifest_path = joinpath(pkgpath, "Manifest.toml")
        pkg_uri = filepath2uri(joinpath(pkgpath, "src", "$pkgname.jl"))
        withenv("JULIA_PKG_PRECOMPILE_AUTO" => "0") do
            withserver(;
                    rootUri = filepath2uri(pkgpath), settings,
                    capabilities = progress_capabilities
                ) do (; server, writemsg, writereadmsg, readmsg)
                (; raw_res) = writereadmsg(make_DidOpenTextDocumentNotification(pkg_uri, pkgcode))
                waiting_progress_request = raw_res
                @test waiting_progress_request isa WorkDoneProgressCreateRequest

                response = ResponseMessage(; id = waiting_progress_request.id, result = null)
                writemsg(response; check = false)
                (; raw_msg) = readmsg(; read=2)
                waiting_messages = raw_msg
                waiting_progress = only(msg for msg in waiting_messages if msg isa ProgressNotification)
                @test waiting_progress.params.token == waiting_progress_request.params.token
                @test waiting_progress.params.value isa WorkDoneProgressBegin
                @test waiting_progress.params.value.title == "Waiting for environment instantiation"
                raw_res = only(msg for msg in waiting_messages if msg isa ShowMessageRequest)
                @test first(waiting_messages) === waiting_progress
                @test last(waiting_messages) === raw_res
                @test occursin("Alternatively, you can resolve and instantiate it manually", raw_res.params.message)

                Pkg.activate(pkgpath) do
                    Pkg.instantiate(; io=devnull)
                end
                @test JETLS.instantiation_needs(env_path) ==
                    (; resolve=false, instantiate=false)
                manual_manifest = read(manifest_path, String)

                response = ResponseMessage(; id = raw_res.id, result = Dict{String,Any}("title" => "Skip"))
                writemsg(response; check = false)
                (; raw_msg) = readmsg(; read=2)
                post_prompt_messages = raw_msg
                waiting_end = only(msg for msg in post_prompt_messages if msg isa ProgressNotification)
                @test waiting_end.params.token == waiting_progress.params.token
                @test waiting_end.params.value isa WorkDoneProgressEnd
                @test waiting_end.params.value.message == "Using manually instantiated environment"
                analysis_progress_request = only(msg for msg in post_prompt_messages if msg isa WorkDoneProgressCreateRequest)

                response = ResponseMessage(; id = analysis_progress_request.id, result = null)
                writemsg(response; check = false)
                analysis_messages = Any[]
                while true
                    (; raw_msg) = readmsg(; check = false)
                    push!(analysis_messages, raw_msg)
                    raw_msg isa PublishDiagnosticsNotification && break
                end
                readmsg(; read=0)
                @test any(analysis_messages) do msg
                    msg isa ProgressNotification &&
                        msg.params.value isa WorkDoneProgressBegin &&
                        startswith(msg.params.value.title, "Analyzing ")
                end
                @test !any(analysis_messages) do msg
                    msg isa ProgressNotification &&
                        msg.params.value isa WorkDoneProgressBegin &&
                        msg.params.value.title == "Instantiating environment"
                end
                diagnostic = only(msg for msg in analysis_messages if msg isa PublishDiagnosticsNotification)
                @test diagnostic.params.uri == pkg_uri
                prompts = server.state.analysis_manager.instantiation_prompts
                @test only(values(JETLS.load(prompts))).decision === :declined
                analysis_info = JETLS.get_analysis_info(server.state.analysis_manager, pkg_uri)::JETLS.AnalysisResult
                @test analysis_info.entry isa JETLS.PackageSourceAnalysisEntry
                @test read(manifest_path, String) == manual_manifest
            end
        end
    end

    # "Instantiate" instantiates the environment before the analysis
    withpackage(pkgname, pkgcode; pkg_setup = Returns(nothing)) do pkgpath
        manifest_path = joinpath(pkgpath, "Manifest.toml")
        pkg_uri = filepath2uri(joinpath(pkgpath, "src", "$pkgname.jl"))
        withenv("JULIA_PKG_PRECOMPILE_AUTO" => "0") do
            withserver(; rootUri = filepath2uri(pkgpath), settings) do (; server, writemsg, writereadmsg, readmsg)
                (; raw_res) = writereadmsg(make_DidOpenTextDocumentNotification(pkg_uri, pkgcode))
                @test raw_res isa ShowMessageRequest
                writemsg(ResponseMessage(; id = raw_res.id, result = Dict{String,Any}("title" => "Instantiate")); check = false)
                (; raw_msg) = readmsg()
                @test raw_msg isa PublishDiagnosticsNotification
                @test raw_msg.params.uri == pkg_uri
                prompts = server.state.analysis_manager.instantiation_prompts
                @test only(values(JETLS.load(prompts))).decision === :accepted
                @test isfile(manifest_path)
            end
        end
    end

    # Changing the setting away from "prompt" drops pending prompts and analyzes their
    # waiters under the new setting; a late answer to the dropped prompt is ignored.
    @testset "config change to $mode drains pending prompts" for mode in (
            JETLS.AUTO_INSTANTIATE_ALWAYS, JETLS.AUTO_INSTANTIATE_NEVER)
        withpackage(pkgname, pkgcode; pkg_setup = Returns(nothing)) do pkgpath
            manifest_path = joinpath(pkgpath, "Manifest.toml")
            pkg_uri = filepath2uri(joinpath(pkgpath, "src", "$pkgname.jl"))
            withenv("JULIA_PKG_PRECOMPILE_AUTO" => "0") do
                withserver(; rootUri = filepath2uri(pkgpath), settings) do (; server, writereadmsg)
                    (; raw_res) = writereadmsg(make_DidOpenTextDocumentNotification(pkg_uri, pkgcode))
                    @test raw_res isa ShowMessageRequest
                    prompt_request = raw_res

                    # the config change notification, the "never" warning, then the diagnostics
                    nmsgs = mode == JETLS.AUTO_INSTANTIATE_NEVER ? 3 : 2
                    changed = Dict{String,Any}(
                        "full_analysis" => Dict{String,Any}("auto_instantiate" => mode))
                    (; raw_res) = writereadmsg(DidChangeConfigurationNotification(;
                            params = DidChangeConfigurationParams(; settings = changed));
                        read = nmsgs)
                    @test count(msg -> msg isa ShowMessageNotification, raw_res) == nmsgs - 1
                    @test count(msg -> msg isa PublishDiagnosticsNotification, raw_res) == 1
                    @test isempty(JETLS.load(server.state.analysis_manager.instantiation_prompts))
                    @test isfile(manifest_path) == (mode == JETLS.AUTO_INSTANTIATE_ALWAYS)

                    writereadmsg(ResponseMessage(; id = prompt_request.id,
                        result = Dict{String,Any}("title" => "Instantiate")); read = 0)
                    @test isfile(manifest_path) == (mode == JETLS.AUTO_INSTANTIATE_ALWAYS)
                end
            end
        end
    end
end

end # module test_full_analysis
