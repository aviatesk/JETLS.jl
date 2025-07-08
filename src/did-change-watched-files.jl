using TOML

const DID_CHANGE_WATCHED_FILES_REGISTRATION_ID = "jetls-did-change-watched-files"
const DID_CHANGE_WATCHED_FILES_REGISTRATION_METHOD = "workspace/didChangeWatchedFiles"

function did_change_watched_files_registration()
    Registration(;
        id = DID_CHANGE_WATCHED_FILES_REGISTRATION_ID,
        method = DID_CHANGE_WATCHED_FILES_REGISTRATION_METHOD,
        registerOptions = DidChangeWatchedFilesRegistrationOptions(;
            watchers = [
                FileSystemWatcher(;
                    globPattern = "**/JETLSConfig.toml",
                    kind = WatchKind.Create | WatchKind.Change | WatchKind.Delete),
            ]))
end

# For dynamic registrations during development
# unregister(currently_running, Unregistration(;
#     id=DID_CHANGE_WATCHED_FILES_REGISTRATION_ID,
#     method=DID_CHANGE_WATCHED_FILES_REGISTRATION_METHOD))
# register(currently_running, did_change_watched_files_registration())

function initialize_config!(server::Server)
    config_path = joinpath(server.state.root_path, "JETLSConfig.toml")
    server.state.config_manager = ConfigManager(copy(DEFAULT_CONFIG), copy(DEFAULT_CONFIG), Set([config_path]))
    isfile(config_path) && load_config!(identity, server, config_path) # no action required for configuration change
end

"""
Loads the configuration from the specified path into the server's config manager.

If the file does not exist or cannot be parsed, current configuration remains unchanged.
When there are unknown keys in the config file, send error by `workspace/showMessage` and **current configuration is not changed.**
"""
function load_config!(on_reload_required, server::Server, path::AbstractString)
    isfile(path) || return
    parsed = TOML.tryparsefile(path)
    parsed isa TOML.ParserError && return
    unknown_keys = collect_unknown_keys(parsed)

    if !isempty(unknown_keys)
        show_error_message(server, "Configuration file at $path contains unknown keys: $(join(unknown_keys, ", "))")
        return
    end

    merge_config!(server.state.config_manager.actual_config,
                  server.state.config_manager.latest_config,
                  parsed,
                  on_reload_required)
end

function handle_file_change!(server::Server, change::FileEvent)
    changed_path = uri2filepath(change.uri)
    change_type = change.type
    is_config_file(server, changed_path) || return
    if change_type == FileChangeType.Created || change_type == FileChangeType.Changed
        load_config!(server, changed_path) do key_path
            show_warning_message(server, "Configuration key `$(join(key_path, "."))` changed. Restarting the server is required to apply the changes.")
        end
    elseif change_type == FileChangeType.Deleted
        show_warning_message(server, "JETLSConfig.toml deleted. Restarting the server is required to apply the changes.")
    end
end

function handle_DidChangeWatchedFilesNotification(server::Server, msg::DidChangeWatchedFilesNotification)
    for change in msg.params.changes
        handle_file_change!(server, change)
    end
end
