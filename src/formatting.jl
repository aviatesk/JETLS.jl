const FORMATTING_REGISTRATION_ID = "jetls-formatting"
const FORMATTING_REGISTRATION_METHOD = "textDocument/formatting"
const RANGE_FORMATTING_REGISTRATION_ID = "jetls-rangeFormatting"
const RANGE_FORMATTING_REGISTRATION_METHOD = "textDocument/rangeFormatting"

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

function handle_DocumentFormattingRequest(server::Server, msg::DocumentFormattingRequest, cancel_flag::CancelFlag)
    if is_cancelled(cancel_flag)
        return send(server,
            DocumentFormattingResponse(;
                id = msg.id,
                result = nothing,
                error = request_cancelled_error()))
    end
    uri = msg.params.textDocument.uri

    workDoneToken = msg.params.workDoneToken
    if workDoneToken !== nothing
        Threads.@spawn do_format_with_progress(server, uri, msg.id, workDoneToken)
    elseif supports(server, :window, :workDoneProgress)
        id = String(gensym(:WorkDoneProgressCreateRequest_formatting))
        token = String(gensym(:FormattingProgress))
        addrequest!(server, id=>FormattingProgressCaller(uri, msg.id, token))
        params = WorkDoneProgressCreateParams(; token)
        send(server, WorkDoneProgressCreateRequest(; id, params))
    else
        Threads.@spawn do_format(server, uri, msg.id)
    end

    return nothing
end

function do_format_with_progress(server::Server, uri::URI, msg_id::Union{String,Int}, token::ProgressToken)
    send(server, ProgressNotification(;
        params = ProgressParams(;
            token,
            value = WorkDoneProgressBegin(;
                title = "Formatting document",
                cancellable = false))))
    completed = false
    try
        do_format(server, uri, msg_id)
        completed = true
    finally
        send(server, ProgressNotification(;
            params = ProgressParams(;
                token,
                value = WorkDoneProgressEnd(;
                    message = "Document formatting " * (completed ? "completed" : "failed")))))
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
    runic = @something Sys.which("runic") return request_failed_error(app_notfound_message("runic"))
    newText = @something format_runic(runic, document_text(fi)) begin
        return request_failed_error("Runic formatter returned an error. See server logs for details.")
    end
    return TextEdit[TextEdit(; range = document_range(fi), newText)]
end

function handle_DocumentRangeFormattingRequest(server::Server, msg::DocumentRangeFormattingRequest, cancel_flag::CancelFlag)
    if is_cancelled(cancel_flag)
        return send(server,
            ResponseMessage(;
                id = msg.id,
                result = nothing,
                error = request_cancelled_error()))
    end
    uri = msg.params.textDocument.uri
    range = msg.params.range

    workDoneToken = msg.params.workDoneToken
    if workDoneToken !== nothing
        Threads.@spawn do_range_format_with_progress(server, uri, range, msg.id, workDoneToken)
    elseif supports(server, :window, :workDoneProgress)
        id = String(gensym(:WorkDoneProgressCreateRequest_rangeFormatting))
        token = String(gensym(:RangeFormattingProgress))
        addrequest!(server, id => RangeFormattingProgressCaller(uri, range, msg.id, token))
        params = WorkDoneProgressCreateParams(; token)
        send(server, WorkDoneProgressCreateRequest(; id, params))
    else
        Threads.@spawn do_range_format(server, uri, range, msg.id)
    end

    return nothing
end

function do_range_format_with_progress(server::Server, uri::URI, range::Range, msg_id::Union{String,Int}, token::ProgressToken)
    send(server, ProgressNotification(;
        params = ProgressParams(;
            token,
            value = WorkDoneProgressBegin(;
                title = "Formatting document range",
                cancellable = false))))
    completed = false
    try
        do_range_format(server, uri, range, msg_id)
        completed = true
    finally
        send(server, ProgressNotification(;
            params = ProgressParams(;
                token,
                value = WorkDoneProgressEnd(;
                    message = "Document range formatting " * (completed ? "completed" : "failed")))))
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
    runic = @something Sys.which("runic") return request_failed_error(app_notfound_message("runic"))
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
