module JETLS

export Server, LSEndpoint, runserver

const __init__hooks__ = Any[]
push_init_hooks!(hook) = push!(__init__hooks__, hook)
function __init__()
    foreach(hook->hook(), __init__hooks__)
end

using Preferences: Preferences
const JETLS_DEV_MODE = Preferences.@load_preference("JETLS_DEV_MODE", false)
const JETLS_TEST_MODE = Preferences.@load_preference("JETLS_TEST_MODE", false)
const JETLS_DEBUG_LOWERING = Preferences.@load_preference("JETLS_DEBUG_LOWERING", false)
push_init_hooks!() do
    @info "Running JETLS with" JETLS_DEV_MODE JETLS_TEST_MODE JETLS_DEBUG_LOWERING Threads.nthreads()
end

using LSP
using LSP.URIs2

using JSONRPC: JSONRPC, Endpoint
# constructor of `Endpoint` with LSP method dispatcher
LSEndpoint(args...) = Endpoint(args..., method_dispatcher)

using Pkg
using JET: CC, JET
using JuliaSyntax: JuliaSyntax as JS
using JuliaLowering: JuliaLowering as JL
using REPL: REPL # loading REPL is necessary to make `Base.Docs.doc(::Base.Docs.Binding)` work
using Markdown: Markdown
using TOML: TOML

abstract type AnalysisEntry end # used by `Analyzer.LSAnalyzer`

include("analysis/Analyzer.jl")
using .Analyzer

# define fallback constructors for LSAnalyzer
Analyzer.LSAnalyzer(uri::URI, args...; kwargs...) = LSAnalyzer(ScriptAnalysisEntry(uri), args...; kwargs...)
Analyzer.LSAnalyzer(args...; kwargs...) = LSAnalyzer(ScriptAnalysisEntry(filepath2uri(@__FILE__)), args...; kwargs...)

include("analysis/resolver.jl")

include("AtomicContainers/AtomicContainers.jl")
using .AtomicContainers
const SWStats  = JETLS_DEV_MODE ? AtomicContainers.SWStats : Nothing
const LWStats  = JETLS_DEV_MODE ? AtomicContainers.LWStats : Nothing
const CASStats = JETLS_DEV_MODE ? AtomicContainers.CASStats : Nothing

include("testrunner/testrunner-types.jl")
include("types.jl")

include("utils/jl_syntax_macros.jl")
include("utils/general.jl")
include("utils/string.jl")
include("utils/path.jl")
include("utils/pkg.jl")
include("utils/ast.jl")
include("utils/binding.jl")
include("utils/lsp.jl")
include("utils/server.jl")

include("config.jl")

include("analysis/Interpreter.jl")
using .Interpreter

include("document-synchronization.jl")
include("analysis/full-analysis.jl")
include("registration.jl")
include("apply-edit.jl")
include("execute-command.jl")
include("completions.jl")
include("signature-help.jl")
include("definition.jl")
include("hover.jl")
include("document-highlight.jl")
include("diagnostics.jl")
include("code-action.jl")
include("code-lens.jl")
include("formatting.jl")
include("inlay-hint.jl")
include("rename.jl")
include("testrunner/testrunner.jl")
include("did-change-watched-files.jl")
include("response.jl")
include("lifecycle.jl")

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

runserver(args...) = runserver(Returns(nothing), args...) # no callback specified
runserver(callback, in::IO, out::IO) = runserver(callback, LSEndpoint(in, out))
runserver(callback, endpoint::Endpoint) = runserver(Server(callback, endpoint))
function runserver(server::Server)
    shutdown_requested = false
    local exit_code::Int = 1
    JETLS_DEV_MODE && @info "Running JETLS server loop"
    seq_queue = start_sequential_message_worker(server)
    con_queue = start_concurrent_message_worker(server)
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
                    error = ResponseError(;
                        code = ErrorCodes.InvalidRequest,
                        message = "Received request after a shutdown request requested")))
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
        close(server.endpoint)
    end
    JETLS_DEV_MODE && @info "Exited JETLS server loop"
    return (; exit_code, server.endpoint)
end

function is_sequential_msg(@nospecialize msg)
    return msg isa DidOpenTextDocumentNotification ||
           msg isa DidChangeTextDocumentNotification ||
           msg isa DidCloseTextDocumentNotification ||
           msg isa DidSaveTextDocumentNotification
end

function start_sequential_message_worker(server::Server)
    queue = Channel{Any}(Inf)
    Threads.@spawn :default while true
        msg = take!(queue)
        handle_message(SequentialMessageHandler(), server, msg)
        GC.safepoint()
    end
    return queue
end

function start_concurrent_message_worker(server::Server)
    queue = Channel{Any}(Inf)
    Threads.@spawn :default while true
        msg = take!(queue)
        handle_message(ConcurrentMessageHandler(queue), server, msg)
        GC.safepoint()
    end
    return queue
end

abstract type MessageHandler end

function handle_message(handler::MessageHandler, server::Server, @nospecialize msg)
    if !JETLS_TEST_MODE
        try
            if JETLS_DEV_MODE
                # `@invokelatest` for allowing changes maded by Revise to be reflected without
                # terminating the `runserver` loop
                return @invokelatest handler(server, msg)
            else
                return handler(server, msg)
            end
        catch err
            @error "Message handling failed for" typeof(handler) typeof(msg)
            Base.display_error(stderr, err, catch_backtrace())
            return nothing
        end
    else
        if JETLS_DEV_MODE
            # `@invokelatest` for allowing changes maded by Revise to be reflected without
            # terminating the `runserver` loop
            return @invokelatest handler(server, msg)
        else
            return handler(server, msg)
        end
    end
end

struct SequentialMessageHandler <: MessageHandler end
function (::SequentialMessageHandler)(server::Server, @nospecialize msg)
    if msg isa DidOpenTextDocumentNotification
        handle_DidOpenTextDocumentNotification(server, msg)
    elseif msg isa DidChangeTextDocumentNotification
        handle_DidChangeTextDocumentNotification(server, msg)
    elseif msg isa DidCloseTextDocumentNotification
        handle_DidCloseTextDocumentNotification(server, msg)
    elseif msg isa DidSaveTextDocumentNotification
        handle_DidSaveTextDocumentNotification(server, msg)
    else error(lazy"Unexpected sequential message type $(typeof(msg))") end
end

struct ConcurrentMessageHandler <: MessageHandler
    queue::Channel{Any}
end
struct HandledId
    id::Union{String, Int}
end
function (handler::ConcurrentMessageHandler)(server::Server, @nospecialize msg)
    # Handle `currently_handled` processing serially within the concurrent message worker thread
    if msg isa CancelRequestNotification
        cancel!(get!(()->CancelFlag(true), server.state.currently_handled, msg.params.id))
    elseif msg isa HandledId
        delete!(server.state.currently_handled, msg.id)
    # Handle regular messages concurrently
    elseif msg isa Dict{Symbol,Any} # ResponseMessage or untyped message
        id = get(msg, :id, nothing)
        cancel_flag = isnothing(id) ? nothing : get!(()->CancelFlag(false), server.state.currently_handled, id)
        Threads.@spawn :default handle_message(ResponseMessageHandler(handler.queue, id, cancel_flag), server, msg)
    elseif isdefined(msg, :id) && (id = msg.id; id isa String || id isa Int)
        cancel_flag = get!(()->CancelFlag(false), server.state.currently_handled, id)
        Threads.@spawn :default handle_message(RequestMessageHandler(handler.queue, id, cancel_flag), server, msg)
    else
        Threads.@spawn :default handle_message(NotificationMessageHandler(), server, msg)
    end
end

struct ResponseMessageHandler <: MessageHandler
    queue::Channel{Any}
    id::Union{String, Int, Nothing}
    cancel_flag::CancelFlag
end
function (handler::ResponseMessageHandler)(server::Server, msg::Dict{Symbol,Any})
    (; queue, id, cancel_flag) = handler
    if handle_ResponseMessage(server, msg) # TODO Use `cancel_flag`
    elseif JETLS_DEV_MODE
        # Log unhandled `ResponseMessage` or untyped message for reference
        _id = get(()->get(msg, :id, nothing), msg, :method)
        @warn "[ResponseMessageHandler] Unhandled message" msg _id=_id maxlog=1
    end
    isnothing(id) || put!(queue, HandledId(id))
    nothing
end

struct RequestMessageHandler <: MessageHandler
    queue::Channel{Any}
    id::Union{String, Int}
    cancel_flag::CancelFlag
end
function (handler::RequestMessageHandler)(server::Server, @nospecialize msg)
    (; queue, id, cancel_flag) = handler
    if msg isa CompletionRequest
        handle_CompletionRequest(server, msg, cancel_flag)
    elseif msg isa CompletionResolveRequest
        handle_CompletionResolveRequest(server, msg, cancel_flag)
    elseif msg isa SignatureHelpRequest
        handle_SignatureHelpRequest(server, msg, cancel_flag)
    elseif msg isa DefinitionRequest
        handle_DefinitionRequest(server, msg, cancel_flag)
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
        handle_ExecuteCommandRequest(server, msg, cancel_flag)
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
        @warn "[RequestMessageHandler] Unhandled message" msg _id=_id maxlog=1
    end
    put!(queue, HandledId(id))
    nothing
end

struct NotificationMessageHandler <: MessageHandler end
function (::NotificationMessageHandler)(server::Server, @nospecialize msg)
    if msg isa DidChangeWatchedFilesNotification
        handle_DidChangeWatchedFilesNotification(server, msg)
    elseif JETLS_DEV_MODE
        if isdefined(msg, :method)
            _id = getfield(msg, :method)
        else
            _id = typeof(msg)
        end
        @warn "[NotificationMessageHandler] Unhandled message" msg _id=_id maxlog=1
    end
    nothing
end

include("precompile.jl")

end # module JETLS
