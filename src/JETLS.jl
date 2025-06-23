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

include("JSONRPC/JSONRPC.jl")
using .JSONRPC

using Pkg
using JET: CC, JET
using JuliaSyntax: JuliaSyntax as JS
using JuliaLowering: JuliaLowering as JL
using REPL: REPL # loading REPL is necessary to make `Base.Docs.doc(::Base.Docs.Binding)` work

abstract type AnalysisEntry end # used by `Analyzer.LSAnalyzer`

include("analysis/Analyzer.jl")
using .Analyzer

# define fallback constructors for LSAnalyzer
Analyzer.LSAnalyzer(uri::URI, args...; kwargs...) = LSAnalyzer(ScriptAnalysisEntry(uri), args...; kwargs...)
Analyzer.LSAnalyzer(args...; kwargs...) = LSAnalyzer(ScriptAnalysisEntry(filepath2uri(@__FILE__)), args...; kwargs...)

include("analysis/resolver.jl")

include("types.jl")

include("utils/general.jl")
include("utils/path.jl")
include("utils/pkg.jl")
include("utils/ast.jl")
include("utils/binding.jl")
include("utils/lsp.jl")
include("utils/server.jl")

include("analysis/Interpreter.jl")
using .Interpreter

include("document-synchronization.jl")
include("analysis/full-analysis.jl")
include("response.jl")
include("registration.jl")
include("completions.jl")
include("signature-help.jl")
include("definition.jl")
include("hover.jl")
include("diagnostics.jl")
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
runserver(callback, in::IO, out::IO) = runserver(callback, Endpoint(in, out))
runserver(callback, endpoint::Endpoint) = runserver(Server(callback, endpoint))
function runserver(server::Server)
    shutdown_requested = false
    local exit_code::Int = 1
    JETLS_DEV_MODE && @info "Running JETLS server loop"
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
    JETLS_DEV_MODE && @info "Exited JETLS server loop"
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
    elseif msg isa CompletionRequest
        return handle_CompletionRequest(server, msg)
    elseif msg isa CompletionResolveRequest
        return handle_CompletionResolveRequest(server, msg)
    elseif msg isa SignatureHelpRequest
        return handle_SignatureHelpRequest(server, msg)
    elseif msg isa DefinitionRequest
        return handle_DefinitionRequest(server, msg)
    elseif msg isa HoverRequest
        return handle_HoverRequest(server, msg)
    elseif msg isa DocumentDiagnosticRequest
        return handle_DocumentDiagnosticRequest(server, msg)
    elseif msg isa WorkspaceDiagnosticRequest
        @assert false "workspace/diagnostic should not be enabled"
    elseif msg isa Dict{Symbol,Any} # response message
        if handle_ResponseMessage(server, msg)
            return nothing
        end
        # some `ResponseMessage` may be unhandled, log it for reference
    end
    if JETLS_DEV_MODE
        if isdefined(msg, :method)
            id = getfield(msg, :method)
        elseif msg isa Dict{Symbol,Any} # unhandled `ResponseMessage`
            id = get(()->get(msg, :id, nothing), msg, :method)
        else
            id = typeof(msg)
        end
        @warn "Unhandled message" msg _id=id maxlog=1
    end
    nothing
end

include("precompile.jl")

end # module JETLS
