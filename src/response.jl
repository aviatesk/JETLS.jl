"""
    handle_response_error(server::Server, msg::Dict{Symbol,Any}, context::String)

Common error handling for response messages. Checks for error field and shows appropriate message.
Returns true if an error was handled, false otherwise.
"""
function handle_response_error(server::Server, msg::Dict{Symbol,Any}, context::String)
    if haskey(msg, :error)
        error_msg = get(msg[:error], "message", "Unknown error")
        show_error_message(server, "Failed to $context: $error_msg")
        return true
    end
    return false
end

function handle_request_analysis_response(
        server::Server, ::Dict{Symbol,Any}, request_caller::RequestAnalysisCaller, cancel_flag::CancelFlag
    )
    (; uri, onsave, token) = request_caller
    request_analysis!(server, uri; onsave, token, cancel_flag)
end

function handle_show_document_response(
        server::Server, msg::Dict{Symbol,Any}, request_caller::ShowDocumentRequestCaller
    )
    if handle_response_error(server, msg, "show document")
    elseif haskey(msg, :result)
        result = msg[:result] # ::ShowDocumentResult
        if haskey(result, "success") && result["success"] === true
            (; uri, logs, context) = request_caller
            return set_document_content(server, uri, logs; context)
        else
            show_error_message(server, "Failed to open document for viewing test logs")
        end
    else
        show_error_message(server, "Unexpected response from show document request")
    end
end

function handle_apply_workspace_edit_response(
        server::Server, msg::Dict{Symbol,Any}, ::SetDocumentContentCaller
    )
    if handle_response_error(server, msg, "apply workspace edit")
    elseif haskey(msg, :result)
        result = msg[:result] # ::ApplyWorkspaceEditResult
        if haskey(result, "applied") && result["applied"] === true
            # If applied successfully, no action needed
        else
            failure_reason = get(result, "failureReason", "Unknown reason")
            show_error_message(server, "Failed to apply workspace edit: $failure_reason")
        end
    else
        show_error_message(server, "Unexpected response from workspace edit request")
    end
end

function handle_test_runner_message_response2(
        server::Server, msg::Dict{Symbol,Any},
        request_caller::TestRunnerMessageRequestCaller2
    )
    if handle_response_error(server, msg, "show test action (logs)")
        return
    elseif haskey(msg, :result) && msg[:result] !== nothing
        selected = msg[:result] # ::MessageActionItem
        title = get(selected, "title", "")
        (; testset_name, logs) = request_caller
        if title == TESTRUNNER_OPEN_LOGS_TITLE
            open_testsetinfo_logs!(server, testset_name, logs)
        else
            error(lazy"Unknown action: $title")
        end
    end
    # If user cancelled (result is null), do nothing
end

function handle_test_runner_message_response4(
        server::Server, msg::Dict{Symbol,Any},
        request_caller::TestRunnerMessageRequestCaller4
    )
    if handle_response_error(server, msg, "show test actions")
        return
    elseif haskey(msg, :result) && msg[:result] !== nothing
        selected = msg[:result] # ::MessageActionItem
        title = get(selected, "title", "")
        (; testset_name, uri, idx, logs) = request_caller
        if title == TESTRUNNER_RERUN_TITLE
            error_msg = testrunner_run_testset_from_uri(server, uri, idx, testset_name)
            if error_msg !== nothing
                show_error_message(server, error_msg)
            end
        elseif title == TESTRUNNER_OPEN_LOGS_TITLE
            open_testsetinfo_logs!(server, testset_name, logs)
        elseif title == TESTRUNNER_CLEAR_RESULT_TITLE
            try_clear_testrunner_result!(server, uri, idx, testset_name)
        else
            error(lazy"Unknown action: $title")
        end
    end
    # If user cancelled (result is null), do nothing
end

function handle_testrunner_testset_progress_response(
        server::Server, msg::Dict{Symbol,Any},
        request_caller::TestRunnerTestsetProgressCaller, cancel_flag::CancelFlag
    )
    if handle_response_error(server, msg, "create work done progress")
        return
    end
    (; uri, fi, idx, testset_name, filepath, token) = request_caller
    testrunner_run_testset(server, uri, fi, idx, testset_name, filepath; token, cancel_flag)
end

function handle_testrunner_testcase_progress_response(
        server::Server, msg::Dict{Symbol,Any},
        request_caller::TestRunnerTestcaseProgressCaller, cancel_flag::CancelFlag
    )
    if handle_response_error(server, msg, "create work done progress")
        return
    end
    (; uri, testcase_line, testcase_text, filepath, token) = request_caller
    testrunner_run_testcase(server, uri, testcase_line, testcase_text, filepath; token, cancel_flag)
end

function handle_code_lens_refresh_response(
        server::Server, msg::Dict{Symbol,Any}, ::CodeLensRefreshRequestCaller
    )
    if handle_response_error(server, msg, "refresh code lens")
    else
        # just valid request response cycle
    end
end

function handle_formatting_progress_response(
        server::Server, msg::Dict{Symbol, Any}, request_caller::FormattingProgressCaller, cancel_flag::CancelFlag
    )
    if handle_response_error(server, msg, "create work done progress")
        return
    end
    (; uri, msg_id, token) = request_caller
    do_format_with_progress(server, uri, msg_id, token, cancel_flag)
end

function handle_range_formatting_progress_response(
        server::Server, msg::Dict{Symbol, Any}, request_caller::RangeFormattingProgressCaller, cancel_flag::CancelFlag
    )
    if handle_response_error(server, msg, "create work done progress")
        return
    end
    (; uri, range, msg_id, token) = request_caller
    do_range_format_with_progress(server, uri, range, msg_id, token, cancel_flag)
end
