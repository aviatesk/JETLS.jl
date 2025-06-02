module test_runserver

"""
Test file for exercising runserver.jl with raw JSON communication.

This test spawns actual server processes using runserver.jl and communicates
with them via stdin/stdout using raw JSON-RPC messages, testing:

1. Server startup and basic lifecycle (initialize, shutdown, exit)
2. Process management and graceful termination

To run this test independently:
    julia --startup-file=no -e 'using Test; @testset "runserver" include("test/test_runserver.jl")'
"""

using Test
using JETLS

# Test configuration
const JULIA_CMD = normpath(Sys.BINDIR, "julia")
const JETLS_DIR = pkgdir(JETLS)
const SERVER_SCRIPT = normpath(JETLS_DIR, "runserver.jl")

function withserverprocess(f)
    cmd = `$JULIA_CMD --project=$JETLS_DIR $SERVER_SCRIPT`
    stdin = Base.BufferStream()
    stdout = Base.BufferStream()
    stderr = Base.BufferStream()
    pipe = pipeline(cmd; stdin, stdout, stderr)
    proc = run(pipe; wait=false)

    try
        return f((; proc, stdin, stdout, stderr))
    catch e
        rethrow(e)
    finally
        close(stdin)
        close(stdout)
        close(stderr)
        if !process_exited(proc)
            @error "Server process did not exit gracefully, killing it"
            kill(proc)
        end
    end
end

function with_timeout(f, timeout, timeout_message)
    elapsed = 0.0
    while true
        elapsed > timeout && error(timeout_message)
        res = f(elapsed)
        if res !== nothing
            @info "Resolved within timeout" timeout_message elapsed
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

function read_lsp_message(io, timeout, message_kind)
    # Read headers with timeout
    var"Content-Length" = with_timeout(timeout, "Timeout waiting for reading `Content-Length` of '$message_kind' message") do elapsed
        bytesavailable(io) > 0 || return nothing
        line = readline(io) # XXX may block
        startswith(line, "Content-Length:") || return nothing
        readline(io) # read the extra line break
        return parse(Int, strip(split(line, ":")[2]))
    end
    return with_timeout(timeout, "Timeout waiting for reading body of '$message_kind' message") do elapsed
        bytesavailable(io) >= var"Content-Length" || return nothing
        return String(read(io, var"Content-Length"))
    end
end

const DEFAULT_TIMEOUT = 10
const STARTUP_TIMEOUT = 60

# test a very simple, normal server lifecycle
withserverprocess() do (; proc, stdin, stdout, stderr)
    @test with_timeout(#=timeout=#STARTUP_TIMEOUT, "Timeout waiting for the server to startup") do elapsed
        bytesavailable(stderr) > 0 || return nothing
        log = String(readavailable(stderr))
        occursin(JETLS.SERVER_LOOP_STARTUP_MSG, log) || return nothing
        return true
    end
    # @info "The server loop started successfully"

    # Send initialization request
    initialize_msg = """{
        "jsonrpc": "2.0",
        "id": 1,
        "method": "initialize",
        "params": {
            "processId": $(getpid()),
            "rootUri": null,
            "capabilities": {},
            "workspaceFolders": []
        }
    }"""
    write_lsp_message(stdin, initialize_msg)
    initialization_response = read_lsp_message(stdout, #=timeout=#DEFAULT_TIMEOUT, "initialize request")
    initialization_response === nothing &&
        error("No response received from server (may have terminated)")
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
    write_lsp_message(stdin, shutdown_msg)
    shutdown_response = read_lsp_message(stdout, #=timeout=#DEFAULT_TIMEOUT, "shutdown request")
    shutdown_response === nothing &&
        error("No response received from server (may have terminated)")
    @test occursin("\"id\":2", shutdown_response)
    # @info "Server responded to shutdown request"

    # Send exit notification
    exit_msg = """{
        "jsonrpc": "2.0",
        "method": "exit",
        "params": null
    }"""
    write_lsp_message(stdin, exit_msg)
    @test with_timeout(#=timeout=#DEFAULT_TIMEOUT, "Timeout waiting for the server to exit the loop") do elapsed
        bytesavailable(stderr) > 0 || return nothing
        log = String(readavailable(stderr))
        occursin(JETLS.SERVER_LOOP_EXIT_MSG, log) || return nothing
        return true
    end
    # @info "The server loop exited successfully"

    @test with_timeout(#=timeout=#DEFAULT_TIMEOUT, "Timeout waiting for the server process to shutdown") do elapsed
        process_running(proc) && return nothing
        return true
    end
    @test process_exited(proc) && proc.exitcode == 0
end

# test a very simple, abnormal server lifecycle
withserverprocess() do (; proc, stdin, stdout, stderr)
    @test with_timeout(#=timeout=#STARTUP_TIMEOUT, "Timeout waiting for the server to startup") do elapsed
        bytesavailable(stderr) > 0 || return nothing
        log = String(readavailable(stderr))
        occursin(JETLS.SERVER_LOOP_STARTUP_MSG, log) || return nothing
        return true
    end
    # @info "The server loop started successfully"

    # Send initialization request
    initialize_msg = """{
        "jsonrpc": "2.0",
        "id": 1,
        "method": "initialize",
        "params": {
            "processId": $(getpid()),
            "rootUri": null,
            "capabilities": {},
            "workspaceFolders": []
        }
    }"""
    write_lsp_message(stdin, initialize_msg)
    initialization_response = read_lsp_message(stdout, #=timeout=#DEFAULT_TIMEOUT, "initialize request")
    initialization_response === nothing &&
        error("No response received from server (may have terminated)")
    @test occursin("\"id\":1", initialization_response)
    @test occursin("\"result\"", initialization_response)
    # @info "Server responded to initialize request successfully"

    # Send exit notification, before requesting shutdown request (invalid)
    exit_msg = """{
        "jsonrpc": "2.0",
        "method": "exit",
        "params": null
    }"""
    write_lsp_message(stdin, exit_msg)
    @test with_timeout(#=timeout=#DEFAULT_TIMEOUT, "Timeout waiting for the server to exit the loop") do elapsed
        bytesavailable(stderr) > 0 || return nothing
        log = String(readavailable(stderr))
        occursin(JETLS.SERVER_LOOP_EXIT_MSG, log) || return nothing
        return true
    end
    # @info "The server loop exited successfully"

    @test with_timeout(#=timeout=#DEFAULT_TIMEOUT, "Timeout waiting for the server process to shutdown") do elapsed
        process_running(proc) && return nothing
        return true
    end
    @test process_exited(proc) && proc.exitcode == 1
end

end # module test_runserver
