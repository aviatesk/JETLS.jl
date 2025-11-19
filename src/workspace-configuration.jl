struct LoadLSPConfigHandler
    server::Server
    source::String
    on_init::Bool
end

function (handler::LoadLSPConfigHandler)(server::Server, @nospecialize(config_value))
    tracker = ConfigChangeTracker()
    if config_value === nothing
        delete_lsp_config!(tracker, server)
    else
        store_lsp_config!(tracker, server, config_value, handler.source)
    end
    if handler.on_init
        # Don't notify even if values different from defaults are loaded initially
        fix_static_settings!(server.state.config_manager)
    else
        notify_config_changes(handler.server, tracker, handler.source)
        if tracker.diagnostic_setting_changed
            notify_diagnostics!(server)
        end
    end
end

struct WorkspaceConfigurationCaller <: RequestCaller
    handler::LoadLSPConfigHandler
end

function request_workspace_configuration(
        handler::LoadLSPConfigHandler,
        server::Server,
        section::Union{Nothing,String}=nothing
    )
    id = String(gensym(:WorkspaceConfigurationRequest))
    addrequest!(server, id=>WorkspaceConfigurationCaller(handler))
    return send(server, ConfigurationRequest(;
        id,
        params = ConfigurationParams(;
            items = ConfigurationItem[ConfigurationItem(; section)])))
end

function handle_workspace_configuration_response(
        server::Server, msg::Dict{Symbol,Any}, caller::WorkspaceConfigurationCaller
    )
    if handle_response_error(server, msg, "workspace/configuration")
    elseif haskey(msg, :result)
        result = msg[:result]
        if result isa Vector && !isempty(result)
            config_value = first(result)
            caller.handler(server, config_value)
        elseif JETLS_DEV_MODE
            @info "workspace/configuration returned empty result"
        end
    else
        show_error_message(server, "Unexpected response from workspace/configuration request")
    end
end

function load_lsp_config!(server::Server, source::AbstractString; on_init::Bool=false)
    handler = LoadLSPConfigHandler(server, source, on_init)
    request_workspace_configuration(handler, server, nothing)
    nothing
end

unmatched_keys_in_lsp_config_msg(unmatched_keys) =
    unmatched_keys_msg("LSP configuration contains unknown keys:", unmatched_keys)

function store_lsp_config!(tracker::ConfigChangeTracker, server::Server, @nospecialize(config_value), source::AbstractString)
    if config_value isa AbstractDict{String}
        config_dict = config_value
    else
        if config_value !== nothing
            show_error_message(server, lazy"Unexpected config data of type $(typeof(config_value)) was passed from $source, deleting LSP configuration")
        end
        return delete_lsp_config!(tracker, server)
    end
    store!(server.state.config_manager) do old_data::ConfigManagerData
        new_lsp_config = parse_config_dict(config_dict)
        if new_lsp_config isa AbstractString
            show_error_message(server, new_lsp_config)
            return old_data, nothing
        end
        new_data = ConfigManagerData(old_data; lsp_config=new_lsp_config)
        on_difference(tracker, get_settings(old_data), get_settings(new_data))
        return new_data, nothing
    end
end

function delete_lsp_config!(tracker::ConfigChangeTracker, server::Server)
    store!(server.state.config_manager) do old_data::ConfigManagerData
        new_data = ConfigManagerData(old_data; lsp_config=EMPTY_CONFIG)
        on_difference(tracker, get_settings(old_data), get_settings(new_data))
        return new_data, nothing
    end
end

function load_lsp_config!(
        server::Server, @nospecialize(settings), source::AbstractString;
        on_init::Bool = false
    )
    if supports(server, :workspace, :configuration)
        load_lsp_config!(server, source; on_init)
    else
        tracker = ConfigChangeTracker()
        store_lsp_config!(tracker, server, settings, source)
        if on_init
            # Don't notify even if values different from defaults are loaded initially
            fix_static_settings!(server.state.config_manager)
        else
            notify_config_changes(server, tracker, source)
            if tracker.diagnostic_setting_changed
                notify_diagnostics!(server)
            end
        end
    end
end

function handle_DidChangeConfigurationNotification(server::Server, msg::DidChangeConfigurationNotification)
    source = "[LSP] workspace/didChangeConfiguration"
    # In a case when client doesn't support the pull model configuration,
    # use `msg.params.settings` as the fallback
    load_lsp_config!(server, msg.params.settings, source)
end

function did_change_configuration_registration()
    return Registration(;
        id = String(gensym(:DidChangeConfigurationRegistration)),
        method = "workspace/didChangeConfiguration",
        registerOptions = nothing)
end
