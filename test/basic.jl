using Test

using JETLS
using JETLS.JSONRPC: JSON3, readmsg, writemsg

# test the basic server setup and lifecycle
let in = Base.BufferStream()
    out = Base.BufferStream()
    in_queue = Channel{Any}(Inf)
    out_queue = Channel{Any}(Inf)
    in_callback = function (@nospecialize(msg),)
        put!(in_queue, msg)
    end
    out_callback = function (@nospecialize(msg),)
        put!(out_queue, msg)
    end
    t = @async runserver(in, out; in_callback, out_callback, shutdown_really=false)
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
    @test take!(out_queue).id == 1
    writemsg(in,
        JETLS.LSP.ShutdownRequest(;
            id=2,
            method="shutdown"))
    let res = take!(out_queue)
        @test res.id == 2
        # make sure the `ShutdownResponse` follows the `ResponseMessage` specification:
        # https://microsoft.github.io/language-server-protocol/specifications/lsp/3.17/specification/#responseMessage
        des = JSON3.read(JSON3.write(res))
        @test haskey(des, :result)
        @test des[:result] === nothing
    end
    writemsg(in,
        JETLS.LSP.ExitNotification(;
            method="exit"))
    @test take!(out_queue) === nothing
    result = fetch(t)
    @test result isa JETLS.JSONRPC.Endpoint
    @test result.state === :closed
end
