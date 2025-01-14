module JETLS

export runserver

include("JSONRPC.jl")
using .JSONRPC
include("LSP/LSP.jl")

using JET

runserver(in::IO, out::IO) = runserver(msg::Message->nothing, in, out)
function runserver(callback, in::IO, out::IO)
    endpoint = Endpoint(in, out)
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
                    res = @invokelatest handle_request_message(msg)
                end
            elseif isa(msg, NotificationMessage)
                res = @invokelatest handle_notification_message(msg)
            else
                msg = msg::ResponseMessage
                error(lazy"got ResponseMessage: $msg")
            end
            if res === nothing
            elseif isa(res, ResponseMessage)
                send(endpoint, res)
    if @isdefined(exit_code)
        exit(exit_code)
    end
            else
                error(lazy"expected ResponseMessage but got: $res")
            end
            callback(msg)
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
            callback(msg)
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
    @info "Handling Requests" msg
            callback(msg)
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
end

function handle_request_message(msg::RequestMessage)
    @info "Handling Requests" msg
        print(stderr, String(take!(io)))
    finally
        close(endpoint)
    end
end

function handle_request_message(msg::RequestMessage)
        close(endpoint)
    end
end

function handle_request_message(msg::RequestMessage)
    method = msg.method
    if method == "initialize"
        return handle_initialize_request(msg)
    # elseif method == "textDocument/diagnostic"
    #     return handle_diagnostic_request(msg)
    elseif method == "workspace/diagnostic"
        return handle_workspace_diagnostic_request(msg)
        return handle_initialize_request(msg)
    # elseif method == "textDocument/diagnostic"
    #     return handle_diagnostic_request(msg)
    elseif method == "workspace/diagnostic"
        return handle_workspace_diagnostic_request(msg)
    elseif method == "shutdown"
        return handle_shutdown_request(msg)
    @info "Handling NotificationMessage" msg
        return handle_initialize_request(msg)
    # elseif method == "textDocument/diagnostic"
    #     return handle_diagnostic_request(msg)
    elseif method == "workspace/diagnostic"
        return handle_workspace_diagnostic_request(msg)
    elseif method == "shutdown"
        return handle_shutdown_request(msg)
    else
        @info "unhandled RequestMessage" msg
    end
    return nothing
end

function handle_notification_message(msg::NotificationMessage)
    @info "Handling NotificationMessage" msg
    #     return handle_diagnostic_request(msg)
    elseif method == "workspace/diagnostic"
        return handle_workspace_diagnostic_request(msg)
    elseif method == "shutdown"
        return handle_shutdown_request(msg)
    else
        @info "unhandled RequestMessage" msg
    end
    return nothing
end

function handle_notification_message(msg::NotificationMessage)
        # TODO?
    elseif method == "workspace/diagnostic"
        return handle_workspace_diagnostic_request(msg)
    elseif method == "shutdown"
        return handle_shutdown_request(msg)
    else
        @info "unhandled RequestMessage" msg
    end
    return nothing
end

function handle_notification_message(msg::NotificationMessage)
    method = msg.method
    if method == "initialized"
        # TODO?
        return handle_workspace_diagnostic_request(msg)
    elseif method == "shutdown"
        return handle_shutdown_request(msg)
    else
        @info "unhandled RequestMessage" msg
    end
    return nothing
end

function handle_notification_message(msg::NotificationMessage)
    method = msg.method
    if method == "initialized"
        return handle_initialized_notification(msg)
        # TODO
    elseif method == "shutdown"
        return handle_shutdown_request(msg)
    else
        @info "unhandled RequestMessage" msg
    end
    return nothing
end

function handle_notification_message(msg::NotificationMessage)
    method = msg.method
    if method == "initialized"
        return handle_initialized_notification(msg)
    elseif method == "workspace/didChangeWatchedFiles"
        # TODO
        return handle_shutdown_request(msg)
    else
        @info "unhandled RequestMessage" msg
    end
    return nothing
end

function handle_notification_message(msg::NotificationMessage)
    method = msg.method
    if method == "initialized"
        return handle_initialized_notification(msg)
    elseif method == "workspace/didChangeWatchedFiles"
        return nothing # TODO
    else
        @info "unhandled RequestMessage" msg
    end
    return nothing
end

function handle_notification_message(msg::NotificationMessage)
    method = msg.method
    if method == "initialized"
        return handle_initialized_notification(msg)
    elseif method == "workspace/didChangeWatchedFiles"
        return nothing # TODO
    end
end

function handle_notification_message(msg::NotificationMessage)
    method = msg.method
    if method == "initialized"
        return handle_initialized_notification(msg)
    elseif method == "workspace/didChangeWatchedFiles"
        return nothing # TODO
    end
    @info "unhandled NotificationMessage" msg

global workspaceUri::URI
function jetpath2abspath(path)
    isabspath(path) && return path
    return joinpath(workspaceUri.path, path)
end

function fileuri_to_path(uri)
    m = match(r"file://(.+)", uri)
    if !isnothing(m)
        return String(m[1]::AbstractString)
    end
    error(lazy"unexpected uri given: $uri")
end
    isabspath(path) && return path
    return joinpath(workspaceUri.path, path)
end

function fileuri_to_path(uri)
    m = match(r"file://(.+)", uri)
    if !isnothing(m)
        return String(m[1]::AbstractString)
    end
    error(lazy"unexpected uri given: $uri")
end

function handle_initialize_request(msg::RequestMessage)
    global workspaceUri = URI(msg.params["rootUri"])
    return ResponseMessage(msg.id, (;
        capabilities = (;
global workspaceDiagnostics::Vector{Any}
            version = "0.0.0",
        )
    ))
end

global workspaceDiagnostics::Vector{Any}

    ))
end

function handle_initialized_notification(msg::NotificationMessage)
    return nothing # TODO
end

function handle_shutdown_request(msg::RequestMessage)
    return ResponseMessage(msg.id, ResponseError(JSONRPC.InvalidRequest, "LS shutdown was requested"))
end

global workspaceDiagnosticsVersion::Int = 0

    global workspaceUri, workspaceDiagnostics
    if @isdefined workspaceDiagnostics
        return ResponseMessage(msg.id, (; items = workspaceDiagnostics))
    end
end

function handle_initialized_notification(msg::NotificationMessage)
    return nothing # TODO
end

function handle_shutdown_request(msg::RequestMessage)
    return ResponseMessage(msg.id, ResponseError(JSONRPC.InvalidRequest, "LS shutdown was requested"))
end

global workspaceDiagnosticsVersion::Int = 0

function handle_workspace_diagnostic_request(msg::RequestMessage)
    global workspaceUri, workspaceDiagnostics
    if @isdefined workspaceDiagnostics
        return ResponseMessage(msg.id, (; items = workspaceDiagnostics))
    end
end

global workspaceDiagnosticsVersion::Int = 0

function handle_workspace_diagnostic_request(msg::RequestMessage)
    global workspaceUri
    result = @invokelatest report_file(pkgpath; analyze_from_definitions=true, toplevel_logger=stderr)

global workspaceDiagnosticsVersion::Int = 0

function handle_workspace_diagnostic_request(msg::RequestMessage)
    global workspaceUri
    @assert @isdefined(workspaceUri)
    workspaceDir = uri2filepath(workspaceUri)
    if isnothing(workspaceDir)
        println(stderr, "unexpected uri", workspaceUri)
        return
    end
    pkgname = basename(workspaceDir)
    pkgpath = joinpath(workspaceDir, "src", "$pkgname.jl")
    result = @invokelatest report_file(pkgpath; analyze_from_definitions=true, toplevel_logger=stderr)
global workspaceDiagnosticsVersion::Int = 0

function handle_workspace_diagnostic_request(msg::RequestMessage)
    global workspaceUri
    @assert @isdefined(workspaceUri)
    workspaceDir = uri2filepath(workspaceUri)
    if isnothing(workspaceDir)
        println(stderr, "unexpected uri", workspaceUri)
        return
    end
    pkgname = basename(workspaceDir)
    pkgpath = joinpath(workspaceDir, "src", "$pkgname.jl")
    result = Base.inferencebarrier(report_file)(pkgpath; analyze_from_definitions=true, toplevel_logger=stderr)
    workspaceDiagnostics = diagnostics
global workspaceDiagnosticsVersion::Int = 0

function handle_workspace_diagnostic_request(msg::RequestMessage)
    global workspaceUri
    @assert @isdefined(workspaceUri)
    workspaceDir = uri2filepath(workspaceUri)
    if isnothing(workspaceDir)
        println(stderr, "unexpected uri", workspaceUri)
        return
    end
    pkgname = basename(workspaceDir)
    pkgpath = joinpath(workspaceDir, "src", "$pkgname.jl")
    result = Base.inferencebarrier(report_file)(pkgpath; analyze_from_definitions=true, toplevel_logger=stderr)
    diagnostics = jet_to_workspace_diagnostics(result)
    workspaceDiagnostics = diagnostics
    global workspaceUri
    @assert @isdefined(workspaceUri)
    workspaceDir = uri2filepath(workspaceUri)
    if isnothing(workspaceDir)
        println(stderr, "unexpected uri", workspaceUri)
        return
    end
    pkgname = basename(workspaceDir)
    pkgpath = joinpath(workspaceDir, "src", "$pkgname.jl")
    result = Base.inferencebarrier(report_file)(pkgpath; analyze_from_definitions=true, toplevel_logger=stderr)
    diagnostics = jet_to_workspace_diagnostics(result)
global workspaceDiagnosticsVersion::Int = 0

    global workspaceUri
    @assert @isdefined(workspaceUri)
    workspaceDir = uri2filepath(workspaceUri)
    if isnothing(workspaceDir)
        println(stderr, "unexpected uri", workspaceUri)
        return
    end
    pkgname = basename(workspaceDir)
    pkgpath = joinpath(workspaceDir, "src", "$pkgname.jl")
    result = Base.inferencebarrier(report_file)(pkgpath; analyze_from_definitions=true, toplevel_logger=stderr)
    diagnostics = jet_to_workspace_diagnostics(result)
    return ResponseMessage(msg.id, (; items = diagnostics))
end

global workspaceDiagnosticsVersion::Int = 0

function jet_to_workspace_diagnostics(result)
    diagnostics = Any[]
    version = (global workspaceDiagnosticsVersion+=1)
    uri2items = Dict{URI,Vector{Any}}()

    # TODO result.res.toplevel_error_reports
    for report in result.res.inference_error_reports
        uri = filepath2uri(lowercase(jetpath2abspath(string(report.vst[1].file))))
        items = get!(()->Any[], uri2items, uri)

        buf = IOBuffer()
        JET.print_report_message(buf, report)
        message = String(take!(buf))

        push!(items, (;
            message,
            range = (;
                start = (; line=report.vst[1].line-1, character=0),
                var"end" = (; line=report.vst[1].line-1, character=Int(typemax(Int32))),
            )
        ))
function jetpath2abspath(path)
    isabspath(path) && return path
    return joinpath(workspaceUri.path, path)
end

    end

    for (uri, items) in uri2items
        push!(diagnostics, (;
            uri=string(uri),
            version,
            kind = "full",
            items,
        ))
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
