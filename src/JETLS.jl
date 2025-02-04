module JETLS

export runserver

include("URIs2/URIs2.jl")
using .URIs2

include("LSP/LSP.jl")
using .LSP

include("JSONRPC.jl")
using .JSONRPC

using Pkg, JuliaSyntax, JET

runserver(in::IO, out::IO; kwargs...) = runserver((msg, res)->nothing, in, out; kwargs...)
function runserver(callback, in::IO, out::IO;
                   in_callback = Returns(nothing),
                   out_callback = Returns(nothing),
                   shutdown_really::Bool=true)
    endpoint = Endpoint(in, out)
    function send(@nospecialize msg)
        JSONRPC.send(endpoint, msg)
        out_callback(msg)
        nothing
    end
    state = initialize_state(send)
    shutdown_requested = false
    local exit_code::Int
    try
        for msg in endpoint
            in_callback(msg)
            if msg isa ShutdownRequest
                shutdown_requested = true
                send(ShutdownResponse(; id = msg.id, result = null))
            elseif msg isa ExitNotification
                exit_code = !shutdown_requested
                out_callback(nothing) # for testing purpose
                break
            elseif shutdown_requested
                send(ResponseMessage(; id = msg.id, error=ResponseError(;
                    code=ErrorCodes.InvalidRequest,
                    message="Received request after a shutdown request requested")))
            else
                @invokelatest handle_message(state, msg)
            end
        end
    catch err
        @error "Message handling failed" err
        Base.display_error(stderr, err, catch_backtrace())
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

function initialize_state(send)
    return (;
        send,
        workspaceFolders = URI[], # TODO support multiple workspace folders properly
        file_cache = Dict{URI,FileInfo}(), # on-memory virtual file system
        analysis_instances = AnalysisInstance[],
        reverse_map = Dict{URI,BitSet}(),
        analysis_interval = 15.0)
end

struct IncludeCallback{State<:NamedTuple} <: Function
    state::State
end
function (include_callback::IncludeCallback)(filepath::String)
    uri = filepath2uri(filepath)
    if haskey(include_callback.state.file_cache, uri)
        return include_callback.state.file_cache[uri].text # TODO use `parsed` instead of `text`
    end
    # fallback to the default file-system-based include
    return read(filepath, String)
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
        return nothing # TODO? handle_WorkspaceDiagnosticRequest(state, msg)
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
            push!(state.workspaceFolders, URI(rootUri))
        else
            @warn "No workspaceFolders or rootUri in InitializeRequest"
        end
    end
    return InitializeResponse(; id = msg.id,
        result = InitializeResult(;
            capabilities = ServerCapabilities(;
                positionEncoding = PositionEncodingKind.UTF16,
                textDocumentSync = TextDocumentSyncOptions(;
                    openClose = true,
                    change = TextDocumentSyncKind.Full,
                    save = SaveOptions(;
                        includeText = true)),
                diagnosticProvider = DiagnosticRegistrationOptions(;
                    documentSelector = DocumentFilter[
                        DocumentFilter(;
                            language = "julia")],
                    identifier = "JETLS",
                    interFileDependencies = true,
                    workspaceDiagnostics = true),
            ),
            serverInfo = (;
                name = "JETLS",
                version = "0.0.0"))) |> state.send
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
    parsed = parse_file(text, uri)
    file_info = FileInfo(textDocument.version, text, parsed)
    state.file_cache[uri] = file_info
    idxs = get(state.reverse_map, uri, nothing)
    if idxs !== nothing
        for idx in idxs
            analysis_instance = state.analysis_instances[idx]
            analysis_instance.result.staled = true
            if parsed isa JuliaSyntax.ParseError
                analysis_instance.parse_errors[uri] = parsed
            else
                delete!(analysis_instance.parse_errors, uri)
            end
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
    try
        return _handle_DocumentDiagnosticRequest(state, msg, uri)
    catch err
        @error "DocumentDiagnosticRequest handling failed" err
        Base.display_error(stderr, err, catch_backtrace())
        clear_analysis_instances!(state)
        return DocumentDiagnosticResponse(;
            id = msg.id,
            error = ResponseError(;
                code = ErrorCodes.InternalError,
                message = "Message handling failed",
                data = DiagnosticServerCancellationData(;
                    retriggerRequest = false))) |> state.send
    end
end

function clear_analysis_instances!(state)
    empty!(state.reverse_map)
    empty!(state.analysis_instances)
end

function _handle_DocumentDiagnosticRequest(state, msg::DocumentDiagnosticRequest, uri::URI)
    if !haskey(state.reverse_map, uri)
        res = initiate_analysis!(state, uri)
    else
        res = refresh_analysis_instances!(state, uri)
    end
    state.send(res isa ResponseError ?
        DocumentDiagnosticResponse(; id = msg.id, error = res) :
        DocumentDiagnosticResponse(; id = msg.id, result = res))
end

function parse_error_to_diagnostics(err::JuliaSyntax.ParseError)
    diagnostics = Diagnostic[]
    parse_error_to_diagnostics!(diagnostics, err)
    return diagnostics
end
function parse_error_to_diagnostics!(diagnostics::Vector{Diagnostic}, err::JuliaSyntax.ParseError)
    source = err.source
    for diagnostic in err.diagnostics
        push!(diagnostics, juliasyntax_diagnostic_to_diagnostic(diagnostic, source))
    end
end
function juliasyntax_diagnostic_to_diagnostic(diagnostic::JuliaSyntax.Diagnostic, source::JuliaSyntax.SourceFile)
    sline, scol = JuliaSyntax.source_location(source, JuliaSyntax.first_byte(diagnostic))
    start = Position(; line = sline-1, character = scol)
    eline, ecol = JuliaSyntax.source_location(source, JuliaSyntax.last_byte(diagnostic))
    var"end" = Position(; line = eline-1, character = ecol)
    return Diagnostic(;
        range = Range(; start, var"end"),
        severity =
            diagnostic.level === :error ? DiagnosticSeverity.Error :
            diagnostic.level === :warning ? DiagnosticSeverity.Warning :
            diagnostic.level === :note ? DiagnosticSeverity.Information :
            DiagnosticSeverity.Hint,
        message = diagnostic.message,
        source = "JuliaSyntax")
end

mutable struct AnalysisResult
    staled::Bool
    last_analysis::Float64
    const uri2diagnostics::Dict{URI,Vector{Diagnostic}}
end

abstract type AnalysisEntry end

struct ScriptAnalysisEntry <: AnalysisEntry
    uri::URI
end
struct ScriptInEnvAnalysisEntry <: AnalysisEntry
    env_path::String
    uri::URI
end
struct PackageSourceAnalysisEntry <: AnalysisEntry
    env_path::String
    pkgfile::String
    pkgid::Base.PkgId
end
struct PackageTestAnalysisEntry <: AnalysisEntry
    env_path::String
    runtests::String
end

struct AnalysisInstance
    entry::AnalysisEntry
    files::Set{URI}
    parse_errors::Dict{URI,JuliaSyntax.ParseError}
    result::AnalysisResult
end

function initiate_analysis!(state, uri::URI)
    path = uri2filepath(uri)
    if path === nothing
        @warn "Non file:// URI supported" uri
        return ResponseError(;
            code = ErrorCodes.ServerCancelled,
            message = "Non file:// URI supported",
            data = DiagnosticServerCancellationData(;
                retriggerRequest = false))
    end
    env_path = find_env_path(path)
    env_toml = env_path === nothing ? nothing : try
        Pkg.TOML.parsefile(env_path)
    catch err
        err isa Base.TOML.ParseError || rethrow(err)
        nothing
    end
    if !haskey(state.file_cache, uri)
        @warn "File cache for the requested document not found" uri
        return ResponseError(;
            code = ErrorCodes.ServerCancelled,
            message = "File cache for the requested document not found",
            data = DiagnosticServerCancellationData(;
                retriggerRequest = false))
    end
    file_info = state.file_cache[uri]
    parsed = file_info.parsed
    if parsed isa JuliaSyntax.ParseError
        return RelatedFullDocumentDiagnosticReport(;
            items = parse_error_to_diagnostics(parsed))
    end
    include_callback = IncludeCallback(state)
    if env_path === nothing
        @label analyze_script
        if env_path !== nothing
            entry = ScriptInEnvAnalysisEntry(env_path, uri)
            result = activate_do(env_path) do
                JET.analyze_and_report_expr!(JET.JETAnalyzer(), parsed, path;
                    toplevel_logger=stderr,
                    include_callback)
            end
        else
            entry = ScriptAnalysisEntry(uri)
            result = JET.analyze_and_report_expr!(JET.JETAnalyzer(), parsed, path;
                toplevel_logger=stderr,
                include_callback)
        end
        analysis_instance = new_analysis_instance(entry, result)
        @assert uri in analysis_instance.files
        record_analysis_instance!(state, analysis_instance)
    elseif env_toml === nothing
        @goto analyze_script
    elseif !haskey(env_toml, "name")
        @goto analyze_script
    else # this file is likely one within a package
        filekind, filedir = find_package_directory(path, env_path)
        if filekind === :script
            @goto analyze_script
        elseif filekind === :src
            pkgname = env_toml["name"]
            pkgenv = Base.identify_package_env(pkgname)
            if pkgenv === nothing
                @warn "Failed to identify package environment" pkgname
                @goto analyze_script
            end
            pkgid, env = pkgenv
            pkgfile = Base.locate_package(pkgid, env)
            if pkgfile === nothing
                @warn "Expected a package to have a source file" pkgname
                @goto analyze_script
            end
            # analyze package source files
            entry = PackageSourceAnalysisEntry(env_path, pkgfile, pkgid)
            result = activate_do(env_path) do
                pkgfiluri = filepath2uri(pkgfile)
                analyze_parsed_if_exist(state, pkgfiluri, pkgfile, pkgid;
                    toplevel_logger=nothing,
                    analyze_from_definitions=true,
                    target_defined_modules=true,
                    concretization_patterns=[:(x_)],
                    include_callback)
            end
            analysis_instance = new_analysis_instance(entry, result)
            record_analysis_instance!(state, analysis_instance)
            if uri ∉ analysis_instance.files
                @goto analyze_script
            end
        elseif filekind === :test
            # analyze test scripts
            runtests = joinpath(filedir, "runtests.jl")
            result = activate_do(env_path) do
                JET.analyze_and_report_file!(JET.JETAnalyzer(), runtests;
                    toplevel_logger=stderr,
                    include_callback)
            end
            entry = PackageTestAnalysisEntry(env_path, runtests)
            analysis_instance = new_analysis_instance(entry, result)
            record_analysis_instance!(state, analysis_instance)
            if uri ∉ analysis_instance.files
                @goto analyze_script
            end
        elseif filekind === :docs
            @goto analyze_script # TODO
        else
            @assert filekind === :ext
            @goto analyze_script # TODO
        end
    end

    return to_diagnostic_report(analysis_instance.result.uri2diagnostics, uri)
end

function analyze_parsed_if_exist(state, uri, args...; kwargs...)
    if haskey(state.file_cache, uri)
        parsed = state.file_cache[uri].parsed
        return JET.analyze_and_report_expr!(JET.JETAnalyzer(), parsed, args...; kwargs...)
    else
        return JET.analyze_and_report_file!(JET.JETAnalyzer(), args...; kwargs...)
    end
end

# summarize the result into diagnostics
function to_diagnostic_report(uri2diagnostics, main_uri)
    items = uri2diagnostics[main_uri]
    relatedDocuments = Dict{String,Union{FullDocumentDiagnosticReport,UnchangedDocumentDiagnosticReport}}()
    for (furi, diagnostics) in uri2diagnostics
        furi == main_uri && continue
        relatedDocuments[string(furi)] = FullDocumentDiagnosticReport(;
            items = diagnostics)
    end
    return RelatedFullDocumentDiagnosticReport(;
        items,
        relatedDocuments)
end

function new_analysis_instance(entry::AnalysisEntry, result)
    files = Set{URI}()
    for filepath in result.res.included_files
        push!(files, filepath2uri(filepath)) # `filepath` is an absolute path (since `path` is specified as absolute)
    end
    # TODO return something for `toplevel_error_reports`
    parse_errors = Dict{URI,JuliaSyntax.ParseError}()
    uri2diagnostics = jet_result_to_diagnostics(result, files)
    analysis_result = AnalysisResult(false, time(), uri2diagnostics)
    return AnalysisInstance(entry, files, parse_errors, analysis_result)
end

function record_analysis_instance!(state, analysis_instance)
    push!(state.analysis_instances, analysis_instance)
    aidx = length(state.analysis_instances)
    for furi in analysis_instance.files
        revmap = get!(BitSet, state.reverse_map, furi)
        push!(revmap, aidx)
    end
end

# TODO severity
function jet_result_to_diagnostics(result, files::Set{URI})
    uri2diagnostics = Dict{URI,Vector{Diagnostic}}(furi => Diagnostic[] for furi in files)
    jet_result_to_diagnostics!(uri2diagnostics, result, files)
    return uri2diagnostics
end

function jet_result_to_diagnostics!(uri2diagnostics::Dict{URI,Vector{Diagnostic}}, result, files::Set{URI})
    for report in result.res.toplevel_error_reports
        diagnostic = jet_toplevel_error_report_to_diagnostic(report)
        furi = filepath2uri(JET.tofullpath(report.file))
        items = uri2diagnostics[furi]
        push!(items, diagnostic)
    end
    for report in result.res.inference_error_reports
        diagnostic = jet_inference_error_report_to_diagnostic(report)
        topframe = report.vst[1]
        furi = filepath2uri(JET.tofullpath(String(topframe.file)))
        items = uri2diagnostics[furi]
        push!(items, diagnostic)
    end
end

function jet_toplevel_error_report_to_diagnostic(@nospecialize report::JET.ToplevelErrorReport)
    if report isa JET.ParseErrorReport
        return juliasyntax_diagnostic_to_diagnostic(report.diagnostic, report.source)
    end
    message = JET.with_bufferring(:limit=>true) do io
        JET.print_report(io, report)
    end
    return Diagnostic(;
        range = line_range(report.line),
        message,
        source = "JETAnalyzer")
end

function jet_inference_error_report_to_diagnostic(@nospecialize report::JET.InferenceErrorReport)
    topframe = report.vst[1]
    message = JET.with_bufferring(:limit=>true) do io
        JET.print_report_message(io, report)
    end
    relatedInformation = DiagnosticRelatedInformation[
        let frame = report.vst[i],
            message = sprint(JET.print_frame_sig, frame, JET.PrintConfig())
            DiagnosticRelatedInformation(;
                location = Location(;
                    uri = string(filepath2uri(JET.tofullpath(String(frame.file)))),
                    range = jet_frame_to_range(frame)),
                message)
        end
        for i = 2:length(report.vst)]
    return Diagnostic(;
        range = jet_frame_to_range(topframe),
        message,
        source = "JETAnalyzer",
        relatedInformation)
end

function jet_frame_to_range(frame)
    line = JET.fixed_line_number(frame)
    line = line == 0 ? line : line - 1
    return line_range(line)
end

function line_range(line::Int)
    start = Position(; line, character=0)
    var"end" = Position(; line, character=Int(typemax(Int32)))
    return Range(; start, var"end")
end

function activate_do(func, env_path::String)
    old_env = Pkg.project().path
    try
        Pkg.activate(env_path; io=devnull)
        func()
    finally
        Pkg.activate(old_env; io=devnull)
    end
end

function find_package_directory(path::String, env_path::String)
    dir = dirname(path)
    env_dir = dirname(env_path)
    src_dir = joinpath(env_dir, "src")
    test_dir = joinpath(env_dir, "test")
    docs_dir = joinpath(env_dir, "docs")
    ext_dir = joinpath(env_dir, "ext")
    while dir != env_dir
        dir == src_dir && return :src, src_dir
        dir == test_dir && return :test, test_dir
        dir == docs_dir && return :docs, docs_dir
        dir == ext_dir && return :ext, ext_dir
        dir = dirname(dir)
    end
    return :script, path
end

function refresh_analysis_instances!(state, uri::URI)
    aidxs = state.reverse_map[uri]
    if aidxs === nothing
        @warn "No analysis instance found for the requested document" uri
        return RelatedFullDocumentDiagnosticReport(;
            items=Diagnostic[])
    end
    # TODO support multiple analysis instances, which can happen if this file is included from multiple different contexts
    analysis_instance = state.analysis_instances[first(aidxs)]
    analysis_result = analysis_instance.result
    if !analysis_result.staled
        return RelatedUnchangedDocumentDiagnosticReport(;
            resultId=string(uri))
    elseif !isempty(analysis_instance.parse_errors)
        items = Diagnostic[]
        relatedDocuments = Dict{String,Union{FullDocumentDiagnosticReport,UnchangedDocumentDiagnosticReport}}()
        for (furi, parse_error) in analysis_instance.parse_errors
            if furi == uri
                parse_error_to_diagnostics!(items, parse_error)
            else
                relatedDocuments[string(furi)] = FullDocumentDiagnosticReport(;
                    items = parse_error_to_diagnostics(parse_error))
            end
        end
        return RelatedFullDocumentDiagnosticReport(;
            items,
            relatedDocuments)
    elseif time() - analysis_result.last_analysis < state.analysis_interval
        return to_diagnostic_report(analysis_instance.result.uri2diagnostics, uri)
    end
    entry = analysis_instance.entry
    include_callback = IncludeCallback(state)
    if entry isa ScriptAnalysisEntry
        result = analyze_parsed_if_exist(state, entry.uri, uri2filepath(entry.uri);
            toplevel_logger=stderr,
            include_callback)
    elseif entry isa ScriptInEnvAnalysisEntry
        result = activate_do(entry.env_path) do
            analyze_parsed_if_exist(state, entry.uri, uri2filepath(entry.uri);
                toplevel_logger=stderr,
                include_callback)
        end
    elseif entry isa PackageSourceAnalysisEntry
        result = activate_do(entry.env_path) do
            pkgfiluri = filepath2uri(entry.pkgfile)
            analyze_parsed_if_exist(state, pkgfiluri, entry.pkgfile, entry.pkgid;
                    toplevel_logger=nothing,
                    analyze_from_definitions=true,
                    target_defined_modules=true,
                    concretization_patterns=[:(x_)],
                    include_callback)
        end
    elseif entry isa PackageTestAnalysisEntry
        result = activate_do(entry.env_path) do
            JET.analyze_and_report_file!(JET.JETAnalyzer(), entry.runtests;
                toplevel_logger=stderr,
                include_callback)
        end
    else
        @warn "Unsupported analysis entry" entry
        return ResponseError(;
            code = ErrorCodes.ServerCancelled,
            message = "Unsupported analysis entry",
            data = DiagnosticServerCancellationData(;
                retriggerRequest = false))
    end
    update_analysis_instance!(analysis_instance, result)
    res = to_diagnostic_report(analysis_instance.result.uri2diagnostics, uri)
    return res
end

function update_analysis_instance!(analysis_instance, result)
    files = analysis_instance.files
    uri2diagnostics = analysis_instance.result.uri2diagnostics
    for filepath in result.res.included_files
        uri = filepath2uri(filepath)
        push!(files, uri) # `filepath` is an absolute path (since `path` is specified as absolute)
        empty!(get!(()->Diagnostic[], uri2diagnostics, uri))
    end
    analysis_instance.result.staled = false
    analysis_instance.result.last_analysis = time()
    jet_result_to_diagnostics!(uri2diagnostics, result, files)
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

# function handle_WorkspaceDiagnosticRequest(state, msg::WorkspaceDiagnosticRequest)
#     if isempty(state.workspaceFolders)
#         return nothing
#     end
#     workspaceDir = uri2filepath(state.workspaceFolders[1])::String
#     if !isempty(state.uri2diagnostics)
#         diagnostics = WorkspaceUnchangedDocumentDiagnosticReport[]
#         for (uri, _) in state.uri2diagnostics
#             suri = string(uri)
#             push!(diagnostics, WorkspaceUnchangedDocumentDiagnosticReport(;
#                 kind = DocumentDiagnosticReportKind.Unchanged,
#                 resultId = suri,
#                 uri=lowercase(suri),
#                 version=nothing))
#         end
#         return ResponseMessage(;
#             id = msg.id,
#             result = WorkspaceDiagnosticReport(; items = diagnostics))
#     end
#     pkgname = basename(workspaceDir)
#     pkgpath = joinpath(workspaceDir, "src", "$pkgname.jl")
#     result = @invokelatest report_file(pkgpath;
#         analyze_from_definitions=true, toplevel_logger=stderr,
#         concretization_patterns=[:(x_)])
#     diagnostics = jet_to_workspace_diagnostics(state, workspaceDir, result)
#     return ResponseMessage(;
#         id = msg.id,
#         result = WorkspaceDiagnosticReport(; items = diagnostics))
# end

# function jet_to_workspace_diagnostics(state, workspaceDir, result)
#     for file in result.res.included_files
#         uri = filepath2uri(jetpath2abspath(file, workspaceDir))
#         state.uri2diagnostics[uri] = Diagnostic[]
#     end

#     # TODO result.res.toplevel_error_reports
#     for report in result.res.inference_error_reports
#         uri = filepath2uri(jetpath2abspath(String(report.vst[1].file), workspaceDir))
#         items = get!(()->Diagnostic[], state.uri2diagnostics, uri)

#         buf = IOBuffer()
#         JET.print_report_message(buf, report)
#         message = String(take!(buf))

#         push!(items, Diagnostic(;
#             message,
#             range = Range(;
#                 start = Position(; line=report.vst[1].line-1, character=0),
#                 var"end" = Position(; line=report.vst[1].line-1, character=Int(typemax(Int32))),
#             )))
#     end

#     diagnostics = WorkspaceFullDocumentDiagnosticReport[]
#     for (uri, items) in state.uri2diagnostics
#         suri = lowercase(string(uri))
#         push!(diagnostics, WorkspaceFullDocumentDiagnosticReport(;
#             kind = DocumentDiagnosticReportKind.Full,
#             resultId = suri,
#             items,
#             uri=suri,
#             version=nothing))
#     end

#     return diagnostics
# end

# function jetpath2abspath(path, workspaceDir)
#     isabspath(path) && return path
#     return joinpath(workspaceDir, path)
# end

end # module JETLS
