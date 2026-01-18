module Interpreter

export LSInterpreter

using JuliaSyntax: JuliaSyntax as JS
using JET: CC, JET, JuliaInterpreter
using ..JETLS:
    AbstractJETLSPlugin, AnalysisRequest, AnalysisResult, SavedFileInfo, Server, JETLS,
    JETLS_DEV_MODE, active_plugins,
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
    plugins::Vector{AbstractJETLSPlugin}
    analyzer::LSAnalyzer
    counter::Counter
    activation_done::Union{Nothing,Base.Event}
    warning_reports::Vector{JETLS.ToplevelWarningReport}
    current_node::Base.RefValue{JS.SyntaxNode}
    state::JET.InterpretationState
    function LSInterpreter(
            server::S, request::AnalysisRequest, plugins::Vector{AbstractJETLSPlugin},
            analyzer::LSAnalyzer, counter::Counter,
            activation_done::Union{Nothing,Base.Event}
        ) where S<:Server
        return new{S}(server, request, plugins, analyzer, counter, activation_done,
            JETLS.ToplevelWarningReport[], Base.RefValue{JS.SyntaxNode}())
    end
    function LSInterpreter(
            server::S, request::AnalysisRequest, plugins::Vector{AbstractJETLSPlugin},
            analyzer::LSAnalyzer, counter::Counter,
            activation_done::Union{Nothing,Base.Event},
            warning_reports::Vector{JETLS.ToplevelWarningReport},
            current_node::Base.RefValue{JS.SyntaxNode},
            state::JET.InterpretationState,
        ) where S<:Server
        return new{S}(server, request, plugins, analyzer, counter, activation_done,
            warning_reports, current_node, state)
    end
end

# The main constructor
function LSInterpreter(
        server::Server, request::AnalysisRequest;
        activation_done::Union{Nothing,Base.Event} = nothing
    )
    plugins = active_plugins(server, request.entry)
    return LSInterpreter(server, request, plugins, LSAnalyzer(request.entry), Counter(), activation_done)
end

# `JET.ConcreteInterpreter` interface
JET.InterpretationState(interp::LSInterpreter) = interp.state
function JET.ConcreteInterpreter(interp::LSInterpreter, state::JET.InterpretationState)
    return LSInterpreter(
        interp.server, interp.request, interp.plugins, interp.analyzer, interp.counter,
        interp.activation_done, interp.warning_reports, interp.current_node, state)
end
JET.ToplevelAbstractAnalyzer(interp::LSInterpreter) = interp.analyzer
function JET.ToplevelAbstractAnalyzer(
        interp::LSInterpreter, concretized::BitVector;
        refresh_local_cache::Bool = true,    # This option is used by JET v0.10. TODO We can remove this once we update JET to v0.11.
        reset_report_target_modules::Bool = true, # LSInterpreter specific option
    )
    if reset_report_target_modules
        reset_report_target_modules!(interp.analyzer, JET.InterpretationState(interp).res.analyzed_files)
    end
    return @invoke JET.ToplevelAbstractAnalyzer(
        interp::JET.ConcreteInterpreter, concretized::BitVector;
        refresh_local_cache)
end

# overloads
# =========

struct MethodDefinitionInfo
    filename::String
    mod::Module
    src
    MethodDefinitionInfo(filename::AbstractString, mod::Module, @nospecialize(src)) = new(filename, mod, src)
end

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
    intermediate_result = JETLS.new_analysis_result(interp, interp.request, result)
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

    res = JET.InterpretationState(interp).res
    reset_report_target_modules!(interp.analyzer, res.analyzed_files)

    # Detect method overwrites
    seen_sigs = IdDict{Type,MethodDefinitionInfo}()
    for signature_info in res.signature_infos
        (; filename, mod, tt, src) = signature_info
        if haskey(seen_sigs, tt)
            lines = if src isa Core.CodeInfo
                JETLS.get_lines_in_src(filename, src)
            elseif src isa Expr
                JETLS.get_lines_in_ex(filename, src)
            else
                @warn "Unsupported source type found" filename mod tt typeof(src)
                continue
            end
            original_definition = seen_sigs[tt]
            original_filename = original_definition.filename
            original_src = original_definition.src
            original_lines = if src isa Core.CodeInfo
                JETLS.get_lines_in_src(original_filename, original_src)
            elseif src isa Expr
                JETLS.get_lines_in_ex(original_filename, original_src)
            else
                @warn "Unsupported source type found" original_filename typeof(original_src)
                continue
            end
            push!(interp.warning_reports, JETLS.MethodOverwriteReport(mod, tt, filename, lines, original_filename, original_lines))
        else
            seen_sigs[tt] = MethodDefinitionInfo(filename, mod, src)
        end
    end

    entrypoint = config.analyze_from_definitions
    n_sigs = length(res.signature_infos)
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
            (; tt) = res.signature_infos[i]
            # Create a new analyzer with fresh local caches (`inf_cache` and `analysis_results`)
            # to avoid data races between concurrent signature analysis tasks
            analyzer = JET.ToplevelAbstractAnalyzer(interp, JET.non_toplevel_concretized;
                reset_report_target_modules = false,
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

function JET.try_read_file(interp::LSInterpreter, _include_context::Module, filename::AbstractString)
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

# XXX This is an ad-hoc overload to make `node` available in the following `JuliaInterpreter.step_expr!`
function JET.lower_with_err_handling(interp::LSInterpreter, node::JS.SyntaxNode, xblk::Expr)
    interp.current_node[] = node
    @invoke JET.lower_with_err_handling(interp::JET.ConcreteInterpreter, node::JS.SyntaxNode, xblk::Expr)
end

function JuliaInterpreter.step_expr!(
        interp::LSInterpreter, frame::JuliaInterpreter.Frame, @nospecialize(node),
        istoplevel::Bool
    )
    if Meta.isexpr(node, :call) && length(node.args) ≥ 4
        func = JuliaInterpreter.lookup(frame, node.args[1])
        if func === Core._typebody!
            structtyp = JuliaInterpreter.lookup(frame, node.args[3])
            if structtyp isa Type
                ftypes = JuliaInterpreter.lookup(frame, node.args[4])::Core.SimpleVector
                fnames = fieldnames(structtyp)
                for (fname, ft) in zip(fnames, ftypes)
                    if JETLS.is_abstract_fieldtype(ft)
                        filename = JET.InterpretationState(interp).filename
                        fieldline = extract_field_line(interp, frame, nameof(structtyp), fname)
                        push!(interp.warning_reports, JETLS.AbstractFieldReport(filename, fieldline, structtyp, fname, ft))
                    end
                end
            end
        end
    end
    @invoke JuliaInterpreter.step_expr!(
        interp::JET.ConcreteInterpreter, frame::JuliaInterpreter.Frame, node::Any,
        istoplevel::Bool
    )
end

# TODO Use lowered `SyntaxTree` for finding field line for macro-generated structs
function extract_field_line(interp::LSInterpreter, frame::JuliaInterpreter.Frame, structname::Symbol, fname::Symbol)
    isassigned(interp.current_node) || return JuliaInterpreter.linenumber(frame)
    return @something(
        JETLS.try_extract_field_line(interp.current_node[], structname, fname),
        JuliaInterpreter.linenumber(frame)
    )
end

end # module Interpreter
