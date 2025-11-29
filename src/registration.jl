struct RegisterCapabilityRequestCaller <: RequestCaller end
struct UnregisterCapabilityRequestCaller <: RequestCaller end

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
    id = String(gensym(:RegisterCapabilityRequest))
    send(server, RegisterCapabilityRequest(;
        id,
        params = RegistrationParams(;
            registrations = filtered)))
    addrequest!(server, id=>RegisterCapabilityRequestCaller())
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
    id = String(gensym(:UnregisterCapabilityRequest))
    send(server, UnregisterCapabilityRequest(;
        id,
        params = UnregistrationParams(;
            unregisterations = filtered)))
    addrequest!(server, id=>UnregisterCapabilityRequestCaller())
end
