module test_testrunner

using Test
using Logging: with_logger
using JETLS
using JETLS: JL, JS
using JETLS.LSP
using JETLS.LSP.URIs2

include("setup.jl")
include("jsjl-utils.jl")

function mock_testrunner_result(; n_passed=1, n_failed=0, n_errored=0, n_broken=0, duration=1.0)
    stats = JETLS.TestRunnerStats(; n_passed, n_failed, n_errored, n_broken, duration)
    return JETLS.TestRunnerResult(; filename="test.jl", stats)
end

function update_testsetinfo_result!(
        server::JETLS.Server, uri::URI, idx::Int, result::JETLS.TestsetResult
    )
    state = server.state
    JETLS.store!(state.file_cache) do cache
        fi = cache[uri]
        testsetinfos = fi.testsetinfos
        old_info = testsetinfos[idx]
        new_info = JETLS.TestsetInfo(old_info.st0, result)
        new_testsetinfos = copy(testsetinfos)
        new_testsetinfos[idx] = new_info
        new_fi = JETLS.FileInfo(fi; testsetinfos=new_testsetinfos)
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
        testsets = JETLS.find_executable_testsets(st0)
        @test length(testsets) == 3
        @test JETLS.testset_name(testsets[1]) == "\"foo\""
        @test JETLS.testset_line(testsets[1]) == 1
        @test JETLS.testset_name(testsets[2]) == "\"bar\""
        @test JETLS.testset_line(testsets[2]) == 5
        @test JETLS.testset_name(testsets[3]) == "\"baz\""
        @test JETLS.testset_line(testsets[3]) == 7
        testsetinfo = JETLS.TestsetInfo(testsets[1])
        @test JETLS.testset_name(testsetinfo) == "\"foo\""
        @test JETLS.testset_line(testsetinfo) == 1
    end

    let st0 = """
        @testset "\$foo" begin
            @test 10 > 0
        end
        """ |> jlparse
        testsets = JETLS.find_executable_testsets(st0)
        @test length(testsets) == 1
        @test JETLS.testset_name(testsets[1]) == "\"\$foo\""
        @test JETLS.testset_line(testsets[1]) == 1
    end

    let st0 = """
        function test_simple_func()
            @testset "simple" begin
                @test 10 > 0
            end
        end
        test_simple_func()
        """ |> jlparse
        @test isempty(JETLS.find_executable_testsets(st0))
    end
end

@testset "summary_testrunner_result" begin
    let result = mock_testrunner_result(; n_passed=10, duration=1.5)
        @test JETLS.summary_testrunner_result(result) == "[ Total: 10 | Pass: 10 | Time: 1.5s ]"
    end

    let result = mock_testrunner_result(; n_passed=5, n_failed=2, n_errored=1, n_broken=1, duration=0.123)
        expected = "[ Total: 9 | Pass: 5 | Fail: 2 | Error: 1 | Broken: 1 | Time: 123.0ms ]"
        @test JETLS.summary_testrunner_result(result) == expected
    end

    let result = mock_testrunner_result(; n_passed=0, duration=0.0)
        @test JETLS.summary_testrunner_result(result) == "[ Total: 0 | Time: 0.0ms ]"
    end

    let result = mock_testrunner_result(; n_passed=100, duration=125.5)
        @test JETLS.summary_testrunner_result(result) == "[ Total: 100 | Pass: 100 | Time: 2m 5.5s ]"
    end
end

@testset "read_testrunner_result" begin
    @static if Sys.iswindows()
        @test_skip "process-backed TestRunner test is Unix-only"
    else
        @testset "large stdin and stdout" begin
            server = JETLS.Server()
            stats = JETLS.TestRunnerStats(;
                n_passed = 1, n_failed = 0, n_errored = 0, n_broken = 0,
                duration = 1.0)
            expected = JETLS.TestRunnerResult(;
                filename = "test.jl", stats, logs = repeat("x", 1_200_000))
            source = String(LSP.JSON3.write(expected))
            result = JETLS.read_testrunner_result(server, `/bin/cat`, source)
            result = result::JETLS.TestRunnerResult
            @test result.filename == expected.filename
            @test result.stats.n_passed == expected.stats.n_passed
            @test result.logs == expected.logs
        end

        @testset "test failure result with exit 1" begin
            server = JETLS.Server()
            expected = mock_testrunner_result(; n_passed = 1, n_failed = 1)
            source = String(LSP.JSON3.write(expected))
            cmd = Cmd(["/bin/sh", "-c", "cat; exit 1"])
            result = JETLS.read_testrunner_result(server, cmd, source)
            result = result::JETLS.TestRunnerResult
            @test result.stats.n_passed == expected.stats.n_passed
            @test result.stats.n_failed == expected.stats.n_failed
        end

        @testset "non-test exit 1 remains a process failure" begin
            server = JETLS.Server()
            source = String(LSP.JSON3.write(mock_testrunner_result()))
            cmd = Cmd(["/bin/sh", "-c", "cat; exit 1"])
            logger = Test.TestLogger()
            result = with_logger(logger) do
                JETLS.read_testrunner_result(server, cmd, source)
            end
            @test result isa TestRunnerRunResult
            @test result.status == TestRunnerRunStatus.Errored
            @test result.message == "Test execution failed"
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
            server = JETLS.Server()
            cmd = Cmd(["/bin/sh", "-c", "cat; printf 'testrunner failed\\n'; exit 1"])
            logger = Test.TestLogger()
            result = with_logger(logger) do
                JETLS.read_testrunner_result(server, cmd, "")
            end
            @test result isa TestRunnerRunResult
            @test result.status == TestRunnerRunStatus.Errored
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
            server = JETLS.Server()
            logger = Test.TestLogger()
            result = with_logger(logger) do
                JETLS.read_testrunner_result(server, `/bin/cat`, "not json\n")
            end
            @test result isa TestRunnerRunResult
            @test result.status == TestRunnerRunStatus.Errored
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
            server = JETLS.Server()
            cancel_flag = JETLS.CancelFlag(false)
            cancellable_token = JETLS.CancellableToken("test", cancel_flag)
            cancel_task = @async begin
                sleep(0.2)
                JETLS.cancel!(cancel_flag)
            end
            result = JETLS.read_testrunner_result(server, `/bin/sleep 30`, ""; cancellable_token)
            wait(cancel_task)
            @test result isa TestRunnerRunResult
            @test result.status == TestRunnerRunStatus.Cancelled
        end
    end
end

@testset "testsetinfo_logs_filename" begin
    let filename = JETLS.testsetinfo_logs_filename("simple")
        @test filename == "TestRunner_simple.log"
    end

    let filename = JETLS.testsetinfo_logs_filename("macro expansion content")
        @test startswith(filename, "TestRunner_")
        @test endswith(filename, ".log")
        @test !occursin('%', filename)
    end

    let filename = JETLS.testsetinfo_logs_filename("a/b ?#%\n")
        @test startswith(filename, "TestRunner_")
        @test endswith(filename, ".log")
        @test filename != "TestRunner_.log"
        @test !any(c -> occursin(c, filename), ('/', '\\', '%', '?', '#', '\n'))
    end

    let filename = JETLS.testsetinfo_logs_filename("日本語")
        @test startswith(filename, "TestRunner_")
        @test endswith(filename, ".log")
        @test occursin("日本語", filename)
        @test !occursin('%', filename)
    end

    let filename = JETLS.testsetinfo_logs_filename(repeat("a", 100))
        @test startswith(filename, "TestRunner_")
        @test endswith(filename, ".log")
        @test length(filename) <= length("TestRunner_") + 80 + length(".log")
    end
end

@testset "testsetinfo_logs_content" begin
    let uri = URI("file:///runtests.jl"), testset_name = "日本語"
        log_uri = JETLS.testsetinfo_logs_content_uri(uri, 1, testset_name)
        @test log_uri == JETLS.testsetinfo_logs_content_uri(uri, 1, testset_name)
        @test log_uri != JETLS.testsetinfo_logs_content_uri(uri, 2, testset_name)
        @test log_uri.scheme == JETLS.TESTRUNNER_LOGS_SCHEME
        @test log_uri.path == "/testrunner/logs"
    end

    let server = JETLS.Server(), uri = URI(; scheme=JETLS.TESTRUNNER_LOGS_SCHEME, path="/test")
        JETLS.update_text_document_content!(server, uri, "old logs")
        @test JETLS.get_text_document_content(server.state, uri) == "old logs"
        JETLS.mark_text_document_content_opened!(server, uri)
        JETLS.update_text_document_content!(server, uri, "new logs")
        @test JETLS.get_text_document_content(server.state, uri) == "new logs"
        @test JETLS.load(server.state.text_document_content_cache)[uri].opened
        JETLS.mark_text_document_content_closed!(server, uri)
        @test !JETLS.load(server.state.text_document_content_cache)[uri].opened
        JETLS.delete_text_document_content!(server, uri)
        @test JETLS.get_text_document_content(server.state, uri) === nothing
    end
end

@testset "testrunner_code_lenses" begin
    let server = JETLS.Server()
        test_code = """
        @testset "my_tests" begin
            @test true
        end
        """
        uri = URI("file://runtests.jl")
        fi = JETLS.cache_file_info!(server, uri, 1, test_code)
        testsetinfos = fi.testsetinfos
        @test length(testsetinfos) == 1

        code_lenses = JETLS.testrunner_code_lenses(uri, fi)

        @test length(code_lenses) == 1
        first_lens = code_lenses[1]
        tsn = JETLS.testset_name(testsetinfos[1])
        @test first_lens.command.title == "$(JETLS.TESTRUNNER_RUN_TITLE) $tsn"
        @test first_lens.command.command == JETLS.COMMAND_TESTRUNNER_RUN_TESTSET
        @test first_lens.command.arguments == [uri, 1, tsn]
        @test first_lens.range isa LSP.Range
    end

    let server = JETLS.Server()
        test_code = """
        @testset "my_tests" begin
            @test true
        end

        @testset "other_tests" begin
            @test false
        end
        """
        uri = URI("file://runtests.jl")
        fi = JETLS.cache_file_info!(server, uri, 1, test_code)
        testsetinfos = fi.testsetinfos
        @test length(testsetinfos) == 2

        result = mock_testrunner_result(; n_passed=1)
        key = JETLS.TestsetDiagnosticsKey(uri, "\"my_tests\"", 1)
        testsetinfos[1] = JETLS.TestsetInfo(testsetinfos[1].st0, JETLS.TestsetResult(result, key))

        code_lenses = JETLS.testrunner_code_lenses(uri, fi)

        @test length(code_lenses) == 4

        rerun_lens = code_lenses[1]
        tsn1 = JETLS.testset_name(testsetinfos[1])
        expected_title = "$(JETLS.TESTRUNNER_RERUN_TITLE) $tsn1 [ Total: 1 | Pass: 1 | Time: 1.0s ]"
        @test rerun_lens.command.title == expected_title
        @test rerun_lens.command.command == JETLS.COMMAND_TESTRUNNER_RUN_TESTSET
        @test rerun_lens.command.arguments == [uri, 1, tsn1]

        logs_lens = code_lenses[2]
        @test logs_lens.command.title == JETLS.TESTRUNNER_OPEN_LOGS_TITLE
        @test logs_lens.command.command == JETLS.COMMAND_TESTRUNNER_OPEN_LOGS
        @test logs_lens.command.arguments == [uri, 1, tsn1]
        # logs are looked up server-side rather than carried in the command arguments
        @test JETLS.get_testsetinfo_logs(server.state, uri, 1) == result.logs
        @test JETLS.get_testsetinfo_logs(server.state, uri, 2) === nothing
        @test JETLS.get_testsetinfo_logs(server.state, URI("file:///none.jl"), 1) === nothing

        clear_lens = code_lenses[3]
        @test clear_lens.command.title == JETLS.TESTRUNNER_CLEAR_RESULT_TITLE
        @test clear_lens.command.command == JETLS.COMMAND_TESTRUNNER_CLEAR_RESULT
        @test clear_lens.command.arguments == [uri, 1, tsn1]

        run_lens = code_lenses[4]
        tsn2 = JETLS.testset_name(testsetinfos[2])
        @test run_lens.command.title == "$(JETLS.TESTRUNNER_RUN_TITLE) $tsn2"
        @test run_lens.command.command == JETLS.COMMAND_TESTRUNNER_RUN_TESTSET
        @test run_lens.command.arguments == [uri, 2, tsn2]
    end
end

@testset "testrunner_code_actions" begin
    let server = JETLS.Server()
        test_code_with_positions = """
        @testset "first_test" begin
            @test tr│ue
        end

        @testset "second_│test" begin
            @test false
        end│

        # Outside any│ testset
        """
        test_code, positions = JETLS.get_text_and_positions(test_code_with_positions)
        @test length(positions) == 4
        uri = URI("file://runtests.jl")
        fi = JETLS.cache_file_info!(server, uri, 1, test_code)
        testsetinfos = fi.testsetinfos
        @test length(testsetinfos) == 2

        # Test action at position inside first testset
        first_testset_range = LSP.Range(;
            start = positions[1],
            var"end" = positions[1])

        code_actions = JETLS.testrunner_code_actions(uri, fi, first_testset_range)
        @test length(code_actions) == 2  # Now includes both @testset and @test actions
        tsn1 = JETLS.testset_name(testsetinfos[1])
        @test code_actions[1].title == "$(JETLS.TESTRUNNER_RUN_TITLE) $tsn1"
        @test code_actions[1].command.command == JETLS.COMMAND_TESTRUNNER_RUN_TESTSET
        @test code_actions[1].command.arguments == [uri, 1, tsn1]
        # Check @test action
        @test code_actions[2].title == "$(JETLS.TESTRUNNER_RUN_TITLE) `@test true`"
        @test code_actions[2].command.command == JETLS.COMMAND_TESTRUNNER_RUN_TESTCASE
        @test code_actions[2].command.arguments == [uri, 2, "`@test true`"]

        # Test action at position inside second testset
        second_testset_range = LSP.Range(;
            start = positions[2],
            var"end" = positions[2])

        code_actions = JETLS.testrunner_code_actions(uri, fi, second_testset_range)
        @test length(code_actions) == 1
        tsn2 = JETLS.testset_name(testsetinfos[2])
        @test code_actions[1].title == "$(JETLS.TESTRUNNER_RUN_TITLE) $tsn2"
        @test code_actions[1].command.command == JETLS.COMMAND_TESTRUNNER_RUN_TESTSET
        @test code_actions[1].command.arguments == [uri, 2, tsn2]

        # Test action with multi-byte span covering both testsets
        multi_range = LSP.Range(;
            start = positions[1],
            var"end" = positions[2])

        code_actions = JETLS.testrunner_code_actions(uri, fi, multi_range)
        @test length(code_actions) == 3  # Two @testset actions and one @test action (true)
        tsn1 = JETLS.testset_name(testsetinfos[1])
        tsn2 = JETLS.testset_name(testsetinfos[2])
        @test code_actions[1].title == "$(JETLS.TESTRUNNER_RUN_TITLE) $tsn1"
        @test code_actions[1].command.command == JETLS.COMMAND_TESTRUNNER_RUN_TESTSET
        @test code_actions[1].command.arguments == [uri, 1, tsn1]
        @test code_actions[2].title == "$(JETLS.TESTRUNNER_RUN_TITLE) $tsn2"
        @test code_actions[2].command.command == JETLS.COMMAND_TESTRUNNER_RUN_TESTSET
        @test code_actions[2].command.arguments == [uri, 2, tsn2]
        @test code_actions[3].title == "$(JETLS.TESTRUNNER_RUN_TITLE) `@test true`"
        @test code_actions[3].command.command == JETLS.COMMAND_TESTRUNNER_RUN_TESTCASE
        @test code_actions[3].command.arguments == [uri, 2, "`@test true`"]

        # Test action at position right after testset end
        after_end_range = LSP.Range(;
            start = positions[3],
            var"end" = positions[3])

        code_actions = JETLS.testrunner_code_actions(uri, fi, after_end_range)
        @test length(code_actions) == 1
        tsn2 = JETLS.testset_name(testsetinfos[2])
        @test code_actions[1].title == "$(JETLS.TESTRUNNER_RUN_TITLE) $tsn2"
        @test code_actions[1].command.command == JETLS.COMMAND_TESTRUNNER_RUN_TESTSET
        @test code_actions[1].command.arguments == [uri, 2, tsn2]

        # Test action at position outside any testset
        no_overlap_range = LSP.Range(;
            start = positions[4],
            var"end" = positions[4])

        code_actions = JETLS.testrunner_code_actions(uri, fi, no_overlap_range)
        @test isempty(code_actions)
    end

    let server = JETLS.Server()
        test_code_with_positions = """
        @testset "test_wi│th_results" begin
            @test true
        end
        """
        test_code, positions = JETLS.get_text_and_positions(test_code_with_positions)
        @test length(positions) == 1

        uri = URI("file://runtests.jl")
        fi = JETLS.cache_file_info!(server, uri, 1, test_code)
        testsetinfos = fi.testsetinfos
        @test length(testsetinfos) == 1

        result = mock_testrunner_result(; n_passed=1, duration=0.5)
        key = JETLS.TestsetDiagnosticsKey(uri, "\"test_with_results\"", 1)
        testsetinfos[1] = JETLS.TestsetInfo(testsetinfos[1].st0, JETLS.TestsetResult(result, key))

        testset_range = LSP.Range(;
            start = positions[1],
            var"end" = positions[1])

        code_actions = JETLS.testrunner_code_actions(uri, fi, testset_range)
        @test length(code_actions) == 3

        tsn = JETLS.testset_name(testsetinfos[1])
        @test code_actions[1].title == "$(JETLS.TESTRUNNER_RERUN_TITLE) $tsn [ Total: 1 | Pass: 1 | Time: 500.0ms ]"
        @test code_actions[1].command.command == JETLS.COMMAND_TESTRUNNER_RUN_TESTSET
        @test code_actions[1].command.arguments == [uri, 1, tsn]

        @test code_actions[2].title == JETLS.TESTRUNNER_OPEN_LOGS_TITLE
        @test code_actions[2].command.command == JETLS.COMMAND_TESTRUNNER_OPEN_LOGS
        @test code_actions[2].command.arguments == [uri, 1, tsn]

        @test code_actions[3].title == JETLS.TESTRUNNER_CLEAR_RESULT_TITLE
        @test code_actions[3].command.command == JETLS.COMMAND_TESTRUNNER_CLEAR_RESULT
        @test code_actions[3].command.arguments == [uri, 1, tsn]
    end

    # Test individual @test macro code actions
    let server = JETLS.Server()
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
        test_code, positions = JETLS.get_text_and_positions(test_code_with_positions)
        @test length(positions) == 4

        uri = URI("file://runtests.jl")
        fi = JETLS.cache_file_info!(server, uri, 1, test_code)

        # Test action on standalone @test (outside any testset)
        standalone_range = LSP.Range(;
            start = positions[1],
            var"end" = positions[1])
        code_actions = JETLS.testrunner_code_actions(uri, fi, standalone_range)
        @test length(code_actions) == 1
        @test code_actions[1].title == "$(JETLS.TESTRUNNER_RUN_TITLE) `@test 1 == 1`"
        @test code_actions[1].command.command == JETLS.COMMAND_TESTRUNNER_RUN_TESTCASE
        @test code_actions[1].command.arguments == [uri, 2, "`@test 1 == 1`"]

        # Test action on first @test inside testset
        # Now shows both testset and @test actions
        first_test_range = LSP.Range(;
            start = positions[2],
            var"end" = positions[2])
        code_actions = JETLS.testrunner_code_actions(uri, fi, first_test_range)
        @test length(code_actions) == 2  # Both testset and test actions
        # First should be testset action
        @test occursin("tests with multiple @test macros", code_actions[1].title)
        @test code_actions[1].command.command == JETLS.COMMAND_TESTRUNNER_RUN_TESTSET
        # Second should be @test action
        @test code_actions[2].title == "$(JETLS.TESTRUNNER_RUN_TITLE) `@test 2 + 2 == 4`"
        @test code_actions[2].command.command == JETLS.COMMAND_TESTRUNNER_RUN_TESTCASE
        @test code_actions[2].command.arguments == [uri, 5, "`@test 2 + 2 == 4`"]

        # Test action on other Test.jl macros
        multiline_range = LSP.Range(;
            start = positions[3],
            var"end" = positions[3])
        code_actions = JETLS.testrunner_code_actions(uri, fi, multiline_range)
        @test length(code_actions) == 1
        @test occursin("@test_throws DomainError sin(Inf)", code_actions[1].title)
        @test code_actions[1].command.command == JETLS.COMMAND_TESTRUNNER_RUN_TESTCASE

        # Test action on multi-line @test (outside any testset)
        multiline_range = LSP.Range(;
            start = positions[4],
            var"end" = positions[4])
        code_actions = JETLS.testrunner_code_actions(uri, fi, multiline_range)
        @test length(code_actions) == 1
        @test occursin("@test begin", code_actions[1].title)
        @test code_actions[1].command.command == JETLS.COMMAND_TESTRUNNER_RUN_TESTCASE
    end
end

@testset "testsetinfos preservation" begin
    # Test that results are preserved when testset names match
    let server = JETLS.Server()
        test_code = """
        @testset "foo" begin
            @test 10 > 0
        end

        @testset "bar" begin
            @test sin(0) == 1
        end
        """
        uri = URI("file://runtests.jl")
        fi = JETLS.cache_file_info!(server, uri, 1, test_code)
        testsetinfos = fi.testsetinfos
        @test length(testsetinfos) == 2

        result1 = mock_testrunner_result(; n_passed=1)
        key1 = JETLS.TestsetDiagnosticsKey(uri, "\"foo\"", 1)
        result2 = mock_testrunner_result(; n_passed=0, n_failed=1)
        key2 = JETLS.TestsetDiagnosticsKey(uri, "\"bar\"", 2)

        update_testsetinfo_result!(server, uri, 1, JETLS.TestsetResult(result1, key1))
        update_testsetinfo_result!(server, uri, 2, JETLS.TestsetResult(result2, key2))

        new_test_code = test_code * "\n" # new line inserted at the end
        fi = JETLS.cache_file_info!(server, uri, 2, new_test_code)
        testsetinfos = fi.testsetinfos
        @test length(testsetinfos) == 2
        @test isdefined(testsetinfos[1], :result)
        @test isdefined(testsetinfos[2], :result)
        @test testsetinfos[1].result.result === result1
        @test testsetinfos[2].result.result === result2
    end

    # Test that results are preserved when testset content changes but name stays the same
    let server = JETLS.Server()
        test_code = """
        @testset "foo" begin
            @test 10 > 0
        end

        @testset "bar" begin
            @test sin(0) == 1
        end
        """
        uri = URI("file://runtests.jl")
        fi = JETLS.cache_file_info!(server, uri, 1, test_code)
        testsetinfos = fi.testsetinfos
        @test length(testsetinfos) == 2

        result = mock_testrunner_result(; n_passed=1)
        key = JETLS.TestsetDiagnosticsKey(uri, "\"foo\"", 1)
        update_testsetinfo_result!(server, uri, 1, JETLS.TestsetResult(result, key))
        val = JETLS.testrunner_result_to_diagnostics(result)
        JETLS.store!(server.state.extra_diagnostics) do data
            JETLS.ExtraDiagnosticsData(data, key=>val), nothing
        end

        new_test_code = """
        @testset "foo" begin
            @test 1 > 0
        end

        @testset "bar" begin
            @test sin(0) == 1
        end
        """ # the testset "foo" has been modified
        fi = JETLS.cache_file_info!(server, uri, 2, new_test_code)
        @test haskey(JETLS.load(server.state.extra_diagnostics), key)
        testsetinfos = fi.testsetinfos
        @test length(testsetinfos) == 2
        @test isdefined(testsetinfos[1], :result)
        @test !isdefined(testsetinfos[2], :result)
    end

    # Test that diagnostics are cleared when testset is deleted
    let server = JETLS.Server()
        test_code = """
        @testset "foo" begin
            @test 10 > 0
        end

        @testset "bar" begin
            @test sin(0) == 1
        end
        """
        uri = URI("file://runtests.jl")
        fi = JETLS.cache_file_info!(server, uri, 1, test_code)
        testsetinfos = fi.testsetinfos
        @test length(testsetinfos) == 2

        result = mock_testrunner_result(; n_passed=1)
        key = JETLS.TestsetDiagnosticsKey(uri, "\"foo\"", 1)
        update_testsetinfo_result!(server, uri, 1, JETLS.TestsetResult(result, key))
        val = JETLS.testrunner_result_to_diagnostics(result)
        JETLS.store!(server.state.extra_diagnostics) do data
            JETLS.ExtraDiagnosticsData(data, key=>val), nothing
        end

        new_test_code = """
        @testset "bar" begin
            @test sin(0) == 1
        end
        """ # the testset "foo" has been deleted
        fi = JETLS.cache_file_info!(server, uri, 2, new_test_code)
        @test isempty(JETLS.load(server.state.extra_diagnostics).keys)
        testsetinfos = fi.testsetinfos
        @test length(testsetinfos) == 1
        @test !isdefined(testsetinfos[1], :result)
    end

    # Test that diagnostics are cleared when testset is renamed
    let server = JETLS.Server()
        test_code = """
        @testset "foo" begin
            @test 10 > 0
        end

        @testset "bar" begin
            @test sin(0) == 1
        end
        """
        uri = URI("file://runtests.jl")
        fi = JETLS.cache_file_info!(server, uri, 1, test_code)
        testsetinfos = fi.testsetinfos
        @test length(testsetinfos) == 2

        result = mock_testrunner_result(; n_passed=1)
        key = JETLS.TestsetDiagnosticsKey(uri, "\"foo\"", 1)
        update_testsetinfo_result!(server, uri, 1, JETLS.TestsetResult(result, key))
        val = JETLS.testrunner_result_to_diagnostics(result)
        JETLS.store!(server.state.extra_diagnostics) do data
            JETLS.ExtraDiagnosticsData(data, key=>val), nothing
        end

        new_test_code = """
        @testset "baz" begin
            @test 10 > 0
        end

        @testset "bar" begin
            @test sin(0) == 1
        end
        """ # the testset "foo" has been renamed to "baz"
        fi = JETLS.cache_file_info!(server, uri, 2, new_test_code)
        @test !haskey(JETLS.load(server.state.extra_diagnostics), key)
        testsetinfos = fi.testsetinfos
        @test length(testsetinfos) == 2
        @test !isdefined(testsetinfos[1], :result)
        @test !isdefined(testsetinfos[2], :result)
    end

    # Test that results are preserved when new testset is added
    let server = JETLS.Server()
        test_code = """
        @testset "foo" begin
            @test 10 > 0
        end
        """
        uri = URI("file://runtests.jl")
        fi = JETLS.cache_file_info!(server, uri, 1, test_code)
        testsetinfos = fi.testsetinfos
        @test length(testsetinfos) == 1

        result = mock_testrunner_result(; n_passed=1)
        key = JETLS.TestsetDiagnosticsKey(uri, "\"foo\"", 1)
        update_testsetinfo_result!(server, uri, 1, JETLS.TestsetResult(result, key))
        val = JETLS.testrunner_result_to_diagnostics(result)
        JETLS.store!(server.state.extra_diagnostics) do data
            JETLS.ExtraDiagnosticsData(data, key=>val), nothing
        end

        new_test_code = """
        @testset "foo" begin
            @test 10 > 0
        end

        @testset "bar" begin
            @test true
        end
        """
        fi = JETLS.cache_file_info!(server, uri, 2, new_test_code)
        @test haskey(JETLS.load(server.state.extra_diagnostics), key)
        testsetinfos = fi.testsetinfos
        @test length(testsetinfos) == 2
        @test isdefined(testsetinfos[1], :result)
        @test testsetinfos[1].result.result === result
        @test !isdefined(testsetinfos[2], :result)
    end
end

@testset "testset_items" begin
    let server = JETLS.Server()
        test_code = """
        @testset "outer" begin
            @testset "inner" begin
                @test true
            end
        end

        @testset "other" begin
            @test true
        end
        """
        uri = URI("file:///testset_items.jl")
        fi = JETLS.cache_file_info!(server, uri, 1, test_code)
        items = JETLS.testset_items(fi)
        @test [item.index for item in items] == [1, 2, 3]
        @test [item.name for item in items] == ["\"outer\"", "\"inner\"", "\"other\""]
        @test [item.range.start.line for item in items] == [0, 1, 6]
        @test [item.range.var"end".line for item in items] == [4, 3, 8]
    end
end

@testset "testrunner_run_completed" begin
    let filename = joinpath(@__DIR__, "testfile.jl")
        stats = JETLS.TestRunnerStats(; n_passed = 2, n_failed = 1, duration = 1.5)
        diagnostics = [JETLS.TestRunnerDiagnostic(filename, 3, "Test Failed", nothing)]
        result = JETLS.TestRunnerResult(; filename, stats, logs = "logs", diagnostics)
        run_result = JETLS.testrunner_run_completed(result)
        @test run_result.status == TestRunnerRunStatus.Completed
        @test run_result.message == JETLS.summary_testrunner_result(result)
        @test run_result.stats.passed == 2
        @test run_result.stats.failed == 1
        @test run_result.stats.errored == 0
        @test run_result.stats.duration == 1.5
        @test run_result.logs == "logs"
        failure = only(run_result.failures)
        @test failure.location.uri == filepath2uri(filename)
        @test failure.location.range.start.line == 2
        @test failure.message == "Test Failed"
    end
end

const TESTRUNNER_COMMAND_TEST_CODE = """
using Test
@testset "foo" begin
    @test true
end
"""

# A stand-in for the `testrunner` executable: it ignores its arguments, consumes the
# source piped via stdin, and then runs `body`.
function fake_testrunner(dir::AbstractString, body::AbstractString)
    path = joinpath(dir, "testrunner")
    write(path, "#!/bin/sh\ncat > /dev/null\n" * body)
    chmod(path, 0o755)
    return path
end

function fake_testrunner_output()
    stats = JETLS.TestRunnerStats(; n_passed = 1, duration = 0.1)
    result = JETLS.TestRunnerResult(; filename = "runtests.jl", stats, logs = "fake logs")
    return "cat <<'EOF'\n" * String(LSP.JSON3.write(result)) * "\nEOF\n"
end

function with_fake_testrunner(
        f, script_body::AbstractString;
        capabilities::ClientCapabilities = ClientCapabilities()
    )
    mktempdir() do dir
        executable = fake_testrunner(dir, script_body)
        settings = Dict{String,Any}(
            "testrunner" => Dict{String,Any}("executable" => executable))
        uri = filepath2uri(joinpath(dir, "runtests.jl"))
        withserver(; capabilities, settings) do server_ctx
            JETLS.cache_file_info!(server_ctx.server, uri, 1, TESTRUNNER_COMMAND_TEST_CODE)
            f(server_ctx, uri)
        end
    end
end

function run_testset_request(
        id::Int, uri::URI; workDoneToken::Union{Nothing,String} = nothing
    )
    return RunTestsetRequest(;
        id,
        params = RunTestsetParams(;
            textDocument = TextDocumentIdentifier(; uri),
            index = 1,
            name = "\"foo\"",
            workDoneToken))
end

function run_testset_command(id::Int, uri::URI)
    return ExecuteCommandRequest(;
        id,
        params = ExecuteCommandParams(;
            command = JETLS.COMMAND_TESTRUNNER_RUN_TESTSET,
            arguments = Any[string(uri), 1, "\"foo\""]))
end

function collect_messages_until(pred, readmsg)
    messages = Any[]
    for _ in 1:50
        msg = readmsg(; check = false).raw_msg
        push!(messages, msg)
        pred(msg) && return messages
    end
    error("Gave up waiting for a matching server message")
end

read_until_response(readmsg, ::Type{T}, id::Int) where T =
    collect_messages_until(msg -> msg isa T && msg.id == id, readmsg)

is_progress_value(msg, token, T) =
    msg isa ProgressNotification && msg.params.token == token && msg.params.value isa T

@static if Sys.iswindows()
    @testset "TestRunner commands" begin
        @test_skip "fake `testrunner` executable is Unix-only"
    end
else
    @testset "jetls/testsets request" begin
        with_fake_testrunner(fake_testrunner_output()) do (; initialize_response, writereadmsg, id_counter), uri
            @test initialize_response.result.capabilities.experimental["testsetsProvider"] === true
            (; raw_res) = writereadmsg(TestsetsRequest(;
                id = id_counter[] += 1,
                params = TestsetsParams(; textDocument = TextDocumentIdentifier(; uri))))
            @test raw_res isa TestsetsResponse
            item = only(raw_res.result)
            @test item.index == 1
            @test item.name == "\"foo\""
            @test item.range.start.line == 1
        end
    end

    @testset "jetls/runTestset request" begin
        with_fake_testrunner(fake_testrunner_output()) do (; writemsg, readmsg, id_counter), uri
            id = id_counter[] += 1
            writemsg(run_testset_request(id, uri; workDoneToken = "client-token"); check = false)
            messages = read_until_response(readmsg, RunTestsetResponse, id)
            result = last(messages).result
            @test result isa TestRunnerRunResult
            @test result.status == TestRunnerRunStatus.Completed
            @test result.stats.passed == 1
            @test result.logs == "fake logs"
            @test any(msg -> is_progress_value(msg, "client-token", WorkDoneProgressBegin), messages)
            @test any(msg -> is_progress_value(msg, "client-token", WorkDoneProgressEnd), messages)
            @test !any(msg -> msg isa ShowMessageRequest, messages)
        end

        with_fake_testrunner(fake_testrunner_output()) do (; writemsg, readmsg, id_counter), uri
            id = id_counter[] += 1
            writemsg(run_testset_request(id, uri); check = false)
            messages = read_until_response(readmsg, RunTestsetResponse, id)
            result = last(messages).result
            @test result isa TestRunnerRunResult
            @test result.status == TestRunnerRunStatus.Completed
            @test !any(msg -> msg isa ProgressNotification, messages)
            @test !any(msg -> msg isa ShowMessageRequest, messages)
        end
    end

    @testset "run@testset command" begin
        with_fake_testrunner(fake_testrunner_output()) do (; writemsg, readmsg, id_counter), uri
            id = id_counter[] += 1
            writemsg(run_testset_command(id, uri); check = false)
            messages = read_until_response(readmsg, ExecuteCommandResponse, id)
            @test last(messages).result === null
            @test any(msg -> msg isa ShowMessageRequest, messages)
        end

        # With server-created progress, the command request is answered before the run
        # starts, so that clients timing out command requests don't report long runs as errors
        capabilities = ClientCapabilities(;
            window = WindowClientCapabilities(; workDoneProgress = true))
        with_fake_testrunner(fake_testrunner_output(); capabilities) do (; writemsg, readmsg, id_counter), uri
            id = id_counter[] += 1
            writemsg(run_testset_command(id, uri); check = false)
            messages = read_until_response(readmsg, ExecuteCommandResponse, id)
            @test last(messages).result === null
            progress_request = only(msg for msg in messages if msg isa WorkDoneProgressCreateRequest)
            writemsg(ResponseMessage(; id = progress_request.id, result = null); check = false)
            token = progress_request.params.token
            messages = collect_messages_until(readmsg) do msg
                is_progress_value(msg, token, WorkDoneProgressEnd)
            end
            @test any(msg -> msg isa ShowMessageRequest, messages)
        end
    end

    @testset "jetls/runTestset cancellation" begin
        with_fake_testrunner("exec sleep 30\n") do (; writemsg, readmsg, id_counter), uri
            id = id_counter[] += 1
            writemsg(run_testset_request(id, uri; workDoneToken = "client-token"); check = false)
            read_until(readmsg) do msg
                is_progress_value(msg, "client-token", WorkDoneProgressBegin)
            end
            writemsg(CancelRequestNotification(; params = CancelParams(; id)); check = false)
            messages = read_until_response(readmsg, RunTestsetResponse, id)
            result = last(messages).result
            @test result isa TestRunnerRunResult
            @test result.status == TestRunnerRunStatus.Cancelled
        end
    end
end

end # module test_testrunner
