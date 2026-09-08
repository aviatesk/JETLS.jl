module test_registration

include("setup.jl")

using JETLS: JETLS
using JETLS: Registered, Registration, Unregistration, register, unregister
using JETLS.AtomicContainers: load

let capabilities = ClientCapabilities(;
        textDocument = TextDocumentClientCapabilities(;
            completion = CompletionClientCapabilities(;
                dynamicRegistration = true)))
    withserver(; capabilities) do (; server, readmsg)
        state = server.state
        reg = Registered(JETLS.COMPLETION_REGISTRATION_ID, JETLS.COMPLETION_REGISTRATION_METHOD)

        # test the completion is registered dynamically at the initialization
        @test reg in load(state.currently_registered)

        # test dynamic unregistration
        unregister(server, Unregistration(;
            id = JETLS.COMPLETION_REGISTRATION_ID,
            method = JETLS.COMPLETION_REGISTRATION_METHOD))
        (; raw_msg) = readmsg()
        @test raw_msg isa UnregisterCapabilityRequest
        @test reg ∉ load(state.currently_registered)

        # test dynamic re-registration
        register(server, JETLS.completion_registration())
        (; raw_msg) = readmsg()
        @test raw_msg isa RegisterCapabilityRequest
        @test reg in load(state.currently_registered)
    end
end

function with_diagnostic_registration_server(
        f;
        configuration::Bool = true,
        dynamicRegistration::Bool = true,
        recorder::JETLS.ServerMessageRecorder = JETLS.ServerMessageRecorder(),
    )
    server = Server(; callback=recorder)
    server.state.workspaceFolders = URI[]
    server.state.init_params = InitializeParams(;
        processId = nothing,
        rootUri = nothing,
        capabilities = ClientCapabilities(;
            workspace = WorkspaceClientCapabilities(; configuration),
            textDocument = TextDocumentClientCapabilities(;
                diagnostic = DiagnosticClientCapabilities(; dynamicRegistration))))
    try
        return f(server, recorder)
    finally
        close(server.endpoint)
    end
end

function recorded_messages!(recorder::JETLS.ServerMessageRecorder)
    messages = Any[]
    while isready(recorder.sent_queue)
        push!(messages, take!(recorder.sent_queue))
    end
    return messages
end

function diagnostic_requests!(server::Server, recorder::JETLS.ServerMessageRecorder)
    while isready(server.message_queue)
        JETLS.handler_concurrent_message(server, take!(server.message_queue))
    end
    return filter(recorded_messages!(recorder)) do msg
        if msg isa RegisterCapabilityRequest
            return any(r -> r.method == JETLS.DIAGNOSTIC_REGISTRATION_METHOD,
                msg.params.registrations)
        elseif msg isa UnregisterCapabilityRequest
            return any(r -> r.method == JETLS.DIAGNOSTIC_REGISTRATION_METHOD,
                msg.params.unregisterations)
        end
        return false
    end
end

function wait_for_recorded_message(recorder::JETLS.ServerMessageRecorder)
    timedwait(() -> isready(recorder.sent_queue), 10.0) === :ok ||
        error("Timed out waiting for a server message")
end

function test_diagnostic_requests(
        messages::Vector{Any}, all_files::Bool; replacement::Bool=false
    )
    @test length(messages) == (replacement ? 2 : 1)
    registration = only((last(messages)::RegisterCapabilityRequest).params.registrations)
    if replacement
        unregistration = only(
            (first(messages)::UnregisterCapabilityRequest).params.unregisterations)
        @test unregistration.id == registration.id
    end
    @test registration.registerOptions.workspaceDiagnostics === all_files
    return registration
end

diagnostic_settings(all_files::Bool) = Dict{String,Any}(
    "diagnostic" => Dict{String,Any}("all_files" => all_files))

# Runs `initialize` for a client without dynamic diagnostic registration and returns
# the statically advertised `diagnosticProvider`.
function static_diagnostic_provider(dir::AbstractString)
    recorder = JETLS.ServerMessageRecorder()
    server = Server(; callback=recorder)
    request = InitializeRequest(;
        id = 1,
        params = InitializeParams(;
            processId = getpid(),
            capabilities = ClientCapabilities(;
                textDocument = TextDocumentClientCapabilities(;
                    diagnostic = DiagnosticClientCapabilities(; dynamicRegistration=false))),
            rootUri = nothing,
            workspaceFolders = [WorkspaceFolder(; uri=filepath2uri(dir), name="workspace")]))
    try
        JETLS.handle_InitializeRequest(server, request; client_process_id = Int(getpid()))
        response = only(msg for msg in recorded_messages!(recorder) if msg isa InitializeResponse)
        return response.result.capabilities.diagnosticProvider
    finally
        JETLS.stop_analysis_worker(server)
        JETLS.stop_signature_analysis_workers(server)
        close(server.endpoint)
    end
end

@testset "diagnostic registration" begin
    @testset "initial client configuration selects document-only diagnostics" begin
        with_diagnostic_registration_server() do server, recorder
            JETLS.handle_InitializedNotification(server)
            messages = recorded_messages!(recorder)
            @test all(r.method != JETLS.DIAGNOSTIC_REGISTRATION_METHOD
                for msg in messages if msg isa RegisterCapabilityRequest
                for r in msg.params.registrations)
            request = only(msg for msg in messages if msg isa ConfigurationRequest)
            caller = JETLS.poprequest!(server, request.id)
            JETLS.handle_workspace_configuration_response(server,
                Dict{Symbol,Any}(
                    :id => request.id,
                    :result => Any[diagnostic_settings(false)]), caller)
            registration = test_diagnostic_requests(diagnostic_requests!(server, recorder), false)
            @test registration.registerOptions.identifier == "JETLS/diagnostic"
            @test registration.registerOptions.interFileDependencies
            @test registration.registerOptions.documentSelector == JETLS.DEFAULT_DOCUMENT_SELECTOR
        end
    end

    @testset "configuration changes update workspace diagnostics" begin
        with_diagnostic_registration_server(; configuration=false) do server, recorder
            JETLS.handle_InitializedNotification(server)
            test_diagnostic_requests(diagnostic_requests!(server, recorder), true)
            for all_files in (false, true)
                JETLS.load_lsp_config!(server, diagnostic_settings(all_files), "test")
                test_diagnostic_requests(
                    diagnostic_requests!(server, recorder), all_files; replacement=true)
            end
            settings = diagnostic_settings(true)
            JETLS.load_lsp_config!(server, settings, "test")
            @test isempty(diagnostic_requests!(server, recorder))
            settings["diagnostic"]["enabled"] = false
            JETLS.load_lsp_config!(server, settings, "test")
            @test isempty(diagnostic_requests!(server, recorder))
        end
    end

    @testset "overlapping updates leave the latest configuration registered" begin
        recorder = JETLS.ServerMessageRecorder(Channel{Any}(Inf), Channel{Any}(0))
        with_diagnostic_registration_server(; configuration=false, recorder) do server, recorder
            JETLS.initialize_config!(server.state.config_manager)
            queue, worker = JETLS.start_concurrent_message_worker(server)
            updates = Task[]
            try
                push!(updates, Threads.@spawn JETLS.update_diagnostic_registration!(
                    server, JETLS.ConfigChangeTracker(); on_init=true))
                wait_for_recorded_message(recorder)
                initial = only((take!(recorder.sent_queue)::RegisterCapabilityRequest).params.registrations)
                messages = Any[]
                for all_files in (false, true)
                    tracker = JETLS.ConfigChangeTracker()
                    JETLS.store_lsp_config!(
                        tracker, server, diagnostic_settings(all_files), "test")
                    push!(updates, Threads.@spawn(
                        JETLS.update_diagnostic_registration!(server, tracker)))
                    if !all_files
                        wait_for_recorded_message(recorder)
                        push!(messages, take!(recorder.sent_queue))
                        # Leave the document-only registration's send pending during re-enable.
                        wait_for_recorded_message(recorder)
                    end
                end
                reader = @async collect(recorder.sent_queue)
                timedwait(() -> all(istaskdone, updates), 10.0) === :ok || error("Timed out waiting for registration updates")
                foreach(fetch, updates)
                put!(queue, nothing)
                timedwait(() -> istaskdone(worker), 10.0) === :ok || error("Timed out waiting for the message worker")
                fetch(worker)
                close(recorder.sent_queue)
                registrations = Dict(initial.id => initial)
                append!(messages, fetch(reader))
                for msg in messages
                    if msg isa UnregisterCapabilityRequest
                        for r in msg.params.unregisterations
                            delete!(registrations, r.id)
                        end
                    elseif msg isa RegisterCapabilityRequest
                        for r in msg.params.registrations
                            registrations[r.id] = r
                        end
                    end
                end
                registration = only(values(registrations))
                @test registration.registerOptions.workspaceDiagnostics ===
                    JETLS.get_config(server, :diagnostic, :all_files)
            finally
                close(recorder.sent_queue)
                put!(queue, nothing)
                @test timedwait(() -> istaskdone(worker) && all(istaskdone, updates), 10.0) === :ok
                close(queue)
            end
        end
    end

    @testset "file configuration initialization and updates" begin
        mktempdir() do dir
            config_path = joinpath(dir, JETLS.CONFIG_FILE)
            write(config_path, "[diagnostic]\nall_files = false\n")
            with_diagnostic_registration_server(; configuration=false) do server, recorder
                server.state.root_path = dir
                JETLS.load_file_config!(Returns(nothing), server, config_path)
                JETLS.handle_InitializedNotification(server)
                test_diagnostic_requests(diagnostic_requests!(server, recorder), false)
                write(config_path, "[diagnostic]\nall_files = true\n")
                JETLS.handle_config_file_change!(server, config_path, FileChangeType.Changed)
                test_diagnostic_requests(diagnostic_requests!(server, recorder), true; replacement=true)
            end
        end
    end

    @testset "static clients follow the file configuration at startup" begin
        @test JETLS.diagnostic_options().workspaceDiagnostics
        mktempdir() do dir
            @test static_diagnostic_provider(dir).workspaceDiagnostics
            write(joinpath(dir, JETLS.CONFIG_FILE), "[diagnostic]\nall_files = false\n")
            @test !static_diagnostic_provider(dir).workspaceDiagnostics
        end
        with_diagnostic_registration_server(;
            dynamicRegistration=false, configuration=false) do server, recorder
            JETLS.handle_InitializedNotification(server)
            @test isempty(diagnostic_requests!(server, recorder))
            JETLS.load_lsp_config!(server, diagnostic_settings(false), "test")
            @test isempty(diagnostic_requests!(server, recorder))
        end
    end

    @testset "configuration failure does not disable diagnostics" begin
        with_diagnostic_registration_server() do server, recorder
            JETLS.handle_InitializedNotification(server)
            request = only(msg for msg in recorded_messages!(recorder) if msg isa ConfigurationRequest)
            response = Dict{Symbol,Any}(
                :id => request.id,
                :error => Dict{String,Any}(
                    "code" => -32603, "message" => "unavailable"))
            caller = JETLS.poprequest!(server, request.id)
            JETLS.handle_workspace_configuration_response(server, response, caller)
            test_diagnostic_requests(diagnostic_requests!(server, recorder), true)
        end
    end
end

end # module test_registration
