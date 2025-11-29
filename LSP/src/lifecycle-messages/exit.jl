"""
A notification to ask the server to exit its process. The server should exit with
success code 0 if the shutdown request has been received before;
otherwise with error code 1.
"""
@interface ExitNotification @extends NotificationMessage begin
    method::String = "exit"
end
