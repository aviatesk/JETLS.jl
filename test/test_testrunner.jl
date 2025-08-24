module test_testrunner

using Test
using JETLS
using JETLS: JS, JL
using JETLS.LSP
using JETLS.LSP.URIs2

include("jsjl_utils.jl")

function mock_testrunner_result(; n_passed=1, n_failed=0, n_errored=0, n_broken=0, duration=1.0)
    stats = JETLS.TestRunnerStats(; n_passed, n_failed, n_errored, n_broken, duration)
    return JETLS.TestRunnerResult(; filename="test.jl", stats)
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

@testset "testrunner_code_lenses" begin
    let server = JETLS.Server()
        test_code = """
        @testset "my_tests" begin
            @test true
        end
        """
        fi = JETLS.FileInfo(1, test_code, @__FILE__)
        JETLS.update_testsetinfos!(server, fi, nothing; notify_server=false)
        @test length(fi.testsetinfos) == 1
        uri = URI("file://runtests.jl")

        code_lenses = CodeLens[]
        JETLS.testrunner_code_lenses!(code_lenses, uri, fi)

        @test length(code_lenses) == 1
        first_lens = code_lenses[1]
        tsn = JETLS.testset_name(fi.testsetinfos[1])
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
        fi = JETLS.FileInfo(1, test_code, uri)
        JETLS.update_testsetinfos!(server, fi, nothing; notify_server=false)
        @test length(fi.testsetinfos) == 2

        result = mock_testrunner_result(; n_passed=1)
        key = JETLS.TestsetDiagnosticsKey(uri, "\"my_tests\"", 1)
        fi.testsetinfos[1] = JETLS.TestsetInfo(fi.testsetinfos[1].st0, JETLS.TestsetResult(result, key))

        code_lenses = CodeLens[]
        JETLS.testrunner_code_lenses!(code_lenses, uri, fi)

        @test length(code_lenses) == 4

        rerun_lens = code_lenses[1]
        tsn1 = JETLS.testset_name(fi.testsetinfos[1])
        expected_title = "$(JETLS.TESTRUNNER_RERUN_TITLE) $tsn1 [ Total: 1 | Pass: 1 | Time: 1.0s ]"
        @test rerun_lens.command.title == expected_title
        @test rerun_lens.command.command == JETLS.COMMAND_TESTRUNNER_RUN_TESTSET
        @test rerun_lens.command.arguments == [uri, 1, tsn1]

        logs_lens = code_lenses[2]
        @test logs_lens.command.title == JETLS.TESTRUNNER_OPEN_LOGS_TITLE
        @test logs_lens.command.command == JETLS.COMMAND_TESTRUNNER_OPEN_LOGS
        @test length(logs_lens.command.arguments) == 2
        @test logs_lens.command.arguments[1] == tsn1

        clear_lens = code_lenses[3]
        @test clear_lens.command.title == JETLS.TESTRUNNER_CLEAR_RESULT_TITLE
        @test clear_lens.command.command == JETLS.COMMAND_TESTRUNNER_CLEAR_RESULT
        @test clear_lens.command.arguments == [uri, 1, tsn1]

        run_lens = code_lenses[4]
        tsn2 = JETLS.testset_name(fi.testsetinfos[2])
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
        fi = JETLS.FileInfo(1, test_code, uri)
        JETLS.update_testsetinfos!(server, fi, nothing; notify_server=false)
        @test length(fi.testsetinfos) == 2

        # Test action at position inside first testset
        first_testset_range = LSP.Range(;
            start = positions[1],
            var"end" = positions[1])

        code_actions = Union{CodeAction,Command}[]
        JETLS.testrunner_code_actions!(code_actions, uri, fi, first_testset_range)
        @test length(code_actions) == 2  # Now includes both @testset and @test actions
        tsn1 = JETLS.testset_name(fi.testsetinfos[1])
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

        code_actions = Union{CodeAction,Command}[]
        JETLS.testrunner_code_actions!(code_actions, uri, fi, second_testset_range)
        @test length(code_actions) == 1
        tsn2 = JETLS.testset_name(fi.testsetinfos[2])
        @test code_actions[1].title == "$(JETLS.TESTRUNNER_RUN_TITLE) $tsn2"
        @test code_actions[1].command.command == JETLS.COMMAND_TESTRUNNER_RUN_TESTSET
        @test code_actions[1].command.arguments == [uri, 2, tsn2]

        # Test action with multi-byte span covering both testsets
        multi_range = LSP.Range(;
            start = positions[1],
            var"end" = positions[2])

        code_actions = Union{CodeAction,Command}[]
        JETLS.testrunner_code_actions!(code_actions, uri, fi, multi_range)
        @test length(code_actions) == 3  # Two @testset actions and one @test action (true)
        tsn1 = JETLS.testset_name(fi.testsetinfos[1])
        tsn2 = JETLS.testset_name(fi.testsetinfos[2])
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

        code_actions = Union{CodeAction,Command}[]
        JETLS.testrunner_code_actions!(code_actions, uri, fi, after_end_range)
        @test length(code_actions) == 1
        tsn2 = JETLS.testset_name(fi.testsetinfos[2])
        @test code_actions[1].title == "$(JETLS.TESTRUNNER_RUN_TITLE) $tsn2"
        @test code_actions[1].command.command == JETLS.COMMAND_TESTRUNNER_RUN_TESTSET
        @test code_actions[1].command.arguments == [uri, 2, tsn2]

        # Test action at position outside any testset
        no_overlap_range = LSP.Range(;
            start = positions[4],
            var"end" = positions[4])

        code_actions = Union{CodeAction,Command}[]
        JETLS.testrunner_code_actions!(code_actions, uri, fi, no_overlap_range)
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
        fi = JETLS.FileInfo(1, test_code, uri)
        JETLS.update_testsetinfos!(server, fi, nothing; notify_server=false)
        @test length(fi.testsetinfos) == 1

        result = mock_testrunner_result(; n_passed=1, duration=0.5)
        key = JETLS.TestsetDiagnosticsKey(uri, "\"test_with_results\"", 1)
        fi.testsetinfos[1] = JETLS.TestsetInfo(fi.testsetinfos[1].st0, JETLS.TestsetResult(result, key))

        testset_range = LSP.Range(;
            start = positions[1],
            var"end" = positions[1])

        code_actions = Union{CodeAction,Command}[]
        JETLS.testrunner_code_actions!(code_actions, uri, fi, testset_range)
        @test length(code_actions) == 3

        tsn = JETLS.testset_name(fi.testsetinfos[1])
        @test code_actions[1].title == "$(JETLS.TESTRUNNER_RERUN_TITLE) $tsn [ Total: 1 | Pass: 1 | Time: 500.0ms ]"
        @test code_actions[1].command.command == JETLS.COMMAND_TESTRUNNER_RUN_TESTSET
        @test code_actions[1].command.arguments == [uri, 1, tsn]

        @test code_actions[2].title == JETLS.TESTRUNNER_OPEN_LOGS_TITLE
        @test code_actions[2].command.command == JETLS.COMMAND_TESTRUNNER_OPEN_LOGS
        @test length(code_actions[2].command.arguments) == 2
        @test code_actions[2].command.arguments[1] == tsn

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
        fi = JETLS.FileInfo(1, test_code, uri)
        JETLS.update_testsetinfos!(server, fi, nothing; notify_server=false)

        # Test action on standalone @test (outside any testset)
        standalone_range = LSP.Range(;
            start = positions[1],
            var"end" = positions[1])
        code_actions = Union{CodeAction,Command}[]
        JETLS.testrunner_code_actions!(code_actions, uri, fi, standalone_range)
        @test length(code_actions) == 1
        @test code_actions[1].title == "$(JETLS.TESTRUNNER_RUN_TITLE) `@test 1 == 1`"
        @test code_actions[1].command.command == JETLS.COMMAND_TESTRUNNER_RUN_TESTCASE
        @test code_actions[1].command.arguments == [uri, 2, "`@test 1 == 1`"]

        # Test action on first @test inside testset
        # Now shows both testset and @test actions
        first_test_range = LSP.Range(;
            start = positions[2],
            var"end" = positions[2])
        code_actions = Union{CodeAction,Command}[]
        JETLS.testrunner_code_actions!(code_actions, uri, fi, first_test_range)
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
        code_actions = Union{CodeAction,Command}[]
        JETLS.testrunner_code_actions!(code_actions, uri, fi, multiline_range)
        @test length(code_actions) == 1
        @test occursin("@test_throws DomainError sin(Inf)", code_actions[1].title)
        @test code_actions[1].command.command == JETLS.COMMAND_TESTRUNNER_RUN_TESTCASE

        # Test action on multi-line @test (outside any testset)
        multiline_range = LSP.Range(;
            start = positions[4],
            var"end" = positions[4])
        code_actions = Union{CodeAction,Command}[]
        JETLS.testrunner_code_actions!(code_actions, uri, fi, multiline_range)
        @test length(code_actions) == 1
        @test occursin("@test begin", code_actions[1].title)
        @test code_actions[1].command.command == JETLS.COMMAND_TESTRUNNER_RUN_TESTCASE
    end
end

@testset "update_testsetinfos!" begin
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
        fi1 = JETLS.FileInfo(1, test_code, uri)
        JETLS.update_testsetinfos!(server, fi1, nothing; notify_server=false)
        @test length(fi1.testsetinfos) == 2

        result1 = mock_testrunner_result(; n_passed=1)
        key1 = JETLS.TestsetDiagnosticsKey(uri, "\"foo\"", 1)
        result2 = mock_testrunner_result(; n_passed=0, n_failed=1)
        key2 = JETLS.TestsetDiagnosticsKey(uri, "\"bar\"", 2)

        fi1.testsetinfos[1] = JETLS.TestsetInfo(fi1.testsetinfos[1].st0, JETLS.TestsetResult(result1, key1))
        fi1.testsetinfos[2] = JETLS.TestsetInfo(fi1.testsetinfos[2].st0, JETLS.TestsetResult(result2, key2))

        new_test_code = test_code * "\n" # new line inserted at the end
        fi2 = JETLS.FileInfo(2, new_test_code, uri)
        @test !JETLS.update_testsetinfos!(server, fi2, fi1; notify_server=false) # nothing changed
        @test length(fi2.testsetinfos) == 2
        @test isdefined(fi2.testsetinfos[1], :result)
        @test isdefined(fi2.testsetinfos[2], :result)
        @test fi2.testsetinfos[1].result.result === result1
        @test fi2.testsetinfos[2].result.result === result2
    end

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
        fi1 = JETLS.FileInfo(1, test_code, uri)
        JETLS.update_testsetinfos!(server, fi1, nothing; notify_server=false)
        @test length(fi1.testsetinfos) == 2

        result = mock_testrunner_result(; n_passed=1)
        key = JETLS.TestsetDiagnosticsKey(uri, "\"foo\"", 1)
        fi1.testsetinfos[1] = JETLS.TestsetInfo(fi1.testsetinfos[1].st0, JETLS.TestsetResult(result, key))
        server.state.extra_diagnostics[key] = JETLS.testrunner_result_to_diagnostics(result)

        new_test_code = """
        @testset "foo" begin
            @test 1 > 0
        end

        @testset "bar" begin
            @test sin(0) == 1
        end
        """ # the testset "foo" has been modified
        fi2 = JETLS.FileInfo(2, new_test_code, uri)
        @test !JETLS.update_testsetinfos!(server, fi2, fi1; notify_server=false) # test results are still being mapped
        @test haskey(server.state.extra_diagnostics, key)
        @test length(fi2.testsetinfos) == 2
        @test isdefined(fi2.testsetinfos[1], :result)
        @test !isdefined(fi2.testsetinfos[2], :result)
    end

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
        fi1 = JETLS.FileInfo(1, test_code, uri)
        JETLS.update_testsetinfos!(server, fi1, nothing; notify_server=false)
        @test length(fi1.testsetinfos) == 2

        result = mock_testrunner_result(; n_passed=1)
        key = JETLS.TestsetDiagnosticsKey(uri, "\"foo\"", 1)
        fi1.testsetinfos[1] = JETLS.TestsetInfo(fi1.testsetinfos[1].st0, JETLS.TestsetResult(result, key))
        server.state.extra_diagnostics[key] = JETLS.testrunner_result_to_diagnostics(result)

        new_test_code = """
        @testset "bar" begin
            @test sin(0) == 1
        end
        """ # the testset "foo" has been deleted
        fi2 = JETLS.FileInfo(2, new_test_code, uri)
        @test JETLS.update_testsetinfos!(server, fi2, fi1; notify_server=false)
        @test isempty(server.state.extra_diagnostics)
        @test length(fi2.testsetinfos) == 1
        @test !isdefined(fi2.testsetinfos[1], :result)
    end

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
        fi1 = JETLS.FileInfo(1, test_code, uri)
        JETLS.update_testsetinfos!(server, fi1, nothing; notify_server=false)
        @test length(fi1.testsetinfos) == 2

        result = mock_testrunner_result(; n_passed=1)
        key = JETLS.TestsetDiagnosticsKey(uri, "\"foo\"", 1)
        fi1.testsetinfos[1] = JETLS.TestsetInfo(fi1.testsetinfos[1].st0, JETLS.TestsetResult(result, key))
        server.state.extra_diagnostics[key] = JETLS.testrunner_result_to_diagnostics(result)

        new_test_code = """
        @testset "baz" begin
            @test 10 > 0
        end

        @testset "bar" begin
            @test sin(0) == 1
        end
        """ # the testset "foo" has been renamed to "baz"
        fi2 = JETLS.FileInfo(2, new_test_code, uri)
        @test JETLS.update_testsetinfos!(server, fi2, fi1; notify_server=false)
        @test !haskey(server.state.extra_diagnostics, key)
        @test length(fi2.testsetinfos) == 2
        @test !isdefined(fi2.testsetinfos[1], :result)
        @test !isdefined(fi2.testsetinfos[2], :result)
    end

    let server = JETLS.Server()
        test_code = """
        @testset "foo" begin
            @test 10 > 0
        end
        """
        uri = URI("file://runtests.jl")
        fi1 = JETLS.FileInfo(1, test_code, uri)
        JETLS.update_testsetinfos!(server, fi1, nothing; notify_server=false)
        @test length(fi1.testsetinfos) == 1

        result = mock_testrunner_result(; n_passed=1)
        key = JETLS.TestsetDiagnosticsKey(uri, "\"foo\"", 1)
        fi1.testsetinfos[1] = JETLS.TestsetInfo(fi1.testsetinfos[1].st0, JETLS.TestsetResult(result, key))
        server.state.extra_diagnostics[key] = JETLS.testrunner_result_to_diagnostics(result)

        new_test_code = """
        @testset "foo" begin
            @test 10 > 0
        end

        @testset "bar" begin
            @test true
        end
        """
        fi2 = JETLS.FileInfo(2, new_test_code, uri)
        @test !JETLS.update_testsetinfos!(server, fi2, fi1; notify_server=false) # just the new testset has been added
        @test haskey(server.state.extra_diagnostics, key)
        @test length(fi2.testsetinfos) == 2
        @test isdefined(fi2.testsetinfos[1], :result)
        @test fi2.testsetinfos[1].result.result === result
        @test !isdefined(fi2.testsetinfos[2], :result)
    end
end

end # module test_testrunner
