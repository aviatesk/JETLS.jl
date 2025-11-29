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
        Threads.@spawn :default request_analysis!(server, uri)
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
        Threads.@spawn :default request_analysis!(server, uri; onsave=true)
    end
end

function handle_request_analysis_response(
        server::Server, request_caller::RequestAnalysisCaller, cancel_flag::CancelFlag
    )
    (; uri, onsave, token) = request_caller
    cancellable_token = CancellableToken(token, cancel_flag)
    # Each response message should be synchronous, so don't use `Threads.@spawn` here
    request_analysis!(server, uri; cancellable_token, onsave)
end

mutable struct ProgressState
    const cancellable_token::CancellableToken
    begun::Bool
    ProgressState(cancellable_token::CancellableToken) = new(cancellable_token, false)
end

"""
    request_analysis!(server, uri; ...)

Requests full analysis for a file, ensuring per-entry serialization.

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
function request_analysis!(
        server::Server, uri::URI;
        cancellable_token::Union{Nothing,CancellableToken} = nothing,
        kwargs...
    )
    completion = Base.Event()
    try
        _request_analysis!(server, uri, completion; cancellable_token, kwargs...)
        wait(completion)
    finally
        if cancellable_token !== nothing
            end_full_analysis_progress(server, cancellable_token)
        end
    end
end

function _request_analysis!(
        server::Server, uri::URI, completion::Base.Event;
        cancellable_token::Union{Nothing,CancellableToken} = nothing,
        onsave::Bool = false,
        notify_diagnostics::Bool = true, # used by tests
    )
    manager = server.state.analysis_manager
    prev_analysis_result = get_analysis_info(server.state.analysis_manager, uri)
    local outofscope::OutOfScope
    if isnothing(prev_analysis_result)
        progress_state = cancellable_token !== nothing ? ProgressState(cancellable_token) : nothing
        entry = lookup_analysis_entry(server, uri, progress_state)
        if entry isa OutOfScope
            outofscope = entry
            @goto out_of_scope
        end
        if cancellable_token !== nothing && progress_state !== nothing && !progress_state.begun
            begin_full_analysis_progress(server, entry, false, cancellable_token)
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
        if cancellable_token !== nothing
            begin_full_analysis_progress(server, entry, true, cancellable_token)
        end
    end
    entry = entry::AnalysisEntry

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
            # Cancel existing timer if any
            if haskey(debounced, request.entry)
                debounce_timer, debounce_completion = debounced[request.entry]
                close(debounce_timer)
                notify(debounce_completion)
            end
            local new_debounced = copy(debounced)
            # Set debounce timer
            new_debounced[request.entry] = Timer(delay) do _
                store!(manager.debounced) do debounced′
                    local new_debounced′ = copy(debounced′)
                    delete!(new_debounced′, request.entry)
                    return new_debounced′, nothing
                end
                queue_request!(server, request)
            end, request.completion
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

    if is_generation_analyzed(manager, request)
        # Skip if this generation was already analyzed (no new changes since last analysis)
        @goto next_request
    end

    has_any_parse_errors(server, request) && @goto next_request

    analysis_result = try
        execute_analysis_request(server, request)
    catch err
        @error "Error in `execute_analysis_request` for " request
        Base.display_error(stderr, err, catch_backtrace())
        @goto next_request
    end

    update_analysis_cache!(manager, analysis_result)
    mark_analyzed_generation!(manager, request)
    request.notify_diagnostics && notify_diagnostics!(server)

    # Request diagnostic refresh for initial full-analysis completion.
    # This ensures that clients using pull diagnostics (textDocument/diagnostic) will
    # re-request diagnostics now that module context is available, allowing
    # lowering/macro-expansion-error diagnostics to be properly reported.
    if isnothing(request.prev_analysis_result) && supports(server, :workspace, :diagnostics, :refreshSupport)
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

function begin_full_analysis_progress(
        server::Server, @nospecialize(entry::AnalysisEntry), reanalyzing::Bool,
        cancellable_token::CancellableToken
    )
    title = (reanalyzing ? "Reanalyzing" : "Analyzing") * " " * progress_title(entry)
    send_progress(server, cancellable_token.token,
        WorkDoneProgressBegin(;
            title,
            cancellable = true,
            message = "Analysis requested",
            percentage = 0))
    yield_to_endpoint()
end

function begin_full_analysis_progress_by_instantiate(
        server::Server, title::String, progress_state::ProgressState
    )
    send_progress(server, progress_state.cancellable_token.token,
        WorkDoneProgressBegin(;
            title = "Analyzing " * title,
            cancellable = true,
            message = "Instantiating environment",
            percentage = 0))
    progress_state.begun = true
    yield_to_endpoint()
end

function end_full_analysis_progress(server::Server, cancellable_token::CancellableToken)
    send_progress(server, cancellable_token.token,
        WorkDoneProgressEnd(; message = "Full analysis finished"))
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

function ensure_instantiated!(
        server::Server, env_path::String, title::String,
        progress_state::Union{Nothing,ProgressState}
    )
    if get_config(server.state.config_manager, :full_analysis, :auto_instantiate)
        if progress_state !== nothing
            begin_full_analysis_progress_by_instantiate(server, title, progress_state)
        end
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

function ensure_instantiated_if_needed!(
        server::Server, env_path::String, title::String,
        progress_state::Union{Nothing,ProgressState}
    )
    instantiated_envs = server.state.analysis_manager.instantiated_envs
    activate_do(env_path) do
        # Check if already processed (success or failure)
        if haskey(load(instantiated_envs), env_path)
            return
        end
        ensure_instantiated!(server, env_path, title, progress_state)
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

function instantiate_package_environment!(
        server::Server, env_path::String, pkgname::String,
        progress_state::Union{Nothing,ProgressState}
    )
    instantiated_envs = server.state.analysis_manager.instantiated_envs
    activate_do(env_path) do
        # Check cache inside lock to avoid race conditions
        cached = get(load(instantiated_envs), env_path, missing)
        if cached !== missing
            return cached
        end
        # Cache miss - perform environment detection
        ensure_instantiated!(server, env_path, progress_title_for_pkg(pkgname), progress_state)
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
progress_title_impl(entry::ScriptAnalysisEntry) = progress_title_for_uri(entry.uri)
progress_title_for_uri(uri::URI) = basename(uri2filename(uri)) * " [no env]"

struct ScriptInEnvAnalysisEntry <: AnalysisEntry
    env_path::String
    uri::URI
end
entryuri_impl(entry::ScriptInEnvAnalysisEntry) = entry.uri
progress_title_impl(entry::ScriptInEnvAnalysisEntry) = progress_title_for_uri_in_env(entry.uri)
progress_title_for_uri_in_env(uri::URI) = basename(uri2filename(uri)) * " [in env]"

struct PackageSourceAnalysisEntry <: AnalysisEntry
    env_path::String
    pkgfileuri::URI
    pkgid::Base.PkgId
end
entryuri_impl(entry::PackageSourceAnalysisEntry) = entry.pkgfileuri
progress_title_impl(entry::PackageSourceAnalysisEntry) = progress_title_for_pkg(entry.pkgid)
progress_title_for_pkg(pkgid::Base.PkgId) = progress_title_for_pkg(pkgid.name)
progress_title_for_pkg(pkgname::AbstractString) = pkgname * ".jl" * " [package]"
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
progress_title_impl(entry::PackageTestAnalysisEntry) = progress_title_for_pkgtest(entry.pkgid)
progress_title_for_pkgtest(pkgid::Base.PkgId) = pkgid.name * ".jl" * " [package test]"

function lookup_analysis_entry(
        server::Server, uri::URI,
        progress_state::Union{Nothing,ProgressState} = nothing,
    )
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
        ensure_instantiated_if_needed!(server, env_path, progress_title_for_uri_in_env(uri), progress_state)
        return ScriptInEnvAnalysisEntry(env_path, uri)
    end

    pkgname = find_pkg_name(env_path)
    filepath = uri2filepath(uri)::String # uri.scheme == "file"
    if isnothing(pkgname) # TODO Test environment with workspace setup fails here
        ensure_instantiated_if_needed!(server, env_path, progress_title_for_uri_in_env(uri), progress_state)
        return ScriptInEnvAnalysisEntry(env_path, uri)
    end
    filekind, filedir = find_package_directory(filepath, env_path)
    if filekind === :src
        pkgid, pkgfile = @something(
            instantiate_package_environment!(server, env_path, pkgname, progress_state),
            return ScriptInEnvAnalysisEntry(env_path, uri))
        pkgfileuri = filepath2uri(pkgfile)
        return PackageSourceAnalysisEntry(env_path, pkgfileuri, pkgid)
    elseif filekind === :test
        pkgid, _ = @something(
            instantiate_package_environment!(server, env_path, pkgname, progress_state),
            return ScriptInEnvAnalysisEntry(env_path, uri))
        runtestsuri = filepath2uri(joinpath(filedir, "runtests.jl"))
        return PackageTestAnalysisEntry(env_path, runtestsuri, pkgid)
    elseif filekind === :docs # TODO
    elseif filekind === :ext # TODO
    else
        @assert filekind === :script
    end
    ensure_instantiated_if_needed!(server, env_path, progress_title_for_uri_in_env(uri), progress_state)
    return ScriptInEnvAnalysisEntry(env_path, uri)
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
