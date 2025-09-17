const EXECUTE_COMMAND_REGISTRATION_ID = "jetls-execute-command"
const EXECUTE_COMMAND_REGISTRATION_METHOD = "workspace/executeCommand"

const COMMAND_TESTRUNNER_RUN_TESTSET = "JETLS.TestRunner.run@testset"
const COMMAND_TESTRUNNER_RUN_TESTCASE = "JETLS.TestRunner.run@test"
const COMMAND_TESTRUNNER_CLEAR_RESULT = "JETLS.TestRunner.clearResult"
const COMMAND_TESTRUNNER_OPEN_LOGS = "JETLS.TestRunner.openLogs"

const SUPPORTED_COMMANDS = [
    COMMAND_TESTRUNNER_RUN_TESTSET,
    COMMAND_TESTRUNNER_RUN_TESTCASE,
    COMMAND_TESTRUNNER_OPEN_LOGS,
    COMMAND_TESTRUNNER_CLEAR_RESULT,
]

function execute_command_options()
    return ExecuteCommandOptions(;
        commands = SUPPORTED_COMMANDS)
end

function execute_command_registration()
    return Registration(;
        id = EXECUTE_COMMAND_REGISTRATION_ID,
        method = EXECUTE_COMMAND_REGISTRATION_METHOD,
        registerOptions = ExecuteCommandRegistrationOptions(;
            commands = SUPPORTED_COMMANDS))
end

# For dynamic registrations during development
# unregister(currently_running, Unregistration(;
#     id = EXECUTE_COMMAND_REGISTRATION_ID,
#     method = EXECUTE_COMMAND_REGISTRATION_METHOD))
# register(currently_running, execute_command_registration())

function handle_ExecuteCommandRequest(server::Server, msg::ExecuteCommandRequest, cancel_flag::CancelFlag)
    if is_cancelled(cancel_flag)
        return send(server,
            ExecuteCommandResponse(;
                id = msg.id,
                result = nothing,
                error = request_cancelled_error()))
    end
    command = msg.params.command
    if command == COMMAND_TESTRUNNER_RUN_TESTSET
        return execute_testrunner_run_testset_command(server, msg)
    elseif command == COMMAND_TESTRUNNER_RUN_TESTCASE
        return execute_testrunner_run_testcase_command(server, msg)
    elseif command == COMMAND_TESTRUNNER_OPEN_LOGS
        return execute_testrunner_open_logs_command(server, msg)
    elseif command == COMMAND_TESTRUNNER_CLEAR_RESULT
        return execute_testrunner_clear_result_command(server, msg)
    end
    return send(server,
        invalid_execute_command_response(msg, "Unknown execution command: $command"))
end

function invalid_execute_command_response(msg::ExecuteCommandRequest, message::AbstractString,
                                          code::Int=ErrorCodes.InvalidParams)
    return ExecuteCommandResponse(;
        id = msg.id,
        result = nothing,
        error = ResponseError(; code, message))
end

# E.g. uri = convert(URI, @tryparsearg server msg[1]::String)
macro tryparsearg(server, ex)
    Meta.isexpr(ex, :(::)) || error("invalid forms")
    length(ex.args) == 2 || error("invalid forms")
    ref, T = ex.args
    Meta.isexpr(ref, :ref) || error("invalid forms")
    length(ref.args) == 2 || error("invalid forms")
    msg, idx = ref.args
    return :(let server = $(esc(server)),
                 msg = $(esc(msg)),
                 idx = $(esc(idx)),
                 T = $(esc(T))
        arguments = @something msg.params.arguments begin
            return send(server, invalid_execute_command_response(msg,
                lazy"Expected `arguments` parameter to be set for `workspace/executeCommand` request"))
        end
        if !(1 ≤ idx ≤ length(arguments))
            return send(server, invalid_execute_command_response(msg,
                lazy"Expected `1 ≤ $idx ≤ length(arguments)` for `workspace/executeCommand` request"))
        end
        arg = arguments[idx]
        arg isa T || return send(server, invalid_execute_command_response(msg,
            lazy"Expected `arguments[$idx]::$T` for `workspace/executeCommand` request"))
        arg
    end)
end

function execute_testrunner_run_testset_command(server::Server, msg::ExecuteCommandRequest)
    uri = convert(URI, @tryparsearg server msg[1]::String)
    idx = @tryparsearg server msg[2]::Int
    tsn = @tryparsearg server msg[3]::String
    error_msg = testrunner_run_testset_from_uri(server, uri, idx, tsn)
    if error_msg !== nothing
        show_error_message(server, error_msg)
        return send(server,
            ExecuteCommandResponse(;
                id = msg.id,
                result = nothing,
                error = request_failed_error(error_msg)))
    end
    return send(server,
        ExecuteCommandResponse(;
            id = msg.id,
            result = null))
end

function execute_testrunner_run_testcase_command(server::Server, msg::ExecuteCommandRequest)
    uri = convert(URI, @tryparsearg server msg[1]::String)
    tcl = @tryparsearg server msg[2]::Int
    tct = @tryparsearg server msg[3]::String
    error_msg = testrunner_run_testcase_from_uri(server, uri, tcl, tct)
    if error_msg !== nothing
        show_error_message(server, error_msg)
        return send(server,
            ExecuteCommandResponse(;
                id = msg.id,
                result = nothing,
                error = request_failed_error(error_msg)))
    end
    return send(server,
        ExecuteCommandResponse(;
            id = msg.id,
            result = null))
end

function execute_testrunner_open_logs_command(server::Server, msg::ExecuteCommandRequest)
    tsn = @tryparsearg server msg[1]::String
    logs = @tryparsearg server msg[2]::String
    open_testsetinfo_logs!(server, tsn, logs)
    return send(server,
        ExecuteCommandResponse(;
            id = msg.id,
            result = null))
end

function execute_testrunner_clear_result_command(server::Server, msg::ExecuteCommandRequest)
    uri = convert(URI, @tryparsearg server msg[1]::String)
    idx = @tryparsearg server msg[2]::Int
    tsn = @tryparsearg server msg[3]::String
    try_clear_testrunner_result!(server, uri, idx, tsn)
    return send(server,
        ExecuteCommandResponse(;
            id = msg.id,
            result = null))
end
