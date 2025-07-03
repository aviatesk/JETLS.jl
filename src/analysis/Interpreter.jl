module Interpreter

export LSInterpreter

using JuliaSyntax: JuliaSyntax as JS
using JET: CC, JET
using ..JETLS:
    AnalysisEntry, FullAnalysisInfo, SavedFileInfo, Server,
    JETLS_DEV_MODE, build_tree!, get_saved_file_info, yield_to_endpoint, send
using ..JETLS.URIs2
using ..JETLS.LSP
using ..JETLS.Analyzer

mutable struct Counter
    count::Int
end
Counter() = Counter(0)
increment!(counter::Counter) = counter.count += 1
Base.getindex(counter::Counter) = counter.count

struct LSInterpreter{S<:Server, I<:FullAnalysisInfo} <: JET.ConcreteInterpreter
    server::S
    info::I
    analyzer::LSAnalyzer
    counter::Counter
    state::JET.InterpretationState
    function LSInterpreter(server::S, info::I, analyzer::LSAnalyzer, counter::Counter) where S<:Server where I<:FullAnalysisInfo
        return new{S,I}(server, info, analyzer, counter)
    end
    function LSInterpreter(server::S, info::I, analyzer::LSAnalyzer, counter::Counter, state::JET.InterpretationState) where S<:Server where I<:FullAnalysisInfo
        return new{S,I}(server, info, analyzer, counter, state)
    end
end

# The main constructor
LSInterpreter(server::Server, info::FullAnalysisInfo) = LSInterpreter(server, info, LSAnalyzer(info.entry), Counter())

# `JET.ConcreteInterpreter` interface
JET.InterpretationState(interp::LSInterpreter) = interp.state
function JET.ConcreteInterpreter(interp::LSInterpreter, state::JET.InterpretationState)
    # add `state` to `interp`, and update `interp.analyzer.cache`
    initialize_cache!(interp.analyzer, state.res.analyzed_files)
    return LSInterpreter(interp.server, interp.info, interp.analyzer, interp.counter, state)
end
JET.ToplevelAbstractAnalyzer(interp::LSInterpreter) = interp.analyzer

# overloads
# =========

function compute_percentage(count, total, max=100)
    return min(round(Int, (count / total) * max), max)
end

function JET.analyze_from_definitions!(interp::LSInterpreter, config::JET.ToplevelConfig)
    analyzer = JET.ToplevelAbstractAnalyzer(interp, JET.non_toplevel_concretized; refresh_local_cache = false)
    entrypoint = config.analyze_from_definitions
    res = JET.InterpretationState(interp).res
    n = length(res.toplevel_signatures)
    next_interval = interval = 10 ^ max(round(Int, log10(n)) - 1, 0)
    token = interp.info.token
    if token !== nothing
        send(interp.server, ProgressNotification(;
            params = ProgressParams(;
                token,
                value = WorkDoneProgressReport(;
                    message = "0 / $n [signature analysis]",
                    percentage = 50))))
        yield_to_endpoint()
    end
    for i = 1:n
        if token !== nothing && i == next_interval
            percentage = compute_percentage(i, n, 50) + 50
            send(interp.server, ProgressNotification(;
                params = ProgressParams(;
                    token,
                    value = WorkDoneProgressReport(;
                        message = "$i / $n [signature analysis]",
                        percentage))))
            yield_to_endpoint(0.01)
            next_interval += interval
        end
        tt = res.toplevel_signatures[i]
        match = Base._which(tt;
            # NOTE use the latest world counter with `method_table(analyzer)` unwrapped,
            # otherwise it may use a world counter when this method isn't defined yet
            method_table=JET.unwrap_method_table(CC.method_table(analyzer)),
            world=CC.get_inference_world(analyzer),
            raise=false)
        if (match !== nothing &&
            (!(entrypoint isa Symbol) || # implies `analyze_from_definitions===true`
             match.method.name === entrypoint))
            analyzer, result = JET.analyze_method_signature!(analyzer,
                match.method, match.spec_types, match.sparams)
            reports = JET.get_reports(analyzer, result)
            append!(res.inference_error_reports, reports)
        else
            # something went wrong
            if JETLS_DEV_MODE
                @warn "Couldn't find a single method matching the signature `", tt, "`"
            end
        end
    end
end

function JET.virtual_process!(interp::LSInterpreter,
                              x::Union{AbstractString,JS.SyntaxNode},
                              overrideex::Union{Nothing,Expr})
    token = interp.info.token
    if token !== nothing
        filename = JET.InterpretationState(interp).filename
        shortpath = let state = interp.server.state
            isdefined(state, :root_path) ? relpath(filename, state.root_path) : basename(filename)
        end
        percentage = let total = interp.info.n_files
            iszero(total) ? 0 : compute_percentage(interp.counter[], total,
                JET.InterpretationState(interp).config.analyze_from_definitions ? 50 : 100)
        end
        send(interp.server, ProgressNotification(;
            params = ProgressParams(;
                token,
                value = WorkDoneProgressReport(;
                    message = shortpath * "[file analysis]",
                    percentage))))
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
    fi = get_saved_file_info(interp.server.state, uri)
    if !isnothing(fi)
        parsed_stream = fi.parsed_stream
        if isempty(parsed_stream.diagnostics)
            return build_tree!(JS.SyntaxNode, fi; filename)
        else
            return String(JS.sourcetext(parsed_stream))
        end
    end
    # fallback to the default file-system-based include
    return read(filename, String)
end

end # module Interpreter
