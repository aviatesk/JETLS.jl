module test_json_output

using Test
using JSON3: JSON3
using TestRunner
using TestRunner.App: TestRunnerResult

function with_simple_passing_test_file(tester)
    content = """
    using Test

    @testset "simple test" begin
        @test 1 + 1 == 2
    end
    """

    mktemp() do path, io
        write(path, content)
        close(io)
        tester(path)
    end
end

function with_failing_test_file(tester)
    content = """
    using Test

    @testset "failing" begin
        @test 1 == 2
    end
    """

    mktemp() do path, io
        write(path, content)
        close(io)
        tester(path)
    end
end

function run_testrunner_process(args; stdin_input::Union{Nothing,AbstractString}=nothing)
    project = pkgdir(TestRunner)
    cmd = `$(Base.julia_cmd()) --startup-file=no --project=$project -e "using TestRunner; exit(TestRunner.main(ARGS))" -- $args`

    mktemp() do out_path, _
        mktemp() do err_path, _
            pipe = if stdin_input === nothing
                pipeline(cmd, stdout=out_path, stderr=err_path)
            else
                pipeline(cmd, stdin=IOBuffer(stdin_input), stdout=out_path, stderr=err_path)
            end
            proc = run(pipe, wait=false)
            wait(proc)

            return (
                stdout = read(out_path, String),
                stderr = read(err_path, String),
                exitcode = proc.exitcode
            )
        end
    end
end

with_simple_passing_test_file() do testfile
    result = run_testrunner_process(["--json", testfile])
    @test result.exitcode == 0
    @test isempty(result.stderr)
    json_result = JSON3.read(result.stdout, TestRunnerResult)
    stats = json_result.stats
    @test stats.n_passed == 1
    @test stats.n_failed == stats.n_errored == stats.n_broken == 0
    @test stats.duration > 0
    @test isempty(json_result.diagnostics)
end

let
    result = run_testrunner_process(["--json", "/nonexistent/file.jl"])
    @test result.exitcode == 1
    @test !isempty(result.stderr)
    @test occursin("File not found", result.stderr)
    @test isempty(result.stdout)
end

with_simple_passing_test_file() do testfile
    result = run_testrunner_process(["--json", "--invalid-option", testfile])
    @test result.exitcode == 1
    @test !isempty(result.stderr)
    @test occursin("Unknown option", result.stderr)
    @test isempty(result.stdout)
end

with_simple_passing_test_file() do testfile
    result = run_testrunner_process(["--json", testfile, "simple test"])
    @test result.exitcode == 0
    @test isempty(result.stderr)
    json_result = JSON3.read(result.stdout, TestRunnerResult)
    @test json_result.patterns == ["simple test"]
    stats = json_result.stats
    @test stats.n_passed == 1
    @test stats.n_failed == stats.n_errored == stats.n_broken == 0
    @test stats.duration > 0
    @test isempty(json_result.diagnostics)
end

with_simple_passing_test_file() do testfile
    result = run_testrunner_process(["--json", "--verbose", testfile])
    json_result = JSON3.read(result.stdout, TestRunnerResult)
    @test occursin("Test Setup", json_result.logs)
    @test occursin("Julia version", json_result.logs)
    @test occursin("Test Configuration", json_result.logs)
    @test occursin("Running Tests", json_result.logs)
end

with_failing_test_file() do testfile
    result = run_testrunner_process(["--json", testfile])
    @test result.exitcode == 1
    @test isempty(result.stderr)
    json_result = JSON3.read(result.stdout, TestRunnerResult)
    stats = json_result.stats
    @test stats.n_failed == 1
    @test stats.n_passed == stats.n_errored == stats.n_broken == 0
    @test stats.duration > 0
    @test !isempty(json_result.diagnostics)
end

function with_test_file(tester, content::AbstractString)
    mktemp() do path, io
        write(io, content)
        close(io)
        tester(path)
    end
end

@testset "testsets" begin
    content = """
    using Test

    @testset "outer" begin
        @test true
        @testset "inner" begin
            @test 1 == 2
        end
        @testset "case \$i" for i in 1:2
            @test i > 0
        end
    end

    @testset "other" begin
        @test true
    end
    """
    with_test_file(content) do testfile
        result = run_testrunner_process(["--json", testfile, "outer"])
        @test result.exitcode == 1
        json_result = JSON3.read(result.stdout, TestRunnerResult)
        outer = only(json_result.testsets)
        @test outer.description == "outer"
        @test outer.line == 3
        @test outer.stats.n_passed == 3
        @test outer.stats.n_failed == 1
        @test outer.stats.duration > 0
        @test isempty(outer.diagnostics)
        inner, case1, case2 = outer.children
        @test inner.description == "inner"
        @test inner.line == 5
        @test inner.stats.n_failed == 1
        @test only(inner.diagnostics).line == 6
        @test case1.description == "case 1" && case1.line == 8
        @test case2.description == "case 2" && case2.line == 8
        @test case1.stats.n_passed == case2.stats.n_passed == 1
    end
    # Running a nested test set also reports its enclosing test sets
    with_test_file(content) do testfile
        result = run_testrunner_process(["--json", testfile, "inner"])
        json_result = JSON3.read(result.stdout, TestRunnerResult)
        outer = only(json_result.testsets)
        @test outer.line == 3
        inner = only(outer.children)
        @test inner.line == 5
        @test inner.stats.n_failed == 1
    end
    # Without patterns, the file is run via `include` and test sets are not reported
    with_test_file(content) do testfile
        result = run_testrunner_process(["--json", testfile])
        json_result = JSON3.read(result.stdout, TestRunnerResult)
        @test json_result.stats.n_passed == 4
        @test json_result.testsets === nothing
    end
    # Custom test set types wrapping `Test.DefaultTestSet`
    let content = """
        using Test

        struct WrapperTestSet <: Test.AbstractTestSet
            dts::Test.DefaultTestSet
        end
        WrapperTestSet(desc::AbstractString; kws...) =
            WrapperTestSet(Test.DefaultTestSet(desc; kws...))
        Test.record(ts::WrapperTestSet, res) = Test.record(ts.dts, res)
        Test.finish(ts::WrapperTestSet) = Test.finish(ts.dts)

        @testset WrapperTestSet "wrapped" begin
            @testset "nested" begin
                @test true
            end
        end
        """
        with_test_file(content) do testfile
            result = run_testrunner_process(["--json", testfile, "nested"])
            @test result.exitcode == 0
            json_result = JSON3.read(result.stdout, TestRunnerResult)
            wrapped = only(json_result.testsets)
            @test wrapped.description == "wrapped"
            @test wrapped.line == 11
            nested = only(wrapped.children)
            @test nested.description == "nested"
            @test nested.line == 12
            @test nested.stats.n_passed == 1
        end
    end
    # A literal description is not matched by the pattern of a preceding interpolated one
    let content = """
        using Test

        @testset "case \$i" for i in 1:2
            @test true
        end
        @testset "case X" begin
            @test true
        end
        """
        with_test_file(content) do testfile
            result = run_testrunner_process(["--json", testfile, "L3:8"])
            @test result.exitcode == 0
            json_result = JSON3.read(result.stdout, TestRunnerResult)
            case1, case2, casex = json_result.testsets
            @test case1.description == "case 1" && case1.line == 3
            @test case2.description == "case 2" && case2.line == 3
            @test casex.description == "case X" && casex.line == 6
        end
        with_test_file(content) do testfile
            result = run_testrunner_process(["--json", testfile, "case X"])
            json_result = JSON3.read(result.stdout, TestRunnerResult)
            casex = only(json_result.testsets)
            @test casex.description == "case X"
            @test casex.line == 6
        end
    end
end

@testset "--read-stdin" begin
    # Pass source via stdin; file path is still required for `@__FILE__` etc.
    let source = """
        using Test
        @testset "stdin test" begin
            @test 1 + 1 == 2
        end
        """
        with_simple_passing_test_file() do testfile
            result = run_testrunner_process(["--json", "--read-stdin", testfile];
                                            stdin_input=source)
            @test result.exitcode == 0
            @test isempty(result.stderr)
            json_result = JSON3.read(result.stdout, TestRunnerResult)
            stats = json_result.stats
            @test stats.n_passed == 1
            @test stats.n_failed == stats.n_errored == stats.n_broken == 0
        end
    end

    # Stdin source overrides on-disk content: testset name only exists in stdin
    with_simple_passing_test_file() do testfile
        source = """
        using Test
        @testset "stdin only" begin
            @test true
        end
        """
        result = run_testrunner_process(["--json", "--read-stdin", testfile, "stdin only"];
                                        stdin_input=source)
        @test result.exitcode == 0
        json_result = JSON3.read(result.stdout, TestRunnerResult)
        @test json_result.stats.n_passed == 1
    end

    # `--read-stdin` works even when the file does not exist on disk
    let source = """
        using Test
        @testset "no file" begin
            @test 1 == 1
        end
        """
        nonexistent = joinpath(mktempdir(), "ghost.jl")
        result = run_testrunner_process(["--json", "--read-stdin", nonexistent];
                                        stdin_input=source)
        @test result.exitcode == 0
        json_result = JSON3.read(result.stdout, TestRunnerResult)
        @test json_result.stats.n_passed == 1
    end

    # `--read-stdin` plus `--filter-lines` matches a testset on a stdin-defined line
    with_simple_passing_test_file() do testfile
        source = """
        using Test
        @testset "first" begin
            @test 1 == 1
        end
        @testset "second" begin
            @test 2 == 2
        end
        """
        result = run_testrunner_process(
            ["--json", "--read-stdin", testfile, "second", "--filter-lines=5"];
            stdin_input=source)
        @test result.exitcode == 0
        json_result = JSON3.read(result.stdout, TestRunnerResult)
        @test json_result.stats.n_passed == 1
    end

    # When source comes from stdin, the file path is treated as a virtual
    # identifier and not `abspath`'d, so editor integrations can pass an
    # untitled-buffer name and have it round-trip through diagnostics
    # unchanged.
    let source = """
        using Test
        @testset "virtual" begin
            @test 1 == 2
        end
        """
        virtual_name = "Untitled-1"
        result = run_testrunner_process(
            ["--json", "--read-stdin", virtual_name];
            stdin_input=source)
        @test result.exitcode == 1
        json_result = JSON3.read(result.stdout, TestRunnerResult)
        @test json_result.filename == virtual_name
        @test !isempty(json_result.diagnostics)
        @test all(diag -> diag.filename == virtual_name, json_result.diagnostics)
    end
end

@testset "--root-path" begin
    # `--root-path` lets a virtual stdin filename resolve relative `include`
    # calls from a real workspace directory, both for the selective-execution
    # path (with patterns, via `runtest`) and the plain include path (no
    # patterns, via `Base.include_string`).
    mktempdir() do dir
        helper_path = joinpath(dir, "helpers.jl")
        write(helper_path, "helper_value() = 42\n")
        source = """
        using Test
        include("helpers.jl")
        @testset "rooted" begin
            @test helper_value() == 42
        end
        """
        for extra_args in (String[], ["rooted"])
            result = run_testrunner_process(
                ["--json", "--read-stdin", "--root-path=$dir", "Untitled-1", extra_args...];
                stdin_input=source)
            @test result.exitcode == 0
            @test isempty(result.stderr)
            json_result = JSON3.read(result.stdout, TestRunnerResult)
            @test json_result.stats.n_passed == 1
            @test isempty(json_result.diagnostics)
        end
    end

    # Without `--root-path`, the same virtual filename can't find the helper
    # because `dirname("Untitled-1")` is empty and resolution falls back to
    # cwd, which is unlikely to contain the helper.
    mktempdir() do dir
        helper_path = joinpath(dir, "helpers.jl")
        write(helper_path, "helper_value() = 42\n")
        source = """
        using Test
        include("helpers.jl")
        @testset "rooted" begin
            @test helper_value() == 42
        end
        """
        result = run_testrunner_process(
            ["--json", "--read-stdin", "Untitled-1", "rooted"];
            stdin_input=source)
        @test result.exitcode != 0
    end

    # When `filename` carries its own directory, `--root-path` is ignored —
    # nested includes resolve via that file's `dirname` as usual.
    mktempdir() do dir
        helper_path = joinpath(dir, "helpers.jl")
        write(helper_path, "helper_value() = 42\n")
        # An unrelated decoy in `--root-path` would mask the real helper if
        # `--root-path` were preferred over `dirname`.
        decoy_dir = mktempdir()
        decoy_helper = joinpath(decoy_dir, "helpers.jl")
        write(decoy_helper, "helper_value() = 0\n")
        entry_path = joinpath(dir, "entry.jl")
        write(entry_path, """
        using Test
        include("helpers.jl")
        @testset "real dir" begin
            @test helper_value() == 42
        end
        """)
        result = run_testrunner_process(
            ["--json", "--root-path=$decoy_dir", entry_path, "real dir"])
        @test result.exitcode == 0
        json_result = JSON3.read(result.stdout, TestRunnerResult)
        @test json_result.stats.n_passed == 1
    end
end

@testset "deprecated `--project`" begin
    mktempdir() do dir
        project_file = joinpath(dir, "Project.toml")
        write(project_file, "")
        testfile = joinpath(dir, "runtests.jl")
        write(testfile, """
        using Test
        @testset "active project" begin
            @test Base.active_project() == $(repr(project_file))
        end
        """)
        # `@.` is resolved from the test file rather than from the current directory
        for project in (dir, "@.")
            result = run_testrunner_process(["--json", "--project=$project", testfile, "active project"])
            @test result.exitcode == 0
            @test occursin("`--project` option of testrunner is deprecated", result.stderr)
            json_result = JSON3.read(result.stdout, TestRunnerResult)
            @test json_result.stats.n_passed == 1
        end
    end
end

end # module test_json_output
