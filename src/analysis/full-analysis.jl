# Progress support
# ================

struct InstantiationRequest
    env_path::String
    pkgname::Union{Nothing,String}
    filekind::Symbol                 # :script, :src, :test
    filedir::String                  # used for :test to construct runtestsuri
    root_path::Union{String,Nothing} # used for progress
end

struct InstantiationProgressCaller <: RequestCaller
    uri::URI
    ins_request::InstantiationRequest
    onsave::Bool
    notify_diagnostics::Bool
    token::ProgressToken
end

struct AnalysisProgressCaller <: RequestCaller
    uri::URI
    onsave::Bool
    entry::AnalysisEntry
    prev_analysis_result::Union{Nothing,AnalysisResult}
    notify_diagnostics::Bool
    token::ProgressToken
end
cancellable_token(rc::AnalysisProgressCaller) = rc.token

function request_instantiation_progress!(
        server::Server, uri::URI, ins_request::InstantiationRequest,
        onsave::Bool, notify_diagnostics::Bool
    )
    id = String(gensym(:WorkDoneProgressCreateRequest_instantiation))
    token = String(gensym(:InstantiationProgress))
    addrequest!(server, id => InstantiationProgressCaller(uri, ins_request, onsave, notify_diagnostics, token))
    params = WorkDoneProgressCreateParams(; token)
    send(server, WorkDoneProgressCreateRequest(; id, params))
end

function handle_instantiation_progress_response(server::Server, caller::InstantiationProgressCaller)
    (; uri, ins_request, onsave, notify_diagnostics, token) = caller
    entry = do_instantiation_with_progress(server, uri, ins_request, token)
    # Now request a new progress token for the analysis phase
    request_analysis_progress!(server, uri, onsave, entry, #=prev_analysis_result=#nothing, notify_diagnostics)
end

function request_analysis_progress!(
        server::Server, uri::URI, onsave::Bool, @nospecialize(entry::AnalysisEntry),
        prev_analysis_result::Union{Nothing,AnalysisResult},
        notify_diagnostics::Bool
    )
    id = String(gensym(:WorkDoneProgressCreateRequest_analysis))
    token = String(gensym(:AnalysisProgress))
    addrequest!(server, id => AnalysisProgressCaller(
        uri, onsave, entry, prev_analysis_result, notify_diagnostics, token))
    params = WorkDoneProgressCreateParams(; token)
    send(server, WorkDoneProgressCreateRequest(; id, params))
end

function handle_analysis_progress_response(
        server::Server, caller::AnalysisProgressCaller, cancel_flag::CancelFlag
    )
    (; uri, onsave, entry, prev_analysis_result, notify_diagnostics, token) = caller
    cancellable_token = CancellableToken(token, cancel_flag)
    schedule_analysis!(
        server, uri, entry, prev_analysis_result, onsave;
        cancellable_token, notify_diagnostics)
end

# Analysis worker
# ===============

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

# Analysis worker pipeline
# ========================

"""
    request_analysis!(server, uri, onsave; wait=false, notify_diagnostics=true)

Driver function that requests full-analysis for a file.

When the client supports `window/workDoneProgress` and `wait=false`, this function issues
server-initiated progress tokens for both environment instantiation (if needed) and the
subsequent analysis phase, then returns immediately. The actual work is performed
asynchronously when the client confirms each progress token.

When `wait=true` or progress is not supported, the function performs the work synchronously
and blocks until analysis completes.

The `onsave` parameter affects generation management: when `true`, the generation counter
is incremented to ensure analysis runs even if the file content hasn't changed since the
last analysis (useful for save-triggered re-analysis).

The `notify_diagnostics` parameter controls whether to send diagnostic notifications after
analysis completes (used by tests to suppress notifications).
"""
function request_analysis!(
        server::Server, uri::URI, onsave::Bool;
        wait::Bool = false,
        notify_diagnostics::Bool = true
    )
    manager = server.state.analysis_manager
    prev_analysis_result = get_analysis_info(manager, uri)

    if prev_analysis_result isa OutOfScope
        cache_out_of_scope!(manager, uri, prev_analysis_result)
        return nothing
    end

    local entry::AnalysisEntry
    if prev_analysis_result isa AnalysisResult
        entry = prev_analysis_result.entry
    else
        # prev_analysis_result === nothing: fresh analysis
        phase1_result = lookup_analysis_entry(server, uri)
        if phase1_result isa OutOfScope
            cache_out_of_scope!(manager, uri, phase1_result)
            return nothing
        elseif phase1_result isa InstantiationRequest
            if !wait && supports(server, :window, :workDoneProgress)
                request_instantiation_progress!(server, uri, phase1_result, onsave, notify_diagnostics)
                return nothing
            else
                entry = do_instantiation(server, uri, phase1_result)
            end
        else
            entry = phase1_result::AnalysisEntry
        end
    end

    if !wait && supports(server, :window, :workDoneProgress)
        request_analysis_progress!(server, uri, onsave, entry, prev_analysis_result, notify_diagnostics)
    else
        completion = Base.Event()
        schedule_analysis!(server, uri, entry, prev_analysis_result, onsave; completion, notify_diagnostics)
        wait && Base.wait(completion)
    end
end

get_analysis_info(manager::AnalysisManager, uri::URI) = get(load(manager.cache), uri, nothing)

function cache_out_of_scope!(manager::AnalysisManager, uri::URI, outofscope::OutOfScope)
    store!(manager.cache) do cache
        if get(cache, uri, nothing) === outofscope
            cache, nothing
        else
            local new_cache = copy(cache)
            new_cache[uri] = outofscope
            new_cache, nothing
        end
    end
end

"""
    schedule_analysis!(server, uri, entry, prev_analysis_result, onsave; ...)

Schedule analysis for a confirmed entry. This is called after entry lookup is complete.
Handles generation management, debouncing, and queueing.

The `pending_analyses` mechanism ensures that analyses for the same `AnalysisEntry` are
serialized (never run concurrently), which is essential for correctness when multiple
analysis workers exist. When a new request arrives while an entry is being analyzed,
it's stored as pending rather than queued, and processed after the current analysis
completes. This also provides optimization by coalescing rapid successive requests
(e.g., from frequent saves) - only the latest pending request is kept.

The `generation` check (`is_generation_analyzed`) is a related but separate optimization
that skips analysis when the file content hasn't changed since the last analysis.

See https://publish.obsidian.md/jetls/work/JETLS/Make+JETLS+multithreaded#4.%20Multithreading%20Full-Analysis
for the details of this concurrent analysis management.
"""
function schedule_analysis!(
        server::Server, uri::URI, @nospecialize(entry::AnalysisEntry),
        prev_analysis_result::Union{Nothing,AnalysisResult}, onsave::Bool;
        completion::Base.Event = Base.Event(),
        cancellable_token::Union{Nothing,CancellableToken} = nothing,
        notify_diagnostics::Bool = true,
    )
    manager = server.state.analysis_manager

    if onsave
        generation = increment_generation!(manager, entry)
    else
        generation = get_generation(manager, entry)
    end

    request = AnalysisRequest(
        entry, uri, generation, cancellable_token, notify_diagnostics,
        prev_analysis_result, completion)

    debounce = get_config(server.state.config_manager, :full_analysis, :debounce)
    if onsave && debounce > 0
        local delay::Float64 = debounce
        store!(manager.debounced) do debounced
            if haskey(debounced, request.entry)
                # Cancel existing timer if any
                debounce_timer, debounce_completion = debounced[request.entry]
                close(debounce_timer)
                JETLS_DEV_MODE && @info "Cancelled analysis debounce timer:" entry=progress_title(request.entry) uri
                notify(debounce_completion)
            end
            local new_debounced = copy(debounced)
            timer = Timer(delay) do _
                store!(manager.debounced) do debounced′
                    local new_debounced′ = copy(debounced′)
                    delete!(new_debounced′, request.entry)
                    return new_debounced′, nothing
                end
                queue_request!(server, request)
            end
            new_debounced[request.entry] = timer, request.completion
            return new_debounced, nothing
        end
    else
        queue_request!(server, request)
    end
end

function queue_request!(server::Server, request::AnalysisRequest)
    manager = server.state.analysis_manager
    # Check if already analyzing and handle pending requests.
    # This check must happen here (after debounce) rather than in request_analysis!,
    # otherwise multiple debounced requests for the same entry could all pass the check
    # and end up in the queue, causing duplicate analyses with multiple workers.
    should_queue = store!(manager.pending_analyses) do analyses
        if haskey(analyses, request.entry)
            # Already analyzing - store as pending (replaces any existing pending request)
            old_request = analyses[request.entry]
            local new_analyses = copy(analyses)
            new_analyses[request.entry] = request
            if old_request !== nothing # replaced by the new request i.e. cancelled
                JETLS_DEV_MODE && @info "Cancelled staled pending analysis request:" entry=progress_title(request.entry) request.uri
                notify(old_request.completion)
            end
            return new_analyses, false
        else
            # Not analyzing - mark as analyzing and queue
            local new_analyses = copy(analyses)
            new_analyses[request.entry] = nothing
            return new_analyses, true
        end
    end
    if should_queue
        put!(manager.queue, request)
    end
end

function resolve_analysis_request(server::Server, request::AnalysisRequest)
    manager = server.state.analysis_manager

    if is_generation_analyzed(manager, request)
        # Skip if this generation was already analyzed (no new changes since last analysis)
        JETLS_DEV_MODE && @info "Skipped analysis for unchanged analysis unit" entry=progress_title(request.entry) request.uri
        @goto next_request
    end

    if has_any_parse_errors(server, request)
        JETLS_DEV_MODE && @info "Requested analysis unit has parse errors" entry=progress_title(request.entry) request.uri
        @goto next_request
    end

    initial_analysis = request.prev_analysis_result === nothing
    cancellable_token = request.cancellable_token
    if cancellable_token !== nothing
        begin_full_analysis_progress(server, cancellable_token, request.entry, initial_analysis)
    end

    analysis_result = try
        execute_analysis_request(server, request)
    catch err
        @error "Error in `execute_analysis_request` for " request
        Base.display_error(stderr, err, catch_backtrace())
        @goto next_request
    finally
        if cancellable_token !== nothing
            end_full_analysis_progress(server, cancellable_token)
        end
    end

    update_analysis_cache!(manager, analysis_result)
    mark_analyzed_generation!(manager, request)
    request.notify_diagnostics && notify_diagnostics!(server)

    # Request diagnostic refresh for initial full-analysis completion.
    # This ensures that clients using pull diagnostics (textDocument/diagnostic) will
    # re-request diagnostics now that module context is available, allowing
    # lowering/macro-expansion-error diagnostics to be properly reported.
    if initial_analysis && supports(server, :workspace, :diagnostics, :refreshSupport)
        request_diagnostic_refresh!(server)
    end

    @label next_request

    notify(request.completion)

    # Check for pending request and re-queue if exist
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

function is_generation_analyzed(manager::AnalysisManager, request::AnalysisRequest)
    analyzed_generation = get(load(manager.analyzed_generations), request.entry, -1)
    return analyzed_generation == request.generation
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

function execute_analysis_request(server::Server, request::AnalysisRequest)
    entry = request.entry

    if entry isa ScriptAnalysisEntry
        result = analyze_parsed_if_exist(server, request)

    elseif entry isa ScriptInEnvAnalysisEntry
        result = activate_do(entry.env_path) do
            analyze_parsed_if_exist(server, request)
        end

    elseif entry isa PackageSourceAnalysisEntry
        result = activate_do(entry.env_path) do
            analyze_parsed_if_exist(server, request, entry.pkgid)
        end

    elseif entry isa PackageTestAnalysisEntry
        result = activate_do(entry.env_path) do
            analyze_parsed_if_exist(server, request)
        end

    else error("Unsupported analysis entry $entry") end

    ret = new_analysis_result(request, result)

    # TODO Request fallback analysis in cases this script was not analyzed by the analysis entry
    # request.uri ∉ analyzed_file_uris(ret)
    return ret
end

function begin_full_analysis_progress(
        server::Server, cancellable_token::CancellableToken,
        @nospecialize(entry::AnalysisEntry), initial_analysis::Bool,
    )
    title = (initial_analysis ? "Analyzing" : "Reanalyzing") * " " * progress_title(entry)
    send_progress(server, cancellable_token.token,
        WorkDoneProgressBegin(;
            title,
            cancellable = true,
            message = "Analysis started",
            percentage = 0))
    yield_to_endpoint()
end

function end_full_analysis_progress(server::Server, cancellable_token::CancellableToken)
    send_progress(server, cancellable_token.token,
        WorkDoneProgressEnd(; message = "Analysis completed"))
end

function analyze_parsed_if_exist(server::Server, request::AnalysisRequest, args...)
    uri = entryuri(request.entry)
    jetconfigs = getjetconfigs(request.entry)
    fi = get_saved_file_info(server.state, uri)
    if !isnothing(fi)
        filename = @something uri2filename(uri) error(lazy"Unsupported URI: $uri")
        return JET.analyze_and_report_expr!(LSInterpreter(server, request), fi.syntax_node, filename, args...; jetconfigs...)
    else
        filepath = @something uri2filepath(uri) error(lazy"Unsupported URI: $uri")
        return JET.analyze_and_report_file!(LSInterpreter(server, request), filepath, args...; jetconfigs...)
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

# Analysis entry lookup
# =====================

entryuri(entry::AnalysisEntry) = entryuri_impl(entry)::URI
progress_title(entry::AnalysisEntry) = progress_title_impl(entry)::String
getjetconfigs(entry::AnalysisEntry) = getjetconfigs_impl(entry)::Dict{Symbol,Any}

let default_jetconfigs = Dict{Symbol,Any}(
        :toplevel_logger => nothing,
        # force concretization of documentation
        :concretization_patterns => [:($(Base.Docs.doc!)(xs__))])
    global getjetconfigs_impl(::AnalysisEntry) = default_jetconfigs
end

struct ScriptAnalysisEntry <: AnalysisEntry
    uri::URI
end
entryuri_impl(entry::ScriptAnalysisEntry) = entry.uri
progress_title_impl(entry::ScriptAnalysisEntry) = basename(uri2filename(entry.uri)) * " [no env]"

struct ScriptInEnvAnalysisEntry <: AnalysisEntry
    env_path::String
    uri::URI
end
entryuri_impl(entry::ScriptInEnvAnalysisEntry) = entry.uri
progress_title_impl(entry::ScriptInEnvAnalysisEntry) = basename(uri2filename(entry.uri)) * " [in env]"

struct PackageSourceAnalysisEntry <: AnalysisEntry
    env_path::String
    pkgfileuri::URI
    pkgid::Base.PkgId
end
entryuri_impl(entry::PackageSourceAnalysisEntry) = entry.pkgfileuri
progress_title_impl(entry::PackageSourceAnalysisEntry) = entry.pkgid.name * ".jl" * " [package]"
let jetconfigs = Dict{Symbol,Any}(
        :toplevel_logger => nothing,
        :analyze_from_definitions => true,
        :concretization_patterns => [:(x_)])
    global getjetconfigs_impl(::PackageSourceAnalysisEntry) = jetconfigs
end

struct PackageTestAnalysisEntry <: AnalysisEntry
    env_path::String
    runtestsuri::URI
    pkgid::Base.PkgId
end
entryuri_impl(entry::PackageTestAnalysisEntry) = entry.runtestsuri
progress_title_impl(entry::PackageTestAnalysisEntry) = entry.pkgid.name * ".jl" * " [package test]"

"""
    lookup_analysis_entry(server, uri) -> AnalysisEntry | InstantiationRequest | OutOfScope

Phase 1 of analysis entry lookup. Returns immediately without blocking.
- If no instantiation is needed (cached or no env), returns an `AnalysisEntry` directly.
- If instantiation is needed, returns `InstantiationRequest` with the information required
  to perform instantiation in phase 2 (`do_instantiation` or `do_instantiation_with_progress`).
- If the file is out of scope, returns `OutOfScope`.
"""
function lookup_analysis_entry(server::Server, uri::URI)
    state = server.state
    maybe_env_path = find_analysis_env_path(state, uri)
    if maybe_env_path isa OutOfScope
        return maybe_env_path
    end

    root_path = isdefined(state, :root_path) ? state.root_path : nothing

    env_path = maybe_env_path
    if isnothing(env_path)
        return ScriptAnalysisEntry(uri)
    elseif uri.scheme == "untitled"
        if is_env_cached(server, env_path)
            return ScriptInEnvAnalysisEntry(env_path, uri)
        else
            return InstantiationRequest(env_path, nothing, :script, "", root_path)
        end
    end

    pkgname = find_pkg_name(env_path)
    filepath = uri2filepath(uri)::String # uri.scheme == "file"
    if isnothing(pkgname) # TODO Test environment with workspace setup fails here
        if is_env_cached(server, env_path)
            return ScriptInEnvAnalysisEntry(env_path, uri)
        else
            return InstantiationRequest(env_path, nothing, :script, "", root_path)
        end
    end

    filekind, filedir = find_package_directory(filepath, env_path)
    if filekind === :src || filekind === :test
        cached = get_cached_pkg_env(server, env_path)
        if cached !== missing
            if cached === nothing
                return ScriptInEnvAnalysisEntry(env_path, uri)
            else
                pkgid, pkgfile = cached
                if filekind === :src
                    return PackageSourceAnalysisEntry(env_path, filepath2uri(pkgfile), pkgid)
                else
                    runtestsuri = filepath2uri(joinpath(filedir, "runtests.jl"))
                    return PackageTestAnalysisEntry(env_path, runtestsuri, pkgid)
                end
            end
        else
            return InstantiationRequest(env_path, pkgname, filekind, filedir, root_path)
        end
    elseif filekind === :docs # TODO
    elseif filekind === :ext # TODO
    else
        @assert filekind === :script
    end

    if is_env_cached(server, env_path)
        return ScriptInEnvAnalysisEntry(env_path, uri)
    else
        return InstantiationRequest(env_path, nothing, :script, "", root_path)
    end
end

function is_env_cached(server::Server, env_path::String)
    instantiated_envs = server.state.analysis_manager.instantiated_envs
    return haskey(load(instantiated_envs), env_path)
end

function get_cached_pkg_env(server::Server, env_path::String)
    instantiated_envs = server.state.analysis_manager.instantiated_envs
    return get(load(instantiated_envs), env_path, missing)
end

# Environment instantiation
# =========================

function do_instantiation(server::Server, uri::URI, ins_request::InstantiationRequest)
    (; env_path, pkgname, filekind, filedir) = ins_request
    if pkgname === nothing
        ensure_instantiated_if_requested!(server, env_path)
        return ScriptInEnvAnalysisEntry(env_path, uri)
    else
        pkgid, pkgfile = @something(
            instantiate_package_environment!(server, env_path, pkgname),
            return ScriptInEnvAnalysisEntry(env_path, uri))
        if filekind === :src
            return PackageSourceAnalysisEntry(env_path, filepath2uri(pkgfile), pkgid)
        else # :test
            runtestsuri = filepath2uri(joinpath(filedir, "runtests.jl"))
            return PackageTestAnalysisEntry(env_path, runtestsuri, pkgid)
        end
    end
end

function instantiate_package_environment!(server::Server, env_path::String, pkgname::String)
    instantiated_envs = server.state.analysis_manager.instantiated_envs
    activate_do(env_path) do
        # Check cache inside lock to avoid race conditions
        cached = get(load(instantiated_envs), env_path, missing)
        if cached !== missing
            return cached
        end
        # Cache miss - perform environment detection
        ensure_instantiated!(server, env_path)
        pkgenv = @lock Base.require_lock @something Base.identify_package_env(pkgname) begin
            @warn "Failed to identify package environment" env_path pkgname filepath
            return store!(instantiated_envs) do cache
                new_cache = copy(cache)
                new_cache[env_path] = nothing
                new_cache, nothing
            end
        end
        pkgid, env = pkgenv
        pkgfile = @something Base.locate_package(pkgid, env) begin
            @warn "Expected a package to have a source file" pkgname
            return store!(instantiated_envs) do cache
                new_cache = copy(cache)
                new_cache[env_path] = nothing
                new_cache, nothing
            end
        end
        return store!(instantiated_envs) do cache
            new_cache = copy(cache)
            new_cache[env_path] = (pkgid, pkgfile)
            new_cache, (pkgid, pkgfile)
        end
    end
end

function ensure_instantiated_if_requested!(server::Server, env_path::String)
    instantiated_envs = server.state.analysis_manager.instantiated_envs
    activate_do(env_path) do
        # Check if already processed (success or failure)
        if haskey(load(instantiated_envs), env_path)
            return
        end
        ensure_instantiated!(server, env_path)
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

function ensure_instantiated!(server::Server, env_path::String)
    if get_config(server.state.config_manager, :full_analysis, :auto_instantiate)
        try
            JETLS_DEV_MODE && @info "Instantiating package environment" env_path
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
                It is recommended to fix your package environment setup and restart the language server.""")
        end
    else
        is_instantiated = try
            Pkg.Operations.is_instantiated(Pkg.Types.EnvCache(env_path))
        catch e
            @error "Failed to create cache for package environment" env_path
            Base.showerror(stderr, e, catch_backtrace())
            false
        end
        if !is_instantiated
            show_warning_message(server, """
                Package environment at $env_path has not been instantiated
                (`full_analysis.auto_instantiate` is disabled).
                The package will be analyzed as a script, which may result in incomplete diagnostics.
                It is recommended to instantiate your package environment and restart the language server.""")
        end
    end
end

# Resolves the delayed environment instantiation with progress reporting.
# Called after receiving confirmation for server-initiated progress token.
function do_instantiation_with_progress(
        server::Server, uri::URI, ins_request::InstantiationRequest, token::ProgressToken
    )
    root_path = ins_request.root_path
    message_path = isnothing(root_path) ? ins_request.env_path :
        relpath(ins_request.env_path, dirname(root_path))
    send_progress(server, token,
        WorkDoneProgressBegin(;
            title = "Instantiating environment",
            message = message_path,
            cancellable = false))
    entry = do_instantiation(server, uri, ins_request)
    send_progress(server, token, WorkDoneProgressEnd())
    return entry
end
