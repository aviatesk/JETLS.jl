# ------------------------------------------------------------------------------------------
# Errors.

@namespace ErrorCodes::Int begin
    ParseError = -32700
    InvalidRequest = -32600
    MethodNotFound = -32601
    InvalidParams = -32602
    InternalError = -32603

    """
    This is the start range of JSON-RPC reserved error codes.
    It doesn't denote a real error code. No LSP error codes should be defined between the start
    and end range. For backwards compatibility the `ServerNotInitialized` and the
    `UnknownErrorCode` are left in the range.

    # Tags
    - since – 3.16.0
    """
    jsonrpcReservedErrorRangeStart = -32099
    """
    # Tags
    - deprecated – use jsonrpcReservedErrorRangeStart
    """
    serverErrorStart = -32099

    """
    Error code indicating that a server received a notification or request before the server
    has received the `initialize` request.
    """
    ServerNotInitialized = -32002
    UnknownErrorCode = -32001

    """
    This is the end range of JSON-RPC reserved error codes.
    It doesn't denote a real error code.

    # Tags
    - since – 3.16.0"
    """
    jsonrpcReservedErrorRangeEnd = -32000
    """
    # Tags
    - deprecated – use jsonrpcReservedErrorRangeEnd
    """
    serverErrorEnd = -32000

    """
    This is the start range of LSP reserved error codes.
    It doesn't denote a real error code.

    # Tags
    - since – 3.16.0
    """
    lspReservedErrorRangeStart = -32899

    """
    A request failed but it was syntactically correct, e.g the method name was known and the
    parameters were valid. The error message should contain human readable information about why
    the request failed.

    # Tags
    - since – 3.17.0
    """
    RequestFailed = -32803

    """
    The server cancelled the request. This error code should only be used for requests that
    explicitly support being server cancellable.

    # Tags
    - since – 3.17.0
    """
    ServerCancelled = -32802

    """
    "The server detected that the content of a document got modified outside normal conditions.
    A server should NOT send this error code if it detects a content change in it unprocessed
    messages. The result even computed on an older state might still be useful for the client.
    If a client decides that a result is not of any use anymore the client should cancel the request.
    """
    ContentModified = -32801

    """
    The client has canceled a request and a server has detected the cancel.
    """
    RequestCancelled = -32800

    """
    This is the end range of LSP reserved error codes. It doesn't denote a real error code.

    # Tags
    - since – 3.16.0"
    """
    lspReservedErrorRangeEnd = -32800
end # @namespace ErrorCodes

@interface ResponseError begin
    "A number indicating the error type that occurred."
    code::ErrorCodes.Ty

    "A string providing a short description of the error."
    message::String

    "A primitive or structured value that contains additional information about the error. Can be omitted."
    data::Union{Any, Nothing} = nothing
end

# ------------------------------------------------------------------------------------------
# Messages.

"""
A general message as defined by JSON-RPC.
The language server protocol always uses “2.0” as the jsonrpc version.
"""
@interface Message begin
    jsonrpc::String = "2.0"
end

"""
A request message to describe a request between the client and the server.
Every processed request must send a response back to the sender of the request.
"""
@interface RequestMessage @extends Message begin
    "The request id."
    id::Int

    "The method to be invoked."
    method::String

    "The method's params."
    params::Union{Any, Nothing} = nothing
end

# TODO Revisit this to correctly lower this struct

"""
A Response Message sent as a result of a request.
If a request doesn’t provide a result value the receiver of a request still needs to return
a response message to conform to the JSON-RPC specification.
The result property of the ResponseMessage should be set to null in this case to signal a
successful request.
"""
@interface ResponseMessage @extends Message begin
    "The request id."
    id::Union{Int, Nothing}

    """
    The result of a request. This member is REQUIRED on success.
    This member MUST NOT exist if there was an error invoking the method.
    """
    result::Union{Any, Nothing} = nothing

    "The error object in case a request fails."
    error::Union{ResponseError, Nothing} = nothing
end

"""
A notification message. A processed notification message must not send a response back.
They work like events.
"""
@interface NotificationMessage @extends Message begin
    "The method to be invoked."
    method::String

    "The notification's params."
    params::Union{Any, Nothing} = nothing
end
