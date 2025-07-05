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
#     id=CODE_ACTION_REGISTRATION_ID,
#     method=CODE_ACTION_REGISTRATION_METHOD))
# register(currently_running, code_action_registration())

function handle_CodeActionRequest(server::Server, msg::CodeActionRequest)
    uri = msg.params.textDocument.uri
    fi = get_file_info(server.state, uri)
    if fi === nothing
        return send(server,
            CodeActionResponse(;
                id = msg.id,
                result = nothing,
                error = file_cache_error(uri)))
    end
    testsetinfos = update_testsetinfos!(server, fi)
    if isempty(testsetinfos)
        return send(server,
            CodeActionResponse(;
                id = msg.id,
                result = null))
    end
    code_actions = testrunner_code_actions(uri, fi, testsetinfos, msg.params.range)
    return send(server,
        CodeActionResponse(;
            id = msg.id,
            result = isempty(code_actions) ? null : code_actions))
end
