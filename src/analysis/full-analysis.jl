function run_full_analysis!(server::Server, uri::URI; onsave::Bool=false, token::Union{Nothing,ProgressToken}=nothing)
    if !haskey(server.state.analysis_cache, uri)
        res = initiate_analysis_unit!(server, uri; token)
        if res isa AnalysisUnit
            notify_diagnostics!(server)
        end
    else # this file is tracked by some analysis unit already
        analysis_info = server.state.analysis_cache[uri]
        if analysis_info isa OutOfScope
            # this file is out of the current project scope, ignore it
            return nothing
        end

        analysis_unit = analysis_info
        if onsave
            analysis_unit.result.staled = true
        end
        function task()
            res = reanalyze!(server, analysis_unit, uri; token)
            if res isa AnalysisUnit
                notify_diagnostics!(server)
            end
        end
        id = hash(run_full_analysis!, hash(analysis_unit))
        if onsave
            debounce(id, get_config(server.state.config_manager, "full_analysis", "debounce")) do
                throttle(id, get_config(server.state.config_manager, "full_analysis", "throttle")) do
                    task()
                end
            end
        else
            JETLS.throttle(id, get_config(server.state.config_manager, "full_analysis", "throttle")) do
                task()
            end
        end
    end
end

function begin_full_analysis_progress(server::Server, info::FullAnalysisInfo)
    token = @something info.token return nothing
    filename = uri2filename(entryuri(info.entry))
    pre = info.reanalyze ? "Reanalyzing" : "Analyzing"
    title = "$(pre) $(basename(filename)) [$(entrykind(info.entry))]"
    send(server, ProgressNotification(;
        params = ProgressParams(;
            token,
            value = WorkDoneProgressBegin(;
                title,
                message = "Full analysis initiated",
                percentage = 0))))
    yield_to_endpoint()
end

function end_full_analysis_progress(server::Server, info::FullAnalysisInfo)
    token = @something info.token return nothing
    send(server, ProgressNotification(;
        params = ProgressParams(;
            token,
            value = WorkDoneProgressEnd(;
                message = "Full analysis finished"))))
end

function analyze_parsed_if_exist(server::Server, info::FullAnalysisInfo, args...)
    uri = entryuri(info.entry)
    jetconfigs = entryjetconfigs(info.entry)
    fi = get_saved_file_info(server.state, uri)
    if !isnothing(fi)
        filename = @something uri2filename(uri) error(lazy"Unsupported URI: $uri")
        parsed = fi.syntax_node
        begin_full_analysis_progress(server, info)
        try
            return JET.analyze_and_report_expr!(LSInterpreter(server, info), parsed, filename, args...; jetconfigs...)
        finally
            end_full_analysis_progress(server, info)
        end
    else
        filepath = @something uri2filepath(uri) error(lazy"Unsupported URI: $uri")
        begin_full_analysis_progress(server, info)
        try
            return JET.analyze_and_report_file!(LSInterpreter(server, info), filepath, args...; jetconfigs...)
        finally
            end_full_analysis_progress(server, info)
        end
    end
end

function is_full_analysis_successful(result)
    return isempty(result.res.toplevel_error_reports)
end

# update `AnalyzerState(analyzer).world` so that `analyzer` can infer any newly defined methods
function update_analyzer_world(analyzer::LSAnalyzer)
    state = JET.AnalyzerState(analyzer)
    newstate = JET.AnalyzerState(state; world = Base.get_world_counter())
    return JET.AbstractAnalyzer(analyzer, newstate)
end

function AnalysisUnit(entry::AnalysisEntry, result, prev_analysis_unit::Union{Nothing,AnalysisUnit})
    analyzed_file_infos = Dict{URI,JET.AnalyzedFileInfo}(
        # `filepath` is an absolute path (since `path` is specified as absolute)
        filename2uri(filepath) => analyzed_file_info for (filepath, analyzed_file_info) in result.res.analyzed_files)

    uri2diagnostics = jet_result_to_diagnostics(keys(analyzed_file_infos), result)

    if !is_full_analysis_successful(result) && !isnothing(prev_analysis_unit)
        (; actual2virtual, analyzer, analyzed_file_infos) = prev_analysis_unit.result
    else
        actual2virtual = result.res.actual2virtual::JET.Actual2Virtual
        analyzer = update_analyzer_world(result.analyzer)
    end

    analysis_result = FullAnalysisResult(
        #=staled=#false, actual2virtual, analyzer, uri2diagnostics, analyzed_file_infos)
    return AnalysisUnit(entry, analysis_result)
end

function lookup_analysis_entry(state::ServerState, uri::URI)
    maybe_env_path = find_analysis_env_path(state, uri)
    if maybe_env_path isa OutOfScope
        return maybe_env_path
    end

    env_path = maybe_env_path
    if isnothing(env_path)
        return ScriptAnalysisEntry(uri)
    elseif uri.scheme == "untitled"
        return ScriptInEnvAnalysisEntry(env_path, uri)
    end

    pkgname = find_pkg_name(env_path)
    filepath = uri2filepath(uri)::String # uri.scheme === "file"
    filekind, filedir = find_package_directory(filepath, env_path)
    if filekind === :src
        entry = activate_do(env_path) do
            pkgenv = @something Base.identify_package_env(pkgname) begin
                @warn "Failed to identify package environment" pkgname
                return nothing
            end
            pkgid, env = pkgenv
            pkgfile = @something Base.locate_package(pkgid, env) begin
                @warn "Expected a package to have a source file" pkgname
                return nothing
            end
            pkgfileuri = filepath2uri(pkgfile)
            PackageSourceAnalysisEntry(env_path, pkgfileuri, pkgid)
        end
        if entry === nothing
            return ScriptInEnvAnalysisEntry(env_path, uri)
        end
        return entry
    elseif filekind === :test
        runtestsfile = joinpath(filedir, "runtests.jl")
        runtestsuri = filepath2uri(runtestsfile)
        return PackageTestAnalysisEntry(env_path, runtestsuri)
    elseif filekind === :docs # TODO
    elseif filekind === :ext # TODO
    else
        @assert filekind === :script
    end
    return ScriptInEnvAnalysisEntry(env_path, uri)
end

function initiate_analysis_unit!(server::Server, uri::URI; token::Union{Nothing,ProgressToken}=nothing)
    entry = lookup_analysis_entry(server.state, uri)

    if entry isa OutOfScope
        server.state.analysis_cache[uri] = entry
        return nothing
    end

    return execute_analysis!(server, entry, uri, #=reanalysis=#nothing; token)
end

function execute_analysis!(
        server::Server, @nospecialize(entry::AnalysisEntry), uri::URI,
        prev_analysis_unit::Union{Nothing,AnalysisUnit} = nothing;
        token::Union{Nothing,ProgressToken} = nothing
    )
    if isnothing(prev_analysis_unit)
        reanalyze = false
        n_files = 0
    else
        reanalyze = true
        n_files = length(prev_analysis_unit.result.analyzed_file_infos)
    end

    if entry isa ScriptAnalysisEntry
        info = FullAnalysisInfo(entry, token, reanalyze, n_files)
        result = analyze_parsed_if_exist(server, info)

    elseif entry isa ScriptInEnvAnalysisEntry
        info = FullAnalysisInfo(entry, token, reanalyze, n_files)
        env_path = entryenvpath(entry)
        result = activate_do(env_path) do
            analyze_parsed_if_exist(server, info)
        end

    elseif entry isa PackageSourceAnalysisEntry
        info = FullAnalysisInfo(entry, token, reanalyze, n_files)
        result = activate_do(entryenvpath(entry)) do
            analyze_parsed_if_exist(server, info, entry.pkgid)
        end

    elseif entry isa PackageTestAnalysisEntry
        info = FullAnalysisInfo(entry, token, reanalyze, n_files)
        env_path = entryenvpath(entry)
        result = activate_do(env_path) do
            analyze_parsed_if_exist(server, info)
        end

    else error("Unsupported analysis entry $entry") end

    analysis_unit = AnalysisUnit(entry, result, prev_analysis_unit)
    analyzed_files = analyzed_file_uris(analysis_unit)

    for uri in analyzed_files
        server.state.analysis_cache[uri] = analysis_unit
    end

    # Fallback analysis in case this script was not analyzed by the analysis entry
    if entry isa ScriptAnalysisEntry || entry isa ScriptInEnvAnalysisEntry
        @assert uri ∈ analyzed_files # make sure we don't fail to infinite recursion
    end
    if uri ∉ analyzed_files
        env_path = entryenvpath(entry)
        entry = isnothing(env_path) ? ScriptAnalysisEntry(uri) : ScriptInEnvAnalysisEntry(uri, env_path)
        return execute_analysis!(server, entry, uri, #=reanalysis=#nothing; token=nothing)::AnalysisUnit
    else
        return analysis_unit
    end
end

function reanalyze!(server::Server, analysis_unit::AnalysisUnit, uri::URI; token::Union{Nothing,ProgressToken}=nothing)
    analysis_result = analysis_unit.result
    analysis_result.staled || return nothing

    any_parse_failed = any(analyzed_file_uris(analysis_unit)) do uri::URI
        fi = get_saved_file_info(server.state, uri)
        if !isnothing(fi) && !isempty(fi.parsed_stream.diagnostics)
            return true
        end
        return false
    end
    any_parse_failed && return nothing

    return execute_analysis!(server, analysis_unit.entry, uri, analysis_unit; token)
end
