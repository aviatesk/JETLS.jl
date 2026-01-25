using Sockets: Sockets

const serve_help_message = """
    jetls serve - Start language server for editor integration

    Starts JETLS as an LSP server for use with LSP client editors.
    By default, communicates via stdin/stdout.

    Usage: jetls serve [OPTIONS]

    Options:
      --stdio                     Use standard input/output (default)
      --pipe-connect=<path>       Connect to client's Unix domain socket/named pipe
      --pipe-listen=<path>        Listen on Unix domain socket/named pipe
      --socket=<port>             Listen on TCP socket
      --clientProcessId=<pid>     Monitor client process (enables crash detection)
      --help, -h                  Show this help message

    Examples:
      jetls serve
      jetls serve --pipe-listen=/tmp/jetls.sock
      jetls serve --socket=8080
    """

const help_message = """
    JETLS - A Julia language server with runtime-aware static analysis,
    powered by JET.jl, JuliaSyntax.jl, and JuliaLowering.jl

    VERSION: $JETLS_VERSION

    Usage: jetls [COMMAND] [OPTIONS]

    Commands:
      check <file|dir>...         Run diagnostics on Julia files
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
      jetls check src/main.jl
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
            args = args[2:end]
        elseif first_arg in ("-h", "--help", "help", "-v", "--version", "version")
            # Don't warn for help/version flags
        else
            @warn "Running `jetls` without a subcommand is deprecated and may be removed in a future release. Use `jetls serve` instead."
        end
    else
        @warn "Running `jetls` without a subcommand is deprecated and may be removed in a future release. Use `jetls serve` instead."
    end

    pipe_connect_path = pipe_listen_path = socket_port = client_process_id = nothing

    i = 1
    while i <= length(args)
        arg = args[i]
        if occursin(r"^(?:-h|--help|help)$", arg)
            print(stdout, help_message)
            return Cint(0)
        elseif occursin(r"^(?:--)?stdio$", arg)
        elseif occursin(r"^(?:--)?pipe-connect$", arg)
            if i < length(args)
                pipe_connect_path = args[i+1]
                i += 1
            else
                @error "--pipe-connect requires a path argument: use --pipe-connect=<path> or --pipe-connect <path>"
                return Cint(1)
            end
        elseif (m = match(r"^--pipe-connect=(.+)$", arg); !isnothing(m))
            pipe_connect_path = m.captures[1]
        elseif occursin(r"^(?:--)?pipe-listen$", arg)
            if i < length(args)
                pipe_listen_path = args[i+1]
                i += 1
            else
                @error "--pipe-listen requires a path argument: use --pipe-listen=<path> or --pipe-listen <path>"
                return Cint(1)
            end
        elseif (m = match(r"^--pipe-listen=(.+)$", arg); !isnothing(m))
            pipe_listen_path = m.captures[1]
        elseif occursin(r"^(?:--)?socket$", arg)
            if i < length(args)
                socket_port = tryparse(Int, args[i+1])
                i += 1
                @goto check_socket_port
            else
                @error "--socket requires a port argument: use --socket=<port> or --socket <port>"
                return Cint(1)
            end
        elseif (m = match(r"^--socket=(\d+)$", arg); !isnothing(m))
            socket_port = tryparse(Int, m.captures[1])
            @label check_socket_port
            if isnothing(socket_port)
                @error "Invalid port number for --socket (must be a valid integer)"
                return Cint(1)
            end
        elseif occursin(r"^--clientProcessId$", arg)
            if i < length(args)
                client_process_id = tryparse(Int, args[i+1])
                i += 1
                @goto check_client_process_id
            else
                @error "--clientProcessId requires a process ID argument: use --clientProcessId=<pid> or --clientProcessId <pid>"
                return Cint(1)
            end
        elseif (m = match(r"^--clientProcessId=(\d+)$", arg); !isnothing(m))
            client_process_id = tryparse(Int, m.captures[1])
            @label check_client_process_id
            if isnothing(client_process_id)
                @error "Invalid process ID for --clientProcessId (must be a valid integer)"
                return Cint(1)
            end
        else
            @error "Unknown CLI argument" arg
            return Cint(1)
        end
        i += 1
    end

    isnothing(client_process_id) ||
        @info "Client process ID provided via command line" client_process_id

    local endpoint::Endpoint
    if !isnothing(pipe_connect_path)
        try
            pipe_type = Sys.iswindows() ? "Windows named pipe" : "Unix domain socket"
            conn = Sockets.connect(pipe_connect_path)
            endpoint = Endpoint(conn, conn)
            @info "Connected to $pipe_type" pipe_connect_path
        catch e
            @error "Failed to connect to pipe" pipe_connect_path
            Base.display_error(stderr, e, catch_backtrace())
            return Cint(1)
        end
    elseif !isnothing(pipe_listen_path)
        try
            pipe_type = Sys.iswindows() ? "Windows named pipe" : "Unix domain socket"
            server_socket = Sockets.listen(pipe_listen_path)
            println(stdout, "<JETLS-PIPE-READY>$pipe_listen_path</JETLS-PIPE-READY>")
            @info "Waiting for connection on $pipe_type" pipe_listen_path
            conn = Sockets.accept(server_socket)
            endpoint = Endpoint(conn, conn)
            @info "Accepted connection on $pipe_type"
        catch e
            @error "Failed to listen on pipe" pipe_listen_path
            Base.display_error(stderr, e, catch_backtrace())
            return Cint(1)
        end
    elseif !isnothing(socket_port)
        try
            server_socket = Sockets.listen(socket_port)
            actual_port = Sockets.getsockname(server_socket)[2]
            println(stdout, "<JETLS-PORT>$actual_port</JETLS-PORT>")
            @info "Waiting for connection on port" actual_port
            conn = Sockets.accept(server_socket)
            endpoint = Endpoint(conn, conn)
            @info "Connected via TCP socket" actual_port
        catch e
            @error "Failed to create socket connection" socket_port
            Base.display_error(stderr, e, catch_backtrace())
            return Cint(1)
        end
    else # use stdio as the communication channel
        endpoint = Endpoint(stdin, stdout)
        @info "Using stdio for communication"
    end

    show_setup_info("Running JETLS with the following setup:")

    old_LOAD_PATH = copy(LOAD_PATH)
    try
        # HACK: Set `LOAD_PATH` to the same state as during normal Julia script execution.
        # JETLS internally uses `Pkg.activate` on user package environments and may actually load them,
        # so this replacement is necessary.
        empty!(LOAD_PATH)
        push!(LOAD_PATH, "@", "@v$(VERSION.major).$(VERSION.minor)", "@stdlib")

        if JETLS_DEV_MODE
            global currently_running
            currently_running = server = Server(endpoint) do s::Symbol, x
                @nospecialize x
                # allow Revise to apply changes with the dev mode enabled
                if s === :received
                    if !(x isa ShutdownRequest || x isa ExitNotification)
                        Revise.revise()
                    end
                end
            end
            runserver_task = let client_process_id=client_process_id
                Threads.@spawn :interactive runserver(server; client_process_id)
            end
        else
            runserver_task = let endpoint=endpoint, client_process_id=client_process_id
                Threads.@spawn :interactive runserver(endpoint; client_process_id)
            end
        end
        exit_code = fetch(runserver_task)
        @info "JETLS server stopped" exit_code
        return exit_code
    finally
        append!(LOAD_PATH, old_LOAD_PATH)
    end
end
