const DID_CHANGE_WATCHED_FILES_REGISTRATION_ID = "jetls-did-change-watched-files"
const DID_CHANGE_WATCHED_FILES_REGISTRATION_METHOD = "workspace/didChangeWatchedFiles"

function did_change_watched_files_registration()
    Registration(;
        id = DID_CHANGE_WATCHED_FILES_REGISTRATION_ID,
        method = DID_CHANGE_WATCHED_FILES_REGISTRATION_METHOD,
        registerOptions = DidChangeWatchedFilesRegistrationOptions(;
            watchers = FileSystemWatcher[
                FileSystemWatcher(;
                    globPattern = "**/.JETLSConfig.toml",
                    kind = WatchKind.Create | WatchKind.Change | WatchKind.Delete),
            ]))
end

# For dynamic registrations during development
# unregister(currently_running, Unregistration(;
#     id = DID_CHANGE_WATCHED_FILES_REGISTRATION_ID,
#     method = DID_CHANGE_WATCHED_FILES_REGISTRATION_METHOD))
# register(currently_running, did_change_watched_files_registration())

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
end

"""
Loads the file-based configuration from the specified path into the server's config manager.

If the file does not exist or cannot be parsed, just return leaving the current
configuration unchanged. When there are unknown keys in the config file,
send error message while leaving current configuration unchanged.
"""
function load_file_config!(callback, server::Server, filepath::AbstractString;
                           reload::Bool = false)
    store!(server.state.config_manager) do old_data::ConfigManagerData
        if reload && old_data.file_config_path != filepath
            show_warning_message(server, "Loading unregistered configuration file: $filepath")
        end

        isfile(filepath) || return old_data, nothing
        parsed = TOML.tryparsefile(filepath)
        parsed isa TOML.ParserError && return old_data, nothing

        new_file_config = try
            Configurations.from_dict(JETLSConfig, parsed)
        catch e
            # TODO: remove this when Configurations.jl support to report
            #       full path of unknown key.
            if e isa Configurations.InvalidKeyError
                config_dict = to_config_dict(parsed)
                unknown_keys = collect_unmatched_keys(config_dict)
                if !isempty(unknown_keys)
                    show_error_message(server, unmatched_keys_in_config_file_msg(filepath, unknown_keys))
                    return old_data, nothing
                end
            end
            show_error_message(server, """
                Failed to load configuration file at $filepath:
                $(e)
                """)
            return old_data, nothing
        end

        new_data = ConfigManagerData(old_data;
            file_config=new_file_config,
            file_config_path=filepath
        )
        on_difference(callback, get_settings(old_data), get_settings(new_data))
        return new_data, nothing
    end
end

unmatched_keys_in_config_file_msg(filepath::AbstractString, unmatched_keys) =
    unmatched_keys_msg("Configuration file at $filepath contains unknown keys:", unmatched_keys)

function delete_file_config!(callback, manager::ConfigManager, filepath::AbstractString)
    store!(manager) do old_data::ConfigManagerData
        old_data.file_config_path == filepath || return old_data, nothing
        new_data = ConfigManagerData(old_data;
            file_config=EMPTY_CONFIG,
            file_config_path=nothing
        )
        on_difference(callback, get_settings(old_data), get_settings(new_data))
        return new_data, nothing
    end
end

function handle_DidChangeWatchedFilesNotification(server::Server, msg::DidChangeWatchedFilesNotification)
    for change in msg.params.changes
        changed_path = uri2filepath(change.uri)
        if is_config_file(changed_path)
            handle_config_file_change!(server, changed_path, change.type)
        end
    end
end
