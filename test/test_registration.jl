module test_registration

include("setup.jl")

using JETLS: JETLS
using JETLS: Registered, Registration, Unregistration, register, unregister
using JETLS.AtomicContainers: load

let capabilities = ClientCapabilities(;
        notebookDocument = NotebookDocumentClientCapabilities(;
            synchronization = NotebookDocumentSyncClientCapabilities(;
                dynamicRegistration = true)),
        textDocument = TextDocumentClientCapabilities(;
            synchronization = TextDocumentSyncClientCapabilities(;
                dynamicRegistration = true,
                didSave = true),
            completion = CompletionClientCapabilities(;
                dynamicRegistration = true)))
    withserver(; capabilities) do (;
            server,
            readmsg,
            initialize_json_response,
            register_capability_json_request
        )
        state = server.state
        reg = Registered(JETLS.COMPLETION_REGISTRATION_ID, JETLS.COMPLETION_REGISTRATION_METHOD)

        server_capabilities = initialize_json_response[:result]["capabilities"]
        @test !haskey(server_capabilities, "textDocumentSync")
        @test !haskey(server_capabilities, "notebookDocumentSync")

        registrations = register_capability_json_request.params.registrations
        methods = Set(registration.method for registration in registrations)
        @test Set((
            "textDocument/didOpen",
            "textDocument/didChange",
            "textDocument/didSave",
            "textDocument/didClose",
            "notebookDocument/sync",
        )) ⊆ methods

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

end # module test_registration
