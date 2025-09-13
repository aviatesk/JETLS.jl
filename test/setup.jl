using Test
using Pkg
using JETLS
using JETLS.LSP
using JETLS.URIs2
using JETLS: JSONRPC

using JETLS: get_text_and_positions

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
                    rootUri::Union{Nothing,URI}=nothing)
    in = Base.BufferStream()
    out = Base.BufferStream()
    received_queue = Channel{Any}(Inf)
    sent_queue = Channel{Any}(Inf)
    server = Server(LSEndpoint(in, out)) do s::Symbol, x
        @nospecialize x
        if s === :received
            put!(received_queue, x)
        elseif s === :sent
            put!(sent_queue, x)
        end
    end
    t = Threads.@spawn :default runserver(server)
    id_counter = Ref(0)
    old_env = Pkg.project().path
    root_path = nothing
    if workspaceFolders !== nothing
        if isempty(workspaceFolders)
            root_path = uri2filepath(first(workspaceFolders).uri)
        end
    elseif rootUri !== nothing
        root_path = uri2filepath(rootUri)
    end
    if root_path === nothing
        Pkg.activate(; temp=true, io=devnull)
    else
        Pkg.activate(root_path; io=devnull)
    end
    if workspaceFolders === nothing && rootUri === nothing
        workspaceFolders = WorkspaceFolder[] # initialize empty workspace by default
    end

    """
        writereadmsg(@nospecialize(msg); read::Int=1)

    Write a message to the language server via JSON-RPC, read the server's received message,
    and read the server's response(s).
    This function also asserts that no messages remain in the queue after reading the
    expected number of responses.

    # Arguments
    - `msg`: The message to send to the server
    - `read::Int=1`: Number of responses to read from the server:
      - `0`: Don't read any responses
      - `1`: Read a single response (default)
      - `>1`: Read multiple responses and return them as arrays

    # Returns
    A named tuple containing:
    - `raw_msg`: The message received by the server
    - `raw_res`: The raw response(s) sent by the server (or `nothing` if `read=0`)
    - `json_res`: The JSON-parsed response(s) from the server (or `nothing` if `read=0`)
    """
    function writereadmsg(@nospecialize(msg); read::Int=1)
        @assert read ≥ 0 "`read::Int` must not be negative"
        JSONRPC.writemsg(in, msg)
        raw_msg = take_with_timeout!(received_queue)
        raw_res = json_res = nothing
        if read == 0
        elseif read == 1
            raw_res = take_with_timeout!(sent_queue)
            json_res = JSONRPC.readmsg(out, method_dispatcher)
        else
            raw_res = Any[]
            json_res = Any[]
            for _ = 1:read
                push!(raw_res, take_with_timeout!(sent_queue))
                push!(json_res, JSONRPC.readmsg(out, method_dispatcher))
            end
        end
        @test isempty(received_queue) && isempty(sent_queue)
        return (; raw_msg, raw_res, json_res)
    end

    """
        readmsg(; read::Int=1)

    Read response messages from the language server without sending a request.
    Similar to `writereadmsg` but only reads responses from the server.

    # Arguments
    - `read::Int=1`: Number of responses to read from the server:
      - `0`: Don't read any responses
      - `1`: Read a single response (default)
      - `>1`: Read multiple responses and return them as arrays

    # Returns
    A named tuple containing:
    - `raw_msg`: The raw response(s) sent by the server (or `nothing` if `read=0`)
    - `json_msg`: The JSON-parsed response(s) from the server (or `nothing` if `read=0`)
    """
    function readmsg(; read::Int=1)
        @assert read ≥ 0 "`read::Int` must not be negative"
        raw_msg = json_msg = nothing
        if read == 0
        elseif read == 1
            raw_msg = take_with_timeout!(sent_queue)
            json_msg = JSONRPC.readmsg(out, method_dispatcher)
        else
            raw_msg = Any[]
            json_msg = Any[]
            for _ = 1:read
                push!(raw_msg, take_with_timeout!(sent_queue))
                push!(json_msg, JSONRPC.readmsg(out, method_dispatcher))
            end
        end
        @test isempty(received_queue) && isempty(sent_queue)
        return (; raw_msg, json_msg)
    end

    # do the server initialization
    let id = id_counter[] += 1
        (; raw_msg, raw_res, json_res) = writereadmsg(
            InitializeRequest(;
                id,
                params=InitializeParams(;
                    processId=getpid(),
                    capabilities,
                    rootUri,
                    workspaceFolders)))
        @test raw_msg isa InitializeRequest && raw_msg.params.workspaceFolders == workspaceFolders
        @test raw_res isa InitializeResponse && raw_res.id == id

        (; raw_msg, raw_res) = writereadmsg(InitializedNotification())
        @test raw_msg isa InitializedNotification
        @test raw_res isa RegisterCapabilityRequest && raw_res.id isa String
    end

    argnt = (; server, writereadmsg, readmsg, id_counter)
    try
        # do the main callback
        return f(argnt)
    finally
        try
            Pkg.activate(old_env; io=devnull)
            let id = id_counter[] += 1
                (; raw_res, json_res) = writereadmsg(ShutdownRequest(; id))
                @test raw_res isa ShutdownResponse && raw_res.id == id
                # make sure the `ShutdownResponse` follows the `ResponseMessage` specification:
                # https://microsoft.github.io/language-server-protocol/specifications/lsp/3.17/specification/#responseMessage
                @test json_res isa Dict{Symbol,Any} &&
                    haskey(json_res, :result) &&
                    json_res[:result] === nothing
            end
            writereadmsg(ExitNotification(); read=0)
            result = fetch(t)
            @test result isa @NamedTuple{exit_code::Int, endpoint::JETLS.JSONRPC.Endpoint}
            @test result.exit_code == 0
            @test result.endpoint.state === :closed
        finally
            close(in)
            close(out)
        end
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

            return test_func(pkgpath)
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
            return test_func(scriptpath)
        finally
            Pkg.activate(old; io=devnull)
        end
    end
end

function make_DidOpenTextDocumentNotification(uri, text;
                                              languageId = "julia",
                                              version = 1)
    return DidOpenTextDocumentNotification(;
        params = DidOpenTextDocumentParams(;
            textDocument = TextDocumentItem(;
                uri, text, languageId, version)))
end

function make_DidChangeTextDocumentNotification(uri, text, version)
    return DidChangeTextDocumentNotification(;
        params = DidChangeTextDocumentParams(;
            textDocument = VersionedTextDocumentIdentifier(; uri, version),
            contentChanges = [TextDocumentContentChangeEvent(; text)]))
end
