module test_jetls_schema

"""
Test file for exercising the `jetls schema` command.

This test calls `JETLS.run_schema` directly for behavior coverage and uses actual
`julia -m JETLS schema` processes for process-boundary smoke tests. It verifies:

1. Each schema option prints valid JSON to stdout
2. Help output is shown with no arguments or `-h`/`--help`
3. Unknown options exit with non-zero code

To run this test independently:
    julia --startup-file=no --project=./test ./test/app/test_jetls_schema.jl
"""

using Test
using JETLS

const JULIA_CMD = normpath(Sys.BINDIR, "julia")
const JETLS_DIR = pkgdir(JETLS)

function run_jetls_schema(args::Vector{String})
    stdout_buf = IOBuffer()
    return mktemp() do stderr_path, stderr_io
        exitcode = redirect_stderr(stderr_io) do
            JETLS.run_schema(args, stdout_buf)
        end
        flush(stderr_io)
        return (;
            exitcode,
            stdout = String(take!(stdout_buf)),
            stderr = read(stderr_path, String),
        )
    end
end

function run_jetls_schema_process(args::Vector{String})
    cmd_args = String[
        JULIA_CMD,
        "--startup-file=no",
        "--project=$JETLS_DIR",
        "-m",
        "JETLS",
        "schema",
    ]
    append!(cmd_args, args)
    cmd = ignorestatus(Cmd(cmd_args))
    stdout_buf = IOBuffer()
    stderr_buf = IOBuffer()
    proc = run(pipeline(cmd; stdout=stdout_buf, stderr=stderr_buf); wait=true)
    return (;
        exitcode = proc.exitcode,
        stdout = String(take!(stdout_buf)),
        stderr = String(take!(stderr_buf)),
    )
end

@testset "process boundary" begin
    let result = run_jetls_schema_process(["--settings"])
        @test result.exitcode == 0
        @test startswith(result.stdout, "{")
    end
    let result = run_jetls_schema_process(["--unknown"])
        @test result.exitcode == 1
        @test occursin("jetls schema", result.stderr)
    end
end

@testset "schema output" begin
    for name in ("--settings", "--init-options", "--config-toml")
        let result = run_jetls_schema([name])
            @test result.exitcode == 0
            @test startswith(result.stdout, "{")
            @test endswith(strip(result.stdout), "}")
        end
    end
end

@testset "help" begin
    let result = run_jetls_schema(String[])
        @test result.exitcode == 0
        @test occursin("jetls schema", result.stdout)
    end

    for flag in ("-h", "--help")
        let result = run_jetls_schema([flag])
            @test result.exitcode == 0
            @test occursin("jetls schema", result.stdout)
        end
    end
end

@testset "invalid arguments" begin
    let result = run_jetls_schema(["--unknown"])
        @test result.exitcode == 1
    end
end

end # module test_jetls_schema
