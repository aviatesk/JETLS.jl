using TOML

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
#     id=DID_CHANGE_WATCHED_FILES_REGISTRATION_ID,
#     method=DID_CHANGE_WATCHED_FILES_REGISTRATION_METHOD))
# register(currently_running, did_change_watched_files_registration())

function initialize_config!(server::Server)
    if !isdefined(server.state, :root_path)
        if JETLS_DEV_MODE
            @info "`server.state.root_path` is not defined, skip registration at startup."
        end
    else
        config_path = joinpath(server.state.root_path, ".JETLSConfig.toml")
        if !isfile(config_path)
            if JETLS_DEV_MODE
                @info "No configuration file found at $config_path, skip registration at startup."
            end
        else
            register_config!(server.state.config_manager, config_path)
            load_config!(Returns(nothing), server, config_path) # in initialization, no actions are required
        end
    end

    fix_reload_required_settings!(server.state.config_manager)
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
            Configuration file at $path contains unknown keys:
            $(join(map(x -> join(x, "."), unknown_keys), ", "))
            """)
        return
    end

    merge_config!(on_reload_required,
                  server.state.config_manager,
                  path,
                  parsed)
end

function handle_file_change!(server::Server, change::FileEvent)
    changed_path = uri2filepath(change.uri)
    change_type = change.type
    # show message when `changed_path` is a highest priority or
    # check effective precisely only?
    if change_type == FileChangeType.Created
        register_config!(server.state.config_manager, changed_path)
        show_warning_message(server, """
            Configuration file $changed_path was created.
            Please restart the server to apply the changes that require restart.
            """)
        load_config!(Returns(nothing), server, changed_path)
    elseif change_type == FileChangeType.Changed
        is_watched_file(server.state.config_manager, changed_path) || return
        load_config!(server, changed_path) do current_config, new_value, k, path
            if !haskey(current_config, k) || current_config[k] != new_value
                show_warning_message(server, """
                    Configuration key `$(join(path, "."))` was changed.
                    Please restart the server to apply the changes that require restart.
                    """)
            end
         end
    elseif change_type == FileChangeType.Deleted
        is_watched_file(server.state.config_manager, changed_path) || return
        delete!(server.state.config_manager.watched_files, changed_path)
        show_warning_message(server, """
            $changed_path was deleted.
            You may need to restart the server to apply the changes that require restart.
            """)
    end
end

function handle_DidChangeWatchedFilesNotification(server::Server, msg::DidChangeWatchedFilesNotification)
    for change in msg.params.changes
        handle_file_change!(server, change)
    end
end
