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
function testset_name(testset::SyntaxTree)
    desc = testset_description_node(testset)
    return isnothing(desc) ? "" : JS.sourcetext(desc)
end
testset_line(testsetinfo::TestsetInfo) = testset_line(testsetinfo.st0)
function testset_line(testset::SyntaxTree)
    desc = testset_description_node(testset)
    return isnothing(desc) ? JS.source_line(testset) : JS.source_line(desc)
end

# Find the description string node of a `@testset` macrocall.
# Returns `K"String"` for simple literals or `K"string"` for interpolated strings.
# Both include quotes in their sourcetext.
function testset_description_node(testset::SyntaxTree)
    for i = 2:JS.numchildren(testset)
        child = testset[i]
        if JS.kind(child) in JS.KSet"string String"
            return child
        end
    end
    return nothing
end

"""
    compute_testsetinfos!(server::Server, st0::SyntaxTree, prev_testsetinfos::Vector{TestsetInfo})

Compute new testsetinfos from the syntax tree, preserving test results from
previous testsetinfos where testset names match. Clears extra diagnostics for
removed or renamed testsets.

Returns `(testsetinfos, any_deleted)` where `any_deleted` indicates whether any
diagnostics were cleared.
"""
function compute_testsetinfos!(
        server::Server, st0::SyntaxTree, prev_testsetinfos::Vector{TestsetInfo}
    )
    new_testsets = find_executable_testsets(st0)
    m = length(new_testsets)
    n = length(prev_testsetinfos)

    # Clear diagnostics for removed or renamed testsets
    any_deleted = false
    for i = 1:n
        prev_testsetinfoᵢ = prev_testsetinfos[i]
        if isdefined(prev_testsetinfoᵢ, :result)
            if i > m
                # testset was removed
                any_deleted |= clear_extra_diagnostics!(server, prev_testsetinfoᵢ.result.key)
            else
                # check if testset was renamed
                key = prev_testsetinfoᵢ.result.key
                if testset_name(new_testsets[i]) != key.testset_name
                    any_deleted |= clear_extra_diagnostics!(server, key)
                end
            end
        end
    end

    # Build new testsetinfos, preserving results where possible
    testsetinfos = if iszero(m)
        EMPTY_TESTSETINFOS
    else
        new_infos = Vector{TestsetInfo}(undef, m)
        for i = 1:m
            testsetᵢ = new_testsets[i]
            if i ≤ n
                prev_testsetinfoᵢ = prev_testsetinfos[i]
                if isdefined(prev_testsetinfoᵢ, :result)
                    key = prev_testsetinfoᵢ.result.key
                    if testset_name(testsetᵢ) == key.testset_name
                        new_infos[i] = TestsetInfo(testsetᵢ, prev_testsetinfoᵢ.result)
                    else
                        new_infos[i] = TestsetInfo(testsetᵢ)
                    end
                else
                    new_infos[i] = TestsetInfo(testsetᵢ)
                end
            else
                new_infos[i] = TestsetInfo(testsetᵢ)
            end
        end
        new_infos
    end

    return testsetinfos, any_deleted
end

function find_executable_testsets(st0_top::SyntaxTree)
    testsets = JS.SyntaxList()
    traverse(st0_top) do st0::SyntaxTree
        if JS.kind(st0) in JS.KSet"function macro"
            # avoid visit inside function scope
            return traversal_no_recurse
        elseif JS.kind(st0) === JS.K"macrocall" && JS.numchildren(st0) ≥ 2
            macroname = st0[1]
            if get_name_val(macroname) == "@testset"
                if testset_description_node(st0) !== nothing
                    push!(testsets, st0)
                end
            end
        end
    end
    return testsets
end

function testrunner_code_lenses!(
        code_lenses::Vector{CodeLens}, uri::URI, fi::FileInfo
    )
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
            push!(code_lenses, CodeLens(; range, command))
        end
        logs_arguments = Any[uri, idx, tsn]
        let command = Command(;
                title = TESTRUNNER_OPEN_LOGS_TITLE,
                command = COMMAND_TESTRUNNER_OPEN_LOGS,
                arguments = logs_arguments)
            push!(code_lenses, CodeLens(; range, command))
        end
        let command = Command(;
                title = TESTRUNNER_CLEAR_RESULT_TITLE,
                command = COMMAND_TESTRUNNER_CLEAR_RESULT,
                arguments = clear_arguments)
            push!(code_lenses, CodeLens(; range, command))
        end
    else
        command = Command(;
            title = "$TESTRUNNER_RUN_TITLE $tsn",
            command = COMMAND_TESTRUNNER_RUN_TESTSET,
            arguments = run_arguments)
        push!(code_lenses, CodeLens(; range, command))
    end
    return code_lenses
end

testrunner_code_lenses(args...) = # used by tests
    testrunner_code_lenses!(CodeLens[], args...)

function testrunner_code_actions!(
        code_actions::Vector{Union{CodeAction,Command}}, uri::URI, fi::FileInfo, action_range::Range
    )
    testrunner_testset_code_actions!(code_actions, uri, fi, action_range)
    testrunner_testcase_code_actions!(code_actions, uri, fi, action_range)
    return code_actions
end

testrunner_code_actions(args...) = # used by tests
    testrunner_code_actions!(Union{CodeAction,Command}[], args...)

function handle_TestsetsRequest(server::Server, msg::TestsetsRequest, cancel_flag::CancelFlag)
    uri = msg.params.textDocument.uri
    result = get_file_info(server.state, uri, cancel_flag)
    if isnothing(result)
        return send(server, TestsetsResponse(; id = msg.id, result = null))
    elseif result isa ResponseError
        return send(server, TestsetsResponse(; id = msg.id, result = nothing, error = result))
    end
    return send(server, TestsetsResponse(; id = msg.id, result = testset_items(result)))
end

function testset_items(fi::FileInfo)
    return TestsetItem[
        TestsetItem(;
            index,
            name = testset_name(testsetinfo),
            range = jsobj_to_range(testsetinfo.st0, fi))
        for (index, testsetinfo) in enumerate(fi.testsetinfos)]
end

function testrunner_testset_code_actions!(
        code_actions::Vector{Union{CodeAction,Command}}, uri::URI, fi::FileInfo,
        action_range::Range
    )
    for (idx, testsetinfo) in enumerate(fi.testsetinfos)
        testrunner_testset_code_actions!(code_actions, uri, fi, idx, testsetinfo, action_range)
    end
    return code_actions
end

function testrunner_testset_code_actions!(
        code_actions::Vector{Union{CodeAction,Command}}, uri::URI, fi::FileInfo, idx::Int, testsetinfo::TestsetInfo, action_range::Range
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
        logs_arguments = Any[uri, idx, tsn]
        let title = TESTRUNNER_OPEN_LOGS_TITLE
            command = Command(;
                title,
                command = COMMAND_TESTRUNNER_OPEN_LOGS,
                arguments = logs_arguments)
            push!(code_actions, CodeAction(; title, command))
        end
        let title = TESTRUNNER_CLEAR_RESULT_TITLE
            command = Command(;
                title,
                command = COMMAND_TESTRUNNER_CLEAR_RESULT,
                arguments = clear_arguments)
            push!(code_actions, CodeAction(; title, command))
        end
    else
        title = "$TESTRUNNER_RUN_TITLE $tsn"
        command = Command(;
            title,
            command = COMMAND_TESTRUNNER_RUN_TESTSET,
            arguments = run_arguments)
        push!(code_actions, CodeAction(; title, command))
    end
    return code_actions
end

function testrunner_testcase_code_actions!(
        code_actions::Vector{Union{CodeAction,Command}}, uri::URI, fi::FileInfo, action_range::Range
    )
    st0_top = build_syntax_tree(fi)
    traverse(st0_top) do st0::SyntaxTree
        if JS.kind(st0) in JS.KSet"function macro"
            # avoid visit inside function scope
            return traversal_no_recurse
        elseif JS.kind(st0) === JS.K"macrocall" && JS.numchildren(st0) ≥ 1
            macroname = st0[1]
            if get_name_val(macroname) in TEST_MACROS
                tcr = jsobj_to_range(st0, fi; adjust_last=1) # +1 to support cases like `@test ...│`
                overlap(action_range, tcr) || return nothing
                tcl = JS.source_line(st0)
                tct = backtick(JS.sourcetext(st0))
                run_arguments = Any[uri, tcl, tct]
                title = "$TESTRUNNER_RUN_TITLE $tct"
                command = Command(;
                    title,
                    command = COMMAND_TESTRUNNER_RUN_TESTCASE,
                    arguments = run_arguments)
                push!(code_actions, CodeAction(; title, command))
            end
        end
    end
    return code_actions
end

# Returns the workspace root to feed `testrunner` as `--root-path`, but only
# when needed: for unsaved (`untitled:`/`buffer:`) URIs the `filepath` we send
# has no `dirname`, so the runner needs an explicit base for relative
# `include` calls. Saved files have a real `dirname` and should rely on it.
function testrunner_root_path(state::ServerState, uri::URI)
    isunsaveduri(uri) || return nothing
    return isdefined(state, :root_path) ? state.root_path : nothing
end

# `julia -m TestRunner` resolves `TestRunner` by name like its Pkg app shim does, which
# requires the root project of the environment JETLS is loaded from. It is captured at load
# time since the server replaces `LOAD_PATH` afterwards (see `@with_cli_LOAD_PATH`).
const testrunner_load_path = Ref{Union{Nothing,String}}(nothing)
push_init_hook!() do
    testrunner_load_path[] = try
        find_testrunner_load_path()
    catch err
        @error "Failed to locate the environment of TestRunner.jl"
        locked_display_error(stderr, err, catch_backtrace())
        nothing
    end
end

function find_testrunner_load_path()
    pkgid = Base.PkgId(TestRunner)
    (_, env) = @something (@lock Base.require_lock Base.locate_package_env(pkgid)) return nothing
    return @something find_testrunner_load_path(env, pkgid) begin
        @warn "TestRunner.jl is not a direct dependency of the root project of the environment JETLS is loaded from" env
        nothing
    end
end

function find_testrunner_load_path(env::String, pkgid::Base.PkgId)
    project_file = Base.env_project_file(env)
    project_file isa String || return nothing
    manifest_file = @something Base.project_file_manifest_path(project_file) return nothing
    load_path = dirname(manifest_file)
    root_project_file = Base.env_project_file(load_path)
    root_project_file isa String || return nothing
    Base.explicit_project_deps_get(root_project_file, pkgid.name) == pkgid.uuid || return nothing
    return load_path
end

struct TestRunnerLauncher
    julia::Cmd
    julia_args::Vector{String}
    env::Vector{Pair{String,Union{Nothing,String}}}
end

# Selects the Julia executable in the same way as the managed installations of the clients:
# `JULIA_APPS_JULIA_CMD` names the executable, `JULIAUP_CHANNEL` selects a channel of the
# `julia` launcher, and tests run with the Julia running JETLS otherwise.
function testrunner_launcher(server::Server)
    load_path = @something testrunner_load_path[] begin
        return "Failed to locate the environment of TestRunner.jl bundled with JETLS."
    end
    env = get_config(server, :testrunner, :env)
    julia_cmd = if haskey(env, "JULIA_APPS_JULIA_CMD")
        julia = env["JULIA_APPS_JULIA_CMD"]
        exe = @something Sys.which(julia) begin
            return app_notfound_message(julia) * check_settings_message(:testrunner, :env)
        end
        `$exe`
    elseif haskey(env, "JULIAUP_CHANNEL")
        exe = @something Sys.which("julia") begin
            return app_notfound_message("julia") * check_settings_message(:testrunner, :env)
        end
        `$exe`
    else
        Base.julia_cmd()
    end
    julia_args = get_config(server, :testrunner, :julia_args)
    launcher_env = Pair{String,Union{Nothing,String}}[
        env...,
        "JULIA_LOAD_PATH" => load_path,
        "JULIA_PROJECT" => nothing]
    return TestRunnerLauncher(julia_cmd, julia_args, launcher_env)
end

# `julia_args` follows `--project` so that it can override the detected test environment.
function testrunner_cmd(launcher::TestRunnerLauncher, test_env_path::Union{Nothing,String},
                        args::Cmd)
    project_args = isnothing(test_env_path) ? `` : `--project=$test_env_path`
    cmd = `$(launcher.julia) --startup-file=no $project_args $(launcher.julia_args) -m TestRunner $args`
    return addenv(cmd, launcher.env...)
end

# `@testset` execution
function testrunner_testset_cmd(launcher::TestRunnerLauncher, filepath::String,
                                lines::Vector{UnitRange{Int}},
                                test_env_path::Union{Nothing,String},
                                root_path::Union{Nothing,String})
    # `--root-path` only matters when `filepath` is a virtual identifier
    # (no `dirname`); for saved files we omit it to avoid implying a
    # workspace-relative include base that doesn't apply.
    root_args = isnothing(root_path) ? `` : `--root-path=$root_path`
    # Select `@testset`s by their lines rather than their names, since name patterns can't
    # match interpolated names
    patterns = String["L$(first(range)):$(last(range))" for range in lines]
    return testrunner_cmd(launcher, test_env_path,
        `--verbose $root_args --json --read-stdin $filepath $patterns`)
end

# `@test` execution
function testrunner_testcase_cmd(launcher::TestRunnerLauncher, filepath::String, tcl::Int,
                                 test_env_path::Union{Nothing,String},
                                 root_path::Union{Nothing,String})
    # See `testrunner_testset_cmd` for the rationale behind `--root-path`.
    root_args = isnothing(root_path) ? `` : `--root-path=$root_path`
    return testrunner_cmd(launcher, test_env_path,
        `--verbose $root_args --json --read-stdin $filepath L$tcl`)
end

function testrunner_diagnostic_to_related_information(diagnostic::TestRunnerDiagnostic)
    relatedInformation = DiagnosticRelatedInformation[]
    for info in @something diagnostic.relatedInformation return nothing
        info.filename == "none" && continue
        uri = to_valid_uri(info.filename)
        range = line_range(info.line)
        location = Location(; uri, range)
        message = info.message
        push!(relatedInformation, DiagnosticRelatedInformation(; location, message))
    end
    return relatedInformation
end

function testrunner_result_to_diagnostics(result::TestRunnerResult)
    uri2diagnostics = URI2Diagnostics()
    for diag in result.diagnostics
        uri = to_valid_uri(diag.filename)
        relatedInformation = testrunner_diagnostic_to_related_information(diag)
        diagnostic = Diagnostic(;
            range = line_range(diag.line),
            severity = DiagnosticSeverity.Error,
            message = diag.message,
            source = DIAGNOSTIC_SOURCE_EXTRA,
            code = TESTRUNNER_TEST_FAILURE_CODE,
            codeDescription = diagnostic_code_description(TESTRUNNER_TEST_FAILURE_CODE),
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

    id = unique_id("ShowMessageRequest")
    addrequest!(server, id=>request_caller)

    params = ShowMessageRequestParams(; type = msg_type, message, actions)
    send(server, ShowMessageRequest(; id, params))
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
            open_testsetinfo_logs!(server, testset_name, logs; source_uri=uri, testset_index=idx)
        elseif title == TESTRUNNER_CLEAR_RESULT_TITLE
            try_clear_testrunner_result!(server, uri, idx, testset_name)
        else
            error(lazy"Unknown action: $title")
        end
    end
    # If user cancelled (result is null), do nothing
end

testrunner_run_cancelled() = TestRunnerRunResult(;
    status = TestRunnerRunStatus.Cancelled,
    message = "Test execution cancelled by user")

testrunner_run_errored(message::String) = TestRunnerRunResult(;
    status = TestRunnerRunStatus.Errored,
    message)

function testrunner_run_completed(
        result::TestRunnerResult;
        testsets::Union{Nothing,Vector{TestsetRunResult}} = nothing
    )
    return TestRunnerRunResult(;
        status = TestRunnerRunStatus.Completed,
        message = summary_testrunner_result(result),
        stats = testrunner_run_stats(result.stats),
        failures = testrunner_run_failures(result.diagnostics),
        logs = result.logs,
        testsets)
end

function testrunner_run_stats(stats::TestRunnerStats)
    (; n_passed, n_failed, n_errored, n_broken, duration) = stats
    return TestRunnerRunStats(;
        passed = n_passed, failed = n_failed, errored = n_errored, broken = n_broken,
        duration)
end

function testrunner_run_failures(diagnostics::Vector{TestRunnerDiagnostic})
    failures = TestRunnerRunFailure[]
    for diag in diagnostics
        location = Location(;
            uri = to_valid_uri(diag.filename),
            range = line_range(diag.line))
        relatedInformation = testrunner_diagnostic_to_related_information(diag)
        push!(failures,
            TestRunnerRunFailure(; location, message = diag.message, relatedInformation))
    end
    return failures
end

function testset_run_results(results::Dict{Int,TestRunnerResult})
    return TestsetRunResult[
        TestsetRunResult(;
            index,
            stats = testrunner_run_stats(result.stats),
            failures = testrunner_run_failures(result.diagnostics))
        for (index, result) in sort!(collect(results); by = first)]
end

"""
    run_testrunner(f, server::Server, title::String;
                   cancellable_token, request_id) -> TestRunnerRunResult

Run `f(launcher::TestRunnerLauncher)::TestRunnerRunResult` while reporting the progress on
`cancellable_token`, then answer the `jetls/runTestsets` request of `request_id`, if any,
with the result.
"""
function run_testrunner(
        f, server::Server, title::String;
        cancellable_token::Union{Nothing,CancellableToken},
        request_id::Union{Nothing,MessageId}
    )
    progress_token = cancellable_token === nothing ? nothing : cancellable_token.token
    local result::TestRunnerRunResult
    try
        launcher = testrunner_launcher(server)
        if launcher isa String
            show_error_message(server, launcher)
            result = testrunner_run_errored("Failed to launch TestRunner")
        else
            if !isnothing(progress_token)
                send_progress(server, progress_token,
                    WorkDoneProgressBegin(; cancellable = true, title))
            end
            result = f(launcher)
        end
    catch err
        result = testrunner_run_errored(sprint(locked_showerror, err, catch_backtrace()))
        @error "Error from testrunner executor" err
        show_error_message(server, """
            An unexpected error occurred while setting up TestRunner.jl or handling the result:
            See the server log for details.
            """)
    finally
        @assert @isdefined(result) "`result` should be defined at this point"
        if !isnothing(progress_token)
            send_progress(server, progress_token,
                WorkDoneProgressEnd(; message = result.message))
        end
        if !isnothing(request_id)
            send(server, RunTestsetsResponse(; id = request_id, result))
        end
    end
    return result
end

struct TestsetTarget
    idx::Int
    tsn::String
end

function testrunner_run_testset(
        server::Server, uri::URI, fi::FileInfo, idx::Int, tsn::String, filepath::String;
        cancellable_token::Union{Nothing,CancellableToken} = nothing
    )
    return run_testrunner(server, "Running tests for $tsn";
                          cancellable_token, request_id = nothing) do launcher::TestRunnerLauncher
        _testrunner_run_testsets(server, launcher, uri, fi, [TestsetTarget(idx, tsn)],
            filepath; cancellable_token, show_result_message = true)
    end
end

function handle_RunTestsetsRequest(
        server::Server, msg::RunTestsetsRequest, cancel_flag::CancelFlag
    )
    (; textDocument, testsets, workDoneToken) = msg.params
    if isempty(testsets)
        return send(server,
            RunTestsetsResponse(;
                id = msg.id,
                result = nothing,
                error = request_failed_error("No `@testset` to run is specified")))
    end
    uri = textDocument.uri
    result = get_file_info(server.state, uri, cancel_flag)
    if isnothing(result)
        return send(server,
            RunTestsetsResponse(;
                id = msg.id,
                result = nothing,
                error = request_failed_error("File is no longer available in the editor")))
    elseif result isa ResponseError
        return send(server, RunTestsetsResponse(; id = msg.id, result = nothing, error = result))
    end
    fi = result
    targets = TestsetTarget[TestsetTarget(testset.index, testset.name) for testset in testsets]
    title = length(targets) == 1 ?
        "Running tests for $(only(targets).tsn)" :
        "Running tests for $(length(targets)) test sets"
    cancellable_token = CancellableToken(workDoneToken, cancel_flag)
    run_testrunner(server, title; cancellable_token, request_id = msg.id) do launcher::TestRunnerLauncher
        _testrunner_run_testsets(server, launcher, uri, fi, targets, uri2filename(uri);
            cancellable_token, show_result_message = false)
    end
    return nothing
end

# Check if the `@testset` mapping state in testsetinfos is still in the expected state
is_testsetinfo_valid(fi::FileInfo, idx::Int) = checkbounds(Bool, fi.testsetinfos, idx)
function is_testsetinfo_valid(server::Server, uri::URI, fi::FileInfo, idx::Int)
    current_fi = get_file_info(server.state, uri)
    current_fi === nothing && return false
    current_fi !== fi && return false
    return is_testsetinfo_valid(fi, idx)
end

function read_testrunner_output(
        testrunnerproc::Base.Process, cancellable_token::Union{Nothing,CancellableToken}
    )
    cancelled = Ref(false)
    cancellation_task = if cancellable_token === nothing
        nothing
    else
        @async begin
            while process_running(testrunnerproc)
                if is_cancelled(cancellable_token.cancel_flag)
                    cancelled[] = true
                    kill(testrunnerproc)
                    break
                end
                sleep(0.1)
            end
            if is_cancelled(cancellable_token.cancel_flag)
                cancelled[] = true
            end
        end
    end
    try
        output = read(testrunnerproc)
        process_success = success(testrunnerproc)
        if cancellation_task !== nothing
            wait(cancellation_task; throw = false)
        end
        return (; output, process_success, cancelled = cancelled[])
    finally
        close(testrunnerproc)
        if process_running(testrunnerproc)
            kill(testrunnerproc)
        end
        wait(testrunnerproc)
        if cancellation_task !== nothing
            wait(cancellation_task; throw = false)
        end
    end
end

function log_testrunner_failure(
        cmd::Cmd, proc::Base.Process, output::Vector{UInt8}, reason::Symbol;
        parse_error::Union{Nothing,String} = nothing
    )
    details = (;
        cmd = Cmd(cmd.exec), # omit the environment, which may contain secrets
        exitcode = proc.exitcode,
        termsignal = proc.termsignal,
        stdout_bytes = length(output),
        reason,
        parse_error,
    )
    @error "TestRunner execution failed" details
    return nothing
end

function read_testrunner_result(
        server::Server, cmd::Cmd, source::String;
        cancellable_token::Union{Nothing,CancellableToken} = nothing
    )
    testrunnerproc = open(pipeline(cmd; stdin = IOBuffer(source)); read = true)
    (; output, process_success, cancelled) =
        read_testrunner_output(testrunnerproc, cancellable_token)
    cancelled && return testrunner_run_cancelled()

    result = try
        LSP.JSON3.read(output, TestRunnerResult)
    catch err
        if process_success
            parse_error = sprint(locked_showerror, err, catch_backtrace())
            log_testrunner_failure(cmd, testrunnerproc, output, :invalid_output; parse_error)
        else
            log_testrunner_failure(cmd, testrunnerproc, output, :process)
        end
        show_error_message(server, """
        An unexpected error occurred while executing TestRunner.jl:
        See the server log for details.
        """)
        return testrunner_run_errored("Test execution failed")
    end

    expected_test_failure =
        testrunnerproc.termsignal == 0 &&
        testrunnerproc.exitcode == 1 &&
        (!iszero(result.stats.n_failed) || !iszero(result.stats.n_errored))
    if !process_success && !expected_test_failure
        log_testrunner_failure(cmd, testrunnerproc, output, :process)
        show_error_message(server, """
        An unexpected error occurred while executing TestRunner.jl:
        See the server log for details.
        """)
        return testrunner_run_errored("Test execution failed")
    end
    return result
end

function _testrunner_run_testsets(
        server::Server, launcher::TestRunnerLauncher, uri::URI, fi::FileInfo,
        targets::Vector{TestsetTarget}, filepath::String;
        cancellable_token::Union{Nothing, CancellableToken} = nothing,
        show_result_message::Bool = true
    )
    if !all(target -> is_testset_target_valid(server, uri, fi, target), targets)
        show_warning_message(server, """
            The test structure has changed significantly, so test execution is being cancelled.
            Please run the test again from the code lens or code actions currently displayed in the editor.
            """)
        return testrunner_run_errored("Test execution cancelled due to test structure changes")
    end
    targets = outermost_testset_targets(fi, targets)

    lines = UnitRange{Int}[testset_lines(fi, target.idx) for target in targets]
    test_env_path = find_uri_env_path(server.state, uri)
    root_path = testrunner_root_path(server.state, uri)
    cmd = testrunner_testset_cmd(launcher, filepath, lines, test_env_path, root_path)
    source = String(document_text(fi))
    result = read_testrunner_result(server, cmd, source; cancellable_token)
    result isa TestRunnerRunResult && return result

    results = testset_results(fi, result)
    target_results = Pair{TestsetTarget,TestRunnerResult}[
        target => results[target.idx] for target in targets if haskey(results, target.idx)]
    completed = testrunner_run_completed(result; testsets = testset_run_results(results))

    # Update testsetinfos with the new results atomically
    updated = store!(server.state.file_cache) do cache
        current_fi = get(cache, uri, nothing)
        if current_fi === nothing ||
           !all(target -> is_testsetinfo_valid(current_fi, target.idx), targets)
            return cache, false
        end
        new_infos = copy(current_fi.testsetinfos)
        for (target, target_result) in target_results
            key = TestsetDiagnosticsKey(uri, target.tsn, target.idx)
            new_infos[target.idx] =
                TestsetInfo(new_infos[target.idx].st0, TestsetResult(target_result, key))
        end
        new_fi = FileInfo(current_fi; testsetinfos=new_infos)
        Base.PersistentDict(cache, uri => new_fi), true
    end
    first_target = first(targets)
    if !updated
        # If the file state has changed during test execution, it's difficult to apply results to the file:
        # Simply show only the option to open logs
        show_result_message &&
            show_testrunner_result_in_message(server, result, #=title=#first_target.tsn)
        return completed
    end

    for (target, target_result) in target_results
        if supports_text_document_content(server)
            log_uri = testsetinfo_logs_content_uri(uri, target.idx, String(rlstrip(target.tsn, '"')))
            update_text_document_content!(server, log_uri, target_result.logs)
        end
        update_testset_diagnostics!(server,
            TestsetDiagnosticsKey(uri, target.tsn, target.idx), target_result)
    end
    notify_diagnostics!(server; ensure_cleared=uri)

    if supports(server, :workspace, :codeLens, :refreshSupport)
        request_codelens_refresh!(server)
    end
    show_result_message && show_testrunner_result_in_message(server, result,
        #=title=#first_target.tsn; next_info=(; uri, idx = first_target.idx))

    return completed
end

is_testset_target_valid(server::Server, uri::URI, fi::FileInfo, target::TestsetTarget) =
    is_testsetinfo_valid(server, uri, fi, target.idx) &&
    testset_name(fi.testsetinfos[target.idx]) == target.tsn

function testset_lines(fi::FileInfo, idx::Int)
    range = jsobj_to_range(fi.testsetinfos[idx].st0, fi)
    return (Int(range.start.line) + 1):(Int(range.var"end".line) + 1)
end

# Drops the targets nested in other targets, since they are run as parts of the others anyway
function outermost_testset_targets(fi::FileInfo, targets::Vector{TestsetTarget})
    targets = unique(target -> target.idx, targets)
    lines = UnitRange{Int}[testset_lines(fi, target.idx) for target in targets]
    is_nested(i::Int, j::Int) = i != j && lines[i] ⊆ lines[j] && (lines[i] != lines[j] || j < i)
    return TestsetTarget[targets[i] for i in eachindex(targets)
        if !any(j -> is_nested(i, j), eachindex(targets))]
end

"""
    testset_results(fi::FileInfo, result::TestRunnerResult) -> Dict{Int,TestRunnerResult}

Map the results of the test sets reported by TestRunner to the `@testset`s of `fi` by their
lines, keyed by the indices of the `@testset`s. The results of a `@testset` executed multiple
times (e.g. in a loop) are summed up.
"""
function testset_results(fi::FileInfo, result::TestRunnerResult)
    results = Dict{Int,TestRunnerResult}()
    testsets = @something result.testsets return results
    line_to_idx = Dict{Int,Int}()
    for idx in eachindex(fi.testsetinfos)
        get!(line_to_idx, first(testset_lines(fi, idx)), idx)
    end
    return collect_testset_results!(results, line_to_idx, result, testsets)
end

function collect_testset_results!(
        results::Dict{Int,TestRunnerResult}, line_to_idx::Dict{Int,Int},
        run_result::TestRunnerResult, testsets::Vector{TestRunnerTestSetResult}
    )
    for testset in testsets
        line = testset.line
        idx = line === nothing ? nothing : get(line_to_idx, line, nothing)
        if idx !== nothing
            diagnostics = collect_testset_diagnostics!(TestRunnerDiagnostic[], testset)
            prev = get(results, idx, nothing)
            results[idx] = TestRunnerResult(;
                filename = run_result.filename,
                stats = prev === nothing ? testset.stats :
                    add_testrunner_stats(prev.stats, testset.stats),
                logs = run_result.logs,
                diagnostics = prev === nothing ? diagnostics : vcat(prev.diagnostics, diagnostics))
        end
        collect_testset_results!(results, line_to_idx, run_result, testset.children)
    end
    return results
end

function collect_testset_diagnostics!(
        diagnostics::Vector{TestRunnerDiagnostic}, testset::TestRunnerTestSetResult
    )
    append!(diagnostics, testset.diagnostics)
    for child in testset.children
        collect_testset_diagnostics!(diagnostics, child)
    end
    return diagnostics
end

add_testrunner_stats(a::TestRunnerStats, b::TestRunnerStats) = TestRunnerStats(;
    n_passed = a.n_passed + b.n_passed,
    n_failed = a.n_failed + b.n_failed,
    n_errored = a.n_errored + b.n_errored,
    n_broken = a.n_broken + b.n_broken,
    duration = a.duration + b.duration)

function update_testset_diagnostics!(
        server::Server, key::TestsetDiagnosticsKey, result::TestRunnerResult
    )
    if !isempty(result.diagnostics)
        val = testrunner_result_to_diagnostics(result)
        store!(server.state.extra_diagnostics) do data
            return ExtraDiagnosticsData(data, key=>val), nothing
        end
    else
        store!(server.state.extra_diagnostics) do data
            if haskey(data, key)
                new_data = copy(data)
                delete!(new_data, key)
                new_data, nothing
            else
                data, nothing
            end
        end
    end
    return nothing
end

function testrunner_run_testcase(
        server::Server, uri::URI, tcl::Int, tct::String, filepath::String, source::String;
        cancellable_token::Union{Nothing,CancellableToken} = nothing
    )
    return run_testrunner(server, "Running test case $tct at L$tcl";
                          cancellable_token, request_id = nothing) do launcher::TestRunnerLauncher
        _testrunner_run_testcase(server, launcher, uri, tcl, tct, filepath, source;
            cancellable_token)
    end
end

function _testrunner_run_testcase(
        server::Server, launcher::TestRunnerLauncher, uri::URI, tcl::Int, tct::String,
        filepath::String, source::String;
        cancellable_token::Union{Nothing,CancellableToken} = nothing
    )
    test_env_path = find_uri_env_path(server.state, uri)
    root_path = testrunner_root_path(server.state, uri)
    cmd = testrunner_testcase_cmd(launcher, filepath, tcl, test_env_path, root_path)
    result = read_testrunner_result(server, cmd, source; cancellable_token)
    result isa TestRunnerRunResult && return result

    # Show the results of this `@test` case temporarily as diagnostics:
    # The `Server` (or `FileInfo`) doesn't track the state of each `@test`,
    # so we can't map editor state to diagnostics.
    # Show error information to the user as temporary diagnostics.
    uri2diagnostics = testrunner_result_to_diagnostics(result)
    notify_temporary_diagnostics!(server, uri2diagnostics)
    Threads.@spawn begin
        sleep(10)
        notify_diagnostics!(server; ensure_cleared=uri) # refresh diagnostics after 5 sec
    end

    extra_message = isempty(uri2diagnostics) ? nothing : """\n
        Test failures are shown as temporary diagnostics in the editor for 10 seconds.
        Open logs to view detailed error messages that persist."""

    show_testrunner_result_in_message(server, result, "$tct", #=request_key=#""; extra_message)

    return testrunner_run_completed(result)
end

is_testsetinfo_logs_filename_unsafe(c::Char) =
    isspace(c) || iscntrl(c) ||
    c in ('%', '/', '\\', '?', '#', '<', '>', ':', '"', '|', '*')

# This builds a filesystem name, not a URI component. Keep Unicode names as-is
# and let `filepath2uri` percent-encode the final path; putting literal `%XX`
# escapes in the filename would show up as `%25XX` in `file:` links.
function testsetinfo_logs_filename(tsn::AbstractString)
    io = IOBuffer()
    last_replaced = false
    for c in tsn
        if is_testsetinfo_logs_filename_unsafe(c)
            if !last_replaced
                print(io, '_')
                last_replaced = true
            end
        else
            print(io, c)
            last_replaced = false
        end
    end
    name = strip(String(take!(io)), '_')
    isempty(name) && (name = "testset")
    length(name) > 80 && (name = first(name, 80))
    return "TestRunner_$name.log"
end

function testsetinfo_logs_content_uri(source_uri::URI, idx::Int, tsn::AbstractString)
    query = LSP.URIs2.escapeuri((source=string(source_uri), index=idx, name=tsn))
    return URI(; scheme = TESTRUNNER_LOGS_SCHEME, path = "/testrunner/logs", query)
end

# Look up the logs of the testset at `idx` in `uri`. Returns `nothing` if the file or
# its result is gone (e.g. cleared, or the file changed since the code lens / action
# that carries this `idx` was generated), so the caller can degrade gracefully.
function get_testsetinfo_logs(state::ServerState, uri::URI, idx::Int)
    fi = @something get_file_info(state, uri) return nothing
    is_testsetinfo_valid(fi, idx) || return nothing
    testsetinfo = fi.testsetinfos[idx]
    isdefined(testsetinfo, :result) || return nothing
    return testsetinfo.result.result.logs
end

function open_testsetinfo_logs!(
        server::Server, tsn::String, logs::String;
        source_uri::Union{Nothing,URI} = nothing,
        testset_index::Union{Nothing,Int} = nothing
    )
    testset_name = String(rlstrip(tsn, '"'))
    content_uri = source_uri !== nothing && testset_index !== nothing ?
        testsetinfo_logs_content_uri(source_uri, testset_index, testset_name) : nothing
    return open_text_document_content!(server, content_uri,
        #=label=# "test logs for `$testset_name`",
        #=tempfile_name=# testsetinfo_logs_filename(testset_name),
        ProduceText(() -> logs))
end

struct TestRunnerTestsetProgressCaller <: RequestCaller
    uri::URI
    fi::FileInfo
    idx::Int
    testset_name::String
    filepath::String
    token::ProgressToken
end
cancellable_token_impl(rc::TestRunnerTestsetProgressCaller) = rc.token

"""
    testrunner_run_testset_from_uri(server::Server, uri::URI, idx::Int) -> Union{Nothing, String}

Run tests for the testset at the given index in the file specified by URI.
The current editor buffer is piped to TestRunner via stdin, so the file does not need to be saved.
Returns `nothing` if the test was started successfully, or an error message string otherwise.
"""
function testrunner_run_testset_from_uri(server::Server, uri::URI, idx::Int, tsn::String)
    fi = @something get_file_info(server.state, uri) begin
        return "File is no longer available in the editor"
    end
    filepath = uri2filename(uri)

    if supports(server, :window, :workDoneProgress)
        id = unique_id("WorkDoneProgressCreateRequest_testrunner")
        token = unique_id("TestRunnerProgress")
        addrequest!(server, id=>TestRunnerTestsetProgressCaller(uri, fi, idx, tsn, filepath, token))
        params = WorkDoneProgressCreateParams(; token)
        send(server, WorkDoneProgressCreateRequest(; id, params))
    else
        testrunner_run_testset(server, uri, fi, idx, tsn, filepath)
    end
    return nothing
end

function handle_testrunner_testset_progress_response(
        server::Server, msg::Dict{Symbol,Any},
        request_caller::TestRunnerTestsetProgressCaller, cancel_flag::CancelFlag
    )
    if handle_response_error(server, msg, "create work done progress")
        return
    end
    (; uri, fi, idx, testset_name, filepath, token) = request_caller
    cancellable_token = CancellableToken(token, cancel_flag)
    testrunner_run_testset(server, uri, fi, idx, testset_name, filepath; cancellable_token)
end

struct TestRunnerTestcaseProgressCaller <: RequestCaller
    uri::URI
    testcase_line::Int
    testcase_text::String
    filepath::String
    source::String
    token::ProgressToken
end
cancellable_token_impl(rc::TestRunnerTestcaseProgressCaller) = rc.token

function testrunner_run_testcase_from_uri(server::Server, uri::URI, tcl::Int, tct::String)
    fi = @something get_file_info(server.state, uri) begin
        return "File is no longer available in the editor"
    end
    filepath = uri2filename(uri)
    source = String(document_text(fi))

    if supports(server, :window, :workDoneProgress)
        id = unique_id("WorkDoneProgressCreateRequest_testrunner")
        token = unique_id("TestRunnerProgress")
        addrequest!(server, id=>TestRunnerTestcaseProgressCaller(uri, tcl, tct, filepath, source, token))
        params = WorkDoneProgressCreateParams(; token)
        send(server, WorkDoneProgressCreateRequest(; id, params))
    else
        testrunner_run_testcase(server, uri, tcl, tct, filepath, source)
    end
    return nothing
end

function handle_testrunner_testcase_progress_response(
        server::Server, msg::Dict{Symbol,Any},
        request_caller::TestRunnerTestcaseProgressCaller, cancel_flag::CancelFlag
    )
    if handle_response_error(server, msg, "create work done progress")
        return
    end
    (; uri, testcase_line, testcase_text, filepath, source, token) = request_caller
    cancellable_token = CancellableToken(token, cancel_flag)
    testrunner_run_testcase(server, uri, testcase_line, testcase_text, filepath, source; cancellable_token)
end

"""
    try_clear_testrunner_result!(server::Server, uri::URI, idx::Int, tsn::String)

Clear test results for the `@testset` whose name is `tsn` at the given `idx` in the file specified by `uri`.
Validates that the file exists and the `@testset` result can be mapped to the current editor state.
"""
function try_clear_testrunner_result!(server::Server, uri::URI, idx::Int, tsn::String)
    # Update testsetinfos to clear the result atomically
    updated = store!(server.state.file_cache) do cache
        fi = get(cache, uri, nothing)
        if fi === nothing || !is_testsetinfo_valid(fi, idx)
            # file is no longer open or has been modified, just do nothing
            return cache, false
        end
        new_infos = copy(fi.testsetinfos)
        new_infos[idx] = TestsetInfo(new_infos[idx].st0)
        new_fi = FileInfo(fi; testsetinfos=new_infos)
        Base.PersistentDict(cache, uri => new_fi), true
    end
    updated || return nothing

    if supports_text_document_content(server)
        log_uri = testsetinfo_logs_content_uri(uri, idx, String(rlstrip(tsn, '"')))
        delete_text_document_content!(server, log_uri)
    end

    if clear_extra_diagnostics!(server, TestsetDiagnosticsKey(uri, tsn, idx))
        notify_diagnostics!(server; ensure_cleared=uri)
    end

    # Also refresh code lens if supported
    if supports(server, :workspace, :codeLens, :refreshSupport)
        request_codelens_refresh!(server)
    end

    return nothing
end
