# TODO (later): move this definition to external files
const DEFAULT_CONFIG = Dict{String,Any}(
    "performance" => Dict{String,Any}(
        "full_analysis" => Dict{String,Any}(
            "debounce" => 1.0,
            "throttle" => 5.0
        )
    ),
    "testrunner" => Dict{String,Any}(
        "executable" => "testrunner",
    ),
)

const CONFIG_RELOAD_REQUIRED = Dict{String,Any}(
    "performance" => Dict{String,Any}(
        "full_analysis" => Dict{String,Any}(
            "debounce" => true,
            "throttle" => true
        )
    ),
    "testrunner" => Dict{String,Any}(
        "executable" => false,
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

"""
    collect_unmatched_keys(sub::AbstractDict, base::AbstractDict) -> Vector{Vector{String}}

Traverses the keys of `sub` and returns a list of key paths that are not present in `base`.
Note that this function does *not* perform deep structural comparison for keys whose values are dictionaries.

# Examples
```julia-repl
julia> collect_unmatched_keys(
            Dict("key1" => Dict("key2" => 0, "key3"  => 0, "key4"  => 0)),
            Dict("key1" => Dict("key2" => 0, "diff1" => 0, "diff2" => 0))
        )
2-element Vector{Vector{String}}:
 ["key1", "key3"]
 ["key1", "key4"]

julia> collect_unmatched_keys(
            Dict("key1" => 0, "key2" => 0),
            Dict("key1" => 1, "key2" => 1)
        )
Vector{String}[]

julia> collect_unmatched_keys(
           Dict("key1" => Dict("key2" => 0, "key3" => 0)),
           Dict("diff" => Dict("diff" => 0, "key3" => 0))
        )
1-element Vector{Vector{String}}:
 ["key1"]
```
"""
function collect_unmatched_keys(sub::AbstractDict, base::AbstractDict)
    unknown_keys = Vector{String}[]
    collect_unmatched_keys!(unknown_keys, sub, base, String[])
    return unknown_keys
end

collect_unmatched_keys(new_config::Dict{String,Any}) = collect_unmatched_keys(new_config, DEFAULT_CONFIG)

function collect_unmatched_keys!(unknown_keys::Vector{Vector{String}}, sub::AbstractDict, base::AbstractDict, key_path::Vector{String})
    for (k, v) in sub
        current_path = [key_path; k]
        b = get(base, k, nothing)
        if b === nothing
            push!(unknown_keys, current_path)
        elseif v isa AbstractDict
            if b isa AbstractDict
                collect_unmatched_keys!(unknown_keys, v, b, current_path)
            else
                push!(unknown_keys, current_path)
            end
        end
    end
end

is_config_file(server::Server, path::AbstractString) = path in server.state.config_manager.watching_files

function merge_config!(on_reload_required::Function, actual_config::AbstractDict, latest_config::AbstractDict,
                       new_config::AbstractDict, key_path::Vector{String} = String[])
    for (k, v) in new_config
        current_path = [key_path; k]
        if v isa AbstractDict
            merge_config!(on_reload_required, actual_config[k], latest_config[k], v, current_path)
        else
            if is_reload_required_key(current_path)
                on_reload_required(actual_config, latest_config, current_path, v)
            else
                actual_config[k] = v
                latest_config[k] = v
            end
        end
    end
end

"""
    merge_config!(on_reload_required::Function), manager::ConfigManager, new_config::AbstractDict

Merges `new_config` into the `manager`'s actual and latest configurations.
If a key in `new_config` requires a reload (as determined by `is_reload_required_key`)
and its value differs from the `manager.latest_config`,
the `on_reload_required` function is called with the `actual_config`, `latest_config`, the key path, and the new value.

If the key does not require a reload, it is directly merged into both `actual_config` and `latest_config`.

Assumes `new_config` has the same structure (`collect_unmatched_keys` returns empty vector) as `manager.actual_config` and `manager.latest_config`.
"""
merge_config!(on_reload_required::Function, manager::ConfigManager, new_config::AbstractDict) =
    merge_config!(on_reload_required, manager.actual_config, manager.latest_config, new_config)

get_config(manager::ConfigManager, key_path::Vector{String}) =
    access_nested_dict(manager.actual_config, key_path)
