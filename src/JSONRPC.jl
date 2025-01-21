module JSONRPC

export Endpoint, send

using JSON3

using ..JETLS.LSP: method_dispatcher

mutable struct Endpoint
    in_msg_queue::Channel{Any}
    out_msg_queue::Channel{Any}
    read_task::Task
    write_task::Task
    state::Symbol

    function Endpoint(in::IO, out::IO, err_handler = nothing)
        in_msg_queue = Channel{Any}(Inf)
        out_msg_queue = Channel{Any}(Inf)

        read_task = @async try
            while true
                msg = readmsg(in)
                msg === nothing && break
                put!(in_msg_queue, msg)
            end
        catch err
            handle_err(err, err_handler)
        end

        write_task = @async try
            for msg in out_msg_queue
                if isopen(out)
                    writemsg(out, msg)
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

function readmsg(io::IO)
    msg_str = read_transport_layer(io)
    msg_str === nothing && return nothing
    parsed = JSON3.read(msg_str, Parsed)
    return reparse(parsed, msg_str)
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

const Parsed = @NamedTuple{id::Union{Nothing,Int}, method::Union{Nothing,String}}
function reparse(parsed::Parsed, msg_str::String)
    if parsed.method !== nothing
        if haskey(method_dispatcher, parsed.method)
            return JSON3.read(msg_str, method_dispatcher[parsed.method])
        end
        return JSON3.read(msg_str, Dict{Symbol,Any})
    else # TODO parse to ResponseMessage?
        return JSON3.read(msg_str, Dict{Symbol,Any})
    end
end

function writemsg(io::IO, @nospecialize msg)
    msg_str = JSON3.write(msg)
    write_transport_layer(io, msg_str)
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

function send(endpoint::Endpoint, @nospecialize(msg::Any))
    check_dead_endpoint!(endpoint)
    put!(endpoint.out_msg_queue, msg)
    return msg
end

end
