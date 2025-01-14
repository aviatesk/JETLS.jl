module JETLS

export runserver

include("JSONRPC.jl")
using .JSONRPC
include("LSP/LSP.jl")

using JET

runserver(in::IO, out::IO) = runserver((msg, res)->nothing, in, out)
function runserver(callback, in::IO, out::IO)
    endpoint = Endpoint(in, out)
    state = (; uri2diagnostics=Dict{URI,Vector{Any}}())
    shutdown_requested = false
    local exit_code::Int
    try
        for msg in endpoint
            if isa(msg, RequestMessage)
                if msg.method == "shutdown"
                    shutdown_requested = true
                    res = ResponseMessage(msg.id, nothing)
                elseif msg.method == "exit"
                    exit_code = !shutdown_requested
                    break
                elseif shutdown_requested
                    res = ResponseMessage(msg.id, ResponseError(
                        JSONRPC.InvalidRequest, "Received request after a shutdown request requested", msg))
                else
                    res = @invokelatest handle_request_message(state, msg)
                end
            elseif isa(msg, NotificationMessage)
                res = @invokelatest handle_notification_message(state, msg)
            else
                msg = msg::ResponseMessage
                error(lazy"got ResponseMessage: $msg")
            end
            if res === nothing
                continue
            elseif isa(res, ResponseMessage)
                send(endpoint, res)
            else
                error(lazy"expected ResponseMessage but got: $res")
            end
            callback(msg, res)
        end
    catch err
        @info "message handling failed" err
        io = IOBuffer()
        bt = catch_backtrace()
        Base.display_error(io, err, bt)
        print(stderr, String(take!(io)))
    finally
        close(endpoint)
    end
    if @isdefined(exit_code)
        exit(exit_code)
    end
end

function handle_request_message(state, msg::RequestMessage)
    # @info "Handling RequestMessage" msg
    method = msg.method
    if method == "initialize"
        return handle_initialize_request(msg)
    # elseif method == "textDocument/diagnostic"
    #     return handle_diagnostic_request(msg)
    elseif method == "workspace/diagnostic"
        return handle_workspace_diagnostic_request(state, msg)
    else
        @info "unhandled RequestMessage" msg
    end
    return nothing
end

function handle_notification_message(state, msg::NotificationMessage)
    @info "Handling NotificationMessage" msg
    method = msg.method
    if method == "initialized"
        # TODO?
    elseif method == "workspace/didChangeWatchedFiles"
        # TODO
    end
    return nothing
end

global workspaceUri::URI

function handle_initialize_request(msg::RequestMessage)
    global workspaceUri = URI(msg.params["rootUri"])
    return ResponseMessage(msg.id, (;
        capabilities = (;
            positionEncoding = "utf-16",
            diagnosticProvider = (;
                identifier = "JETLS",
                interFileDependenciers = true,
                workspaceDiagnostics= true,
            )
        ),
        serverInfo = (;
            name = "JETLS",
            version = "0.0.0",
        )
    ))
end

global workspaceDiagnosticsVersion::Int = 0

function handle_workspace_diagnostic_request(state, msg::RequestMessage)
    global workspaceUri, workspaceDiagnosticsVersion
    workspaceDiagnosticsVersion += 1
    workspaceDir = uri2filepath(workspaceUri)
    if isnothing(workspaceDir)
        println(stderr, "unexpected uri", workspaceUri)
        return
    end
    if !isempty(state.uri2diagnostics)
        diagnostics = Any[]
        for (uri, _) in state.uri2diagnostics
            suri = string(uri)
            push!(diagnostics, (;
                kind = "unchanged",
                resultId = suri,
                uri=suri,
                version=workspaceDiagnosticsVersion))
        end
        return ResponseMessage(msg.id, (; items = diagnostics))
    end
    pkgname = basename(workspaceDir)
    pkgpath = joinpath(workspaceDir, "src", "$pkgname.jl")
    result = @invokelatest report_file(pkgpath; analyze_from_definitions=true, toplevel_logger=stderr)
    diagnostics = jet_to_workspace_diagnostics(state, result)
    return ResponseMessage(msg.id, (; items = diagnostics))
end

function jet_to_workspace_diagnostics(state, result)
    global workspaceDiagnosticsVersion

    # TODO result.res.toplevel_error_reports
    for report in result.res.inference_error_reports
        uri = filepath2uri(lowercase(jetpath2abspath(string(report.vst[1].file))))
        items = get!(()->Any[], state.uri2diagnostics, uri)

        buf = IOBuffer()
        JET.print_report_message(buf, report)
        message = String(take!(buf))

        push!(items, (;
            message,
            range = (;
                start = (; line=report.vst[1].line-1, character=0),
                var"end" = (; line=report.vst[1].line-1, character=Int(typemax(Int32))),
            )))
    end

    diagnostics = Any[]
    for (uri, items) in state.uri2diagnostics
        suri = string(uri)
        push!(diagnostics, (;
            kind = "full",
            resultId = suri,
            items,
            uri=suri,
            version=workspaceDiagnosticsVersion))
    end

    return diagnostics
end

function jetpath2abspath(path)
    isabspath(path) && return path
    return joinpath(workspaceUri.path, path)
end

# TODO handle standalone toplevel script here
function handle_diagnostic_request(msg::RequestMessage)
    return nothing
end

end # module JETLS
