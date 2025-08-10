const TESTRUNNER_DIAGNOSTIC_SOURCE = "JETLS - TestRunner"

const TESTRUNNER_RUN_TITLE = "▶ Run"
const TESTRUNNER_RERUN_TITLE = "▶ Rerun"
const TESTRUNNER_OPEN_LOGS_TITLE = "☰ Open logs"
const TESTRUNNER_CLEAR_RESULT_TITLE = "✓ Clear result"

const TEST_MACROS = [
    "@inferred",
    "@test",
    "@test_broken",
    "@test_deprecated",
    "@test_logs",
    "@test_nowarn",
    "@test_skip",
    "@test_throws",
    "@test_warn"
]

function summary_testrunner_result(result::TestRunnerResult)
    (; n_passed, n_failed, n_errored, n_broken, duration) = result.stats
    n_total = n_passed + n_failed + n_errored + n_broken
    summary = "[ Total: $n_total"
    iszero(n_passed)  || (summary *= " | Pass: $n_passed")
    iszero(n_failed)  || (summary *= " | Fail: $n_failed")
    iszero(n_errored) || (summary *= " | Error: $n_errored")
    iszero(n_broken)  || (summary *= " | Broken: $n_broken")
    duration_str = format_duration(duration)
    summary *= " | Time: $duration_str ]"
    return summary
end

testset_name(testsetinfo::TestsetInfo) = testset_name(testsetinfo.st0)
testset_name(testset::JL.SyntaxTree) = JS.sourcetext(testset[2])
testset_line(testsetinfo::TestsetInfo) = testset_line(testsetinfo.st0)
testset_line(testset::JL.SyntaxTree) = JS.source_line(testset[2])

function update_testsetinfos!(server::Server, fi::FileInfo; notify_server::Bool=true)
    st0_top = build_tree!(JL.SyntaxTree, fi)
    testsets = find_executable_testsets(st0_top)
    m, n = length(testsets), length(fi.testsetinfos)
    if m == n == 0
        return fi.testsetinfos # nothing to do
    end
    any_deleted = false
    for i = 1:max(m, n)
        if i ≤ m
            testsetᵢ = testsets[i]
            if i ≤ n
                testsetinfoᵢ = fi.testsetinfos[i]
                if isdefined(testsetinfoᵢ, :result)
                    key = testsetinfoᵢ.result.key
                    if testset_name(testsetᵢ) == key.testset_name
                        # this `@testset` is likely still begin mapped to the original
                        # testset, so let's keep the result and diagnostics
                        fi.testsetinfos[i] = TestsetInfo(testsetᵢ, testsetinfoᵢ.result)
                    else
                        any_deleted |= clear_extra_diagnostics!(server, key) # === true
                        fi.testsetinfos[i] = TestsetInfo(testsetᵢ)
                    end
                else
                    fi.testsetinfos[i] = TestsetInfo(testsetᵢ)
                end
            else
                push!(fi.testsetinfos, TestsetInfo(testsetᵢ))
            end
        else # i > m && i ≤ n
            testsetinfoᵢ = fi.testsetinfos[i]
            if isdefined(testsetinfoᵢ, :result)
                any_deleted |= clear_extra_diagnostics!(server, testsetinfoᵢ.result.key) # === true
            end
            # `fi.testsetinfos[i]` will be erased by the following `resize!`
        end
    end
    resize!(fi.testsetinfos, m)
    if notify_server && any_deleted
        notify_diagnostics!(server)
    end
    return fi.testsetinfos
end

function traverse_skip_func_scope(@specialize(callback), st0_top::SyntaxTree0)
    testsets = JL.SyntaxList(st0_top)
    stack = JL.SyntaxList(st0_top)
    push!(stack, st0_top)
    while !isempty(stack)
        st0 = pop!(stack)
        if JS.kind(st0) in JS.KSet"function macro"
            # avoid visit inside function scope
            continue
        end
        callback(st0)
        for i = JS.numchildren(st0):-1:1
            push!(stack, st0[i])
        end
    end
    return testsets
end

function find_executable_testsets(st0_top::SyntaxTree0)
    testsets = JL.SyntaxList(st0_top)
    traverse_skip_func_scope(st0_top) do st0::SyntaxTree0
        if JS.kind(st0) === JS.K"macrocall" && JS.numchildren(st0) ≥ 2
            macroname = st0[1]
            if JS.kind(macroname) === JS.K"MacroName" && macroname.name_val == "@testset"
                testsetname = st0[2]
                if JS.kind(testsetname) === JS.K"string"
                    push!(testsets, st0)
                end
            end
        end
    end
    return testsets
end

function testrunner_code_lenses!(code_lenses::Vector{CodeLens}, uri::URI, fi::FileInfo)
    for (idx, testsetinfo) in enumerate(fi.testsetinfos)
        testrunner_code_lenses!(code_lenses, uri, fi, idx, testsetinfo)
    end
    return code_lenses
end

function testrunner_code_lenses!(
        code_lenses::Vector{CodeLens}, uri::URI, fi::FileInfo, idx::Int, testsetinfo::TestsetInfo
    )
    range = jsobj_to_range(testsetinfo.st0, fi)
    tsn = testset_name(testsetinfo)
    clear_arguments = run_arguments = Any[uri, idx, tsn]
    if isdefined(testsetinfo, :result)
        prev_result = testsetinfo.result.result
        let summary = summary_testrunner_result(prev_result)
            command = Command(;
                title = "$TESTRUNNER_RERUN_TITLE $tsn $summary",
                command = COMMAND_TESTRUNNER_RUN_TESTSET,
                arguments = run_arguments)
            push!(code_lenses, CodeLens(;
                range,
                command))
        end
        logs_arguments = Any[tsn, prev_result.logs]
        let command = Command(;
                title = TESTRUNNER_OPEN_LOGS_TITLE,
                command = COMMAND_TESTRUNNER_OPEN_LOGS,
                arguments = logs_arguments)
            push!(code_lenses, CodeLens(;
                range,
                command))
        end
        let command = Command(;
                title = TESTRUNNER_CLEAR_RESULT_TITLE,
                command = COMMAND_TESTRUNNER_CLEAR_RESULT,
                arguments = clear_arguments)
            push!(code_lenses, CodeLens(;
                range,
                command))
        end
    else
        command = Command(;
            title = "$TESTRUNNER_RUN_TITLE $tsn",
            command = COMMAND_TESTRUNNER_RUN_TESTSET,
            arguments = run_arguments)
        push!(code_lenses, CodeLens(;
            range,
            command))
    end
    return code_lenses
end

function testrunner_code_actions!(
        code_actions::Vector{Union{CodeAction,Command}}, uri::URI, fi::FileInfo, action_range::Range
    )
    testrunner_testset_code_actions!(code_actions, uri, fi, action_range)
    testrunner_testcase_code_actions!(code_actions, uri, fi, action_range)
    return code_actions
end

function testrunner_testset_code_actions!(
        code_actions::Vector{Union{CodeAction, Command}}, uri::URI, fi::FileInfo, action_range::Range
    )
    for (idx, testsetinfo) in enumerate(fi.testsetinfos)
        testrunner_testset_code_actions!(code_actions, uri, fi, idx, testsetinfo, action_range)
    end
    return code_actions
end

function testrunner_testset_code_actions!(
        code_actions::Vector{Union{CodeAction, Command}}, uri::URI, fi::FileInfo, idx::Int, testsetinfo::TestsetInfo, action_range::Range
    )
    tsr = jsobj_to_range(testsetinfo.st0, fi; adjust_last=1) # +1 to support cases like `@testset "xxx" begin ... end│`
    overlap(action_range, tsr) || return nothing
    tsn = testset_name(testsetinfo)
    clear_arguments = run_arguments = Any[uri, idx, tsn]
    if isdefined(testsetinfo, :result)
        prev_result = testsetinfo.result.result
        let summary = summary_testrunner_result(prev_result)
            title = "$TESTRUNNER_RERUN_TITLE $tsn $summary"
            command = Command(;
                title,
                command = COMMAND_TESTRUNNER_RUN_TESTSET,
                arguments = run_arguments)
            push!(code_actions, CodeAction(; title, command))
        end
        logs_arguments = Any[tsn, prev_result.logs]
        let title = TESTRUNNER_OPEN_LOGS_TITLE
            command = Command(;
                title,
                command = COMMAND_TESTRUNNER_OPEN_LOGS,
                arguments = logs_arguments)
            push!(code_actions, CodeAction(;
                title,
                command))
        end
        let title = TESTRUNNER_CLEAR_RESULT_TITLE
            command = Command(;
                title,
                command = COMMAND_TESTRUNNER_CLEAR_RESULT,
                arguments = clear_arguments)
            push!(code_actions, CodeAction(;
                title,
                command))
        end
    else
        title = "$TESTRUNNER_RUN_TITLE $tsn"
        command = Command(;
            title,
            command = COMMAND_TESTRUNNER_RUN_TESTSET,
            arguments = run_arguments)
        push!(code_actions, CodeAction(;
            title,
            command))
    end
    return code_actions
end

function testrunner_testcase_code_actions!(
        code_actions::Vector{Union{CodeAction, Command}}, uri::URI, fi::FileInfo, action_range::Range
    )
    st0_top = build_tree!(JL.SyntaxTree, fi)
    traverse_skip_func_scope(st0_top) do st0::SyntaxTree0
        if JS.kind(st0) === JS.K"macrocall" && JS.numchildren(st0) ≥ 1
            macroname = st0[1]
            if JS.kind(macroname) === JS.K"MacroName" && macroname.name_val in TEST_MACROS
                tcr = jsobj_to_range(st0, fi; adjust_last=1) # +1 to support cases like `@test ...│`
                overlap(action_range, tcr) || return nothing
                tcl = JS.source_line(st0)
                tct = "`" * JS.sourcetext(st0) * "`"
                run_arguments = Any[uri, tcl, tct]
                title = "$TESTRUNNER_RUN_TITLE $tct"
                push!(code_actions, CodeAction(;
                    title,
                    command = Command(;
                        title,
                        command = COMMAND_TESTRUNNER_RUN_TESTCASE,
                        arguments = run_arguments)))
            end
        end
    end
    return code_actions
end

# `@testset` execution
function testrunner_cmd(executable::String, filepath::String, tsn::String, tsl::Int, test_env_path::Union{Nothing,String})
    tsn = rlstrip(tsn, '"')
    testrunner_exe = Sys.which(executable)
    if isnothing(test_env_path)
        return `$testrunner_exe --verbose --json $filepath $tsn --filter-lines=$tsl`
    else
        return `$testrunner_exe --verbose --project=$test_env_path --json $filepath $tsn --filter-lines=$tsl`
    end
end

# `@test` execution
function testrunner_cmd(executable::String, filepath::String, tcl::Int, test_env_path::Union{Nothing,String})
    testrunner_exe = Sys.which(executable)
    if isnothing(test_env_path)
        return `$testrunner_exe --verbose --json $filepath L$tcl`
    else
        return `$testrunner_exe --verbose --project=$test_env_path --json $filepath L$tcl`
    end
end

function testrunner_diagnostic_to_related_information(diagnostic::TestRunnerDiagnostic)
    relatedInformation = DiagnosticRelatedInformation[]
    for info in @something diagnostic.relatedInformation return nothing
        info.filename == "none" && continue
        uri = filepath2uri(to_full_path(info.filename))
        range = line_range(fixed_line_number(info.line))
        location = Location(; uri, range)
        message = info.message
        push!(relatedInformation, DiagnosticRelatedInformation(; location, message))
    end
    return relatedInformation
end

function testrunner_result_to_diagnostics(result::TestRunnerResult)
    uri2diagnostics = URI2Diagnostics()
    for diag in result.diagnostics
        uri = filename2uri(to_full_path(diag.filename))
        relatedInformation = testrunner_diagnostic_to_related_information(diag)
        diagnostic = Diagnostic(;
            range = line_range(fixed_line_number(diag.line)),
            severity = DiagnosticSeverity.Error,
            message = diag.message,
            source = TESTRUNNER_DIAGNOSTIC_SOURCE,
            relatedInformation)
        push!(get!(Vector{Diagnostic}, uri2diagnostics, uri), diagnostic)
    end
    return uri2diagnostics
end

struct TestRunnerMessageRequestCaller2 <: RequestCaller
    testset_name::String
    logs::String
end

struct TestRunnerMessageRequestCaller4 <: RequestCaller
    testset_name::String
    uri::URI
    idx::Int
    logs::String
end

function show_testrunner_result_in_message(server::Server, result::TestRunnerResult,
                                           title::String, request_key::String=title;
                                           next_info=nothing,
                                           extra_message::Union{Nothing,String}=nothing)
    summary = summary_testrunner_result(result)
    message = "Test results for $title: $summary"
    if !isnothing(extra_message)
        message *= extra_message
    end

    (; n_failed, n_errored, n_broken) = result.stats
    msg_type = if n_failed > 0 || n_errored > 0
        MessageType.Error
    elseif n_broken > 0
        MessageType.Warning
    else
        MessageType.Info
    end

    if isnothing(next_info)
        actions = MessageActionItem[
            MessageActionItem(; title = TESTRUNNER_OPEN_LOGS_TITLE)
        ]
        request_caller = TestRunnerMessageRequestCaller2(request_key, result.logs)
    else
        actions = MessageActionItem[
            MessageActionItem(; title = TESTRUNNER_RERUN_TITLE)
            MessageActionItem(; title = TESTRUNNER_OPEN_LOGS_TITLE)
            MessageActionItem(; title = TESTRUNNER_CLEAR_RESULT_TITLE)
        ]
        (; uri, idx) = next_info
        request_caller = TestRunnerMessageRequestCaller4(request_key, uri, idx, result.logs)
    end

    id = String(gensym(:ShowMessageRequest))
    server.state.currently_requested[id] = request_caller

    send(server, ShowMessageRequest(;
        id,
        params = ShowMessageRequestParams(;
            type = msg_type,
            message,
            actions)))
end

function testrunner_run_testset(server::Server, uri::URI, fi::FileInfo, idx::Int, tsn::String, filepath::String;
                                token::Union{Nothing,ProgressToken}=nothing)
    executable = get_config(server.state.config_manager, "testrunner", "executable")
    if isnothing(Sys.which(executable))
        is_default_setting = executable == "testrunner"
        show_error_message(server, app_notfound_message(executable, "testrunner", "executable", is_default_setting=is_default_setting))
        return token !== nothing && end_testrunner_progress(server, token, "TestRunner not installed")
    end

    if token !== nothing
        send(server, ProgressNotification(;
            params = ProgressParams(;
                token,
                value = WorkDoneProgressBegin(;
                    title = "Running tests for $tsn",
                    cancellable = false))))
    end

    local result::String
    try
        result = _testrunner_run_testset(server, executable, uri, fi, idx, tsn, filepath)
    catch err
        result = sprint(Base.showerror, err, catch_backtrace())
        @error "Error from testrunner executor" err
        show_error_message(server, """
            An unexpected error occurred while setting up TestRunner.jl or handling the result:
            See the server log for details.
            """)
    finally
        @assert @isdefined(result) "`result` should be defined at this point"
        if token !== nothing
            end_testrunner_progress(server, token, result)
        end
    end
end

# Check if the `@testset` mapping state in `fi.testsetinfos` is still in the expected state
is_testsetinfo_valid(fi::FileInfo, idx::Int, tsn::String) =
    checkbounds(Bool, fi.testsetinfos, idx) && testset_name(fi.testsetinfos[idx]) == tsn

function _testrunner_run_testset(server::Server, executable::AbstractString, uri::URI, fi::FileInfo, idx::Int, tsn::String, filepath::String)
    if !is_testsetinfo_valid(fi, idx, tsn)
        show_warning_message(server, """
            The test structure has changed significantly, so test execution is being cancelled.
            Please run the test again from the code lens or code actions currently displayed in the editor.
            """)
        return "Test execution cancelled"
    end
    tsl = testset_line(fi.testsetinfos[idx])
    test_env_path = find_uri_env_path(server.state, uri)
    cmd = testrunner_cmd(executable, filepath, tsn, tsl, test_env_path)
    testrunnerproc = open(cmd; read=true)
    wait(testrunnerproc)
    result = try
        JSONRPC.JSON3.read(testrunnerproc, TestRunnerResult)
    catch err
        @error "Error from testrunner process" err
        show_error_message(server, """
            An unexpected error occurred while executing TestRunner.jl:
            See the server log for details.
            """)
        return "Test execution failed"
    end

    ret = summary_testrunner_result(result)

    if !is_testsetinfo_valid(fi, idx, tsn)
        # If the file state has changed during test execution, it's difficult to apply results to the file:
        # Simply show only the option to open logs
        show_testrunner_result_in_message(server, result, #=title=#tsn)
        return ret
    end

    key = TestsetDiagnosticsKey(tsn, idx, fi)
    fi.testsetinfos[idx] = TestsetInfo(fi.testsetinfos[idx].st0, TestsetResult(result, key))
    if !isempty(result.diagnostics)
        server.state.extra_diagnostics[key] = testrunner_result_to_diagnostics(result)
    elseif haskey(server.state.extra_diagnostics, key)
        empty!(server.state.extra_diagnostics[key])
    end
    notify_diagnostics!(server)

    if supports(server, :workspace, :codeLens, :refreshSupport)
        request_codelens_refresh!(server)
    end
    show_testrunner_result_in_message(server, result, #=title=#tsn; next_info=(; uri, idx))

    return ret
end

function testrunner_run_testcase(server::Server, uri::URI, tcl::Int, tct::String, filepath::String;
                                 token::Union{Nothing,ProgressToken}=nothing)
    executable = get_config(server.state.config_manager, "testrunner", "executable")
    if isnothing(Sys.which(executable))
        is_default_setting = executable == "testrunner"
        show_error_message(server, app_notfound_message(executable, "testrunner", "executable", is_default_setting=is_default_setting))
        return token !== nothing && end_testrunner_progress(server, token, "TestRunner not installed")
    end

    if token !== nothing
        send(server, ProgressNotification(;
            params = ProgressParams(;
                token,
                value = WorkDoneProgressBegin(;
                    title = "Running test case $tct at L$tcl",
                    cancellable = false))))
    end

    local result::String
    try
        result = _testrunner_run_testcase(server, executable, uri, tcl, tct, filepath)
    catch err
        result = sprint(Base.showerror, err, catch_backtrace())
        @error "Error from testrunner executor" err
        show_error_message(server, """
            An unexpected error occurred while setting up TestRunner.jl or handling the result:
            See the server log for details.
            """)
    finally
        @assert @isdefined(result) "`result` should be defined at this point"
        if token !== nothing
            end_testrunner_progress(server, token, result)
        end
    end
end

function _testrunner_run_testcase(server::Server, executable::AbstractString, uri::URI, tcl::Int, tct::String, filepath::String)
    test_env_path = find_uri_env_path(server.state, uri)
    cmd = testrunner_cmd(executable, filepath, tcl, test_env_path)
    testrunnerproc = open(cmd; read=true)
    wait(testrunnerproc)
    result = try
        JSONRPC.JSON3.read(testrunnerproc, TestRunnerResult)
    catch err
        @error "Error from testrunner process" err
        show_error_message(server, """
            An unexpected error occurred while executing TestRunner.jl:
            See the server log for details.
            """)
        return "Test execution failed"
    end

    # Show the results of this `@test` case temporarily as diagnostics:
    # The `Server` (or `FileInfo`) doesn't track the state of each `@test`,
    # so we can't map editor state to diagnostics.
    # Show error information to the user as temporary diagnostics.
    uri2diagnostics = testrunner_result_to_diagnostics(result)
    notify_temporary_diagnostics!(server, uri2diagnostics)
    @async begin
        sleep(10)
        notify_diagnostics!(server) # refresh diagnostics after 5 sec
    end

    extra_message = isempty(uri2diagnostics) ? nothing : """\n
        Test failures are shown as temporary diagnostics in the editor for 10 seconds.
        Open logs to view detailed error messages that persist."""

    show_testrunner_result_in_message(server, result, "$tct", #=request_key=#""; extra_message)

    return summary_testrunner_result(result)
end

function end_testrunner_progress(server::Server, token::ProgressToken, message::String)
    send(server, ProgressNotification(;
        params = ProgressParams(;
            token,
            value = WorkDoneProgressEnd(;
                message))))
end

struct ShowDocumentRequestCaller <: RequestCaller
    uri::URI
    logs::String
    context::String
end

function open_testsetinfo_logs!(server::Server, tsn::String, logs::String)
    tsn = rlstrip(tsn, '"')
    if supports(server, :window, :showDocument, :support)
        # Use `window/showDocument` to show logs in untitled editor if supported
        untitled_name = "TestRunner_$tsn.log"
        uri = URI(; scheme="untitled", path=untitled_name)
        id = String(gensym(:ShowDocumentRequest))
        context = "showing test logs"
        server.state.currently_requested[id] = ShowDocumentRequestCaller(uri, logs, context)
        send(server, ShowDocumentRequest(;
            id,
            params = ShowDocumentParams(;
                uri,
                takeFocus = true)))
    else
        # Fallback: save to temp file
        temp_filename = "TestRunner_$(tsn)_$(getpid()).log"
        temp_path = joinpath(mktempdir(; cleanup=false), temp_filename)
        try
            write(temp_path, logs)
        catch err
            return show_error_message(server, "Failed to save test logs: $(sprint(showerror, err))")
        end
        uri = filepath2uri(temp_path)
        show_info_message(server, """
        Test logs for $tsn saved to:

        [$temp_path]($uri)
        """)
    end
end

struct TestRunnerTestsetProgressCaller <: RequestCaller
    uri::URI
    fi::FileInfo
    idx::Int
    testset_name::String
    filepath::String
    token::ProgressToken
end

"""
    testrunner_run_testset_from_uri(server::Server, uri::URI, idx::Int) -> Union{Nothing, String}

Run tests for the testset at the given index in the file specified by URI.
Validates that the file exists, is saved, and matches the on-disk version.
Returns `nothing` if the test was started successfully, or an error message string otherwise.
"""
function testrunner_run_testset_from_uri(server::Server, uri::URI, idx::Int, tsn::String)
    fi = @something get_file_info(server.state, uri) begin
        return "File is no longer available in the editor"
    end
    sfi = @something get_saved_file_info(server.state, uri) begin
        return "The file appears not to exist on disk. Save the file first to run tests."
    end
    if JS.sourcetext(fi.parsed_stream) ≠ JS.sourcetext(sfi.parsed_stream)
        return "The editor state differs from the saved file. Save the file first to run tests."
    end
    filepath = @something uri2filepath(uri) return "Cannot determine file path for the URI"

    if supports(server, :window, :workDoneProgress)
        id = String(gensym(:WorkDoneProgressCreateRequest_testrunner))
        token = String(gensym(:TestRunnerProgress))
        server.state.currently_requested[id] = TestRunnerTestsetProgressCaller(uri, fi, idx, tsn, filepath, token)
        params = WorkDoneProgressCreateParams(; token)
        send(server, WorkDoneProgressCreateRequest(; id, params))
    else
        @async testrunner_run_testset(server, uri, fi, idx, tsn, filepath)
    end
    return nothing
end

struct TestRunnerTestcaseProgressCaller <: RequestCaller
    uri::URI
    testcase_line::Int
    testcase_text::String
    filepath::String
    token::ProgressToken
end

function testrunner_run_testcase_from_uri(server::Server, uri::URI, tcl::Int, tct::String)
    fi = @something get_file_info(server.state, uri) begin
        return "File is no longer available in the editor"
    end
    sfi = @something get_saved_file_info(server.state, uri) begin
        return "The file appears not to exist on disk. Save the file first to run tests."
    end
    if JS.sourcetext(fi.parsed_stream) ≠ JS.sourcetext(sfi.parsed_stream)
        return "The editor state differs from the saved file. Save the file first to run tests."
    end
    filepath = @something uri2filepath(uri) return "Cannot determine file path for the URI"

    if supports(server, :window, :workDoneProgress)
        id = String(gensym(:WorkDoneProgressCreateRequest_testrunner))
        token = String(gensym(:TestRunnerProgress))
        server.state.currently_requested[id] = TestRunnerTestcaseProgressCaller(uri, tcl, tct, filepath, token)
        params = WorkDoneProgressCreateParams(; token)
        send(server, WorkDoneProgressCreateRequest(; id, params))
    else
        @async testrunner_run_testcase(server, uri, tcl, tct, filepath)
    end
    return nothing
end

"""
    try_clear_testrunner_result!(server::Server, uri::URI, idx::Int, tsn::String)

Clear test results for the `@testset` whose name is `tsn` at the given `idx` in the file specified by `uri`.
Validates that the file exists and the `@testset` result can be mapped to the current editor state.
"""
function try_clear_testrunner_result!(server::Server, uri::URI, idx::Int, tsn::String)
    fi = @something get_file_info(server.state, uri) begin
        # file is no longer open in the editor, just do nothing and return
        # the clean up should be performed by `handle_DidCloseTextDocumentNotification`
        return nothing
    end

    if !is_testsetinfo_valid(fi, idx, tsn)
        # file is has been modified, just do nothing and return
        # the clean up should be performed by `invalidate_testsetinfos!`
        return nothing
    end

    fi.testsetinfos[idx] = TestsetInfo(fi.testsetinfos[idx].st0)
    if clear_extra_diagnostics!(server, TestsetDiagnosticsKey(tsn, idx, fi))
        notify_diagnostics!(server)
    end

    # Also refresh code lens if supported
    if supports(server, :workspace, :codeLens, :refreshSupport)
        request_codelens_refresh!(server)
    end

    return nothing
end
