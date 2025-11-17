module JSONRPC

export Endpoint, send

using JSON

mutable struct Endpoint
    in_msg_queue::Channel{Any}
    out_msg_queue::Channel{Any}
    read_task::Task
    write_task::Task
    @atomic isopen::Bool

    function Endpoint(err_handler, in::IO, out::IO, method_dispatcher)
        in_msg_queue = Channel{Any}(Inf)
        out_msg_queue = Channel{Any}(Inf)

        local endpoint::Endpoint

        read_task = Threads.@spawn :interactive while true
            if @isdefined(endpoint) && !isopen(endpoint)
                break
            end
            msg = @something try
                readmsg(in, method_dispatcher)
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
                    writemsg(out, msg)
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

function Endpoint(in::IO, out::IO, method_dispatcher)
    Endpoint(in, out, method_dispatcher) do isread::Bool, err, bt
        @nospecialize err
        @error "Error in Endpoint $(isread ? "reading" : "writing") task"
        Base.display_error(stderr, err, bt)
    end
end

function readmsg(io::IO, method_dispatcher)
    msg_str = @something read_transport_layer(io) return nothing
    lazyjson = JSON.lazy(msg_str)
    if hasproperty(lazyjson, :method)
        method = lazyjson.method[]
        if method isa String && haskey(method_dispatcher, method)
            return JSON.parse(lazyjson, method_dispatcher[method])
        end
        return JSON.parse(lazyjson, Dict{Symbol,Any})
    else # TODO parse to ResponseMessage?
        return JSON.parse(lazyjson, Dict{Symbol,Any})
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
    @isdefined(var"Content-Length") || error("Got header without Content-Length")
    message_length = parse(Int, var"Content-Length")
    return String(read(io, message_length))
end

function writemsg(io::IO, @nospecialize msg)
    msg_str = JSON.json(msg; omit_null=true)
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

function send(endpoint::Endpoint, @nospecialize(msg::Any))
    check_dead_endpoint!(endpoint)
    put!(endpoint.out_msg_queue, msg)
    return msg
end

end # module JSONRPC
