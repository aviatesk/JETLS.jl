const help_message = """
    JETLS - A Julia language server with runtime-aware static analysis,
    powered by JET.jl, JuliaSyntax.jl, and JuliaLowering.jl

    VERSION: $JETLS_VERSION

    Usage: jetls <COMMAND> [OPTIONS]

    Commands:
      serve                       Start language server (default)
      check <file>...             Run diagnostics on Julia files
      schema                      Print JSON schema for configuration
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
      jetls serve --socket=8080
      jetls check src/SomePkg.jl
      jetls check --root=/path/to/project src/
      jetls schema --settings
    """

@doc help_message
function (@main)(args::Vector{String})::Cint
    if any(arg -> arg in ("-v", "--version", "version"), args)
        println(stdout, "JETLS version $JETLS_VERSION")
        return 0
    end

    if !isempty(args)
        first_arg = args[1]
        if first_arg == "check"
            if length(args) >= 2 && args[2] in ("-h", "--help", "help")
                print(stdout, check_help_message)
                return 0
            end
            return run_check(args[2:end])
        elseif first_arg == "schema"
            return run_schema(args[2:end])
        elseif first_arg == "serve"
            if length(args) >= 2 && args[2] in ("-h", "--help", "help")
                print(stdout, serve_help_message)
                return 0
            end
            return run_serve(args[2:end])
        end
    end
    print(stdout, help_message)
    return 0
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
