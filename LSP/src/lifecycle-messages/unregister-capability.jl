"""
General parameters to unregister a capability.
"""
@interface Unregistration begin
    """
    The id used to unregister the request or notification. Usually an id
    provided during the register request.
    """
    id::String

    """
    The method / capability to unregister for.
    """
    method::String
end

@interface UnregistrationParams begin
    """
    This should correctly be named `unregistrations`. However changing this
    is a breaking change and needs to wait until we deliver a 4.x version
    of the specification.
    """
    unregisterations::Vector{Unregistration}
end

"""
The client/unregisterCapability request is sent from the server to the client to unregister
a previously registered capability.
"""
@interface UnregisterCapabilityRequest @extends RequestMessage begin
    method::String = "client/unregisterCapability"
    params::UnregistrationParams
end
