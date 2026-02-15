module test_jetls_check

"""
Test file for exercising the `jetls check` command.

This test spawns actual `julia -m JETLS check` processes and verifies:

1. Basic diagnostic output
2. CLI options (--exit-severity, --show-severity, --context-lines)
3. Configuration file (.JETLSConfig.toml) application

To run this test independently:
    julia --startup-file=no --project=./test ./test/app/test_jetls_check.jl
"""

using Test
using JETLS

const JULIA_CMD = normpath(Sys.BINDIR, "julia")
const JETLS_DIR = pkgdir(JETLS)

function run_jetls_check(
        args::Vector{String};
        root::Union{String,Nothing} = nothing,
        skip_analysis::Bool = true # Enabled for faster test execution (this file doesn't test functionalities that depend on full-analysis)
    )
    cmd_args = String[JULIA_CMD, "--startup-file=no", "--project=$JETLS_DIR", "-m", "JETLS", "check"]
    if root !== nothing
        push!(cmd_args, "--root=$root")
    end
    push!(cmd_args, "--progress=none")
    skip_analysis && push!(cmd_args, "--skip-full-analysis")
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

function write_test_file(dir::String, filename::String, content::String)
    filepath = joinpath(dir, filename)
    write(filepath, content)
    return filepath
end

function write_config_file(dir::String, content::String)
    filepath = joinpath(dir, ".JETLSConfig.toml")
    write(filepath, content)
    return filepath
end

@testset "basic functionality" begin
    mktempdir() do dir
        filepath = write_test_file(dir, "test.jl", """
            module TestModule
            function foo()
                x = 1
                return nothing
            end
            end
            """)

        result = run_jetls_check([filepath]; root=dir)
        @test occursin("lowering/unused-local", result.stdout)
        @test occursin("test.jl", result.stdout)

        # Relative path should be resolved relative to --root
        result = run_jetls_check(["test.jl"]; root=dir)
        @test occursin("lowering/unused-local", result.stdout)
        @test occursin("test.jl", result.stdout)
    end
end

@testset "--exit-severity" begin
    mktempdir() do dir
        # Create a file with info-level diagnostic (unused local)
        filepath = write_test_file(dir, "test.jl", """
            module TestModule
            function foo()
                x = 1
                return nothing
            end
            end
            """)

        # Default exit-severity is warn, so info diagnostic should not cause exit 1
        let result = run_jetls_check([filepath]; root=dir)
            @test result.exitcode == 0
            @test occursin("lowering/unused-local", result.stdout)
        end

        # With exit-severity=info, info diagnostic should cause exit 1
        let result = run_jetls_check(["--exit-severity=info", filepath]; root=dir)
            @test result.exitcode == 1
            @test occursin("lowering/unused-local", result.stdout)
        end
    end
end

@testset "--show-severity" begin
    mktempdir() do dir
        filepath = write_test_file(dir, "test.jl", """
            module TestModule
            function foo()
                x = 1
                return nothing
            end
            end
            """)

        # Default show-severity is hint, should show info diagnostic
        let result = run_jetls_check([filepath]; root=dir)
            @test occursin("lowering/unused-local", result.stdout)
        end

        # With show-severity=warn, info diagnostic should be hidden
        let result = run_jetls_check(["--show-severity=warn", filepath]; root=dir)
            @test !occursin("lowering/unused-local", result.stdout)
            @test occursin("No diagnostics found", result.stdout)
        end
    end
end

@testset "--context-lines" begin
    mktempdir() do dir
        filepath = write_test_file(dir, "test.jl", """
            module TestModule
            function foo()
                x = 1
                return nothing
            end
            end
            """)

        # With context-lines=0, should show minimal context
        let result = run_jetls_check(["--context-lines=0", filepath]; root=dir)
            @test occursin("lowering/unused-local", result.stdout)
            # Should not show "function foo()" line (which is context)
            lines = split(result.stdout, '\n')
            diagnostic_lines = filter(l -> occursin("x = 1", l), lines)
            @test !isempty(diagnostic_lines)
        end
    end
end

@testset "configuration file" begin
    mktempdir() do dir
        filepath = write_test_file(dir, "test.jl", """
            module TestModule
            function foo()
                x = 1
                return nothing
            end
            end
            """)

        # Without config, should show diagnostic
        let result = run_jetls_check([filepath]; root=dir)
            @test occursin("lowering/unused-local", result.stdout)
        end

        # With config to disable diagnostic
        write_config_file(dir, """
            [[diagnostic.patterns]]
            pattern = "lowering/unused-local"
            match_by = "code"
            match_type = "literal"
            severity = "off"
            """)
        let result = run_jetls_check([filepath]; root=dir)
            @test !occursin("lowering/unused-local", result.stdout)
            @test occursin("No diagnostics found", result.stdout)
        end
    end
end

@testset "multiple files" begin
    mktempdir() do dir
        file1 = write_test_file(dir, "file1.jl", """
            module File1
            function foo()
                x = 1
                return nothing
            end
            end
            """)
        file2 = write_test_file(dir, "file2.jl", """
            module File2
            function bar()
                y = 2
                return nothing
            end
            end
            """)

        result = run_jetls_check([file1, file2]; root=dir)
        @test occursin("file1.jl", result.stdout)
        @test occursin("file2.jl", result.stdout)
        @test occursin("Analyzed 2 files", result.stdout)
        @test occursin("Found 2 diagnostics in 2 files", result.stdout)
    end
end

@testset "invalid arguments" begin
    let result = run_jetls_check(["/nonexistent/path/file.jl"])
        @test result.exitcode == 1 || occursin("error", lowercase(result.stderr))
    end
    mktempdir() do dir
        filepath = write_test_file(dir, "test.jl", "x = 1")
        result = run_jetls_check(["--exit-severity=invalid", filepath]; root=dir)
        @test result.exitcode == 1
        @test occursin("Invalid value", result.stderr)
        result = run_jetls_check(["--show-severity=invalid", filepath]; root=dir)
        @test result.exitcode == 1
        @test occursin("Invalid value", result.stderr)
    end
end

end # module test_jetls_check
