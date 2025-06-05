module JETLS

export Server, Endpoint, runserver

const __init__hooks__ = Any[]
push_init_hooks!(hook) = push!(__init__hooks__, hook)
function __init__()
    foreach(hook->hook(), __init__hooks__)
end

using Preferences: Preferences
const JETLS_DEV_MODE = Preferences.@load_preference("JETLS_DEV_MODE", false)
push_init_hooks!() do
    @info "Running JETLS with" JETLS_DEV_MODE
end

include("URIs2/URIs2.jl")
using .URIs2

include("LSP/LSP.jl")
using .LSP

include("JSONRPC.jl")
using .JSONRPC

include("analysis/analysis.jl")
using .Analysis

using REPL # loading REPL is necessary to make `Base.Docs.doc(::Base.Docs.Binding)` work
using Pkg, JuliaSyntax
using JET: JET
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
    actual2virtual::JET.Actual2Virtual
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

struct Registered
    id::String
    method::String
end

mutable struct ServerState
    const workspaceFolders::Vector{URI}
    const file_cache::Dict{URI,FileInfo} # syntactic analysis cache
    const contexts::Dict{URI,Union{Set{AnalysisContext},ExternalContext}} # entry points for the full analysis (currently not cached really)
    const currently_registered::Set{Registered}
    root_path::String
    root_env_path::String
    completion_module::Module
    init_params::InitializeParams
    function ServerState()
        return new(
            URI[],
            Dict{URI,FileInfo}(),
            Dict{URI,Union{Set{AnalysisContext},ExternalContext}}(),
            Set{Registered}(),
        )
    end
end

struct Server{Callback}
    endpoint::Endpoint
    callback::Callback
    state::ServerState
    function Server(callback::Callback, endpoint::Endpoint) where Callback
        return new{Callback}(
            endpoint,
            callback,
            ServerState(),
        )
    end
end

const DEFAULT_DOCUMENT_SELECTOR = DocumentFilter[
    DocumentFilter(; language = "julia")
]

include("utils.jl")
include("registration.jl")
include("completions.jl")
include("signature-help.jl")
include("definition.jl")
include("diagnostics.jl")

"""
    send(state::ServerState, msg)

Send a message to the client through the server `state.endpoint`

This function is used by each handler that processes messages sent from the client,
as well as for sending requests and notifications from the server to the client.
"""
function send(server::Server, @nospecialize msg)
    JSONRPC.send(server.endpoint, msg)
    server.callback !== nothing && server.callback(:sent, msg)
    nothing
end

"""
    runserver([callback,] in::IO, out::IO) -> (; exit_code::Int, endpoint::Endpoint)
    runserver([callback,] endpoint::Endpoint) -> (; exit_code::Int, endpoint::Endpoint)
    runserver([callback,] server::Server) -> (; exit_code::Int, endpoint::Endpoint)

Run the JETLS language server with the specified input/output streams or endpoint.

The `callback` function is invoked on each message sent or received, with the
signature `callback(event::Symbol, msg)` where `event` is either `:sent` or
`:received`. If not specified, a no-op callback is used.

When given IO streams, the function creates an `Endpoint` and then a `ServerState`
before entering the message handling loop. The function returns after receiving an
exit notification, with an exit code based on whether shutdown was properly requested.
"""
function runserver end

"""
    currently_running::Server

A global variable that may hold a reference to the currently running `Server` instance.

This variable is only defined when running with `JETLS_DEV_MODE=true` and is intended
for development purposes only, particularly for inspection or dynamic registration hacking.

!!! warning
    This global variable should only be used for development purposes and should NOT
    be included in production routines and even in test code.
    In test code, use the `withserver` routine to create a `Server` instance for each
    individual test.
"""
global currently_running::Server

const SERVER_LOOP_STARTUP_MSG = "Running JETLS server loop"
const SERVER_LOOP_EXIT_MSG    = "Exited JETLS server loop"

runserver(args...; kwarg...) = runserver(Returns(nothing), args...; kwarg...) # no callback specified
runserver(callback, in::IO, out::IO; kwarg...) = runserver(callback, Endpoint(in, out); kwarg...)
runserver(callback, endpoint::Endpoint; kwarg...) = runserver(Server(callback, endpoint); kwarg...)
function runserver(server::Server; server_loop_log::Bool=true)
    shutdown_requested = false
    local exit_code::Int = 1
    server_loop_log && @info SERVER_LOOP_STARTUP_MSG
    try
        for msg in server.endpoint
            server.callback !== nothing && server.callback(:received, msg)
            # handle lifecycle-related messages
            if msg isa InitializeRequest
                handle_InitializeRequest(server, msg)
            elseif msg isa InitializedNotification
                handle_InitializedNotification(server)
            elseif msg isa ShutdownRequest
                shutdown_requested = true
                send(server, ShutdownResponse(; id = msg.id, result = null))
            elseif msg isa ExitNotification
                exit_code = !shutdown_requested
                break
            elseif shutdown_requested
                send(server, ResponseMessage(;
                    id = msg.id,
                    error=ResponseError(;
                        code=ErrorCodes.InvalidRequest,
                        message="Received request after a shutdown request requested")))
            else
                # handle general messages
                handle_message(server, msg)
            end
        end
    catch err
        @error "Message handling loop failed"
        Base.display_error(stderr, err, catch_backtrace())
    finally
        close(server.endpoint)
    end
    server_loop_log && @info SERVER_LOOP_EXIT_MSG
    return (; exit_code, server.endpoint)
end

function handle_message(server::Server, msg)
    @nospecialize msg
    if JETLS_DEV_MODE
        try
            # `@invokelatest` for allowing changes maded by Revise to be reflected without
            # terminating the `runserver` loop
            return @invokelatest _handle_message(server, msg)
        catch err
            @error "Message handling failed for" typeof(msg)
            Base.display_error(stderr, err, catch_backtrace())
            return nothing
        end
    else
        return _handle_message(server, msg)
    end
end

function _handle_message(server::Server, msg)
    @nospecialize msg
    if msg isa DidOpenTextDocumentNotification
        return handle_DidOpenTextDocumentNotification(server, msg)
    elseif msg isa DidChangeTextDocumentNotification
        return handle_DidChangeTextDocumentNotification(server, msg)
    elseif msg isa DidCloseTextDocumentNotification
        return handle_DidCloseTextDocumentNotification(server, msg)
    elseif msg isa DidSaveTextDocumentNotification
        return handle_DidSaveTextDocumentNotification(server, msg)
    elseif msg isa DocumentDiagnosticRequest || msg isa WorkspaceDiagnosticRequest
        @assert false "Document and workspace diagnostics are not enabled"
    elseif msg isa CompletionRequest
        return handle_CompletionRequest(server, msg)
    elseif msg isa CompletionResolveRequest
        return handle_CompletionResolveRequest(server, msg)
    elseif msg isa SignatureHelpRequest
        return handle_SignatureHelpRequest(server, msg)
    elseif msg isa DefinitionRequest
        return handle_DefinitionRequest(server, msg)
    elseif JETLS_DEV_MODE
        if isdefined(msg, :method)
            id = getfield(msg, :method)
        elseif msg isa Dict{Symbol,Any}
            id = get(()->get(msg, :id, nothing), msg, :method)
        else
            id = typeof(msg)
        end
        @warn "Unhandled message" msg _id=id maxlog=1
    end
    nothing
end

"""
Receives `msg::InitializeRequest` and sets up the `server.state` based on `msg.params`.
As a response to this `msg`, it returns an `InitializeResponse` and performs registration of
server capabilities and server information that should occur during initialization.

For server capabilities, it's preferable to register those that support dynamic/static
registration in the `handle_InitializedNotification` handler using `RegisterCapabilityRequest`.
On the other hand, basic server capabilities such as `textDocumentSync` must be registered here,
and features that don't extend and support `StaticRegistrationOptions` like "completion"
need to be registered in this handler in a case when the client does not support
dynamic registration.
"""
function handle_InitializeRequest(server::Server, msg::InitializeRequest)
    state = server.state
    params = state.init_params = msg.params

    workspaceFolders = params.workspaceFolders
    if workspaceFolders !== nothing
        for workspaceFolder in workspaceFolders
            push!(state.workspaceFolders, workspaceFolder.uri)
        end
    else
        rootUri = params.rootUri
        if rootUri !== nothing
            push!(state.workspaceFolders, rootUri)
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
            state.root_path = root_path
            env_path = find_env_path(root_path)
            if env_path !== nothing
                state.root_env_path = env_path
            end
        else
            @warn "Root URI scheme not supported for workspace analysis" root_uri
        end
    else
        @warn "Multiple workspaceFolders are not supported - using limited functionality" state.workspaceFolders
        # leave Refs undefined
    end

    if getobjpath(params.capabilities,
        :textDocument, :completion, :dynamicRegistration) !== true
        completionProvider = completion_options()
        if JETLS_DEV_MODE
            @info "Registering 'textDocument/completion' with `InitializeResponse`"
        end
    else
        completionProvider = nothing # will be registered dynamically
    end

    if getobjpath(params.capabilities,
        :textDocument, :signatureHelp, :dynamicRegistration) !== true
        signatureHelpProvider = signature_help_options()
        if JETLS_DEV_MODE
            @info "Registering 'textDocument/signatureHelp' with `InitializeResponse`"
        end
    else
        signatureHelpProvider = nothing # will be registered dynamically
    end

    if getpath(params.capabilities,
        :textDocument, :definition, :dynamicRegistration) !== true
        definitionProvider = definition_options()
        if JETLS_DEV_MODE
            @info "Registering 'textDocument/definition' with `InitializeResponse`"
        end
    else
        definitionProvider = nothing # will be registered dynamically
    end

    result = InitializeResult(;
        capabilities = ServerCapabilities(;
            positionEncoding = PositionEncodingKind.UTF16,
            textDocumentSync = TextDocumentSyncOptions(;
                openClose = true,
                change = TextDocumentSyncKind.Full,
                save = SaveOptions(;
                    includeText = true)),
            completionProvider,
            signatureHelpProvider,
            definitionProvider,
        ),
        serverInfo = (;
            name = "JETLS",
            version = "0.0.0"))

    return send(server,
        InitializeResponse(;
            id = msg.id,
            result))
end

"""
Handler that performs the necessary actions when receiving an `InitializedNotification`.
Primarily, it registers LSP features that support dynamic/static registration and
should be enabled by default.
"""
function handle_InitializedNotification(server::Server)
    state = server.state

    isdefined(state, :init_params) ||
        error("Initialization process not completed") # to exit the server loop

    registrations = Registration[]

    if getobjpath(state.init_params.capabilities,
        :textDocument, :completion, :dynamicRegistration) === true
        push!(registrations, completion_registration())
        if JETLS_DEV_MODE
            @info "Dynamically registering 'textDocument/completion' upon `InitializedNotification`"
        end
    else
        # NOTE If completion's `dynamicRegistration` is not supported,
        # it needs to be registered along with initialization in the `InitializeResponse`,
        # since `CompletionRegistrationOptions` does not extend `StaticRegistrationOptions`.
    end

    if getobjpath(state.init_params.capabilities,
        :textDocument, :signatureHelp, :dynamicRegistration) === true
        push!(registrations, signature_help_registration())
        if JETLS_DEV_MODE
            @info "Dynamically registering 'textDocument/signatureHelp' upon `InitializedNotification`"
        end
    else
        # NOTE If completion's `dynamicRegistration` is not supported,
        # it needs to be registered along with initialization in the `InitializeResponse`,
        # since `SignatureHelpRegistrationOptions` does not extend `StaticRegistrationOptions`.
    end

    if getpath(state.init_params.capabilities,
        :textDocument, :definition, :dynamicRegistration) === true
        push!(registrations, definition_registration())
        if JETLS_DEV_MODE
            @info "Dynamically registering 'textDocument/definition' upon `InitializedNotification`"
        end
    else
        # NOTE If definition's `dynamicRegistration` is not supported,
        # it needs to be registered along with initialization in the `InitializeResponse`,
        # since `DefinitionRegistrationOptions` does not extend `StaticRegistrationOptions`.
    end

    register(server, registrations)
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

function handle_DidOpenTextDocumentNotification(server::Server, msg::DidOpenTextDocumentNotification)
    state = server.state
    textDocument = msg.params.textDocument
    @assert textDocument.languageId == "julia"
    uri = textDocument.uri
    filename = uri2filename(uri)
    @assert filename !== nothing "Unsupported URI: $uri"
    cache_file_info!(state, uri, textDocument.version, textDocument.text, filename)
    if !haskey(state.contexts, uri)
        res = initiate_context!(state, uri)
        if res === nothing
            notify_diagnostics!(server)
        else
            notify_diagnostics!(server, res)
        end
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
                res = reanalyze_with_context!(state, context)
                if res === nothing
                    notify_diagnostics!(server)
                else
                    notify_diagnostics!(server, res)
                end
            end
        end
    end
    nothing
end

# TODO switch to incremental updates?
function handle_DidChangeTextDocumentNotification(server::Server, msg::DidChangeTextDocumentNotification)
    state = server.state
    (;textDocument,contentChanges) = msg.params
    uri = textDocument.uri
    for contentChange in contentChanges
        @assert contentChange.range === contentChange.rangeLength === nothing # since `change = TextDocumentSyncKind.Full`
    end
    text = last(contentChanges).text
    filename = uri2filename(uri)
    @assert filename !== nothing "Unsupported URI: $uri"
    cache_file_info!(state, uri, textDocument.version, text, filename)
    if !haskey(state.contexts, uri)
        res = initiate_context!(state, uri)
        if res === nothing
            notify_diagnostics!(server)
        else
            notify_diagnostics!(server, res)
        end
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
                res = reanalyze_with_context!(state, context)
                if res === nothing
                    notify_diagnostics!(server)
                else
                    notify_diagnostics!(server, res)
                end
            end
        end
    end
    nothing
end

function handle_DidCloseTextDocumentNotification(server::Server, msg::DidCloseTextDocumentNotification)
    state = server.state
    textDocument = msg.params.textDocument
    uri = textDocument.uri
    delete!(state.file_cache, uri)
    return nothing
end

function handle_DidSaveTextDocumentNotification(server::Server, msg::DidSaveTextDocumentNotification)
    return nothing
end

function analyze_parsed_if_exist(state::ServerState, uri::URI, args...; kwargs...)
    if haskey(state.file_cache, uri)
        file_info = state.file_cache[uri]
        parsed_stream = file_info.parsed_stream
        filename = uri2filename(uri)::String
        parsed = JS.build_tree(JS.SyntaxNode, parsed_stream; filename)
        return JET.analyze_and_report_expr!(JETLSAnalyzer(), parsed, filename, args...; kwargs...)
    else
        filepath = uri2filepath(uri)
        @assert filepath !== nothing "Unsupported URI: $uri"
        return JET.analyze_and_report_file!(JETLSAnalyzer(), filepath, args...; kwargs...)
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
    uri2diagnostics = jet_result_to_diagnostics(keys(analyzed_file_infos), result)
    successfully_analyzed_file_infos = copy(analyzed_file_infos)
    is_full_analysis_successful(result) || empty!(successfully_analyzed_file_infos)
    analysis_result = FullAnalysisResult(false, time(), result.res.actual2virtual, uri2diagnostics, analyzed_file_infos, successfully_analyzed_file_infos)
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
    if is_full_analysis_successful(result)
        analysis_context.result.actual2virtual = result.res.actual2virtual
    end
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

function initiate_context!(state::ServerState, uri::URI)
    if uri.scheme == "file"
        filename = path = uri2filepath(uri)::String
        if isdefined(state, :root_path)
            if !issubdir(dirname(path), state.root_path)
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
        env_path = isdefined(state, :root_env_path) ? state.root_env_path : nothing
        pkgname = nothing # to hit the `@goto analyze_script` case
    else @assert false "Unsupported URI: $uri" end
    file_info = state.file_cache[uri]
    parsed_stream = file_info.parsed_stream
    if !isempty(parsed_stream.diagnostics)
        diagnostics = parsed_stream_to_diagnostics(parsed_stream, file_info.filename)
        return (uri => diagnostics,)
    end
    include_callback = IncludeCallback(state)
    if env_path === nothing
        @label analyze_script
        filename = file_info.filename
        parsed = JS.build_tree(JS.SyntaxNode, parsed_stream; filename)
        if env_path !== nothing
            entry = ScriptInEnvAnalysisEntry(env_path, uri)
            result = activate_do(env_path) do
                JET.analyze_and_report_expr!(JETLSAnalyzer(), parsed, filename;
                    toplevel_logger=stderr,
                    include_callback)
            end
        else
            entry = ScriptAnalysisEntry(uri)
            result = JET.analyze_and_report_expr!(JETLSAnalyzer(), parsed, filename;
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

    return nothing
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
        return (
            uri => parsed_stream_to_diagnostics(file_info.parsed_stream, file_info.filename)
            for (uri, file_info) in parse_failed)
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
    return nothing
end

function get_text_and_positions(text::AbstractString, matcher::Regex=r"#=cursor=#")
    positions = Position[]
    lines = split(text, '\n')

    # First pass to collect positions
    for (i, line) in enumerate(lines)
        offset_adjustment = 0
        for m in eachmatch(matcher, line)
            # Position is 0-based
            # Adjust the character position by subtracting the length of previous matches
            adjusted_offset = m.offset - offset_adjustment
            push!(positions, Position(; line=i-1, character=adjusted_offset-1))
            offset_adjustment += length(m.match)
        end
    end

    # Second pass to replace all occurrences
    for (i, line) in enumerate(lines)
        lines[i] = replace(line, matcher => "")
    end

    return join(lines, '\n'), positions
end

using PrecompileTools
@setup_workload let
    state = ServerState()
    text, positions = get_text_and_positions("""
        struct Bar
            x::Int
        end
        function getx(bar::Bar)
            out = bar.x
            #=cursor=#
            return out
        end
    """)
    position = only(positions)
    mktemp() do filename, io
        uri = filepath2uri(filename)
        @compile_workload let
            cache_file_info!(state, uri, #=version=#1, text, filename)
            comp_params = CompletionParams(;
                textDocument = TextDocumentIdentifier(; uri),
                position)
            items = get_completion_items(state, uri, comp_params)
            any(item->item.label=="out", items) || @warn "completion seems to be broken"
            any(item->item.label=="bar", items) || @warn "completion seems to be broken"
        end
    end
end

end # module JETLS
