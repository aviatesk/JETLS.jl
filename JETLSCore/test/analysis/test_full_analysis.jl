module test_full_analysis

using Test
using JETLSCore: JETLSCore
using JETLSCore.URIs2: filepath2uri

include("../setup.jl")
include("../jsjl-utils.jl")

module module_range_target
module A
module B end
end
baremodule C end
end

@testset "immediate invalidation supersedes older requests" begin
    server = JETLSCore.Server()
    manager = server.state.analysis_manager
    script_uri = filepath2uri(joinpath(@__DIR__, "superseded-analysis.jl"))
    entry = JETLSCore.ScriptAnalysisEntry(script_uri)

    # `Server()` has no analysis worker. Manually dequeue generation 0 while
    # leaving its marker in `pending_analyses`, as happens during active analysis.
    JETLSCore.schedule_analysis!(server, script_uri, entry, #=invalidate=#false;
        debounce=0.0, notify_diagnostics=false)
    active_request = take!(manager.queue)::JETLSCore.AnalysisRequest
    @test JETLSCore.load(manager.pending_analyses)[entry] === nothing

    # Generation 1 represents a save-triggered request waiting on its debounce.
    JETLSCore.schedule_analysis!(server, script_uri, entry, #=invalidate=#true;
        debounce=60.0, notify_diagnostics=false)
    debounced_generation = JETLSCore.get_generation(manager, entry)
    debounce_timer, debounce_completion = JETLSCore.load(manager.debounced)[entry]
    debounce_completion_waiter = Threads.@spawn wait(debounce_completion)

    # Generation 2 is an immediate invalidation. It should cancel generation 1
    # and become the pending request behind the active generation 0 request.
    JETLSCore.schedule_analysis!(server, script_uri, entry, #=invalidate=#true;
        debounce=0.0, notify_diagnostics=false)
    @test JETLSCore.get_generation(manager, entry) == debounced_generation + 1
    @test !haskey(JETLSCore.load(manager.debounced), entry)
    @test !isopen(debounce_timer)
    @test timedwait(() -> istaskdone(debounce_completion_waiter), 1.0) == :ok

    immediate_request = JETLSCore.load(manager.pending_analyses)[entry]
    @test immediate_request isa JETLSCore.AnalysisRequest
    @test immediate_request.generation == debounced_generation + 1

    # A timer callback can race with cancellation and reach the queue late.
    # Such a generation 1 request must not replace the pending generation 2.
    late_completion = Base.Event()
    late_debounced_request = JETLSCore.AnalysisRequest(
        entry, script_uri, debounced_generation, nothing, false, late_completion)
    late_completion_waiter = Threads.@spawn wait(late_completion)
    JETLSCore.queue_request!(server, late_debounced_request)
    @test timedwait(() -> istaskdone(late_completion_waiter), 1.0) == :ok
    @test JETLSCore.load(manager.pending_analyses)[entry] === immediate_request

    # Finishing generation 0 should skip it without updating analysis state,
    # then promote the pending generation 2 request to the worker queue.
    JETLSCore.resolve_analysis_request(server, active_request)
    @test JETLSCore.get_analysis_info(manager, script_uri) === nothing
    @test !haskey(JETLSCore.load(manager.analyzed_generations), entry)
    @test take!(manager.queue) === immediate_request
end

@testset "concretization config changes reanalyze affected units" begin
    mktempdir() do dir
        server = JETLSCore.Server()
        server.state.root_path = dir
        manager = server.state.analysis_manager
        glob(pattern::String) = JETLSCore.Glob.FilenameMatch(pattern, "dp")
        function tracker_for(globs...; timeout::Bool = false)
            tracker = JETLSCore.ConfigChangeTracker()
            append!(tracker.changed_concretization_globs, globs)
            tracker.concretization_timeout_changed = timeout
            return tracker
        end

        script_uri = filepath2uri(joinpath(dir, "script.jl"))
        included_uri = filepath2uri(joinpath(dir, "src", "included.jl"))
        script_entry = JETLSCore.ScriptAnalysisEntry(script_uri)
        affected(entry, tracker; unit_uris = [script_uri, included_uri], analyzing = false) =
            JETLSCore.affected_by_config_changes(server, entry, tracker, unit_uris, analyzing)

        @testset "units consulting configured patterns" begin
            @test affected(script_entry, tracker_for(nothing))
            @test affected(script_entry, tracker_for(glob("src/*.jl")))
            @test !affected(script_entry, tracker_for(glob("other.jl")))
            @test affected(script_entry, tracker_for(; timeout = true))
            # configured patterns never apply outside the workspace
            outside_uri = filepath2uri(joinpath(dirname(dir), "outside.jl"))
            @test !affected(script_entry, tracker_for(nothing); unit_uris = [outside_uri])
            # the files to check are unknown
            @test affected(script_entry, tracker_for(glob("other.jl")); analyzing = true)
            @test affected(script_entry, tracker_for(glob("other.jl")); unit_uris = nothing)
        end

        @testset "units not consulting configured patterns" begin
            pkgid = Base.PkgId(@__MODULE__)
            package_entry = JETLSCore.PackageSourceAnalysisEntry(dir, script_uri, pkgid)
            @test !affected(package_entry, tracker_for(nothing); analyzing = true)
            @test affected(package_entry, tracker_for(; timeout = true))
            for entry in (JETLSCore.NewAnalysisEntry(pkgid), JETLSCore.PackageExtensionAnalysisEntry(script_uri))
                @test !affected(entry, tracker_for(nothing; timeout = true); analyzing = true)
            end
        end

        @testset "`request_reanalysis_for_tracked_entries!`" begin
            other_uri = filepath2uri(joinpath(dir, "other.jl"))
            other_entry = JETLSCore.ScriptAnalysisEntry(other_uri)
            world = Base.get_world_counter()
            for (entry, uris) in ((script_entry, [script_uri, included_uri]), (other_entry, [other_uri]))
                result = JETLSCore.AnalysisResult(entry,
                    JETLSCore.URI2Diagnostics(uri => Diagnostic[] for uri in uris),
                    JETLSCore.LSAnalyzer(entry, world),
                    Dict(uri => JETLSCore.JET.AnalyzedFileInfo() for uri in uris),
                    Main => Main, world)
                JETLSCore.update_analysis_cache!(server.state, result)
            end
            JETLSCore.store!(manager.tracked_entries) do _
                Dict{JETLSCore.AnalysisEntry,URI}(
                    script_entry => script_uri, other_entry => other_uri), nothing
            end
            # The glob matches a file of `script_entry` other than its tracked one
            JETLSCore.request_reanalysis_for_tracked_entries!(server, tracker_for(glob("src/*.jl")))
            @test JETLSCore.get_generation(manager, script_entry) == 1
            @test JETLSCore.get_generation(manager, other_entry) == 0
        end
    end
end

@testset "instantiation_needs" begin
    mktempdir() do env_dir
        env_path = joinpath(env_dir, "Project.toml")
        manifest_path = joinpath(env_dir, "Manifest.toml")
        write(env_path, "")

        @test !isfile(manifest_path)
        @test JETLSCore.instantiation_needs(env_path) == (; resolve=true, instantiate=true)

        withenv("JULIA_PKG_PRECOMPILE_AUTO" => "0") do
            Pkg.activate(env_dir) do
                Pkg.instantiate(; io=devnull)
            end
        end
        @test isfile(manifest_path)
        @test JETLSCore.instantiation_needs(env_path) == (; resolve=false, instantiate=false)

        # adding a dependency to `Project.toml` leaves the manifest stale
        open(env_path, "a") do io
            println(io, "\n[deps]\nTest = \"8dfed614-e22c-5e08-85e1-65c5234f0b40\"")
        end
        @test JETLSCore.instantiation_needs(env_path) == (; resolve=true, instantiate=true)

        Pkg.activate(env_dir) do
            Pkg.resolve(; io=devnull)
        end
        @test JETLSCore.instantiation_needs(env_path) == (; resolve=false, instantiate=false)

        manifest = read(manifest_path, String)
        manifest_without_test = replace(manifest,
            r"(?ms)^\[\[deps\.Test\]\]\n.*?(?=^\[\[deps\.|\z)" => "")
        @test manifest_without_test != manifest
        write(manifest_path, manifest_without_test)

        env = Pkg.Types.EnvCache(env_path)
        @test Pkg.Operations.is_manifest_current(env) === true
        @test Pkg.Operations.is_instantiated(env)
        @test JETLSCore.instantiation_needs(env_path) == (; resolve=true, instantiate=true)

        Pkg.activate(env_dir) do
            Pkg.resolve(; io=devnull)
        end
        @test JETLSCore.instantiation_needs(env_path) == (; resolve=false, instantiate=false)

        manifest = read(manifest_path, String)
        hashless_manifest = replace(manifest, r"(?m)^project_hash = .*\n" => "")
        @test hashless_manifest != manifest
        write(manifest_path, hashless_manifest)
        @test JETLSCore.instantiation_needs(env_path) == (; resolve=true, instantiate=true)

        Pkg.activate(env_dir) do
            Pkg.resolve(; io=devnull)
        end
        @test JETLSCore.instantiation_needs(env_path) == (; resolve=false, instantiate=false)

        write(manifest_path, "")
        @test JETLSCore.instantiation_needs(env_path) == (; resolve=true, instantiate=true)
    end
end

@testset "ensure_instantiated!" begin
    withpackage("TestEnsureInstantiated", "module TestEnsureInstantiated end";
                pkg_setup = Returns(nothing)) do pkgpath
        env_path = joinpath(pkgpath, "Project.toml")
        manifest_path = joinpath(pkgpath, "Manifest.toml")
        sent_queue = Channel{Any}(Inf)
        server = JETLSCore.Server(;
            callback = JETLSCore.ServerMessageRecorder(Channel{Any}(Inf), sent_queue))
        function set_auto_instantiate!(auto_instantiate)
            JETLSCore.store!(server.state.config_manager) do old_data
                lsp_config = JETLSCore.JETLSConfig(;
                    full_analysis = JETLSCore.FullAnalysisConfig(; auto_instantiate))
                return JETLSCore.ConfigManagerData(old_data; lsp_config), nothing
            end
        end
        ensure_instantiated!() = JETLSCore.activate_do(env_path) do
            JETLSCore.ensure_instantiated!(server, env_path)
        end

        # disabled: only warn, never touch the environment
        set_auto_instantiate!(JETLSCore.AUTO_INSTANTIATE_NEVER)
        ensure_instantiated!()
        @test !isfile(manifest_path)
        let msg = take!(sent_queue)
            @test msg isa ShowMessageNotification
            @test msg.params.type == MessageType.Warning
        end
        @test isempty(sent_queue)

        # "prompt" without a client decision behaves like "never"
        set_auto_instantiate!(JETLSCore.AUTO_INSTANTIATE_PROMPT)
        ensure_instantiated!()
        @test !isfile(manifest_path)
        @test take!(sent_queue) isa ShowMessageNotification
        @test isempty(sent_queue)

        set_auto_instantiate!(JETLSCore.AUTO_INSTANTIATE_ALWAYS)
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
        server = JETLSCore.Server(; cli_mode = true,
            callback = JETLSCore.ServerMessageRecorder(Channel{Any}(Inf), sent_queue))
        JETLSCore.store!(server.state.config_manager) do old_data
            lsp_config = JETLSCore.JETLSConfig(;
                full_analysis = JETLSCore.FullAnalysisConfig(;
                    auto_instantiate = JETLSCore.AUTO_INSTANTIATE_PROMPT))
            return JETLSCore.ConfigManagerData(old_data; lsp_config), nothing
        end
        withenv("JULIA_PKG_PRECOMPILE_AUTO" => "0") do
            @test_logs (:info, "Resolving package environment") (:info, "Instantiating package environment") match_mode=:any begin
                redirect_stderr(devnull) do
                    JETLSCore.activate_do(env_path) do
                        JETLSCore.ensure_instantiated!(server, env_path)
                    end
                end
            end
        end
        @test isfile(manifest_path)
        @test isempty(sent_queue)
    end
end

@testset "do_instantiation_with_progress with offline Pkg" begin
    offline = Pkg.OFFLINE_MODE[]
    Pkg.offline(true)
    try
        withenv("JULIA_PKG_PRECOMPILE_AUTO" => "0") do
            @testset "$filekind" for filekind in (:script, :src)
                pkgname = "TestInstantiationProgress"
                withpackage(pkgname, "module $pkgname end";
                    pkg_setup = Returns(nothing)) do pkgpath
                    env_path = joinpath(pkgpath, "Project.toml")
                    manifest_path = joinpath(pkgpath, "Manifest.toml")
                    deps = "\n[deps]\nTest = \"8dfed614-e22c-5e08-85e1-65c5234f0b40\"\n"
                    if filekind === :script
                        write(env_path, deps)
                        script_path = joinpath(pkgpath, "script.jl")
                        write(script_path, "using Test\n")
                        uri = filepath2uri(script_path)
                    else
                        open(env_path, "a") do io
                            print(io, deps)
                        end
                        uri = filepath2uri(joinpath(pkgpath, "src", "$pkgname.jl"))
                    end
                    sent_queue = Channel{Any}(Inf)
                    server = JETLSCore.Server(;
                        callback = JETLSCore.ServerMessageRecorder(Channel{Any}(Inf), sent_queue))
                    server.state.root_path = pkgpath
                    JETLSCore.store!(server.state.config_manager) do old_data
                        lsp_config = JETLSCore.JETLSConfig(;
                            full_analysis = JETLSCore.FullAnalysisConfig(;
                                auto_instantiate = JETLSCore.AUTO_INSTANTIATE_ALWAYS))
                        return JETLSCore.ConfigManagerData(old_data; lsp_config), nothing
                    end
                    token = "pkg-instantiation-$filekind"
                    @test !isfile(manifest_path)
                    request = JETLSCore.lookup_analysis_entry(server, uri)
                    @test request isa JETLSCore.InstantiationRequest
                    entry = JETLSCore.do_instantiation_with_progress(server, request, token)
                    @test isfile(manifest_path)
                    @test JETLSCore.instantiation_needs(env_path) == (; resolve=false, instantiate=false)
                    @test filepath2uri(entry.env_path) == filepath2uri(env_path)
                    if filekind === :script
                        @test entry isa JETLSCore.ScriptInEnvAnalysisEntry
                        @test entry.uri == uri
                    else
                        @test entry isa JETLSCore.PackageSourceAnalysisEntry
                        @test entry.pkgfileuri == uri
                        @test entry.pkgid.name == "TestInstantiationProgress"
                    end
                    messages = Any[]
                    while isready(sent_queue)
                        push!(messages, take!(sent_queue))
                    end
                    @test all(msg -> msg isa ProgressNotification, messages)
                    @test all(msg -> msg.params.token == token, messages)
                    @test first(messages).params.value isa WorkDoneProgressBegin
                    @test last(messages).params.value isa WorkDoneProgressEnd
                    begin_value = first(messages).params.value
                    @test begin_value.title == "Instantiating environment"
                    @test begin_value.message == joinpath("TestInstantiationProgress", "Project.toml")
                    @test begin_value.cancellable === false
                    reports = messages[2:end-1]
                    @test !isempty(reports)
                    @test all(msg -> msg.params.value isa WorkDoneProgressReport, reports)
                    @test all(reports) do msg
                        message = msg.params.value.message
                        message isa String && !isempty(message)
                    end
                end
            end
        end
    finally
        Pkg.offline(offline)
    end
end

@testset "find_env_package" begin
    uuid = "f7e1a6a2-4bd3-4f0e-9a43-0a3c6f6d8c51"
    function find_env_package(project_toml::String, entryfiles::String...)
        mktempdir() do dir
            env_path = joinpath(dir, "Project.toml")
            write(env_path, project_toml)
            for entryfile in entryfiles
                mkpath(dirname(joinpath(dir, entryfile)))
                touch(joinpath(dir, entryfile))
            end
            pkg = JETLSCore.find_env_package(env_path, JETLSCore.parse_project_toml(env_path))
            return pkg === nothing ? nothing :
                (; pkg.pkgid, pkgfile = relpath(pkg.pkgfile, dir),
                   base_pkgid = Base.project_file_name_uuid(env_path, pkg.pkgid.name))
        end
    end

    let pkg = find_env_package("name = \"Foo\"\nuuid = \"$uuid\"\n", "src/Foo.jl")
        @test pkg.pkgid == Base.PkgId(Base.UUID(uuid), "Foo")
        @test pkg.pkgfile == joinpath("src", "Foo.jl")
    end
    let pkg = find_env_package(
            "name = \"Foo\"\nuuid = \"$uuid\"\nentryfile = \"main.jl\"\n", "main.jl")
        @test pkg.pkgfile == "main.jl"
    end
    # `Base` loads a project without `uuid` under a path-derived dummy UUID
    let pkg = find_env_package("name = \"Foo\"\n", "src/Foo.jl")
        @test pkg.pkgid == pkg.base_pkgid
    end
    @test find_env_package("name = \"Foo\"\nuuid = \"$uuid\"\n") === nothing
    @test find_env_package("name = \"Foo\"\nuuid = \"invalid\"\n", "src/Foo.jl") === nothing
    @test find_env_package("[deps]\n", "src/Foo.jl") === nothing
    for entryfile in ("a"^300 * ".jl", "a\\u0000b.jl")
        @test find_env_package("name = \"Foo\"\nuuid = \"$uuid\"\nentryfile = \"$entryfile\"\n") === nothing
    end
end

@testset "package files after instantiating the environment for a script" begin
    pkgname = "TestScriptInstantiation"
    withpackage(pkgname, "module $pkgname end") do pkgpath
        script_path = joinpath(pkgpath, "script.jl")
        write(script_path, "1 + 1\n")
        script_uri = filepath2uri(script_path)
        pkgfile_uri = filepath2uri(joinpath(pkgpath, "src", "$pkgname.jl"))
        server = JETLSCore.Server()
        server.state.root_path = pkgpath

        request = JETLSCore.lookup_analysis_entry(server, script_uri)
        @test request isa JETLSCore.InstantiationRequest
        @test JETLSCore.do_instantiation(server, request) isa JETLSCore.ScriptInEnvAnalysisEntry

        entry = JETLSCore.lookup_analysis_entry(server, pkgfile_uri)
        @test entry isa JETLSCore.PackageSourceAnalysisEntry
        @test entry.pkgfileuri == pkgfile_uri
        @test entry.pkgid.name == pkgname
    end
end

@testset "auto_instantiate = \"prompt\"" begin
    settings = Dict{String,Any}(
        "full_analysis" => Dict{String,Any}(
            "auto_instantiate" => JETLSCore.AUTO_INSTANTIATE_PROMPT))
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
                length(only(values(JETLSCore.load(prompts))).waiters) == 2
            end == :ok
            @test only(values(JETLSCore.load(prompts))).decision === :pending

            for debounce in (1.0, 2.0, 0.0)
                JETLSCore.request_analysis!(server, script_uri, #=invalidate=#true; debounce)
            end
            waiters = only(values(JETLSCore.load(prompts))).waiters
            @test length(waiters) == 2
            script_waiter = only(waiter for waiter in waiters if waiter.uri == script_uri)
            @test script_waiter.invalidate
            @test script_waiter.debounce == 0.0

            writemsg(ResponseMessage(; id = raw_res.id, result = Dict{String,Any}("title" => "Skip")); check = false)
            # The first completed analysis publishes one URI; the second republishes both.
            (; raw_msg) = readmsg(; read = 3)
            @test all(msg -> msg isa PublishDiagnosticsNotification, raw_msg)
            @test Set(msg.params.uri for msg in raw_msg) == Set([pkg_uri, script_uri])
            @test only(values(JETLSCore.load(prompts))).decision === :declined
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
                @test JETLSCore.instantiation_needs(env_path) ==
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
                @test only(values(JETLSCore.load(prompts))).decision === :declined
                analysis_info = JETLSCore.get_analysis_info(server.state.analysis_manager, pkg_uri)::JETLSCore.AnalysisResult
                @test analysis_info.entry isa JETLSCore.PackageSourceAnalysisEntry
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
                @test only(values(JETLSCore.load(prompts))).decision === :accepted
                @test isfile(manifest_path)
            end
        end
    end

    # Changing the setting away from "prompt" drops pending prompts and analyzes their
    # waiters under the new setting; a late answer to the dropped prompt is ignored.
    @testset "config change to $mode drains pending prompts" for mode in (
            JETLSCore.AUTO_INSTANTIATE_ALWAYS, JETLSCore.AUTO_INSTANTIATE_NEVER)
        withpackage(pkgname, pkgcode; pkg_setup = Returns(nothing)) do pkgpath
            manifest_path = joinpath(pkgpath, "Manifest.toml")
            pkg_uri = filepath2uri(joinpath(pkgpath, "src", "$pkgname.jl"))
            withenv("JULIA_PKG_PRECOMPILE_AUTO" => "0") do
                withserver(; rootUri = filepath2uri(pkgpath), settings) do (; server, writereadmsg)
                    (; raw_res) = writereadmsg(make_DidOpenTextDocumentNotification(pkg_uri, pkgcode))
                    @test raw_res isa ShowMessageRequest
                    prompt_request = raw_res

                    # the config change notification, the "never" warning, then the diagnostics
                    nmsgs = mode == JETLSCore.AUTO_INSTANTIATE_NEVER ? 3 : 2
                    changed = Dict{String,Any}(
                        "full_analysis" => Dict{String,Any}("auto_instantiate" => mode))
                    (; raw_res) = writereadmsg(DidChangeConfigurationNotification(;
                            params = DidChangeConfigurationParams(; settings = changed));
                        read = nmsgs)
                    @test count(msg -> msg isa ShowMessageNotification, raw_res) == nmsgs - 1
                    @test count(msg -> msg isa PublishDiagnosticsNotification, raw_res) == 1
                    @test isempty(JETLSCore.load(server.state.analysis_manager.instantiation_prompts))
                    @test isfile(manifest_path) == (mode == JETLSCore.AUTO_INSTANTIATE_ALWAYS)

                    (; raw_res) = writereadmsg(ResponseMessage(;
                        id = prompt_request.id,
                        result = Dict{String,Any}("title" => "Instantiate")))
                    @test raw_res isa ShowMessageNotification
                    @test raw_res.params.type == MessageType.Info
                    @test occursin("Your selection was not applied.", raw_res.params.message)
                    @test isfile(manifest_path) == (mode == JETLSCore.AUTO_INSTANTIATE_ALWAYS)
                end
            end
        end
    end
end

function with_analysis_server(f::Function)
    mktempdir() do dir
        server = JETLSCore.Server()
        server.state.root_path = dir
        JETLSCore.start_signature_analysis_workers!(server)
        try
            f(server, dir)
        finally
            JETLSCore.stop_signature_analysis_workers(server)
            close(server.endpoint)
            close(server.message_queue)
        end
    end
end

function analyze_saved_unit(
        server::JETLSCore.Server, entry_uri::URI;
        request_uri::URI = entry_uri,
        entry::JETLSCore.AnalysisEntry = JETLSCore.ScriptAnalysisEntry(entry_uri),
        prev_result::Union{Nothing,JETLSCore.AnalysisResult} = nothing
    )
    request = JETLSCore.AnalysisRequest(entry, request_uri,
        #=generation=#1, #=token=#nothing, #=notify=#false)
    execution = JETLSCore.AnalysisExecution(request, prev_result)
    interp, jet_result = JETLSCore.analyze_parsed_if_exist(server, execution)
    result, replaced = JETLSCore.new_analysis_result(interp, jet_result)
    return (; result, replaced, jet_result, execution)
end

function populate_analysis_context_caches!(server::JETLSCore.Server, uri::URI)
    fi = JETLSCore.get_file_info(server.state, uri)::JETLSCore.FileInfo
    JETLSCore.get_per_file_diagnostics!(server, uri, fi, JETLSCore.DUMMY_CANCEL_FLAG)
    st0_top = JETLSCore.build_syntax_tree(fi)
    st0 = JETLSCore.lowerable_toplevel_at(st0_top, 1)
    mod = JETLSCore.get_context_module(server.state, uri, Position(; line=0, character=0))
    JETLSCore.build_inferred_context_for_range(st0_top, mod, JETLSCore.JS.byte_range(st0);
        cache=fi.inferred_context_cache)
    @test haskey(JETLSCore.load(server.state.binding_occurrences_cache), uri)
    @test haskey(JETLSCore.load(server.state.per_file_diagnostics_cache), uri)
    @test !isempty(JETLSCore.load(fi.inferred_context_cache))
    JETLSCore.check_syntax_tree0(fi)
    return fi
end

@testset "analysis override abort" begin
    @testset "nested abort cannot be caught or run finally" begin
        for saved_excluded in (true, false)
            with_analysis_server() do server, dir
                state = server.state
                entry_uri = filepath2uri(joinpath(dir, "main.jl"))
                nested_uri = filepath2uri(joinpath(dir, "nested.jl"))
                excluded_path = joinpath(dir, "excluded.jl")
                excluded_uri = filepath2uri(excluded_path)
                marker = joinpath(dir, "executed")
                side_effect = "@eval write($(repr(marker)), \"executed\")"
                state.init_options = JETLSCore.merge_init_options(state.init_options,
                    JETLSCore.InitOptions(; analysis_overrides=[
                        JETLSCore.AnalysisOverride(;
                            path=JETLSCore.Glob.FilenameMatch("excluded.jl", "dp"),
                            full_analysis=false)]))
                JETLSCore.cache_saved_file_info!(state, entry_uri, """
                    missing_before_include
                    body_error() = missing_from_body()
                    try
                        include("nested.jl")
                    catch
                        $side_effect
                    finally
                        $side_effect
                    end
                    $side_effect
                    """)
                JETLSCore.cache_saved_file_info!(state, nested_uri, """
                    const nested_started = true
                    try
                        include("excluded.jl")
                    catch
                        $side_effect
                    finally
                        $side_effect
                    end
                    $side_effect
                    """)
                if saved_excluded
                    JETLSCore.cache_saved_file_info!(state, excluded_uri, side_effect)
                end
                @test !isfile(excluded_path)

                (; result, jet_result, execution) = analyze_saved_unit(server, entry_uri)
                report = jet_result.res.toplevel_error_report
                @test report isa JETLSCore.AnalysisStoppedReport
                @test report isa JETLSCore.JET.ToplevelErrorReport
                @test report.file == uri2filename(nested_uri)
                @test report.line == 3
                @test report.excluded_file == uri2filename(excluded_uri)
                diagnostic = only(result.uri2diagnostics[nested_uri])
                @test diagnostic.code == JETLSCore.TOPLEVEL_ANALYSIS_STOPPED_CODE
                @test diagnostic.severity == DiagnosticSeverity.Warning
                @test diagnostic.source == JETLSCore.DIAGNOSTIC_SOURCE_SAVE
                @test diagnostic.range == JETLSCore.line_range(3)
                @test occursin("excluded.jl", diagnostic.message)
                @test any(result.uri2diagnostics[entry_uri]) do d
                    d.code == JETLSCore.INFERENCE_UNDEF_GLOBAL_VAR_CODE &&
                        occursin("missing_before_include", d.message)
                end
                @test !any(d -> occursin("missing_from_body", d.message),
                    Iterators.flatten(values(result.uri2diagnostics)))
                @test !execution.context_refreshed
                @test !haskey(result.analyzed_file_infos, excluded_uri)
                @test !isfile(marker)
            end
        end
    end

    @testset "package-style concretization inside a module" begin
        with_analysis_server() do server, dir
            state = server.state
            entry_uri = filepath2uri(joinpath(dir, "main.jl"))
            excluded_path = joinpath(dir, "excluded.jl")
            started = joinpath(dir, "started")
            marker = joinpath(dir, "executed")
            state.init_options = JETLSCore.merge_init_options(state.init_options,
                JETLSCore.InitOptions(; analysis_overrides=[
                    JETLSCore.AnalysisOverride(;
                        path=JETLSCore.Glob.FilenameMatch("excluded.jl", "dp"),
                        full_analysis=false, module_name="Test")]))
            JETLSCore.cache_saved_file_info!(state, entry_uri, """
                module PackageStyle
                write($(repr(started)), "started")
                Base.include(@__MODULE__, "excluded.jl")
                write($(repr(marker)), "after include")
                end
                write($(repr(marker)), "after module")
                """)
            JETLSCore.cache_saved_file_info!(state, filepath2uri(excluded_path),
                "write($(repr(marker)), \"excluded\")")
            entry = JETLSCore.PackageSourceAnalysisEntry(dir, entry_uri, Base.PkgId(@__MODULE__))
            @test JETLSCore.getjetconfigs(server, entry)[:concretization_patterns] == [:(x_)]
            (; result, jet_result, execution) = analyze_saved_unit(server, entry_uri; entry)
            report = jet_result.res.toplevel_error_report
            @test report isa JETLSCore.AnalysisStoppedReport
            @test report.file == uri2filename(entry_uri)
            @test report.line == 3
            @test report.excluded_file == uri2filename(filepath2uri(excluded_path))
            diagnostic = only(result.uri2diagnostics[entry_uri])
            @test diagnostic.code == JETLSCore.TOPLEVEL_ANALYSIS_STOPPED_CODE
            @test diagnostic.severity == DiagnosticSeverity.Warning
            @test diagnostic.source == JETLSCore.DIAGNOSTIC_SOURCE_SAVE
            @test diagnostic.range == JETLSCore.line_range(3)
            @test !execution.context_refreshed
            @test isfile(started)
            @test !isfile(marker)
        end
    end

    @testset "skipped includes continue the analysis" begin
        with_analysis_server() do server, dir
            state = server.state
            entry_uri = filepath2uri(joinpath(dir, "main.jl"))
            excluded_uri = filepath2uri(joinpath(dir, "excluded.jl"))
            later_uri = filepath2uri(joinpath(dir, "later.jl"))
            marker = joinpath(dir, "executed")
            state.init_options = JETLSCore.merge_init_options(state.init_options,
                JETLSCore.InitOptions(; analysis_overrides=[
                    JETLSCore.AnalysisOverride(;
                        path=JETLSCore.Glob.FilenameMatch("excluded.jl", "dp"),
                        on_include="skip")]))
            JETLSCore.cache_saved_file_info!(state, entry_uri, """
                begin
                    include("excluded.jl")
                end
                include("later.jl")
                """)
            JETLSCore.cache_saved_file_info!(state, excluded_uri,
                "@eval write($(repr(marker)), \"executed\")")
            JETLSCore.cache_saved_file_info!(state, later_uri, "later() = missing_later()")
            (; result, jet_result) = analyze_saved_unit(server, entry_uri)
            @test jet_result.res.toplevel_error_report === nothing
            @test Set(keys(result.analyzed_file_infos)) == Set([entry_uri, later_uri])
            diagnostic = only(result.uri2diagnostics[entry_uri])
            @test diagnostic.code == JETLSCore.TOPLEVEL_ANALYSIS_SKIPPED_CODE
            @test diagnostic.severity == DiagnosticSeverity.Information
            @test diagnostic.source == JETLSCore.DIAGNOSTIC_SOURCE_SAVE
            @test diagnostic.range == JETLSCore.line_range(2)
            @test only(diagnostic.relatedInformation).location.uri == excluded_uri
            @test any(result.uri2diagnostics[later_uri]) do d
                d.code == JETLSCore.INFERENCE_UNDEF_GLOBAL_VAR_CODE &&
                    occursin("missing_later", d.message)
            end
            @test !isfile(marker)
        end
    end

    @testset "first match and nonexcluded includes" begin
        with_analysis_server() do server, dir
            mktempdir() do outside_dir
                state = server.state
                entry_uri = filepath2uri(joinpath(dir, "main.jl"))
                allowed_path = joinpath(dir, "allowed.jl")
                allowed_uri = filepath2uri(allowed_path)
                outside_path = joinpath(outside_dir, "outside.jl")
                outside_uri = filepath2uri(outside_path)
                write(allowed_path, "error(\"must use saved contents\")")
                write(outside_path, "@eval const outside_value = 42")
                JETLSCore.cache_saved_file_info!(state, entry_uri, """
                    include("allowed.jl")
                    include($(repr(outside_path)))
                    """)
                JETLSCore.cache_saved_file_info!(state, allowed_uri, "@eval const saved_value = 1")
                allow_entry = JETLSCore.AnalysisOverride(;
                    path=JETLSCore.Glob.FilenameMatch("main.jl", "dp"), full_analysis=true)
                allow_include = JETLSCore.AnalysisOverride(;
                    path=JETLSCore.Glob.FilenameMatch("allowed.jl", "dp"), full_analysis=true)
                deny = JETLSCore.AnalysisOverride(;
                    path=JETLSCore.Glob.FilenameMatch("*.jl", "dp"), full_analysis=false)
                state.init_options = JETLSCore.merge_init_options(state.init_options,
                    JETLSCore.InitOptions(; analysis_overrides=[allow_entry, allow_include, deny]))

                (; result, jet_result) = analyze_saved_unit(server, entry_uri)
                @test jet_result.res.toplevel_error_report === nothing
                @test all(isempty, values(result.uri2diagnostics))
                @test Set(keys(result.analyzed_file_infos)) ==
                    Set([entry_uri, allowed_uri, outside_uri])
                pos = Position(; line=0, character=0)
                @test Base.invoke_in_world(result.world, getglobal,
                    JETLSCore.get_context_module(result, allowed_uri, pos), :saved_value) == 1
                @test Base.invoke_in_world(result.world, getglobal,
                    JETLSCore.get_context_module(result, outside_uri, pos), :outside_value) == 42

                state.init_options = JETLSCore.merge_init_options(state.init_options,
                    JETLSCore.InitOptions(; analysis_overrides=[allow_entry, deny, allow_include]))
                stopped = analyze_saved_unit(server, entry_uri)
                @test stopped.jet_result.res.toplevel_error_report isa JETLSCore.AnalysisStoppedReport
                @test only(stopped.result.uri2diagnostics[entry_uri]).range == JETLSCore.line_range(1)
                @test !haskey(stopped.result.analyzed_file_infos, allowed_uri)
                @test !haskey(stopped.result.analyzed_file_infos, outside_uri)
            end
        end
    end

    @testset "reanalysis removes stale contexts and diagnostics" begin
        with_analysis_server() do server, dir
            state = server.state
            manager = state.analysis_manager
            entry_uri = filepath2uri(joinpath(dir, "main.jl"))
            excluded_uri = filepath2uri(joinpath(dir, "excluded.jl"))
            later_uri = filepath2uri(joinpath(dir, "later.jl"))
            independent_uri = filepath2uri(joinpath(dir, "independent.jl"))
            for (uri, code) in (
                    entry_uri => """
                        root_value() = 1
                        include("excluded.jl")
                        include("later.jl")
                        """,
                    excluded_uri => "stale_child() = missing_child()",
                    later_uri => "stale_later() = missing_later()",
                    independent_uri => "independent_error() = missing_independent()")
                JETLSCore.cache_saved_file_info!(state, uri, code)
                JETLSCore.cache_file_info!(server, uri, 1, code)
            end
            original = analyze_saved_unit(server, entry_uri; request_uri=later_uri)
            @test original.jet_result.res.toplevel_error_report === nothing
            JETLSCore.update_analysis_cache!(state, original.result)
            @test !isempty(original.result.uri2diagnostics[excluded_uri])
            @test !isempty(original.result.uri2diagnostics[later_uri])
            independent = analyze_saved_unit(server, independent_uri)
            JETLSCore.update_analysis_cache!(state, independent.result)
            independent_fi = populate_analysis_context_caches!(server, independent_uri)
            for uri in (entry_uri, excluded_uri, later_uri)
                @test JETLSCore.has_analyzed_context(state, uri)
                populate_analysis_context_caches!(server, uri)
            end

            state.init_options = JETLSCore.merge_init_options(state.init_options,
                JETLSCore.InitOptions(; analysis_overrides=[
                    JETLSCore.AnalysisOverride(;
                        path=JETLSCore.Glob.FilenameMatch("excluded.jl", "dp"), full_analysis=false)]))
            stopped = analyze_saved_unit(server, entry_uri;
                request_uri=later_uri, prev_result=original.result)
            @test stopped.replaced
            @test stopped.result.actual2virtual !== original.result.actual2virtual
            JETLSCore.update_analysis_cache!(state, stopped.result)
            @test JETLSCore.has_analyzed_context(state, entry_uri)
            for uri in (excluded_uri, later_uri)
                @test JETLSCore.get_analysis_info(manager, uri) === nothing
                @test !JETLSCore.has_analyzed_context(state, uri)
                @test !haskey(stopped.result.uri2diagnostics, uri)
            end
            diagnostics = JETLSCore.get_full_diagnostics(server, Set([excluded_uri, later_uri]))
            @test all(isempty, values(diagnostics))
            for uri in (entry_uri, excluded_uri, later_uri)
                @test !haskey(JETLSCore.load(state.binding_occurrences_cache), uri)
                @test !haskey(JETLSCore.load(state.per_file_diagnostics_cache), uri)
                @test isempty(JETLSCore.load(JETLSCore.get_file_info(state, uri).inferred_context_cache))
            end

            @test JETLSCore.get_analysis_info(manager, independent_uri) === independent.result
            @test JETLSCore.has_analyzed_context(state, independent_uri)
            @test haskey(JETLSCore.load(state.binding_occurrences_cache), independent_uri)
            @test haskey(JETLSCore.load(state.per_file_diagnostics_cache), independent_uri)
            @test JETLSCore.get_file_info(state, independent_uri) === independent_fi
            @test !isempty(JETLSCore.get_full_diagnostics(server, Set([independent_uri]))[independent_uri])
            rerun = analyze_saved_unit(server, independent_uri; prev_result=independent.result)
            @test rerun.jet_result.res.toplevel_error_report === nothing
            @test rerun.execution.context_refreshed
            @test any(rerun.result.uri2diagnostics[independent_uri]) do d
                d.code == JETLSCore.INFERENCE_UNDEF_GLOBAL_VAR_CODE &&
                    occursin("missing_independent", d.message)
            end
            for fi in values(JETLSCore.load(state.file_cache))
                JETLSCore.check_syntax_tree0(fi)
            end
        end
    end
end

@testset "excluded entry files" begin
    mktempdir() do dir
        write(joinpath(dir, "Project.toml"), "name = \"ExcludedEntry\"\n")
        pkgfile = joinpath(mkpath(joinpath(dir, "src")), "ExcludedEntry.jl")
        runtests = joinpath(mkpath(joinpath(dir, "test")), "runtests.jl")
        for path in (pkgfile, runtests, joinpath(dir, "src", "other.jl"), joinpath(dir, "test", "other.jl"))
            touch(path)
        end
        for (entryfile, pattern, unaffected_file, UnaffectedEntry) in (
                (pkgfile, "src/ExcludedEntry.jl", runtests, JETLSCore.PackageTestAnalysisEntry),
                (runtests, "test/runtests.jl", pkgfile, JETLSCore.PackageSourceAnalysisEntry))
            state = JETLSCore.ServerState()
            state.root_path = dir
            state.init_options = JETLSCore.InitOptions(; analysis_overrides=[
                JETLSCore.AnalysisOverride(; path=JETLSCore.Glob.FilenameMatch(pattern, "dp"))])
            entryuri = filepath2uri(entryfile)
            otheruri = filepath2uri(joinpath(dirname(entryfile), "other.jl"))
            for uri in (entryuri, otheruri)
                result = JETLSCore.find_analysis_entry(state, uri)
                @test result isa JETLSCore.OutOfScope
                @test result.module_context === JETLSCore.FallbackAnalysisContext
                @test result.skip_reason == JETLSCore.AnalysisExclusion(entryuri, pattern)
            end
            @test JETLSCore.find_analysis_entry(state, filepath2uri(unaffected_file)) isa UnaffectedEntry
        end
    end
end

@testset "package test environments" begin
    mktempdir() do dir
        write(joinpath(dir, "Project.toml"), """
            name = "TestEnvPkg"
            [workspace]
            projects = ["test"]
            """)
        touch(joinpath(mkpath(joinpath(dir, "src")), "TestEnvPkg.jl"))
        testdir = mkpath(joinpath(dir, "test"))
        test_env_path = joinpath(testdir, "Project.toml")
        write(test_env_path, "[deps]\n")
        runtests = joinpath(testdir, "runtests.jl")
        state = JETLSCore.ServerState()
        state.root_path = dir
        for path in (runtests, joinpath(testdir, "test_a.jl"),
                     joinpath(mkpath(joinpath(testdir, "sub")), "test_b.jl"))
            touch(path)
            entry = JETLSCore.find_analysis_entry(state, filepath2uri(path))
            @test entry isa JETLSCore.PackageTestAnalysisEntry
            @test filepath2uri(entry.env_path) == filepath2uri(test_env_path)
            @test entry.runtestsuri == filepath2uri(runtests)
            @test entry.pkgid.name == "TestEnvPkg"
        end

        # a nameless environment in another directory is not a package test environment
        scriptsdir = mkpath(joinpath(dir, "scripts"))
        write(joinpath(scriptsdir, "Project.toml"), "[deps]\n")
        script = joinpath(scriptsdir, "script.jl")
        touch(script)
        @test JETLSCore.find_analysis_entry(state, filepath2uri(script)) isa JETLSCore.ScriptInEnvAnalysisEntry
    end

    # `test/Project.toml` of a directory that is not a package
    mktempdir() do dir
        testdir = mkpath(joinpath(dir, "test"))
        write(joinpath(testdir, "Project.toml"), "[deps]\n")
        runtests = joinpath(testdir, "runtests.jl")
        touch(runtests)
        state = JETLSCore.ServerState()
        state.root_path = dir
        @test JETLSCore.find_analysis_entry(state, filepath2uri(runtests)) isa JETLSCore.ScriptInEnvAnalysisEntry
    end
end

function analyze_package_source(server::JETLSCore.Server, pkgpath::String, pkgname::String)
    server.state.root_path = pkgpath
    pkg_uri = filepath2uri(joinpath(pkgpath, "src", "$pkgname.jl"))
    entry = JETLSCore.find_analysis_entry(server.state, pkg_uri)
    @test entry isa JETLSCore.PackageSourceAnalysisEntry
    request = JETLSCore.AnalysisRequest(entry, pkg_uri,
        #=generation=#1, #=token=#nothing, #=notify=#false)
    result, = JETLSCore.execute_analysis(server, JETLSCore.AnalysisExecution(request, nothing))
    return pkg_uri, result
end

function published_diagnostics(responses::Vector{Any}, uri::URI)
    return only(filter(responses) do res
        res isa PublishDiagnosticsNotification && res.params.uri == uri
    end).params.diagnostics
end

@testset "an included script joins the unit of the script that includes it" begin
    mktempdir() do dir
        main_path = joinpath(dir, "main.jl")
        utils_path = joinpath(dir, "utils.jl")
        main_code = """
            factor() = 2
            include("utils.jl")
            """
        utils_code = """
            scaled(x) = factor() * x
            """
        write(main_path, main_code)
        write(utils_path, utils_code)
        main_uri = filepath2uri(main_path)
        utils_uri = filepath2uri(utils_path)
        mentions(name) = diag -> occursin(name, diag.message)
        withserver(; rootUri = filepath2uri(dir)) do (; server, writereadmsg, readmsg)
            manager = server.state.analysis_manager
            utils_entry = JETLSCore.ScriptAnalysisEntry(utils_uri)

            # opened first, `utils.jl` is analyzed alone, without what `main.jl` defines
            let (; raw_res) = writereadmsg(
                    make_DidOpenTextDocumentNotification(utils_uri, utils_code))
                @test raw_res isa PublishDiagnosticsNotification
                @test raw_res.params.uri == utils_uri
                @test any(mentions("factor"), raw_res.params.diagnostics)
            end
            standalone = JETLSCore.get_analysis_info(manager, utils_uri)::JETLSCore.AnalysisResult
            standalone_scaled = let mod = JETLSCore.get_context_module(
                    standalone, utils_uri, Position(; line=0, character=0))
                f = Base.invoke_in_world(standalone.world, getglobal, mod, :scaled)
                only(Base.invoke_in_world(standalone.world, methods, f))
            end

            let (; raw_res) = writereadmsg(
                    make_DidOpenTextDocumentNotification(main_uri, main_code); read=2)
                @test !any(mentions("factor"), published_diagnostics(raw_res, utils_uri))
            end
            # the unit that `utils.jl` formed alone is gone
            @test !haskey(JETLSCore.load(manager.tracked_entries), utils_entry)
            @test !haskey(JETLSCore.load(manager.analyzed_generations), utils_entry)
            @test JETLSCore.is_method_disabled(standalone_scaled)

            # saving `utils.jl` reanalyzes the unit from `main.jl`
            new_utils_code = """
                scaled(x) = factor() * x
                shifted(x) = x + offset()
                """
            let (; raw_res) = writereadmsg(DidSaveTextDocumentNotification(;
                    params = DidSaveTextDocumentParams(;
                        textDocument = TextDocumentIdentifier(; uri = utils_uri),
                        text = new_utils_code)); read=2)
                diagnostics = published_diagnostics(raw_res, utils_uri)
                @test !any(mentions("factor"), diagnostics)
                @test any(mentions("offset"), diagnostics)
            end

            # a configuration change reanalyzes the unit from `main.jl`, but not the unit
            # that `utils.jl` formed alone, which would take `utils.jl` back
            utils_generation = JETLSCore.get_generation(manager, utils_entry)
            tracker = JETLSCore.ConfigChangeTracker()
            tracker.concretization_timeout_changed = true
            JETLSCore.request_reanalysis_for_tracked_entries!(server, tracker)
            @test JETLSCore.get_generation(manager, utils_entry) == utils_generation
            let (; raw_msg) = readmsg(; read=2)
                @test !any(mentions("factor"), published_diagnostics(raw_msg, utils_uri))
            end
            @test JETLSCore.get_analysis_info(manager, utils_uri).entry == JETLSCore.ScriptAnalysisEntry(main_uri)
        end
    end
end

@testset "a script that another unit takes over while queued is not analyzed alone" begin
    with_analysis_server() do server, dir
        state = server.state
        manager = state.analysis_manager
        main_uri = filepath2uri(joinpath(dir, "main.jl"))
        utils_uri = filepath2uri(joinpath(dir, "utils.jl"))
        JETLSCore.cache_saved_file_info!(state, main_uri, """
            factor() = 2
            include("utils.jl")
            """)
        JETLSCore.cache_saved_file_info!(state, utils_uri, "scaled(x) = factor() * x\n")
        main_entry = JETLSCore.ScriptAnalysisEntry(main_uri)
        utils_entry = JETLSCore.ScriptAnalysisEntry(utils_uri)

        # `utils.jl` is opened before the analysis of `main.jl` caches anything
        for (uri, entry) in ((main_uri, main_entry), (utils_uri, utils_entry))
            JETLSCore.schedule_analysis!(server, uri, entry, #=invalidate=#false;
                debounce=0.0, notify_diagnostics=false)
        end
        main_request = take!(manager.queue)::JETLSCore.AnalysisRequest
        utils_request = take!(manager.queue)::JETLSCore.AnalysisRequest
        @test utils_request.entry == utils_entry

        JETLSCore.resolve_analysis_request(server, main_request)
        @test JETLSCore.get_analysis_info(manager, utils_uri).entry == main_entry
        JETLSCore.resolve_analysis_request(server, utils_request)
        @test JETLSCore.get_analysis_info(manager, utils_uri).entry == main_entry
        @test !haskey(JETLSCore.load(manager.tracked_entries), utils_entry)
        @test !haskey(JETLSCore.load(manager.analyzed_generations), utils_entry)
    end
end

@testset "files that their unit does not include" begin
    pkgname = "TestUnincludedFile"
    pkgcode = "module $pkgname end\n"
    withpackage(pkgname, pkgcode) do pkgpath
        pkg_path = joinpath(pkgpath, "src", "$pkgname.jl")
        orphan_path = joinpath(pkgpath, "src", "orphan.jl")
        orphan_code = "orphan() = undefined_in_orphan()\n"
        write(orphan_path, orphan_code)
        pkg_uri = filepath2uri(pkg_path)
        orphan_uri = filepath2uri(orphan_path)
        is_unincluded_diagnostic(diag) =
            diag.code == JETLSCore.TOPLEVEL_ANALYSIS_SKIPPED_CODE &&
            diag.severity == DiagnosticSeverity.Information &&
            occursin(uri2filename(pkg_uri), diag.message)
        save(uri, text) = DidSaveTextDocumentNotification(;
            params = DidSaveTextDocumentParams(;
                textDocument = TextDocumentIdentifier(; uri), text))
        withserver(; rootUri = filepath2uri(pkgpath)) do (; server, writereadmsg)
            manager = server.state.analysis_manager

            let (; raw_res) = writereadmsg(
                    make_DidOpenTextDocumentNotification(orphan_uri, orphan_code); read=2)
                @test is_unincluded_diagnostic(only(published_diagnostics(raw_res, orphan_uri)))
            end
            @test JETLSCore.get_analysis_info(manager, orphan_uri) ==
                JETLSCore.OutOfScope(JETLSCore.FallbackAnalysisContext, JETLSCore.UnincludedFile(pkg_uri))

            # saving the file does not analyze the package again
            entry = JETLSCore.find_analysis_entry(server.state, pkg_uri)
            generation = JETLSCore.get_generation(manager, entry)
            let (; raw_res) = writereadmsg(save(orphan_uri, orphan_code))
                @test raw_res isa PublishDiagnosticsNotification
                @test raw_res.params.uri == orphan_uri
                @test is_unincluded_diagnostic(only(raw_res.params.diagnostics))
            end
            @test JETLSCore.get_generation(manager, entry) == generation

            writereadmsg(make_DidOpenTextDocumentNotification(pkg_uri, pkgcode); read=0)
            let (; raw_res) = writereadmsg(save(pkg_uri, """
                        module $pkgname
                        include("orphan.jl")
                        end
                        """); read=2)
                diagnostics = published_diagnostics(raw_res, orphan_uri)
                @test any(diag -> occursin("undefined_in_orphan", diag.message), diagnostics)
                @test !any(is_unincluded_diagnostic, diagnostics)
            end

            # the intermediate result clears the diagnostics of the file before the final
            # result reports it again
            let (; raw_res) = writereadmsg(save(pkg_uri, pkgcode); read=3)
                orphan_res = last(filter(raw_res) do res
                    res isa PublishDiagnosticsNotification && res.params.uri == orphan_uri
                end)
                @test is_unincluded_diagnostic(only(orphan_res.params.diagnostics))
            end
            @test JETLSCore.get_analysis_info(manager, orphan_uri) ==
                JETLSCore.OutOfScope(JETLSCore.FallbackAnalysisContext, JETLSCore.UnincludedFile(pkg_uri))
        end
    end
end

# The vendored CI environment loads the analyzed package's Preferences.jl as a module
# separate from the one JETLS itself uses (aviatesk/JETLS.jl#478)
@testset "package using Preferences.jl" begin
    pkgname = "TestPreferencesUsage"
    pkgcode = """
        module $pkgname
        using Preferences
        const ENABLED = @load_preference("enabled", false)
        end
        """
    withpackage(pkgname, pkgcode; pkg_setup = function ()
            Pkg.add("Preferences"; io=devnull)
        end) do pkgpath
        with_analysis_server() do server, _
            pkg_uri, result = analyze_package_source(server, pkgpath, pkgname)
            @test isempty(result.uri2diagnostics[pkg_uri])
        end
    end
end

@testset "package using `pathof` and `pkgdir`" begin
    pkgname = "TestPackagePaths"
    pkgcode = """
        module $pkgname
        const VERSION_STRING = string(pkgversion(@__MODULE__)::VersionNumber)
        srcdir() = pkgdir(@__MODULE__, "src")
        include(joinpath(srcdir(), "other.jl"))
        module Sub
        include(joinpath(dirname(pathof(parentmodule(@__MODULE__))), "sub.jl"))
        end
        end
        """
    withpackage(pkgname, pkgcode; pkg_setup = function () end) do pkgpath
        other_path = joinpath(pkgpath, "src", "other.jl")
        sub_path = joinpath(pkgpath, "src", "sub.jl")
        write(other_path, "const OTHER = 1\n")
        write(sub_path, "const SUB = 1\n")
        with_analysis_server() do server, _
            pkg_uri, result = analyze_package_source(server, pkgpath, pkgname)
            @test isempty(result.uri2diagnostics[pkg_uri])
            @test haskey(result.analyzed_file_infos, filepath2uri(other_path))
            @test haskey(result.analyzed_file_infos, filepath2uri(sub_path))
        end
    end
end

@testset "collect_module_range_infos" begin
    let st0_top = jlparse("""
            x = 1

            module A
            y = 2
            \"\"\"docs\"\"\"
            module B
            end

            end

            baremodule C
            end
            module Undefined
            end
            """)
        world = Base.get_world_counter()
        @test JETLSCore.collect_module_range_infos(st0_top, module_range_target, world) == [
            (1:typemax(Int)) => module_range_target,
            3:9 => module_range_target.A,
            6:7 => module_range_target.A.B,
            11:12 => module_range_target.C]
    end

    # Revise tracks a package entry file as `include`d into the package module itself
    let st0_top = jlparse("""
            module module_range_target
            module A
            end
            end
            """)
        world = Base.get_world_counter()
        @test JETLSCore.collect_module_range_infos(st0_top, module_range_target, world) == [
            (1:typemax(Int)) => module_range_target,
            1:4 => module_range_target,
            2:3 => module_range_target.A]
    end
end

end # module test_full_analysis
