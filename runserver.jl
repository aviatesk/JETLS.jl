module var"##__JETLSEntryPoint__##"

@info "Running JETLS with Julia version" VERSION

using Pkg
using Sockets

let old_env = Pkg.project().path
    try
        Pkg.activate(@__DIR__; io=devnull)

        # TODO load Revise only when `JETLS_DEV_MODE` is true
        try
            # load Revise with JuliaInterpreter used by JETLS
            using Revise
        catch err
            @warn "Revise not found"
        end

        @info "Loading JETLS..."

        try
            using JETLS
        catch
            @error "JETLS not found"
            exit(1)
        end
    finally
        Pkg.activate(old_env; io=devnull)
    end
end

function show_help()
    println(stdout, """
    JETLS - A Julia language server providing advanced static analysis and seamless
    runtime integration. Powered by JET.jl, JuliaSyntax.jl, and JuliaLowering.jl.

    Usage: julia runserver.jl [OPTIONS]

    Communication channel options (choose one, default: --stdio):
      --stdio                  Use standard input/output
      --pipe=<path>            Use named pipe (Windows) or Unix domain socket
      --socket=<port>          Use TCP socket on specified port

    Options:
      --clientProcessId=<pid>  Monitor client process (server shuts down if client exits)
      --help, -h               Show this help message

    Examples:
      julia runserver.jl
      julia runserver.jl --socket=8080
      julia runserver.jl --pipe=/tmp/jetls.sock --clientProcessId=12345
    """)
end

function (@main)(args::Vector{String})::Cint
    pipe_name = socket_port = client_process_id = nothing
    help_requested = false

    i = 1
    while i <= length(args)
        arg = args[i]
        if occursin(r"^(?:-h|--help|help)$", arg)
            show_help()
            return Cint(0)
        elseif occursin(r"^(?:--)?stdio$", arg)
        elseif occursin(r"^(?:--)?pipe$", arg)
            socket_port = nothing
            if i < length(args)
                pipe_name = args[i+1]
                i += 1
            else
                @error "--pipe requires a path argument: use --pipe=<path> or --pipe <path>"
                return Cint(1)
            end
        elseif (m = match(r"^--pipe=(.+)$", arg); !isnothing(m))
            pipe_name = m.captures[1]
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

    # Create endpoint based on communication channel
    if !isnothing(pipe_name)
        # Try to connect to client-created socket first, then fallback to creating our own
        try
            pipe_type = Sys.iswindows() ? "Windows named pipe" : "Unix domain socket"
            # Most LSP clients expect server to create the socket, but VSCode extension creates it
            # Try connecting first (for VSCode), fallback to listen/accept (for other clients).
            try
                conn = connect(pipe_name)
                endpoint = LSEndpoint(conn, conn)
                @info "Connected to existing $pipe_type" pipe_name
            catch
                # Connection failed - client expects us to create the socket
                @info "No existing socket found, creating server socket: $pipe_name"
                server_socket = listen(pipe_name)
                @info "Waiting for connection on $pipe_type: $pipe_name"
                conn = accept(server_socket)
                endpoint = LSEndpoint(conn, conn)
                @info "Accepted connection on $pipe_type"
            end
        catch e
            @error "Failed to create pipe/socket connection" pipe_name
            Base.display_error(stderr, e, catch_backtrace())
            return Cint(1)
        end
    elseif !isnothing(socket_port)
        try
            server_socket = listen(socket_port)
            actual_port = getsockname(server_socket)[2]
            println(stdout, "<JETLS-PORT>$actual_port</JETLS-PORT>")
            @info "Waiting for connection on port" actual_port
            conn = accept(server_socket)
            endpoint = LSEndpoint(conn, conn)
            @info "Connected via TCP socket" actual_port
        catch e
            @error "Failed to create socket connection" socket_port
            Base.display_error(stderr, e, catch_backtrace())
            return Cint(1)
        end
    else # use stdio as the communication channel
        endpoint = LSEndpoint(stdin, stdout)
        @info "Using stdio for communication"
    end

    if JETLS.JETLS_DEV_MODE
        server = Server(endpoint) do s::Symbol, x
            @nospecialize x
            # allow Revise to apply changes with the dev mode enabled
            if s === :received
                if !(x isa JETLS.ShutdownRequest || x isa JETLS.ExitNotification)
                    Revise.revise()
                end
            end
        end
        JETLS.currently_running = server
        t = Threads.@spawn :interactive runserver(server)
    else
        t = Threads.@spawn :interactive runserver(endpoint)
    end
    res = fetch(t)
    @info "JETLS server stopped" res.exit_code
    return res.exit_code
end

end # module var"##__JETLSEntryPoint__##"

using .var"##__JETLSEntryPoint__##": main
