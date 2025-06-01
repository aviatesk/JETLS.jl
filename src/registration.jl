register(state::ServerState, registration::Registration) =
    register(state, Registration[registration])
function register(state::ServerState, registrations::Vector{Registration})
    filtered = filter(registrations) do registration
        reg = Registered(registration.id, registration.method)
        if reg ∉ state.currently_registered
            push!(state.currently_registered, reg)
            return true
        else
            return false
        end
    end
    send(state, RegisterCapabilityRequest(;
        id = String(gensym(:RegisterCapabilityRequest)),
        params = RegistrationParams(;
            registrations = filtered)))
end

unregister(state::ServerState, unregistration::Unregistration) =
    unregister(state, Unregistration[unregistration])
function unregister(state::ServerState, unregisterations::Vector{Unregistration})
    filtered = filter(unregisterations) do unregistration
        reg = Registered(unregistration.id, unregistration.method)
        if reg ∈ state.currently_registered
            delete!(state.currently_registered, reg)
            return true
        else
            return false
        end
    end
    send(state, UnregisterCapabilityRequest(;
        id = String(gensym(:UnregisterCapabilityRequest)),
        params = UnregistrationParams(;
            unregisterations = filtered)))
end
