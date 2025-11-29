@interface DidChangeConfigurationClientCapabilities begin
    """
    Did change configuration notification supports dynamic registration.

    # Tags
    - since - 3.6.0 to support the new pull model.
    """
    dynamicRegistration::Union{Nothing, Bool} = nothing
end

@interface ConfigurationItem begin
    """
    The scope to get the configuration section for.
    """
    scopeUri::Union{Nothing, URI} = nothing

    """
    The configuration section asked for.
    """
    section::Union{Nothing, String} = nothing
end

@interface ConfigurationParams begin
    items::Vector{ConfigurationItem}
end

"""
The `workspace/configuration` request is sent from the server to the client to
fetch configuration settings from the client. The request can fetch several
configuration settings in one roundtrip. The order of the returned configuration
settings correspond to the order of the passed `ConfigurationItems` (e.g. the
first item in the response is the result for the first configuration item in
the params).

A `ConfigurationItem` consists of the configuration section to ask for and an
additional scope URI. The configuration section asked for is defined by the
server and doesn't necessarily need to correspond to the configuration store
used by the client. So a server might ask for a configuration
`cpp.formatterOptions` but the client stores the configuration in an XML store
layout differently. It is up to the client to do the necessary conversion. If a
scope URI is provided the client should return the setting scoped to the
provided resource. If the client for example uses EditorConfig to manage its
settings the configuration should be returned for the passed resource URI. If
the client can't provide a configuration setting for a given scope then `null`
needs to be present in the returned array.

This pull model replaces the old push model were the client signaled
configuration change via an event. If the server still needs to react to
configuration changes (since the server caches the result of
`workspace/configuration` requests) the server should register for an empty
configuration change using the following registration pattern:

```julia
connection.client.register(DidChangeConfigurationNotification.type, undefined)
```

# Tags
- since - 3.6.0
"""
@interface ConfigurationRequest @extends RequestMessage begin
    method::String = "workspace/configuration"
    params::ConfigurationParams
end

@interface ConfigurationResponse @extends ResponseMessage begin
    result::Vector{LSPAny}
end

@interface DidChangeConfigurationParams begin
    """
    The actual changed settings
    """
    settings::LSPAny
end

"""
A notification sent from the client to the server to signal the change of
configuration settings.
"""
@interface DidChangeConfigurationNotification @extends NotificationMessage begin
    method::String = "workspace/didChangeConfiguration"
    params::DidChangeConfigurationParams
end
