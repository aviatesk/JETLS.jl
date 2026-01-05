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
    allow_unused_underscore = get_config(server.state.config_manager, :diagnostic, :allow_unused_underscore)
    unused_variable_code_actions!(code_actions, uri, msg.params.context.diagnostics; allow_unused_underscore)
    return send(server,
        CodeActionResponse(;
            id = msg.id,
            result = @somereal code_actions null))
end

function unused_variable_code_actions!(
        code_actions::Vector{Union{CodeAction,Command}},
        uri::URI,
        diagnostics::Vector{Diagnostic};
        allow_unused_underscore::Bool = true
    )
    for diagnostic in diagnostics
        code = diagnostic.code
        if code == LOWERING_UNUSED_ARGUMENT_CODE || code == LOWERING_UNUSED_LOCAL_CODE
            range = diagnostic.range
            if allow_unused_underscore
                insert_pos = Position(; line=range.start.line, character=range.start.character)
                edit = WorkspaceEdit(;
                    changes = Dict(
                        uri => [TextEdit(;
                            range = Range(; start=insert_pos, var"end"=insert_pos),
                            newText = "_")]))
                title = "Prefix with '_' to indicate intentionally unused"
            else
                edit = WorkspaceEdit(;
                    changes = Dict(
                        uri => [TextEdit(; range, newText = "_")]))
                title = "Replace with '_' to indicate intentionally unused"
            end
            push!(code_actions, CodeAction(;
                title,
                kind = CodeActionKind.QuickFix,
                diagnostics = [diagnostic],
                isPreferred = true,
                edit))
        end
    end
    return code_actions
end
