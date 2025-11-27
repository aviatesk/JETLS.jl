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

struct RequestAnalysisCaller <: RequestCaller
    uri::URI
    onsave::Bool
    token::ProgressToken
end
cancellable_token(rc::RequestAnalysisCaller) = rc.token

function request_analysis_on_open!(server::Server, uri::URI)
    if supports(server, :window, :workDoneProgress)
        id = String(gensym(:WorkDoneProgressCreateRequest_request_analysis_on_open!))
        token = String(gensym(:WorkDoneProgressCreateRequest_request_analysis_on_open!))
        addrequest!(server, id=>RequestAnalysisCaller(uri, #=onsave=#false, token))
        params = WorkDoneProgressCreateParams(; token)
        send(server, WorkDoneProgressCreateRequest(; id, params))
    else
        request_analysis!(server, uri)
    end
end

function request_analysis_on_save!(server::Server, uri::URI)
    if supports(server, :window, :workDoneProgress)
        id = String(gensym(:WorkDoneProgressCreateRequest_request_analysis_on_save!))
        token = String(gensym(:WorkDoneProgressCreateRequest_request_analysis_on_save!))
        addrequest!(server, id=>RequestAnalysisCaller(uri, #=onsave=#true, token))
        params = WorkDoneProgressCreateParams(; token)
        send(server, WorkDoneProgressCreateRequest(; id, params))
    else
        request_analysis!(server, uri; onsave=true)
    end
end

function handle_request_analysis_response(
        server::Server, request_caller::RequestAnalysisCaller, cancel_flag::CancelFlag
    )
    (; uri, onsave, token) = request_caller
    cancellable_token = CancellableToken(token, cancel_flag)
    # Each response message handler needs to be written synchronously, so we use `wait=true`
    request_analysis!(server, uri; cancellable_token, onsave, wait=true)
end

function request_analysis!(
        server::Server, uri::URI;
        cancellable_token::Union{Nothing,CancellableToken} = nothing,
        onsave::Bool = false,
        wait::Bool = false,
        notify::Bool = true, # used by tests
    )
    manager = server.state.analysis_manager
    prev_analysis_result = get_analysis_info(server.state.analysis_manager, uri)
    local outofscope::OutOfScope
    if isnothing(prev_analysis_result)
        entry = lookup_analysis_entry(server, uri)
        if entry isa OutOfScope
            outofscope = entry
            @goto out_of_scope
        end
    elseif prev_analysis_result isa OutOfScope
        outofscope = prev_analysis_result
        @label out_of_scope
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
    else
        prev_analysis_result::AnalysisResult
        entry = prev_analysis_result.entry
    end
    entry = entry::AnalysisEntry

    if onsave
        generation = increment_generation!(manager, entry)
    else
        generation = get_generation(manager, entry)
    end

    completion = Base.Event()
    request = AnalysisRequest(
        entry, uri, generation, cancellable_token, notify, prev_analysis_result, completion)

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

    debounce = get_config(server.state.config_manager, :full_analysis, :debounce)
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
    wait && Base.wait(completion)
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
    while true
        request = take!(server.state.analysis_manager.queue)
        @tryinvokelatest resolve_analysis_request(server, request)
        GC.safepoint()
    end
end

function resolve_analysis_request(server::Server, request::AnalysisRequest)
    manager = server.state.analysis_manager

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

    # Request diagnostic refresh for initial full-analysis completion.
    # This ensures that clients using pull diagnostics (textDocument/diagnostic) will
    # re-request diagnostics now that module context is available, allowing
    # lowering/macro-expansion-error diagnostics to be properly reported.
    if isnothing(request.prev_analysis_result) &&
       supports(server, :workspace, :diagnostics, :refreshSupport)
        request_diagnostic_refresh!(server)
    end

    @label next_request

    notify(request.completion)

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
    cancellable_token = @something request.cancellable_token return nothing
    filename = uri2filename(entryuri(request.entry))
    pre = isnothing(request.prev_analysis_result) ? "Analyzing" : "Reanalyzing"
    title = "$(pre) $(basename(filename)) [$(entrykind(request.entry))]"
    send_progress(server, cancellable_token.token,
        WorkDoneProgressBegin(;
            title,
            cancellable = true,
            message = "Full analysis initiated",
            percentage = 0))
    yield_to_endpoint()
end

function end_full_analysis_progress(server::Server, request::AnalysisRequest)
    cancellable_token = @something request.cancellable_token return nothing
    send_progress(server, cancellable_token.token,
        WorkDoneProgressEnd(; message = "Full analysis finished"))
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
    if !(isempty(result.res.toplevel_error_reports) || isnothing(prev_analysis_result))
        (; actual2virtual, analyzer, analyzed_file_infos) = prev_analysis_result
    else
        actual2virtual = result.res.actual2virtual::JET.Actual2Virtual
        analyzer = update_analyzer_world(result.analyzer)
    end

    return AnalysisResult(entry, uri2diagnostics, analyzer, analyzed_file_infos, actual2virtual)
end

function ensure_instantiated(server::Server, env_path::String, context::String)
    if get_config(server.state.config_manager, :full_analysis, :auto_instantiate)
        try
            JETLS_DEV_MODE && @info "Instantiating package environment" env_path context
            Pkg.instantiate()
        catch e
            @error """Failed to instantiate package environment;
            Unable to instantiate the environment of the target package for analysis,
            so this package will be analyzed as a script instead.
            This may cause various features such as diagnostics to not function properly.
            It is recommended to fix the problem by referring to the following error""" env_path
            Base.showerror(stderr, e, catch_backtrace())
            show_warning_message(server, """
                Failed to instantiate package environment at $env_path.
                The package will be analyzed as a script, which may result in incomplete diagnostics.
                See the language server log for details.
                It is recommended to fix your environment setup and restart the language server.""")
        end
    end
end

function ensure_instantiated_if_needed(server::Server, env_path::String, context::String)
    instantiated_envs = server.state.analysis_manager.instantiated_envs
    activate_do(env_path) do
        # Check if already processed (success or failure)
        if haskey(load(instantiated_envs), env_path)
            return
        end
        ensure_instantiated(server, env_path, context)
        # Mark as processed
        store!(instantiated_envs) do cache
            if haskey(cache, env_path)
                cache, nothing
            else
                new_cache = copy(cache)
                new_cache[env_path] = nothing
                new_cache, nothing
            end
        end
    end
end

function lookup_analysis_entry(server::Server, uri::URI)
    state = server.state
    maybe_env_path = find_analysis_env_path(state, uri)
    if maybe_env_path isa OutOfScope
        outofscope = maybe_env_path
        return outofscope
    end

    env_path = maybe_env_path
    if isnothing(env_path)
        return ScriptAnalysisEntry(uri)
    elseif uri.scheme == "untitled"
        ensure_instantiated_if_needed(server, env_path, "untitled")
        return ScriptInEnvAnalysisEntry(env_path, uri)
    end

    pkgname = find_pkg_name(env_path)
    filepath = uri2filepath(uri)::String # uri.scheme === "file"
    if isnothing(pkgname)
        ensure_instantiated_if_needed(server, env_path, "script: $filepath")
        return ScriptInEnvAnalysisEntry(env_path, uri)
    end
    filekind, filedir = find_package_directory(filepath, env_path)
    if filekind === :src
        instantiated_envs = server.state.analysis_manager.instantiated_envs
        return @something activate_do(env_path) do
            # Check cache inside lock to avoid race conditions
            cached = get(load(instantiated_envs), env_path, missing)
            if cached === nothing
                # Previously failed to detect package environment
                return ScriptInEnvAnalysisEntry(env_path, uri)
            elseif cached !== missing
                pkgid, pkgfileuri = cached
                return PackageSourceAnalysisEntry(env_path, pkgfileuri, pkgid)
            end
            # Cache miss - perform environment detection
            ensure_instantiated(server, env_path, "src: $filepath")
            pkgenv = @lock Base.require_lock @something Base.identify_package_env(pkgname) begin
                @warn "Failed to identify package environment" env_path pkgname filepath
                store!(instantiated_envs) do cache
                    new_cache = copy(cache)
                    new_cache[env_path] = nothing
                    new_cache, nothing
                end
                return nothing
            end
            pkgid, env = pkgenv
            pkgfile = @something Base.locate_package(pkgid, env) begin
                @warn "Expected a package to have a source file" pkgname
                store!(instantiated_envs) do cache
                    new_cache = copy(cache)
                    new_cache[env_path] = nothing
                    new_cache, nothing
                end
                return nothing
            end
            pkgfileuri = filepath2uri(pkgfile)
            store!(instantiated_envs) do cache
                new_cache = copy(cache)
                new_cache[env_path] = (pkgid, pkgfileuri)
                new_cache, nothing
            end
            PackageSourceAnalysisEntry(env_path, pkgfileuri, pkgid)
        end ScriptInEnvAnalysisEntry(env_path, uri)
    elseif filekind === :test
        ensure_instantiated_if_needed(server, env_path, "test: $filepath")
        runtestsfile = joinpath(filedir, "runtests.jl")
        runtestsuri = filepath2uri(runtestsfile)
        return PackageTestAnalysisEntry(env_path, runtestsuri)
    elseif filekind === :docs # TODO
    elseif filekind === :ext # TODO
    else
        @assert filekind === :script
    end
    ensure_instantiated_if_needed(server, env_path, "script: $filepath")
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
