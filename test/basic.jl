using Test

using JETLS
using JETLS.JSONRPC: readmsg, writemsg

# test the basic server setup and lifecycle
let in = Base.BufferStream()
    out = Base.BufferStream()
    message_queue = Channel{Any}(Inf)
    result_queue = Channel{Any}(Inf)
    t = @async runserver(in, out; shutdown_really=false) do msg, res
        put!(message_queue, msg)
        put!(result_queue, res)
    end
    rootPath = dirname(@__DIR__)
    rootUri = "file://$rootPath"
    writemsg(in,
        JETLS.LSP.InitializeRequest(;
            id=1,
            method="initialize",
            params=JETLS.LSP.InitializeParams(;
                processId=getpid(),
                rootPath,
                rootUri,
                capabilities=JETLS.LSP.ClientCapabilities())))
    @test take!(result_queue).id == 1
    writemsg(in,
        JETLS.LSP.ShutdownRequest(;
            id=2,
            method="shutdown"))
    @test take!(result_queue).id == 2
    writemsg(in,
        JETLS.LSP.ExitNotification(;
            method="exit"))
    fetch(t)
    @test t.result isa JETLS.JSONRPC.Endpoint
    @test t.result.state === :closed
end
