"""
General parameters to register for a capability.
"""
@interface Registration begin
    """
    The id used to register the request. The id can be used to deregister
    the request again.
    """
    id::String

    """
    The method / capability to register for.
    """
    method::String

    """
    Options necessary for the registration.
    """
    registerOptions::Union{LSPAny, Nothing} = nothing
end

@interface RegistrationParams begin
    registrations::Vector{Registration}
end

"""
The `client/registerCapability` request is sent from the server to the client to register
for a new capability on the client side. Not all clients need to support dynamic
capability registration. A client opts in via the `dynamicRegistration` property on the
specific client capabilities. A client can even provide dynamic registration for
capability A but not for capability B (see `TextDocumentClientCapabilities` as an
example).

Server must not register the same capability both statically through the initialize
result and dynamically for the same document selector. If a server wants to support
both static and dynamic registration it needs to check the client capability in the
initialize request and only register the capability statically if the client doesn't
support dynamic registration for that capability.
"""
@interface RegisterCapabilityRequest @extends RequestMessage begin
    method::String = "client/registerCapability"
    params::RegistrationParams
end

"""
Static registration options to be returned in the initialize request.

`StaticRegistrationOptions` can be used to register a feature in the initialize result with
a given server control ID to be able to un-register the feature later on.
"""
@interface StaticRegistrationOptions begin
    """
    The id used to register the request. The id can be used to deregister the request again.
    See also Registration#id.
    """
    id::Union{String, Nothing} = nothing
end

"""
General text document registration options.

`TextDocumentRegistrationOptions` can be used to dynamically register for requests for a set
of text documents.
"""
@interface TextDocumentRegistrationOptions begin
    """
    A document selector to identify the scope of the registration.
    If set to null the document selector provided on the client side will be used.
    """
    documentSelector::Union{DocumentSelector, Nothing}
end
