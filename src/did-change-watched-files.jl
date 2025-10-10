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

function handle_config_file_change!(
        server::Server, changed_path::AbstractString, change_type::FileChangeType.Ty
    )
    changed_settings = String[]
    changed_static_settings = String[]

    if change_type == FileChangeType.Created
        load_config!(server, changed_path) do old_val, new_val, path
            if is_static_setting(path...)
                push!(changed_static_settings, join(path, "."))
            else
                push!(changed_settings, join(path, "."))
            end
            new_val
        end
        kind = "Created"
    elseif change_type == FileChangeType.Changed
        load_config!(server, changed_path; reload=true) do old_val, new_val, path
            if is_static_setting(path...)
                push!(changed_static_settings, join(path, "."))
            else
                push!(changed_settings, join(path, "."))
            end
            new_val
        end
        kind = "Updated"
    elseif change_type == FileChangeType.Deleted
        delete_config!(server.state.config_manager, changed_path) do old_val, new_val, path
            if is_static_setting(path...)
                push!(changed_static_settings, join(path, "."))
            else
                push!(changed_settings, join(path, "."))
            end
            new_val
        end
        kind = "Deleted"
    else error("Unknown FileChangeType") end

    if !isempty(changed_static_settings) && !isempty(changed_settings)
        settings_str = join(string.('`', changed_settings, '`'), ", ")
        static_str = join(string.('`', changed_static_settings, '`'), ", ")
        show_warning_message(server, """
            $kind config file: $changed_path
            Changes applied: $settings_str
            Static settings affected: $static_str (requires restart to apply)
            """)
    elseif !isempty(changed_static_settings)
        static_str = join(string.('`', changed_static_settings, '`'), ", ")
        show_warning_message(server, """
            $kind config file: $changed_path
            Static settings affected: $static_str (requires restart to apply)
            """)
    elseif !isempty(changed_settings)
        settings_str = join(string.('`', changed_settings, '`'), ", ")
        show_info_message(server, """
            $kind config file: $changed_path
            Changes applied: $settings_str
            """)
    elseif kind != "Updated"
        show_info_message(server, """
            $kind config file: $changed_path
            """)
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
