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
    if isnothing(result)
        return send(server, CodeActionResponse(; id = msg.id, result = null))
    elseif result isa ResponseError
        return send(server, CodeActionResponse(; id = msg.id, result = nothing, error = result))
    end
    fi = result
    code_actions = Union{CodeAction,Command}[]
    testsetinfos = fi.testsetinfos
    isempty(testsetinfos) ||
        testrunner_code_actions!(code_actions, uri, fi, testsetinfos, msg.params.range)
    allow_unused_underscore = get_config(server.state.config_manager, :diagnostic, :allow_unused_underscore)
    unused_variable_code_actions!(code_actions, uri, msg.params.context.diagnostics; allow_unused_underscore)
    sort_imports_code_actions!(code_actions, uri, fi, msg.params.range, msg.params.context.diagnostics)
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

const SORT_IMPORTS_MAX_LINE_LENGTH = 92
const SORT_IMPORTS_INDENT = "    "

# We analyze `st0` directly instead of relying on `msg.params.context.diagnostics` because
# the diagnostic may be disabled via `diagnostic.patterns` (severity = "off"), but the code
# action should still be available. Analyzing `st0` is lightweight since it doesn't require
# macro expansion or full lowering - it's just the already-parsed syntax tree.
function sort_imports_code_actions!(
        code_actions::Vector{Union{CodeAction,Command}},
        uri::URI, fi::FileInfo, request_range::Range, diagnostics::Vector{Diagnostic}
    )
    st0_top = build_syntax_tree(fi)
    request_byte_start = xy_to_offset(fi, request_range.start)
    request_byte_end = xy_to_offset(fi, request_range.var"end")
    traverse(st0_top) do st0::JS.SyntaxTree
        node_start = JS.first_byte(st0)
        node_end = JS.last_byte(st0)
        if node_end < request_byte_start || node_start > request_byte_end
            return TraversalNoRecurse()
        end
        kind = JS.kind(st0)
        if kind in JS.KSet"import using export public"
            if node_start ≤ request_byte_start ≤ node_end
                add_sort_imports_code_action!(code_actions, uri, fi, st0, diagnostics)
            end
            return TraversalNoRecurse()
        end
        return nothing
    end
    return code_actions
end

function add_sort_imports_code_action!(
        code_actions::Vector{Union{CodeAction,Command}},
        uri::URI, fi::FileInfo, st0::JS.SyntaxTree, diagnostics::Vector{Diagnostic}
    )
    names = collect_import_names(st0)
    length(names) < 2 && return code_actions
    if is_sorted_imports(names)
        return code_actions
    end
    sorted_names = sort!(names; by=get_import_sort_key)
    base_indent = get_line_indent(fi, JS.first_byte(st0))
    new_text = generate_sorted_import_text(st0, sorted_names, base_indent)
    range = jsobj_to_range(st0, fi)
    related_diagnostics = filter(diagnostics) do d
        d.code == LOWERING_UNSORTED_IMPORT_NAMES_CODE && d.range == range
    end
    push!(code_actions, CodeAction(;
        title = "Sort import names",
        kind = CodeActionKind.QuickFix,
        diagnostics = related_diagnostics,
        isPreferred = true,
        edit = WorkspaceEdit(;
            changes = Dict{URI,Vector{TextEdit}}(
                uri => TextEdit[TextEdit(; range, newText=new_text)]))))
    return code_actions
end

function generate_sorted_import_text(
        node::JS.SyntaxTree, sorted_names::Vector{JS.SyntaxTree},
        base_indent::Union{String,Nothing}
    )
    kind = JS.kind(node)
    keyword = kind === JS.K"import" ? "import" :
              kind === JS.K"using" ? "using" :
              kind === JS.K"export" ? "export" : "public"
    if kind === JS.K"import" || kind === JS.K"using"
        nchildren = JS.numchildren(node)
        if nchildren == 1 && JS.kind(node[1]) === JS.K":"
            module_path = lstrip(JS.sourcetext(node[1][1]))
            prefix = "$keyword $module_path: "
        else
            prefix = "$keyword "
        end
    else
        prefix = "$keyword "
    end
    name_texts = String[lstrip(JS.sourcetext(n)) for n in sorted_names]
    single_line = prefix * join(name_texts, ", ")
    # Don't wrap lines if we can't determine indent (e.g., `begin export ... end`)
    if base_indent === nothing
        return single_line
    end
    # Check line length including base indent
    if length(base_indent) + length(single_line) <= SORT_IMPORTS_MAX_LINE_LENGTH
        return single_line
    end
    continuation_indent = base_indent * SORT_IMPORTS_INDENT
    lines = String[prefix * name_texts[1]]
    current_line_idx = 1
    for i = 2:length(name_texts)
        name = name_texts[i]
        current_indent = current_line_idx == 1 ? base_indent : continuation_indent
        potential_line = lines[current_line_idx] * ", " * name
        if length(current_indent) + length(potential_line) <= SORT_IMPORTS_MAX_LINE_LENGTH
            lines[current_line_idx] = potential_line
        else
            lines[current_line_idx] *= ","
            push!(lines, continuation_indent * name)
            current_line_idx += 1
        end
    end
    return join(lines, "\n")
end
