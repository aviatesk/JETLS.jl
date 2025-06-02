register(server::Server, registration::Registration) =
    register(server, Registration[registration])
function register(server::Server, registrations::Vector{Registration})
    state = server.state
    filtered = filter(registrations) do registration
        reg = Registered(registration.id, registration.method)
        if reg ∉ state.currently_registered
            push!(state.currently_registered, reg)
            return true
        else
            return false
        end
    end
    send(server, RegisterCapabilityRequest(;
        id = String(gensym(:RegisterCapabilityRequest)),
        params = RegistrationParams(;
            registrations = filtered)))
end

unregister(server::Server, unregistration::Unregistration) =
    unregister(server, Unregistration[unregistration])
function unregister(server::Server, unregisterations::Vector{Unregistration})
    filtered = filter(unregisterations) do unregistration
        reg = Registered(unregistration.id, unregistration.method)
        if reg ∈ server.state.currently_registered
            delete!(server.state.currently_registered, reg)
            return true
        else
            return false
        end
    end
    send(server, UnregisterCapabilityRequest(;
        id = String(gensym(:UnregisterCapabilityRequest)),
        params = UnregistrationParams(;
            unregisterations = filtered)))
end
