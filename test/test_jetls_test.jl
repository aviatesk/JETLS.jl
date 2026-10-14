"""
Test file for exercising the `jetls test` command.

This test calls `JETLSCore.run_test` directly for behavior coverage and uses an actual
`julia -m JETLS test` process for a process-boundary smoke test. It verifies:

1. Patterns and TestRunner.jl options are passed to TestRunner.jl
2. The exit code reflects the test results
3. The test environment is detected from the test file and overridden by `--project`
4. The `[testrunner]` configuration of `.JETLSConfig.toml` and `--julia` apply

To run this test independently:
    julia --startup-file=no --project=./test ./test/test_jetls_test.jl
"""
module test_jetls_test

using Test
using JETLS
using JETLSCore
using JETLSCore.LSP.JSON3: JSON3

const JULIA_CMD = normpath(Sys.BINDIR, "julia")
const JETLS_DIR = pkgdir(JETLS)

# `jetls test` runs TestRunner.jl in a child process that inherits the standard streams,
# so they are redirected to files rather than to in-memory buffers.
function capture_jetls_test(f::Function)
    return mktemp() do stdout_path, stdout_io
        mktemp() do stderr_path, stderr_io
            exitcode = redirect_stdout(stdout_io) do
                redirect_stderr(stderr_io) do
                    Int(f())
                end
            end
            flush(stdout_io)
            flush(stderr_io)
            return (;
                exitcode,
                stdout = read(stdout_path, String),
                stderr = read(stderr_path, String),
            )
        end
    end
end

run_jetls_test(args::Vector{String}) = capture_jetls_test(() -> JETLSCore.run_test(args))

function write_test_file(dir::String, content::String)
    filepath = joinpath(dir, "runtests.jl")
    write(filepath, content)
    return filepath
end

const TESTFILE_CONTENT = """
    using Test
    @testset "pass" begin
        @test 1 + 1 == 2
    end
    @testset "fail" begin
        @test 1 + 1 == 3
    end
    """

@testset "help" begin
    result = capture_jetls_test(() -> JETLS.main(["test", "--help"]))
    @test result.exitcode == 0
    @test occursin("Usage: jetls test", result.stdout)
end

@testset "missing test file" begin
    result = run_jetls_test(["--verbose"])
    @test result.exitcode == 1
    @test occursin("No test file given", result.stderr)
end

@testset "patterns and exit code" begin
    mktempdir() do dir
        filepath = write_test_file(dir, TESTFILE_CONTENT)

        result = run_jetls_test([filepath, "pass"])
        @test result.exitcode == 0
        @test occursin("Test Summary", result.stdout)

        result = run_jetls_test([filepath, "fail"])
        @test result.exitcode == 1

        result = run_jetls_test([filepath])
        @test result.exitcode == 1
    end
end

@testset "TestRunner.jl options" begin
    mktempdir() do dir
        filepath = write_test_file(dir, TESTFILE_CONTENT)
        result = run_jetls_test(["--json", filepath, "pass"])
        @test result.exitcode == 0
        json = JSON3.read(result.stdout)
        @test json.stats.n_passed == 1
        @test json.stats.n_failed == 0
    end
end

function active_project_testfile(expected::String)
    return """
        using Test
        @testset "active project" begin
            @test realpath(Base.active_project()) == realpath($(repr(expected)))
        end
        """
end

@testset "test environment" begin
    mktempdir() do dir
        detected = joinpath(dir, "Project.toml")
        touch(detected)
        filepath = write_test_file(dir, active_project_testfile(detected))
        result = run_jetls_test([filepath])
        @test result.exitcode == 0
    end

    mktempdir() do dir
        touch(joinpath(dir, "Project.toml"))
        other = mkdir(joinpath(dir, "other"))
        expected = touch(joinpath(other, "Project.toml"))
        filepath = write_test_file(dir, active_project_testfile(expected))
        result = run_jetls_test(["--project=$other", filepath])
        @test result.exitcode == 0

        # `--project` also overrides the environment configured in `julia_args`
        write(joinpath(dir, ".JETLSConfig.toml"), """
            [testrunner]
            julia_args = ["--project=$(escape_string(dir))"]
            """)
        result = run_jetls_test(["--root=$dir", "--project=$other", filepath])
        @test result.exitcode == 0
    end
end

@testset "configuration" begin
    mktempdir() do dir
        filepath = write_test_file(dir, """
            using Test
            @testset "env" begin
                @test get(ENV, "JETLS_TEST_CONFIGURED", nothing) == "yes"
            end
            """)
        write(joinpath(dir, ".JETLSConfig.toml"), """
            [testrunner]
            env = { JETLS_TEST_CONFIGURED = "yes" }
            """)

        result = run_jetls_test(["--root=$dir", filepath])
        @test result.exitcode == 0

        # without `--root`, the configuration is looked up in the current directory
        result = cd(() -> run_jetls_test([filepath]), mktempdir())
        @test result.exitcode == 1
    end
end

@testset "--julia" begin
    mktempdir() do dir
        filepath = write_test_file(dir, TESTFILE_CONTENT)

        result = run_jetls_test(["--julia=$JULIA_CMD", filepath, "pass"])
        @test result.exitcode == 0

        result = run_jetls_test(["--julia=$(joinpath(dir, "nonexistent-julia"))", filepath])
        @test result.exitcode == 1
        @test occursin("is not found", result.stderr)
    end
end

function run_jetls_test_process(cmd::Cmd)
    stdout_buf = IOBuffer()
    stderr_buf = IOBuffer()
    proc = run(pipeline(ignorestatus(cmd); stdout=stdout_buf, stderr=stderr_buf); wait=true)
    return (;
        exitcode = proc.exitcode,
        stdout = String(take!(stdout_buf)),
        stderr = String(take!(stderr_buf)),
    )
end

@testset "process boundary" begin
    mktempdir() do dir
        filepath = write_test_file(dir, TESTFILE_CONTENT)

        # `-v` is the verbose option of TestRunner.jl, not the version option of `jetls`
        result = run_jetls_test_process(
            `$JULIA_CMD --startup-file=no --project=$JETLS_DIR -m JETLS test -v $filepath pass`)
        @test result.exitcode == 0
        @test occursin("Running Tests", result.stdout)
        @test !occursin("jetls version", result.stdout)
        # `--project` that loads JETLS is not reported
        @test !occursin("does not apply to the tests", result.stderr)

        # Like the `jetls` app shim, load JETLS through `JULIA_LOAD_PATH`, so that the
        # `--project` given to Julia does not load JETLS
        cmd = `$JULIA_CMD --startup-file=no --project=$dir -m JETLS test $filepath pass`
        result = run_jetls_test_process(addenv(cmd, "JULIA_LOAD_PATH" => JETLS_DIR))
        @test result.exitcode == 0
        @test occursin("does not apply to the tests", result.stderr)
    end
end

end # module test_jetls_test
