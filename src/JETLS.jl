module JETLS

export runserver

include("utils.jl")
using .LSPURI

module LSP
using StructTypes
function lsptypeof end
include("LSP.jl")
end
using .LSP

include("JSONRPC.jl")
using .JSONRPC

using JET

runserver(in::IO, out::IO; kwargs...) = runserver((msg, res)->nothing, in, out; kwargs...)
function runserver(callback, in::IO, out::IO;
                   shutdown_really::Bool=true)
    endpoint = Endpoint(in, out)
    state = (; uri2diagnostics=Dict{URI,Vector{Diagnostic}}())
    shutdown_requested = false
    local exit_code::Int
    try
        for msg in endpoint
            if msg isa ShutdownRequest
                shutdown_requested = true
                res = ResponseMessage(; id=msg.id, result=nothing)
            elseif msg isa ExitNotification
                exit_code = !shutdown_requested
                break
            elseif shutdown_requested
                res = ResponseMessage(; id=msg.id, error=ResponseError(
                    JSONRPC.InvalidRequest, "Received request after a shutdown request requested", msg))
            else
                res = @invokelatest handle_message(state, msg)
            end
            if res === nothing
                continue
            elseif isa(res, ResponseMessage)
                send(endpoint, res)
            else
                error(lazy"Got unexpected handler result: $res")
            end
            callback(msg, res)
        end
    catch err
        @info "Message handling failed" err
        io = IOBuffer()
        bt = catch_backtrace()
        Base.display_error(io, err, bt)
        print(stderr, String(take!(io)))
    finally
        close(endpoint)
    end
    if @isdefined(exit_code) && shutdown_really
        exit(exit_code)
    end
    return endpoint
end

function handle_message(state, msg)
    if msg isa InitializeRequest
        return handle_InitializeRequest(msg)
    elseif msg isa WorkspaceDiagnosticRequest
        return handle_WorkspaceDiagnosticRequest(state, msg)
    elseif msg isa InitializedNotification
        return nothing
    elseif msg isa DidSaveTextDocumentNotification
        return handle_DidSaveTextDocumentNotification(state, msg)
    else
        @warn "Unhandled message" msg
        nothing
    end
end

global workspaceUri::URI

function handle_InitializeRequest(msg::InitializeRequest)
    global workspaceUri = URI(msg.params.rootUri) # workspaceFolder
    return ResponseMessage(; id=msg.id,
        result=InitializeResult(;
            capabilities = ServerCapabilities(;
                positionEncoding = PositionEncodingKind.UTF16,
                textDocumentSync = TextDocumentSyncOptions(;
                    openClose = true,
                    change = TextDocumentSyncKind.Incremental,
                    save = true),
                diagnosticProvider = DiagnosticOptions(;
                    identifier = "JETLS",
                    interFileDependencies = true,
                    workspaceDiagnostics = true),
            ),
            serverInfo = (;
                name = "JETLS",
                version = "0.0.0")))
end

function handle_DidSaveTextDocumentNotification(state, msg::DidSaveTextDocumentNotification)
    uri = URI(msg.params.textDocument.uri)
    if haskey(state.uri2diagnostics, uri)
        empty!(state.uri2diagnostics)
    end
    return nothing
end

function handle_WorkspaceDiagnosticRequest(state, msg::WorkspaceDiagnosticRequest)
    global workspaceUri
    workspaceDir = uri2filepath(workspaceUri)
    if isnothing(workspaceDir)
        return ResponseMessage(;
            id=msg.id,
            error=ResponseError(JSONRPC.InternalError, "Unexpected workspaceUri", msg))
    end
    if !isempty(state.uri2diagnostics)
        diagnostics = WorkspaceUnchangedDocumentDiagnosticReport[]
        for (uri, _) in state.uri2diagnostics
            suri = string(uri)
            push!(diagnostics, WorkspaceUnchangedDocumentDiagnosticReport(;
                kind = DocumentDiagnosticReportKind.Unchanged,
                resultId = suri,
                uri=lowercase(suri),
                version=nothing))
        end
        return ResponseMessage(;
            id=msg.id,
            result=WorkspaceDiagnosticReport(; items = diagnostics))
    end
    pkgname = basename(workspaceDir)
    pkgpath = joinpath(workspaceDir, "src", "$pkgname.jl")
    result = @invokelatest report_file(pkgpath;
        analyze_from_definitions=true, toplevel_logger=stderr,
        concretization_patterns=[:(x_)])
    diagnostics = jet_to_workspace_diagnostics(state, result)
    return ResponseMessage(;
        id=msg.id,
        result=WorkspaceDiagnosticReport(; items = diagnostics))
end

function jet_to_workspace_diagnostics(state, result)
    for file in result.res.included_files
        uri = filepath2uri(jetpath2abspath(file))
        state.uri2diagnostics[uri] = Diagnostic[]
    end

    # TODO result.res.toplevel_error_reports
    for report in result.res.inference_error_reports
        uri = filepath2uri(jetpath2abspath(String(report.vst[1].file)))
        items = get!(()->Diagnostic[], state.uri2diagnostics, uri)

        buf = IOBuffer()
        JET.print_report_message(buf, report)
        message = String(take!(buf))

        push!(items, Diagnostic(;
            message,
            range = Range(;
                start = Position(; line=report.vst[1].line-1, character=0),
                var"end" = Position(; line=report.vst[1].line-1, character=Int(typemax(Int32))),
            )))
    end

    diagnostics = WorkspaceFullDocumentDiagnosticReport[]
    for (uri, items) in state.uri2diagnostics
        suri = lowercase(string(uri))
        push!(diagnostics, WorkspaceFullDocumentDiagnosticReport(;
            kind = DocumentDiagnosticReportKind.Full,
            resultId = suri,
            items,
            uri=suri,
            version=nothing))
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
