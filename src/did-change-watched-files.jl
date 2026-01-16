const DID_CHANGE_WATCHED_FILES_REGISTRATION_ID = "jetls-did-change-watched-files"
const DID_CHANGE_WATCHED_FILES_REGISTRATION_METHOD = "workspace/didChangeWatchedFiles"

const CONFIG_FILE = ".JETLSConfig.toml"
const PROFILE_TRIGGER_FILE = ".JETLSProfile"

function did_change_watched_files_registration(server::Server)
    state = server.state
    isdefined(state, :root_path) || return nothing
    root_uri = filepath2uri(state.root_path)
    Registration(;
        id = DID_CHANGE_WATCHED_FILES_REGISTRATION_ID,
        method = DID_CHANGE_WATCHED_FILES_REGISTRATION_METHOD,
        registerOptions = DidChangeWatchedFilesRegistrationOptions(;
            watchers = FileSystemWatcher[
                FileSystemWatcher(;
                    globPattern = RelativePattern(;
                        baseUri = root_uri,
                        pattern = CONFIG_FILE),
                    kind = WatchKind.Create | WatchKind.Change | WatchKind.Delete),
                FileSystemWatcher(;
                    globPattern = RelativePattern(;
                        baseUri = root_uri,
                        pattern = PROFILE_TRIGGER_FILE),
                    kind = WatchKind.Create),
                FileSystemWatcher(;
                    globPattern = RelativePattern(;
                        baseUri = root_uri,
                        pattern = "**/*.jl"),
                    kind = WatchKind.Create | WatchKind.Change | WatchKind.Delete),
            ]))
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
    if tracker.diagnostic_setting_changed
        notify_diagnostics!(server)
        request_diagnostic_refresh!(server)
    end
end

"""
Loads the file-based configuration from the specified path into the server's config manager.

If the file does not exist or cannot be parsed, just return leaving the current
configuration unchanged. When there are unknown keys in the config file,
send error message while leaving current configuration unchanged.
"""
function load_file_config!(on_difference, server::Server, filepath::AbstractString;
                           reload::Bool = false)
    store!(server.state.config_manager) do old_data::ConfigManagerData
        if reload && old_data.file_config_path != filepath
            show_warning_message(server, "Loading unregistered configuration file: $filepath")
        end

        isfile(filepath) || return old_data, nothing
        parsed = TOML.tryparsefile(filepath)
        parsed isa TOML.ParserError && return old_data, nothing

        new_file_config = parse_config_dict(parsed, filepath)
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

unmatched_keys_in_config_file_msg(filepath::AbstractString, unmatched_keys) =
    unmatched_keys_msg("Configuration file at $filepath contains unknown keys:", unmatched_keys)

function delete_file_config!(on_difference, manager::ConfigManager, filepath::AbstractString)
    store!(manager) do old_data::ConfigManagerData
        old_data.file_config_path == filepath || return old_data, nothing
        new_data = ConfigManagerData(old_data;
            file_config=EMPTY_CONFIG,
            file_config_path=nothing
        )
        track_setting_changes(on_difference, old_data.settings, new_data.settings)
        return new_data, nothing
    end
end

is_profile_trigger_file(path::AbstractString) = endswith(path, PROFILE_TRIGGER_FILE)

is_jl_file(path::AbstractString) = endswith(path, ".jl")

function handle_DidChangeWatchedFilesNotification(server::Server, msg::DidChangeWatchedFilesNotification)
    state = server.state
    for change in msg.params.changes
        changed_path = @something uri2filepath(change.uri) continue
        if is_config_file(changed_path)
            handle_config_file_change!(server, changed_path, change.type)
        elseif is_profile_trigger_file(changed_path) && change.type == FileChangeType.Created
            trigger_profile!(server, changed_path)
        elseif is_jl_file(changed_path)
            handle_jl_file_change!(state, change.uri)
        end
    end
end

function handle_jl_file_change!(state::ServerState, uri::URI)
    if haskey(load(state.file_cache), uri)
        # File is synced (opened in editor) - cache invalidation is handled by
        # `textDocument/didChange`, so we don't need to do anything here
        return
    end
    invalidate_document_symbol_cache!(state, uri)
end
