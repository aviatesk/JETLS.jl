# TODO: move this hardcoded config to a file
const DEFAULT_CONFIG = Dict{String,Any}(
    "performance" => Dict{String,Any}(
        "full_analysis" => Dict{String,Any}(
            "debounce" => 1.0,
            "throttle" => 5.0
        )
    ),
)

const CONFIG_RELOAD_REQUIRED = Dict{String,Any}(
    "performance" => Dict{String,Any}(
        "full_analysis" => Dict{String,Any}(
            "debounce" => true,
            "throttle" => true
        )
    ),
)

function access_nested_dict(dict::AbstractDict, key_path::Vector{String})
    current_dict = dict
    for key in key_path
        if haskey(current_dict, key)
            current_dict = current_dict[key]
        else
            return nothing
        end
    end
    return current_dict
end

is_reload_required_key(key_path::Vector{String}) = access_nested_dict(CONFIG_RELOAD_REQUIRED, key_path) === true

function collect_unknown_keys(new_config::Dict{String,Any})
    unknown_keys = String[]
    collect_unmatch_keys!(unknown_keys, new_config, DEFAULT_CONFIG, String[])
    return unknown_keys
end

function collect_unmatch_keys!(unknown_keys::Vector{String}, sub::AbstractDict, base::AbstractDict, key_path::Vector{String})
    for (k, v) in sub
        current_path = [key_path; k]
        b = get(base, k, nothing)
        if b === nothing
            push!(unknown_keys, join(current_path, "."))
        elseif v isa AbstractDict
            if b isa AbstractDict
                collect_unmatch_keys!(unknown_keys, v, b, current_path)
            else
                push!(unknown_keys, join(current_path, "."))
            end
        end
    end
end

is_config_file(server::Server, path::AbstractString) = path in server.state.config_manager.watching_files

function merge_config!(actual_config::Dict{String,Any}, latest_config::Dict{String,Any},
                       new_config::Dict{String,Any}, on_reload_required::Function, key_path::Vector{String} = String[])
    for (k, v) in new_config
        current_path = [key_path; k]
        if v isa AbstractDict
            merge_config!(actual_config[k], latest_config[k], v, on_reload_required, current_path)
        else
            if is_reload_required_key(current_path)
                if latest_config[k] !== v
                    latest_config[k] = v
                    on_reload_required(current_path)
                end
            else
                actual_config[k] = v
                latest_config[k] = v
            end
        end
    end
end

get_config(server::Server, key_path::Vector{String}) =
    access_nested_dict(server.state.config_manager.actual_config, key_path)
