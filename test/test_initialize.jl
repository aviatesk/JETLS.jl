module test_initialize

include("setup.jl")

function initialize_messages(;
        root_uri::Union{Nothing,URI} = nothing,
        workspace_folders::Union{Nothing,Vector{WorkspaceFolder}} = nothing
    )
    recorder = JETLS.ServerMessageRecorder()
    server = Server(; callback=recorder)
    request = InitializeRequest(;
        id = 1,
        params = InitializeParams(;
            processId = getpid(),
            capabilities = ClientCapabilities(),
            rootUri = root_uri,
            workspaceFolders = workspace_folders))
    try
        JETLS.handle_InitializeRequest(server, request; client_process_id = Int(getpid()))
        messages = Any[]
        while isready(recorder.sent_queue)
            push!(messages, take!(recorder.sent_queue))
        end
        return messages
    finally
        JETLS.stop_analysis_worker(server)
        JETLS.stop_signature_analysis_workers(server)
        close(server.endpoint)
    end
end

function test_initialize_warning(messages::Vector{Any}, expected::AbstractString)
    @test length(messages) == 2
    warning = first(messages)
    if warning isa ShowMessageNotification
        @test warning.params.type == MessageType.Warning
        @test occursin(expected, warning.params.message)
    else
        @test warning isa ShowMessageNotification
    end
    @test last(messages) isa InitializeResponse
    return nothing
end

@testset "workspace initialization warnings" begin
    let messages = @test_logs(
            (:warn, r"No workspace folder"),
            match_mode = :any,
            initialize_messages())
        test_initialize_warning(messages, "started without a workspace folder")
    end

    let workspace_folders = WorkspaceFolder[]
        messages = @test_logs(
            (:warn, r"No workspace folder"),
            match_mode = :any,
            initialize_messages(; workspace_folders))
        test_initialize_warning(messages, "started without a workspace folder")
    end

    let root_uri = URI("https://example.com/workspace")
        messages = @test_logs(
            (:warn, r"Root URI scheme not supported"),
            match_mode = :any,
            initialize_messages(; root_uri))
        test_initialize_warning(messages, "root URI scheme `https:`")
    end

    let workspace_folders = [
            WorkspaceFolder(; uri=URI("file:///workspace-a"), name="workspace-a"),
            WorkspaceFolder(; uri=URI("file:///workspace-b"), name="workspace-b")]
        messages = @test_logs(
            (:warn, r"Multiple workspaceFolders are not supported"),
            match_mode = :any,
            initialize_messages(; workspace_folders))
        test_initialize_warning(messages, "one JETLS server per workspace folder")
    end
end

end # module test_initialize
