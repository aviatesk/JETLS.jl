module test_registration

include("setup.jl")

using JETLSCore: JETLSCore
using JETLSCore: Registered, Registration, Unregistration, register, unregister
using JETLSCore.AtomicContainers: load

let capabilities = ClientCapabilities(;
        textDocument = TextDocumentClientCapabilities(;
            completion = CompletionClientCapabilities(;
                dynamicRegistration = true)))
    withserver(; capabilities) do (; server, readmsg)
        state = server.state
        reg = Registered(JETLSCore.COMPLETION_REGISTRATION_ID, JETLSCore.COMPLETION_REGISTRATION_METHOD)

        # test the completion is registered dynamically at the initialization
        @test reg in load(state.currently_registered)

        # test dynamic unregistration
        unregister(server, Unregistration(;
            id = JETLSCore.COMPLETION_REGISTRATION_ID,
            method = JETLSCore.COMPLETION_REGISTRATION_METHOD))
        (; raw_msg) = readmsg()
        @test raw_msg isa UnregisterCapabilityRequest
        @test reg ∉ load(state.currently_registered)

        # test dynamic re-registration
        register(server, JETLSCore.completion_registration())
        (; raw_msg) = readmsg()
        @test raw_msg isa RegisterCapabilityRequest
        @test reg in load(state.currently_registered)
    end
end

end # module test_registration
