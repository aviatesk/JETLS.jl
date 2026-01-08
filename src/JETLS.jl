module JETLS

export Server, Endpoint, runserver

const JETLS_VERSION = let
    version_file = joinpath(dirname(@__DIR__), "JETLS_VERSION")
    isfile(version_file) ? strip(read(version_file, String)) : "unknown"
end

const __init__hooks__ = Any[]
push_init_hooks!(hook) = push!(__init__hooks__, hook)
function __init__()
    foreach(hook->hook(), __init__hooks__)
end

using Preferences: Preferences
const JETLS_DEV_MODE = Preferences.@load_preference("JETLS_DEV_MODE", false)
const JETLS_TEST_MODE = Preferences.@load_preference("JETLS_TEST_MODE", false)
const JETLS_DEBUG_LOWERING = Preferences.@load_preference("JETLS_DEBUG_LOWERING", false)
function show_setup_info(msg)
    @info msg Sys.BINDIR pkgdir(JETLS) Threads.nthreads() JETLS_VERSION JETLS_DEV_MODE JETLS_TEST_MODE JETLS_DEBUG_LOWERING
end

if JETLS_DEV_MODE
    using Revise: Revise
else
    const Revise = nothing
end

using LSP
using LSP: LSP
using LSP.URIs2
using LSP.Communication: Endpoint

const MessageId = Union{String, Int}

using Pkg
using JET: CC, JET
using JuliaSyntax: JuliaSyntax as JS
using JuliaLowering: JuliaLowering as JL
using REPL: REPL # loading REPL is necessary to make `Base.Docs.doc(::Base.Docs.Binding)` work
using Markdown: Markdown
using TOML: TOML

using Configurations: @option, Configurations, Maybe
using Glob: Glob

abstract type AnalysisEntry end # used by `Analyzer.LSAnalyzer`

include("AtomicContainers/AtomicContainers.jl")
using .AtomicContainers
const SWStats  = JETLS_DEV_MODE ? AtomicContainers.SWStats : Nothing
const LWStats  = JETLS_DEV_MODE ? AtomicContainers.LWStats : Nothing
const CASStats = JETLS_DEV_MODE ? AtomicContainers.CASStats : Nothing

include("analysis/Analyzer.jl")
using .Analyzer

# define fallback constructors for LSAnalyzer
Analyzer.LSAnalyzer(uri::URI, args...; kwargs...) = LSAnalyzer(ScriptAnalysisEntry(uri), args...; kwargs...)
Analyzer.LSAnalyzer(args...; kwargs...) = LSAnalyzer(ScriptAnalysisEntry(filepath2uri(@__FILE__)), args...; kwargs...)

include("analysis/resolver.jl")

include("FixedSizeFIFOQueue/FixedSizeFIFOQueue.jl")

include("utils/general.jl")

include("testrunner/testrunner-types.jl")
include("types.jl")

include("utils/jl-syntax-macros.jl")
include("utils/string.jl")
include("utils/path.jl")
include("utils/pkg.jl")
include("utils/ast.jl")
include("utils/binding.jl")
include("utils/lsp.jl")
include("utils/server.jl")

include("init-options.jl")
include("config.jl")
include("workspace-configuration.jl")

include("diagnostic.jl")

include("analysis/Interpreter.jl")
using .Interpreter

include("document-synchronization.jl")
include("notebook.jl")
include("analysis/full-analysis.jl")
include("registration.jl")
include("apply-edit.jl")
include("execute-command.jl")
include("signature-help.jl")
include("completions.jl")
include("definition.jl")
include("references.jl")
include("hover.jl")
include("document-highlight.jl")
include("code-action.jl")
include("code-lens.jl")
include("formatting.jl")
include("inlay-hint.jl")
include("rename.jl")
include("testrunner/testrunner.jl")
include("profile.jl")
include("did-change-watched-files.jl")
include("initialize.jl")

"""
    runserver([callback,] in::IO, out::IO; client_process_id=nothing)
        -> (; exit_code::Int, endpoint::Endpoint)
    runserver([callback,] endpoint::Endpoint; client_process_id=nothing)
        -> (; exit_code::Int, endpoint::Endpoint)
    runserver([callback,] server::Server; client_process_id=nothing)
        -> (; exit_code::Int, endpoint::Endpoint)

Run the JETLS language server with the specified input/output streams or endpoint.

The `callback` function is invoked on each message sent or received, with the
signature `callback(event::Symbol, msg)` where `event` is either `:sent` or
`:received`. If not specified, a no-op callback is used.

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

runserver(args...; kwargs...) = runserver(Returns(nothing), args...; kwargs...) # no callback specified
runserver(callback, in::IO, out::IO; kwargs...) = runserver(callback, Endpoint(in, out); kwargs...)
runserver(callback, endpoint::Endpoint; kwargs...) = runserver(Server(callback, endpoint); kwargs...)
function runserver(server::Server; client_process_id::Union{Nothing,Int}=nothing)
    initialize_requested = shutdown_requested = false
    local exit_code::Int = 1
    JETLS_DEV_MODE && @info "Running JETLS server loop"
    seq_queue = start_sequential_message_worker(server)
    con_queue = start_concurrent_message_worker(server)
    if !isnothing(client_process_id)
        JETLS_DEV_MODE && @info "Monitoring client process ID" client_process_id
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
                handle_InitializeRequest(server, msg; client_process_id)
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
            # Handle messages received before initialization (LSP 3.17 spec):
            # - For requests: respond with error code -32002 (ServerNotInitialized)
            # - For notifications: drop silently (exit already handled above)
            elseif !initialize_requested
                if isdefined(msg, :id)
                    send(server, ResponseMessage(;
                        id = msg.id,
                        error = ResponseError(;
                            code = ErrorCodes.ServerNotInitialized,
                            message = "Server has not been initialized")))
                end
            elseif shutdown_requested
                if isdefined(msg, :id)
                    send(server, ResponseMessage(;
                        id = msg.id,
                        error = ResponseError(;
                            code = ErrorCodes.InvalidRequest,
                            message = "Received request after a shutdown request requested")))
                else
                    # This is the case where some notification was sent.
                    # In this case, there is no way to inform the client side that it was unexpected.
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
        close(seq_queue); close(con_queue); close(server.endpoint)
    end
    JETLS_DEV_MODE && @info "Exited JETLS server loop"
    return exit_code
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
    Threads.@spawn :default while true
        msg = take!(queue)
        @tryinvokelatest handle_sequential_message(server, msg)
        GC.safepoint()
        isopen(queue) || break
    end
    return queue
end

function start_concurrent_message_worker(server::Server)
    queue = Channel{Any}(Inf)
    Threads.@spawn :default while true
        msg = take!(queue)
        handler_concurrent_message = ConcurrentMessageHandler(queue)
        @tryinvokelatest handler_concurrent_message(server, msg)
        GC.safepoint()
        isopen(queue) || break
    end
    return queue
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
    elseif JETLS_DEV_MODE
        if isdefined(msg, :method)
            _id = getfield(msg, :method)
        else
            _id = typeof(msg)
        end
        @warn "[handle_sequential_message] Unhandled message" msg _id=_id maxlog=1
    end
end

struct ConcurrentMessageHandler
    queue::Channel{Any}
end
struct HandledToken
    id::MessageId
end
function (dispatcher::ConcurrentMessageHandler)(server::Server, @nospecialize msg)
    # Handle `currently_handled` processing serially within the concurrent message worker thread
    if msg isa CancelRequestNotification
        if msg.params.id in server.state.handled_history
            return # Request was already handled, ignore cancellation
        end
        cancel!(get!(()->CancelFlag(true), server.state.currently_handled, msg.params.id))
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
    # Handle regular messages concurrently
    elseif msg isa Dict{Symbol,Any} # ResponseMessage or untyped message
        request_caller = let id = get(msg, :id, nothing)
            id !== nothing ? poprequest!(server, id) : nothing
        end
        if request_caller !== nothing
            # NOTE: The `get!` call to `server.state.currently_handled` MUST happen here
            # to avoid race conditions. Only after getting the flag can we spawn the actual dispatcher.
            token = cancellable_token(request_caller)
            cancel_flag = isnothing(token) ? DUMMY_CANCEL_FLAG :
                get!(()->CancelFlag(false), server.state.currently_handled, token)
            handle_response_message = ResponseMessageDispatcher(dispatcher.queue, token, cancel_flag, request_caller)
            Threads.@spawn :default @tryinvokelatest handle_response_message(server, msg)
        elseif JETLS_DEV_MODE
            # Not a response to our request, or untyped message - log if in dev mode
            _id = get(()->get(msg, :id, nothing), msg, :method)
            @warn "[ConcurrentMessageHandler] Unhandled message" msg _id=_id maxlog=1
        end
    elseif isdefined(msg, :id) && (id = msg.id; id isa String || id isa Int)
        cancel_flag = get!(()->CancelFlag(false), server.state.currently_handled, id)
        handle_request_message = RequestMessageDispatcher(dispatcher.queue, id, cancel_flag)
        Threads.@spawn :default @tryinvokelatest handle_request_message(server, msg)
    else
        Threads.@spawn :default @tryinvokelatest handle_notification_message(server, msg)
    end
end

struct ResponseMessageDispatcher
    queue::Channel{Any}
    token::Union{Nothing,ProgressToken}
    cancel_flag::CancelFlag
    request_caller::RequestCaller
end
function (dispatcher::ResponseMessageDispatcher)(server::Server, msg::Dict{Symbol,Any})
    (; cancel_flag, request_caller) = dispatcher
    if request_caller isa InstantiationProgressCaller
        handle_instantiation_progress_response(server, request_caller)
    elseif request_caller isa AnalysisProgressCaller
        handle_analysis_progress_response(server, request_caller, cancel_flag)
    elseif request_caller isa ShowDocumentRequestCaller
        handle_show_document_response(server, msg, request_caller)
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
    elseif request_caller isa FormattingProgressCaller
        handle_formatting_progress_response(server, msg, request_caller)
    elseif request_caller isa RangeFormattingProgressCaller
        handle_range_formatting_progress_response(server, msg, request_caller)
    elseif request_caller isa ReferencesProgressCaller
        handle_references_progress_response(server, msg, request_caller)
    elseif request_caller isa RenameProgressCaller
        handle_rename_progress_response(server, msg, request_caller)
    elseif request_caller isa ProfileProgressCaller
        handle_profile_progress_response(server, msg, request_caller)
    elseif request_caller isa WorkspaceConfigurationCaller
        handle_workspace_configuration_response(server, msg, request_caller)
    elseif request_caller isa RegisterCapabilityRequestCaller || request_caller isa UnregisterCapabilityRequestCaller
        # nothing to do
    else
        error("Unknown request caller type")
    end
    id = dispatcher.token
    isnothing(id) || put!(dispatcher.queue, HandledToken(id))
    nothing
end

struct RequestMessageDispatcher
    queue::Channel{Any}
    id::MessageId
    cancel_flag::CancelFlag
end
function (dispatcher::RequestMessageDispatcher)(server::Server, @nospecialize msg)
    (; queue, id, cancel_flag) = dispatcher
    if is_cancelled(cancel_flag)
        send(server,
            ResponseMessage(;
                id = msg.id,
                result = nothing,
                error = request_cancelled_error()))
    elseif msg isa CompletionRequest
        handle_CompletionRequest(server, msg, cancel_flag)
    elseif msg isa CompletionResolveRequest
        handle_CompletionResolveRequest(server, msg)
    elseif msg isa SignatureHelpRequest
        handle_SignatureHelpRequest(server, msg, cancel_flag)
    elseif msg isa DefinitionRequest
        handle_DefinitionRequest(server, msg, cancel_flag)
    elseif msg isa ReferencesRequest
        handle_ReferencesRequest(server, msg, cancel_flag)
    elseif msg isa HoverRequest
        handle_HoverRequest(server, msg, cancel_flag)
    elseif msg isa DocumentHighlightRequest
        handle_DocumentHighlightRequest(server, msg, cancel_flag)
    elseif msg isa DocumentDiagnosticRequest
        handle_DocumentDiagnosticRequest(server, msg, cancel_flag)
    elseif msg isa WorkspaceDiagnosticRequest
        @assert false "workspace/diagnostic should not be enabled"
    elseif msg isa CodeLensRequest
        handle_CodeLensRequest(server, msg, cancel_flag)
    elseif msg isa CodeActionRequest
        handle_CodeActionRequest(server, msg, cancel_flag)
    elseif msg isa ExecuteCommandRequest
        handle_ExecuteCommandRequest(server, msg)
    elseif msg isa InlayHintRequest
        handle_InlayHintRequest(server, msg, cancel_flag)
    elseif msg isa DocumentFormattingRequest
        handle_DocumentFormattingRequest(server, msg, cancel_flag)
    elseif msg isa DocumentRangeFormattingRequest
        handle_DocumentRangeFormattingRequest(server, msg, cancel_flag)
    elseif msg isa RenameRequest
        handle_RenameRequest(server, msg, cancel_flag)
    elseif msg isa PrepareRenameRequest
        handle_PrepareRenameRequest(server, msg, cancel_flag)
    elseif JETLS_DEV_MODE
        if isdefined(msg, :method)
            _id = getfield(msg, :method)
        else
            _id = typeof(msg)
        end
        @warn "[RequestMessageDispatcher] Unhandled message" msg _id=_id maxlog=1
    end
    put!(queue, HandledToken(id))
    nothing
end

function handle_notification_message(server::Server, @nospecialize msg)
    if msg isa DidChangeWatchedFilesNotification
        handle_DidChangeWatchedFilesNotification(server, msg)
    elseif msg isa DidChangeConfigurationNotification
        handle_DidChangeConfigurationNotification(server, msg)
    elseif JETLS_DEV_MODE
        if isdefined(msg, :method)
            _id = getfield(msg, :method)
        else
            _id = typeof(msg)
        end
        @warn "[handle_notification_message] Unhandled message" msg _id=_id maxlog=1
    end
    nothing
end

include("app.jl")

include("precompile.jl")

end # module JETLS
