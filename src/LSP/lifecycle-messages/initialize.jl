@interface InitializeParams @extends WorkDoneProgressParams begin
    """
    The process Id of the parent process that started the server. Is null if the process has
    not been started by another process. If the parent process is not alive then the server
    should exit (see exit notification) its process.
    """
    processId::Union{Int, Nothing}

    """
    Information about the client

    # Tags
    - since – 3.15.0
    """
    clientInfo::Union{Nothing, @interface begin
        "The name of the client as defined by the client."
        name::String

        "The client's version as defined by the client."
        version::Union{String, Nothing} = nothing
    end} = nothing

    """
    The locale the client is currently showing the user interface in.
    This must not necessarily be the locale of the operating system.

    Uses IETF language tags as the value's syntax
    (see https://en.wikipedia.org/wiki/IETF_language_tag).

    # Tags
    - since – 3.16.0
    """
    locale::Union{String, Nothing} = nothing

    """
    The rootPath of the workspace. Is null if no folder is open.

    # Tags
    - deprecated – in favour of `rootUri`.
    """
    rootPath::Union{String, Nothing} = nothing

    """
    The rootUri of the workspace. Is null if no folder is open. If both `rootPath` and
    `rootUri` are set `rootUri` wins.

    # Tags
    - deprecated – in favour of `workspaceFolders`
    """
    rootUri::Union{DocumentUri, Nothing}

    "User provided initialization options."
    initializationOptions::Union{Any, Nothing} = nothing

    "The capabilities provided by the client (editor or tool)"
    capabilities::ClientCapabilities

    "The initial trace setting. If omitted trace is disabled ('off')."
    trace::Union{TraceValue.Ty, Nothing} = nothing

    """
    The workspace folders configured in the client when the server starts.
    This property is only available if the client supports workspace folders.
    It can be `null` if the client supports workspace folders but none are configured.

    # Tags
    - since – 3.6.0
    """
    workspaceFolders::Union{Vector{WorkspaceFolder}, Nothing} = nothing
end

"""
The initialize request is sent as the first request from the client to the server.
If the server receives a request or notification before the initialize request it should act
as follows:
   - For a request the response should be an error with code: -32002. The message
     can be picked by the server.
   - Notifications should be dropped, except for the exit notification. This will allow
     the exit of a server without an initialize request.

Until the server has responded to the initialize request with an `InitializeResult`,
the client must not send any additional requests or notifications to the server.
In addition the server is not allowed to send any requests or notifications to the client
until it has responded with an `InitializeResult`, with the exception that during the
initialize request the server is allowed to send the notifications `window/showMessage`,
`window/logMessage` and `telemetry/event` as well as the `window/showMessageRequest`
request to the client. In case the client sets up a progress token in the initialize params
(e.g. property `workDoneToken`) the server is also allowed to use that token
(and only that token) using the `\$/progress` notification sent from the server to the
client.
The initialize request may only be sent once.
"""
@interface InitializeRequest @extends RequestMessage begin
    method::String = "initialize"
    params::InitializeParams
end

@interface InitializeResult begin
    "The capabilities the language server provides."
    capabilities::ServerCapabilities

    """
    Information about the server.

    # Tags
    - since – 3.15.0
    """
    serverInfo::Union{Nothing, @interface begin
        "The name of the server as defined by the server."
        name::String

        "The server's version as defined by the server."
        version::Union{String, Nothing} = nothing
    end} = nothing
end

"Known error codes for an `InitializeErrorCodes`."
@namespace InitializeErrorCodes::Int begin
    """
    If the protocol version provided by the client can't be handled by the server.

    # Tags
    - deprecated – This initialize error got replaced by client capabilities.
                There is no version handshake in version 3.0x
    """
    unknownProtocolVersion = 1
end

@interface InitializeError begin
    """
    Indicates whether the client execute the following retry logic:
    (1) show the message provided by the ResponseError to the user;
    (2) user selects retry or cancel;
    (3) if user selected retry the initialize method is sent again.
    """
    retry::Bool
end

@interface InitializeResponseError @extends ResponseError begin
    code::InitializeErrorCodes.Ty
    data::InitializeError
end

@interface InitializeResponse @extends ResponseMessage begin
    result::Union{InitializeResult, Nothing}
    error::Union{InitializeResponseError, Nothing} = nothing
end

"""
The initialized notification is sent from the client to the server after the client received
the result of the initialize request but before the client is sending any other request or
notification to the server. The server can use the initialized notification, for example,
to dynamically register capabilities. The initialized notification may only be sent once.
"""
@interface InitializedNotification @extends NotificationMessage begin
    method::String = "initialized"
end
