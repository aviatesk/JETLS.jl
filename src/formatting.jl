const FORMATTING_REGISTRATION_ID = "jetls-formatting"
const FORMATTING_REGISTRATION_METHOD = "textDocument/formatting"
const RANGE_FORMATTING_REGISTRATION_ID = "jetls-rangeFormatting"
const RANGE_FORMATTING_REGISTRATION_METHOD = "textDocument/rangeFormatting"
const RUNIC_INSTALLATION_URL = "https://github.com/fredrikekre/Runic.jl#installation"
const JULIAFORMATTER_INSTALLATION_URL = "https://github.com/domluna/JuliaFormatter.jl#installation"

struct FormattingProgressCaller <: RequestCaller
    uri::URI
    options::FormattingOptions
    msg_id::MessageId
    token::ProgressToken
    cancel_flag::CancelFlag
end
cancellable_token_impl(caller::FormattingProgressCaller) = caller.token

struct RangeFormattingProgressCaller <: RequestCaller
    uri::URI
    range::Range
    options::FormattingOptions
    msg_id::MessageId
    token::ProgressToken
    cancel_flag::CancelFlag
end
cancellable_token_impl(caller::RangeFormattingProgressCaller) = caller.token

struct RangesFormattingProgressCaller <: RequestCaller
    uri::URI
    ranges::Vector{Range}
    options::FormattingOptions
    msg_id::MessageId
    token::ProgressToken
    cancel_flag::CancelFlag
end
cancellable_token_impl(caller::RangesFormattingProgressCaller) = caller.token

function formatting_options(server::Server)
    return DocumentFormattingOptions(;
        workDoneProgress = supports(server, :window, :workDoneProgress))
end

function formatting_registration(server::Server)
    return Registration(;
        id = FORMATTING_REGISTRATION_ID,
        method = FORMATTING_REGISTRATION_METHOD,
        registerOptions = DocumentFormattingRegistrationOptions(;
            documentSelector = DEFAULT_DOCUMENT_SELECTOR,
            workDoneProgress = supports(server, :window, :workDoneProgress)))
end

function ranges_formatting_supported(server::Server)
    return supports(server, :textDocument, :rangeFormatting, :rangesSupport)
end

function range_formatting_options(server::Server)
    return DocumentRangeFormattingOptions(;
        workDoneProgress = supports(server, :window, :workDoneProgress),
        rangesSupport = ranges_formatting_supported(server) ? true : nothing)
end

function range_formatting_registration(server::Server)
    return Registration(;
        id = RANGE_FORMATTING_REGISTRATION_ID,
        method = RANGE_FORMATTING_REGISTRATION_METHOD,
        registerOptions = DocumentRangeFormattingRegistrationOptions(;
            documentSelector = DEFAULT_DOCUMENT_SELECTOR,
            workDoneProgress = supports(server, :window, :workDoneProgress),
            rangesSupport = ranges_formatting_supported(server) ? true : nothing))
end

# For dynamic registrations during development
# unregister(currently_running, Unregistration(;
#     id = FORMATTING_REGISTRATION_ID,
#     method = FORMATTING_REGISTRATION_METHOD))
# register(currently_running, formatting_registration(currently_running))
# unregister(currently_running, Unregistration(;
#     id = RANGE_FORMATTING_REGISTRATION_ID,
#     method = RANGE_FORMATTING_REGISTRATION_METHOD))
# register(currently_running, range_formatting_registration(currently_running))

document_text(fi::FileInfo) = JS.sourcetext(fi.parsed_stream)
document_range(fi::FileInfo) = jsobj_to_range(fi.parsed_stream, fi)

function get_cell_text(state::ServerState, cell_uri::URI)
    notebook_uri = @something get_notebook_uri_for_cell(state, cell_uri) return nothing
    notebook_info = @something get_notebook_info(state, notebook_uri) return nothing
    for cell in notebook_info.cells
        if cell.uri == cell_uri && cell.kind == NotebookCellKind.Code
            return cell.text
        end
    end
    return nothing
end

function cell_range(text::AbstractString, encoding::PositionEncodingKind.Ty)
    textbuf = Vector{UInt8}(text)
    end_pos = _offset_to_xy(textbuf, sizeof(text) + 1, encoding)
    return Range(;
        start = Position(; line = 0, character = 0),
        var"end" = end_pos)
end

function handle_DocumentFormattingRequest(
        server::Server, msg::DocumentFormattingRequest, cancel_flag::CancelFlag
    )
    uri = msg.params.textDocument.uri
    options = msg.params.options

    workDoneToken = msg.params.workDoneToken
    if workDoneToken !== nothing
        do_format_with_progress(server, uri, options, msg.id, workDoneToken, cancel_flag)
    elseif supports(server, :window, :workDoneProgress)
        id = String(gensym(:WorkDoneProgressCreateRequest_formatting))
        token = String(gensym(:FormattingProgress))
        addrequest!(server, id => FormattingProgressCaller(uri, options, msg.id, token, cancel_flag))
        params = WorkDoneProgressCreateParams(; token)
        send(server, WorkDoneProgressCreateRequest(; id, params))
    else
        do_format(server, uri, options, msg.id, cancel_flag)
    end

    return nothing
end

function handle_formatting_progress_response(
        server::Server, msg::Dict{Symbol, Any}, request_caller::FormattingProgressCaller,
        progress_cancel_flag::CancelFlag
    )
    if handle_response_error(server, msg, "create work done progress")
        return
    end
    (; uri, options, msg_id, token, cancel_flag) = request_caller
    combined_flag = CombinedCancelFlag(cancel_flag, progress_cancel_flag)
    do_format_with_progress(server, uri, options, msg_id, token, combined_flag)
end

function do_format_with_progress(
        server::Server, uri::URI, options::FormattingOptions,
        msg_id::MessageId, token::ProgressToken, cancel_flag::AbstractCancelFlag
    )
    send_progress(server, token,
        WorkDoneProgressBegin(; title = "Formatting document", cancellable = true))
    completed = false
    try
        do_format(server, uri, options, msg_id, cancel_flag)
        completed = true
    finally
        send_progress(server, token,
            WorkDoneProgressEnd(;
                message = "Document formatting " * (completed ? "completed" : "failed")))
    end
end

function do_format(
        server::Server, uri::URI, options::FormattingOptions,
        msg_id::MessageId, cancel_flag::AbstractCancelFlag
    )
    result = format_result(server.state, uri, options, cancel_flag)
    if isnothing(result)
        return send(server, DocumentFormattingResponse(; id = msg_id, result = null))
    elseif result isa ResponseError
        return send(server, DocumentFormattingResponse(; id = msg_id, result = nothing, error = result))
    else
        return send(server, DocumentFormattingResponse(; id = msg_id, result))
    end
end

function get_formatter_executable(formatter::FormatterConfig, for_range::Bool)
    if formatter isa String
        # Preset formatter: "Runic" or "JuliaFormatter"
        executable = default_executable(formatter)
        executable === nothing &&
            return request_failed_error(
                "Unknown formatter preset \"$formatter\". " *
                "Valid presets are: \"Runic\", \"JuliaFormatter\". " *
                "For custom formatters, use [formatter.custom] configuration.")

        if for_range && formatter == "JuliaFormatter"
            return request_failed_error(
                "JuliaFormatter does not support range formatting. " *
                "Please use document formatting instead or configure a custom " *
                "formatter with `executable_range`.")
        else
            additional_msg = if formatter == "JuliaFormatter"
                install_instruction_message(executable, JULIAFORMATTER_INSTALLATION_URL)
            elseif formatter == "Runic"
                install_instruction_message(executable, RUNIC_INSTALLATION_URL)
            else
                check_settings_message(:formatter)
            end

            exe_path = @something Sys.which(executable) return request_failed_error(
                app_notfound_message(executable) * additional_msg)
            return exe_path
        end
    else # Custom formatter
        formatter = formatter::CustomFormatterConfig
        if for_range
            executable = formatter.executable_range
            if executable === nothing
                return request_failed_error(
                    "Custom formatter does not specify `executable_range`. " *
                    check_settings_message(:formatter))
            end
        else
            executable = formatter.executable
            if executable === nothing
                return request_failed_error(
                    "Custom formatter does not specify `executable`. " *
                    check_settings_message(:formatter))
            end
        end
        return executable
    end
end

function format_result(
        state::ServerState, uri::URI, options::FormattingOptions, cancel_flag::AbstractCancelFlag
    )
    result = @something get_file_info(state, uri, cancel_flag) return nothing
    result isa ResponseError && return result
    fi = result

    formatter = get_config(state, :formatter)
    exe = get_formatter_executable(formatter, false)
    if exe isa ResponseError
        return exe
    end

    return format_file(state, exe, uri, fi, nothing, options, formatter)
end

function handle_DocumentRangeFormattingRequest(
        server::Server, msg::DocumentRangeFormattingRequest, cancel_flag::CancelFlag
    )
    uri = msg.params.textDocument.uri
    range = msg.params.range
    options = msg.params.options

    workDoneToken = msg.params.workDoneToken
    if workDoneToken !== nothing
        do_range_format_with_progress(server, uri, range, options, msg.id, workDoneToken, cancel_flag)
    elseif supports(server, :window, :workDoneProgress)
        id = String(gensym(:WorkDoneProgressCreateRequest_rangeFormatting))
        token = String(gensym(:RangeFormattingProgress))
        addrequest!(server, id => RangeFormattingProgressCaller(uri, range, options, msg.id, token, cancel_flag))
        params = WorkDoneProgressCreateParams(; token)
        send(server, WorkDoneProgressCreateRequest(; id, params))
    else
        do_range_format(server, uri, range, options, msg.id, cancel_flag)
    end

    return nothing
end

function handle_range_formatting_progress_response(
        server::Server, msg::Dict{Symbol, Any}, request_caller::RangeFormattingProgressCaller,
        progress_cancel_flag::CancelFlag
    )
    if handle_response_error(server, msg, "create work done progress")
        return
    end
    (; uri, range, options, msg_id, token, cancel_flag) = request_caller
    combined_flag = CombinedCancelFlag(cancel_flag, progress_cancel_flag)
    do_range_format_with_progress(server, uri, range, options, msg_id, token, combined_flag)
end

function do_range_format_with_progress(
        server::Server, uri::URI, range::Range, options::FormattingOptions,
        msg_id::MessageId, token::ProgressToken, cancel_flag::AbstractCancelFlag
    )
    send_progress(server, token,
        WorkDoneProgressBegin(; title = "Formatting document range", cancellable = true))
    completed = false
    try
        do_range_format(server, uri, range, options, msg_id, cancel_flag)
        completed = true
    finally
        send_progress(server, token,
            WorkDoneProgressEnd(;
                message = "Document range formatting " * (completed ? "completed" : "failed")))
    end
end

function do_range_format(
        server::Server, uri::URI, range::Range, options::FormattingOptions,
        msg_id::MessageId, cancel_flag::AbstractCancelFlag
    )
    result = range_format_result(server.state, uri, range, options, cancel_flag)
    if isnothing(result)
        return send(server, DocumentRangeFormattingResponse(; id = msg_id, result = null))
    elseif result isa ResponseError
        return send(server, DocumentRangeFormattingResponse(; id = msg_id, result = nothing, error = result))
    else
        return send(server, DocumentRangeFormattingResponse(; id = msg_id, result))
    end
end

function range_format_result(
        state::ServerState, uri::URI, range::Range, options::FormattingOptions,
        cancel_flag::AbstractCancelFlag
    )
    result = @something get_file_info(state, uri, cancel_flag) return nothing
    result isa ResponseError && return result
    fi = result

    formatter = get_config(state, :formatter)
    exe = get_formatter_executable(formatter, true)
    if exe isa ResponseError
        return exe
    end

    return format_file(state, exe, uri, fi, Range[range], options, formatter)
end

function handle_DocumentRangesFormattingRequest(
        server::Server, msg::DocumentRangesFormattingRequest, cancel_flag::CancelFlag
    )
    uri = msg.params.textDocument.uri
    ranges = msg.params.ranges
    options = msg.params.options

    workDoneToken = msg.params.workDoneToken
    if workDoneToken !== nothing
        do_ranges_format_with_progress(
            server, uri, ranges, options, msg.id, workDoneToken, cancel_flag)
    elseif supports(server, :window, :workDoneProgress)
        id = String(gensym(:WorkDoneProgressCreateRequest_rangesFormatting))
        token = String(gensym(:RangesFormattingProgress))
        addrequest!(server,
            id => RangesFormattingProgressCaller(
                uri, ranges, options, msg.id, token, cancel_flag))
        params = WorkDoneProgressCreateParams(; token)
        send(server, WorkDoneProgressCreateRequest(; id, params))
    else
        do_ranges_format(server, uri, ranges, options, msg.id, cancel_flag)
    end

    return nothing
end

function handle_ranges_formatting_progress_response(
        server::Server, msg::Dict{Symbol, Any},
        request_caller::RangesFormattingProgressCaller,
        progress_cancel_flag::CancelFlag
    )
    if handle_response_error(server, msg, "create work done progress")
        return
    end
    (; uri, ranges, options, msg_id, token, cancel_flag) = request_caller
    combined_flag = CombinedCancelFlag(cancel_flag, progress_cancel_flag)
    do_ranges_format_with_progress(
        server, uri, ranges, options, msg_id, token, combined_flag)
end

function do_ranges_format_with_progress(
        server::Server, uri::URI, ranges::Vector{Range}, options::FormattingOptions,
        msg_id::MessageId, token::ProgressToken, cancel_flag::AbstractCancelFlag
    )
    send_progress(server, token,
        WorkDoneProgressBegin(; title = "Formatting document ranges", cancellable = true))
    completed = false
    try
        do_ranges_format(server, uri, ranges, options, msg_id, cancel_flag)
        completed = true
    finally
        send_progress(server, token,
            WorkDoneProgressEnd(;
                message = "Document ranges formatting " *
                          (completed ? "completed" : "failed")))
    end
end

function do_ranges_format(
        server::Server, uri::URI, ranges::Vector{Range}, options::FormattingOptions,
        msg_id::MessageId, cancel_flag::AbstractCancelFlag
    )
    result = ranges_format_result(server.state, uri, ranges, options, cancel_flag)
    if isnothing(result)
        return send(server, DocumentRangesFormattingResponse(; id = msg_id, result = null))
    elseif result isa ResponseError
        return send(server,
            DocumentRangesFormattingResponse(;
                id = msg_id,
                result = nothing,
                error = result))
    else
        return send(server, DocumentRangesFormattingResponse(; id = msg_id, result))
    end
end

function ranges_format_result(
        state::ServerState, uri::URI, ranges::Vector{Range}, options::FormattingOptions,
        cancel_flag::AbstractCancelFlag
    )
    isempty(ranges) && return TextEdit[]

    result = @something get_file_info(state, uri, cancel_flag) return nothing
    result isa ResponseError && return result
    fi = result

    formatter = get_config(state, :formatter)
    exe = get_formatter_executable(formatter, true)
    if exe isa ResponseError
        return exe
    end

    return format_file(state, exe, uri, fi, ranges, options, formatter)
end

function range_lines(range::Range)
    startline = Int(range.start.line + 1)
    endline = Int(range.var"end".line + 1)
    return "$startline:$endline"
end

function format_file(
        state::ServerState, exe::String, uri::URI, fi::FileInfo,
        ranges::Union{Vector{Range},Nothing},
        options::FormattingOptions, formatter::FormatterConfig
    )
    if ranges !== nothing && isempty(ranges)
        return TextEdit[]
    end

    cell_text = get_cell_text(state, uri)
    text = cell_text !== nothing ? cell_text : document_text(fi)
    line_ranges = ranges === nothing ? nothing : map(range_lines, ranges)

    formatter_result = run_formatter(exe, text, line_ranges, uri, options, formatter)
    newText = @something formatter_result begin
        return request_failed_error(
            "Formatter returned an error. See server logs for details.")
    end
    edit_range = if cell_text !== nothing
        cell_range(cell_text, fi.encoding)
    else
        document_range(fi)
    end
    return TextEdit[TextEdit(; range = edit_range, newText)]
end

function run_formatter(
        exe::String, text::AbstractString, line_ranges::Union{Nothing,Vector{String}},
        uri::URI, options::FormattingOptions, formatter::FormatterConfig
    )
    line_args = line_ranges === nothing ?
        String[] : ["--lines=$line_range" for line_range in line_ranges]
    cmd = if formatter isa String
        # Preset formatter: "Runic" or "JuliaFormatter"
        if formatter == "Runic"
            if isempty(line_args)
                `$exe`
            else
                `$exe $(line_args)`
            end
        elseif formatter == "JuliaFormatter"
            # JuliaFormatter doesn't support range formatting
            # (should not reach here due to earlier validation)
            if line_ranges === nothing
                tabSize = options.tabSize
                filepath = uri2filepath(uri)
                if filepath !== nothing
                    config_dir = dirname(filepath)
                    `$exe --indent=$(Int(tabSize)) --prioritize-config-file --config-dir=$config_dir`
                else
                    `$exe --indent=$(Int(tabSize))`
                end
            else
                return nothing
            end
        else # Unknown preset (should not reach here)
            return nothing
        end
    else # Custom formatter
        formatter = formatter::CustomFormatterConfig
        # Assume custom formatters use the same interface as Runic
        if isempty(line_args)
            `$exe`
        else
            `$exe $(line_args)`
        end
    end

    proc = open(cmd; read = true, write = true)
    write(proc, text)
    close(proc.in)
    wait(proc)
    if proc.exitcode ≠ 0
        close(proc)
        return nothing
    end
    ret = read(proc)
    close(proc)
    return String(ret)
end
