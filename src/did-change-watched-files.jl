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
    if !isdefined(server.state, :root_path)
        if JETLS_DEV_MODE
            @info "server.state.root_path is not defined, skipping add JETLSConfig.toml watcher"
        end
        return
    end
    config_path = joinpath(server.state.root_path, "JETLSConfig.toml")
    push!(server.state.config_manager.watching_files, config_path)
    load_config!(server, config_path) do actual_config, latest_config, key_path, v
        # at initialization, we can just update the config in both actual and latest configs
        actual_config[last(key_path)] = v
        latest_config[last(key_path)] = v
    end
end

"""
Loads the configuration from the specified path into the server's config manager.

If the file does not exist or cannot be parsed, current configuration remains unchanged.
When there are unknown keys in the config file, send error by `workspace/showMessage`
and **current configuration is not changed.**
"""
function load_config!(on_reload_required, server::Server, path::AbstractString)
    isfile(path) || return
    parsed = TOML.tryparsefile(path)
    parsed isa TOML.ParserError && return # just skip to reduce noise while typing
    unknown_keys = collect_unmatched_keys(parsed)

    if !isempty(unknown_keys)
        show_error_message(server, """
            Configuration file at $path contains unknown keys.
            unknown keys: $(join(map(x -> join(x, "."), unknown_keys), ", "))
            """)
        return
    end

    merge_config!(on_reload_required,
                  server.state.config_manager,
                  parsed)
end

function handle_file_change!(server::Server, change::FileEvent)
    changed_path = uri2filepath(change.uri)
    change_type = change.type
    is_config_file(server, changed_path) || return
    if change_type == FileChangeType.Created || change_type == FileChangeType.Changed
        load_config!(server, changed_path) do _, latest_config, key_path, v
            k = last(key_path)
            if latest_config[k] !== v
                latest_config[k] = v
                show_warning_message(server, """
                    Configuration key `$(join(key_path, "."))` changed.
                    Restarting the server is required to apply the changes.
                    """)
            end
        end
    elseif change_type == FileChangeType.Deleted
        show_warning_message(server, """
            JETLSConfig.toml deleted.
            Restarting the server is required to apply the changes.
            """)
    end
end

function handle_DidChangeWatchedFilesNotification(server::Server, msg::DidChangeWatchedFilesNotification)
    for change in msg.params.changes
        handle_file_change!(server, change)
    end
end
