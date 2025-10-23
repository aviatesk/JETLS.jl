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
        load_config!(tracker, server, changed_path)
        kind = "created"
        show_info_message(server, config_file_created_msg(changed_path))
    elseif change_type == FileChangeType.Changed
        load_config!(tracker, server, changed_path; reload=true)
        kind = "updated"
    elseif change_type == FileChangeType.Deleted
        delete_config!(tracker, server.state.config_manager, changed_path)
        kind = "deleted"
        show_info_message(server, config_file_deleted_msg(changed_path))
    else error("Unknown FileChangeType") end

    source = "[.JETLSConfig.toml] $(dirname(changed_path)) ($kind)"
    notify_config_changes(server, tracker, source)
end

function handle_DidChangeWatchedFilesNotification(server::Server, msg::DidChangeWatchedFilesNotification)
    for change in msg.params.changes
        changed_path = uri2filepath(change.uri)
        if is_config_file(changed_path)
            handle_config_file_change!(server, changed_path, change.type)
        end
    end
end
