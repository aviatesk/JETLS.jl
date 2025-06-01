module test_registration

include("setup.jl")

using JETLS: JETLS
using JETLS: Registered, Registration, Unregistration, register, unregister

let capabilities = ClientCapabilities(;
        textDocument = TextDocumentClientCapabilities(;
            completion = CompletionClientCapabilities(;
                dynamicRegistration = true)))
    withserver(; capabilities) do (; state, sent_queue)
        reg = Registered(JETLS.COMPLETION_REGISTRATION_ID, JETLS.COMPLETION_REGISTRATION_METHOD)

        # test the completion is registered dynamically at the initialization
        @test reg in state.currently_registered

        # test dynamic unregistration
        unregister(state, Unregistration(;
            id=JETLS.COMPLETION_REGISTRATION_ID,
            method=JETLS.COMPLETION_REGISTRATION_METHOD))
        take_with_timeout!(sent_queue)
        @test reg ∉ state.currently_registered

        # test dynamic re-registration
        register(state, JETLS.completion_registration())
        take_with_timeout!(sent_queue)
        @test reg in state.currently_registered
    end
end

end # module test_registration
