const FORMATTING_REGISTRATION_ID = "jetls-formatting"
const FORMATTING_REGISTRATION_METHOD = "textDocument/formatting"
const RANGE_FORMATTING_REGISTRATION_ID = "jetls-rangeFormatting"
const RANGE_FORMATTING_REGISTRATION_METHOD = "textDocument/rangeFormatting"
const RUNIC_INSTALLATION_URL = "https://github.com/fredrikekre/Runic.jl#installation"
const JULIAFORMATTER_INSTALLATION_URL = "https://github.com/domluna/JuliaFormatter.jl#installation"

struct FormattingProgressCaller <: RequestCaller
    uri::URI
    options::FormattingOptions
    msg_id::Union{String,Int}
    token::ProgressToken
end

struct RangeFormattingProgressCaller <: RequestCaller
    uri::URI
    range::Range
    options::FormattingOptions
    msg_id::Union{String,Int}
    token::ProgressToken
end

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

function range_formatting_options(server::Server)
    return DocumentRangeFormattingOptions(;
        workDoneProgress = supports(server, :window, :workDoneProgress))
end

function range_formatting_registration(server::Server)
    return Registration(;
        id = RANGE_FORMATTING_REGISTRATION_ID,
        method = RANGE_FORMATTING_REGISTRATION_METHOD,
        registerOptions = DocumentRangeFormattingRegistrationOptions(;
            documentSelector = DEFAULT_DOCUMENT_SELECTOR,
            workDoneProgress = supports(server, :window, :workDoneProgress)))
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

function handle_DocumentFormattingRequest(server::Server, msg::DocumentFormattingRequest)
    uri = msg.params.textDocument.uri
    options = msg.params.options

    workDoneToken = msg.params.workDoneToken
    if workDoneToken !== nothing
        do_format_with_progress(server, uri, options, msg.id, workDoneToken)
    elseif supports(server, :window, :workDoneProgress)
        id = String(gensym(:WorkDoneProgressCreateRequest_formatting))
        token = String(gensym(:FormattingProgress))
        addrequest!(server, id=>FormattingProgressCaller(uri, options, msg.id, token))
        params = WorkDoneProgressCreateParams(; token)
        send(server, WorkDoneProgressCreateRequest(; id, params))
    else
        do_format(server, uri, options, msg.id)
    end

    return nothing
end

function handle_formatting_progress_response(
        server::Server, msg::Dict{Symbol, Any}, request_caller::FormattingProgressCaller,
    )
    if handle_response_error(server, msg, "create work done progress")
        return
    end
    (; uri, options, msg_id, token) = request_caller
    do_format_with_progress(server, uri, options, msg_id, token)
end

function do_format_with_progress(
        server::Server, uri::URI, options::FormattingOptions,
        msg_id::Union{String,Int}, token::ProgressToken
    )
    send_progress(server, token,
        WorkDoneProgressBegin(; title = "Formatting document"))
    completed = false
    try
        do_format(server, uri, options, msg_id)
        completed = true
    finally
        send_progress(server, token,
            WorkDoneProgressEnd(;
                message = "Document formatting " * (completed ? "completed" : "failed")))
    end
end

function do_format(
        server::Server, uri::URI, options::FormattingOptions,
        msg_id::Union{String,Int}
    )
    result = format_result(server.state, uri, options)
    if result isa ResponseError
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

function format_result(state::ServerState, uri::URI, options::FormattingOptions)
    fi = @something get_file_info(state, uri) return file_cache_error(uri)

    formatter = get_config(state.config_manager, :formatter)
    exe = get_formatter_executable(formatter, false)
    if exe isa ResponseError
        return exe
    end

    newText = @something format_file(exe, uri, fi, nothing, options, formatter) begin
        return request_failed_error("Formatter returned an error. See server logs for details.")
    end
    return TextEdit[TextEdit(; range = document_range(fi), newText)]
end

function handle_DocumentRangeFormattingRequest(server::Server, msg::DocumentRangeFormattingRequest)
    uri = msg.params.textDocument.uri
    range = msg.params.range
    options = msg.params.options

    workDoneToken = msg.params.workDoneToken
    if workDoneToken !== nothing
        do_range_format_with_progress(server, uri, range, options, msg.id, workDoneToken)
    elseif supports(server, :window, :workDoneProgress)
        id = String(gensym(:WorkDoneProgressCreateRequest_rangeFormatting))
        token = String(gensym(:RangeFormattingProgress))
        addrequest!(server, id => RangeFormattingProgressCaller(uri, range, options, msg.id, token))
        params = WorkDoneProgressCreateParams(; token)
        send(server, WorkDoneProgressCreateRequest(; id, params))
    else
        do_range_format(server, uri, range, options, msg.id)
    end

    return nothing
end

function handle_range_formatting_progress_response(
        server::Server, msg::Dict{Symbol, Any}, request_caller::RangeFormattingProgressCaller
    )
    if handle_response_error(server, msg, "create work done progress")
        return
    end
    (; uri, range, options, msg_id, token) = request_caller
    do_range_format_with_progress(server, uri, range, options, msg_id, token)
end

function do_range_format_with_progress(
        server::Server, uri::URI, range::Range, options::FormattingOptions,
        msg_id::Union{String,Int}, token::ProgressToken
    )
    send_progress(server, token,
        WorkDoneProgressBegin(; title = "Formatting document range"))
    completed = false
    try
        do_range_format(server, uri, range, options, msg_id)
        completed = true
    finally
        send_progress(server, token,
            WorkDoneProgressEnd(;
                message = "Document range formatting " * (completed ? "completed" : "failed")))
    end
end

function do_range_format(
        server::Server, uri::URI, range::Range, options::FormattingOptions,
        msg_id::Union{String,Int}
    )
    result = range_format_result(server.state, uri, range, options)
    if result isa ResponseError
        return send(server, DocumentRangeFormattingResponse(; id = msg_id, result = nothing, error = result))
    else
        return send(server, DocumentRangeFormattingResponse(; id = msg_id, result))
    end
end

function range_format_result(
        state::ServerState, uri::URI, range::Range, options::FormattingOptions
    )
    fi = @something get_file_info(state, uri) return file_cache_error(uri)

    formatter = get_config(state.config_manager, :formatter)
    exe = get_formatter_executable(formatter, true)
    if exe isa ResponseError
        return exe
    end

    startline = Int(range.start.line + 1)
    endline = Int(range.var"end".line + 1)
    lines = "$startline:$endline"
    newText = @something format_file(exe, uri, fi, lines, options, formatter) begin
        return request_failed_error("Formatter returned an error. See server logs for details.")
    end
    edit = TextEdit(; range = document_range(fi), newText)
    return TextEdit[edit]
end

function format_file(
        exe::String, uri::URI, fi::FileInfo, lines::Union{Nothing,AbstractString},
        options::FormattingOptions, formatter::FormatterConfig
    )
    cmd = if formatter isa String
        # Preset formatter: "Runic" or "JuliaFormatter"
        if formatter == "Runic"
            if isnothing(lines)
                `$exe`
            else
                `$exe --lines=$lines`
            end
        elseif formatter == "JuliaFormatter"
            # JuliaFormatter doesn't support range formatting
            # (should not reach here due to earlier validation)
            if isnothing(lines)
                tabSize = options.tabSize
                filepath = uri2filepath(uri)
                if filepath !== nothing
                    config_dir = dirname(filepath)
                    if tabSize !== nothing
                        `$exe --indent=$(Int(tabSize)) --prioritize-config-file --config-dir=$config_dir`
                    else
                        `$exe --config-dir=$config_dir`
                    end
                elseif tabSize !== nothing
                    `$exe --indent=$(Int(tabSize))`
                else
                    `$exe`
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
        if isnothing(lines)
            `$exe`
        else
            `$exe --lines=$lines`
        end
    end

    proc = open(cmd; read = true, write = true)
    write(proc, document_text(fi))
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
