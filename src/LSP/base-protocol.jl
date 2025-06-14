# Base types
# =========

"""
A special object representing `null` value.
When used as a field specified as `StructTypes.omitempties`, the key-value pair is not
omitted in the serialized JSON but instead appears as `null`.
This special object is specifically intended for use in `ResponseMessage`.
"""
struct Null end
const null = Null()
StructTypes.StructType(::Type{Null}) = StructTypes.CustomStruct()
StructTypes.lower(::Null) = nothing
push!(exports, :Null, :null)

const boolean = Bool
const string = String

"""
Defines an integer number in the range of -2^31 to 2^31 - 1.
"""
const integer = Int

"""
Defines an unsigned integer number in the range of 0 to 2^31 - 1.
"""
const uinteger = UInt

"""
Defines a decimal number.
Since decimal numbers are very rare in the language server specification we denote the exact
range with every decimal using the mathematics interval notation (e.g. `[0, 1]` denotes all
decimals `d` with `0 <= d <= 1`).
"""
const decimal = Float64

"""
The LSP any type

# Tags
- since – 3.17.0
"""
const LSPAny = Any

"""
LSP object definition.

# Tags
- since – 3.17.0
"""
const LSPObject = Dict{String,Any}

"""
LSP arrays.

# Tags
- since – 3.17.0
"""
const LSPArray = Vector{Any}

# Abstract Message
# ================

"""
A general message as defined by JSON-RPC.
The language server protocol always uses “2.0” as the jsonrpc version.
"""
@interface Message begin
    jsonrpc::String = "2.0"
end

# Request Message
# ===============

"""
A request message to describe a request between the client and the server.
Every processed request must send a response back to the sender of the request.
"""
@interface RequestMessage @extends Message begin
    "The request id."
    id::Union{Int, String}

    "The method to be invoked."
    method::String

    "The method's params."
    params::Union{Any, Nothing} = nothing
end

# Respose Message
# ===============

@namespace ErrorCodes::Int begin
    ParseError = -32700
    InvalidRequest = -32600
    MethodNotFound = -32601
    InvalidParams = -32602
    InternalError = -32603

    """
    This is the start range of JSON-RPC reserved error codes.
    It doesn't denote a real error code. No LSP error codes should be defined between
    the start and end range. For backwards compatibility the `ServerNotInitialized` and
    the `UnknownErrorCode` are left in the range.

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
    parameters were valid. The error message should contain human readable information about
    why the request failed.

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
    The server detected that the content of a document got modified outside normal
    conditions. A server should NOT send this error code if it detects a content change
    in it unprocessed messages. The result even computed on an older state might still be
    useful for the client. If a client decides that a result is not of any use anymore
    the client should cancel the request.
    """
    ContentModified = -32801

    """
    The client has canceled a request and a server has detected the cancel.
    """
    RequestCancelled = -32800

    """
    This is the end range of LSP reserved error codes. It doesn't denote a real error code.

    # Tags
    - since – 3.16.0
    """
    lspReservedErrorRangeEnd = -32800
end  # @namespace ErrorCodes

@interface ResponseError begin
    "A number indicating the error type that occurred."
    code::ErrorCodes.Ty

    "A string providing a short description of the error."
    message::String

    """
    A primitive or structured value that contains additional information about the error.
    Can be omitted.
    """
    data::Union{Any, Nothing} = nothing
end

"""
A Response Message sent as a result of a request.
If a request doesn’t provide a result value the receiver of a request still needs to return
a response message to conform to the JSON-RPC specification.
The result property of the ResponseMessage should be set to null in this case to signal a
successful request.
"""
@interface ResponseMessage @extends Message begin
    "The request id."
    id::Union{Int, String, Nothing}

    """
    The result of a request. This member is REQUIRED on success.
    This member MUST NOT exist if there was an error invoking the method.

    This means that this field should be non-`nothing` on success (i.e. should be `null`
    if nothing is specified to be returned as `result`),
    and should be `nothing` on failure with `error` set to be non-`nothing`.
    """
    result::Union{Any, Null, Nothing}

    "The error object in case a request fails."
    error::Union{ResponseError, Nothing} = nothing
end

# Notification Message
# ====================

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

# $ Notifications and Requests
# ============================

"""
Notification and requests whose methods start with `\$/` are messages which are protocol
implementation dependent and might not be implementable in all clients or servers.
For example if the server implementation uses a single threaded synchronous programming
language then there is little a server can do to react to a `\$/cancelRequest` notification.
If a server or client receives notifications starting with `\$/` it is free to ignore
the notification. If a server or client receives a request starting with `\$/`
it must error the request with error code `MethodNotFound` (e.g. `-32601`).
"""
:(dollar_requests)

# Cancellation Support
# ====================

@interface CancelParams begin
    "The request id to cancel."
    id::Union{Int, String}
end

"""
The base protocol offers support for request cancellation.
To cancel a request, a notification message with the following properties is sent:

Notification:
- method: `\$/cancelRequest`
- params: `CancelParams`

A request that got canceled still needs to return from the server and send a response back.
It can not be left open / hanging. This is in line with the JSON-RPC protocol that requires
that every request sends a response back. In addition it allows for returning partial results
on cancel. If the request returns an error response on cancellation it is advised to set the
error code to `ErrorCodes.RequestCancelled`.
"""
@interface CancelRequestNotification @extends NotificationMessage begin
    method::String = "\$/cancelRequest"
    params::CancelParams
end

# Progress Support
# ================

const ProgressToken = Union{Int, String}

@interface ProgressParams begin
    "The progress token provided by the client or server."
    token::ProgressToken

    "The progress data."
    value::Any
end

"""
The base protocol offers also support to report progress in a generic fashion.
This mechanism can be used to report any kind of progress including [work done progress](@ref work_done_progress)
(usually used to report progress in the user interface using a progress bar) and
[partial result progress](@ref partial_result_progress) to support streaming of results.

Notification:
- method: `\$/progress`
- params: `ProgressParams`

Progress is reported against a token.
The token is different than the request ID which allows to report progress out of band
and also for notification.

# Tags
- since – 3.15.0
"""
@interface ProgressNotification @extends NotificationMessage begin
    method::String = "\$/progress"
    params::ProgressParams
end
