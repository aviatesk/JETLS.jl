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
            add_rename_unused_var_code_actions!(code_actions, uri, diagnostic; allow_unused_underscore)
            if code == LOWERING_UNUSED_LOCAL_CODE
                add_delete_unused_var_code_actions!(code_actions, uri, diagnostic)
            end
        end
    end
    return code_actions
end

# Add rename actions for unused bindings (both local and arguments)
function add_rename_unused_var_code_actions!(
        code_actions::Vector{Union{CodeAction,Command}}, uri::URI, diagnostic::Diagnostic;
        allow_unused_underscore::Bool = true
    )
    range = diagnostic.range
    if allow_unused_underscore
        insert_pos = Position(; line=range.start.line, character=range.start.character)
        edit = WorkspaceEdit(;
            changes = Dict{URI,Vector{TextEdit}}(
                uri => TextEdit[TextEdit(;
                    range = Range(; start=insert_pos, var"end"=insert_pos),
                    newText = "_")]))
        title = "Prefix with '_' to indicate intentionally unused"
    else
        edit = WorkspaceEdit(;
            changes = Dict{URI,Vector{TextEdit}}(
                uri => TextEdit[TextEdit(; range, newText = "_")]))
        title = "Replace with '_' to indicate intentionally unused"
    end
    push!(code_actions, CodeAction(;
        title,
        kind = CodeActionKind.QuickFix,
        diagnostics = Diagnostic[diagnostic],
        isPreferred = true,
        edit))
end

# Add delete actions for unused local bindings (not arguments)
function add_delete_unused_var_code_actions!(
        code_actions::Vector{Union{CodeAction,Command}}, uri::URI, diagnostic::Diagnostic
    )
    data = diagnostic.data
    if data isa UnusedVariableData && !data.is_tuple_unpacking
        if data.lhs_eq_range !== nothing
            push!(code_actions, CodeAction(;
                title = "Delete assignment",
                kind = CodeActionKind.QuickFix,
                diagnostics = Diagnostic[diagnostic],
                edit = WorkspaceEdit(;
                    changes = Dict{URI,Vector{TextEdit}}(
                        uri => TextEdit[TextEdit(;
                            range = data.lhs_eq_range,
                            newText = "")]))))
        end
        if data.assignment_range !== nothing
            push!(code_actions, CodeAction(;
                title = "Delete statement",
                kind = CodeActionKind.QuickFix,
                diagnostics = Diagnostic[diagnostic],
                edit = WorkspaceEdit(;
                    changes = Dict{URI,Vector{TextEdit}}(
                        uri => TextEdit[TextEdit(;
                            range = data.assignment_range,
                            newText = "")]))))
        end
    end
end
