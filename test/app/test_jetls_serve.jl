module test_jetls_serve

"""
Test file for exercising the `jetls` executable app with raw JSON communication.

This test calls the top-level app directly for help behavior. It also spawns
actual server processes using `julia -m JETLS` and communicates with them via
stdin/stdout using raw JSON-RPC messages, testing:

1. Server startup and basic lifecycle (initialize, shutdown, exit)
2. Process management and graceful termination

To run this test independently:
    julia --startup-file=no -e 'using Test; @testset "jetls serve" include("test/app/test_jetls_serve.jl")'
"""

using Test
using JETLS
using Sockets: Sockets

# Test configuration
const JULIA_CMD = normpath(Sys.BINDIR, "julia")
const JETLS_DIR = pkgdir(JETLS)

function withserverprocess(f)
    cmd = `$JULIA_CMD --project=$JETLS_DIR -m JETLS serve`
    proc = open(cmd; write=true, read=true)
    try
        return f(proc)
    finally
        if !process_exited(proc)
            @error "Server process did not exit gracefully, killing it"
            kill(proc)
        end
    end
end

function with_timeout(f, timeout, sth)
    elapsed = 0.0
    while true
        elapsed > timeout && error("Timeout waiting for " * sth)
        res = f(elapsed)
        if res !== nothing
            @info "Waited $sth" elapsed
            return res
        end
        sleep(1.0)
        elapsed += 1.0
    end
end

function write_lsp_message(io, message)
    response_utf8 = transcode(UInt8, message)
    var"Content-Length" = length(response_utf8)
    write(io, "Content-Length: $(var"Content-Length")\r\n\r\n")
    write(io, message)
    flush(io)
    return nothing
end

function read_lsp_message(io)
    # Read headers with timeout
    header_regex = r"Content-Length: (\d+)"
    var"Content-Length" = let
        line = readuntil(io, "\r\n\r\n") # XXX may block
        m = match(header_regex, line)
        if isnothing(m) || length(m.captures) ≠ 1
            error("Failed to parse `Content-Length` header")
        end
        other = replace(line, header_regex=>"")
        if !isempty(other)
            @warn "Found unexpected output from the server process" other
        end
        parse(Int, only(m.captures))
    end
    return String(read(io, var"Content-Length"))
end

function read_lsp_response(io, id::Int)
    preceding_messages = String[]
    id_marker = "\"id\":$id"
    while true
        message = read_lsp_message(io)
        if occursin(id_marker, message)
            return (; response=message, preceding_messages)
        end
        push!(preceding_messages, message)
    end
end

const DEFAULT_TIMEOUT = 10
const STARTUP_TIMEOUT = 60

function run_jetls_app(args::Vector{String})
    return mktemp() do stdout_path, stdout_io
        exitcode = redirect_stdout(stdout_io) do
            Int(JETLS.main(args))
        end
        flush(stdout_io)
        return (; exitcode, stdout=read(stdout_path, String))
    end
end

@testset "jetls without subcommand shows help" begin
    for args in (String[], ["--stdio"], ["--socket=8080"])
        let result = run_jetls_app(args)
            @test result.exitcode == 0
            @test occursin("Usage: jetls <COMMAND>", result.stdout)
            @test occursin("jetls serve", result.stdout)
        end
    end
end

# test a very simple, normal server lifecycle
withserverprocess() do proc; mktempdir() do root_dir
    # Send initialization request
    initialize_msg = """{
        "jsonrpc": "2.0",
        "id": 1,
        "method": "initialize",
        "params": {
            "processId": $(getpid()),
            "capabilities": {},
            "workspaceFolders": [{
                "uri": "$(JETLS.LSP.URIs2.filepath2uri(root_dir))",
                "name": "test-workspace"
            }]
        }
    }"""
    write_lsp_message(proc, initialize_msg)
    initialization = read_lsp_response(proc, 1)
    @test isempty(initialization.preceding_messages)
    initialization_response = initialization.response
    @test occursin("\"id\":1", initialization_response)
    @test occursin("\"result\"", initialization_response)
    # @info "Server responded to initialize request successfully"

    # Send shutdown request
    shutdown_msg = """{
        "jsonrpc": "2.0",
        "id": 2,
        "method": "shutdown",
        "params": null
    }"""
    write_lsp_message(proc, shutdown_msg)
    shutdown = read_lsp_response(proc, 2)
    @test isempty(shutdown.preceding_messages)
    shutdown_response = shutdown.response
    @test occursin("\"id\":2", shutdown_response)
    @test occursin("\"result\":null", shutdown_response)
    # @info "Server responded to shutdown request"

    # Send exit notification
    exit_msg = """{
        "jsonrpc": "2.0",
        "method": "exit",
        "params": null
    }"""
    write_lsp_message(proc, exit_msg)

    @test with_timeout(#=timeout=#DEFAULT_TIMEOUT, "server process to shutdown") do _
        process_running(proc) && return nothing
        return true
    end
    @test process_exited(proc) && proc.exitcode == 0
end; end

# test a very simple, abnormal server lifecycle
withserverprocess() do proc; mktempdir() do root_dir
    # Send initialization request
    initialize_msg = """{
        "jsonrpc": "2.0",
        "id": 1,
        "method": "initialize",
        "params": {
            "processId": $(getpid()),
            "capabilities": {},
            "workspaceFolders": [{
                "uri": "$(JETLS.LSP.URIs2.filepath2uri(root_dir))",
                "name": "test-workspace"
            }]
        }
    }"""
    write_lsp_message(proc, initialize_msg)
    initialization = read_lsp_response(proc, 1)
    @test isempty(initialization.preceding_messages)
    initialization_response = initialization.response
    @test occursin("\"id\":1", initialization_response)
    @test occursin("\"result\"", initialization_response)
    # @info "Server responded to initialize request successfully"

    # Send exit notification, before requesting shutdown request (invalid)
    exit_msg = """{
        "jsonrpc": "2.0",
        "method": "exit",
        "params": null
    }"""
    write_lsp_message(proc, exit_msg)

    @test with_timeout(#=timeout=#DEFAULT_TIMEOUT, "server process to shutdown") do _
        process_running(proc) && return nothing
        return true
    end
    @test process_exited(proc) && proc.exitcode == 1
end; end

# test a normal server lifecycle over the pipe transport, exercising both
# `--pipe-connect` and its `--pipe` alias, the flag convention that stock
# LSP clients (e.g. vscode-languageclient) use
for pipe_flag in ("--pipe-connect", "--pipe")
    mktempdir() do pipe_dir; mktempdir() do root_dir
        pipe_name = "jetls-test-$(getpid())-$(lstrip(pipe_flag, '-'))"
        pipe_path = @static Sys.iswindows() ?
            "\\\\.\\pipe\\$pipe_name" : joinpath(pipe_dir, "$pipe_name.sock")
        server_socket = Sockets.listen(pipe_path)
        cmd = `$JULIA_CMD --project=$JETLS_DIR -m JETLS serve $pipe_flag=$pipe_path`
        proc = run(cmd; wait=false)
        conn = nothing
        try
            accept_task = @async Sockets.accept(server_socket)
            conn = with_timeout(#=timeout=#STARTUP_TIMEOUT, "pipe connection") do _
                process_exited(proc) &&
                    error("Server exited (code $(proc.exitcode)) before connecting")
                istaskdone(accept_task) || return nothing
                return fetch(accept_task)
            end

            initialize_msg = """{
                "jsonrpc": "2.0",
                "id": 1,
                "method": "initialize",
                "params": {
                    "processId": $(getpid()),
                    "capabilities": {},
                    "workspaceFolders": [{
                        "uri": "$(JETLS.LSP.URIs2.filepath2uri(root_dir))",
                        "name": "test-workspace"
                    }]
                }
            }"""
            write_lsp_message(conn, initialize_msg)
            initialization = read_lsp_response(conn, 1)
            @test occursin("\"id\":1", initialization.response)
            @test occursin("\"result\"", initialization.response)

            shutdown_msg = """{
                "jsonrpc": "2.0",
                "id": 2,
                "method": "shutdown",
                "params": null
            }"""
            write_lsp_message(conn, shutdown_msg)
            shutdown = read_lsp_response(conn, 2)
            @test occursin("\"result\":null", shutdown.response)

            exit_msg = """{
                "jsonrpc": "2.0",
                "method": "exit",
                "params": null
            }"""
            write_lsp_message(conn, exit_msg)

            @test with_timeout(#=timeout=#DEFAULT_TIMEOUT, "server shutdown") do _
                process_running(proc) && return nothing
                return true
            end
            @test process_exited(proc) && proc.exitcode == 0
        finally
            isnothing(conn) || close(conn)
            close(server_socket)
            if !process_exited(proc)
                @error "Server process did not exit gracefully, killing it"
                kill(proc)
            end
        end
    end; end
end

end # module test_jetls_serve
