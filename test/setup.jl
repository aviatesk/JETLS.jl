using Test
using Pkg
using JETLS
using JETLS.LSP
using JETLS.URIs2

using JETLS: get_text_and_positions

include("HierarchicalTestSet.jl")

"""
    wait_for_file_cache_version(state::JETLS.ServerState, uri::URI, version::Int; timeout::Float64=10.0)

Wait until the file cache for `uri` is updated to the given `version`.
Use this between `writemsg` (notification) and `writereadmsg` (request) to
ensure the sequential worker has finished processing the notification before
the concurrent worker handles the request.
"""
function wait_for_file_cache_version(
        state::JETLS.ServerState, uri::URIs2.URI,
        version::Int; timeout::Float64 = 10.0
    )
    deadline = time() + timeout
    while time() < deadline
        fi = get(JETLS.load(state.file_cache), uri, nothing)
        fi !== nothing && fi.version == version && return
        sleep(0.01)
    end
    error("Timed out waiting for file cache version $version for $uri")
end

function take_with_timeout!(chn::Channel; interval = 0.1, limit = 600)
    while limit > 0
        if isready(chn)
            return take!(chn)
        end
        sleep(interval)
        limit -= 1
    end
    error("Timeout waiting for message")
end

# Reads server messages one at a time until `pred` accepts one and returns it; messages
# arriving in between (other publishes, configuration notices) are discarded.
function read_until(pred, readmsg; limit::Int = 50)
    for _ in 1:limit
        msg = readmsg(; check = false).raw_msg
        pred(msg) && return msg
    end
    error("Gave up waiting for a matching server message")
end

# Runs one scan of the workspace diagnostics worker synchronously and returns what it
# published, keyed by URI. With the worker stopped (see `withserver`), this is the only
# way `JETLS/live` diagnostics reach the client, which keeps the message sequences exact;
# the queues are expected to be empty when this is called.
function scan_live_diagnostics!(server::JETLS.Server, readmsg)
    JETLS.publish_workspace_diagnostics!(server, JETLS.DUMMY_CANCEL_FLAG)
    published = Dict{URI,PublishDiagnosticsParams}()
    while isready(server.callback.sent_queue)
        msg = readmsg(; check = false).raw_msg
        msg isa PublishDiagnosticsNotification ||
            error("Unexpected message during a live diagnostics scan: $(typeof(msg))")
        published[msg.params.uri] = msg.params
    end
    return published
end

# Stops the workspace diagnostics worker once full-analysis has settled and discards
# whatever was published meanwhile, so that the shutdown handshake sees empty queues.
function settle_live_diagnostics!(server::JETLS.Server, readmsg)
    manager = server.state.analysis_manager
    quiescent() = isempty(JETLS.load(manager.debounced)) &&
        isempty(JETLS.load(manager.pending_analyses))
    # a debounce timer hands its request over to `pending_analyses` in two steps
    timedwait(10.0) do
        quiescent() || return false
        sleep(0.1)
        quiescent()
    end === :ok || error("Full-analysis did not settle")
    JETLS.stop_workspace_diagnostics_worker(server)
    while isready(server.callback.sent_queue)
        readmsg(; check = false)
    end
    return nothing
end

function with_pull_diagnostics(capabilities::ClientCapabilities)
    textDocument = @something capabilities.textDocument TextDocumentClientCapabilities()
    textDocument.diagnostic === nothing || return capabilities
    fields(x) = (; (f => getfield(x, f) for f in fieldnames(typeof(x)))...)
    textDocument = TextDocumentClientCapabilities(;
        fields(textDocument)..., diagnostic = DiagnosticClientCapabilities())
    return ClientCapabilities(; fields(capabilities)..., textDocument)
end

# Tests model a client with pull diagnostic support unless they opt out with
# `pull_diagnostics = false`, in which case the server pushes the live diagnostics of
# open files too. The workspace diagnostics worker is stopped right after initialization
# unless a test opts in with `live_diagnostics = true`: its pushes arrive at their own
# pace and would interleave with the exact message sequences asserted below. Tests then
# drive the scans themselves through `scan_live_diagnostics!`.
function withserver(
        f::Base.Callable;
        capabilities::ClientCapabilities = ClientCapabilities(),
        live_diagnostics::Bool = false,
        pull_diagnostics::Bool = true,
        workspaceFolders::Union{Nothing, Vector{WorkspaceFolder}} = nothing,
        rootUri::Union{Nothing, URI} = nothing,
        settings::Union{Nothing, AbstractDict} = nothing
    )
    if pull_diagnostics
        capabilities = with_pull_diagnostics(capabilities)
    end
    in_pipe = Pipe()
    out_pipe = Pipe()
    Base.link_pipe!(in_pipe; reader_supports_async=true, writer_supports_async=true)
    Base.link_pipe!(out_pipe; reader_supports_async=true, writer_supports_async=true)
    in = in_pipe.in
    out = out_pipe.out
    received_queue = Channel{Any}(Inf)
    sent_queue = Channel{Any}(Inf)
    endpoint = Endpoint(in_pipe.out, out_pipe.in)
    server = Server(endpoint; callback=JETLS.ServerMessageRecorder(received_queue, sent_queue))
    runserver_task = Threads.@spawn :interactive runserver(server)
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

    function assert_empty_queues()
        isempty(received_queue) && isempty(sent_queue) && return
        @error "Non empty queue found"
        isempty(received_queue) || @error "received_queue" take!(received_queue)
        isempty(sent_queue) || @error "sent_queue" take!(sent_queue)
        error("Unexpected messages remained in the server queues")
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
    function writereadmsg(@nospecialize(msg); read::Int=1, check::Bool=true)
        @assert read ≥ 0 "`read::Int` must not be negative"
        LSP.writelsp(in, msg)
        raw_msg = take_with_timeout!(received_queue)
        raw_res = json_res = nothing
        if read == 0
        elseif read == 1
            raw_res = take_with_timeout!(sent_queue)
            json_res = LSP.readlsp(out)
        else
            raw_res = Any[]
            json_res = Any[]
            for _ = 1:read
                push!(raw_res, take_with_timeout!(sent_queue))
                push!(json_res, LSP.readlsp(out))
            end
        end
        check && assert_empty_queues()
        return (; raw_msg, raw_res, json_res)
    end

    function writemsg(@nospecialize(msg); check::Bool=true)
        LSP.writelsp(in, msg)
        raw_msg = take_with_timeout!(received_queue)
        check && assert_empty_queues()
        return (; raw_msg)
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
    function readmsg(; read::Int=1, check::Bool=true)
        @assert read ≥ 0 "`read::Int` must not be negative"
        raw_msg = json_msg = nothing
        if read == 0
        elseif read == 1
            raw_msg = take_with_timeout!(sent_queue)
            json_msg = LSP.readlsp(out)
        else
            raw_msg = Any[]
            json_msg = Any[]
            for _ = 1:read
                push!(raw_msg, take_with_timeout!(sent_queue))
                push!(json_msg, LSP.readlsp(out))
            end
        end
        check && assert_empty_queues()
        return (; raw_msg, json_msg)
    end

    function read_initialize_response(id::Int)
        while true
            raw_res = take_with_timeout!(sent_queue)
            json_res = LSP.readlsp(out)
            if raw_res isa InitializeResponse
                @assert raw_res.id == id
                return (; raw_res, json_res)
            end
            raw_res isa ShowMessageNotification ||
                error("Unexpected message before InitializeResponse: $(typeof(raw_res))")
        end
    end

    local initialize_response, initialize_json_response
    local register_capability_request, register_capability_json_request
    initialize_completed = false
    try
        let id = id_counter[] += 1
            LSP.writelsp(in, InitializeRequest(;
                id,
                params = InitializeParams(;
                    processId = getpid(),
                    capabilities,
                    rootUri,
                    workspaceFolders)))
            raw_msg = take_with_timeout!(received_queue)::InitializeRequest
            initialize_completed = true
            (; raw_res, json_res) = read_initialize_response(id)
            assert_empty_queues()
            @assert raw_msg.params.workspaceFolders == workspaceFolders
            initialize_response = raw_res
            initialize_json_response = json_res::Dict{Symbol,Any}

            (; raw_msg, raw_res, json_res) = writereadmsg(InitializedNotification())
            raw_msg::InitializedNotification
            register_capability_request = raw_res::RegisterCapabilityRequest
            @assert register_capability_request.id isa String
            register_capability_json_request = json_res::RegisterCapabilityRequest
            @assert register_capability_json_request.id isa String

            live_diagnostics || JETLS.stop_workspace_diagnostics_worker(server)

            # apply initial settings if provided
            # read=1: ShowMessageNotification for config change
            if settings !== nothing
                writereadmsg(DidChangeConfigurationNotification(;
                    params = DidChangeConfigurationParams(; settings)); read=1)
            end
        end

        argnt = (;
            server,
            writemsg,
            readmsg,
            writereadmsg,
            id_counter,
            initialize_response,
            initialize_json_response,
            register_capability_request,
            register_capability_json_request)
        return f(argnt)
    finally
        try
            Pkg.activate(old_env; io=devnull)
            if initialize_completed
                let id = id_counter[] += 1
                    (; raw_res, json_res) = writereadmsg(ShutdownRequest(; id))
                    shutdown_response = raw_res::ShutdownResponse
                    @assert shutdown_response.id == id
                    shutdown_json = json_res::Dict{Symbol,Any}
                    @assert haskey(shutdown_json, :result)
                    @assert shutdown_json[:result] === nothing
                end
                writereadmsg(ExitNotification(); read=0)
                exit_code = fetch(runserver_task)
                @assert exit_code == 0
                @assert !endpoint.isopen
            end
        finally
            close(in)
            close(out)
            close(in_pipe.out)
            close(out_pipe.in)
        end
    end
end

"""
Create a server without starting `runserver`, so tests can advance document
synchronization and concurrent dispatch independently.
"""
function with_manual_dispatch_server(tester)
    recorder = JETLS.ServerMessageRecorder()
    server = Server(Endpoint(IOBuffer(), IOBuffer()); callback = recorder)
    server.state.init_params = InitializeParams(;
        processId = getpid(), rootUri = nothing, capabilities = ClientCapabilities())
    try
        return tester(server, recorder)
    finally
        close(server.endpoint)
        close(server.message_queue)
    end
end

function queued_snapshot_requests(server::Server, messages::Vector)
    queue, worker = JETLS.start_sequential_message_worker(server)
    try
        foreach(msg -> put!(queue, msg), messages)
        put!(queue, nothing)
        timedwait(() -> istaskdone(worker), 30.0; pollint = 0.01) === :ok ||
            error("Timed out preparing document snapshots")
        fetch(worker)
    finally
        close(queue)
    end
    # Keep concurrent dispatch stopped until every later edit has been applied.
    prepared = JETLS.SnapshotRequestMessage[]
    while isready(server.message_queue)
        msg = take!(server.message_queue)
        @test msg isa JETLS.SnapshotRequestMessage
        push!(prepared, msg)
    end
    return prepared
end

function dispatch_snapshot_request(
        server::Server, recorder::JETLS.ServerMessageRecorder,
        prepared::JETLS.SnapshotRequestMessage
    )
    JETLS.handler_concurrent_message(server, prepared)
    response = take_with_timeout!(recorder.sent_queue; interval = 0.01, limit = 6000)
    @test response.id == prepared.msg.id
    token = take_with_timeout!(server.message_queue; interval = 0.01, limit = 3000)
    @test token isa JETLS.HandledToken
    @test token.id == prepared.msg.id
    JETLS.handler_concurrent_message(server, token)
    @test !haskey(server.state.currently_handled, prepared.msg.id)
    @test prepared.msg.id in server.state.handled_history
    @test !isready(recorder.sent_queue)
    return response
end

function withpackage(
        test_func::Base.Callable, pkgname::AbstractString,
        pkgcode::AbstractString;
        pkg_setup::Base.Callable = function ()
            return Pkg.precompile(; io = devnull)
        end,
        env_setup::Base.Callable = function () end
    )
    mktempdir() do tempdir
        pkgpath = normpath(tempdir, pkgname)
        Pkg.activate(pkgpath) do
            Pkg.generate(pkgpath; io=devnull)
            pkgfile = normpath(pkgpath, "src", "$pkgname.jl")
            write(pkgfile, string(pkgcode))
            pkg_setup()

            Pkg.activate(; temp=true, io=devnull)
            env_setup()

            return test_func(pkgpath)
        end
    end
end

function withscript(
        test_func, scriptcode::AbstractString;
        env_setup::Base.Callable = function () end
    )
    mktemp() do scriptpath, _
        Pkg.activate(dirname(scriptpath)) do
            write(scriptpath, scriptcode)
            Pkg.activate(; temp=true, io=devnull)
            env_setup()
            return test_func(scriptpath)
        end
    end
end

function make_DidOpenTextDocumentNotification(
        uri::URI, text::AbstractString;
        languageId::AbstractString = "julia",
        version::Int = 1
    )
    return DidOpenTextDocumentNotification(;
        params = DidOpenTextDocumentParams(;
            textDocument = TextDocumentItem(;
                uri, text, languageId, version)))
end

function make_DidChangeTextDocumentNotification(
        uri::URI, text::AbstractString, version::Int
    )
    return DidChangeTextDocumentNotification(;
        params = DidChangeTextDocumentParams(;
            textDocument = VersionedTextDocumentIdentifier(; uri, version),
            contentChanges = [TextDocumentContentChangeEvent(; text)]))
end

function make_DidCloseTextDocumentNotification(uri::URI)
    return DidCloseTextDocumentNotification(;
        params = DidCloseTextDocumentParams(;
            textDocument = TextDocumentIdentifier(; uri)))
end
