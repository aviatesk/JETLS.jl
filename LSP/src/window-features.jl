# Window Features
# ===============

# MessageType
# ===========

"""
Message types for window notifications and requests.
"""
@namespace MessageType::Int begin
    "An error message."
    Error = 1
    "A warning message."
    Warning = 2
    "An information message."
    Info = 3
    "A log message."
    Log = 4
    "A debug message."
    Debug = 5
end

# ShowMessage Notification
# ========================

@interface ShowMessageParams begin
    """
    The message type. See [`MessageType`](@ref).
    """
    type::MessageType.Ty

    """
    The actual message.
    """
    message::String
end

"""
The show message notification is sent from a server to a client to ask the client to
display a particular message in the user interface.
"""
@interface ShowMessageNotification @extends NotificationMessage begin
    method::String = "window/showMessage"
    params::ShowMessageParams
end

# ShowMessage Request
# ===================

"""
Show message request client capabilities.
"""
@interface ShowMessageRequestClientCapabilities begin
    """
    Capabilities specific to the MessageActionItem type.
    """
    messageActionItem::Union{Nothing, @interface begin
        """
        Whether the client supports additional attributes which
        are preserved and sent back to the server in the
        request's response.
        """
        additionalPropertiesSupport::Union{Nothing, Bool} = nothing
    end} = nothing
end

@interface MessageActionItem begin
    """
    A short title like 'Retry', 'Open Log' etc.
    """
    title::String
end

@interface ShowMessageRequestParams begin
    """
    The message type. See [`MessageType`](@ref).
    """
    type::MessageType.Ty

    """
    The actual message.
    """
    message::String

    """
    The message action items to present.
    """
    actions::Union{Nothing, Vector{MessageActionItem}} = nothing
end

"""
The show message request is sent from a server to a client to ask the client to display a
particular message in the user interface. In addition to the show message notification the
request allows to pass actions and to wait for an answer from the client.
"""
@interface ShowMessageRequest @extends RequestMessage begin
    method::String = "window/showMessageRequest"
    params::ShowMessageRequestParams
end

@interface ShowMessageResponse @extends ResponseMessage begin
    result::Union{Null, MessageActionItem, Nothing}
end

# Show Document Request
# =====================

"""
Client capabilities for the show document request.

# Tags
- since - 3.16.0
"""
@interface ShowDocumentClientCapabilities begin
    """
    The client has support for the show document
    request.
    """
    support::Bool
end

"""
Params to show a resource.

# Tags
- since - 3.16.0
"""
@interface ShowDocumentParams begin
    """
    The uri to show.
    """
    uri::URI

    """
    Indicates to show the resource in an external program.
    To show, for example, `https://code.visualstudio.com/`
    in the default WEB browser set `external` to `true`.
    """
    external::Union{Nothing, Bool} = nothing

    """
    An optional property to indicate whether the editor
    showing the document should take focus or not.
    Clients might ignore this property if an external
    program is started.
    """
    takeFocus::Union{Nothing, Bool} = nothing

    """
    An optional selection range if the document is a text
    document. Clients might ignore the property if an
    external program is started or the file is not a text
    file.
    """
    selection::Union{Nothing, Range} = nothing
end

"""
The result of an show document request.

# Tags
- since - 3.16.0
"""
@interface ShowDocumentResult begin
    """
    A boolean indicating if the show was successful.
    """
    success::Bool
end

"""
The show document request is sent from a server to a client to ask the client to display a
particular resource referenced by a URI in the user interface.

# Tags
- since - 3.16.0
"""
@interface ShowDocumentRequest @extends RequestMessage begin
    method::String = "window/showDocument"
    params::ShowDocumentParams
end

@interface ShowDocumentResponse @extends ResponseMessage begin
    result::Union{ShowDocumentResult, Nothing}
end

# LogMessage Notification
# =======================

@interface LogMessageParams begin
    """
    The message type. See MessageType.
    """
    type::MessageType.Ty

    """
    The actual message.
    """
    message::String
end

"""
The log message notification is sent from the server to the client to ask the client to
log a particular message.
"""
@interface LogMessageNotification @extends NotificationMessage begin
    method::String = "window/logMessage"
    params::LogMessageParams
end

# Create Work Done Progress
# =========================

@interface WorkDoneProgressCreateParams begin
    """
    The token to be used to report progress.
    """
    token::ProgressToken
end

"""
The `window/workDoneProgress/create` request is sent from the server to the client to ask
the client to create a work done progress.
"""
@interface WorkDoneProgressCreateRequest @extends RequestMessage begin
    method::String = "window/workDoneProgress/create"
    params::WorkDoneProgressCreateParams
end

@interface WorkDoneProgressCreateResponse @extends ResponseMessage begin
    result::Union{Null, Nothing}

    """
    code and message set in case an exception happens during the `window/workDoneProgress/create` request.
    In case an error occurs a server must not send any progress notification using the token
    provided in the `WorkDoneProgressCreateParams`.
    """
    error::Union{ResponseError, Nothing} = nothing
end

# Cancel a Work Done Progress
# ===========================

@interface WorkDoneProgressCancelParams begin
    """
    The token to be used to report progress.
    """
    token::ProgressToken
end

"""
The `window/workDoneProgress/cancel` notification is sent from the client to the server to
cancel a progress initiated on the server side using the `window/workDoneProgress/create`.
The progress need not be marked as `cancellable` to be cancelled and a client may cancel a
progress for any number of reasons: in case of error, reloading a workspace etc.
"""
@interface WorkDoneProgressCancelNotification @extends NotificationMessage begin
    method::String = "window/workDoneProgress/cancel"
    params::WorkDoneProgressCancelParams
end
