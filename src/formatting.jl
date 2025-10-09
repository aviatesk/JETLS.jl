const FORMATTING_REGISTRATION_ID = "jetls-formatting"
const FORMATTING_REGISTRATION_METHOD = "textDocument/formatting"
const RANGE_FORMATTING_REGISTRATION_ID = "jetls-rangeFormatting"
const RANGE_FORMATTING_REGISTRATION_METHOD = "textDocument/rangeFormatting"
const RUNIC_INSTALLATION_URL = "https://github.com/fredrikekre/Runic.jl#installation"

struct FormattingProgressCaller <: RequestCaller
    uri::URI
    msg_id::Union{String,Int}
    token::ProgressToken
end

struct RangeFormattingProgressCaller <: RequestCaller
    uri::URI
    range::Range
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

    workDoneToken = msg.params.workDoneToken
    if workDoneToken !== nothing
        do_format_with_progress(server, uri, msg.id, workDoneToken)
    elseif supports(server, :window, :workDoneProgress)
        id = String(gensym(:WorkDoneProgressCreateRequest_formatting))
        token = String(gensym(:FormattingProgress))
        addrequest!(server, id=>FormattingProgressCaller(uri, msg.id, token))
        params = WorkDoneProgressCreateParams(; token)
        send(server, WorkDoneProgressCreateRequest(; id, params))
    else
        do_format(server, uri, msg.id)
    end

    return nothing
end

function handle_formatting_progress_response(
        server::Server, msg::Dict{Symbol, Any}, request_caller::FormattingProgressCaller,
    )
    if handle_response_error(server, msg, "create work done progress")
        return
    end
    (; uri, msg_id, token) = request_caller
    do_format_with_progress(server, uri, msg_id, token)
end

function do_format_with_progress(
        server::Server, uri::URI, msg_id::Union{String,Int}, token::ProgressToken
    )
    send_progress(server, token,
        WorkDoneProgressBegin(; title = "Formatting document"))
    completed = false
    try
        do_format(server, uri, msg_id)
        completed = true
    finally
        send_progress(server, token,
            WorkDoneProgressEnd(;
                message = "Document formatting " * (completed ? "completed" : "failed")))
    end
end

function do_format(server::Server, uri::URI, msg_id::Union{String,Int})
    result = format_result(server.state, uri)
    if result isa ResponseError
        return send(server, DocumentFormattingResponse(; id = msg_id, result = nothing, error = result))
    else
        return send(server, DocumentFormattingResponse(; id = msg_id, result))
    end
end

function format_result(state::ServerState, uri::URI)
    fi = @something get_file_info(state, uri) return file_cache_error(uri)
    setting_path = ("formatter", "runic", "executable")
    executable = get_config(state.config_manager, setting_path...)
    default_executable = access_nested_dict(DEFAULT_CONFIG, setting_path...)
    additional_msg = if executable == default_executable
        install_instruction_message(executable, RUNIC_INSTALLATION_URL)
    else
        check_settings_message(setting_path...)
    end
    runic = @something Sys.which(executable) return request_failed_error(
        app_notfound_message(executable) * additional_msg)
    newText = @something format_runic(runic, document_text(fi)) begin
        return request_failed_error("Runic formatter returned an error. See server logs for details.")
    end
    return TextEdit[TextEdit(; range = document_range(fi), newText)]
end

function handle_DocumentRangeFormattingRequest(server::Server, msg::DocumentRangeFormattingRequest)
    uri = msg.params.textDocument.uri
    range = msg.params.range

    workDoneToken = msg.params.workDoneToken
    if workDoneToken !== nothing
        do_range_format_with_progress(server, uri, range, msg.id, workDoneToken)
    elseif supports(server, :window, :workDoneProgress)
        id = String(gensym(:WorkDoneProgressCreateRequest_rangeFormatting))
        token = String(gensym(:RangeFormattingProgress))
        addrequest!(server, id => RangeFormattingProgressCaller(uri, range, msg.id, token))
        params = WorkDoneProgressCreateParams(; token)
        send(server, WorkDoneProgressCreateRequest(; id, params))
    else
        do_range_format(server, uri, range, msg.id)
    end

    return nothing
end

function handle_range_formatting_progress_response(
        server::Server, msg::Dict{Symbol, Any}, request_caller::RangeFormattingProgressCaller
    )
    if handle_response_error(server, msg, "create work done progress")
        return
    end
    (; uri, range, msg_id, token) = request_caller
    do_range_format_with_progress(server, uri, range, msg_id, token)
end

function do_range_format_with_progress(
        server::Server, uri::URI, range::Range, msg_id::Union{String,Int}, token::ProgressToken
    )
    send_progress(server, token,
        WorkDoneProgressBegin(; title = "Formatting document range"))
    completed = false
    try
        do_range_format(server, uri, range, msg_id)
        completed = true
    finally
        send_progress(server, token,
            WorkDoneProgressEnd(;
                message = "Document range formatting " * (completed ? "completed" : "failed")))
    end
end

function do_range_format(server::Server, uri::URI, range::Range, msg_id::Union{String,Int})
    result = range_format_result(server.state, uri, range)
    if result isa ResponseError
        return send(server, DocumentRangeFormattingResponse(; id = msg_id, result = nothing, error = result))
    else
        return send(server, DocumentRangeFormattingResponse(; id = msg_id, result))
    end
end

function range_format_result(state::ServerState, uri::URI, range::Range)
    fi = @something get_file_info(state, uri) return file_cache_error(uri)
    setting_path = ("formatter", "runic", "executable")
    executable = get_config(state.config_manager, setting_path...)
    default_executable = access_nested_dict(DEFAULT_CONFIG, setting_path...)
    additional_msg = if executable == default_executable
        install_instruction_message(executable, RUNIC_INSTALLATION_URL)
    else
        check_settings_message(setting_path...)
    end
    runic = @something Sys.which(executable) return request_failed_error(
        app_notfound_message(executable) * additional_msg)
    startline = Int(range.start.line + 1)
    endline = Int(range.var"end".line + 1)
    lines = "$startline:$endline"
    newText = @something format_runic(runic, document_text(fi), lines) begin
        return request_failed_error("Runic formatter returned an error. See server logs for details.")
    end
    edit = TextEdit(; range = document_range(fi), newText)
    return TextEdit[edit]
end

function format_runic(exe::String, text::AbstractString, lines::Union{Nothing,AbstractString}=nothing)
    if isnothing(lines)
        proc = open(`$exe`; read = true, write = true)
    else
        proc = open(`$exe --lines=$lines`; read = true, write = true)
    end
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
