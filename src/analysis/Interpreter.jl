module Interpreter

export LSInterpreter

using JuliaSyntax: JuliaSyntax as JS
using JET: CC, JET
using ..JETLS:
    AnalysisRequest, AnalysisResult, SavedFileInfo, Server, JETLS, JETLS_DEV_MODE,
    is_cancelled, send_progress, yield_to_endpoint
using ..JETLS.URIs2
using ..JETLS.LSP
using ..JETLS.Analyzer

mutable struct Counter
    count::Int
end
Counter() = Counter(0)
increment!(counter::Counter) = counter.count += 1
Base.getindex(counter::Counter) = counter.count

struct LSInterpreter{S<:Server} <: JET.ConcreteInterpreter
    server::S
    request::AnalysisRequest
    analyzer::LSAnalyzer
    counter::Counter
    activation_done::Union{Nothing,Base.Event}
    state::JET.InterpretationState
    function LSInterpreter(
            server::S, request::AnalysisRequest, analyzer::LSAnalyzer, counter::Counter,
            activation_done::Union{Nothing,Base.Event}
        ) where S<:Server
        return new{S}(server, request, analyzer, counter, activation_done)
    end
    function LSInterpreter(
            server::S, request::AnalysisRequest, analyzer::LSAnalyzer, counter::Counter,
            activation_done::Union{Nothing,Base.Event}, state::JET.InterpretationState
        ) where S<:Server
        return new{S}(server, request, analyzer, counter, activation_done, state)
    end
end

# The main constructor
function LSInterpreter(
        server::Server, request::AnalysisRequest;
        activation_done::Union{Nothing,Base.Event} = nothing
    )
    return LSInterpreter(server, request, LSAnalyzer(request.entry), Counter(), activation_done)
end

# `JET.ConcreteInterpreter` interface
JET.InterpretationState(interp::LSInterpreter) = interp.state
function JET.ConcreteInterpreter(interp::LSInterpreter, state::JET.InterpretationState)
    # add `state` to `interp`, and update `interp.analyzer.cache`
    initialize_cache!(interp.analyzer, state.res.analyzed_files)
    return LSInterpreter(
        interp.server, interp.request, interp.analyzer, interp.counter,
        interp.activation_done, state)
end
JET.ToplevelAbstractAnalyzer(interp::LSInterpreter) = interp.analyzer

# overloads
# =========

mutable struct SignatureAnalysisProgress
    const reports::Vector{JET.InferenceErrorReport}
    const reports_lock::ReentrantLock
    @atomic done::Int
    const interval::Int
    @atomic next_interval::Int
    function SignatureAnalysisProgress(n_sigs::Int)
        interval = max(n_sigs ÷ 25, 1)
        new(JET.InferenceErrorReport[], ReentrantLock(), 0, interval, interval)
    end
end

function compute_percentage(count, total, max=100)
    return min(round(Int, (count / total) * max), max)
end

function cache_intermediate_analysis_result!(interp::LSInterpreter)
    result = JET.JETToplevelResult(interp.analyzer, interp.state.res, "LSInterpreter (intermediate result)", ())
    intermediate_result = JETLS.new_analysis_result(interp.request, result)
    JETLS.update_analysis_cache!(interp.server.state.analysis_manager, intermediate_result)
end

function JET.analyze_from_definitions!(interp::LSInterpreter, config::JET.ToplevelConfig)
    activation_done = interp.activation_done
    if activation_done !== nothing
        # The phase that requires code loading has finished, so this environment is no
        # longer needed, so let's release the `ACTIVATION_LOCK`
        notify(activation_done)
    end

    # Cache intermediate analysis results after file analysis completes
    # This makes module context information available immediately for LS features
    cache_intermediate_analysis_result!(interp)

    entrypoint = config.analyze_from_definitions
    res = JET.InterpretationState(interp).res
    n_sigs = length(res.toplevel_signatures)
    n_sigs == 0 && return
    cancellable_token = interp.request.cancellable_token
    if cancellable_token !== nothing
        if is_cancelled(cancellable_token.cancel_flag)
            return
        end
        send_progress(interp.server, cancellable_token.token,
            WorkDoneProgressReport(;
                cancellable = true,
                message = "0 / $n_sigs [signature analysis]",
                percentage = 50))
        yield_to_endpoint()
    end

    progress = SignatureAnalysisProgress(n_sigs)

    tasks = map(1:n_sigs) do i
        Threads.@spawn :default try
            if cancellable_token !== nothing && is_cancelled(cancellable_token.cancel_flag)
                return
            end
            tt = res.toplevel_signatures[i]
            # Create a new analyzer with fresh local caches (`inf_cache` and `analysis_results`)
            # to avoid data races between concurrent signature analysis tasks
            analyzer = JET.ToplevelAbstractAnalyzer(interp, JET.non_toplevel_concretized;
                refresh_local_cache = true)
            match = Base._which(tt;
                # NOTE use the latest world counter with `method_table(analyzer)` unwrapped,
                # otherwise it may use a world counter when this method isn't defined yet
                method_table = CC.method_table(analyzer),
                world = CC.get_inference_world(analyzer),
                raise = false)
            if (match !== nothing &&
                (!(entrypoint isa Symbol) || # implies `analyze_from_definitions===true`
                 match.method.name === entrypoint))
                analyzer, result = JET.analyze_method_signature!(analyzer,
                    match.method, match.spec_types, match.sparams)
                reports = JET.get_reports(analyzer, result)
                isempty(reports) || @lock progress.reports_lock append!(progress.reports, reports)
            else
                JETLS_DEV_MODE && @warn "Couldn't find a single method matching the signature" tt
            end
            done = (@atomic progress.done += 1)
            if cancellable_token !== nothing
                current_next = @atomic progress.next_interval
                if done >= current_next
                    # Try to update next_interval (may race with other tasks)
                    @atomicreplace progress.next_interval current_next => current_next + progress.interval
                    percentage = compute_percentage(done, n_sigs, 50) + 50
                    send_progress(interp.server, cancellable_token.token,
                        WorkDoneProgressReport(;
                            cancellable = true,
                            message = "$done / $n_sigs [signature analysis]",
                            percentage))
                end
            end
            yield() # Give other tasks a chance to run
        catch e
            @error "Error during signature analysis"
            Base.showerror(stderr, e, catch_backtrace())
        end
    end

    for task in tasks
        wait(task)
        if cancellable_token !== nothing && is_cancelled(cancellable_token.cancel_flag)
            break
        end
    end

    append!(res.inference_error_reports, progress.reports)
end

function JET.virtual_process!(interp::LSInterpreter,
                              x::Union{AbstractString,JS.SyntaxNode},
                              overrideex::Union{Nothing,Expr})
    cancellable_token = interp.request.cancellable_token
    if cancellable_token !== nothing
        filename = JET.InterpretationState(interp).filename
        shortpath = let state = interp.server.state
            isdefined(state, :root_path) ? relpath(filename, state.root_path) : basename(filename)
        end
        percentage = let prev_analysis_result = interp.request.prev_analysis_result
            n_files = isnothing(prev_analysis_result) ? 0 : length(prev_analysis_result.analyzed_file_infos)
            iszero(n_files) ? 0 : compute_percentage(interp.counter[], n_files,
                JET.InterpretationState(interp).config.analyze_from_definitions ? 50 : 100)
        end
        send_progress(interp.server, cancellable_token.token,
            WorkDoneProgressReport(;
                cancellable = true,
                message = shortpath * " [file analysis]",
                percentage))
        yield_to_endpoint()
    end
    res = @invoke JET.virtual_process!(interp::JET.ConcreteInterpreter,
                                       x::Union{AbstractString,JS.SyntaxNode},
                                       overrideex::Union{Nothing,Expr})
    increment!(interp.counter)
    return res
end

function JET.try_read_file(interp::LSInterpreter, include_context::Module, filename::AbstractString)
    uri = filename2uri(filename)
    fi = JETLS.get_saved_file_info(interp.server.state, uri)
    if !isnothing(fi)
        parsed_stream = fi.parsed_stream
        if isempty(parsed_stream.diagnostics)
            return fi.syntax_node
        else
            return String(JS.sourcetext(parsed_stream))
        end
    end
    # fallback to the default file-system-based include
    return read(filename, String)
end

end # module Interpreter
