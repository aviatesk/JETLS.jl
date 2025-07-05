module test_testrunner

using Test
using JETLS
using JETLS: JS, JL
using JETLS.LSP

include("jsjl_utils.jl")

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
    let stats = JETLS.TestRunnerStats(;
            n_passed=10,
            n_failed=0,
            n_errored=0,
            n_broken=0,
            duration=1.5)
        result = JETLS.TestRunnerResult(; filename="test.jl", stats)
        @test JETLS.summary_testrunner_result(result) == "[ Total: 10 | Pass: 10 | Time: 1.5s ]"
    end

    let stats = JETLS.TestRunnerStats(;
            n_passed=5,
            n_failed=2,
            n_errored=1,
            n_broken=1,
            duration=0.123)
        result = JETLS.TestRunnerResult(; filename="test.jl", stats)
        expected = "[ Total: 9 | Pass: 5 | Fail: 2 | Error: 1 | Broken: 1 | Time: 123.0ms ]"
        @test JETLS.summary_testrunner_result(result) == expected
    end

    let stats = JETLS.TestRunnerStats(;
            n_passed=0,
            n_failed=0,
            n_errored=0,
            n_broken=0,
            duration=0.0)
        result = JETLS.TestRunnerResult(; filename="test.jl", stats)
        @test JETLS.summary_testrunner_result(result) == "[ Total: 0 | Time: 0.0ms ]"
    end

    let stats = JETLS.TestRunnerStats(;
            n_passed=100,
            n_failed=0,
            n_errored=0,
            n_broken=0,
            duration=125.5)
        result = JETLS.TestRunnerResult(; filename="test.jl", stats)
        @test JETLS.summary_testrunner_result(result) == "[ Total: 100 | Pass: 100 | Time: 2m 5.5s ]"
    end
end

@testset "testrunner_code_lenses" begin
    let test_code = """
        @testset "my_tests" begin
            @test true
        end
        """
        fi = JETLS.FileInfo(1, parsedstream(test_code))
        st0 = JETLS.build_tree!(JL.SyntaxTree, fi)
        testsets = JETLS.find_executable_testsets(st0)
        @test length(testsets) == 1

        fi.testsetinfos = [JETLS.TestsetInfo(testsets[1])]
        uri = LSP.URI("file:///test.jl")

        code_lenses = JETLS.testrunner_code_lenses(uri, fi, fi.testsetinfos)

        @test length(code_lenses) == 1
        first_lens = code_lenses[1]
        tsn = JETLS.testset_name(fi.testsetinfos[1])
        @test first_lens.command.title == "$(JETLS.TESTRUNNER_RUN_TITLE) $tsn"
        @test first_lens.command.command == JETLS.COMMAND_TESTRUNNER_RUN_TESTSET
        @test first_lens.command.arguments == [uri, 1, tsn]
        @test first_lens.range isa LSP.Range
    end

    let test_code = """
        @testset "my_tests" begin
            @test true
        end

        @testset "other_tests" begin
            @test false
        end
        """
        fi = JETLS.FileInfo(1, parsedstream(test_code))
        st0 = JETLS.build_tree!(JL.SyntaxTree, fi)
        testsets = JETLS.find_executable_testsets(st0)
        @test length(testsets) == 2

        stats = JETLS.TestRunnerStats(;
            n_passed=5,
            n_failed=1,
            duration=1.0)
        result = JETLS.TestRunnerResult(; filename="test.jl", stats)
        fi.testsetinfos = [
            JETLS.TestsetInfo(testsets[1], result),
            JETLS.TestsetInfo(testsets[2])
        ]
        uri = LSP.URI("file:///test.jl")

        code_lenses = JETLS.testrunner_code_lenses(uri, fi, fi.testsetinfos)

        @test length(code_lenses) == 4

        rerun_lens = code_lenses[1]
        tsn1 = JETLS.testset_name(fi.testsetinfos[1])
        expected_title = "$(JETLS.TESTRUNNER_RERUN_TITLE) $tsn1 [ Total: 6 | Pass: 5 | Fail: 1 | Time: 1.0s ]"
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
    let test_code_with_positions = """
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

        fi = JETLS.FileInfo(1, parsedstream(test_code))
        st0 = JETLS.build_tree!(JL.SyntaxTree, fi)
        testsets = JETLS.find_executable_testsets(st0)
        @test length(testsets) == 2

        fi.testsetinfos = [
            JETLS.TestsetInfo(testsets[1]),
            JETLS.TestsetInfo(testsets[2])
        ]
        uri = LSP.URI("file:///test.jl")

        # Test action at position inside first testset
        first_testset_range = LSP.Range(;
            start = positions[1],
            var"end" = positions[1])

        code_actions = JETLS.testrunner_code_actions(uri, fi, fi.testsetinfos, first_testset_range)
        @test length(code_actions) == 1
        tsn1 = JETLS.testset_name(fi.testsetinfos[1])
        @test code_actions[1].title == "$(JETLS.TESTRUNNER_RUN_TITLE) $tsn1"
        @test code_actions[1].command.command == JETLS.COMMAND_TESTRUNNER_RUN_TESTSET
        @test code_actions[1].command.arguments == [uri, 1, tsn1]

        # Test action at position inside second testset
        second_testset_range = LSP.Range(;
            start = positions[2],
            var"end" = positions[2])

        code_actions = JETLS.testrunner_code_actions(uri, fi, fi.testsetinfos, second_testset_range)
        @test length(code_actions) == 1
        tsn2 = JETLS.testset_name(fi.testsetinfos[2])
        @test code_actions[1].title == "$(JETLS.TESTRUNNER_RUN_TITLE) $tsn2"
        @test code_actions[1].command.command == JETLS.COMMAND_TESTRUNNER_RUN_TESTSET
        @test code_actions[1].command.arguments == [uri, 2, tsn2]

        # Test action with multi-byte span covering both testsets
        multi_range = LSP.Range(;
            start = positions[1],
            var"end" = positions[2])

        code_actions = JETLS.testrunner_code_actions(uri, fi, fi.testsetinfos, multi_range)
        @test length(code_actions) == 2
        tsn1 = JETLS.testset_name(fi.testsetinfos[1])
        tsn2 = JETLS.testset_name(fi.testsetinfos[2])
        @test code_actions[1].title == "$(JETLS.TESTRUNNER_RUN_TITLE) $tsn1"
        @test code_actions[1].command.command == JETLS.COMMAND_TESTRUNNER_RUN_TESTSET
        @test code_actions[1].command.arguments == [uri, 1, tsn1]
        @test code_actions[2].title == "$(JETLS.TESTRUNNER_RUN_TITLE) $tsn2"
        @test code_actions[2].command.command == JETLS.COMMAND_TESTRUNNER_RUN_TESTSET
        @test code_actions[2].command.arguments == [uri, 2, tsn2]

        # Test action at position right after testset end
        after_end_range = LSP.Range(;
            start = positions[3],
            var"end" = positions[3])

        code_actions = JETLS.testrunner_code_actions(uri, fi, fi.testsetinfos, after_end_range)
        @test length(code_actions) == 1
        tsn2 = JETLS.testset_name(fi.testsetinfos[2])
        @test code_actions[1].title == "$(JETLS.TESTRUNNER_RUN_TITLE) $tsn2"
        @test code_actions[1].command.command == JETLS.COMMAND_TESTRUNNER_RUN_TESTSET
        @test code_actions[1].command.arguments == [uri, 2, tsn2]

        # Test action at position outside any testset
        no_overlap_range = LSP.Range(;
            start = positions[4],
            var"end" = positions[4])

        code_actions = JETLS.testrunner_code_actions(uri, fi, fi.testsetinfos, no_overlap_range)
        @test isempty(code_actions)
    end

    let test_code_with_positions = """
        @testset "test_wi│th_results" begin
            @test true
        end
        """
        test_code, positions = JETLS.get_text_and_positions(test_code_with_positions)
        @test length(positions) == 1

        fi = JETLS.FileInfo(1, parsedstream(test_code))
        st0 = JETLS.build_tree!(JL.SyntaxTree, fi)
        testsets = JETLS.find_executable_testsets(st0)

        stats = JETLS.TestRunnerStats(;
            n_passed=3,
            n_failed=1,
            duration=0.5)
        result = JETLS.TestRunnerResult(; filename="test.jl", stats)
        fi.testsetinfos = [JETLS.TestsetInfo(testsets[1], result)]
        uri = LSP.URI("file:///test.jl")

        # Test that we get 3 code actions for a testset with results
        testset_range = LSP.Range(;
            start = positions[1],
            var"end" = positions[1])

        code_actions = JETLS.testrunner_code_actions(uri, fi, fi.testsetinfos, testset_range)
        @test length(code_actions) == 3

        tsn = JETLS.testset_name(fi.testsetinfos[1])
        @test code_actions[1].title == "$(JETLS.TESTRUNNER_RERUN_TITLE) $tsn [ Total: 4 | Pass: 3 | Fail: 1 | Time: 500.0ms ]"
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
end

end # module test_testrunner
