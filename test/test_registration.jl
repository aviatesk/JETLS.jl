module test_registration

include("setup.jl")

using JETLS: JETLS
using JETLS: Registered, Registration, Unregistration, register, unregister
using JETLS.AtomicContainers: load

let capabilities = ClientCapabilities(;
        textDocument = TextDocumentClientCapabilities(;
            completion = CompletionClientCapabilities(;
                dynamicRegistration = true)))
    withserver(; capabilities) do (; server, readmsg, id_counter)
        state = server.state
        reg = Registered(JETLS.COMPLETION_REGISTRATION_ID, JETLS.COMPLETION_REGISTRATION_METHOD)

        # test the completion is registered dynamically at the initialization
        @test reg in load(state.currently_registered)

        # test dynamic unregistration
        unregister(server, Unregistration(;
            id=JETLS.COMPLETION_REGISTRATION_ID,
            method=JETLS.COMPLETION_REGISTRATION_METHOD))
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
