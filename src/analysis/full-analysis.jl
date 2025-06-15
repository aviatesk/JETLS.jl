const FULL_ANALYSIS_THROTTLE = 5.0 # 3.0
const FULL_ANALYSIS_DEBOUNCE = 1.0
const SYNTACTIC_ANALYSIS_DEBOUNCE = 0.5

function run_full_analysis!(server::Server, uri::URI; onsave::Bool=false, token::Union{Nothing,ProgressToken}=nothing)
    if !haskey(server.state.contexts, uri)
        res = initiate_context!(server, uri; token)
        if res isa AnalysisContext
            notify_full_diagnostics!(server)
        end
    else # this file is tracked by some context already
        contexts = server.state.contexts[uri]
        if contexts isa ExternalContext
            # this file is out of the current project scope, ignore it
        else
            # TODO support multiple analysis contexts, which can happen if this file is included from multiple different contexts
            context = first(contexts)
            if onsave
                context.result.staled = true
            end
            function task()
                res = reanalyze_with_context!(server, context; token)
                if res isa AnalysisContext
                    notify_full_diagnostics!(server)
                end
            end
            id = hash(run_full_analysis!, hash(context))
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
    token = info.token
    if token === nothing
        return nothing
    end
    filepath = uri2filepath(entryuri(info.entry))
    pre = info.reanalyze ? "Reanalyzing" : "Analyzing"
    title = "$(pre) $(basename(filepath)) [$(entrykind(info.entry))]"
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
    token = info.token
    if token === nothing
        return nothing
    end
    send(server, ProgressNotification(;
        params = ProgressParams(;
            token,
            value = WorkDoneProgressEnd(;
                message = "Full analysis finished"))))
end

function analyze_parsed_if_exist(server::Server, info::FullAnalysisInfo, args...;
                                 toplevel_logger = nothing, kwargs...)
    uri = entryuri(info.entry)
    if haskey(server.state.saved_file_cache, uri)
        parsed_stream = server.state.saved_file_cache[uri].parsed_stream
        filename = uri2filename(uri)
        @assert !isnothing(filename) "Unsupported URI: $uri"
        parsed = JS.build_tree(JS.SyntaxNode, parsed_stream; filename)
        begin_full_analysis_progress(server, info)
        try
            return JET.analyze_and_report_expr!(LSInterpreter(server, info), parsed, filename, args...; toplevel_logger, kwargs...)
        finally
            end_full_analysis_progress(server, info)
        end
    else
        filepath = uri2filepath(uri)
        @assert filepath !== nothing "Unsupported URI: $uri"
        begin_full_analysis_progress(server, info)
        try
            return JET.analyze_and_report_file!(LSInterpreter(server, info), filepath, args...; toplevel_logger, kwargs...)
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

function new_analysis_context(entry::AnalysisEntry, result)
    analyzed_file_infos = Dict{URI,JET.AnalyzedFileInfo}(
        # `filepath` is an absolute path (since `path` is specified as absolute)
        filename2uri(filepath) => analyzed_file_info for (filepath, analyzed_file_info) in result.res.analyzed_files)
    # TODO return something for `toplevel_error_reports`
    uri2diagnostics = jet_result_to_diagnostics(keys(analyzed_file_infos), result)
    successfully_analyzed_file_infos = copy(analyzed_file_infos)
    is_full_analysis_successful(result) || empty!(successfully_analyzed_file_infos)
    analysis_result = FullAnalysisResult(
        #=staled=#false, result.res.actual2virtual, update_analyzer_world(result.analyzer),
        uri2diagnostics, analyzed_file_infos, successfully_analyzed_file_infos)
    return AnalysisContext(entry, analysis_result)
end

function update_analysis_context!(analysis_context::AnalysisContext, result)
    uri2diagnostics = analysis_context.result.uri2diagnostics
    cached_file_infos = analysis_context.result.analyzed_file_infos
    cached_successfully_analyzed_file_infos = analysis_context.result.successfully_analyzed_file_infos
    new_file_infos = Dict{URI,JET.AnalyzedFileInfo}(
        # `filepath` is an absolute path (since `path` is specified as absolute)
        filename2uri(filepath) => analyzed_file_info for (filepath, analyzed_file_info) in result.res.analyzed_files)
    for deleted_file_uri in setdiff(keys(cached_file_infos), keys(new_file_infos))
        empty!(get!(()->Diagnostic[], uri2diagnostics, deleted_file_uri))
        delete!(cached_file_infos, deleted_file_uri)
        if is_full_analysis_successful(result)
            delete!(cached_successfully_analyzed_file_infos, deleted_file_uri)
        end
    end
    for (new_file_uri, analyzed_file_info) in new_file_infos
        cached_file_infos[new_file_uri] = analyzed_file_info
        if is_full_analysis_successful(result)
            cached_successfully_analyzed_file_infos[new_file_uri] = analyzed_file_info
        end
        empty!(get!(()->Diagnostic[], uri2diagnostics, new_file_uri))
    end
    jet_result_to_diagnostics!(uri2diagnostics, result)
    analysis_context.result.staled = false
    if is_full_analysis_successful(result)
        analysis_context.result.actual2virtual = result.res.actual2virtual
        analysis_context.result.analyzer = update_analyzer_world(result.analyzer)
    end
end

# TODO This reverse map recording should respect the changes made in `include` chains
function record_reverse_map!(state::ServerState, analysis_context::AnalysisContext)
    afiles = analyzed_file_uris(analysis_context)
    for uri in afiles
        contexts = get!(Set{AnalysisContext}, state.contexts, uri)
        should_record = true
        for analysis_context′ in contexts
            bfiles = analyzed_file_uris(analysis_context′)
            if afiles ≠ bfiles
                if afiles ⊆ bfiles
                    should_record = false
                else # bfiles ⊆ afiles, i.e. now we have a better context to analyze this file
                    delete!(contexts, analysis_context′)
                end
            end
        end
        should_record && push!(contexts, analysis_context)
    end
end

function initiate_context!(server::Server, uri::URI; token::Union{Nothing,ProgressToken}=nothing)
    state = server.state
    file_info = state.saved_file_cache[uri]
    parsed_stream = file_info.parsed_stream
    if !isempty(parsed_stream.diagnostics)
        return nothing
    end

    if uri.scheme == "file"
        filename = path = uri2filepath(uri)::String
        if isdefined(state, :root_path)
            if !issubdir(dirname(path), state.root_path)
                state.contexts[uri] = ExternalContext()
                return nothing
            end
        end
        env_path = find_env_path(path)
        pkgname = env_path === nothing ? nothing : try
            env_toml = Pkg.TOML.parsefile(env_path)
            haskey(env_toml, "name") ? env_toml["name"]::String : nothing
        catch err
            err isa Base.TOML.ParseError || rethrow(err)
            nothing
        end
    elseif uri.scheme == "untitled"
        filename = path = uri2filename(uri)::String
        # try to analyze untitled editors using the root environment
        env_path = isdefined(state, :root_env_path) ? state.root_env_path : nothing
        pkgname = nothing # to hit the `@goto analyze_script` case
    else @assert false "Unsupported URI: $uri" end

    if env_path === nothing
        @label analyze_script
        if env_path !== nothing
            entry = ScriptInEnvAnalysisEntry(env_path, uri)
            info = FullAnalysisInfo(entry, token, #=reanalyze=#false, #=n_files=#0)
            result = activate_do(env_path) do
                analyze_parsed_if_exist(server, info)
            end
        else
            entry = ScriptAnalysisEntry(uri)
            info = FullAnalysisInfo(entry, token, #=reanalyze=#false, #=n_files=#0)
            result = analyze_parsed_if_exist(server, info)
        end
        analysis_context = new_analysis_context(entry, result)
        @assert uri in analyzed_file_uris(analysis_context)
        record_reverse_map!(state, analysis_context)
    elseif pkgname === nothing
        @goto analyze_script
    else # this file is likely one within a package
        filekind, filedir = find_package_directory(path, env_path)
        if filekind === :script
            @goto analyze_script
        elseif filekind === :src
            # analyze package source files
            entry_result = activate_do(env_path) do
                pkgenv = Base.identify_package_env(pkgname)
                if pkgenv === nothing
                    @warn "Failed to identify package environment" pkgname
                    return nothing
                end
                pkgid, env = pkgenv
                pkgfile = Base.locate_package(pkgid, env)
                if pkgfile === nothing
                    @warn "Expected a package to have a source file" pkgname
                    return nothing
                end
                pkgfileuri = filepath2uri(pkgfile)
                entry = PackageSourceAnalysisEntry(env_path, pkgfileuri, pkgid)
                info = FullAnalysisInfo(entry, token, #=reanalyze=#false, #=n_files=#0)
                res = analyze_parsed_if_exist(server, info, pkgid;
                    analyze_from_definitions=true,
                    concretization_patterns=[:(x_)])
                return entry, res
            end
            if entry_result === nothing
                @goto analyze_script
            end
            entry, result = entry_result
            analysis_context = new_analysis_context(entry, result)
            record_reverse_map!(state, analysis_context)
            if uri ∉ analyzed_file_uris(analysis_context)
                @goto analyze_script
            end
        elseif filekind === :test
            # analyze test scripts
            runtestsfile = joinpath(filedir, "runtests.jl")
            runtestsuri = filepath2uri(runtestsfile)
            entry = PackageTestAnalysisEntry(env_path, runtestsuri)
            info = FullAnalysisInfo(entry, token, #=reanalyze=#false, #=n_files=#0)
            result = activate_do(env_path) do
                analyze_parsed_if_exist(server, info)
            end
            analysis_context = new_analysis_context(entry, result)
            record_reverse_map!(state, analysis_context)
            if uri ∉ analyzed_file_uris(analysis_context)
                @goto analyze_script
            end
        elseif filekind === :docs
            @goto analyze_script # TODO
        else
            @assert filekind === :ext
            @goto analyze_script # TODO
        end
    end

    return analysis_context
end

function reanalyze_with_context!(server::Server, analysis_context::AnalysisContext; token::Union{Nothing,ProgressToken}=nothing)
    state = server.state
    analysis_result = analysis_context.result
    if !(analysis_result.staled)
        return nothing
    end

    any_parse_failed = any(analyzed_file_uris(analysis_context)) do uri::URI
        if haskey(state.saved_file_cache, uri)
            file_info = state.saved_file_cache[uri]
            if !isempty(file_info.parsed_stream.diagnostics)
                return true
            end
        end
        return false
    end
    if any_parse_failed
        # TODO Allow running the full analysis even with any parse errors?
        return nothing
    end

    entry = analysis_context.entry
    n_files = length(values(analysis_context.result.successfully_analyzed_file_infos))
    if entry isa ScriptAnalysisEntry
        info = FullAnalysisInfo(entry, token, #=reanalyze=#true, n_files)
        result = analyze_parsed_if_exist(server, info)
    elseif entry isa ScriptInEnvAnalysisEntry
        info = FullAnalysisInfo(entry, token, #=reanalyze=#true, n_files)
        result = activate_do(entry.env_path) do
            analyze_parsed_if_exist(server, info)
        end
    elseif entry isa PackageSourceAnalysisEntry
        info = FullAnalysisInfo(entry, token, #=reanalyze=#true, n_files)
        result = activate_do(entry.env_path) do
            analyze_parsed_if_exist(server, info, entry.pkgid;
                    analyze_from_definitions=true,
                    concretization_patterns=[:(x_)])
        end
    elseif entry isa PackageTestAnalysisEntry
        info = FullAnalysisInfo(entry, token, #=reanalyze=#true, n_files)
        result = activate_do(entry.env_path) do
            analyze_parsed_if_exist(server, info)
        end
    else
        @warn "Unsupported analysis entry" entry
        return ResponseError(;
            code = ErrorCodes.ServerCancelled,
            message = "Unsupported analysis entry",
            data = DiagnosticServerCancellationData(;
                retriggerRequest = false))
    end

    update_analysis_context!(analysis_context, result)
    record_reverse_map!(state, analysis_context)

    return analysis_context
end
