module Interpreter

export LSInterpreter, analyze_package

using JuliaSyntax: JuliaSyntax as JS
using Revise: Revise
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
    state::JET.InterpretationState
    function LSInterpreter(server::S, request::AnalysisRequest, analyzer::LSAnalyzer, counter::Counter) where S<:Server
        return new{S}(server, request, analyzer, counter)
    end
    function LSInterpreter(server::S, request::AnalysisRequest, analyzer::LSAnalyzer, counter::Counter, state::JET.InterpretationState) where S<:Server
        return new{S}(server, request, analyzer, counter, state)
    end
end

# The main constructor
LSInterpreter(server::Server, request::AnalysisRequest) = LSInterpreter(server, request, LSAnalyzer(request.entry), Counter())

# `JET.ConcreteInterpreter` interface
JET.InterpretationState(interp::LSInterpreter) = interp.state
function JET.ConcreteInterpreter(interp::LSInterpreter, state::JET.InterpretationState)
    # add `state` to `interp`, and update `interp.analyzer.cache`
    initialize_cache!(interp.analyzer, state.res.analyzed_files)
    return LSInterpreter(interp.server, interp.request, interp.analyzer, interp.counter, state)
end
JET.ToplevelAbstractAnalyzer(interp::LSInterpreter) = interp.analyzer

# overloads
# =========

function compute_percentage(count, total, max=100)
    return min(round(Int, (count / total) * max), max)
end

function cache_intermediate_analysis_result!(interp::LSInterpreter)
    result = JET.JETToplevelResult(interp.analyzer, interp.state.res, "LSInterpreter (intermediate result)", ())
    intermediate_result = JETLS.new_analysis_result(interp.request, result)
    JETLS.update_analysis_cache!(interp.server.state.analysis_manager, intermediate_result)
end

function JET.analyze_from_definitions!(interp::LSInterpreter, config::JET.ToplevelConfig)
    # Cache intermediate analysis results after file analysis completes
    # This makes module context information available immediately for LS features
    cache_intermediate_analysis_result!(interp)

    analyzer = JET.ToplevelAbstractAnalyzer(interp, JET.non_toplevel_concretized; refresh_local_cache = false)
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
    next_interval = interval = 10 ^ max(round(Int, log10(n_sigs)) - 1, 0)
    all_reports = JET.InferenceErrorReport[]
    for i = 1:n_sigs
        if cancellable_token !== nothing
            if is_cancelled(cancellable_token.cancel_flag)
                return
            end
            if i == next_interval
                percentage = compute_percentage(i, n_sigs, 50) + 50
                send_progress(interp.server, cancellable_token.token,
                    WorkDoneProgressReport(;
                        cancellable = true,
                        message = "$i / $n_sigs [signature analysis]",
                        percentage))
                yield_to_endpoint(0.01)
                next_interval += interval
            end
        end
        tt = res.toplevel_signatures[i]
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
            append!(all_reports, JET.get_reports(analyzer, result))
        else
            # something went wrong
            if JETLS_DEV_MODE
                @warn "Couldn't find a single method matching the signature `", tt, "`"
            end
        end
    end
    append!(res.inference_error_reports, all_reports)
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

# analyze_package

function cache_intermediate_analysis_result!(server, analyzer, request, res)
    result = JET.JETToplevelResult(analyzer, res, "LSInterpreter (intermediate result)", ())
    intermediate_result = JETLS.new_analysis_result(request, result)
    JETLS.update_analysis_cache!(server.state.analysis_manager, intermediate_result)
end

function analyze_package(server::Server, request::AnalysisRequest, pkgid::Base.PkgId)
    if !haskey(Base.loaded_modules, pkgid)
        pkgmod = Base.require(pkgid)
    else
        pkgmod = Base.loaded_modules[pkgid]
    end
    Revise.revise()

    haskey(Revise.pkgdatas, pkgid) || Revise.watch_package(pkgid)
    if !haskey(Revise.pkgdatas, pkgid)
        error(lazy"Package $pkgmod is not tracked by Revise.")
    end

    # If Revise hasn't instantiated signatures yet, populate that cache here
    pkgdata = Revise.pkgdatas[pkgid]
    for file in Revise.srcfiles(pkgdata)
        fi = Revise.maybe_parse_from_cache!(pkgdata, file)
        Revise.maybe_extract_sigs!(fi)
    end

    res = JET.VirtualProcessResult(nothing)

    # Revise's signature population may execute code, which can increment the world age,
    # so we update to the latest world age here
    analyzer = LSAnalyzer(request.entry)

    n_sigs = 0
    for (i, fi) in enumerate(pkgdata.fileinfos)
        # TODO Use a custom extenstion data for modexsigs (per-module extension data)
        filename = normpath(pkgdata.info.basedir, pkgdata.info.files[i])
        res.analyzed_files[filename] = JET.AnalyzedFileInfo(
            JET.ModuleRangeInfo[1:typemax(Int) => first(keys(fi.modexsigs))])
        for (_, exsigs) in fi.modexsigs, (_, siginfos) in exsigs
            isnothing(siginfos) && continue
            n_sigs += length(siginfos)
        end
    end

    cache_intermediate_analysis_result!(server, analyzer, request, res)

    cancellable_token = request.cancellable_token
    if cancellable_token !== nothing
        if is_cancelled(cancellable_token.cancel_flag)
            return
        end
        send_progress(server, cancellable_token.token,
            WorkDoneProgressReport(;
                cancellable = true,
                message = "0 / $n_sigs [incremental package analysis]",
                percentage = 0))
        yield_to_endpoint()
    end
    next_interval = interval = 10 ^ max(round(Int, log10(n_sigs)) - 1, 0)

    counter = Ref(0)
    for fi in pkgdata.fileinfos, (_, exsigs) in fi.modexsigs, (_, siginfos) in exsigs
        isnothing(siginfos) && continue
        for (i, siginfo) in enumerate(siginfos)
            counter[] += 1
            if cancellable_token !== nothing
                if is_cancelled(cancellable_token.cancel_flag)
                    return
                end
                if counter[] == next_interval
                    percentage = compute_percentage(counter[], n_sigs)
                    send_progress(server, cancellable_token.token,
                        WorkDoneProgressReport(;
                            cancellable = true,
                            message = "$(counter[]) / $n_sigs [incremental package analysis]",
                            percentage))
                    yield_to_endpoint(0.01)
                    next_interval += interval
                end
            end

            inf_world = CC.get_inference_world(analyzer)
            ext = Revise.get_extended_data(siginfo, :JETLS)
            if ext !== nothing && ext.data isa JET.SigAnalysisResult
                prev_result = ext.data::JET.SigAnalysisResult
                if (CC.cache_owner(analyzer) === prev_result.codeinst.owner &&
                    prev_result.codeinst.max_world ≥ inf_world ≥ prev_result.codeinst.min_world)
                    reports = prev_result.reports
                    @goto gotreports
                end
            end
            match = Base._which(siginfo.sig;
                method_table = CC.method_table(analyzer),
                world = inf_world,
                raise = false)
            if match !== nothing
                result = JET.analyze_method_signature!(analyzer,
                    match.method, match.spec_types, match.sparams)
                reports = JET.get_reports(analyzer, result)
                siginfos[i] = Revise.replace_extended_data(siginfo, :JETLS, JET.SigAnalysisResult(reports, result.ci))
                @label gotreports
                append!(res.inference_error_reports, reports)
            else
                @warn sprint() do io
                    print("Couldn't find a single matching method for the signature `")
                    Base.show_tuple_as_call(io, Symbol(""), siginfo.sig)
                    print(io, "` (progress: $(counter[])/$n_sigs)")
                end
            end
        end
    end

    unique!(JET.aggregation_policy(analyzer), res.inference_error_reports)
    return JET.JETToplevelResult(analyzer, res, "LSAnalyzer: $(pkgid.name)")
end

end # module Interpreter
