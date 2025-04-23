@interface ShutdownRequest @extends RequestMessage begin
    method::String = "shutdown"
end

@interface ShutdownResponse @extends ResponseMessage begin
    result::Union{Null, Nothing} = nothing
end

@interface ExitNotification @extends NotificationMessage begin
    method::String = "exit"
end
