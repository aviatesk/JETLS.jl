"""
    handle_ResponseMessage(server::Server, msg::Dict{Symbol,Any}) -> res::Bool

Handler for `ResponseMessage` sent from the client.
Note that `msg` is just a `Dict{Symbol,Any}` object because the current implementation of
JSONRPC.jl  does not convert `ResponseMessage` to LSP objects defined in LSP.jl.

Also, this handler does not handle all `ResponseMessage`s, but only returns `true`
when the server handles `msg` in some way, and returns `false` in other cases,
in which case an unhandled message log is output in `handle_message` as a reference
for developers.
"""
function handle_ResponseMessage(server::Server, msg::Dict{Symbol,Any})
    id = get(msg, :id, nothing)
    currently_requested = server.state.currently_requested
    if id isa String && haskey(currently_requested, id)
        request_caller = currently_requested[id]
        delete!(currently_requested, id)
        handle_requested_response(server, msg, request_caller)
        return true
    end
    return false
end

function handle_requested_response(server::Server, msg::Dict{Symbol,Any},
                                   @nospecialize request_caller::RequestCaller)
    if request_caller isa RunFullAnalysisCaller
        (; uri, onsave, token) = request_caller
        run_full_analysis!(server, uri; onsave, token)
    else
        error("Invalid request caller type")
    end
end
