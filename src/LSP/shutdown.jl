"""
The shutdown request is sent from the client to the server. It asks the server to shut down,
but to not exit (otherwise the response might not be delivered correctly to the client).
There is a separate exit notification that asks the server to exit. Clients must not send
any notifications other than exit or requests to a server to which they have sent a shutdown
request. Clients should also wait with sending the exit notification until they have
received a response from the shutdown request.

If a server receives requests after a shutdown request those requests should error with
`InvalidRequest`.
"""
@interface ShutdownRequest @extends RequestMessage begin
    method::String = "shutdown"
end

# TODO: Should this also have an `error::ErrorCodes.Ty` field?
@interface ShutdownResponse @extends ResponseMessage begin
    result::Union{Null, Nothing} = nothing
end

"""
A notification to ask the server to exit its process. The server should exit with
success code 0 if the shutdown request has been received before;
otherwise with error code 1.
"""
@interface ExitNotification @extends NotificationMessage begin
    method::String = "exit"
end
