using Test
using Pkg
using JETLS
using JETLS.LSP
using JETLS.URIs2
using JETLS.JSONRPC: JSON3, readmsg, writemsg

function withserver(f;
                    workspaceFolders::Union{Nothing,Vector{WorkspaceFolder}}=nothing,
                    rootUri::Union{Nothing,String}=nothing)
    in = Base.BufferStream()
    out = Base.BufferStream()
    received_queue = Channel{Any}(Inf)
    sent_queue = Channel{Any}(Inf)
    t = @async runserver(in, out) do state::Symbol, msg
        @nospecialize msg
        if state === :received
            put!(received_queue, msg)
        elseif state === :sent
            put!(sent_queue, msg)
        end
    end
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
    let id = id_counter[] += 1
        writemsg(in,
            InitializeRequest(;
                id,
                params=InitializeParams(;
                    processId=getpid(),
                    capabilities=ClientCapabilities(),
                    rootUri,
                    workspaceFolders)))
        req = take_with_timeout!(received_queue)
        @test req isa InitializeRequest && req.params.workspaceFolders == workspaceFolders
        res = take_with_timeout!(sent_queue)
        @test res isa InitializeResponse && res.id == id
    end
    try
        return f(in, out, received_queue, sent_queue, id_counter)
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
