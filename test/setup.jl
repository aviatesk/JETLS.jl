using Test
using Pkg
using JETLS
using JETLS.LSP
using JETLS.URIs2
using JETLS.JSONRPC: JSON3, readmsg, writemsg

function take_with_timeout!(chn::Channel; interval=1, limit=60)
    while limit > 0
        if isready(chn)
            return take!(chn)
        end
        sleep(interval)
        limit -= 1
    end
    error("Timeout waiting for message")
end

function withserver(f;
                    capabilities::ClientCapabilities=ClientCapabilities(),
                    workspaceFolders::Union{Nothing,Vector{WorkspaceFolder}}=nothing,
                    rootUri::Union{Nothing,String}=nothing)
    in = Base.BufferStream()
    out = Base.BufferStream()
    received_queue = Channel{Any}(Inf)
    sent_queue = Channel{Any}(Inf)
    server = JETLS.Server(JETLS.JSONRPC.Endpoint(in, out)) do s::Symbol, x
        @nospecialize x
        if s === :received
            put!(received_queue, x)
        elseif s === :sent
            put!(sent_queue, x)
        end
    end
    t = @async runserver(server)
    id_counter = Ref(0)
    old_env = Pkg.project().path
    root_path = nothing
    if workspaceFolders !== nothing
        if isempty(workspaceFolders)
            root_path = uri2filepath(URI(first(workspaceFolders).uri))
        end
    elseif rootUri !== nothing
        root_path = uri2filepath(URI(rootUri))
    end
    if root_path === nothing
        Pkg.activate(; temp=true, io=devnull)
    else
        Pkg.activate(root_path; io=devnull)
    end
    if workspaceFolders === nothing && rootUri === nothing
        workspaceFolders = WorkspaceFolder[] # initialize empty workspace by default
    end

    # do the server initialization
    let id = id_counter[] += 1
        writemsg(in,
            InitializeRequest(;
                id,
                params=InitializeParams(;
                    processId=getpid(),
                    capabilities,
                    rootUri,
                    workspaceFolders)))
        req = take_with_timeout!(received_queue)
        @test req isa InitializeRequest && req.params.workspaceFolders == workspaceFolders
        res = take_with_timeout!(sent_queue)
        @test res isa InitializeResponse && res.id == id

        writemsg(in, InitializedNotification())
        @test take_with_timeout!(received_queue) isa InitializedNotification
        res = take_with_timeout!(sent_queue)
        @test res isa RegisterCapabilityRequest && res.id isa String
    end

    argnt = (; in, out, server, received_queue, sent_queue, id_counter)
    try
        # do the main callback
        return f(argnt)
    finally
        Pkg.activate(old_env; io=devnull)
        let id = id_counter[] += 1
            writemsg(in,
                ShutdownRequest(;
                    id))
            res = take_with_timeout!(sent_queue)
            @test res.id == id
            # make sure the `ShutdownResponse` follows the `ResponseMessage` specification:
            # https://microsoft.github.io/language-server-protocol/specifications/lsp/3.17/specification/#responseMessage
            roundtrip = JSON3.read(JSON3.write(res))
            @test haskey(roundtrip, :result)
            @test roundtrip[:result] === nothing
        end
        writemsg(in,
            ExitNotification())
        result = fetch(t)
        @test result isa @NamedTuple{exit_code::Int, endpoint::JETLS.JSONRPC.Endpoint}
        @test result.exit_code == 0
        @test result.endpoint.state === :closed
    end
end

function withpackage(test_func, pkgname::AbstractString,
                     pkgcode::AbstractString;
                     pkg_setup=function ()
                         Pkg.precompile(; io=devnull)
                     end,
                     env_setup=function () end)
    old = Pkg.project().path
    mktempdir() do tempdir
        try
            pkgpath = normpath(tempdir, pkgname)
            Pkg.generate(pkgpath; io=devnull)
            Pkg.activate(pkgpath; io=devnull)
            pkgfile = normpath(pkgpath, "src", "$pkgname.jl")
            write(pkgfile, string(pkgcode))
            pkg_setup()

            Pkg.activate(; temp=true, io=devnull)
            env_setup()

            test_func(pkgpath)
        finally
            Pkg.activate(old; io=devnull)
        end
    end
end

function withscript(test_func, scriptcode::AbstractString;
                    env_setup=function () end)
    old = Pkg.project().path
    mktemp() do scriptpath, io
        try
            write(scriptpath, scriptcode)
            Pkg.activate(; temp=true, io=devnull)
            env_setup()
            test_func(scriptpath)
        finally
            Pkg.activate(old; io=devnull)
        end
    end
end

function get_text_and_positions(text::String)
    positions = Position[]
    lines = split(text, '\n')
    for (i, line) in enumerate(lines)
        for m in eachmatch(r"#=cursor=#", line)
            # Position is 0-based
            push!(positions, JETLS.Position(; line=i-1, character=m.match.offset-1))
            lines[i] = replace(line, r"#=cursor=#" => "")
        end
    end
    return join(lines, '\n'), positions
end
