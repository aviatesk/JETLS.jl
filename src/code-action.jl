const CODE_ACTION_REGISTRATION_ID = "jetls-code-action"
const CODE_ACTION_REGISTRATION_METHOD = "textDocument/codeAction"

function code_action_options()
    return CodeActionOptions(;
        codeActionKinds = [CodeActionKind.Empty],  # Support all kinds
        resolveProvider = false)
end

function code_action_registration()
    return Registration(;
        id = CODE_ACTION_REGISTRATION_ID,
        method = CODE_ACTION_REGISTRATION_METHOD,
        registerOptions = CodeActionRegistrationOptions(;
            documentSelector = DEFAULT_DOCUMENT_SELECTOR,
            codeActionKinds = [CodeActionKind.Empty],
            resolveProvider = false))
end

# For dynamic code lens registrations during development
# unregister(currently_running, Unregistration(;
#     id = CODE_ACTION_REGISTRATION_ID,
#     method = CODE_ACTION_REGISTRATION_METHOD))
# register(currently_running, code_action_registration())

function handle_CodeActionRequest(
        server::Server, msg::CodeActionRequest, cancel_flag::CancelFlag)
    uri = msg.params.textDocument.uri
    result = get_file_info(server.state, uri, cancel_flag)
    if result isa ResponseError
        return send(server,
            CodeActionResponse(;
                id = msg.id,
                result = nothing,
                error = result))
    end
    fi = result
    code_actions = Union{CodeAction,Command}[]
    testsetinfos = fi.testsetinfos
    isempty(testsetinfos) ||
        testrunner_code_actions!(code_actions, uri, fi, testsetinfos, msg.params.range)
    return send(server,
        CodeActionResponse(;
            id = msg.id,
            result = isempty(code_actions) ? null : code_actions))
end
