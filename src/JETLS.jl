module JETLS

export Endpoint, Server, runserver

const JETLS_VERSION = let
    version_file = joinpath(dirname(@__DIR__), "JETLS_VERSION")
    include_dependency(version_file)
    isfile(version_file) ? strip(read(version_file, String)) : "unknown"
end

# Append `old_path => new_path` pairs to register a key migration, or
# `old_path => nothing` to deprecate a key without a replacement.
# Each path is a list of nested keys; `migrate_deprecated_config_keys!` consults this
# table and rewrites raw user config dicts before parsing.
const deprecated_configurations = Pair{Vector{String},Union{Nothing,Vector{String}}}[]

const __init__hooks__ = Any[]
push_init_hook!(hook) = push!(__init__hooks__, hook)
function __init__()
    foreach(hook->hook(), __init__hooks__)
end

using Preferences: Preferences
const JETLS_DEV_MODE = Preferences.@load_preference("JETLS_DEV_MODE", false)
const JETLS_TEST_MODE = Preferences.@load_preference("JETLS_TEST_MODE", false)
const JETLS_DEBUG_LOWERING = Preferences.@load_preference("JETLS_DEBUG_LOWERING", false)
function show_setup_info(msg::AbstractString)
    @info msg Sys.BINDIR pkgdir(JETLS) Threads.nthreads() JETLS_VERSION JETLS_DEV_MODE JETLS_TEST_MODE JETLS_DEBUG_LOWERING
end

const server_world_age = Ref{UInt}(typemax(UInt))

"""
    advance_server_world!()

Pin JETLS server dispatch to the current world age.
"""
advance_server_world!() = (server_world_age[] = Base.get_world_counter(); nothing)

call_in_server_world(@nospecialize(f), args...; kwargs...) =
    Base.invoke_in_world(server_world_age[], f, args...; kwargs...)

push_init_hook!(advance_server_world!)

@static if JETLS_DEV_MODE
    using Revise: Revise
else
    const Revise = nothing
end

revise_now!() = @static JETLS_DEV_MODE && Revise.revise()

using LSP
using LSP: LSP
using LSP.URIs2
using LSP.Communication: Endpoint

const MessageId = Union{String, Int}

using Pkg
using Compiler: Compiler as CC
using JET: JET
using JuliaSyntax: JuliaSyntax as JS
using JuliaLowering: JuliaLowering as JL
using REPL: REPL # loading REPL is necessary to make `Base.Docs.doc(::Base.Docs.Binding)` work
using Markdown: Markdown
using TOML: TOML
using Test: Test # used to define new-style implementations of `@test`/`@testset`

using Glob: Glob

abstract type AnalysisEntry end # used by `Analyzer.LSAnalyzer`

include("AtomicContainers/AtomicContainers.jl")
using .AtomicContainers
# const SWStats  = @static JETLS_DEV_MODE ? AtomicContainers.SWStats  : Nothing
# const LWStats  = @static JETLS_DEV_MODE ? AtomicContainers.LWStats  : Nothing
# const CASStats = @static JETLS_DEV_MODE ? AtomicContainers.CASStats : Nothing
const SWStats  = Nothing
const LWStats  = Nothing
const CASStats = Nothing

const SyntaxTree = JS.SyntaxTree
const SyntaxList = JS.SyntaxList

include("analysis/Analyzer.jl")
using .Analyzer

# define fallback constructors for LSAnalyzer
Analyzer.LSAnalyzer(uri::URI, args...; kwargs...) = LSAnalyzer(ScriptAnalysisEntry(uri), args...; kwargs...)
Analyzer.LSAnalyzer(args...; kwargs...) = LSAnalyzer(ScriptAnalysisEntry(filepath2uri(@__FILE__)), args...; kwargs...)

include("FixedSizeQueues/FixedSizeQueues.jl")
using .FixedSizeQueues

include("utils/markdown.jl")
include("utils/general.jl")

include("testrunner/testrunner-types.jl")
include("types.jl")

include("utils/jl-syntax-macros.jl")
include("utils/string.jl")
include("utils/toml.jl")
include("utils/path.jl")
include("utils/pkg.jl")
include("utils/JETLSTestModule.jl")
include("utils/ast.jl")
include("utils/binding.jl")
include("utils/docs.jl")
include("utils/lsp.jl")
include("utils/server.jl")
include("utils/native-inference.jl")

include("analysis/Closure2Opaque.jl")
using .Closure2Opaque

include("analysis/TypeAnnotation.jl")
using .TypeAnnotation

include("utils/type-annotation-utils.jl")

include("init-options.jl")
include("config.jl")
include("workspace-configuration.jl")

include("analysis/occurrence-analysis.jl")
include("analysis/cfg-analysis.jl")

include("diagnostic.jl")

include("analysis/Interpreter.jl")
using .Interpreter

include("document-synchronization.jl")
include("notebook.jl")
include("analysis/instantiation-progress.jl")
include("analysis/full-analysis.jl")
include("registration.jl")
include("apply-edit.jl")
include("text-document-content.jl")
include("code-views.jl")
include("execute-command.jl")
include("signature-help.jl")
include("completions.jl")
include("declaration.jl")
include("definition.jl")
include("type-definition.jl")
include("references.jl")
include("hover.jl")
include("document-highlight.jl")
include("document-link.jl")
include("document-symbol.jl")
include("workspace-symbol.jl")
include("code-action.jl")
include("code-lens.jl")
include("formatting.jl")
include("inlay-hint.jl")
include("semantic-tokens.jl")
include("rename.jl")
include("testrunner/testrunner.jl")
include("profile.jl")
include("did-change-watched-files.jl")
include("initialize.jl")

"""
    runserver(in::IO, out::IO; client_process_id=nothing) -> exit_code::Int
    runserver(endpoint::Endpoint; client_process_id=nothing) -> exit_code::Int
    runserver(server::Server; client_process_id=nothing) -> exit_code::Int

Run the JETLS language server with the specified input/output streams or endpoint.

When given IO streams, the function creates an `Endpoint` and then a `ServerState`
before entering the message handling loop. The function returns after receiving an
exit notification, with an exit code based on whether shutdown was properly requested.

# Keyword arguments
- `client_process_id::Union{Nothing,Int}`: If provided, the server monitors the
  specified client process and automatically shuts down if the client process
  terminates. This handles cases where the client crashes and cannot execute the
  normal server shutdown process. Note that if this is specified, the value is
  expected to be identical to the process ID that the client passes as `processId`
  in the [initialize parameters](@ref InitializeParams) of the
  [`InitializeRequest`](@ref).
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

struct SelfShutdownNotification end
"""
In cases where the client crashes and cannot execute the normal server shutdown,
this special token is sent from the server itself to its `endpoint`.
When the server loop receives this token, the server immediately shuts down the server loop,
allowing the caller side to safely `exit` this Julia process.
"""
const self_shutdown_token = SelfShutdownNotification()

runserver(in::IO, out::IO; kwargs...) = runserver(Endpoint(in, out); kwargs...)
runserver(endpoint::Endpoint; kwargs...) = runserver(Server(endpoint); kwargs...)
function runserver(
        server::Server;
        client_process_id::Union{Nothing,Int} = nothing,
        transport::String = "stdio"
    )
    initialize_requested = shutdown_requested = false
    local exit_code::Int = 1
    @static JETLS_DEV_MODE && @info "Running JETLS server loop"
    seq_queue, seq_task = start_sequential_message_worker(server)
    con_queue, con_task = start_concurrent_message_worker(server)
    if !isnothing(client_process_id)
        @static JETLS_DEV_MODE && @info "Monitoring client process ID" client_process_id
        Threads.@spawn while true
            # To handle cases where the client crashes and cannot execute the normal
            # server shutdown process, check every 60 seconds whether the `processId`
            # is alive, and if not, put a special message token `SelfShutdownNotification`
            # into the `endpoint` queue. See `runserver(server::Server)`.
            sleep(60)
            isopen(server.endpoint) || break
            if !iszero(@ccall uv_kill(client_process_id::Cint, 0::Cint)::Cint)
                put!(server.endpoint.in_msg_queue, self_shutdown_token)
                break
            end
        end
    end
    try
        for msg in server.endpoint
            server.callback !== nothing && server.callback(:received, msg)
            # Handle lifecycle-related messages
            if msg isa InitializeRequest
                initialize_requested = true
                handle_InitializeRequest(server, msg; client_process_id, transport)
            elseif msg isa InitializedNotification
                handle_InitializedNotification(server)
            elseif msg isa ShutdownRequest
                shutdown_requested = true
                send(server, ShutdownResponse(; id = msg.id, result = null))
            elseif msg isa ExitNotification
                exit_code = !shutdown_requested
                break
            elseif msg === self_shutdown_token
                exit_code = 1
                break
            elseif !initialize_requested
                # Handle messages received before initialization (LSP 3.18 spec):
                # - For requests: respond with error code -32002 (ServerNotInitialized)
                # - For notifications: drop silently (exit already handled above)
                id = valid_request_message_id(msg)
                if id !== nothing
                    send(server, ResponseMessage(;
                        id,
                        result = nothing,
                        error = ResponseError(;
                            code = ErrorCodes.ServerNotInitialized,
                            message = "Server has not been initialized")))
                end
            elseif shutdown_requested
                # Handle messages received after a shutdown request (LSP 3.18 spec):
                # - For requests: respond with error code -32600 (InvalidRequest)
                # - For notifications and responses to server requests: drop silently
                #   (exit already handled above)
                id = valid_request_message_id(msg)
                if id !== nothing
                    send(server, ResponseMessage(;
                        id,
                        result = nothing,
                        error = ResponseError(;
                            code = ErrorCodes.InvalidRequest,
                            message = "Received request after a shutdown request requested")))
                end
            elseif is_sequential_msg(msg)
                put!(seq_queue, msg)
            else
                put!(con_queue, msg)
            end
            GC.safepoint()
        end
    catch err
        @error "Message handling loop failed"
        Base.display_error(stderr, err, catch_backtrace())
    finally
        # The client may close the transport after `exit`; reject output before worker cleanup.
        close(server.endpoint)
        stop_analysis_worker(server)
        stop_signature_analysis_workers(server)
        put!(seq_queue, nothing); put!(con_queue, nothing);
        close(seq_queue); close(con_queue);
        waitall((seq_task, con_task))
    end
    @static JETLS_DEV_MODE && @info "Exited JETLS server loop"
    return exit_code
end

function valid_request_message_id(@nospecialize msg)
    if msg isa Dict{Symbol,Any}
        haskey(msg, :method) || return nothing
        id = get(msg, :id, nothing)
    elseif isdefined(msg, :id) && isdefined(msg, :method)
        id = getfield(msg, :id)
    else
        return nothing
    end
    return valid_message_id(id)
end

function valid_message_id(@nospecialize id)
    @static if Int === Int32
        # JSON3 parses untyped integers as Int64 even on 32-bit Julia.
        if id isa Int64 && typemin(Int32) <= id <= typemax(Int32)
            id = Int32(id)
        end
    end
    return id isa String || id isa Int ? id : nothing
end

function is_sequential_msg(@nospecialize msg)
    return msg isa DidOpenTextDocumentNotification ||
           msg isa DidChangeTextDocumentNotification ||
           msg isa DidCloseTextDocumentNotification ||
           msg isa DidSaveTextDocumentNotification ||
           msg isa DidOpenNotebookDocumentNotification ||
           msg isa DidChangeNotebookDocumentNotification ||
           msg isa DidCloseNotebookDocumentNotification ||
           msg isa DidSaveNotebookDocumentNotification
end

function start_sequential_message_worker(server::Server)
    queue = Channel{Any}(Inf)
    task = Threads.@spawn :default while true
        msg = take!(queue)
        msg === nothing && break
        @tryinvokelatest handle_sequential_message(server, msg)
        GC.safepoint()
        isopen(queue) || break
    end
    return queue, task
end

function start_concurrent_message_worker(server::Server)
    queue = server.message_queue
    task = Threads.@spawn :default while true
        msg = take!(queue)
        msg === nothing && break
        @tryinvokelatest handler_concurrent_message(server, msg)
        GC.safepoint()
        isopen(queue) || break
    end
    return queue, task
end

function handle_sequential_message(server::Server, @nospecialize msg)
    if msg isa DidOpenTextDocumentNotification
        handle_DidOpenTextDocumentNotification(server, msg)
    elseif msg isa DidChangeTextDocumentNotification
        handle_DidChangeTextDocumentNotification(server, msg)
    elseif msg isa DidCloseTextDocumentNotification
        handle_DidCloseTextDocumentNotification(server, msg)
    elseif msg isa DidSaveTextDocumentNotification
        handle_DidSaveTextDocumentNotification(server, msg)
    elseif msg isa DidOpenNotebookDocumentNotification
        handle_DidOpenNotebookDocumentNotification(server, msg)
    elseif msg isa DidChangeNotebookDocumentNotification
        handle_DidChangeNotebookDocumentNotification(server, msg)
    elseif msg isa DidCloseNotebookDocumentNotification
        handle_DidCloseNotebookDocumentNotification(server, msg)
    elseif msg isa DidSaveNotebookDocumentNotification
        handle_DidSaveNotebookDocumentNotification(server, msg)
    else
        error(lazy"Unexpected sequential message: $(typeof(msg))")
    end
end

function handler_concurrent_message(server::Server, @nospecialize msg)
    # Handle `currently_handled` processing serially within the concurrent message worker thread
    if msg isa CancelRequestNotification
        if msg.params.id in server.state.handled_history
            return # Request was already handled, ignore cancellation
        end
        cancel!(get!(()->CancelFlag(true), server.state.currently_handled, msg.params.id))
        cancel_parked_workspace_diagnostic_request!(server, msg.params.id)
    elseif msg isa WorkDoneProgressCancelNotification
        if msg.params.token in server.state.handled_history
            return # Token was already handled, ignore cancellation
        end
        cancel!(get!(()->CancelFlag(true), server.state.currently_handled, msg.params.token))
    elseif msg isa HandledToken
        delete!(server.state.currently_handled, msg.id)
        push!(server.state.handled_history, msg.id) # Add to handled history to prevent dead IDs from accumulating
        # @info "Remaining requests" length(server.state.currently_handled) Base.summarysize(server.state.currently_handled)
        # @info "Handled history" length(server.state.handled_history) Base.summarysize(server.state.handled_history)
    elseif msg isa WorkspaceDiagnosticParkToken
        park_workspace_diagnostic_request!(server, msg.request)
    elseif msg isa WorkspaceDiagnosticWakeToken
        resume_parked_workspace_diagnostic_request!(server)
    elseif msg isa DiagnosticRegistrationUpdateToken
        update_diagnostic_registration!(server)
    # Handle regular messages concurrently
    elseif msg isa Dict{Symbol,Any} # ResponseMessage or untyped message
        id = valid_message_id(get(msg, :id, nothing))
        request_caller = id !== nothing ? poprequest!(server, id) : nothing
        if request_caller !== nothing
            # NOTE: The `get!` call to `server.state.currently_handled` MUST happen here
            # to avoid race conditions. Only after getting the flag can we spawn the actual dispatcher.
            token = cancellable_token(request_caller)
            let cancel_flag = isnothing(token) ? DUMMY_CANCEL_FLAG :
                    get!(()->CancelFlag(false), server.state.currently_handled, token)
                Threads.@spawn :default @tryinvokelatest handle_response_message(server, msg, request_caller, cancel_flag)
            end
        else
            method = get(msg, :method, nothing)
            @static if JETLS_DEV_MODE
                # Not a response to our request, or untyped message - log if in dev mode
                _id = something(method, Some(id))
                @warn "[handler_concurrent_message] Unhandled message" msg _id=_id maxlog=1
            end
            if method isa String && id !== nothing
                send(server, ResponseMessage(;
                    id,
                    result = nothing,
                    error = method_not_found_error(method)))
            end
        end
    elseif isdefined(msg, :id) && (id = valid_message_id(getfield(msg, :id)); id !== nothing)
        prepare_request_message!(server, msg)
        let cancel_flag = get!(()->CancelFlag(false), server.state.currently_handled, id)
            Threads.@spawn :default @tryinvokelatest handle_request_message(server, msg, id, cancel_flag)
        end
    else
        Threads.@spawn :default @tryinvokelatest handle_notification_message(server, msg)
    end
end

function handle_response_message(
        server::Server, msg::Dict{Symbol,Any}, @nospecialize(request_caller::RequestCaller),
        cancel_flag::CancelFlag
    )
    if request_caller isa InstantiationPromptProgressCaller
        handle_instantiation_prompt_progress_response(server, msg, request_caller)
    elseif request_caller isa InstantiationProgressCaller
        handle_instantiation_progress_response(server, request_caller)
    elseif request_caller isa InstantiationPromptCaller
        handle_instantiation_prompt_response(server, msg, request_caller)
    elseif request_caller isa AnalysisProgressCaller
        handle_analysis_progress_response(server, request_caller, cancel_flag)
    elseif request_caller isa ShowTextDocumentContentCaller
        handle_show_text_document_content_response(server, msg, request_caller)
    elseif request_caller isa SetDocumentContentCaller
        handle_apply_workspace_edit_response(server, msg, request_caller)
    elseif request_caller isa DeleteFileCaller
        handle_apply_workspace_edit_response(server, msg, request_caller)
    elseif request_caller isa TestRunnerMessageRequestCaller2
        handle_test_runner_message_response2(server, msg, request_caller)
    elseif request_caller isa TestRunnerMessageRequestCaller4
        handle_test_runner_message_response4(server, msg, request_caller)
    elseif request_caller isa TestRunnerTestsetProgressCaller
        handle_testrunner_testset_progress_response(server, msg, request_caller, cancel_flag)
    elseif request_caller isa TestRunnerTestcaseProgressCaller
        handle_testrunner_testcase_progress_response(server, msg, request_caller, cancel_flag)
    elseif request_caller isa CodeLensRefreshRequestCaller
        handle_code_lens_refresh_response(server, msg, request_caller)
    elseif request_caller isa DiagnosticRefreshRequestCaller
        handle_diagnostic_refresh_response(server, msg, request_caller)
    elseif request_caller isa TextDocumentContentRefreshCaller
        handle_text_document_content_refresh_response(server, msg, request_caller)
    elseif request_caller isa FormattingProgressCaller
        handle_formatting_progress_response(server, msg, request_caller, cancel_flag)
    elseif request_caller isa RangeFormattingProgressCaller
        handle_range_formatting_progress_response(server, msg, request_caller, cancel_flag)
    elseif request_caller isa RangesFormattingProgressCaller
        handle_ranges_formatting_progress_response(server, msg, request_caller, cancel_flag)
    elseif request_caller isa ReferencesProgressCaller
        handle_references_progress_response(server, msg, request_caller, cancel_flag)
    elseif request_caller isa RenameProgressCaller
        handle_rename_progress_response(server, msg, request_caller, cancel_flag)
    elseif request_caller isa WorkspaceSymbolProgressCaller
        handle_workspace_symbol_progress_response(server, msg, request_caller, cancel_flag)
    elseif request_caller isa ProfileProgressCaller
        handle_profile_progress_response(server, msg, request_caller)
    elseif request_caller isa WorkspaceConfigurationCaller
        handle_workspace_configuration_response(server, msg, request_caller)
    elseif request_caller isa RegisterCapabilityRequestCaller || request_caller isa UnregisterCapabilityRequestCaller
        # nothing to do
    else
        error(lazy"Unknown request caller type: $(typeof(request_caller))")
    end
    nothing
end

# Runs on the concurrent message worker right before a request is dispatched, for
# bookkeeping that has to stay serialized with the worker's other state updates.
function prepare_request_message!(server::Server, @nospecialize(msg))
    if msg isa WorkspaceDiagnosticRequest
        begin_workspace_diagnostic_request!(server, msg)
    end
    nothing
end

function handle_request_message(
        server::Server, @nospecialize(msg), id::MessageId, cancel_flag::CancelFlag
    )
    if is_cancelled(cancel_flag)
        send(server,
            ResponseMessage(;
                id,
                result = nothing,
                error = request_cancelled_error()))
    elseif msg isa CompletionRequest
        handle_CompletionRequest(server, msg, cancel_flag)
    elseif msg isa CompletionResolveRequest
        handle_CompletionResolveRequest(server, msg)
    elseif msg isa SignatureHelpRequest
        handle_SignatureHelpRequest(server, msg, cancel_flag)
    elseif msg isa DeclarationRequest
        handle_DeclarationRequest(server, msg, cancel_flag)
    elseif msg isa DefinitionRequest
        handle_DefinitionRequest(server, msg, cancel_flag)
    elseif msg isa TypeDefinitionRequest
        handle_TypeDefinitionRequest(server, msg, cancel_flag)
    elseif msg isa ReferencesRequest
        handle_ReferencesRequest(server, msg, cancel_flag)
    elseif msg isa HoverRequest
        handle_HoverRequest(server, msg, cancel_flag)
    elseif msg isa DocumentHighlightRequest
        handle_DocumentHighlightRequest(server, msg, cancel_flag)
    elseif msg isa DocumentSymbolRequest
        handle_DocumentSymbolRequest(server, msg, cancel_flag)
    elseif msg isa WorkspaceSymbolRequest
        handle_WorkspaceSymbolRequest(server, msg, cancel_flag)
    elseif msg isa DocumentDiagnosticRequest
        handle_DocumentDiagnosticRequest(server, msg, cancel_flag)
    elseif msg isa WorkspaceDiagnosticRequest
        handle_WorkspaceDiagnosticRequest(server, msg, cancel_flag)
    elseif msg isa CodeLensRequest
        handle_CodeLensRequest(server, msg, cancel_flag)
    elseif msg isa CodeLensResolveRequest
        handle_CodeLensResolveRequest(server, msg, cancel_flag)
    elseif msg isa DocumentLinkRequest
        handle_DocumentLinkRequest(server, msg, cancel_flag)
    elseif msg isa CodeActionRequest
        handle_CodeActionRequest(server, msg, cancel_flag)
    elseif msg isa InlayHintRequest
        handle_InlayHintRequest(server, msg, cancel_flag)
    elseif msg isa InlayHintResolveRequest
        handle_InlayHintResolveRequest(server, msg, cancel_flag)
    elseif msg isa SemanticTokensFullRequest
        handle_SemanticTokensFullRequest(server, msg, cancel_flag)
    elseif msg isa SemanticTokensRangeRequest
        handle_SemanticTokensRangeRequest(server, msg, cancel_flag)
    elseif msg isa DocumentFormattingRequest
        handle_DocumentFormattingRequest(server, msg, cancel_flag)
    elseif msg isa DocumentRangeFormattingRequest
        handle_DocumentRangeFormattingRequest(server, msg, cancel_flag)
    elseif msg isa DocumentRangesFormattingRequest
        handle_DocumentRangesFormattingRequest(server, msg, cancel_flag)
    elseif msg isa RenameRequest
        handle_RenameRequest(server, msg, cancel_flag)
    elseif msg isa PrepareRenameRequest
        handle_PrepareRenameRequest(server, msg, cancel_flag)
    elseif msg isa ExecuteCommandRequest
        handle_ExecuteCommandRequest(server, msg)
    elseif msg isa TextDocumentContentRequest
        handle_TextDocumentContentRequest(server, msg)
    else
        method = isdefined(msg, :method) ? getfield(msg, :method) : nothing
        @static if JETLS_DEV_MODE
            _id = something(method, typeof(msg))
            @warn "[handle_request_message] Unhandled message" msg _id=_id maxlog=1
        end
        if method isa String
            send(server, ResponseMessage(;
                id,
                result = nothing,
                error = method_not_found_error(method)))
        end
    end
    nothing
end

function handle_notification_message(server::Server, @nospecialize msg)
    if msg isa DidChangeWatchedFilesNotification
        handle_DidChangeWatchedFilesNotification(server, msg)
    elseif msg isa DidChangeConfigurationNotification
        handle_DidChangeConfigurationNotification(server, msg)
    else
        @static if JETLS_DEV_MODE
            method = isdefined(msg, :method) ? getfield(msg, :method) : nothing
            _id = something(method, typeof(msg))
            @warn "[handle_notification_message] Unhandled message" msg _id=_id maxlog=1
        end
    end
    nothing
end

include("app/app.jl")
include("app/cli-check.jl")
include("app/cli-schema.jl")
include("app/cli-serve.jl")

include("precompile.jl")

end # module JETLS
