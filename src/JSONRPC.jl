module JSONRPC

export
    Endpoint, RequestMessage, ResponseMessage, NotificationMessage, ErrorCodes, ResponseError,
    send

using JSON

abstract type Message end

@enum ErrorCodes begin
    ParseError = -32700;
    InvalidRequest = -32600;
    MethodNotFound = -32601;
    InvalidParams = -32602;
    InternalError = -32603;

    # /**
    #  * This is the start range of JSON-RPC reserved error codes.
    #  * It doesn't denote a real error code. No LSP error codes should
    #  * be defined between the start and end range. For backwards
    #  * compatibility the `ServerNotInitialized` and the `UnknownErrorCode`
    #  * are left in the range.
    #  *
    #  * @since 3.16.0
    #  */
    jsonrpcReservedErrorRangeStart = -32099;

    # /** @deprecated use jsonrpcReservedErrorRangeStart */
    # serverErrorStart = jsonrpcReservedErrorRangeStart;

    # /**
    #  * Error code indicating that a server received a notification or
    #  * request before the server has received the `initialize` request.
    #  */
    ServerNotInitialized = -32002;
    UnknownErrorCode = -32001;

    # /**
    #  * This is the end range of JSON-RPC reserved error codes.
    #  * It doesn't denote a real error code.
    #  *
    #  * @since 3.16.0
    #  */
    jsonrpcReservedErrorRangeEnd = -32000;
    # /** @deprecated use jsonrpcReservedErrorRangeEnd */
    # serverErrorEnd = jsonrpcReservedErrorRangeEnd;

    # /**
    #  * This is the start range of LSP reserved error codes.
    #  * It doesn't denote a real error code.
    #  *
    #  * @since 3.16.0
    #  */
    lspReservedErrorRangeStart = -32899;

    # /**
    #  * A request failed but it was syntactically correct, e.g the
    #  * method name was known and the parameters were valid. The error
    #  * message should contain human readable information about why
    #  * the request failed.
    #  *
    #  * @since 3.17.0
    #  */
    RequestFailed = -32803;

    # /**
    #  * The server cancelled the request. This error code should
    #  * only be used for requests that explicitly support being
    #  * server cancellable.
    #  *
    #  * @since 3.17.0
    #  */
    ServerCancelled = -32802;

    # /**
    #  * The server detected that the content of a document got
    #  * modified outside normal conditions. A server should
    #  * NOT send this error code if it detects a content change
    #  * in it unprocessed messages. The result even computed
    #  * on an older state might still be useful for the client.
    #  *
    #  * If a client decides that a result is not of any use anymore
    #  * the client should cancel the request.
    #  */
    ContentModified = -32801;

    # /**
    #  * The client has canceled a request and a server as detected
    #  * the cancel.
    #  */
    RequestCancelled = -32800;

    # /**
    #  * This is the end range of LSP reserved error codes.
    #  * It doesn't denote a real error code.
    #  *
    #  * @since 3.16.0
    #  */
    # lspReservedErrorRangeEnd = -32800;
end

struct ResponseError <: Exception
    code::ErrorCodes
    message::String
    data::Any
    ResponseError(code::ErrorCodes, msg::String, @nospecialize(data=nothing)) =
        new(code, msg, nothing)
end
function Base.showerror(io::IO, err::ResponseError)
    (; code, message, data) = err
    print(io, code)
    print(io, ": ")
    print(io, message)
    if data !== nothing
        print(io, " (")
        print(io, data)
        print(io, ")")
    end
end
JSON.lower(code::ErrorCodes) = Int(code)

struct RequestMessage <: Message
    id::Int
    method::String
    params
    RequestMessage(id::Int, method::String, @nospecialize(params=nothing)) =
        new(id, method, params)
end

struct ResponseMessage <: Message
    id::Int
    result
    error::ResponseError
    ResponseMessage(id::Int, @nospecialize(result)) = new(id, result)
    ResponseMessage(id::Int, error::ResponseError) = new(id, nothing, error)
end

struct NotificationMessage <: Message
    method::String
    params
    NotificationMessage(method::String, @nospecialize(params=nothing)) =
        new(method, params)
end

function tomsg(json::Dict{String,Any})
    if haskey(json, "id")
        id = json["id"]
        if !isa(id, Int)
            isa(id, String) || return ResponseMessage(#=id=#-1, # XXX,
                ResponseError(InvalidRequest, "[Request|Response]Message with invalid id", id))
            id = parse(Int, id)
        end
        if haskey(json, "method") # this must be a RequestMessage
            method = json["method"]
            isa(method, String) || return ResponseMessage(id,
                ResponseError(InvalidRequest, "RequestMessage with invalid method", method))
            return RequestMessage(id, method, get(json, "params", nothing))
        else # this must be a ResponseMessage
            if haskey(json, "result")
                return ResponseMessage(id, json["result"])
            else
                haskey(json, "code") || return ResponseMessage(id,
                    ResponseError(UnknownErrorCode, "ResponseError without code", json))
                code = json["code"]
                isa(code, Int) || return ResponseMessage(id,
                    ResponseError(UnknownErrorCode, "ResponseError with invalid code", code))
                haskey(json, "message") || return ResponseMessage(id,
                    ResponseError(UnknownErrorCode, "ResponseError without message", json))
                message = json["message"]
                isa(message, String) || return ResponseMessage(id,
                    ResponseError(UnknownErrorCode, "ResponseError with invalid message", message))
                error = ResponseError(ErrorCodes(code), message, get(json, "data", nothing))
                return ResponseMessage(id, error)
            end
        end
    else # this must be a NotificationMessage
        if !haskey(json, "method")
            return ResponseMessage(#=id=#-1, # XXX,
                ResponseError(InvalidRequest, "message without method", json))
        end
        return NotificationMessage(json["method"], get(json, "params", nothing))
    end
end

function JSON.lower(msg::Message)
    out = Dict{String,Any}()
    out["jsonrpc"] = "2.0"
    for fname in fieldnames(typeof(msg))
        out[string(fname)] = getfield(msg, fname)
    end
    return out
end

function JSON.lower(msg::ResponseMessage)
    if isdefined(msg, :error)
        return (; jsonrpc = "2.0", msg.id, msg.error)
    else
        return (; jsonrpc = "2.0", msg.id, msg.result)
    end
end

mutable struct Endpoint
    in_msg_queue::Channel{Message}
    out_msg_queue::Channel{Message}
    read_task::Task
    write_task::Task
    state::Symbol

    function Endpoint(in::IO, out::IO, err_handler = nothing)
        in_msg_queue = Channel{Message}(Inf)
        out_msg_queue = Channel{Message}(Inf)

        read_task = @async try
            while true
                msg_str = read_transport_layer(in)
                msg_str === nothing && break
                if isa(msg_str, ResponseError)
                    msg = ResponseMessage(#=id=#-1, # XXX,
                        ResponseError(InvalidRequest, "invalid transport layer", msg_str))
                    put!(out_msg_queue, msg)
                    continue
                end
                msg_json = JSON.parse(msg_str)
                msg = tomsg(msg_json)
                put!(in_msg_queue, msg)
            end
        catch err
            handle_err(err, err_handler)
        end

        write_task = @async try
            for msg in out_msg_queue
                if isopen(out)
                    msg_str = JSON.json(msg)
                    write_transport_layer(out, msg_str)
                else
                    @info "failed to send" msg
                    # TODO Reconsider at some point whether this should be treated as an error.
                    break
                end
            end
        catch err
            handle_err(err, err_handler)
        end

        return new(in_msg_queue, out_msg_queue, read_task, write_task, :open)
    end
end

function read_transport_layer(io::IO)
    line = chomp(readline(io))
    if line == ""
        return nothing # the stream was closed
    end
    local var"Content-Length"
    while !isempty(line)
        parts = split(line, ":")
        if chomp(parts[1]) == "Content-Length"
            var"Content-Length" = chomp(parts[2])
        end
        line = chomp(readline(io))
    end
    if !@isdefined(var"Content-Length")
        return ResponseError(ParseError, "header without Content-Length")
    end
    message_length = parse(Int, var"Content-Length")
    return String(read(io, message_length))
end

function write_transport_layer(io::IO, response::String)
    response_utf8 = transcode(UInt8, response)
    n = length(response_utf8)
    write(io, "Content-Length: $n\r\n\r\n")
    write(io, response_utf8)
    flush(io)
    return n
end

function handle_err(err, handler)
    @nospecialize err handler
    bt = catch_backtrace()
    if handler !== nothing
        handler(err, bt)
    else
        Base.display_error(stderr, err, bt)
    end
end

function Base.close(endpoint::Endpoint)
    flush(endpoint)
    close(endpoint.in_msg_queue)
    close(endpoint.out_msg_queue)
    # TODO we would also like to close the read Task
    # But unclear how to do that without also closing
    # the socket, which we don't want to do
    # fetch(endpoint.read_task)
    fetch(endpoint.write_task)
    endpoint.state = :closed
    return endpoint
end
function check_dead_endpoint!(endpoint::Endpoint)
    state = endpoint.state
    state === :open || error("Endpoint is $state")
end

function Base.flush(endpoint::Endpoint)
    check_dead_endpoint!(endpoint)
    while isready(endpoint.out_msg_queue)
        yield()
    end
end

function Base.iterate(endpoint::Endpoint, state = nothing)
    check_dead_endpoint!(endpoint)
    return take!(endpoint.in_msg_queue), nothing
end

function send(endpoint::Endpoint, @nospecialize(msg::Message))
    check_dead_endpoint!(endpoint)
    put!(endpoint.out_msg_queue, msg)
    return msg
end

end
