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
        analysis_interval = 5)
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
    elseif msg isa DocumentDiagnosticRequest || msg isa WorkspaceDiagnosticRequest
        @assert false
    else
        @warn "Unhandled message" msg
        return nothing
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
    # root_uri = get_root_folder(state)
    # run_preset_analysis!(state, root_uri)
    res = InitializeResponse(; id = msg.id, result = initialize_result())
    return state.send(res)
end

function get_root_folder(state)
    (;workspaceFolders) = state
    if isempty(workspaceFolders)
        return nothing
    elseif length(workspaceFolders) == 1
        return only(workspaceFolders)
    else
        @warn "Multiple workspaceFolders are not supported" workspaceFolders
        return nothing
    end
end

function initialize_result()
    return InitializeResult(;
        capabilities = ServerCapabilities(;
            positionEncoding = PositionEncodingKind.UTF16,
            textDocumentSync = TextDocumentSyncOptions(;
                openClose = true,
                change = TextDocumentSyncKind.Full,
                save = SaveOptions(;
                    includeText = true)),
        ),
        serverInfo = (;
            name = "JETLS",
            version = "0.0.0"))
end

function run_preset_analysis!(state, rooturi::URI)
    rootpath = uri2filepath(rooturi)
    if rootpath === nothing
        @warn "Non file:// URI supported" rooturi
        return nothing
    end
    env_path = joinpath(rootpath, "Project.toml")
    isfile(env_path) || return nothing
    env_toml = try
        Pkg.TOML.parsefile(env_path)
    catch err
        err isa Base.TOML.ParseError || rethrow(err)
        return nothing
    end
    haskey(env_toml, "name") || return nothing

    pkgname = env_toml["name"]
    pkgenv = Base.identify_package_env(pkgname)
    if pkgenv === nothing
        @warn "Failed to identify package environment" pkgname
        return nothing
    end
    pkgid, env = pkgenv
    pkgfile = Base.locate_package(pkgid, env)
    if pkgfile === nothing
        @warn "Expected a package to have a source file" pkgname
        return nothing
    end

    # TODO analyze package source files lazily?
    # Or perform a simpler analysis here to figure out the included files only?

    # analyze package source files
    result = activate_do(env_path) do
        pkgfileuri = filepath2uri(pkgfile)
        include_callback = IncludeCallback(state)
        analyze_parsed_if_exist(state, pkgfileuri, pkgid;
            toplevel_logger=nothing,
            analyze_from_definitions=true,
            target_defined_modules=true,
            concretization_patterns=[:(x_)],
            include_callback)
    end
    entry = PackageSourceAnalysisEntry(env_path, pkgfile, pkgid)
    analysis_instance = new_analysis_instance(entry, result)
    notify_diagnostics!(state, analysis_instance.result.uri2diagnostics)
    record_analysis_instance!(state, analysis_instance)

    # # analyze test scripts
    # runtests = joinpath(filedir, "runtests.jl")
    # result = activate_do(env_path) do
    #     include_callback = IncludeCallback(state)
    #     JET.analyze_and_report_file!(JET.JETAnalyzer(), runtests;
    #         toplevel_logger=stderr,
    #         include_callback)
    # end
    # entry = PackageTestAnalysisEntry(env_path, runtests)
    # analysis_instance = new_analysis_instance(entry, result)
    # record_analysis_instance!(state, analysis_instance)

    nothing
end

function notify_diagnostics!(state, uri2diagnostics)
    for (uri, diagnostics) in uri2diagnostics
        state.send(PublishDiagnosticsNotification(;
            params = PublishDiagnosticsParams(;
                uri = string(uri),
                # version = 0,
                diagnostics)))
    end
end

function parse_file(text::String, uri::URI)
    filename = uri2filename(uri)
    @assert filename !== nothing "Unsupported URI: $uri"
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
    # @info "opened" uri
    parsed = parse_file(textDocument.text, uri)
    state.file_cache[uri] =
        FileInfo(textDocument.version, textDocument.text, parsed)
    if !haskey(state.reverse_map, uri)
        initiate_analysis!(state, uri)
        @assert haskey(state.reverse_map, uri)
    else
        refresh_analysis_instances!(state, uri)
    end
    nothing
end

# TODO switch to incremental updates?
function handle_DidChangeTextDocumentNotification(state, msg::DidChangeTextDocumentNotification)
    (;textDocument,contentChanges) = msg.params
    uri = URI(textDocument.uri)
    # @info "changed" uri
    for contentChange in contentChanges
        @assert contentChange.range === contentChange.rangeLength === nothing # since `change = TextDocumentSyncKind.Full`
    end
    text = last(contentChanges).text
    parsed = parse_file(text, uri)
    file_info = FileInfo(textDocument.version, text, parsed)
    state.file_cache[uri] = file_info
    @assert haskey(state.reverse_map, uri)
    for idx in state.reverse_map[uri]
        analysis_instance = state.analysis_instances[idx]
        analysis_instance.result.staled = true
        if parsed isa JuliaSyntax.ParseError
            analysis_instance.parse_errors[uri] = parsed
        else
            delete!(analysis_instance.parse_errors, uri)
        end
    end
    refresh_analysis_instances!(state, uri)
    nothing
end

function handle_DidCloseTextDocumentNotification(state, msg::DidCloseTextDocumentNotification)
    textDocument = msg.params.textDocument
    uri = URI(textDocument.uri)
    # @info "closed" uri
    delete!(state.file_cache, uri)
    return nothing
end

function handle_DidSaveTextDocumentNotification(state, msg::DidSaveTextDocumentNotification)
    return nothing
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

function analyze_parsed_if_exist(state, uri::URI, args...; kwargs...)
    if haskey(state.file_cache, uri)
        parsed = state.file_cache[uri].parsed
        filename = uri2filename(uri)::String
        return JET.analyze_and_report_expr!(JET.JETAnalyzer(), parsed, filename, args...; kwargs...)
    else
        filepath = uri2filepath(uri)
        @assert filepath !== nothing "Unsupported URI: $uri"
        return JET.analyze_and_report_file!(JET.JETAnalyzer(), filepath, args...; kwargs...)
    end
end

function new_analysis_instance(entry::AnalysisEntry, result)
    files = Set{URI}()
    for filepath in result.res.included_files
        push!(files, filename2uri(filepath)) # `filepath` is an absolute path (since `path` is specified as absolute)
    end
    # TODO return something for `toplevel_error_reports`
    parse_errors = Dict{URI,JuliaSyntax.ParseError}()
    uri2diagnostics = jet_result_to_diagnostics(result, files)
    analysis_result = AnalysisResult(false, time(), uri2diagnostics)
    return AnalysisInstance(entry, files, parse_errors, analysis_result)
end

function update_analysis_instance!(analysis_instance, result)
    files = analysis_instance.files
    uri2diagnostics = analysis_instance.result.uri2diagnostics
    for filepath in result.res.included_files
        uri = filename2uri(filepath)
        push!(files, uri) # `filepath` is an absolute path (since `path` is specified as absolute)
        empty!(get!(()->Diagnostic[], uri2diagnostics, uri))
    end
    analysis_instance.result.staled = false
    analysis_instance.result.last_analysis = time()
    jet_result_to_diagnostics!(uri2diagnostics, result, files)
end

function record_analysis_instance!(state, analysis_instance)
    push!(state.analysis_instances, analysis_instance)
    aidx = length(state.analysis_instances)
    for uri in analysis_instance.files
        revmap = get!(BitSet, state.reverse_map, uri)
        push!(revmap, aidx)
    end
end

function rerecord_analysis_instance!(state, analysis_instance, aidx)
    for uri in analysis_instance.files
        revmap = get!(BitSet, state.reverse_map, uri)
        push!(revmap, aidx)
    end
end

# TODO severity
function jet_result_to_diagnostics(result, files::Set{URI})
    uri2diagnostics = Dict{URI,Vector{Diagnostic}}(uri => Diagnostic[] for uri in files)
    jet_result_to_diagnostics!(uri2diagnostics, result, files)
    return uri2diagnostics
end

function jet_result_to_diagnostics!(uri2diagnostics::Dict{URI,Vector{Diagnostic}}, result, files::Set{URI})
    for report in result.res.toplevel_error_reports
        diagnostic = jet_toplevel_error_report_to_diagnostic(report)
        filename = report.file
        if startswith(filename, "Untitled")
            uri = filename2uri(filename)
        else
            uri = filepath2uri(JET.tofullpath(filename))
        end
        items = uri2diagnostics[uri]
        push!(items, diagnostic)
    end
    for report in result.res.inference_error_reports
        diagnostic = jet_inference_error_report_to_diagnostic(report)
        topframe = report.vst[1]
        filename = String(topframe.file)
        if startswith(filename, "Untitled")
            uri = filename2uri(filename)
        else
            uri = filepath2uri(JET.tofullpath(filename))
        end
        items = uri2diagnostics[uri]
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

find_env_path(path::String) = search_up_file(path, "Project.toml")

search_up_file(path::String, basename::String) = search_up_dir(dirname(path), basename)
function search_up_dir(dir::String, basename::String)
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

function initiate_analysis!(state, uri::URI)
    if uri.scheme == "file"
        filename = path = uri2filepath(uri)::String
        env_path = find_env_path(path)
        pkgname = env_path === nothing ? nothing : try
            env_toml = Pkg.TOML.parsefile(env_path)
            haskey(env_toml, "name") ? env_toml["name"]::String : nothing
        catch err
            err isa Base.TOML.ParseError || rethrow(err)
            nothing
        end
    elseif uri.scheme == "untitled"
        filename = path = uri2filename(uri)::String
        # try to analyze untitled editors using the root environment
        root_uri = get_root_folder(state)
        if root_uri !== nothing
            root_path = uri2filepath(root_uri)
            env_path = find_env_path(root_path)
            pkgname = nothing # to hit the `@goto analyze_script` case
        else
            env_path = pkgname = nothing
        end
    else @assert false "Unsupported URI: $uri" end
    file_info = state.file_cache[uri]
    parsed = file_info.parsed
    if parsed isa JuliaSyntax.ParseError
        diagnostics = parse_error_to_diagnostics(parsed)
        notify_diagnostics!(state, (uri => diagnostics,))
        return nothing
    end
    include_callback = IncludeCallback(state)
    if env_path === nothing
        @label analyze_script
        if env_path !== nothing
            entry = ScriptInEnvAnalysisEntry(env_path, uri)
            result = activate_do(env_path) do
                JET.analyze_and_report_expr!(JET.JETAnalyzer(), parsed, filename;
                    toplevel_logger=stderr,
                    include_callback)
            end
        else
            entry = ScriptAnalysisEntry(uri)
            result = JET.analyze_and_report_expr!(JET.JETAnalyzer(), parsed, filename;
                toplevel_logger=stderr,
                include_callback)
        end
        analysis_instance = new_analysis_instance(entry, result)
        @assert uri in analysis_instance.files
        record_analysis_instance!(state, analysis_instance)
    elseif pkgname === nothing
        @goto analyze_script
    else # this file is likely one within a package
        filekind, filedir = find_package_directory(path, env_path)
        if filekind === :script
            @goto analyze_script
        elseif filekind === :src
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
                analyze_parsed_if_exist(state, pkgfiluri, pkgid;
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

    notify_diagnostics!(state, analysis_instance.result.uri2diagnostics)
    nothing
end

function refresh_analysis_instances!(state, uri::URI)
    @assert haskey(state.reverse_map, uri)

    # TODO support multiple analysis instances, which can happen if this file is included from multiple different contexts
    aidxs = state.reverse_map[uri]
    aidx = first(aidxs)
    analysis_instance = state.analysis_instances[aidx]
    analysis_result = analysis_instance.result
    if !analysis_result.staled
        return nothing
    elseif !isempty(analysis_instance.parse_errors)
        notify_diagnostics!(state, (
            uri => parse_error_to_diagnostics(parse_error) for (uri, parse_error) in analysis_instance.parse_errors))
        return nothing
    elseif time() - analysis_result.last_analysis < state.analysis_interval
        return nothing # no update
    end
    entry = analysis_instance.entry
    include_callback = IncludeCallback(state)
    if entry isa ScriptAnalysisEntry
        result = analyze_parsed_if_exist(state, entry.uri;
            toplevel_logger=stderr,
            include_callback)
    elseif entry isa ScriptInEnvAnalysisEntry
        result = activate_do(entry.env_path) do
            analyze_parsed_if_exist(state, entry.uri;
                toplevel_logger=stderr,
                include_callback)
        end
    elseif entry isa PackageSourceAnalysisEntry
        result = activate_do(entry.env_path) do
            pkgfileuri = filepath2uri(entry.pkgfile)
            analyze_parsed_if_exist(state, pkgfileuri, entry.pkgid;
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
    # TODO update reverse_map correctly here (watching the diff of included files)
    update_analysis_instance!(analysis_instance, result)
    notify_diagnostics!(state, analysis_instance.result.uri2diagnostics)
    rerecord_analysis_instance!(state, analysis_instance, aidx)
    nothing
end

end # module JETLS
