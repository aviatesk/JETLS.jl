const help_message = """
    JETLS - A Julia language server with runtime-aware static analysis,
    powered by JET.jl, JuliaSyntax.jl, and JuliaLowering.jl

    VERSION: $JETLS_VERSION

    Usage: jetls [COMMAND] [OPTIONS]

    Commands:
      check <file>...             Run diagnostics on Julia files
      serve                       Start language server (default)
      version                     Show version information

    Check options (for 'check' command):
      --root=<path>               Set the root path for configuration (default: pwd)
      --context-lines=<n>         Number of context lines to show (default: 2)
      --exit-severity=<level>     Minimum severity for error exit (default: warn)
      --show-severity=<level>     Minimum severity to display (default: hint)

    Server options (for 'serve' command):
      --stdio                     Use standard input/output (default)
      --pipe-connect=<path>       Connect to client's Unix domain socket/named pipe
      --pipe-listen=<path>        Listen on Unix domain socket/named pipe
      --socket=<port>             Listen on TCP socket
      --clientProcessId=<pid>     Monitor client process (enables crash detection)

    Common options:
      --version, -v               Show version information
      --help, -h                  Show this help message

    Examples:
      jetls serve --pipe-listen=/tmp/jetls.sock
      jetls --socket=8080
      jetls check src/SomePkg.jl
      jetls check --root=/path/to/project src/
    """

@doc help_message
function (@main)(args::Vector{String})::Cint
    if any(arg -> arg in ("-v", "--version", "version"), args)
        println(stdout, "JETLS version $JETLS_VERSION")
        return Cint(0)
    end

    if !isempty(args)
        first_arg = args[1]
        if first_arg == "check"
            if length(args) >= 2 && args[2] in ("-h", "--help", "help")
                print(stdout, check_help_message)
                return Cint(0)
            end
            return run_check(args[2:end])
        elseif first_arg == "serve"
            if length(args) >= 2 && args[2] in ("-h", "--help", "help")
                print(stdout, serve_help_message)
                return Cint(0)
            end
            return run_serve(args[2:end])
        elseif first_arg in ("-h", "--help", "help")
            print(stdout, help_message)
            return Cint(0)
        else
            @warn "Running `jetls` without a subcommand is deprecated and may be removed in a future release. Use `jetls serve` instead."
        end
    else
        @warn "Running `jetls` without a subcommand is deprecated and may be removed in a future release. Use `jetls serve` instead."
    end

    return run_serve(args)
end

# HACK: Set `LOAD_PATH` to the same state as during normal Julia script execution.
# JETLS internally uses `Pkg.activate` on user package environments and may actually load them,
# so this replacement is necessary.
macro with_cli_LOAD_PATH(ex)
    :(let old_LOAD_PATH = copy(LOAD_PATH)
        try
            empty!(LOAD_PATH)
            push!(LOAD_PATH, "@", "@v$(VERSION.major).$(VERSION.minor)", "@stdlib")
            $(esc(ex))
        finally
            empty!(LOAD_PATH)
            append!(LOAD_PATH, old_LOAD_PATH)
        end
    end)
end
