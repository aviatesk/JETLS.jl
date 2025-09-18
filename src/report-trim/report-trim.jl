const REPORT_TRIM_DIAGNOSTIC_SOURCE = "JETLS - TrimAnalyzer"

const REPORT_TRIM_RUN_TITLE = "▶ Run TrimAnalyzer"
const REPORT_TRIM_RERUN_TITLE = "▶ Rerun TrimAnalyzer"
const REPORT_TRIM_CLEAR_RESULT_TITLE = "✓ Clear result"

function update_entrypoint!(server::Server, uri::URI, fi::FileInfo)
    entrypoint = find_main_entrypoint(build_syntax_tree(fi))
    prev_entrypointinfo = fi.entrypointinfo
    any_deleted = false

    if isnothing(entrypoint)
        if !isnothing(prev_entrypointinfo)
            if isdefined(prev_entrypointinfo, :result)
                key = prev_entrypointinfo.result.key
                any_deleted |= clear_extra_diagnostics!(server, key)
            end
            fi.entrypointinfo = nothing
        end
    else
        if !isnothing(prev_entrypointinfo)
            if isdefined(prev_entrypointinfo, :result)
                # Preserve the result if the entrypoint hasn't changed
                fi.entrypointinfo = Entrypoint(entrypoint, prev_entrypointinfo.result)
            else
                fi.entrypointinfo = Entrypoint(entrypoint)
            end
        else
            fi.entrypointinfo = Entrypoint(entrypoint)
        end
    end

    if any_deleted
        notify_diagnostics!(server)
    end

    return fi.entrypointinfo
end

# TODO support `function @main(args::Vector{String}) ... end`
function find_main_entrypoint(st0_top::SyntaxTree0)
    for st0 in JS.children(st0_top)
        if JS.kind(st0) === JS.K"function" && JS.numchildren(st0) >= 2
            st01 = st0[1]
            if JS.kind(st01) === JS.K"call" && JS.numchildren(st01) >= 1
                st011 = st01[1]
                if JS.kind(st011) === JS.K"macrocall" && JS.numchildren(st011) >= 1
                    st0111 = st011[1]
                    if JS.kind(st0111) === JS.K"MacroName" && hasproperty(st0111, :name_val)
                        if st0111.name_val == "@main"
                            return st0
                        end
                    end
                end
            end
        end
    end
    return nothing
end

function report_trim_code_lens!(code_lenses, uri::URI, fi::FileInfo)
    entrypointinfo = fi.entrypointinfo
    if isnothing(entrypointinfo)
        return
    end

    range = get_source_range(entrypointinfo.st0)
    run_arguments = Any[uri]

    if isdefined(entrypointinfo, :result)
        result = entrypointinfo.result.result
        summary = result.success ? "✓ No dispatch errors" : "✗ $(length(result.diagnostics)) dispatch error(s)"

        command = Command(;
            title = "$REPORT_TRIM_RERUN_TITLE $summary",
            command = COMMAND_REPORT_TRIM_RUN,
            arguments = run_arguments)
        push!(code_lenses, CodeLens(; range, command))

        command = Command(;
            title = REPORT_TRIM_CLEAR_RESULT_TITLE,
            command = COMMAND_REPORT_TRIM_CLEAR_RESULT,
            arguments = run_arguments)
        push!(code_lenses, CodeLens(; range, command))
    else
        command = Command(;
            title = REPORT_TRIM_RUN_TITLE,
            command = COMMAND_REPORT_TRIM_RUN,
            arguments = run_arguments)
        push!(code_lenses, CodeLens(; range, command))
    end

    return code_lenses
end

function report_trim_cmd(filepath::String, env_path::Union{Nothing,String})
    report_trim_exe = Sys.which("report-trim")
    if isnothing(env_path)
        return `$report_trim_exe --json $filepath`
    else
        return `$report_trim_exe --project=$env_path --json $filepath`
    end
end

function report_trim_result_to_diagnostics(result::ReportTrimResult)
    uri2diagnostics = URI2Diagnostics()
    uri = filename2uri(result.filepath)
    isnothing(uri) && return uri2diagnostics
    uri2diagnostics[uri] = result.diagnostics
    return uri2diagnostics
end

function report_trim_run(server::Server, uri::URI, fi::FileInfo, filepath::String;
                         token::Union{Nothing,ProgressToken}=nothing)
    if isnothing(Sys.which("report-trim"))
        show_error_message(server, """
            `report-trim` executable is not found on the `PATH`.
            Please install TrimAnalyzer app to use this feature.
            """)
        return token !== nothing && end_report_trim_progress(server, token, "TrimAnalyzer not installed")
    end

    if token !== nothing
        send(server, ProgressNotification(;
            params = ProgressParams(;
                token,
                value = WorkDoneProgressBegin(;
                    title = "Running TrimAnalyzer",
                    cancellable = false))))
    end

    local result::String
    try
        result = _report_trim_run(server, uri, fi, filepath)
    catch err
        result = sprint(Base.showerror, err, catch_backtrace())
        @error "Error from TrimAnalyzer executor" err
        show_error_message(server, """
            An unexpected error occurred while running TrimAnalyzer:
            See the server log for details.
            """)
    finally
        @assert @isdefined(result) "`result` should be defined at this point"
        if token !== nothing
            end_report_trim_progress(server, token, result)
        end
    end
end

function _report_trim_run(server::Server, uri::URI, fi::FileInfo, filepath::String)
    env_path = find_uri_env_path(server.state, uri)
    cmd = report_trim_cmd(filepath, env_path)

    proc = open(cmd; read=true, write=false)
    output = read(proc, String)
    wait(proc)

    result = try
        JSONRPC.JSON3.read(output, ReportTrimResult)
    catch err
        @error "Error parsing TrimAnalyzer output" err output
        show_error_message(server, """
            Failed to parse TrimAnalyzer output.
            See the server log for details.
            """)
        return "Analysis failed"
    end

    if !isnothing(fi.entrypointinfo)
        key = ReportTrimDiagnosticsKey(fi)
        report_trim_info = ReportTrimInfo(result, key)
        fi.entrypointinfo = Entrypoint(fi.entrypointinfo.st0, report_trim_info)

        uri2diagnostics = report_trim_result_to_diagnostics(result)
        if !isempty(result.diagnostics)
            server.state.extra_diagnostics[key] = uri2diagnostics
        elseif haskey(server.state.extra_diagnostics, key)
            delete!(server.state.extra_diagnostics, key)
        end
        notify_diagnostics!(server)

        if supports(server, :workspace, :codeLens, :refreshSupport)
            request_codelens_refresh!(server)
        end
    end

    show_report_trim_result_in_message(server, result, fi, uri)

    summary = result.success ? "✓ No dispatch errors found" : "✗ Found $(length(result.diagnostics)) dispatch error(s)"
    return summary
end

function show_report_trim_result_in_message(server::Server, result::ReportTrimResult, fi::FileInfo, uri::URI)
    summary = result.success ? "✓ No dispatch errors found" : "✗ Found $(length(result.diagnostics)) dispatch error(s)"
    message = "TrimAnalyzer: $summary"

    msg_type = if !result.success
        MessageType.Error
    else
        MessageType.Info
    end

    actions = MessageActionItem[
        MessageActionItem(; title = REPORT_TRIM_RERUN_TITLE),
        MessageActionItem(; title = REPORT_TRIM_CLEAR_RESULT_TITLE)
    ]

    id = String(gensym(:ShowMessageRequest))
    server.state.currently_requested[id] = ReportTrimMessageRequestCaller(uri, fi)

    send(server, ShowMessageRequest(;
        id,
        params = ShowMessageRequestParams(;
            type = msg_type,
            message,
            actions)))
end

function end_report_trim_progress(server::Server, token::ProgressToken, message::String)
    send(server, ProgressNotification(;
        params = ProgressParams(;
            token,
            value = WorkDoneProgressEnd(; message))))
end

struct ReportTrimMessageRequestCaller <: RequestCaller
    uri::URI
    fi::FileInfo
end

struct ReportTrimProgressCaller <: RequestCaller
    uri::URI
    fi::FileInfo
    filepath::String
    token::ProgressToken
end

function report_trim_run_from_uri(server::Server, uri::URI)
    fi = get_file_info(server.state, uri)
    if fi === nothing
        return "File is no longer available in the editor"
    end

    if isnothing(fi.entrypointinfo)
        return "No @main function found in this file"
    end

    sfi = get_saved_file_info(server.state, uri)
    if sfi === nothing
        return "The file appears not to exist on disk. Save the file first to run TrimAnalyzer."
    elseif JS.sourcetext(fi.parsed_stream) ≠ JS.sourcetext(sfi.parsed_stream)
        return "The editor state differs from the saved file. Save the file first to run TrimAnalyzer."
    end

    filepath = uri2filepath(uri)
    if isnothing(filepath)
        return "Cannot determine file path for the URI"
    end

    if supports(server, :window, :workDoneProgress)
        id = String(gensym(:WorkDoneProgressCreateRequest_report_trim))
        token = String(gensym(:ReportTrimProgress))
        server.state.currently_requested[id] = ReportTrimProgressCaller(uri, fi, filepath, token)
        params = WorkDoneProgressCreateParams(; token)
        send(server, WorkDoneProgressCreateRequest(; id, params))
    else
        @async report_trim_run(server, uri, fi, filepath)
    end

    return nothing
end


function try_clear_report_trim_result!(server::Server, uri::URI)
    fi = get_file_info(server.state, uri)
    if fi === nothing || isnothing(fi.entrypointinfo)
        return nothing
    end

    if isdefined(fi.entrypointinfo, :result)
        fi.entrypointinfo = Entrypoint(fi.entrypointinfo.st0)

        if clear_extra_diagnostics!(server, ReportTrimDiagnosticsKey(fi))
            notify_diagnostics!(server)
        end

        if supports(server, :workspace, :codeLens, :refreshSupport)
            request_codelens_refresh!(server)
        end
    end

    return nothing
end

function handle_report_trim_message_response(server::Server, msg::Dict{Symbol,Any}, request_caller::ReportTrimMessageRequestCaller)
    if handle_response_error(server, msg, "show TrimAnalyzer action")
        return
    elseif haskey(msg, :result) && msg[:result] !== nothing
        selected = msg[:result] # ::MessageActionItem
        title = get(selected, "title", "")
        (; uri, fi) = request_caller
        if title == REPORT_TRIM_RERUN_TITLE
            error_msg = report_trim_run_from_uri(server, uri)
            if error_msg !== nothing
                show_error_message(server, error_msg)
            end
        elseif title == REPORT_TRIM_CLEAR_RESULT_TITLE
            try_clear_report_trim_result!(server, uri)
        else
            error(lazy"Unknown action: $title")
        end
    end
end

function handle_report_trim_progress_response(server::Server, msg::Dict{Symbol,Any}, request_caller::ReportTrimProgressCaller)
    if handle_response_error(server, msg, "create work done progress")
        return
    end
    # If successful, run TrimAnalyzer with progress reporting
    (; uri, fi, filepath, token) = request_caller
    @async report_trim_run(server, uri, fi, filepath; token)
end
