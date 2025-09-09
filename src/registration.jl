register(server::Server, registration::Registration) =
    register(server, Registration[registration])
function register(server::Server, registrations::Vector{Registration})
    state = server.state
    filtered = filter(registrations) do registration
        reg = Registered(registration.id, registration.method)
        return store!(state.currently_registered) do data
            if reg ∉ data
                new_data = copy(data)
                push!(new_data, reg)
                return new_data, true
            end
            return data, false
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
        return store!(server.state.currently_registered) do data
            if reg ∈ data
                new_data = copy(data)
                delete!(new_data, reg)
                return new_data, true
            end
            return data, false
        end
    end
    send(server, UnregisterCapabilityRequest(;
        id = String(gensym(:UnregisterCapabilityRequest)),
        params = UnregistrationParams(;
            unregisterations = filtered)))
end
