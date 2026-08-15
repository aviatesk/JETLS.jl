module test_initialize

include("setup.jl")

function initialize_result(;
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
        root_path = isdefined(server.state, :root_path) ? server.state.root_path : nothing
        return (; messages, root_path)
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

@testset "workspace initialization warning notifications" begin
    let result = initialize_result()
        test_initialize_warning(result.messages, "started without a workspace folder")
    end

    let workspace_folders = WorkspaceFolder[]
        result = initialize_result(; workspace_folders)
        test_initialize_warning(result.messages, "started without a workspace folder")
    end

    let root_uri = URI("https://example.com/workspace")
        result = initialize_result(; root_uri)
        test_initialize_warning(result.messages, "root URI scheme `https:`")
    end

    let workspace_folders = [
            WorkspaceFolder(; uri=URI("file:///workspace-a"), name="workspace-a"),
            WorkspaceFolder(; uri=URI("file:///workspace-b"), name="workspace-b")]
        result = initialize_result(; workspace_folders)
        test_initialize_warning(result.messages, "one JETLS server per workspace folder")
    end
end

@testset "workspace root normalization" begin
    mktempdir() do dir
        let script_path = joinpath(dir, "script.jl")
            write(script_path, "")
            workspace_folders = [WorkspaceFolder(; uri = filepath2uri(script_path), name = "script.jl")]
            result = initialize_result(; workspace_folders)
            @test JETLS.paths_equal(result.root_path, dir)
        end

        let workspace_path = joinpath(dir, "missing-workspace")
            workspace_folders = [WorkspaceFolder(; uri = filepath2uri(workspace_path), name = "missing-workspace")]
            result = initialize_result(; workspace_folders)
            @test JETLS.paths_equal(result.root_path, workspace_path)
        end
    end
end

end # module test_initialize
