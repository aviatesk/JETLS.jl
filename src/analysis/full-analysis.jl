function start_analysis_workers!(server::Server)
    for i = 1:length(server.state.analysis_manager.worker_tasks)
        server.state.analysis_manager.worker_tasks[i] = Threads.@spawn :default try
            analysis_worker(server)
        catch err
            @error "Critical error happened in analysis worker"
            Base.display_error(stderr, err, catch_backtrace())
        end
    end
end

get_analysis_info(manager::AnalysisManager, uri::URI) = get(load(manager.cache), uri, nothing)

function request_analysis!(
        server::Server, uri::URI;
        onsave::Bool = false,
        token::Union{Nothing,ProgressToken} = nothing,
        cancel_flag::CancelFlag = CancelFlag(false),
        notify::Bool = true, # used by tests
        wait::Bool = false,  # used by tests
    )
    manager = server.state.analysis_manager
    analysis_info = get_analysis_info(server.state.analysis_manager, uri)
    prev_analysis_result = nothing
    if isnothing(analysis_info)
        entry = lookup_analysis_entry(server.state, uri)
    elseif analysis_info isa OutOfScope
        entry = analysis_info
    else
        analysis_result = analysis_info::AnalysisResult # cached analysis result
        entry = analysis_result.entry
        prev_analysis_result = analysis_result
    end

    if entry isa OutOfScope
        local outofscope = entry
        store!(manager.cache) do cache
            if get(cache, uri, nothing) === outofscope
                cache, nothing
            else
                local new_cache = copy(cache)
                new_cache[uri] = outofscope
                new_cache, nothing
            end
        end
        return nothing
    end
    entry = entry::AnalysisEntry

    if onsave
        generation = increment_generation!(manager, entry)
    else
        generation = get_generation(manager, entry)
    end

    completion = Channel{Nothing}(1)
    request = AnalysisRequest(
        entry, uri, generation, token, notify, prev_analysis_result, completion)

    # Check if already analyzing and handle pending requests
    should_queue = store!(manager.pending_analyses) do analyses
        if haskey(analyses, request.entry)
            # Replace any existing pending request with this new one
            local new_analyses = copy(analyses)
            new_analyses[request.entry] = request
            new_analyses, false  # Don't queue - just update pending
        else
            analyses, true  # Not analyzing - should queue
        end
    end
    should_queue || @goto wait_or_return # Request saved as pending

    debounce = get_config(server.state.config_manager, "full_analysis", "debounce")
    if onsave && debounce isa Float64 && debounce > 0
        local delay::Float64 = debounce
        store!(manager.debounced) do debounced
            # Cancel existing timer if any
            if haskey(debounced, request.entry)
                close(debounced[request.entry])
            end
            local new_debounced = copy(debounced)
            # Set debounce timer
            new_debounced[request.entry] = Timer(delay) do _
                store!(manager.debounced) do debounced′
                    local new_debounced′ = copy(debounced′)
                    delete!(new_debounced′, request.entry)
                    return new_debounced′, nothing
                end
                # Queue the request after debounce period
                queue_request!(manager, request)
            end
            return new_debounced, nothing
        end
    else
        queue_request!(manager, request)
    end

    @label wait_or_return
    wait && take!(completion)
    nothing
end

function queue_request!(manager::AnalysisManager, request::AnalysisRequest)
    store!(manager.pending_analyses) do analyses
        new_analyses = copy(analyses)
        new_analyses[request.entry] = nothing  # Mark as analyzing, no pending yet
        return new_analyses, nothing
    end
    put!(manager.queue, request)
end

 # Analysis queue processing implementation (analysis serialized per AnalysisEntry)
function analysis_worker(server::Server)
    # Note: Currently single worker, but designed for future multi-worker scaling.
    # When multiple workers exist, the per-entry serialization ensures correctness.

    manager = server.state.analysis_manager

    while true
        request = take!(manager.queue)

        is_staled_request(manager, request) || @goto next_request # skip analysis if the analyzed generation is still latest

        has_any_parse_errors(server, request) && @goto next_request

        analysis_result = @something try
            execute_analysis_request(server, request)
        catch err
            @error "Error in `execute_analysis_request` for " request
            Base.display_error(stderr, err, catch_backtrace())
            nothing
        end @goto next_request

        update_analysis_cache!(manager, analysis_result)
        mark_analyzed_generation!(manager, request)
        request.notify && notify_diagnostics!(server)

        @label next_request

        put!(request.completion, nothing) # Notify the completion callback

        # Check for pending request and re-queue if needed
        pending_request = store!(manager.pending_analyses) do analyses
            if haskey(analyses, request.entry)
                new_analyses = copy(analyses)
                pending = pop!(new_analyses, request.entry)
                if pending !== nothing
                    # Re-mark as analyzing before queueing the pending request
                    new_analyses[request.entry] = nothing
                end
                return new_analyses, pending
            end
            return analyses, nothing
        end
        if pending_request !== nothing
            put!(manager.queue, pending_request)
        end

        GC.safepoint()
    end
end

function increment_generation!(manager::AnalysisManager, @nospecialize entry::AnalysisEntry)
    some = Some{AnalysisEntry}(entry)
    store!(manager.current_generations) do generations
        new_generations = copy(generations)
        generation = get(new_generations, some.value, 0) + 1
        new_generations[some.value] = generation
        return new_generations, generation
    end
end

get_generation(manager::AnalysisManager, @nospecialize entry::AnalysisEntry) =
    get(load(manager.current_generations), entry, 0)

function is_staled_request(manager::AnalysisManager, request::AnalysisRequest)
    analyzed_generation = get(load(manager.analyzed_generations), request.entry, -1)
    return analyzed_generation != request.generation
end

function has_any_parse_errors(server::Server, request::AnalysisRequest)
    prev_analysis_result = @something request.prev_analysis_result return false # fresh analysis, no knowledge about the sources
    return any(analyzed_file_uris(prev_analysis_result)) do uri::URI
        saved_fi = @something get_saved_file_info(server.state, uri) return false
        return !isempty(saved_fi.parsed_stream.diagnostics)
    end
end

function update_analysis_cache!(manager::AnalysisManager, analysis_result::AnalysisResult)
    analyzed_uris = analyzed_file_uris(analysis_result)
    store!(manager.cache) do cache
        new_cache = copy(cache)
        for uri in analyzed_uris
            new_cache[uri] = analysis_result
        end
        return new_cache, nothing
    end
end

function mark_analyzed_generation!(manager::AnalysisManager, request::AnalysisRequest)
    store!(manager.analyzed_generations) do generations
        new_generations = copy(generations)
        new_generations[request.entry] = request.generation
        return new_generations, nothing
    end
end

function begin_full_analysis_progress(server::Server, request::AnalysisRequest)
    token = @something request.token return nothing
    filename = uri2filename(entryuri(request.entry))
    pre = isnothing(request.prev_analysis_result) ? "Analyzing" : "Reanalyzing"
    title = "$(pre) $(basename(filename)) [$(entrykind(request.entry))]"
    send(server, ProgressNotification(;
        params = ProgressParams(;
            token,
            value = WorkDoneProgressBegin(;
                title,
                cancellable = true,
                message = "Full analysis initiated",
                percentage = 0))))
    yield_to_endpoint()
end

function end_full_analysis_progress(server::Server, request::AnalysisRequest)
    token = @something request.token return nothing
    send(server, ProgressNotification(;
        params = ProgressParams(;
            token,
            value = WorkDoneProgressEnd(;
                message = "Full analysis finished"))))
end

function analyze_parsed_if_exist(server::Server, request::AnalysisRequest, args...)
    uri = entryuri(request.entry)
    jetconfigs = entryjetconfigs(request.entry)
    fi = get_saved_file_info(server.state, uri)
    if !isnothing(fi)
        filename = @something uri2filename(uri) error(lazy"Unsupported URI: $uri")
        parsed = fi.syntax_node
        begin_full_analysis_progress(server, request)
        try
            return JET.analyze_and_report_expr!(LSInterpreter(server, request), parsed, filename, args...; jetconfigs...)
        finally
            end_full_analysis_progress(server, request)
        end
    else
        filepath = @something uri2filepath(uri) error(lazy"Unsupported URI: $uri")
        begin_full_analysis_progress(server, request)
        try
            return JET.analyze_and_report_file!(LSInterpreter(server, request), filepath, args...; jetconfigs...)
        finally
            end_full_analysis_progress(server, request)
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

function new_analysis_result(request::AnalysisRequest, result)
    analyzed_file_infos = Dict{URI,JET.AnalyzedFileInfo}(
        # `filepath` is an absolute path (since `path` is specified as absolute)
        filename2uri(filepath) => analyzed_file_info
        for (filepath, analyzed_file_info) in result.res.analyzed_files)

    uri2diagnostics = jet_result_to_diagnostics(keys(analyzed_file_infos), result)

    (; entry, prev_analysis_result) = request
    if !is_full_analysis_successful(result) && !isnothing(prev_analysis_result)
        (; actual2virtual, analyzer, analyzed_file_infos) = prev_analysis_result
    else
        actual2virtual = result.res.actual2virtual::JET.Actual2Virtual
        analyzer = update_analyzer_world(result.analyzer)
    end

    return AnalysisResult(entry, uri2diagnostics, analyzer, analyzed_file_infos, actual2virtual)
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
        return @something activate_do(env_path) do
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
        end ScriptInEnvAnalysisEntry(env_path, uri)
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

function execute_analysis_request(server::Server, request::AnalysisRequest)
    entry = request.entry

    if entry isa ScriptAnalysisEntry
        result = analyze_parsed_if_exist(server, request)

    elseif entry isa ScriptInEnvAnalysisEntry
        result = activate_do(entryenvpath(entry)) do
            analyze_parsed_if_exist(server, request)
        end

    elseif entry isa PackageSourceAnalysisEntry
        result = activate_do(entryenvpath(entry)) do
            analyze_parsed_if_exist(server, request, entry.pkgid)
        end

    elseif entry isa PackageTestAnalysisEntry
        result = activate_do(entryenvpath(entry)) do
            analyze_parsed_if_exist(server, request)
        end

    else error("Unsupported analysis entry $entry") end

    ret = new_analysis_result(request, result)

    # TODO Request fallback analysis in cases this script was not analyzed by the analysis entry
    # request.uri ∉ analyzed_file_uris(ret)
    return ret
end
