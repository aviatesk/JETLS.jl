module JSONRPC

export
    Endpoint, Message, RequestMessage, ResponseMessage, NotificationMessage,
    ResponseError, send

using JSON3, StructTypes

# COMBAK Return `ResponseMessage(_, ResponseError)` instead of `error("...")`?

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
StructTypes.StructType(::Type{ErrorCodes}) = StructTypes.NumberType()
StructTypes.numbertype(::Type{ErrorCodes}) = Int

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

abstract type Message end

struct RequestMessage <: Message
    jsonrpc::String
    id::Int
    method::String
    params
    RequestMessage(id::Int, method::String, @nospecialize(params=nothing)) =
        new("2.0", id, method, params)
end

struct ResponseMessage <: Message
    jsonrpc::String
    id::Int
    result
    error::ResponseError
    function ResponseMessage(id::Int, @nospecialize(result))
        if result === nothing
            error("`ResponseMessage(id::Int, result)` construct expects non-`nothing` `result` argument")
        end
        return new("2.0", id, result)
    end
    ResponseMessage(id::Int, error::ResponseError) = new("2.0", id, nothing, error)
end
StructTypes.omitempties(::Type{ResponseMessage}) = (:result,)

struct NotificationMessage <: Message
    jsonrpc::String
    method::String
    params
    NotificationMessage(method::String, @nospecialize(params=nothing)) =
        new("2.0", method, params)
end

function tomsg(json::Dict{Symbol,Any})
    if haskey(json, :id)
        id = json[:id]
        if !isa(id, Int)
            isa(id, String) || error("Non-parseable `id` given")
            id = parse(Int, id)
        end
        if haskey(json, :method) # this must be a RequestMessage
            method = json[:method]
            isa(method, String) || error("RequestMessage must have `:method::String`")
            return RequestMessage(id, method, get(json, :params, nothing))
        else # this must be a ResponseMessage
            if haskey(json, :result)
                return ResponseMessage(id, json[:result])
            else
                haskey(json, :error) || error("ResponseMessage must have either of `:result` or `:error`")
                error = json[:error]
                haskey(error, :code) || error("ResponseError must have `:code::Int`")
                code = error[:code]
                isa(code, Int) || error("ResponseError must have `:code::Int`")
                haskey(error, :message) || error("ResponseError must have `:message::String`")
                message = json[:message]
                isa(message, String) || error("ResponseError must have `:message::String`")
                error = ResponseError(ErrorCodes(code), message, get(json, :data, nothing))
                return ResponseMessage(id, error)
            end
        end
    else # this must be a NotificationMessage
        haskey(json, :method) || error("NotificationMessage must have :method")
        return NotificationMessage(json[:method], get(json, :params, nothing))
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
                msg_json = JSON3.read(msg_str, Dict{Symbol,Any})
                msg = tomsg(msg_json)
                put!(in_msg_queue, msg)
            end
        catch err
            handle_err(err, err_handler)
        end

        write_task = @async try
            for msg in out_msg_queue
                if isopen(out)
                    msg_str = JSON3.write(msg)
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
        error("header without Content-Length")
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
