const FULL_ANALYSIS_THROTTLE = 5.0 # 3.0
const FULL_ANALYSIS_DEBOUNCE = 1.0
const SYNTACTIC_ANALYSIS_DEBOUNCE = 0.5

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
        else
            # TODO support multiple analysis units, which can happen if this file is included from multiple different analysis_units
            analysis_unit = first(analysis_info)
            if onsave
                analysis_unit.result.staled = true
            end
            function task()
                res = reanalyze!(server, analysis_unit; token)
                if res isa AnalysisUnit
                    notify_diagnostics!(server)
                end
            end
            id = hash(run_full_analysis!, hash(analysis_unit))
            if onsave
                debounce(id, FULL_ANALYSIS_DEBOUNCE) do
                    throttle(id, FULL_ANALYSIS_THROTTLE) do
                        task()
                    end
                end
            else
                throttle(id, FULL_ANALYSIS_THROTTLE) do
                    task()
                end
            end
        end
    end
    nothing
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
        filename = uri2filename(uri)
        @assert !isnothing(filename) lazy"Unsupported URI: $uri"
        parsed = build_tree!(JS.SyntaxNode, fi; filename)
        begin_full_analysis_progress(server, info)
        try
            return JET.analyze_and_report_expr!(LSInterpreter(server, info), parsed, filename, args...; jetconfigs...)
        finally
            end_full_analysis_progress(server, info)
        end
    else
        filepath = uri2filepath(uri)
        @assert filepath !== nothing lazy"Unsupported URI: $uri"
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

function new_analysis_unit(entry::AnalysisEntry, result)
    analyzed_file_infos = Dict{URI,JET.AnalyzedFileInfo}(
        # `filepath` is an absolute path (since `path` is specified as absolute)
        filename2uri(filepath) => analyzed_file_info for (filepath, analyzed_file_info) in result.res.analyzed_files)
    # TODO return something for `toplevel_error_reports`
    uri2diagnostics = jet_result_to_diagnostics(keys(analyzed_file_infos), result)
    successfully_analyzed_file_infos = copy(analyzed_file_infos)
    is_full_analysis_successful(result) || empty!(successfully_analyzed_file_infos)
    analysis_result = FullAnalysisResult(
        #=staled=#false, result.res.actual2virtual::JET.Actual2Virtual, update_analyzer_world(result.analyzer),
        uri2diagnostics, analyzed_file_infos, successfully_analyzed_file_infos)
    return AnalysisUnit(entry, analysis_result)
end

function update_analysis_unit!(analysis_unit::AnalysisUnit, result)
    uri2diagnostics = analysis_unit.result.uri2diagnostics
    cached_analyzed_file_infos = analysis_unit.result.analyzed_file_infos
    cached_successfully_analyzed_file_infos = analysis_unit.result.successfully_analyzed_file_infos
    new_analyzed_file_infos = Dict{URI,JET.AnalyzedFileInfo}(
        # `filepath` is an absolute path (since `path` is specified as absolute)
        filename2uri(filepath) => analyzed_file_info for (filepath, analyzed_file_info) in result.res.analyzed_files)
    for deleted_file_uri in setdiff(keys(cached_analyzed_file_infos), keys(new_analyzed_file_infos))
        empty!(get!(()->Diagnostic[], uri2diagnostics, deleted_file_uri))
        delete!(cached_analyzed_file_infos, deleted_file_uri)
        if is_full_analysis_successful(result)
            delete!(cached_successfully_analyzed_file_infos, deleted_file_uri)
        end
    end
    for (new_file_uri, analyzed_file_info) in new_analyzed_file_infos
        cached_analyzed_file_infos[new_file_uri] = analyzed_file_info
        if is_full_analysis_successful(result)
            cached_successfully_analyzed_file_infos[new_file_uri] = analyzed_file_info
        end
        empty!(get!(()->Diagnostic[], uri2diagnostics, new_file_uri))
    end
    jet_result_to_diagnostics!(uri2diagnostics, result)
    analysis_unit.result.staled = false
    if is_full_analysis_successful(result)
        analysis_unit.result.actual2virtual = result.res.actual2virtual
        analysis_unit.result.analyzer = update_analyzer_world(result.analyzer)
    end
end

# TODO This reverse map recording should respect the changes made in `include` chains
function record_reverse_map!(state::ServerState, analysis_unit::AnalysisUnit)
    afiles = analyzed_file_uris(analysis_unit)
    for uri in afiles
        analysis_info = get!(Set{AnalysisUnit}, state.analysis_cache, uri)
        if analysis_info isa OutOfScope
            # this file was previously `OutOfScope`, but now can be analyzed by some unit,
            # so replace the cache with a set
            analysis_info = state.analysis_cache[uri] = Set{AnalysisUnit}()
        end
        should_record = true
        for analysis_unit′ in analysis_info
            bfiles = analyzed_file_uris(analysis_unit′)
            if afiles ≠ bfiles
                if afiles ⊆ bfiles
                    should_record = false
                else # bfiles ⊆ afiles, i.e. now we have a better unit to analyze this file
                    delete!(analysis_info, analysis_unit′)
                end
            end
        end
        should_record && push!(analysis_info, analysis_unit)
    end
end

function initiate_analysis_unit!(server::Server, uri::URI; token::Union{Nothing,ProgressToken}=nothing)
    state = server.state
    fi = get_saved_file_info(state, uri)
    if isnothing(fi)
        error(lazy"`initiate_analysis_unit!` called before saved file cache is created for $uri")
    end
    parsed_stream = fi.parsed_stream
    if !isempty(parsed_stream.diagnostics)
        return nothing
    end

    env_path = find_analysis_env_path(state, uri)
    if env_path isa OutOfScope
        state.analysis_cache[uri] = env_path
        return nothing
    end
    if isnothing(env_path)
        pkgname = nothing
    elseif uri.scheme == "untitled"
        pkgname = nothing
    else
        pkgname = find_pkg_name(env_path)
    end

    if env_path === nothing
        @label analyze_script
        if env_path !== nothing
            local entry = ScriptInEnvAnalysisEntry(env_path, uri)
            local info = FullAnalysisInfo(entry, token, #=reanalyze=#false, #=n_files=#0)
            result = activate_do(env_path) do
                analyze_parsed_if_exist(server, info)
            end
        else
            local entry = ScriptAnalysisEntry(uri)
            local info = FullAnalysisInfo(entry, token, #=reanalyze=#false, #=n_files=#0)
            result = analyze_parsed_if_exist(server, info)
        end
        analysis_unit = new_analysis_unit(entry, result)
        @assert uri in analyzed_file_uris(analysis_unit)
        record_reverse_map!(state, analysis_unit)
    elseif pkgname === nothing
        @goto analyze_script
    else # this file is likely one within a package
        filepath = uri2filepath(uri)::String # uri.scheme === "file"
        filekind, filedir = find_package_directory(filepath, env_path)
        if filekind === :script
            @goto analyze_script
        elseif filekind === :src
            # analyze package source files
            entry_result = activate_do(env_path) do
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
                local entry = PackageSourceAnalysisEntry(env_path, pkgfileuri, pkgid)
                local info = FullAnalysisInfo(entry, token, #=reanalyze=#false, #=n_files=#0)
                res = analyze_parsed_if_exist(server, info, pkgid)
                return entry, res
            end
            if entry_result === nothing
                @goto analyze_script
            end
            entry, result = entry_result
            analysis_unit = new_analysis_unit(entry, result)
            record_reverse_map!(state, analysis_unit)
            if uri ∉ analyzed_file_uris(analysis_unit)
                @goto analyze_script
            end
        elseif filekind === :test
            # analyze test scripts
            runtestsfile = joinpath(filedir, "runtests.jl")
            runtestsuri = filepath2uri(runtestsfile)
            local entry = PackageTestAnalysisEntry(env_path, runtestsuri)
            local info = FullAnalysisInfo(entry, token, #=reanalyze=#false, #=n_files=#0)
            result = activate_do(env_path) do
                analyze_parsed_if_exist(server, info)
            end
            analysis_unit = new_analysis_unit(entry, result)
            record_reverse_map!(state, analysis_unit)
            if uri ∉ analyzed_file_uris(analysis_unit)
                @goto analyze_script
            end
        elseif filekind === :docs
            @goto analyze_script # TODO
        else
            @assert filekind === :ext
            @goto analyze_script # TODO
        end
    end

    return analysis_unit
end

function reanalyze!(server::Server, analysis_unit::AnalysisUnit; token::Union{Nothing,ProgressToken}=nothing)
    state = server.state
    analysis_result = analysis_unit.result
    if !(analysis_result.staled)
        return nothing
    end

    any_parse_failed = any(analyzed_file_uris(analysis_unit)) do uri::URI
        fi = get_saved_file_info(state, uri)
        if !isnothing(fi) && !isempty(fi.parsed_stream.diagnostics)
            return true
        end
        return false
    end
    if any_parse_failed
        # TODO Allow running the full analysis even with any parse errors?
        return nothing
    end

    entry = analysis_unit.entry
    n_files = length(values(analysis_unit.result.successfully_analyzed_file_infos))

    # manually dispatch here for the maximum inferrability
    if entry isa ScriptAnalysisEntry
        info = FullAnalysisInfo(entry, token, #=reanalyze=#true, n_files)
        result = analyze_parsed_if_exist(server, info)
    elseif entry isa ScriptInEnvAnalysisEntry
        info = FullAnalysisInfo(entry, token, #=reanalyze=#true, n_files)
        result = activate_do(entryenvpath(entry)) do
            analyze_parsed_if_exist(server, info)
        end
    elseif entry isa PackageSourceAnalysisEntry
        info = FullAnalysisInfo(entry, token, #=reanalyze=#true, n_files)
        result = activate_do(entryenvpath(entry)) do
            analyze_parsed_if_exist(server, info, entry.pkgid)
        end
    elseif entry isa PackageTestAnalysisEntry
        info = FullAnalysisInfo(entry, token, #=reanalyze=#true, n_files)
        result = activate_do(entryenvpath(entry)) do
            analyze_parsed_if_exist(server, info)
        end
    else error("Unsupported analysis entry $entry") end

    update_analysis_unit!(analysis_unit, result)
    record_reverse_map!(state, analysis_unit)

    return analysis_unit
end
