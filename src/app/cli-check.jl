@enum ProgressMode::Int8 begin
    PROGRESS_AUTO
    PROGRESS_FULL
    PROGRESS_SIMPLE
    PROGRESS_NONE
end

function is_tty(io::IO)
    io isa Base.TTY && return true
    io isa IOContext && return is_tty(io.io)
    return false
end

# Progress context that holds mode and io for unified progress handling
struct ProgressContext{IOTyp<:IO}
    mode::ProgressMode
    io::IOTyp
    function ProgressContext(mode::ProgressMode, io::IOTyp=stderr) where IOTyp<:IO
        effective_mode = mode == PROGRESS_AUTO ? (is_tty(io) ? PROGRESS_FULL : PROGRESS_SIMPLE) : mode
        return new{IOTyp}(effective_mode, io)
    end
end

# Spinner-based progress (PROGRESS_FULL)
const SPINNER_FRAMES = ["⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏"]
const SPINNER_INTERVAL = 0.1

mutable struct SpinnerProgress{IOTyp<:IO}
    const io::IOTyp
    active::Bool
    current_file::String
    current_message::String
    spinner_idx::Int
    last_line_length::Int
    spinner_task::Union{Nothing,Task}
    const lock::ReentrantLock
end

function SpinnerProgress(io::IO)
    return SpinnerProgress(io, false, "", "", 1, 0, nothing, ReentrantLock())
end

function clear_line(p::SpinnerProgress)
    if p.last_line_length > 0
        print(p.io, "\r", " "^p.last_line_length, "\r")
        p.last_line_length = 0
    end
end

function render_spinner(p::SpinnerProgress)
    @lock p.lock begin
        clear_line(p)
        if !p.active
            return
        end
        frame = SPINNER_FRAMES[p.spinner_idx]
        prefix = "$(frame) $(p.current_file)"
        term_width = displaysize(p.io)[2]::Int
        if isempty(p.current_message)
            if length(prefix) > term_width - 1
                prefix = prefix[1:term_width-2] * "…"
            end
            printstyled(p.io, prefix; color=:light_cyan)
            p.last_line_length = length(prefix)
        else
            separator = ": "
            message = p.current_message
            total_len = length(prefix) + length(separator) + length(message)
            if total_len > term_width - 1
                available = term_width - 1 - length(prefix) - length(separator) - 1
                if available > 0
                    message = message[1:min(available, length(message))] * "…"
                else
                    message = "…"
                end
            end
            printstyled(p.io, prefix, separator; color=:light_cyan)
            printstyled(p.io, message; color=:light_black)
            p.last_line_length = length(prefix) + length(separator) + length(message)
        end
    end
end

function start_spinner!(p::SpinnerProgress, file::AbstractString)
    @lock p.lock begin
        p.current_file = file
        p.current_message = ""
    end
    p.active = true
    p.spinner_task = Threads.@spawn :interactive begin
        while p.active
            render_spinner(p)
            sleep(SPINNER_INTERVAL)
            p.spinner_idx = mod1(p.spinner_idx + 1, length(SPINNER_FRAMES))
        end
    end
end

function stop_spinner!(p::SpinnerProgress)
    p.active = false
    spinner_task = p.spinner_task
    if spinner_task !== nothing
        wait(spinner_task)
        p.spinner_task = nothing
    end
    @lock p.lock clear_line(p)
end

function update_spinner!(p::SpinnerProgress, message::AbstractString)
    @lock p.lock p.current_message = message
end

struct SpinnerProgressToken
    progress::SpinnerProgress
end

function send_progress(::Server, token::SpinnerProgressToken, value::WorkDoneProgressValue)
    if (value isa WorkDoneProgressBegin || value isa WorkDoneProgressReport ||
        value isa WorkDoneProgressEnd)
        message = value.message
        if message !== nothing && !isempty(message)
            update_spinner!(token.progress, message)
        end
    end
end

# Simple line-based progress (PROGRESS_SIMPLE)
mutable struct SimpleProgress{IOTyp<:IO}
    const io::IOTyp
    last_phase::String
end
SimpleProgress(io::IO) = SimpleProgress(io, "")

function start_simple!(p::SimpleProgress, prefix::AbstractString, name::AbstractString)
    p.last_phase = ""
    printstyled(p.io, prefix, " ", name; color=:light_cyan)
end

function update_simple!(p::SimpleProgress, phase::AbstractString)
    if phase != p.last_phase
        printstyled(p.io, ' ', phase; color=:light_black)
        p.last_phase = phase
    else
        printstyled(p.io, '.'; color=:light_black)
    end
end

function stop_simple!(p::SimpleProgress)
    printstyled(p.io, " done"; color=:light_black)
    println(p.io)
end

struct SimpleProgressToken
    progress::SimpleProgress
end

function send_progress(::Server, token::SimpleProgressToken, value::WorkDoneProgressValue)
    if value isa WorkDoneProgressBegin
        update_simple!(token.progress, value.title)
    elseif value isa WorkDoneProgressReport
        message = @something value.message return
        if occursin("[file analysis]", message)
            update_simple!(token.progress, "[file analysis]")
        elseif occursin("[signature analysis]", message)
            update_simple!(token.progress, "[signature analysis]")
        elseif occursin("[lowering analysis]", message)
            update_simple!(token.progress, "[lowering analysis]")
        end
    end
end

function with_progress(f::Function, ctx::ProgressContext, prefix::String, name::String)
    if ctx.mode == PROGRESS_FULL
        p = SpinnerProgress(ctx.io)
        start_spinner!(p, "$prefix $name")
        try
            token = SpinnerProgressToken(p)
            return f(CancellableToken(token, DUMMY_CANCEL_FLAG))
        finally
            stop_spinner!(p)
        end
    elseif ctx.mode == PROGRESS_SIMPLE
        p = SimpleProgress(ctx.io)
        start_simple!(p, prefix, name)
        try
            token = SimpleProgressToken(p)
            return f(CancellableToken(token, DUMMY_CANCEL_FLAG))
        finally
            stop_simple!(p)
        end
    else # PROGRESS_NONE
        return f(nothing)
    end
end

const check_help_message = """
    jetls check - Run diagnostics on Julia files

    Analyzes Julia source files and reports errors, warnings, and suggestions.
    Useful for CI pipelines and command-line workflows.

    Analysis mode is determined by the file's directory structure.
    For package analysis, run from the package root: jetls check src/SomePkg.jl

    Usage: jetls check [OPTIONS] <file>...

    Options:
      --help, -h               Show this help message
      --quiet, -q              Suppress info and warning log messages
      --exit-severity=<level>  Minimum severity to exit with error code 1
                               (error, warn, info, hint; default: warn)
      --show-severity=<level>  Minimum severity to display in output
                               (error, warn, info, hint; default: hint)
      --root=<path>            Set the root path for configuration and relative paths
                               (default: current working directory)
      --context-lines=<n>      Number of context lines to show (default: 2)
      --progress=<mode>        Progress display mode (default: auto)
                               auto   - spinner if TTY, simple otherwise
                               full   - always show spinner
                               simple - one line per file
                               none   - no progress output

    Exit codes:
      0  No diagnostics at or above the exit severity level
      1  One or more diagnostics found, or invalid arguments

    Examples:
      jetls check src/SomePkg.jl
      jetls check src/SomePkg.jl test/runtests.jl
      jetls check --root=/path/to/project src/SomePkg.jl
      jetls check --context-lines=0 src/SomePkg.jl
      jetls check --exit-severity=error src/SomePkg.jl
      jetls check --show-severity=warn src/SomePkg.jl
      jetls check --progress=none src/SomePkg.jl
    """

function run_check(args::Vector{String})::Cint
    root_path_opt = nothing
    context_lines = 2
    exit_severity = DiagnosticSeverity.Warning
    show_severity = DiagnosticSeverity.Hint
    progress_mode = PROGRESS_AUTO
    skip_analysis = false # Undocumented option to skip analysis (only used for test)
    quiet = false
    paths = String[]
    for arg in args
        if arg in ("--quiet", "-q")
            quiet = true
        elseif startswith(arg, "--root=")
            root_path_opt = arg[8:end]
        elseif startswith(arg, "--context-lines=")
            context_lines = tryparse(Int, arg[17:end])
            if context_lines === nothing
                @error "Invalid value for --context-lines (must be a non-negative integer)"
                return 1
            end
        elseif startswith(arg, "--exit-severity=")
            level = arg[17:end]
            if level in ("error", "1")
                exit_severity = DiagnosticSeverity.Error
            elseif level in ("warn", "warning", "2")
                exit_severity = DiagnosticSeverity.Warning
            elseif level in ("info", "information", "3")
                exit_severity = DiagnosticSeverity.Information
            elseif level in ("hint", "4")
                exit_severity = DiagnosticSeverity.Hint
            else
                @error "Invalid value for --exit-severity (must be error, warn, info, or hint)"
                return 1
            end
        elseif startswith(arg, "--show-severity=")
            level = arg[17:end]
            if level in ("error", "1")
                show_severity = DiagnosticSeverity.Error
            elseif level in ("warn", "warning", "2")
                show_severity = DiagnosticSeverity.Warning
            elseif level in ("info", "information", "3")
                show_severity = DiagnosticSeverity.Information
            elseif level in ("hint", "4")
                show_severity = DiagnosticSeverity.Hint
            else
                @error "Invalid value for --show-severity (must be error, warn, info, or hint)"
                return 1
            end
        elseif startswith(arg, "--progress=")
            mode = arg[12:end]
            if mode == "auto"
                progress_mode = PROGRESS_AUTO
            elseif mode == "full"
                progress_mode = PROGRESS_FULL
            elseif mode == "simple"
                progress_mode = PROGRESS_SIMPLE
            elseif mode == "none"
                progress_mode = PROGRESS_NONE
            else
                @error "Invalid value for --progress (must be auto, full, simple, or none)"
                return 1
            end
        elseif arg == "--skip-full-analysis"
            skip_analysis = true
        else
            push!(paths, arg)
        end
    end

    if isempty(paths)
        print(stderr, check_help_message)
        return 1
    end

    quiet && Base.CoreLogging.disable_logging(Base.CoreLogging.Warn)

    root_path = root_path_opt !== nothing ? abspath(root_path_opt) : pwd()
    server = start_cli_server(root_path)
    skip_analysis || start_analysis_workers!(server)
    progress_ctx = ProgressContext(progress_mode, stderr)

    start_time = time()

    if skip_analysis
        analysis_uris = Set{URI}()
        for path in paths
            filepath = abspath(path)
            if !isfile(filepath)
                @error "File not found: $filepath"
                return 1
            end
            uri = filepath2uri(filepath)
            push!(analysis_uris, uri)
        end
        lookup_func = Returns(OutOfScope(Main))
    else
        # Full analysis phase (textDocument/publishDiagnostics equivalent)
        run_full_analysis(server, root_path, paths, progress_ctx)
        analysis_uris = collect_workspace_uris(server)
        if isempty(analysis_uris)
            @error "Full analysis failed: could not find any files to analyze"
            return 1
        end
        lookup_func = nothing
    end

    uri2diagnostics = get_full_diagnostics(server)

    # Lowering analysis phase (workspace/diagnostic equivalent)
    total_uris = run_lowering_analysis!(uri2diagnostics, analysis_uris, server, root_path, progress_ctx; lookup_func)

    for (uri, diagnostics) in uri2diagnostics
        apply_diagnostic_config!(diagnostics, server.state.config_manager, uri, root_path)
        unique!(d::Diagnostic -> (d.range, d.message, d.code), diagnostics)
    end

    elapsed_time = time() - start_time
    print_stats(uri2diagnostics, total_uris, elapsed_time, show_severity)
    has_errors = print_diagnostics(uri2diagnostics, root_path, context_lines, exit_severity, show_severity)

    cleanup_cli_tasks(server)

    return has_errors
end

function start_cli_server(root_path::AbstractString)
    server = Server(; suppress_notifications=true)

    server.state.root_path = root_path
    server.state.workspaceFolders = URI[filepath2uri(root_path)]
    env_path = find_env_path(root_path)
    if env_path !== nothing
        server.state.root_env_path = env_path
    end

    config_path = joinpath(root_path, ".JETLSConfig.toml")
    if isfile(config_path)
        load_file_init_options!(server, config_path)
        load_file_config!(Returns(nothing), server, config_path)
    end

    return server
end

function run_full_analysis(
        server::Server, root_path::AbstractString, paths::Vector{String},
        progress_ctx::ProgressContext
    )
    total_files = length(paths)
    for (idx, path) in enumerate(paths)
        filepath = abspath(path)
        rel_path = relpath(filepath, root_path)
        display_name = "[$idx/$total_files] $rel_path"
        with_progress(progress_ctx, "Full analysis", display_name) do cancellable_token
            uri = filepath2uri(filepath)
            cache_file_info!(server, uri, 1, read(filepath))
            request_analysis!(server, uri, false;
                wait=true, notify_diagnostics=false, cancellable_token, debounce=0.0)
        end
    end
end

mutable struct Counter
    @atomic count::Int
end

function run_lowering_analysis!(
        uri2diagnostics::Dict{URI,Vector{Diagnostic}}, analyzed_uris::Set{URI},
        server::Server, root_path::AbstractString,
        progress_ctx::ProgressContext;
        lookup_func = nothing
    )
    total_uris = length(analyzed_uris)
    uri2diagnostics_lock = ReentrantLock()
    with_progress(progress_ctx, "Lowering analysis", "[$total_uris files]") do cancellable_token
        if cancellable_token !== nothing
            send_progress(server, cancellable_token.token, WorkDoneProgressBegin(; title="Analyzing", message="Started lowering analysis"))
        end

        counter = Counter(0)
        run_lowering_analysis_for_uri = function (uri::URI, lock::Bool)
            fi = @something get_file_info(server.state, uri) begin
                get_unsynced_file_info!(server.state, uri)
            end return
            diagnostics = toplevel_lowering_diagnostics(server, uri, fi; lookup_func)
            if !isempty(diagnostics)
                if lock
                    @lock uri2diagnostics_lock append!(get!(Vector{Diagnostic}, uri2diagnostics, uri), diagnostics)
                else
                    append!(get!(Vector{Diagnostic}, uri2diagnostics, uri), diagnostics)
                end
            end
            @atomic counter.count += 1
            if cancellable_token !== nothing
                filepath = uri2filepath(uri)
                if filepath !== nothing
                    rel_path = relpath(filepath, root_path)
                    send_progress(server, cancellable_token.token,
                        WorkDoneProgressReport(; message = rel_path * " ($(counter.count)/$total_uris) [lowering analysis]"))
                    yield()
                end
            end
        end

        if Threads.nthreads() > 1
            map(collect(analyzed_uris)) do uri
                Threads.@spawn :default run_lowering_analysis_for_uri(uri, false)
            end |> waitall
        else
            for uri in analyzed_uris
                run_lowering_analysis_for_uri(uri, false)
            end
        end

        if cancellable_token !== nothing
            send_progress(server, cancellable_token.token, WorkDoneProgressEnd(; message="Completed lowering analysis"))
        end
    end
    return total_uris
end

function print_stats(
        uri2diagnostics::URI2Diagnostics, total_files::Int, elapsed_time::Float64,
        show_severity::DiagnosticSeverity.Ty
    )
    n_errors = n_warnings = n_info = n_hints = 0
    files_with_diagnostics = 0
    for (_, diagnostics) in uri2diagnostics
        file_has_diagnostics = false
        for d in diagnostics
            d.severity > show_severity && continue
            file_has_diagnostics = true
            if d.severity == DiagnosticSeverity.Error
                n_errors += 1
            elseif d.severity == DiagnosticSeverity.Warning
                n_warnings += 1
            elseif d.severity == DiagnosticSeverity.Information
                n_info += 1
            else
                n_hints += 1
            end
        end
        file_has_diagnostics && (files_with_diagnostics += 1)
    end
    total_diagnostics = n_errors + n_warnings + n_info + n_hints

    println(stdout, "# Analyzed $total_files files in $(format_duration(elapsed_time))")
    if total_diagnostics == 0
        println(stdout, "# No diagnostics found")
    else
        if total_diagnostics == 1
            print(stdout, "# Found 1 diagnostic")
        else
            print(stdout, "# Found $total_diagnostics diagnostics")
        end
        print(stdout, " in $files_with_diagnostics files")
        parts = String[]
        n_errors > 0 && push!(parts, "$n_errors errors")
        n_warnings > 0 && push!(parts, "$n_warnings warnings")
        n_info > 0 && push!(parts, "$n_info info")
        n_hints > 0 && push!(parts, "$n_hints hints")
        println(stdout, " (", join(parts, ", "), ")")
        println(stdout)
    end
end

function print_diagnostics(
        uri2diagnostics::URI2Diagnostics, root_path::String,
        context_lines::Int, exit_severity::DiagnosticSeverity.Ty,
        show_severity::DiagnosticSeverity.Ty
    )
    has_errors = false
    sorted_uris = sort(collect(keys(uri2diagnostics)); by=string)

    for uri in sorted_uris
        diagnostics = uri2diagnostics[uri]
        isempty(diagnostics) && continue
        filepath = uri2filepath(uri)
        filepath === nothing && continue
        text = try
            read(filepath, String)
        catch
            continue
        end
        src = JS.SourceFile(text; filename=filepath)

        rel_path = relpath(filepath, root_path)
        sorted_diagnostics = sort(diagnostics; by=d->(d.range.start.line, d.range.start.character))
        for (i, diagnostic) in enumerate(sorted_diagnostics)
            severity = diagnostic.severity
            if severity <= exit_severity
                has_errors = true
            end
            severity > show_severity && continue
            if severity == DiagnosticSeverity.Error
                color = :light_red
                severity_str = "error"
            elseif severity == DiagnosticSeverity.Warning
                color = :light_yellow
                severity_str = "warn"
            elseif severity == DiagnosticSeverity.Information
                color = :light_blue
                severity_str = "info"
            else
                color = :light_black
                severity_str = "hint"
            end

            textbuf = Vector{UInt8}(text)
            start_byte = _xy_to_offset(textbuf, diagnostic.range.start, PositionEncodingKind.UTF16)
            end_byte = _xy_to_offset(textbuf, diagnostic.range.var"end", PositionEncodingKind.UTF16)
            note = diagnostic.message
            if diagnostic.code !== nothing
                note *= " [$severity_str:$(diagnostic.code)]"
            else
                note *= " [$severity_str]"
            end
            line = diagnostic.range.start.line + 1
            character = diagnostic.range.start.character + 1
            i == 1 || println(stdout)
            printstyled(stdout, "# @ $rel_path:$line,$character\n"; color=:light_black)
            output = let note=note, notecolor=color, context_lines=context_lines
                sprint(; context=IOContext(stdout)) do io
                    JS.highlight(io, src, start_byte:end_byte;
                        note, notecolor=notecolor,
                        context_lines_before=context_lines, context_lines_after=context_lines)
                end
            end
            println(stdout, strip(output, '\n'))
        end
    end

    return has_errors
end

function cleanup_cli_tasks(server::Server)
    stop_analysis_workers(server)
    close(server.endpoint)
end
