const DID_CHANGE_WATCHED_FILES_REGISTRATION_ID = "jetls-did-change-watched-files"
const DID_CHANGE_WATCHED_FILES_REGISTRATION_METHOD = "workspace/didChangeWatchedFiles"

const PROFILE_TRIGGER_FILE = ".JETLSProfile"
const SERVER_REVISE_TRIGGER_FILE = ".JETLS_REVISE"

function watched_file_pattern(
        root_uri::URI, pattern::String, fallback::String, relative_pattern_support::Bool
    )
    relative_pattern_support || return fallback
    return RelativePattern(; baseUri = root_uri, pattern)
end

function did_change_watched_files_registration(server::Server)
    state = server.state
    isdefined(state, :root_path) || return nothing
    root_uri = filepath2uri(state.root_path)
    relative_pattern_support = supports(
        server, :workspace, :didChangeWatchedFiles, :relativePatternSupport)
    watchers = FileSystemWatcher[
        FileSystemWatcher(;
            globPattern = watched_file_pattern(
                root_uri, CONFIG_FILE, CONFIG_FILE_GLOB_PATTERN,
                relative_pattern_support),
            kind = WatchKind.Create | WatchKind.Change | WatchKind.Delete),
        FileSystemWatcher(;
            globPattern = watched_file_pattern(
                root_uri, PROFILE_TRIGGER_FILE, "**/$PROFILE_TRIGGER_FILE",
                relative_pattern_support),
            kind = WatchKind.Create),
        FileSystemWatcher(;
            globPattern = watched_file_pattern(
                root_uri, "**/*.jl", "**/*.jl",
                relative_pattern_support),
            kind = WatchKind.Create | WatchKind.Change | WatchKind.Delete),
    ]
    @static if JETLS_DEV_MODE
        push!(watchers, FileSystemWatcher(;
            globPattern = watched_file_pattern(
                root_uri, SERVER_REVISE_TRIGGER_FILE, "**/$SERVER_REVISE_TRIGGER_FILE",
                relative_pattern_support),
            kind = WatchKind.Create))
    end
    Registration(;
        id = DID_CHANGE_WATCHED_FILES_REGISTRATION_ID,
        method = DID_CHANGE_WATCHED_FILES_REGISTRATION_METHOD,
        registerOptions = DidChangeWatchedFilesRegistrationOptions(; watchers))
end

# For dynamic registrations during development
# unregister(currently_running, Unregistration(;
#     id = DID_CHANGE_WATCHED_FILES_REGISTRATION_ID,
#     method = DID_CHANGE_WATCHED_FILES_REGISTRATION_METHOD))
# register(currently_running, did_change_watched_files_registration(currently_running))

config_file_created_msg(path::AbstractString) = "JETLS configuration file loaded: $path"
config_file_deleted_msg(path::AbstractString) = "JETLS configuration file removed: $path"

function handle_config_file_change!(
        server::Server, changed_path::AbstractString, change_type::FileChangeType.Ty
    )
    tracker = ConfigChangeTracker()

    if change_type == FileChangeType.Created
        load_file_config!(tracker, server, changed_path)
        kind = "created"
        show_info_message(server, config_file_created_msg(changed_path))
    elseif change_type == FileChangeType.Changed
        load_file_config!(tracker, server, changed_path; reload=true)
        kind = "updated"
    elseif change_type == FileChangeType.Deleted
        delete_file_config!(tracker, server.state.config_manager, changed_path)
        kind = "deleted"
        show_info_message(server, config_file_deleted_msg(changed_path))
    else error("Unknown FileChangeType") end

    source = "[.JETLSConfig.toml] $(dirname(changed_path)) ($kind)"
    notify_config_changes(server, tracker, source)
    apply_auto_instantiate_change!(server)
    if tracker.diagnostic_setting_changed
        clear_per_file_diagnostics_cache!(server.state)
        notify_diagnostics!(server; ensure_cleared = true)
        request_diagnostic_refresh!(server)
    end
    if tracker.analysis_setting_changed
        request_reanalysis_for_tracked_entries!(server)
        request_diagnostic_refresh!(server)
    end
end

# TODO: We may eventually want to separate live config validation from saved config
# application. Synchronized `.JETLSConfig.toml` buffers could be validated on
# `textDocument/didChange`, with source-ranged issues exposed through pull diagnostics,
# while this watched-file path remains the trigger for applying saved settings. Proper
# ranges for JETLS-specific semantic errors would require a provenance-preserving TOML
# parser or source map. However, schema-aware external tools such as Tombi can already
# provide most live validation using `config-toml.schema.json`, so it is unclear whether
# JETLS should own that machinery.
#
# In any case, do not reuse live `ConfigDocumentInfo.config_data` here: it may contain
# unsaved changes, and config-change invalidation must only run after saved settings are
# applied.

"""
Loads the file-based configuration from the specified path into the server's config manager.

If the file does not exist or cannot be parsed, just return leaving the current
configuration unchanged. When there are unknown keys in the config file,
send error message while leaving current configuration unchanged.
"""
function load_file_config!(on_difference, server::Server, filepath::AbstractString;
                           reload::Bool = false)
    store!(server.state.config_manager) do old_data::ConfigManagerData
        old_path = old_data.file_config_path
        if reload && (old_path === nothing || !paths_equal(old_path, filepath))
            show_warning_message(server, "Loading unregistered configuration file: $filepath")
        end

        isfile(filepath) || return old_data, nothing
        parsed = TOML.tryparsefile(filepath)
        parsed isa TOML.ParserError && return old_data, nothing
        config_dict = try
            validate_config_data(parsed)
        catch err
            err isa InvalidConfigDataError || rethrow(err)
            show_error_message(server, """
                Failed to load configuration file at $filepath:
                $(sprint(showerror, err))
                """)
            return old_data, nothing
        end

        for msg in migrate_deprecated_config_keys!(config_dict)
            show_warning_message(server, msg)
        end
        new_file_config = parse_config_dict(config_dict, filepath)
        if new_file_config isa AbstractString
            show_error_message(server, new_file_config)
            return old_data, nothing
        end
        new_data = ConfigManagerData(old_data;
            file_config=new_file_config,
            file_config_path=filepath
        )
        track_setting_changes(on_difference, old_data.settings, new_data.settings)
        return new_data, nothing
    end
end

unmatched_key_in_config_file_msg(filepath::AbstractString, path::Vector{String}) =
    unmatched_key_msg("Configuration file at $filepath contains an unknown key:", path)

function delete_file_config!(on_difference, manager::ConfigManager, filepath::AbstractString)
    store!(manager) do old_data::ConfigManagerData
        old_path = old_data.file_config_path
        old_path === nothing && return old_data, nothing
        paths_equal(old_path, filepath) || return old_data, nothing
        new_data = ConfigManagerData(old_data;
            file_config=EMPTY_CONFIG,
            file_config_path=nothing
        )
        track_setting_changes(on_difference, old_data.settings, new_data.settings)
        return new_data, nothing
    end
end

is_jl_file(path::AbstractString) = endswith(path, ".jl")

function handle_server_revise_trigger!(server::Server, trigger_path::AbstractString)
    @static JETLS_DEV_MODE || return show_warning_message(server,  ".JETLS_REVISE requires dev mode")
    revise_now!()
    advance_server_world!()
    show_info_message(server, "JETLS server world advanced: $trigger_path")
    request_delete_file(server, filepath2uri(trigger_path))
end

function handle_DidChangeWatchedFilesNotification(server::Server, msg::DidChangeWatchedFilesNotification)
    for change in msg.params.changes
        changed_path = @something uri2filepath(change.uri) continue
        state = server.state
        if is_workspace_root_file(state, changed_path, CONFIG_FILE)
            handle_config_file_change!(server, changed_path, change.type)
        elseif is_workspace_root_file(state, changed_path, PROFILE_TRIGGER_FILE) &&
                change.type == FileChangeType.Created
            trigger_profile!(server, changed_path)
        elseif is_workspace_root_file(state, changed_path, SERVER_REVISE_TRIGGER_FILE) &&
                change.type != FileChangeType.Deleted
            handle_server_revise_trigger!(server, changed_path)
        elseif is_workspace_file(state, changed_path) && is_jl_file(changed_path)
            handle_jl_file_change!(server, change)
        end
    end
end

function handle_jl_file_change!(server::Server, change::FileEvent)
    state = server.state
    uri = change.uri
    if is_synchronized(state, uri)
        # File is synced (opened in editor) - `unsynced_file_cache` should have been
        # invalidated via `textDocument/didOpen`, and the other cache invalidations
        # are handled by `textDocument/didChange`, so we don't need to do anything here
        return
    end
    if change.type == FileChangeType.Created
        store_unsynced_file_info!(state, uri)
    else
        if change.type == FileChangeType.Changed
            store_unsynced_file_info!(state, uri)
        else
            @assert change.type == FileChangeType.Deleted
            invalidate_unsynced_file_cache!(state, uri)
        end
        invalidate_per_file_caches!(state, uri)
    end
    request_diagnostic_refresh!(server)
end
