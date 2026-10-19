module JETLS

# `TestRunner` is a direct dependency of this package without being loaded by it, since
# `JETLSCore` runs tests with `julia -m TestRunner` in the environment of this package.

const JETLS_VERSION = let
    version_file = joinpath(dirname(@__DIR__), "JETLS_VERSION")
    include_dependency(version_file)
    isfile(version_file) ? String(strip(read(version_file, String))) : "unknown"
end

const help_message = """
    JETLS - A Julia language server with runtime-aware static analysis,
    powered by JET.jl, JuliaSyntax.jl, and JuliaLowering.jl

    VERSION: $JETLS_VERSION

    Usage: jetls <COMMAND> [OPTIONS]

    Commands:
      serve                       Start language server
      check [<path>...]           Run diagnostics on Julia files
      test <path> [<pattern>...]  Run tests with TestRunner.jl
      schema                      Print JSON schema for configuration
      version                     Show version information

    Common options:
      --version, -v               Show version information
      --help, -h                  Show this help message

    Run 'jetls <command> --help' for command-specific options.

    Examples:
      jetls serve --pipe-listen=/tmp/jetls.sock
      jetls check src/SomePkg.jl
      jetls test test/runtests.jl "selected tests"
      jetls schema --settings
    """

const serve_help_message = """
    jetls serve - Start language server for editor integration

    Starts JETLS as an LSP server for use with LSP client editors.
    By default, communicates via stdin/stdout.

    Usage: jetls serve [OPTIONS]

    Options:
      --stdio                     Use standard input/output (default)
      --pipe-connect=<path>       Connect to client's Unix domain socket/named pipe
      --pipe=<path>               Alias for --pipe-connect (LSP client convention)
      --pipe-listen=<path>        Listen on Unix domain socket/named pipe
      --socket=<port>             Listen on TCP socket
      --clientProcessId=<pid>     Monitor client process (enables crash detection)
      --help, -h                  Show this help message

    Examples:
      jetls serve
      jetls serve --pipe-listen=/tmp/jetls.sock
      jetls serve --socket=8080
    """

const check_help_message = """
    jetls check - Run diagnostics on Julia files

    Analyzes Julia source files and reports errors, warnings, and suggestions.
    Useful for CI pipelines and command-line workflows.

    Usage: jetls check [OPTIONS] [<path>...]

    Arguments:
      <path>...                Julia files or package directories to check;
                               a package directory is checked via its src/<name>.jl
                               (default: the package at the root path)

    Options:
      --help, -h               Show this help message
      --quiet, -q              Suppress info and warning log messages
      --stdin-filename=<path>  Check the source read from stdin as if it were the
                               file at <path>, which does not need to exist
                               (default: an unsaved buffer shown as <stdin>)
      --exit-severity=<level>  Minimum severity to exit with error code 1
                               (error, warn, info, hint; default: warn)
      --show-severity=<level>  Minimum severity to display in output
                               (error, warn, info, hint; default: info)
      --root=<path>            Set the root path for configuration and relative paths
                               (default: the package directory if exactly one is
                               given, otherwise the current working directory)
      --context-lines=<n>      Number of context lines to show (default: 2)
      --progress=<mode>        Progress display mode (default: auto)
                               auto   - spinner if TTY, simple otherwise
                               full   - always show spinner
                               simple - one line per file
                               none   - no progress output

    Exit codes:
      0  No diagnostics at or above the exit severity level
      1  One or more diagnostics found, or invalid arguments

    Examples:
      jetls check
      jetls check /path/to/SomePkg
      jetls check src/SomePkg.jl
      jetls check . test/runtests.jl
      jetls check --root=/path/to/project src/SomePkg.jl
      jetls check --context-lines=0 src/SomePkg.jl
      jetls check --exit-severity=error src/SomePkg.jl
      jetls check --show-severity=warn src/SomePkg.jl
      jetls check --progress=none src/SomePkg.jl
      jetls check - <<< 'f(x) = undefined_name + x'
      sed 's/helper/helper2/g' src/utils.jl | jetls check --stdin-filename=src/utils.jl -
    """

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

const schema_help_message = """
    jetls schema - Print JSON schema for JETLS configuration

    Usage: jetls schema [--settings | --init-options | --config-toml]

    Options:
      --settings        Print the workspace settings schema
      --init-options    Print the initialization options schema
      --config-toml     Print the .JETLSConfig.toml configuration schema
      --help, -h        Show this help message

    Examples:
      jetls schema --config-toml    # .JETLSConfig.toml schema
      jetls schema --settings       # settings schema
      jetls schema --init-options   # initialization options schema
    """

function (@main)(args::Vector{String})::Cint
    command = isempty(args) ? "" : first(args)
    command_args = args[2:end]
    if command in ("-v", "--version", "version")
        println(stdout, "jetls version $JETLS_VERSION, julia version $VERSION")
        return 0
    elseif command == "serve"
        help_requested(command_args) && return print_help(serve_help_message)
    elseif command == "check"
        help_requested(command_args) && return print_help(check_help_message)
    elseif command == "test"
        # `help` is a test pattern for `jetls test`
        help_requested(command_args, ("-h", "--help")) && return print_help(test_help_message)
    elseif command == "schema"
        return run_schema(command_args)
    else
        return print_help(help_message)
    end
    return run_core_command(command, command_args)
end

help_requested(args::Vector{String}, flags::Tuple{Vararg{String}}=("-h", "--help", "help")) =
    any(in(flags), args)

function print_help(message::String)
    print(stdout, message)
    return 0
end

function run_schema(args::Vector{String}, out::IO=stdout)
    if isempty(args) || args[1] in ("-h", "--help", "help")
        print(out, schema_help_message)
        return 0
    end

    schema_map = Dict(
        "--settings"     => "settings.schema.json",
        "--init-options" => "init-options.schema.json",
        "--config-toml"  => "config-toml.schema.json",
    )

    schema_dir = joinpath(dirname(@__DIR__), "schemas")
    for arg in args
        filename = get(schema_map, arg, nothing)
        if isnothing(filename)
            @error "Unknown schema option" arg
            print(stderr, schema_help_message)
            return 1
        end
        path = joinpath(schema_dir, filename)
        print(out, read(path, String))
    end
    return 0
end

# Load `JETLSCore` only here to keep the commands handled above fast
function run_core_command(command::String, args::Vector{String})
    JETLSCore = Base.require(@__MODULE__, :JETLSCore)
    return @invokelatest JETLSCore.run_command(command, args, JETLS_VERSION, @__MODULE__)
end

precompile(main, (Vector{String},))

end # module JETLS
