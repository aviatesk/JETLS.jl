module test_testrunner

using Test
using Logging: with_logger
using JETLSCore
using JETLSCore: JL, JS
using JETLSCore.LSP
using JETLSCore.LSP.URIs2

include("jsjl-utils.jl")

function mock_testrunner_result(; n_passed=1, n_failed=0, n_errored=0, n_broken=0, duration=1.0)
    stats = JETLSCore.TestRunner.App.TestRunnerStats(; n_passed, n_failed, n_errored, n_broken, duration)
    return JETLSCore.TestRunnerResult(; filename="test.jl", stats)
end

function store_lsp_config!(server::JETLSCore.Server, config::JETLSCore.JETLSConfig)
    JETLSCore.store!(server.state.config_manager) do old_data::JETLSCore.ConfigManagerData
        new_data = JETLSCore.ConfigManagerData(old_data; lsp_config = config)
        return new_data, nothing
    end
end

function server_with_testrunner_config(; kwargs...)
    server = JETLSCore.Server()
    store_lsp_config!(server, JETLSCore.JETLSConfig(; testrunner = JETLSCore.TestRunnerConfig(; kwargs...)))
    return server
end

function env_with_deps(deps::Pair{String,Base.UUID}...)
    dir = mktempdir()
    write(joinpath(dir, "Manifest.toml"), "")
    write(joinpath(dir, "Project.toml"),
        "[deps]\n" * join("$name = \"$uuid\"\n" for (name, uuid) in deps))
    return dir
end

function update_testsetinfo_result!(
        server::JETLSCore.Server, uri::URI, idx::Int, result::JETLSCore.TestsetResult
    )
    state = server.state
    JETLSCore.store!(state.file_cache) do cache
        fi = cache[uri]
        testsetinfos = fi.testsetinfos
        old_info = testsetinfos[idx]
        new_info = JETLSCore.TestsetInfo(old_info.st0, result)
        new_testsetinfos = copy(testsetinfos)
        new_testsetinfos[idx] = new_info
        new_fi = JETLSCore.FileInfo(fi; testsetinfos=new_testsetinfos)
        Base.PersistentDict(cache, uri => new_fi), new_fi
    end
end

@testset "find_executable_testsets" begin
    let st0 = """
        @testset "foo" begin
            @test 10 > 0
        end

        @testset "bar" begin
            @test sin(0) == 1
            @testset "baz" include("somefile.jl")
        end
        """ |> jlparse
        testsets = JETLSCore.find_executable_testsets(st0)
        @test length(testsets) == 3
        @test JETLSCore.testset_name(testsets[1]) == "\"foo\""
        @test JETLSCore.testset_line(testsets[1]) == 1
        @test JETLSCore.testset_name(testsets[2]) == "\"bar\""
        @test JETLSCore.testset_line(testsets[2]) == 5
        @test JETLSCore.testset_name(testsets[3]) == "\"baz\""
        @test JETLSCore.testset_line(testsets[3]) == 7
        testsetinfo = JETLSCore.TestsetInfo(testsets[1])
        @test JETLSCore.testset_name(testsetinfo) == "\"foo\""
        @test JETLSCore.testset_line(testsetinfo) == 1
    end

    let st0 = """
        @testset "\$foo" begin
            @test 10 > 0
        end
        """ |> jlparse
        testsets = JETLSCore.find_executable_testsets(st0)
        @test length(testsets) == 1
        @test JETLSCore.testset_name(testsets[1]) == "\"\$foo\""
        @test JETLSCore.testset_line(testsets[1]) == 1
    end

    for description in ("\"\"", "\"a\\\"b\"", "\"\"\"foo\"\"\"", "\"\"\"\"\"\"")
        let st0 = jlparse("@testset " * description * " begin end")
            testset = only(JETLSCore.find_executable_testsets(st0))
            @test JETLSCore.testset_name(testset) == description
        end
    end

    let st0 = """
        function test_simple_func()
            @testset "simple" begin
                @test 10 > 0
            end
        end
        test_simple_func()
        """ |> jlparse
        @test isempty(JETLSCore.find_executable_testsets(st0))
    end
end

@testset "summary_testrunner_result" begin
    let result = mock_testrunner_result(; n_passed=10, duration=1.5)
        @test JETLSCore.summary_testrunner_result(result) == "[ Total: 10 | Pass: 10 | Time: 1.5s ]"
    end

    let result = mock_testrunner_result(; n_passed=5, n_failed=2, n_errored=1, n_broken=1, duration=0.123)
        expected = "[ Total: 9 | Pass: 5 | Fail: 2 | Error: 1 | Broken: 1 | Time: 123.0ms ]"
        @test JETLSCore.summary_testrunner_result(result) == expected
    end

    let result = mock_testrunner_result(; n_passed=0, duration=0.0)
        @test JETLSCore.summary_testrunner_result(result) == "[ Total: 0 | Time: 0.0ms ]"
    end

    let result = mock_testrunner_result(; n_passed=100, duration=125.5)
        @test JETLSCore.summary_testrunner_result(result) == "[ Total: 100 | Pass: 100 | Time: 2m 5.5s ]"
    end
end

@testset "testrunner_diagnostic_to_related_information" begin
    RelatedInformation = JETLSCore.TestRunner.App.TestRunnerDiagnosticRelatedInformation
    # stack frames of the methods defined in an unsaved buffer and of those without
    # location information
    relatedInformation = [
        RelatedInformation(joinpath(".", "Untitled-1"), 2, "f()"),
        RelatedInformation(joinpath(".", "none"), 1, "g()")]
    diagnostic = JETLSCore.TestRunnerDiagnostic(
        "Untitled-1", 4, "Error During Test", "Test failed", "", relatedInformation)
    info = only(something(JETLSCore.testrunner_diagnostic_to_related_information(diagnostic)))
    @test info.location.uri == filename2uri("Untitled-1")
    @test info.message == "f()"
end

@testset "testrunner_diagnostic_message" begin
    let diagnostic = JETLSCore.TestRunnerDiagnostic(
            "runtests.jl", 2, "Test Failed at runtests.jl:2\n  Expression: 1 == 2",
            "Test failed", "  Expression: 1 == 2", nothing)
        @test JETLSCore.testrunner_diagnostic_message(diagnostic) ==
            "Test failed\n\n  Expression: 1 == 2"
        @test JETLSCore.testrunner_diagnostic_message(diagnostic; markdown_rendering = true) ==
            "Test failed\n\n```\n  Expression: 1 == 2\n```\n"
    end
    let diagnostic = JETLSCore.TestRunnerDiagnostic(
            "runtests.jl", 2, "Interrupted", "Test interrupted", "", nothing)
        @test JETLSCore.testrunner_diagnostic_message(diagnostic; markdown_rendering = true) ==
            "Test interrupted"
    end
end

@testset "read_testrunner_result" begin
    @static if Sys.iswindows()
        @test_skip "process-backed TestRunner test is Unix-only"
    else
        @testset "large stdin and stdout" begin
            server = JETLSCore.Server()
            stats = JETLSCore.TestRunner.App.TestRunnerStats(;
                n_passed = 1, n_failed = 0, n_errored = 0, n_broken = 0,
                duration = 1.0)
            expected = JETLSCore.TestRunnerResult(;
                filename = "test.jl", stats, logs = repeat("x", 1_200_000))
            source = String(LSP.JSON3.write(expected))
            result = JETLSCore.read_testrunner_result(server, `/bin/cat`, source)
            result = result::JETLSCore.TestRunnerResult
            @test result.filename == expected.filename
            @test result.stats.n_passed == expected.stats.n_passed
            @test result.logs == expected.logs
        end

        @testset "test failure result with exit 1" begin
            server = JETLSCore.Server()
            expected = mock_testrunner_result(; n_passed = 1, n_failed = 1)
            source = String(LSP.JSON3.write(expected))
            cmd = Cmd(["/bin/sh", "-c", "cat; exit 1"])
            result = JETLSCore.read_testrunner_result(server, cmd, source)
            result = result::JETLSCore.TestRunnerResult
            @test result.stats.n_passed == expected.stats.n_passed
            @test result.stats.n_failed == expected.stats.n_failed
        end

        @testset "non-test exit 1 remains a process failure" begin
            server = JETLSCore.Server()
            source = String(LSP.JSON3.write(mock_testrunner_result()))
            cmd = Cmd(["/bin/sh", "-c", "cat; exit 1"])
            logger = Test.TestLogger()
            result = with_logger(logger) do
                JETLSCore.read_testrunner_result(server, cmd, source)
            end
            @test result == "Test execution failed"
            log = only(logger.logs)
            @test log.message == "TestRunner execution failed"
            details = log.kwargs[:details]
            @test details.exitcode == 1
            @test details.termsignal == 0
            @test details.stdout_bytes == ncodeunits(source)
            @test details.reason === :process
            @test isnothing(details.parse_error)
        end

        @testset "process failure logs metadata" begin
            server = JETLSCore.Server()
            cmd = Cmd(["/bin/sh", "-c", "cat; printf 'testrunner failed\\n'; exit 1"])
            logger = Test.TestLogger()
            result = with_logger(logger) do
                JETLSCore.read_testrunner_result(server, cmd, "")
            end
            @test result == "Test execution failed"
            log = only(logger.logs)
            @test log.message == "TestRunner execution failed"
            details = log.kwargs[:details]
            @test details.exitcode == 1
            @test details.termsignal == 0
            @test details.stdout_bytes == 18
            @test details.reason === :process
            @test isnothing(details.parse_error)
        end

        @testset "invalid JSON logs parse error" begin
            server = JETLSCore.Server()
            logger = Test.TestLogger()
            result = with_logger(logger) do
                JETLSCore.read_testrunner_result(server, `/bin/cat`, "not json\n")
            end
            @test result == "Test execution failed"
            log = only(logger.logs)
            @test log.message == "TestRunner execution failed"
            details = log.kwargs[:details]
            @test details.exitcode == 0
            @test details.termsignal == 0
            @test details.stdout_bytes == 9
            @test details.reason === :invalid_output
            @test details.parse_error isa String
        end

        @testset "cancellation terminates the process" begin
            server = JETLSCore.Server()
            cancel_flag = JETLSCore.CancelFlag(false)
            cancellable_token = JETLSCore.CancellableToken("test", cancel_flag)
            cancel_task = @async begin
                sleep(0.2)
                JETLSCore.cancel!(cancel_flag)
            end
            result = JETLSCore.read_testrunner_result(server, `/bin/sleep 30`, ""; cancellable_token)
            wait(cancel_task)
            @test result == "Test execution cancelled by user"
        end
    end
end

@testset "find_testrunner_load_path" begin
    pkgid = Base.PkgId(JETLSCore.TestRunner)
    root = dirname(dirname(@__DIR__))
    @test JETLSCore.find_testrunner_load_path(root, pkgid) == root
    # workspace members resolve to the root project through the shared manifest
    @test JETLSCore.find_testrunner_load_path(@__DIR__, pkgid) == root

    let dir = env_with_deps("TestRunner" => pkgid.uuid)
        @test JETLSCore.find_testrunner_load_path(dir, pkgid) == dir
    end
    # `-m TestRunner` needs the root project to list `TestRunner` as a direct dependency
    let dir = env_with_deps("JETLSCore" => Base.PkgId(JETLSCore).uuid)
        @test JETLSCore.find_testrunner_load_path(dir, pkgid) === nothing
    end
    let dir = env_with_deps("TestRunner" => Base.UUID(0))
        @test JETLSCore.find_testrunner_load_path(dir, pkgid) === nothing
    end
end

@testset "testrunner_launcher" begin
    @test JETLSCore.testrunner_load_path[] isa String

    let launcher = JETLSCore.testrunner_launcher(JETLSCore.Server())::JETLSCore.TestRunnerLauncher
        @test launcher.julia.exec == Base.julia_cmd().exec
        @test isempty(launcher.julia_args)
        @test ("JULIA_LOAD_PATH" => JETLSCore.testrunner_load_path[]) in launcher.env
        @test ("JULIA_PROJECT" => nothing) in launcher.env
    end

    let julia = first(Base.julia_cmd().exec),
        server = server_with_testrunner_config(;
            env = Dict("JULIA_APPS_JULIA_CMD" => julia, "NAME" => "value"),
            julia_args = ["--threads=2"])
        launcher = JETLSCore.testrunner_launcher(server)::JETLSCore.TestRunnerLauncher
        @test launcher.julia.exec == [Sys.which(julia)]
        @test launcher.julia_args == ["--threads=2"]
        @test ("NAME" => "value") in launcher.env
    end

    let server = server_with_testrunner_config(;
            env = Dict("JULIA_APPS_JULIA_CMD" => "/nonexistent/julia"))
        msg = JETLSCore.testrunner_launcher(server)
        @test msg isa String
        @test occursin("/nonexistent/julia", msg)
    end

    let server = server_with_testrunner_config(; env = Dict("JULIAUP_CHANNEL" => "1.12"))
        launcher = withenv("PATH" => Sys.BINDIR) do
            JETLSCore.testrunner_launcher(server)
        end::JETLSCore.TestRunnerLauncher
        @test launcher.julia.exec == [withenv(() -> Sys.which("julia"), "PATH" => Sys.BINDIR)]
        @test ("JULIAUP_CHANNEL" => "1.12") in launcher.env
        mktempdir() do dir
            @test withenv(() -> JETLSCore.testrunner_launcher(server), "PATH" => dir) isa String
        end
    end
end

@testset "testrunner_testset_cmd / testrunner_testcase_cmd" begin
    launcher = JETLSCore.TestRunnerLauncher(`julia`, ["--threads=2"],
        Pair{String,Union{Nothing,String}}["JULIA_LOAD_PATH" => "/jetls", "JULIA_PROJECT" => nothing])
    let cmd = withenv("JULIA_PROJECT" => "/user") do
            JETLSCore.testrunner_testset_cmd(launcher, "/test/runtests.jl", "\"foo\"", 3, "/test", nothing)
        end
        @test cmd.exec == ["julia", "--startup-file=no", "--project=/test", "--threads=2",
            "-m", "TestRunner", "--verbose", "--json", "--read-stdin", "/test/runtests.jl", "foo",
            "--filter-lines=3"]
        @test "JULIA_LOAD_PATH=/jetls" in cmd.env
        @test !any(startswith("JULIA_PROJECT="), cmd.env)
    end
    let cmd = JETLSCore.testrunner_testcase_cmd(launcher, "Untitled-1", 5, nothing, "/root")
        @test cmd.exec == ["julia", "--startup-file=no", "--threads=2",
            "-m", "TestRunner", "--verbose", "--root-path=/root", "--json", "--read-stdin",
            "Untitled-1", "L5"]
    end
end

@testset "run TestRunner" begin
    mktempdir() do dir
        project_file = joinpath(dir, "Project.toml")
        write(project_file, "")
        filepath = joinpath(dir, "runtests.jl")
        source = """
        using Test
        @testset "foo" begin
            @test Base.active_project() == $(repr(project_file))
            @test 1 == 2
        end
        """
        server = JETLSCore.Server()
        launcher = JETLSCore.testrunner_launcher(server)::JETLSCore.TestRunnerLauncher
        cmd = JETLSCore.testrunner_testset_cmd(launcher, filepath, "\"foo\"", 2, project_file, nothing)
        result = JETLSCore.read_testrunner_result(server, cmd, source)::JETLSCore.TestRunnerResult
        @test result.stats.n_passed == 1
        @test result.stats.n_failed == 1
        @test only(result.diagnostics).line == 4
    end
end

@testset "testsetinfo_logs_filename" begin
    let filename = JETLSCore.testsetinfo_logs_filename("simple")
        @test filename == "TestRunner_simple.log"
    end

    let filename = JETLSCore.testsetinfo_logs_filename("macro expansion content")
        @test startswith(filename, "TestRunner_")
        @test endswith(filename, ".log")
        @test !occursin('%', filename)
    end

    let filename = JETLSCore.testsetinfo_logs_filename("a/b ?#%\n")
        @test startswith(filename, "TestRunner_")
        @test endswith(filename, ".log")
        @test filename != "TestRunner_.log"
        @test !any(c -> occursin(c, filename), ('/', '\\', '%', '?', '#', '\n'))
    end

    let filename = JETLSCore.testsetinfo_logs_filename("日本語")
        @test startswith(filename, "TestRunner_")
        @test endswith(filename, ".log")
        @test occursin("日本語", filename)
        @test !occursin('%', filename)
    end

    let filename = JETLSCore.testsetinfo_logs_filename(repeat("a", 100))
        @test startswith(filename, "TestRunner_")
        @test endswith(filename, ".log")
        @test length(filename) <= length("TestRunner_") + 80 + length(".log")
    end
end

@testset "testsetinfo_logs_content" begin
    let uri = URI("file:///runtests.jl"), testset_name = "日本語"
        log_uri = JETLSCore.testsetinfo_logs_content_uri(uri, 1, testset_name)
        @test log_uri == JETLSCore.testsetinfo_logs_content_uri(uri, 1, testset_name)
        @test log_uri != JETLSCore.testsetinfo_logs_content_uri(uri, 2, testset_name)
        @test log_uri.scheme == JETLSCore.TESTRUNNER_LOGS_SCHEME
        @test log_uri.path == "/testrunner/logs"
    end

    let server = JETLSCore.Server(), uri = URI(; scheme=JETLSCore.TESTRUNNER_LOGS_SCHEME, path="/test")
        JETLSCore.update_text_document_content!(server, uri, "old logs")
        @test JETLSCore.get_text_document_content(server.state, uri) == "old logs"
        JETLSCore.mark_text_document_content_opened!(server, uri)
        JETLSCore.update_text_document_content!(server, uri, "new logs")
        @test JETLSCore.get_text_document_content(server.state, uri) == "new logs"
        @test JETLSCore.load(server.state.text_document_content_cache)[uri].opened
        JETLSCore.mark_text_document_content_closed!(server, uri)
        @test !JETLSCore.load(server.state.text_document_content_cache)[uri].opened
        JETLSCore.delete_text_document_content!(server, uri)
        @test JETLSCore.get_text_document_content(server.state, uri) === nothing
    end
end

@testset "testrunner_code_lenses" begin
    let server = JETLSCore.Server()
        test_code = """
        @testset "my_tests" begin
            @test true
        end
        """
        uri = URI("file://runtests.jl")
        fi = JETLSCore.cache_file_info!(server, uri, 1, test_code)
        testsetinfos = fi.testsetinfos
        @test length(testsetinfos) == 1

        code_lenses = JETLSCore.testrunner_code_lenses(uri, fi)

        @test length(code_lenses) == 1
        first_lens = code_lenses[1]
        tsn = JETLSCore.testset_name(testsetinfos[1])
        @test first_lens.command.title == "$(JETLSCore.TESTRUNNER_RUN_TITLE) $tsn"
        @test first_lens.command.command == JETLSCore.COMMAND_TESTRUNNER_RUN_TESTSET
        @test first_lens.command.arguments == [uri, 1, tsn]
        @test first_lens.range isa LSP.Range
    end

    let server = JETLSCore.Server()
        test_code = """
        @testset "my_tests" begin
            @test true
        end

        @testset "other_tests" begin
            @test false
        end
        """
        uri = URI("file://runtests.jl")
        fi = JETLSCore.cache_file_info!(server, uri, 1, test_code)
        testsetinfos = fi.testsetinfos
        @test length(testsetinfos) == 2

        result = mock_testrunner_result(; n_passed=1)
        key = JETLSCore.TestsetDiagnosticsKey(uri, "\"my_tests\"", 1)
        testsetinfos[1] = JETLSCore.TestsetInfo(testsetinfos[1].st0, JETLSCore.TestsetResult(result, key))

        code_lenses = JETLSCore.testrunner_code_lenses(uri, fi)

        @test length(code_lenses) == 4

        rerun_lens = code_lenses[1]
        tsn1 = JETLSCore.testset_name(testsetinfos[1])
        expected_title = "$(JETLSCore.TESTRUNNER_RERUN_TITLE) $tsn1 [ Total: 1 | Pass: 1 | Time: 1.0s ]"
        @test rerun_lens.command.title == expected_title
        @test rerun_lens.command.command == JETLSCore.COMMAND_TESTRUNNER_RUN_TESTSET
        @test rerun_lens.command.arguments == [uri, 1, tsn1]

        logs_lens = code_lenses[2]
        @test logs_lens.command.title == JETLSCore.TESTRUNNER_OPEN_LOGS_TITLE
        @test logs_lens.command.command == JETLSCore.COMMAND_TESTRUNNER_OPEN_LOGS
        @test logs_lens.command.arguments == [uri, 1, tsn1]
        # logs are looked up server-side rather than carried in the command arguments
        @test JETLSCore.get_testsetinfo_logs(server.state, uri, 1) == result.logs
        @test JETLSCore.get_testsetinfo_logs(server.state, uri, 2) === nothing
        @test JETLSCore.get_testsetinfo_logs(server.state, URI("file:///none.jl"), 1) === nothing

        clear_lens = code_lenses[3]
        @test clear_lens.command.title == JETLSCore.TESTRUNNER_CLEAR_RESULT_TITLE
        @test clear_lens.command.command == JETLSCore.COMMAND_TESTRUNNER_CLEAR_RESULT
        @test clear_lens.command.arguments == [uri, 1, tsn1]

        run_lens = code_lenses[4]
        tsn2 = JETLSCore.testset_name(testsetinfos[2])
        @test run_lens.command.title == "$(JETLSCore.TESTRUNNER_RUN_TITLE) $tsn2"
        @test run_lens.command.command == JETLSCore.COMMAND_TESTRUNNER_RUN_TESTSET
        @test run_lens.command.arguments == [uri, 2, tsn2]
    end
end

@testset "testrunner_code_actions" begin
    let server = JETLSCore.Server()
        test_code_with_positions = """
        @testset "first_test" begin
            @test tr│ue
        end

        @testset "second_│test" begin
            @test false
        end│

        # Outside any│ testset
        """
        test_code, positions = JETLSCore.get_text_and_positions(test_code_with_positions)
        @test length(positions) == 4
        uri = URI("file://runtests.jl")
        fi = JETLSCore.cache_file_info!(server, uri, 1, test_code)
        testsetinfos = fi.testsetinfos
        @test length(testsetinfos) == 2

        # Test action at position inside first testset
        first_testset_range = LSP.Range(;
            start = positions[1],
            var"end" = positions[1])

        code_actions = JETLSCore.testrunner_code_actions(uri, fi, first_testset_range)
        @test length(code_actions) == 2  # Now includes both @testset and @test actions
        tsn1 = JETLSCore.testset_name(testsetinfos[1])
        @test code_actions[1].title == "$(JETLSCore.TESTRUNNER_RUN_TITLE) $tsn1"
        @test code_actions[1].command.command == JETLSCore.COMMAND_TESTRUNNER_RUN_TESTSET
        @test code_actions[1].command.arguments == [uri, 1, tsn1]
        # Check @test action
        @test code_actions[2].title == "$(JETLSCore.TESTRUNNER_RUN_TITLE) `@test true`"
        @test code_actions[2].command.command == JETLSCore.COMMAND_TESTRUNNER_RUN_TESTCASE
        @test code_actions[2].command.arguments == [uri, 2, "`@test true`"]

        # Test action at position inside second testset
        second_testset_range = LSP.Range(;
            start = positions[2],
            var"end" = positions[2])

        code_actions = JETLSCore.testrunner_code_actions(uri, fi, second_testset_range)
        @test length(code_actions) == 1
        tsn2 = JETLSCore.testset_name(testsetinfos[2])
        @test code_actions[1].title == "$(JETLSCore.TESTRUNNER_RUN_TITLE) $tsn2"
        @test code_actions[1].command.command == JETLSCore.COMMAND_TESTRUNNER_RUN_TESTSET
        @test code_actions[1].command.arguments == [uri, 2, tsn2]

        # Test action with multi-byte span covering both testsets
        multi_range = LSP.Range(;
            start = positions[1],
            var"end" = positions[2])

        code_actions = JETLSCore.testrunner_code_actions(uri, fi, multi_range)
        @test length(code_actions) == 3  # Two @testset actions and one @test action (true)
        tsn1 = JETLSCore.testset_name(testsetinfos[1])
        tsn2 = JETLSCore.testset_name(testsetinfos[2])
        @test code_actions[1].title == "$(JETLSCore.TESTRUNNER_RUN_TITLE) $tsn1"
        @test code_actions[1].command.command == JETLSCore.COMMAND_TESTRUNNER_RUN_TESTSET
        @test code_actions[1].command.arguments == [uri, 1, tsn1]
        @test code_actions[2].title == "$(JETLSCore.TESTRUNNER_RUN_TITLE) $tsn2"
        @test code_actions[2].command.command == JETLSCore.COMMAND_TESTRUNNER_RUN_TESTSET
        @test code_actions[2].command.arguments == [uri, 2, tsn2]
        @test code_actions[3].title == "$(JETLSCore.TESTRUNNER_RUN_TITLE) `@test true`"
        @test code_actions[3].command.command == JETLSCore.COMMAND_TESTRUNNER_RUN_TESTCASE
        @test code_actions[3].command.arguments == [uri, 2, "`@test true`"]

        # Test action at position right after testset end
        after_end_range = LSP.Range(;
            start = positions[3],
            var"end" = positions[3])

        code_actions = JETLSCore.testrunner_code_actions(uri, fi, after_end_range)
        @test length(code_actions) == 1
        tsn2 = JETLSCore.testset_name(testsetinfos[2])
        @test code_actions[1].title == "$(JETLSCore.TESTRUNNER_RUN_TITLE) $tsn2"
        @test code_actions[1].command.command == JETLSCore.COMMAND_TESTRUNNER_RUN_TESTSET
        @test code_actions[1].command.arguments == [uri, 2, tsn2]

        # Test action at position outside any testset
        no_overlap_range = LSP.Range(;
            start = positions[4],
            var"end" = positions[4])

        code_actions = JETLSCore.testrunner_code_actions(uri, fi, no_overlap_range)
        @test isempty(code_actions)
    end

    let server = JETLSCore.Server()
        test_code_with_positions = """
        @testset "test_wi│th_results" begin
            @test true
        end
        """
        test_code, positions = JETLSCore.get_text_and_positions(test_code_with_positions)
        @test length(positions) == 1

        uri = URI("file://runtests.jl")
        fi = JETLSCore.cache_file_info!(server, uri, 1, test_code)
        testsetinfos = fi.testsetinfos
        @test length(testsetinfos) == 1

        result = mock_testrunner_result(; n_passed=1, duration=0.5)
        key = JETLSCore.TestsetDiagnosticsKey(uri, "\"test_with_results\"", 1)
        testsetinfos[1] = JETLSCore.TestsetInfo(testsetinfos[1].st0, JETLSCore.TestsetResult(result, key))

        testset_range = LSP.Range(;
            start = positions[1],
            var"end" = positions[1])

        code_actions = JETLSCore.testrunner_code_actions(uri, fi, testset_range)
        @test length(code_actions) == 3

        tsn = JETLSCore.testset_name(testsetinfos[1])
        @test code_actions[1].title == "$(JETLSCore.TESTRUNNER_RERUN_TITLE) $tsn [ Total: 1 | Pass: 1 | Time: 500.0ms ]"
        @test code_actions[1].command.command == JETLSCore.COMMAND_TESTRUNNER_RUN_TESTSET
        @test code_actions[1].command.arguments == [uri, 1, tsn]

        @test code_actions[2].title == JETLSCore.TESTRUNNER_OPEN_LOGS_TITLE
        @test code_actions[2].command.command == JETLSCore.COMMAND_TESTRUNNER_OPEN_LOGS
        @test code_actions[2].command.arguments == [uri, 1, tsn]

        @test code_actions[3].title == JETLSCore.TESTRUNNER_CLEAR_RESULT_TITLE
        @test code_actions[3].command.command == JETLSCore.COMMAND_TESTRUNNER_CLEAR_RESULT
        @test code_actions[3].command.arguments == [uri, 1, tsn]
    end

    # Test individual @test macro code actions
    let server = JETLSCore.Server()
        test_code_with_positions = """
        # Single @test outside testset
        @test 1 ==│ 1

        @testset "tests with multiple @test macros" begin
            @test 2 + │2 == 4
        end

        @test_throws DomainError│ sin(Inf)

        # Edge case with complex expression
        @test begin
            x = 5│
            x^2 == 25
        end
        """
        test_code, positions = JETLSCore.get_text_and_positions(test_code_with_positions)
        @test length(positions) == 4

        uri = URI("file://runtests.jl")
        fi = JETLSCore.cache_file_info!(server, uri, 1, test_code)

        # Test action on standalone @test (outside any testset)
        standalone_range = LSP.Range(;
            start = positions[1],
            var"end" = positions[1])
        code_actions = JETLSCore.testrunner_code_actions(uri, fi, standalone_range)
        @test length(code_actions) == 1
        @test code_actions[1].title == "$(JETLSCore.TESTRUNNER_RUN_TITLE) `@test 1 == 1`"
        @test code_actions[1].command.command == JETLSCore.COMMAND_TESTRUNNER_RUN_TESTCASE
        @test code_actions[1].command.arguments == [uri, 2, "`@test 1 == 1`"]

        # Test action on first @test inside testset
        # Now shows both testset and @test actions
        first_test_range = LSP.Range(;
            start = positions[2],
            var"end" = positions[2])
        code_actions = JETLSCore.testrunner_code_actions(uri, fi, first_test_range)
        @test length(code_actions) == 2  # Both testset and test actions
        # First should be testset action
        @test occursin("tests with multiple @test macros", code_actions[1].title)
        @test code_actions[1].command.command == JETLSCore.COMMAND_TESTRUNNER_RUN_TESTSET
        # Second should be @test action
        @test code_actions[2].title == "$(JETLSCore.TESTRUNNER_RUN_TITLE) `@test 2 + 2 == 4`"
        @test code_actions[2].command.command == JETLSCore.COMMAND_TESTRUNNER_RUN_TESTCASE
        @test code_actions[2].command.arguments == [uri, 5, "`@test 2 + 2 == 4`"]

        # Test action on other Test.jl macros
        multiline_range = LSP.Range(;
            start = positions[3],
            var"end" = positions[3])
        code_actions = JETLSCore.testrunner_code_actions(uri, fi, multiline_range)
        @test length(code_actions) == 1
        @test occursin("@test_throws DomainError sin(Inf)", code_actions[1].title)
        @test code_actions[1].command.command == JETLSCore.COMMAND_TESTRUNNER_RUN_TESTCASE

        # Test action on multi-line @test (outside any testset)
        multiline_range = LSP.Range(;
            start = positions[4],
            var"end" = positions[4])
        code_actions = JETLSCore.testrunner_code_actions(uri, fi, multiline_range)
        @test length(code_actions) == 1
        @test occursin("@test begin", code_actions[1].title)
        @test code_actions[1].command.command == JETLSCore.COMMAND_TESTRUNNER_RUN_TESTCASE
    end
end

@testset "testsetinfos preservation" begin
    # Test that results are preserved when testset names match
    let server = JETLSCore.Server()
        test_code = """
        @testset "foo" begin
            @test 10 > 0
        end

        @testset "bar" begin
            @test sin(0) == 1
        end
        """
        uri = URI("file://runtests.jl")
        fi = JETLSCore.cache_file_info!(server, uri, 1, test_code)
        testsetinfos = fi.testsetinfos
        @test length(testsetinfos) == 2

        result1 = mock_testrunner_result(; n_passed=1)
        key1 = JETLSCore.TestsetDiagnosticsKey(uri, "\"foo\"", 1)
        result2 = mock_testrunner_result(; n_passed=0, n_failed=1)
        key2 = JETLSCore.TestsetDiagnosticsKey(uri, "\"bar\"", 2)

        update_testsetinfo_result!(server, uri, 1, JETLSCore.TestsetResult(result1, key1))
        update_testsetinfo_result!(server, uri, 2, JETLSCore.TestsetResult(result2, key2))

        new_test_code = test_code * "\n" # new line inserted at the end
        fi = JETLSCore.cache_file_info!(server, uri, 2, new_test_code)
        testsetinfos = fi.testsetinfos
        @test length(testsetinfos) == 2
        @test isdefined(testsetinfos[1], :result)
        @test isdefined(testsetinfos[2], :result)
        @test testsetinfos[1].result.result === result1
        @test testsetinfos[2].result.result === result2
    end

    # Test that results are preserved when testset content changes but name stays the same
    let server = JETLSCore.Server()
        test_code = """
        @testset "foo" begin
            @test 10 > 0
        end

        @testset "bar" begin
            @test sin(0) == 1
        end
        """
        uri = URI("file://runtests.jl")
        fi = JETLSCore.cache_file_info!(server, uri, 1, test_code)
        testsetinfos = fi.testsetinfos
        @test length(testsetinfos) == 2

        result = mock_testrunner_result(; n_passed=1)
        key = JETLSCore.TestsetDiagnosticsKey(uri, "\"foo\"", 1)
        update_testsetinfo_result!(server, uri, 1, JETLSCore.TestsetResult(result, key))
        val = JETLSCore.testrunner_result_to_diagnostics(result)
        JETLSCore.store!(server.state.extra_diagnostics) do data
            JETLSCore.ExtraDiagnosticsData(data, key=>val), nothing
        end

        new_test_code = """
        @testset "foo" begin
            @test 1 > 0
        end

        @testset "bar" begin
            @test sin(0) == 1
        end
        """ # the testset "foo" has been modified
        fi = JETLSCore.cache_file_info!(server, uri, 2, new_test_code)
        @test haskey(JETLSCore.load(server.state.extra_diagnostics), key)
        testsetinfos = fi.testsetinfos
        @test length(testsetinfos) == 2
        @test isdefined(testsetinfos[1], :result)
        @test !isdefined(testsetinfos[2], :result)
    end

    # Test that diagnostics are cleared when testset is deleted
    let server = JETLSCore.Server()
        test_code = """
        @testset "foo" begin
            @test 10 > 0
        end

        @testset "bar" begin
            @test sin(0) == 1
        end
        """
        uri = URI("file://runtests.jl")
        fi = JETLSCore.cache_file_info!(server, uri, 1, test_code)
        testsetinfos = fi.testsetinfos
        @test length(testsetinfos) == 2

        result = mock_testrunner_result(; n_passed=1)
        key = JETLSCore.TestsetDiagnosticsKey(uri, "\"foo\"", 1)
        update_testsetinfo_result!(server, uri, 1, JETLSCore.TestsetResult(result, key))
        val = JETLSCore.testrunner_result_to_diagnostics(result)
        JETLSCore.store!(server.state.extra_diagnostics) do data
            JETLSCore.ExtraDiagnosticsData(data, key=>val), nothing
        end

        new_test_code = """
        @testset "bar" begin
            @test sin(0) == 1
        end
        """ # the testset "foo" has been deleted
        fi = JETLSCore.cache_file_info!(server, uri, 2, new_test_code)
        @test isempty(JETLSCore.load(server.state.extra_diagnostics).keys)
        testsetinfos = fi.testsetinfos
        @test length(testsetinfos) == 1
        @test !isdefined(testsetinfos[1], :result)
    end

    # Test that diagnostics are cleared when testset is renamed
    let server = JETLSCore.Server()
        test_code = """
        @testset "foo" begin
            @test 10 > 0
        end

        @testset "bar" begin
            @test sin(0) == 1
        end
        """
        uri = URI("file://runtests.jl")
        fi = JETLSCore.cache_file_info!(server, uri, 1, test_code)
        testsetinfos = fi.testsetinfos
        @test length(testsetinfos) == 2

        result = mock_testrunner_result(; n_passed=1)
        key = JETLSCore.TestsetDiagnosticsKey(uri, "\"foo\"", 1)
        update_testsetinfo_result!(server, uri, 1, JETLSCore.TestsetResult(result, key))
        val = JETLSCore.testrunner_result_to_diagnostics(result)
        JETLSCore.store!(server.state.extra_diagnostics) do data
            JETLSCore.ExtraDiagnosticsData(data, key=>val), nothing
        end

        new_test_code = """
        @testset "baz" begin
            @test 10 > 0
        end

        @testset "bar" begin
            @test sin(0) == 1
        end
        """ # the testset "foo" has been renamed to "baz"
        fi = JETLSCore.cache_file_info!(server, uri, 2, new_test_code)
        @test !haskey(JETLSCore.load(server.state.extra_diagnostics), key)
        testsetinfos = fi.testsetinfos
        @test length(testsetinfos) == 2
        @test !isdefined(testsetinfos[1], :result)
        @test !isdefined(testsetinfos[2], :result)
    end

    # Test that results are preserved when new testset is added
    let server = JETLSCore.Server()
        test_code = """
        @testset "foo" begin
            @test 10 > 0
        end
        """
        uri = URI("file://runtests.jl")
        fi = JETLSCore.cache_file_info!(server, uri, 1, test_code)
        testsetinfos = fi.testsetinfos
        @test length(testsetinfos) == 1

        result = mock_testrunner_result(; n_passed=1)
        key = JETLSCore.TestsetDiagnosticsKey(uri, "\"foo\"", 1)
        update_testsetinfo_result!(server, uri, 1, JETLSCore.TestsetResult(result, key))
        val = JETLSCore.testrunner_result_to_diagnostics(result)
        JETLSCore.store!(server.state.extra_diagnostics) do data
            JETLSCore.ExtraDiagnosticsData(data, key=>val), nothing
        end

        new_test_code = """
        @testset "foo" begin
            @test 10 > 0
        end

        @testset "bar" begin
            @test true
        end
        """
        fi = JETLSCore.cache_file_info!(server, uri, 2, new_test_code)
        @test haskey(JETLSCore.load(server.state.extra_diagnostics), key)
        testsetinfos = fi.testsetinfos
        @test length(testsetinfos) == 2
        @test isdefined(testsetinfos[1], :result)
        @test testsetinfos[1].result.result === result
        @test !isdefined(testsetinfos[2], :result)
    end
end

end # module test_testrunner
