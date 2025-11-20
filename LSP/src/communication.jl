using JSON3: JSON3

"""
    Endpoint

A bidirectional communication endpoint for Language Server Protocol messages.

`Endpoint` manages asynchronous reading and writing of LSP messages over IO streams.
It spawns two separate tasks:
- A read task that continuously reads messages from the input stream and queues them
- A write task that continuously writes messages from the output queue to the output stream

Both tasks run on the `:interactive` thread pool to ensure responsive message handling.

- `in_msg_queue::Channel{Any}`: Queue of incoming messages read from the input stream
- `out_msg_queue::Channel{Any}`: Queue of outgoing messages to be written to the output stream
- `read_task::Task`: Task handling message reading
- `write_task::Task`: Task handling message writing
- `isopen::Bool`: Atomic flag indicating whether the endpoint is open

There are two constructors:
- `Endpoint(in::IO, out::IO)`
- `Endpoint(err_handler, in::IO, out::IO)`

The later creates an endpoint with custom error handler or default error handler that logs to `stderr`.
The error handler should have signature `(isread::Bool, err, backtrace) -> nothing`.

# Example
```julia
endpoint = Endpoint(stdin, stdout)
for msg in endpoint
    # Process incoming messages
    send(endpoint, response)
end
close(endpoint)
```
"""
mutable struct Endpoint
    in_msg_queue::Channel{Any}
    out_msg_queue::Channel{Any}
    read_task::Task
    write_task::Task
    @atomic isopen::Bool

    function Endpoint(err_handler, in::IO, out::IO)
        in_msg_queue = Channel{Any}(Inf)
        out_msg_queue = Channel{Any}(Inf)

        local endpoint::Endpoint

        read_task = Threads.@spawn :interactive while true
            if @isdefined(endpoint) && !isopen(endpoint)
                break
            end
            msg = @something try
                readlsp(in)
            catch err
                err_handler(#=isread=#true, err, catch_backtrace())
                continue
            end break
            put!(in_msg_queue, msg)
            GC.safepoint()
        end

        write_task = Threads.@spawn :interactive for msg in out_msg_queue
            if isopen(out)
                try
                    writelsp(out, msg)
                catch err
                    err_handler(#=isread=#false, err, catch_backtrace())
                    continue
                end
            else
                @error "Output channel has been closed before message serialization:" msg
                break
            end
            GC.safepoint()
        end

        return endpoint = new(in_msg_queue, out_msg_queue, read_task, write_task, true)
    end
end

function Endpoint(in::IO, out::IO)
    Endpoint(in, out) do isread::Bool, err, bt
        @nospecialize err
        @error "Error in Endpoint $(isread ? "reading" : "writing") task"
        Base.display_error(stderr, err, bt)
    end
end

readlsp(io::IO) = to_lsp_object(@something read_transport_layer(io) return nothing)

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
    @isdefined(var"Content-Length") || error("Got header without Content-Length")
    message_length = parse(Int, var"Content-Length")
    return String(read(io, message_length))
end

const Parsed = @NamedTuple{method::Union{Nothing,String}}

function to_lsp_object(msg_str::AbstractString)
    parsed = JSON3.read(msg_str, Parsed)
    parsed_method = parsed.method
    if parsed_method !== nothing
        if haskey(method_dispatcher, parsed_method)
            return JSON3.read(msg_str, method_dispatcher[parsed_method])
        end
        return JSON3.read(msg_str, Dict{Symbol,Any})
    end
    # TODO Parse response message?
    return JSON3.read(msg_str, Dict{Symbol,Any})
end

writelsp(io::IO, @nospecialize msg) = write_transport_layer(io, to_lsp_json(msg))

function write_transport_layer(io::IO, response::String)
    response_utf8 = transcode(UInt8, response)
    n = length(response_utf8)
    write(io, "Content-Length: $n\r\n\r\n")
    write(io, response_utf8)
    flush(io)
    return n
end

to_lsp_json(@nospecialize msg) = JSON3.write(msg)

function Base.close(endpoint::Endpoint)
    flush(endpoint)
    close(endpoint.in_msg_queue)
    close(endpoint.out_msg_queue)
    # TODO we would also like to close the read Task
    # But unclear how to do that without also closing
    # the socket, which we don't want to do
    # fetch(endpoint.read_task)
    fetch(endpoint.write_task)
    @atomic :release endpoint.isopen = false
    return endpoint
end

Base.isopen(endpoint::Endpoint) = @atomic :acquire endpoint.isopen

check_dead_endpoint!(endpoint::Endpoint) = isopen(endpoint) || error("Endpoint is closed")

function Base.flush(endpoint::Endpoint)
    check_dead_endpoint!(endpoint)
    while isready(endpoint.out_msg_queue)
        yield()
    end
end

function Base.iterate(endpoint::Endpoint, _=nothing)
    isopen(endpoint) || return nothing
    return take!(endpoint.in_msg_queue), nothing
end

"""
    send(endpoint::Endpoint, msg)

Send a message through the endpoint's output queue.

The message will be asynchronously written to the output stream by the endpoint's write task.
This function is non-blocking and returns immediately after queueing the message.

# Arguments
- `endpoint::Endpoint`: The endpoint to send the message through
- `msg`: The message to send (typically an LSP message structure)

# Throws
- `ErrorException`: If the endpoint is closed
"""
function send(endpoint::Endpoint, @nospecialize(msg::Any))
    check_dead_endpoint!(endpoint)
    put!(endpoint.out_msg_queue, msg)
    nothing
end
