module JETLS

export runserver

const __init__hooks__ = Any[]
push_init_hooks!(hook) = push!(__init__hooks__, hook)
function __init__()
    foreach(hook->hook(), __init__hooks__)
end

# TODO turn off `JETLS_DEV_MODE` by default when releasing
using Preferences: Preferences
const JETLS_DEV_MODE = Preferences.@load_preference("JETLS_DEV_MODE", true)
push_init_hooks!() do
    @info "Running JETLS with" JETLS_DEV_MODE
end

include("URIs2/URIs2.jl")
using .URIs2

include("LSP/LSP.jl")
using .LSP

include("JSONRPC.jl")
using .JSONRPC

using REPL # loading REPL is necessary to make `Base.Docs.doc(::Base.Docs.Binding)` work
using Pkg, JuliaSyntax, JET
using JuliaSyntax: JuliaSyntax as JS
using JuliaLowering: JuliaLowering as JL

struct FileInfo
    version::Int
    text::String
    filename::String
    parsed_stream::JS.ParseStream
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
    runtestsuri::URI
end

mutable struct FullAnalysisResult
    staled::Bool
    last_analysis::Float64
    const uri2diagnostics::Dict{URI,Vector{Diagnostic}}
    const analyzed_file_infos::Dict{URI,JET.AnalyzedFileInfo}
    const successfully_analyzed_file_infos::Dict{URI,JET.AnalyzedFileInfo}
end

struct AnalysisContext
    entry::AnalysisEntry
    result::FullAnalysisResult
end

analyzed_file_uris(context::AnalysisContext) = keys(context.result.analyzed_file_infos)

function successfully_analyzed_file_info(context::AnalysisContext, uri::URI)
    return get(context.result.successfully_analyzed_file_infos, uri, nothing)
end

struct ExternalContext end

struct ServerState{F}
    send::F
    workspaceFolders::Vector{URI}
    file_cache::Dict{URI,FileInfo} # syntactic analysis cache
    contexts::Dict{URI,Union{Set{AnalysisContext},ExternalContext}} # entry points for the full analysis (currently not cached really)
    root_path::Ref{String}
    root_env_path::Ref{String}
    completion_module::Ref{Module}
end
function ServerState(send::F) where F
    return ServerState{F}(
        send,
        URI[],
        Dict{URI,FileInfo}(),
        Dict{URI,Union{Set{AnalysisContext},ExternalContext}}(),
        Ref{String}(),
        Ref{String}(),
        Ref{Module}())
end

include("utils.jl")
include("completions.jl")

struct IncludeCallback <: Function
    file_cache::Dict{URI,FileInfo}
end
IncludeCallback(state::ServerState) = IncludeCallback(state.file_cache)
function (include_callback::IncludeCallback)(filepath::String)
    uri = filepath2uri(filepath)
    if haskey(include_callback.file_cache, uri)
        return include_callback.file_cache[uri].text # TODO use `parsed` instead of `text`
    end
    # fallback to the default file-system-based include
    return read(filepath, String)
end

runserver(in::IO, out::IO) = runserver(Returns(nothing), in, out)
function runserver(callback, in::IO, out::IO)
    endpoint = Endpoint(in, out)
    function send(@nospecialize msg)
        JSONRPC.send(endpoint, msg)
        callback(:sent, msg)
        nothing
    end
    state = ServerState(send)
    shutdown_requested = false
    local exit_code::Int = 1
    try
        for msg in endpoint
            callback(:received, msg)
            # handle lifecycle-related messages
            if msg isa InitializeRequest
                handle_InitializeRequest(state, msg)
            elseif msg isa InitializedNotification
                continue
            elseif msg isa ShutdownRequest
                shutdown_requested = true
                send(ShutdownResponse(; id = msg.id, result = null))
            elseif msg isa ExitNotification
                exit_code = !shutdown_requested
                break
            elseif shutdown_requested
                send(ResponseMessage(; id = msg.id, error=ResponseError(;
                    code=ErrorCodes.InvalidRequest,
                    message="Received request after a shutdown request requested")))
            else
                # handle general messages
                handle_message(state, msg)
            end
        end
    catch err
        @error "Message handling loop failed"
        Base.display_error(stderr, err, catch_backtrace())
    finally
        close(endpoint)
    end
    return (; exit_code, endpoint)
end

function handle_message(state::ServerState, msg)
    if JETLS_DEV_MODE
        try
            # `@invokelatest` for allowing changes maded by Revise to be reflected without
            # terminating the `runserver` loop
            return @invokelatest _handle_message(state, msg)
        catch err
            @error "Message handling failed for" typeof(msg)
            Base.display_error(stderr, err, catch_backtrace())
            return nothing
        end
    else
        return _handle_message(state, msg)
    end
end

function _handle_message(state::ServerState, msg)
    if msg isa DidOpenTextDocumentNotification
        return handle_DidOpenTextDocumentNotification(state, msg)
    elseif msg isa DidChangeTextDocumentNotification
        return handle_DidChangeTextDocumentNotification(state, msg)
    elseif msg isa DidCloseTextDocumentNotification
        return handle_DidCloseTextDocumentNotification(state, msg)
    elseif msg isa DidSaveTextDocumentNotification
        return handle_DidSaveTextDocumentNotification(state, msg)
    elseif msg isa DocumentDiagnosticRequest || msg isa WorkspaceDiagnosticRequest
        @assert false "Document and workspace diagnostics are not enabled"
    elseif msg isa CompletionRequest
        return handle_CompletionRequest(state, msg)
    elseif msg isa CompletionResolveRequest
        return handle_CompletionResolveRequest(state, msg)
    elseif JETLS_DEV_MODE
        @warn "Unhandled message" msg
    end
    nothing
end

function handle_InitializeRequest(state::ServerState, msg::InitializeRequest)
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
            @warn "No workspaceFolders or rootUri in InitializeRequest - some functionality will be limited"
        end
    end

    # Update root information
    if isempty(state.workspaceFolders)
        # leave Refs undefined
    elseif length(state.workspaceFolders) == 1
        root_uri = only(state.workspaceFolders)
        root_path = uri2filepath(root_uri)
        if root_path !== nothing
            state.root_path[] = root_path
            env_path = find_env_path(root_path)
            if env_path !== nothing
                state.root_env_path[] = env_path
            end
        else
            @warn "Root URI scheme not supported for workspace analysis" root_uri
        end
    else
        @warn "Multiple workspaceFolders are not supported - using limited functionality" state.workspaceFolders
        # leave Refs undefined
    end

    res = InitializeResponse(; id = msg.id, result = initialize_result())
    return state.send(res)
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
            completionProvider = CompletionOptions(;
                resolveProvider = true,
                triggerCharacters = ["@"],
                completionItem = (;
                    labelDetailsSupport = true)),
        ),
        serverInfo = (;
            name = "JETLS",
            version = "0.0.0"))
end

function run_preset_analysis!(state::ServerState, rooturi::URI)
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
        err isa Base.TOML.ParserError || rethrow(err)
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
    analysis_context = new_analysis_context(entry, result)
    record_reverse_map!(state, analysis_context)
    notify_diagnostics!(state)

    # # analyze test scripts
    # runtests = joinpath(filedir, "runtests.jl")
    # result = activate_do(env_path) do
    #     include_callback = IncludeCallback(state)
    #     JET.analyze_and_report_file!(JET.JETAnalyzer(), runtests;
    #         toplevel_logger=stderr,
    #         include_callback)
    # end
    # entry = PackageTestAnalysisEntry(env_path, runtests)
    # analysis_context = new_analysis_context(entry, result)
    # record_analysis_context!(state, analysis_context)

    nothing
end

function notify_diagnostics!(state::ServerState)
    uri2diagnostics = Dict{URI,Vector{Diagnostic}}()
    for (uri, contexts) in state.contexts
        if contexts isa ExternalContext
            continue
        end
        diagnostics = get!(Vector{Diagnostic}, uri2diagnostics, uri)
        for analysis_context in contexts
            diags = get(analysis_context.result.uri2diagnostics, uri, nothing)
            if diags !== nothing
                append!(diagnostics, diags)
            end
        end
    end
    notify_diagnostics!(state, uri2diagnostics)
end

function notify_diagnostics!(state::ServerState, uri2diagnostics)
    for (uri, diagnostics) in uri2diagnostics
        state.send(PublishDiagnosticsNotification(;
            params = PublishDiagnosticsParams(;
                uri = string(uri),
                # version = 0,
                diagnostics)))
    end
end

function cache_file_info!(state::ServerState, uri::URI, version::Int, text::String, filename::String)
    state.file_cache[uri] = parsefile(version, text, filename)
end
function cache_file_info!(state::ServerState, uri::URI, file_info::FileInfo)
    state.file_cache[uri] = file_info
end
function parsefile(version::Int, text::String, filename::String)
    stream = JS.ParseStream(text)
    JS.parse!(stream; rule=:all)
    return FileInfo(version, text, filename, stream)
end

function handle_DidOpenTextDocumentNotification(state::ServerState, msg::DidOpenTextDocumentNotification)
    textDocument = msg.params.textDocument
    @assert textDocument.languageId == "julia"
    uri = URI(textDocument.uri)
    filename = uri2filename(uri)
    @assert filename !== nothing "Unsupported URI: $uri"
    cache_file_info!(state, uri, textDocument.version, textDocument.text, filename)
    if !haskey(state.contexts, uri)
        initiate_context!(state, uri)
    else # this file is tracked by some context already
        contexts = state.contexts[uri]
        if contexts isa ExternalContext
            # this file is out of the current project scope, ignore it
            return nothing
        else
            # TODO support multiple analysis contexts, which can happen if this file is included from multiple different contexts
            context = first(contexts)
            id = hash(reanalyze_with_context!, hash(context))
            throttle(id, 3.0) do
                reanalyze_with_context!(state, context)
            end
        end
    end
    nothing
end

# TODO switch to incremental updates?
function handle_DidChangeTextDocumentNotification(state::ServerState, msg::DidChangeTextDocumentNotification)
    (;textDocument,contentChanges) = msg.params
    uri = URI(textDocument.uri)
    for contentChange in contentChanges
        @assert contentChange.range === contentChange.rangeLength === nothing # since `change = TextDocumentSyncKind.Full`
    end
    text = last(contentChanges).text
    filename = uri2filename(uri)
    @assert filename !== nothing "Unsupported URI: $uri"
    cache_file_info!(state, uri, textDocument.version, text, filename)
    if !haskey(state.contexts, uri)
        initiate_context!(state, uri)
    else
        contexts = state.contexts[uri]
        if contexts isa ExternalContext
            # this file is out of the current project scope, ignore it
            return nothing
        end
        for analysis_context in contexts
            analysis_context.result.staled = true
        end
        # TODO support multiple analysis contexts, which can happen if this file is included from multiple different contexts
        context = first(contexts)
        id = hash(reanalyze_with_context!, hash(context))
        throttle(id, 3.0) do
            debounce(id, 1.5) do
                reanalyze_with_context!(state, context)
            end
        end
    end
    nothing
end

function handle_DidCloseTextDocumentNotification(state::ServerState, msg::DidCloseTextDocumentNotification)
    textDocument = msg.params.textDocument
    uri = URI(textDocument.uri)
    delete!(state.file_cache, uri)
    return nothing
end

function handle_DidSaveTextDocumentNotification(state::ServerState, msg::DidSaveTextDocumentNotification)
    return nothing
end

function parsed_stream_to_diagnostics(parsed_stream::JS.ParseStream, filename::String)
    diagnostics = Diagnostic[]
    parsed_stream_to_diagnostics!(diagnostics, parsed_stream, filename)
    return diagnostics
end
function parsed_stream_to_diagnostics!(diagnostics::Vector{Diagnostic}, parsed_stream::JS.ParseStream, filename::String)
    source = JS.SourceFile(parsed_stream; filename)
    for diagnostic in parsed_stream.diagnostics
        push!(diagnostics, juliasyntax_diagnostic_to_diagnostic(diagnostic, source))
    end
end
function juliasyntax_diagnostic_to_diagnostic(diagnostic::JS.Diagnostic, source::JS.SourceFile)
    sline, scol = JS.source_location(source, JS.first_byte(diagnostic))
    start = Position(; line = sline-1, character = scol)
    eline, ecol = JS.source_location(source, JS.last_byte(diagnostic))
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

function analyze_parsed_if_exist(state::ServerState, uri::URI, args...; kwargs...)
    if haskey(state.file_cache, uri)
        file_info = state.file_cache[uri]
        parsed_stream = file_info.parsed_stream
        filename = uri2filename(uri)::String
        parsed = JS.build_tree(JS.SyntaxNode, parsed_stream; filename)
        return JET.analyze_and_report_expr!(JET.JETAnalyzer(), parsed, filename, args...; kwargs...)
    else
        filepath = uri2filepath(uri)
        @assert filepath !== nothing "Unsupported URI: $uri"
        return JET.analyze_and_report_file!(JET.JETAnalyzer(), filepath, args...; kwargs...)
    end
end

function is_full_analysis_successful(result)
    return isempty(result.res.toplevel_error_reports)
end

function new_analysis_context(entry::AnalysisEntry, result)
    analyzed_file_infos = Dict{URI,JET.AnalyzedFileInfo}(
        # `filepath` is an absolute path (since `path` is specified as absolute)
        filename2uri(filepath) => analyzed_file_info for (filepath, analyzed_file_info) in result.res.analyzed_files)
    # TODO return something for `toplevel_error_reports`
    uri2diagnostics = jet_result_to_diagnostics(result, keys(analyzed_file_infos))
    successfully_analyzed_file_infos = copy(analyzed_file_infos)
    is_full_analysis_successful(result) ||
        empty!(successfully_analyzed_file_infos)
    analysis_result = FullAnalysisResult(false, time(), uri2diagnostics, analyzed_file_infos, successfully_analyzed_file_infos)
    return AnalysisContext(entry, analysis_result)
end

function update_analysis_context!(analysis_context::AnalysisContext, result)
    uri2diagnostics = analysis_context.result.uri2diagnostics
    cached_file_infos = analysis_context.result.analyzed_file_infos
    cached_successfully_analyzed_file_infos = analysis_context.result.successfully_analyzed_file_infos
    new_file_infos = Dict{URI,JET.AnalyzedFileInfo}(
        # `filepath` is an absolute path (since `path` is specified as absolute)
        filename2uri(filepath) => analyzed_file_info for (filepath, analyzed_file_info) in result.res.analyzed_files)
    for deleted_file_uri in setdiff(keys(cached_file_infos), keys(new_file_infos))
        empty!(get!(()->Diagnostic[], uri2diagnostics, deleted_file_uri))
        delete!(cached_file_infos, deleted_file_uri)
        if is_full_analysis_successful(result)
            delete!(cached_successfully_analyzed_file_infos, deleted_file_uri)
        end
    end
    for (new_file_uri, analyzed_file_info) in new_file_infos
        cached_file_infos[new_file_uri] = analyzed_file_info
        if is_full_analysis_successful(result)
            cached_successfully_analyzed_file_infos[new_file_uri] = analyzed_file_info
        end
        empty!(get!(()->Diagnostic[], uri2diagnostics, new_file_uri))
    end
    jet_result_to_diagnostics!(uri2diagnostics, result)
    analysis_context.result.staled = false
    analysis_context.result.last_analysis = time()
end

# TODO This reverse map recording should respect the changes made in `include` chains
function record_reverse_map!(state::ServerState, analysis_context::AnalysisContext)
    afiles = analyzed_file_uris(analysis_context)
    for uri in afiles
        contexts = get!(Set{AnalysisContext}, state.contexts, uri)
        should_record = true
        for analysis_context′ in contexts
            bfiles = analyzed_file_uris(analysis_context′)
            if afiles ≠ bfiles
                if afiles ⊆ bfiles
                    should_record = false
                else # bfiles ⊆ afiles, i.e. now we have a better context to analyze this file
                    delete!(contexts, analysis_context′)
                end
            end
        end
        should_record && push!(contexts, analysis_context)
    end
end

# TODO severity
function jet_result_to_diagnostics(result, file_uris)
    uri2diagnostics = Dict{URI,Vector{Diagnostic}}(uri => Diagnostic[] for uri in file_uris)
    jet_result_to_diagnostics!(uri2diagnostics, result)
    return uri2diagnostics
end

function jet_result_to_diagnostics!(uri2diagnostics::Dict{URI,Vector{Diagnostic}}, result)
    for report in result.res.toplevel_error_reports
        diagnostic = jet_toplevel_error_report_to_diagnostic(report)
        filename = report.file
        filename === :none && continue
        if startswith(filename, "Untitled")
            uri = filename2uri(filename)
        else
            uri = filepath2uri(JET.tofullpath(filename))
        end
        push!(uri2diagnostics[uri], diagnostic)
    end
    for report in result.res.inference_error_reports
        diagnostic = jet_inference_error_report_to_diagnostic(report)
        topframe = report.vst[1]
        topframe.file === :none && continue # TODO Figure out why this is necessary
        filename = String(topframe.file)
        if startswith(filename, "Untitled")
            uri = filename2uri(filename)
        else
            uri = filepath2uri(JET.tofullpath(filename))
        end
        push!(uri2diagnostics[uri], diagnostic)
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

find_env_path(path) = search_up_file(path, "Project.toml")

function search_up_file(path, basename)
    traverse_dir(dirname(path)) do dir
        project_file = joinpath(dir, basename)
        if isfile(project_file)
            return project_file
        end
        return nothing
    end
end

function traverse_dir(f, dir)
    while !isempty(dir)
        res = f(dir)
        if res !== nothing
            return res
        end
        parent = dirname(dir)
        if parent == dir
            break
        end
        dir = parent
    end
    return nothing
end

# check if `dir1` is a subdirectory of `dir2`
function issubdir(dir1, dir2)
    dir1 = rstrip(dir1, '/')
    dir2 = rstrip(dir2, '/')
    something(traverse_dir(dir1) do dir
        if dir == dir2
            return true
        end
        return nothing
    end, false)
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

function initiate_context!(state::ServerState, uri::URI)
    if uri.scheme == "file"
        filename = path = uri2filepath(uri)::String
        if isassigned(state.root_path)
            if !issubdir(dirname(path), state.root_path[])
                state.contexts[uri] = ExternalContext()
                return nothing
            end
        end
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
        env_path = isassigned(state.root_env_path) ? state.root_env_path[] : nothing
        pkgname = nothing # to hit the `@goto analyze_script` case
    else @assert false "Unsupported URI: $uri" end
    file_info = state.file_cache[uri]
    parsed_stream = file_info.parsed_stream
    if !isempty(parsed_stream.diagnostics)
        diagnostics = parsed_stream_to_diagnostics(parsed_stream, file_info.filename)
        notify_diagnostics!(state, (uri => diagnostics,))
        return nothing
    end
    include_callback = IncludeCallback(state)
    if env_path === nothing
        @label analyze_script
        filename = file_info.filename
        parsed = JS.build_tree(JS.SyntaxNode, parsed_stream; filename)
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
        analysis_context = new_analysis_context(entry, result)
        @assert uri in analyzed_file_uris(analysis_context)
        record_reverse_map!(state, analysis_context)
    elseif pkgname === nothing
        @goto analyze_script
    else # this file is likely one within a package
        filekind, filedir = find_package_directory(path, env_path)
        if filekind === :script
            @goto analyze_script
        elseif filekind === :src
            # analyze package source files
            entry_result = activate_do(env_path) do
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
                pkgfiluri = filepath2uri(pkgfile)
                entry = PackageSourceAnalysisEntry(env_path, pkgfile, pkgid)
                res = analyze_parsed_if_exist(state, pkgfiluri, pkgid;
                    toplevel_logger=nothing,
                    analyze_from_definitions=true,
                    target_defined_modules=true,
                    concretization_patterns=[:(x_)],
                    include_callback)
                return entry, res
            end
            if entry_result === nothing
                @goto analyze_script
            end
            entry, result = entry_result
            analysis_context = new_analysis_context(entry, result)
            record_reverse_map!(state, analysis_context)
            if uri ∉ analyzed_file_uris(analysis_context)
                @goto analyze_script
            end
        elseif filekind === :test
            # analyze test scripts
            runtestsfile = joinpath(filedir, "runtests.jl")
            runtestsuri = filepath2uri(runtestsfile)
            result = activate_do(env_path) do
                analyze_parsed_if_exist(state, runtestsuri;
                    toplevel_logger=stderr,
                    include_callback)
            end
            entry = PackageTestAnalysisEntry(env_path, runtestsuri)
            analysis_context = new_analysis_context(entry, result)
            record_reverse_map!(state, analysis_context)
            if uri ∉ analyzed_file_uris(analysis_context)
                @goto analyze_script
            end
        elseif filekind === :docs
            @goto analyze_script # TODO
        else
            @assert filekind === :ext
            @goto analyze_script # TODO
        end
    end

    notify_diagnostics!(state)
    nothing
end

function reanalyze_with_context!(state::ServerState, analysis_context::AnalysisContext)
    analysis_result = analysis_context.result
    if !analysis_result.staled
        return nothing
    end
    parse_failed = nothing
    for uri in analyzed_file_uris(analysis_context)
        if haskey(state.file_cache, uri)
            file_info = state.file_cache[uri]
            parsed_stream = file_info.parsed_stream
            isempty(parsed_stream.diagnostics) && continue
            if parse_failed === nothing
                parse_failed = Dict{URI,FileInfo}()
            end
            parse_failed[uri] = file_info
        end
    end
    if parse_failed !== nothing
        notify_diagnostics!(state, (
            uri => parsed_stream_to_diagnostics(file_info.parsed_stream, file_info.filename) for (uri, file_info) in parse_failed))
        return nothing
    end
    entry = analysis_context.entry
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
            analyze_parsed_if_exist(state, entry.runtestsuri;
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
    update_analysis_context!(analysis_context, result)
    record_reverse_map!(state, analysis_context)
    notify_diagnostics!(state)
    nothing
end

end # module JETLS
