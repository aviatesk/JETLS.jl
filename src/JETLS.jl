module JETLS

export runserver

include("URIs2/URIs2.jl")
using .URIs2

module LSP
using StructTypes
function lsptypeof end
include("LSP.jl")
end
using .LSP

include("JSONRPC.jl")
using .JSONRPC

using Pkg, JuliaSyntax, JET

runserver(in::IO, out::IO; kwargs...) = runserver((msg, res)->nothing, in, out; kwargs...)
function runserver(callback, in::IO, out::IO;
                   shutdown_really::Bool=true)
    endpoint = Endpoint(in, out)
    state = initialize_state()
    shutdown_requested = false
    local exit_code::Int
    try
        for msg in endpoint
            if msg isa ShutdownRequest
                shutdown_requested = true
                res = ResponseMessage(; id = msg.id, result = nothing)
            elseif msg isa ExitNotification
                exit_code = !shutdown_requested
                callback(msg, nothing)
                break
            elseif shutdown_requested
                res = ResponseMessage(; id = msg.id, error=ResponseError(;
                    code=ErrorCodes.InvalidRequest,
                    message="Received request after a shutdown request requested"))
            else
                res = @invokelatest handle_message(state, msg)
            end
            if res === nothing
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

struct FileInfo
    version::Int
    text::String
    parsed::Union{Expr,JuliaSyntax.ParseError}
end

mutable struct AnalysisResult
    staled::Bool
    last_analysis::Float64
    ready::Bool
    const diagnostics::Dict{URI,Vector{Diagnostic}}
end

struct AnalysisInstance
    env_path::String
    entry_path::String
    files::Set{URI}
    result::AnalysisResult
end

function initialize_state()
    return (;
        workspaceFolders = URI[], # TODO support multiple workspace folders properly
        file_cache = Dict{URI,FileInfo}(), # on-memory virtual file system
        analysis_instances = AnalysisInstance[],
        reverse_map = Dict{URI,BitSet}())
end

function handle_message(state, msg)
    if msg isa InitializeRequest
        return handle_InitializeRequest(state, msg)
    elseif msg isa InitializedNotification
        return nothing
    elseif msg isa DidOpenTextDocumentNotification
        return handle_DidOpenTextDocumentNotification(state, msg)
    elseif msg isa DidChangeTextDocumentNotification
        return handle_DidChangeTextDocumentNotification(state, msg)
    elseif msg isa DidCloseTextDocumentNotification
        return handle_DidCloseTextDocumentNotification(state, msg)
    elseif msg isa DidSaveTextDocumentNotification
        return handle_DidSaveTextDocumentNotification(state, msg)
    elseif msg isa DocumentDiagnosticRequest
        return handle_DocumentDiagnosticRequest(state, msg)
    elseif msg isa WorkspaceDiagnosticRequest
        return nothing
        return handle_WorkspaceDiagnosticRequest(state, msg)
    else
        @warn "Unhandled message" msg
        nothing
    end
end

function handle_InitializeRequest(state, msg::InitializeRequest)
    workspaceFolders = msg.params.workspaceFolders
    if workspaceFolders !== nothing
        for workspaceFolder in workspaceFolders
            push!(state.workspaceFolders, URI(workspaceFolder.uri))
        end
    else
        rootUri = msg.params.rootUri
        if rootUri !== nothing
            push!(state.workspaceFolders, URI(msg.params.rootUri))
        else
            @info "No workspaceFolders or rootUri in InitializeRequest"
        end
    end
    return ResponseMessage(; id = msg.id,
        result = InitializeResult(;
            capabilities = ServerCapabilities(;
                positionEncoding = PositionEncodingKind.UTF16,
                textDocumentSync = TextDocumentSyncOptions(;
                    openClose = true,
                    change = TextDocumentSyncKind.Full,
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

function parse_file(text::String, uri::URI)
    filename = uri2filepath(uri)
    try
        return JuliaSyntax.parseall(Expr, text; filename, ignore_errors=false)::Expr
    catch err
        err isa JuliaSyntax.ParseError || rethrow(err)
        return err
    end
end

function handle_DidOpenTextDocumentNotification(state, msg::DidOpenTextDocumentNotification)
    textDocument = msg.params.textDocument
    @assert textDocument.languageId == "julia"
    uri = URI(textDocument.uri)
    file_info = FileInfo(textDocument.version, textDocument.text, parse_file(textDocument.text, uri))
    state.file_cache[uri] = file_info
    return nothing
end

# TODO switch to incremental updates?
function handle_DidChangeTextDocumentNotification(state, msg::DidChangeTextDocumentNotification)
    (;textDocument,contentChanges) = msg.params
    uri = URI(textDocument.uri)
    for contentChange in contentChanges
        @assert contentChange.range === contentChange.rangeLength === nothing # since `change = TextDocumentSyncKind.Full`
    end
    text = last(contentChanges).text
    file_info = FileInfo(textDocument.version, text, parse_file(text, uri))
    state.file_cache[uri] = file_info
    idxs = get(state.reverse_map, uri, nothing)
    if idxs !== nothing
        for idx in idxs
            analysis_instance = state.analysis_instances[idx]
            analysis_instance.result.staled = true
            analysis_instance.result.ready = file_info.parsed isa Expr
        end
    end
    return nothing
end

function handle_DidCloseTextDocumentNotification(state, msg::DidCloseTextDocumentNotification)
    textDocument = msg.params.textDocument
    uri = URI(textDocument.uri)
    delete!(state.file_cache, uri)
    return nothing
end

function handle_DidSaveTextDocumentNotification(state, msg::DidSaveTextDocumentNotification)
    return nothing
end

function handle_DocumentDiagnosticRequest(state, msg::DocumentDiagnosticRequest)
    @assert msg.params.identifier == "JETLS"
    textDocument = msg.params.textDocument
    uri = URI(textDocument.uri)
    if !haskey(state.file_cache, uri)
        return ResponseMessage(;
            id = msg.id,
            error=ResponseError(
                code=ErrorCodes.ServerCancelled,
                message="File cache for the requested document not found",
                data=DiagnosticServerCancellationData(;
                    retriggerRequest=true)))
    end
    file_info = state.file_cache[uri]
    if file_info.parsed isa JuliaSyntax.ParseError
        return ResponseMessage(;
            id = msg.id,
            result = RelatedFullDocumentDiagnosticReport(;
                items=parse_error_to_diagnostics(file_info.parsed)))
    end
    return ResponseMessage(;
        id = msg.id,
        result = RelatedFullDocumentDiagnosticReport(;
            items = Diagnostic[]))
    if !haskey(state.reverse_map, uri)
        analysis_instance = initiate_analysis(uri)
        if analysis_instance === nothing
            return nothing
        end
        push!(state.analysis_instances, analysis_instance)
        state.reverse_map[uri] = push!(BitSet(), length(state.analysis_instances))
    else
        for idx in state.reverse_map[uri]
            analysis_instance = state.analysis_instances[idx]
            refresh_analysis!(analysis_instance)
        end
        return ResponseMessage(;
            id = msg.id,
            result = RelatedFullDocumentDiagnosticReport(;
                items = Diagnostic[]))
    end
    return nothing
end

function parse_error_to_diagnostics(err::JuliaSyntax.ParseError)
    diagnostics = Diagnostic[]
    source = err.source
    for diagnostic in err.diagnostics
        severity =
            diagnostic.level === :error ? DiagnosticSeverity.Error :
            diagnostic.level === :warning ? DiagnosticSeverity.Warning :
            diagnostic.level === :note ? DiagnosticSeverity.Information :
            DiagnosticSeverity.Hint
        start = let
            line, col = JuliaSyntax.source_location(source, JuliaSyntax.first_byte(diagnostic))
            Position(; line = line-1, character = col)
        end
        var"end" = let
            line, col = JuliaSyntax.source_location(source, JuliaSyntax.last_byte(diagnostic))
            Position(; line = line-1, character = col)
        end
        range = Range(; start, var"end")
        push!(diagnostics, Diagnostic(;
            severity,
            source = "JuliaSyntax",
            message = diagnostic.message,
            range))
    end
    return diagnostics
end

function initiate_analysis(uri::URI)
    path = uri2filepath(uri)
    if path === nothing
        @warn "non file:// URI supported" uri
        return nothing
    end
    env_path = find_env_path(path)
    env_toml = env_path === nothing ? nothing : try
        Pkg.TOML.parsefile(env_path)
    catch err
        err isa Base.TOML.ParseError || rethrow(err)
        nothing
    end
    if haskey(file_cache, uri)
        @warn "File cache for the requested document not found" uri
        return nothing
    end
    file_info = file_cache[uri]
    parsed = file_info.parsed
    if parsed isa JuliaSyntax.ParseError
        # translate to diagnostics
        diagnostics = Dict{URI,Vector{Diagnostic}}()
    else
        result = activate_do(env_path) do
            analyze_from_file(path, env_path, env_toml)
        end
    end
    diagnostics = Dict{URI,Vector{Diagnostic}}()
    diagnostics[uri] = Diagnostic[]
    result = AnalysisResult(false, time(), false, diagnostics)
    files = push!(Set{URI}(), uri)
    return AnalysisInstance(env_path, path, files, result)
end

function activate_do(func, env_path::String)
    old_env = Pkg.project().path
    try
        Pkg.activate(env_path)
        func()
    finally
        Pkg.activate(old_env.path)
    end
end

function analyze_from_file(path::String, env_path::String, env_toml::Dict{String,Any})
    analyzer = JET.JETAnalyzer()
    if env_toml !== nothing && haskey(env_toml, "name") && is_package_file(path, env_path)
        pkgname = env_toml["name"]
        pkgenv = Base.identify_package_env(pkgname)
        if pkgenv === nothing
            @warn "Failed to identify package environment" pkgname
            @goto analyze_script
        end
        pkgid, env = pkgenv
        pkgfile = Base.locate_package(pkgid, env)
        if pkgfile === nothing
            @warn "Expected a package to have a source file." pkgname
            @goto analyze_script
        end
        result = JET.analyze_and_report_expr!(analyzer, parsed, path;
            analyze_from_definitions=true, toplevel_logger=stderr,
            concretization_patterns=[:(x_)])
    else
        @label analyze_script
        result = JET.analyze_and_report_expr!(analyzer, parsed, path;
            toplevel_logger=stderr)
    end
    return result
end

function is_package_file(path::String, env_path::String)
    env_dir = dirname(env_path)
    src_dir = joinpath(env_dir, "src")
    dir = dirname(path)
    while dir != env_dir
        src_dir == dir && return true
        dir = dirname(dir)
    end
    return false
end

function refresh_analysis!(analysis_instance::AnalysisInstance)
    # TODO
end

find_env_path(path::String) = search_up_file(path, "Project.toml")

function search_up_file(path::String, basename::String)
    dir = dirname(path)
    while !isempty(dir)
        project_file = joinpath(dir, basename)
        if isfile(project_file)
            return project_file
        end
        parent = dirname(dir)
        if parent == dir
            break
        end
        dir = parent
    end
    return nothing
end

function handle_WorkspaceDiagnosticRequest(state, msg::WorkspaceDiagnosticRequest)
    if isempty(state.workspaceFolders)
        return nothing
    end
    workspaceDir = uri2filepath(state.workspaceFolders[1])::String
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
            id = msg.id,
            result = WorkspaceDiagnosticReport(; items = diagnostics))
    end
    pkgname = basename(workspaceDir)
    pkgpath = joinpath(workspaceDir, "src", "$pkgname.jl")
    result = @invokelatest report_file(pkgpath;
        analyze_from_definitions=true, toplevel_logger=stderr,
        concretization_patterns=[:(x_)])
    diagnostics = jet_to_workspace_diagnostics(state, workspaceDir, result)
    return ResponseMessage(;
        id = msg.id,
        result = WorkspaceDiagnosticReport(; items = diagnostics))
end

function jet_to_workspace_diagnostics(state, workspaceDir, result)
    for file in result.res.included_files
        uri = filepath2uri(jetpath2abspath(file, workspaceDir))
        state.uri2diagnostics[uri] = Diagnostic[]
    end

    # TODO result.res.toplevel_error_reports
    for report in result.res.inference_error_reports
        uri = filepath2uri(jetpath2abspath(String(report.vst[1].file), workspaceDir))
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

function jetpath2abspath(path, workspaceDir)
    isabspath(path) && return path
    return joinpath(workspaceDir, path)
end

end # module JETLS
