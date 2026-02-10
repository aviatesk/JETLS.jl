module test_jetls_serve

"""
Test file for exercising the `jetls` executable app with raw JSON communication.

This test spawns actual server processes using `julia -m JETLS` and communicates
with them via stdin/stdout using raw JSON-RPC messages, testing:

1. Server startup and basic lifecycle (initialize, shutdown, exit)
2. Process management and graceful termination

To run this test independently:
    julia --startup-file=no -e 'using Test; @testset "jetls serve" include("test/app/test_jetls_serve.jl")'
"""

using Test
using JETLS

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

const DEFAULT_TIMEOUT = 10
const STARTUP_TIMEOUT = 60

# test a very simple, normal server lifecycle
withserverprocess() do proc
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
    write_lsp_message(proc, initialize_msg)
    initialization_response = @something read_lsp_message(proc) begin
        error("No response received from server (may have terminated)")
    end
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
    shutdown_response = @something read_lsp_message(proc) begin
        error("No response received from server (may have terminated)")
    end
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
end

# test a very simple, abnormal server lifecycle
withserverprocess() do proc
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
    write_lsp_message(proc, initialize_msg)
    initialization_response = @something read_lsp_message(proc) begin
        error("No response received from server (may have terminated)")
    end
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
end

end # module test_jetls_serve
