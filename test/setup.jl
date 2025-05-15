using Test
using Pkg
using JETLS
using JETLS.LSP
using JETLS.JSONRPC: JSON3, readmsg, writemsg

const FIXTURES_DIR = normpath(pkgdir(JETLS), "test", "fixtures")

function withserver(f;
                    rootPath=dirname(@__DIR__),
                    rootUri="file://$rootPath",)
    in = Base.BufferStream()
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
    id_counter = Ref(0)
    old_env = Pkg.project().path
    Pkg.activate(rootPath; io=devnull)
    let id = id_counter[] += 1
        writemsg(in,
            InitializeRequest(;
                id,
                params=InitializeParams(;
                    processId=getpid(),
                    rootPath,
                    rootUri,
                    capabilities=ClientCapabilities())))
        @test take!(out_queue).id == id
    end
    try
        return f(in, out, in_queue, out_queue, id_counter)
    finally
        Pkg.activate(old_env; io=devnull)
        let id = id_counter[] += 1
            writemsg(in,
                ShutdownRequest(;
                    id))
            res = take!(out_queue)
            @test res.id == id
            # make sure the `ShutdownResponse` follows the `ResponseMessage` specification:
            # https://microsoft.github.io/language-server-protocol/specifications/lsp/3.17/specification/#responseMessage
            roundtrip = JSON3.read(JSON3.write(res))
            @test haskey(roundtrip, :result)
            @test roundtrip[:result] === nothing
        end
        writemsg(in,
            ExitNotification())
        @test take!(out_queue) === nothing
        result = fetch(t)
        @test result isa JETLS.JSONRPC.Endpoint
        @test result.state === :closed
    end
end
