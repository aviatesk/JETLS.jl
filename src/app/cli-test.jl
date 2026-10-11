const test_help_message = """
    jetls test - Run tests with the TestRunner.jl bundled with JETLS

    Usage: jetls test [options] <path> [patterns...]

    Runs the tests in <path> that match any of the patterns, or all the tests in
    <path> without patterns, in a separate Julia process. The tests run in the
    nearest environment of <path>, with the `[testrunner]` configuration of
    `.JETLSConfig.toml` applied.

    Patterns:
      my tests                 The @testsets named exactly "my tests"
      r"regex"                 The @testsets whose names match the regex
      :(expr)                  The code matching the expression pattern
      L10                      The code on line 10
      L10:20                   The code on lines 10-20

    Quote patterns so that the shell passes them as they are, e.g. 'r"^basic"'.

    Options:
      --help, -h               Show this help message
      --julia=<path>           Julia executable to run the tests with
                               (default: the one selected by `[testrunner] env`,
                               otherwise the Julia running JETLS)
      --project=<path>         Project environment of the tests
                               (default: the nearest Project.toml of <path>)
      --root=<path>            Set the root path for configuration
                               (default: the current working directory)

    Other options are passed to TestRunner.jl, e.g.:
      --verbose, -v            Show verbose output
      --json                   Output results in JSON format
      --filter-lines=<lines>   Run only the matches overlapping the given lines,
                               e.g. 1,5,10:20 (short form: -f=<lines>)
      --read-stdin             Read source for <path> from stdin instead of disk

    Exit codes:
      0  All the tests passed
      1  Some tests failed or errored, or invalid arguments

    Examples:
      jetls test test/runtests.jl
      jetls test test/runtests.jl "selected tests"
      jetls test test/runtests.jl L15:25
      jetls test test/runtests.jl ':(@test length(xs) == 1)'
      jetls test --verbose test/runtests.jl 'r"^basic"'
      jetls test --julia=/path/to/julia-nightly test/runtests.jl
      jetls test --project=test test/runtests.jl "my tests"
    """

function run_test(args::Vector{String})
    julia_exe = project = root_path_opt = nothing
    testrunner_args = String[]
    for arg in args
        if arg in ("-h", "--help")
            print(stdout, test_help_message)
            return 0
        elseif startswith(arg, "--julia=")
            julia_exe = arg[9:end]
        elseif startswith(arg, "--project=")
            project = arg[11:end]
        elseif startswith(arg, "--root=")
            root_path_opt = arg[8:end]
        else
            push!(testrunner_args, arg)
        end
    end

    path_index = @something findfirst(arg -> !startswith(arg, "-"), testrunner_args) begin
        @error "No test file given (see `jetls test --help`)"
        return 1
    end
    filepath = testrunner_args[path_index]

    # Without `@` in `LOAD_PATH`, as in the `jetls` app shim, the `--project` given to Julia
    # neither loads JETLS nor reaches the test process.
    if Base.JLOptions().project != C_NULL && "@" ∉ LOAD_PATH
        @warn "`--project` given to Julia before `--` does not apply to the tests; " *
            "use `jetls test --project=<path>` to select their environment"
    end

    root_path = root_path_opt !== nothing ? abspath(root_path_opt) : pwd()
    server = start_cli_server(root_path)
    launcher = testrunner_launcher(server; julia_exe)
    if launcher isa String
        @error launcher
        return 1
    end
    if project !== nothing
        # Put after `julia_args` so that it also overrides the environment configured there
        launcher = TestRunnerLauncher(
            launcher.julia, String[launcher.julia_args; "--project=$project"], launcher.env)
    end
    cmd = testrunner_cmd(launcher, find_env_path(abspath(filepath)), `$testrunner_args`)
    proc = run(ignorestatus(cmd))
    return proc.termsignal == 0 ? proc.exitcode : 1
end
