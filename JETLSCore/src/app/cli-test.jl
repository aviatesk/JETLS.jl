function run_test(args::Vector{String})
    julia_exe = project = root_path_opt = nothing
    testrunner_args = String[]
    for arg in args
        if startswith(arg, "--julia=")
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
