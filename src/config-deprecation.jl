# Deprecated configurations
# =========================
#
# Keys of `.JETLSConfig.toml` listed in `deprecated_configurations` and values listed in
# `deprecated_configuration_values` are reported as `config/deprecated-key` and
# `config/deprecated-value` diagnostics with quick fixes, and loading a file that contains
# them shows a message offering to fix them all. A fix changes the parsed configuration
# exactly as `migrate_deprecated_config!` does.

# Diagnostics
# -----------

struct DeprecatedConfigKey
    old_path::Vector{String}
    new_path::Union{Nothing,Vector{String}}
    # The key as written, including all segments of a dotted key
    span::TS.Span
end

struct DeprecatedConfigValue
    path::Vector{String}
    old_value::Any
    new_value::Any
    span::TS.Span
end

const DeprecatedConfig = Union{DeprecatedConfigKey,DeprecatedConfigValue}

function find_deprecated_configs(
        doc::TS.Document,
        deprecated_configs::DeprecatedConfigurations = deprecated_configurations,
        deprecated_values::DeprecatedConfigurationValues = deprecated_configuration_values
    )
    found = DeprecatedConfig[]
    for (old_path, new_path) in deprecated_configs
        deprecated = @something find_deprecated_config_key(doc, old_path, new_path) continue
        push!(found, deprecated)
    end
    for (path, (old_value, new_value)) in deprecated_values
        deprecated = @something find_deprecated_config_value(
            doc, path, old_value, new_value) continue
        push!(found, deprecated)
    end
    return found
end

function find_deprecated_config_key(
        doc::TS.Document, old_path::Vector{String},
        new_path::Union{Nothing,Vector{String}}
    )
    item = @something TS.item(doc, old_path) return nothing
    span = @something item.key return nothing
    entry = item.entry
    entry === nothing || (span = TS.Span(entry.first, span.past_last))
    return DeprecatedConfigKey(old_path, new_path, span)
end

function find_deprecated_config_value(
        doc::TS.Document, path::Vector{String}, @nospecialize(old_value),
        @nospecialize(new_value)
    )
    item = @something TS.item(doc, path) return nothing
    span = @something item.value return nothing
    parent = @something get_nested_dict(doc.data, @view path[1:end-1]) return nothing
    is_deprecated_value(get(parent, path[end], nothing), old_value) || return nothing
    return DeprecatedConfigValue(path, old_value, new_value, span)
end

deprecated_config_code(::DeprecatedConfigKey) = CONFIG_DEPRECATED_KEY_CODE
deprecated_config_code(::DeprecatedConfigValue) = CONFIG_DEPRECATED_VALUE_CODE

deprecated_config_message(deprecated::DeprecatedConfigKey) =
    deprecated_config_key_message(deprecated.old_path, deprecated.new_path)
deprecated_config_message(deprecated::DeprecatedConfigValue) =
    deprecated_config_value_message(deprecated.path, deprecated.old_value, deprecated.new_value)

function deprecated_config_diagnostics(text::String, encoding::PositionEncodingKind.Ty)
    doc = TS.tryparse(text)
    doc isa TS.Document || return Diagnostic[]
    bytes = Vector{UInt8}(text)
    return Diagnostic[
        Diagnostic(;
            range = source_range(bytes, deprecated.span, encoding),
            severity = DiagnosticSeverity.Warning,
            code = deprecated_config_code(deprecated),
            codeDescription = diagnostic_code_description(deprecated_config_code(deprecated)),
            source = DIAGNOSTIC_SOURCE_EXTRA,
            message = deprecated_config_message(deprecated),
            tags = DiagnosticTag.Ty[DiagnosticTag.Deprecated])
        for deprecated in find_deprecated_configs(doc)]
end

config_text_and_version(server::Server, uri::URI) =
    toml_text_and_version(get_config_document(server.state, uri), uri)

"""
    update_config_diagnostics!(server::Server, uri::URI)

Diagnose the config file at `uri`, from its live buffer if it is open or else from disk,
and publish the result.
"""
function update_config_diagnostics!(server::Server, uri::URI)
    state = server.state
    state.cli_mode && return nothing
    text_version = config_text_and_version(server, uri)
    diagnostics = text_version === nothing ? Diagnostic[] :
        deprecated_config_diagnostics(first(text_version), state.encoding)
    key = ConfigDiagnosticsKey(uri)
    changed = store!(state.extra_diagnostics) do data
        had_diagnostics = haskey(data, key)
        isempty(diagnostics) && !had_diagnostics && return data, false
        new_data = copy(data)
        if isempty(diagnostics)
            delete!(new_data, key)
        else
            new_data[key] = URI2Diagnostics(uri => diagnostics)
        end
        return new_data, true
    end
    if changed
        uris = Set{URI}((uri,))
        notify_diagnostics!(server, get_full_diagnostics(server, uris); ensure_cleared = uri)
    end
    return nothing
end

# Code actions
# ------------

# Like `migrate_deprecated_config!`, keep the value of a key that is already migrated.
function deprecated_config_key_removes(
        doc::TS.Document, deprecated::DeprecatedConfigKey
    )
    new_path = deprecated.new_path
    return new_path === nothing || TS.item(doc, new_path) !== nothing
end

function deprecated_config_edit(doc::TS.Document, deprecated::DeprecatedConfigKey)
    (; old_path, new_path) = deprecated
    deprecated_config_key_removes(doc, deprecated) &&
        return TS.delete_entry(doc, old_path; prune = true)
    return TS.move_entry(doc, old_path, new_path::Vector{String}; prune = true)
end
deprecated_config_edit(doc::TS.Document, deprecated::DeprecatedConfigValue) =
    TS.replace_value(doc, deprecated.path, deprecated.new_value)

function deprecated_config_fix(doc::TS.Document, deprecated::DeprecatedConfig)
    edit = @something deprecated_config_edit(doc, deprecated) return nothing
    expected = @something tryparse_config_data(doc.source) return nothing
    migrate_deprecated_config!(expected, migration_tables(deprecated)...)
    fixed = tryparse_config_data(TS.apply(doc.source, edit))
    return isequal(fixed, expected) ? edit : nothing
end

migration_tables(deprecated::DeprecatedConfigKey) = (
    DeprecatedConfigurations([deprecated.old_path => deprecated.new_path]),
    DeprecatedConfigurationValues())
migration_tables(deprecated::DeprecatedConfigValue) = (
    DeprecatedConfigurations(),
    DeprecatedConfigurationValues([
        deprecated.path => (deprecated.old_value => deprecated.new_value)]))

function deprecated_config_fix_title(
        doc::TS.Document, deprecated::DeprecatedConfigKey
    )
    old = join(deprecated.old_path, ".")
    deprecated_config_key_removes(doc, deprecated) && return "Remove deprecated `$old`"
    return "Replace `$old` with `$(join(deprecated.new_path::Vector{String}, "."))`"
end
deprecated_config_fix_title(::TS.Document, deprecated::DeprecatedConfigValue) =
    "Replace `" * TS.format_value(deprecated.old_value) * "` with `" *
        TS.format_value(deprecated.new_value) * "`"

# `text` with the fixes of all deprecated keys and values applied, skipping those that
# cannot be fixed, or `nothing` if nothing is fixed
function fix_deprecated_configs(
        text::String,
        deprecated_configs::DeprecatedConfigurations = deprecated_configurations,
        deprecated_values::DeprecatedConfigurationValues = deprecated_configuration_values
    )
    doc = TS.tryparse(text)
    doc isa TS.Document || return nothing
    any_fixed = false
    # Fix in the order of `migrate_deprecated_config!`, finding each again in the fixed text
    for (old_path, new_path) in deprecated_configs
        deprecated = @something find_deprecated_config_key(doc, old_path, new_path) continue
        doc, fixed = fixed_document(doc, deprecated)
        any_fixed |= fixed
    end
    for (path, (old_value, new_value)) in deprecated_values
        deprecated = @something find_deprecated_config_value(
            doc, path, old_value, new_value) continue
        doc, fixed = fixed_document(doc, deprecated)
        any_fixed |= fixed
    end
    return any_fixed ? doc.source : nothing
end

function fixed_document(doc::TS.Document, deprecated::DeprecatedConfig)
    edit = @something deprecated_config_fix(doc, deprecated) return doc, false
    fixed = TS.tryparse(TS.apply(doc.source, edit))
    fixed isa TS.Document || return doc, false
    return fixed, true
end

const DEPRECATED_CONFIG_CODES = (CONFIG_DEPRECATED_KEY_CODE, CONFIG_DEPRECATED_VALUE_CODE)

"""
    deprecated_config_code_actions!(code_actions::Vector{Union{CodeAction,Command}},
                                    server::Server, uri::URI,
                                    diagnostics::Vector{Diagnostic})

Add to `code_actions` the quick fixes of the deprecated settings that `diagnostics` report
in the config file at `uri`, and one that fixes all of them if there are several.
"""
function deprecated_config_code_actions!(
        code_actions::Vector{Union{CodeAction,Command}}, server::Server, uri::URI,
        diagnostics::Vector{Diagnostic}
    )
    requested = Diagnostic[d for d in diagnostics if d.code in DEPRECATED_CONFIG_CODES]
    isempty(requested) && return code_actions
    text, version = @something config_text_and_version(server, uri) return code_actions
    doc = TS.tryparse(text)
    doc isa TS.Document || return code_actions
    encoding = server.state.encoding
    bytes = Vector{UInt8}(text)
    found = find_deprecated_configs(doc)
    for diagnostic in requested, deprecated in found
        diagnostic.code == deprecated_config_code(deprecated) || continue
        source_range(bytes, deprecated.span, encoding) == diagnostic.range || continue
        edit = @something deprecated_config_fix(doc, deprecated) continue
        push!(code_actions, CodeAction(;
            title = deprecated_config_fix_title(doc, deprecated),
            kind = CodeActionKind.QuickFix,
            diagnostics = Diagnostic[diagnostic],
            isPreferred = true,
            edit = text_document_workspace_edit(
                server, uri, version, source_text_edit(bytes, edit, encoding))))
    end
    if length(found) > 1
        fixed = @something fix_deprecated_configs(text) return code_actions
        edit = TS.minimal_edit(text, fixed)
        push!(code_actions, CodeAction(;
            title = "Fix all deprecated settings",
            kind = CodeActionKind.QuickFix,
            diagnostics = requested,
            edit = text_document_workspace_edit(
                server, uri, version, source_text_edit(bytes, edit, encoding))))
    end
    return code_actions
end

# Window messages
# ---------------

const FIX_DEPRECATED_CONFIGS_TITLE = "Fix all"

struct DeprecatedConfigPromptCaller <: RequestCaller
    uri::URI
end

"""
    report_deprecated_configs(server::Server, filepath::String, warnings::Vector{String})

Show `warnings` about the deprecated settings found while loading the config file at
`filepath`. If the client can apply workspace edits and the settings can be fixed, show
them in one message with an action that fixes them all; otherwise show each as a warning.
"""
function report_deprecated_configs(
        server::Server, filepath::String, warnings::Vector{String}
    )
    isempty(warnings) && return nothing
    uri = filepath2uri(filepath)
    if server.state.cli_mode || !supports(server, :workspace, :applyEdit) ||
            !can_fix_deprecated_configs(server, uri)
        foreach(warning -> show_warning_message(server, warning), warnings)
        return nothing
    end
    id = unique_id("ShowMessageRequest_deprecated_configs")
    addrequest!(server, id => DeprecatedConfigPromptCaller(uri))
    message = "Configuration file at $filepath contains deprecated settings:\n" *
        join(("- " * warning for warning in warnings), "\n")
    actions = MessageActionItem[MessageActionItem(; title = FIX_DEPRECATED_CONFIGS_TITLE)]
    params = ShowMessageRequestParams(; type = MessageType.Warning, message, actions)
    send(server, ShowMessageRequest(; id, params))
    return nothing
end

function can_fix_deprecated_configs(server::Server, uri::URI)
    text, _ = @something config_text_and_version(server, uri) return false
    return fix_deprecated_configs(text) !== nothing
end

"""
    handle_deprecated_config_prompt_response(server::Server, msg::Dict{Symbol,Any},
                                             caller::DeprecatedConfigPromptCaller)

Fix all the deprecated settings of the config file through `workspace/applyEdit` when the
"Fix all" action of the message shown by [`report_deprecated_configs`](@ref) is chosen.
"""
function handle_deprecated_config_prompt_response(
        server::Server, msg::Dict{Symbol,Any}, caller::DeprecatedConfigPromptCaller
    )
    handle_response_error(server, msg, "fix deprecated settings") && return nothing
    result = get(msg, :result, nothing)
    (result isa Dict && get(result, "title", nothing) == FIX_DEPRECATED_CONFIGS_TITLE) ||
        return nothing
    uri = caller.uri
    # The file may have changed while the message was shown
    text, version = @something config_text_and_version(server, uri) return nothing
    fixed = @something fix_deprecated_configs(text) return nothing
    text_edit = source_text_edit(
        Vector{UInt8}(text), TS.minimal_edit(text, fixed), server.state.encoding)
    edit = text_document_workspace_edit(server, uri, version, text_edit)
    id = unique_id("ApplyWorkspaceEditRequest")
    addrequest!(server, id => ApplyWorkspaceEditCaller())
    label = "Fix deprecated settings"
    send(server, ApplyWorkspaceEditRequest(;
        id, params = ApplyWorkspaceEditParams(; label, edit)))
    return nothing
end
