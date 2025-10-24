struct LoadLSPConfigHandler
    server::Server
    source::String
end

function (handler::LoadLSPConfigHandler)(server::Server, @nospecialize(config_value))
    tracker = ConfigChangeTracker()
    if config_value === nothing
        delete_lsp_config!(tracker, server)
    else
        store_lsp_config!(tracker, server, config_value, handler.source)
    end
    notify_config_changes(handler.server, tracker, handler.source)
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

function load_lsp_config!(server::Server, source::AbstractString)
    supports(server, :workspace, :configuration) || return false
    handler = LoadLSPConfigHandler(server, source)
    request_workspace_configuration(handler, server, nothing)
    return true
end

unmatched_keys_in_lsp_config_msg(unmatched_keys) =
    unmatched_keys_msg("LSP configuration contains unknown keys:", unmatched_keys)

function store_lsp_config!(tracker::ConfigChangeTracker, server::Server, @nospecialize(config_value), source::AbstractString)
    if config_value isa Dict{String,Any}
        config_dict = config_value
    else
        show_error_message(server, "Unexpected config data was passed from $source, deleting LSP configuration")
        return delete_lsp_config!(tracker, server)
    end
    store!(server.state.config_manager) do old_data::ConfigManagerData
        new_lsp_config = try
            Configurations.from_dict(JETLSConfig, config_dict)
        catch e
            if e isa Configurations.InvalidKeyError
                unknown_keys = collect_unmatched_keys(to_config_dict(config_dict))
                if !isempty(unknown_keys)
                    show_error_message(server, unmatched_keys_in_lsp_config_msg(unknown_keys))
                    return old_data, nothing
                end
            end
            show_error_message(server, "Failed to parse LSP configuration: $(e)")
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

function handle_DidChangeConfigurationNotification(server::Server, msg::DidChangeConfigurationNotification)
    source = "[LSP] workspace/didChangeConfiguration"
    if !load_lsp_config!(server, source)
        # If the client doesn't support the pull model configuration,
        # use `msg.params.settings` as the fallback
        tracker = ConfigChangeTracker()
        store_lsp_config!(tracker, server, msg.params.settings, source)
        notify_config_changes(server, tracker, source)
    end
end

function did_change_configuration_registration()
    return Registration(;
        id = String(gensym(:DidChangeConfigurationRegistration)),
        method = "workspace/didChangeConfiguration",
        registerOptions = nothing)
end
