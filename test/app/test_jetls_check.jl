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
using JETLS.LSP

const JULIA_CMD = normpath(Sys.BINDIR, "julia")
const JETLS_DIR = pkgdir(JETLS)

function build_check_args(
        args::Vector{String};
        root::Union{String,Nothing} = nothing,
        skip_analysis::Bool = true
    )
    check_args = String[]
    if root !== nothing
        push!(check_args, "--root=$root")
    end
    push!(check_args, "--progress=none")
    skip_analysis && push!(check_args, "--skip-full-analysis")
    append!(check_args, args)
    return check_args
end

function capture_jetls_check(f::Function)
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

function run_jetls_check(
        args::Vector{String};
        root::Union{String,Nothing} = nothing,
        skip_analysis::Bool = true
    )
    check_args = build_check_args(args; root, skip_analysis)
    return capture_jetls_check() do
        JETLS.run_check(check_args)
    end
end

function run_jetls_check_process(
        args::Vector{String};
        root::Union{String,Nothing} = nothing,
        skip_analysis::Bool = true
    )
    cmd_args = String[
        JULIA_CMD,
        "--startup-file=no",
        "--project=$JETLS_DIR",
        "-m",
        "JETLS",
        "check",
    ]
    append!(cmd_args, build_check_args(args; root, skip_analysis))
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

@testset "process boundary" begin
    mktempdir() do dir
        filepath = write_test_file(dir, "test.jl", """
            module TestModule
            function foo()
                x = 1
                return nothing
            end
            end
            """)

        let result = run_jetls_check_process([filepath]; root=dir)
            @test result.exitcode == 0
            @test occursin("lowering/unused-local", result.stdout)
            @test endswith(result.stdout, "\n\n# Check passed (--exit-severity=warn)\n")
        end
        let result = run_jetls_check_process(
                ["--exit-severity=info", filepath]; root=dir
            )
            @test result.exitcode == 1
            @test occursin("lowering/unused-local", result.stdout)
            @test endswith(result.stdout, "\n\n# Check failed (--exit-severity=info)\n")
        end
    end
end

@testset "analysis failure" begin
    mktempdir() do dir
        filepath = joinpath(dir, "missing.jl")
        result = run_jetls_check_process([filepath]; root=dir, skip_analysis=false)
        @test result.exitcode == 1
        @test occursin("missing.jl", result.stderr)
        @test !occursin("# Check ", result.stdout)
    end
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

@testset "multi-line diagnostic message rendering" begin
    mktempdir() do dir
        filepath = write_test_file(dir, "test.jl", "func(1, 2)\n")
        uri = JETLS.filepath2uri(filepath)
        message = "MethodError: no matching method found `func(::Int64, ::Int64)`\n\n" *
            "The function `func` exists.\n\nClosest candidates are:\n- `func(::Int64)`"
        diagnostic = Diagnostic(;
            range = Range(;
                start = Position(; line=0, character=0),
                var"end" = Position(; line=0, character=10)),
            severity = DiagnosticSeverity.Warning,
            message,
            code = "inference/method-error")
        uri2diagnostics = JETLS.URI2Diagnostics(uri => [diagnostic])
        result = capture_jetls_check() do
            JETLS.print_diagnostics(uri2diagnostics, dir, 1,
                DiagnosticSeverity.Error, DiagnosticSeverity.Information)
        end
        # the summary line carries the severity tag inline
        @test occursin("`func(::Int64, ::Int64)` [warn:inference/method-error]", result.stdout)
        # continuation lines form a separate `#`-prefixed block
        @test occursin("# The function `func` exists.", result.stdout)
        @test occursin("# Closest candidates are:", result.stdout)
        @test occursin("# - `func(::Int64)`", result.stdout)
        @test !occursin("exists. [warn", result.stdout)
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
            @test endswith(result.stdout, "\n\n# Check passed (--exit-severity=warn)\n")
        end

        # With exit-severity=info, info diagnostic should cause exit 1
        let result = run_jetls_check(["--exit-severity=info", filepath]; root=dir)
            @test result.exitcode == 1
            @test occursin("lowering/unused-local", result.stdout)
            @test endswith(result.stdout, "\n\n# Check failed (--exit-severity=info)\n")
        end

        for (level, canonical, exitcode, status) in (
                ("1", "error", 0, "passed"),
                ("warning", "warn", 0, "passed"),
                ("information", "info", 1, "failed"),
                ("4", "hint", 1, "failed"))
            result = run_jetls_check(["--exit-severity=$level", filepath]; root=dir)
            @test result.exitcode == exitcode
            @test endswith(result.stdout, "\n\n# Check $status (--exit-severity=$canonical)\n")
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

        let result = run_jetls_check([filepath]; root=dir)
            @test result.exitcode == 0
            @test occursin("lowering/unused-local", result.stdout)
            @test occursin("Found 1 diagnostic in 1 file (1 info)", result.stdout)
            @test !occursin("# Hidden:", result.stdout)
        end

        let result = run_jetls_check(["--show-severity=warn", filepath]; root=dir)
            @test result.exitcode == 0
            @test !occursin("lowering/unused-local", result.stdout)
            @test endswith(result.stdout,
                "# No diagnostics displayed\n" *
                "# Hidden: 1 info (use --show-severity=hint to show all)\n" *
                "# Check passed (--exit-severity=warn)\n")
        end

        for options in (["--exit-severity=info", "--show-severity=warn"],
                        ["--show-severity=warn", "--exit-severity=info"])
            result = run_jetls_check([options; filepath]; root=dir)
            @test result.exitcode == 1
            @test !occursin("lowering/unused-local", result.stdout)
            @test endswith(result.stdout,
                "# No diagnostics displayed\n" *
                "# Hidden: 1 info (use --show-severity=hint to show all)\n" *
                "# Check failed (--exit-severity=info)\n")
        end

        write_config_file(dir, """
            [[diagnostic.patterns]]
            pattern = "lowering/unused-local"
            match_by = "code"
            match_type = "literal"
            severity = "warn"
            """)
        let result = run_jetls_check(["--show-severity=error", filepath]; root=dir)
            @test result.exitcode == 1
            @test !occursin("lowering/unused-local", result.stdout)
            @test endswith(result.stdout,
                "# No diagnostics displayed\n" *
                "# Hidden: 1 warning (use --show-severity=hint to show all)\n" *
                "# Check failed (--exit-severity=warn)\n")
        end
    end

    mktempdir() do dir
        filepath = write_test_file(dir, "test.jl", """
            module TestModule
            function foo()
                @static if false
                    return 1
                else
                    return nothing
                end
            end
            end
            """)

        for (options, exit_severity) in (
                (String[], "warn"),
                (["--exit-severity=error"], "error"),
                (["--exit-severity=info"], "info"))
            result = run_jetls_check([options; filepath]; root=dir)
            @test result.exitcode == 0
            @test !occursin("lowering/inactive-code", result.stdout)
            @test endswith(result.stdout,
                "# No diagnostics displayed\n" *
                "# Hidden: 1 hint (use --show-severity=hint to show all)\n" *
                "# Check passed (--exit-severity=$exit_severity)\n")
        end

        let result = run_jetls_check(["--show-severity=hint", filepath]; root=dir)
            @test result.exitcode == 0
            @test occursin("lowering/inactive-code", result.stdout)
            @test occursin("Found 1 diagnostic in 1 file (1 hint)", result.stdout)
            @test !occursin("# Hidden:", result.stdout)
        end

        let result = run_jetls_check(["--exit-severity=hint", filepath]; root=dir)
            @test result.exitcode == 1
            @test !occursin("lowering/inactive-code", result.stdout)
            @test endswith(result.stdout,
                "# No diagnostics displayed\n" *
                "# Hidden: 1 hint (use --show-severity=hint to show all)\n" *
                "# Check failed (--exit-severity=hint)\n")
        end

        for options in (["--exit-severity=hint", "--show-severity=info"],
                        ["--show-severity=info", "--exit-severity=hint"])
            result = run_jetls_check([options; filepath]; root=dir)
            @test result.exitcode == 1
            @test !occursin("lowering/inactive-code", result.stdout)
            @test endswith(result.stdout,
                "# No diagnostics displayed\n" *
                "# Hidden: 1 hint (use --show-severity=hint to show all)\n" *
                "# Check failed (--exit-severity=hint)\n")
        end
    end

    mktempdir() do dir
        filepath = write_test_file(dir, "test.jl", "module TestModule\nend\n")
        for (options, exit_severity) in (
                (String[], "warn"),
                (["--show-severity=error"], "warn"),
                (["--exit-severity=hint"], "hint"))
            result = run_jetls_check([options; filepath]; root=dir)
            @test result.exitcode == 0
            @test endswith(result.stdout, "# No diagnostics found\n# Check passed (--exit-severity=$exit_severity)\n")
        end
    end
end

@testset "diagnostic statistics" begin
    mktempdir() do dir
        range = Range(;
            start = Position(; line=0, character=0),
            var"end" = Position(; line=0, character=1))
        uri2diagnostics = JETLS.URI2Diagnostics()
        for (filename, severities) in (
                ("warnings.jl", (DiagnosticSeverity.Error, DiagnosticSeverity.Warning, DiagnosticSeverity.Warning)),
                ("hints.jl", (DiagnosticSeverity.Information, DiagnosticSeverity.Information, DiagnosticSeverity.Hint, DiagnosticSeverity.Hint, DiagnosticSeverity.Hint)))
            uri2diagnostics[JETLS.filepath2uri(joinpath(dir, filename))] =
                Diagnostic[
                    Diagnostic(; range, severity, message="Diagnostic $i")
                    for (i, severity) in enumerate(severities)]
        end

        for (show_severity, summary) in (
                (DiagnosticSeverity.Error,
                    "# Found 1 diagnostic in 1 file (1 error)\n" *
                    "# Hidden: 2 warnings, 2 info, 3 hints (use --show-severity=hint to show all)\n\n"),
                (DiagnosticSeverity.Warning,
                    "# Found 3 diagnostics in 1 file (1 error, 2 warnings)\n" *
                    "# Hidden: 2 info, 3 hints (use --show-severity=hint to show all)\n\n"),
                (DiagnosticSeverity.Information,
                    "# Found 5 diagnostics in 2 files (1 error, 2 warnings, 2 info)\n" *
                    "# Hidden: 3 hints (use --show-severity=hint to show all)\n\n"),
                (DiagnosticSeverity.Hint,
                    "# Found 8 diagnostics in 2 files (1 error, 2 warnings, 2 info, 3 hints)\n\n"))
            result = capture_jetls_check() do
                JETLS.print_stats(uri2diagnostics, 2, 1.0, show_severity)
                return 0
            end
            @test endswith(result.stdout, summary)
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
            @test occursin("    x = 1\n#   ╙", result.stdout)
            @test !occursin("    x = 1\n#   └┘", result.stdout)
        end
    end

    mktempdir() do dir
        filepath = write_test_file(dir, "test.jl", """
            module TestModule
            function foo()
                xyz = 1
                return nothing
            end
            end
            """)

        let result = run_jetls_check(["--context-lines=0", filepath]; root=dir)
            @test occursin("lowering/unused-local", result.stdout)
            @test occursin("    xyz = 1\n#   └─┘", result.stdout)
            @test !occursin("    xyz = 1\n#   └──┘", result.stdout)
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

@testset "analysis override lowering context" begin
    mktempdir() do dir
        filepath = write_test_file(dir, "test.jl", "f(x) = @somereal x\n")
        write_config_file(dir, """
            [[initialization_options.analysis_overrides]]
            path = "test.jl"
            module_name = "JETLS"
            """)

        result = run_jetls_check([filepath]; root=dir)
        @test result.exitcode == 0
        @test !occursin("lowering/macro-expansion-error", result.stdout)
        @test occursin("No diagnostics found", result.stdout)
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

@testset "parse errors" begin
    mktempdir() do dir
        filepath = write_test_file(dir, "test.jl", "f(x) = println(x\n")
        result = run_jetls_check([filepath]; root=dir)
        @test result.exitcode == 1
        @test occursin("syntax/parse-error", result.stdout)
        @test occursin("test.jl", result.stdout)
        @test occursin("Found 1 diagnostic in 1 file", result.stdout)
        @test endswith(result.stdout, "\n\n# Check failed (--exit-severity=warn)\n")
    end
end

@testset "invalid arguments" begin
    let result = run_jetls_check(["/nonexistent/path/file.jl"])
        @test result.exitcode == 1 || occursin("error", lowercase(result.stderr))
        @test !occursin("# Check ", result.stdout)
    end
    mktempdir() do dir
        filepath = write_test_file(dir, "test.jl", "x = 1")
        result = run_jetls_check(["--exit-severity=invalid", filepath]; root=dir)
        @test result.exitcode == 1
        @test occursin("Invalid value", result.stderr)
        @test !occursin("# Check ", result.stdout)
        result = run_jetls_check(["--show-severity=invalid", filepath]; root=dir)
        @test result.exitcode == 1
        @test occursin("Invalid value", result.stderr)
        @test !occursin("# Check ", result.stdout)
    end
end

end # module test_jetls_check
