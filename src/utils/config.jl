# TODO (later): move this definition to external files
global DEFAULT_CONFIG::Dict{String,Any} = Dict{String,Any}(
    "performance" => Dict{String,Any}(
        "full_analysis" => Dict{String,Any}(
            "debounce" => 1.0,
            "throttle" => 5.0
        )
    ),
    "testrunner" => Dict{String,Any}(
        "executable" => "testrunner"
    ),
)

global CONFIG_RELOAD_REQUIRED::Dict{String,Any} = Dict{String,Any}(
    "performance" => Dict{String,Any}(
        "full_analysis" => Dict{String,Any}(
            "debounce" => true,
            "throttle" => true
        )
    ),
    "testrunner" => Dict{String,Any}(
        "executable" => false
    ),
)

function access_nested_dict(dict::Dict{String,Any}, path::String, rest_path::String...)
    nextobj = @something get(dict, path, nothing) return nothing
    nextobj isa Dict{String,Any} || return nextobj
    return access_nested_dict(nextobj, rest_path...)
end

"""
    Base.lt(::ConfigFileOrder, path1, path2)

Compare two paths to determine their priority.
The order is determined by the following rule:

1. "__DEFAULT_CONFIG__" has lower priority than any other path.

This rules defines a total order. (See `is_config_file`)
"""
function Base.lt(::ConfigFileOrder, path1, path2)
    path1 == "__DEFAULT_CONFIG__" && return false
    path2 == "__DEFAULT_CONFIG__" && return true

    path1 == path2                && return false

    # unreachable
    return false
end

is_config_file(filepath::AbstractString) = filepath == "__DEFAULT_CONFIG__" || endswith(filepath, ".JETLSConfig.toml")

function register_config!(manager::ConfigManager,
                          filepath::AbstractString,
                          actual_config::Dict{String,Any} = Dict{String,Any}(),
                          latest_config::Dict{String,Any} = Dict{String,Any}())
    if !is_config_file(filepath)
        if JETLS_DEV_MODE
            @warn "File $filepath is not a recognized config file, skipping."
        end
        return
    end

    if haskey(manager.watched_files, filepath)
        if JETLS_DEV_MODE
            @warn "File $filepath is already being watched, skipping."
        end
        return
    end

    manager.watched_files[filepath] = ConfigState(actual_config, latest_config)
end

# Merge two dictionaries recursively with right precedence.
recursive_merge!(_, b) = b
recursive_merge!(a::Dict{String, Any}, b::Dict{String, Any}) = mergewith!(recursive_merge!, a, b)

"""
    fix_reload_required_settings!(manager::ConfigManager)

Traverse the reload-required settings from the currently registered config files,
merge them based on priority, and set them as the settings that require a reload
for this server.
"""
function fix_reload_required_settings!(manager::ConfigManager)
    for config in Iterators.reverse(collect(values(manager.watched_files)))
        recursive_merge!(manager.reload_required_setting, deepcopy(config.actual_config))
    end
end

is_reload_required_key(key_path::String...) = access_nested_dict(CONFIG_RELOAD_REQUIRED, key_path...) === true

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

is_watched_file(manager::ConfigManager, filepath::AbstractString) = haskey(manager.watched_files, filepath)

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

function merge_config!(on_reload_required::Function, actual_config::AbstractDict, latest_config::AbstractDict,
                       new_config::AbstractDict, key_path::Vector{String} = String[])
    for (k, v) in new_config
        current_path = [key_path; k]
        if v isa AbstractDict
            # `actual_config` and `latest_config` has the same structures,
            # so it is enough to check `actual_config` only.
            if haskey(actual_config, k) && actual_config[k] isa AbstractDict
                merge_config!(on_reload_required, actual_config[k], latest_config[k], v, current_path)
            else
                actual_config[k] = Dict{String,Any}()
                latest_config[k] = Dict{String,Any}()
                merge_config!(on_reload_required, actual_config[k], latest_config[k], v, current_path)
            end
        else
            if is_reload_required_key(current_path...)
                on_reload_required(actual_config, latest_config, current_path, v)
            else
                actual_config[k] = v
                latest_config[k] = v
            end
        end
    end
end

"""
    merge_config!(on_reload_required::Function, manager::ConfigManager, new_config::AbstractDict)

Merges `new_config` into the `manager`'s actual and latest configurations.
If a key in `new_config` requires a reload (as determined by `is_reload_required_key`)
and its value differs from the `manager.latest_config`,
the `on_reload_required` function is called with the `actual_config`, `latest_config`, the key path, and the new value.

If the key does not require a reload, it is directly merged into both `actual_config` and `latest_config`.
"""
function merge_config!(on_reload_required::Function, manager::ConfigManager, filepath::AbstractString, new_config::AbstractDict)
    config_state = get(manager.watched_files, filepath, nothing)
    if config_state === nothing
        if JETLS_DEV_MODE
            @warn "File $filepath is not being watched, skipping merge."
        end
        return
    end

    merge_config!(on_reload_required,
                  config_state.actual_config,
                  config_state.latest_config,
                  new_config)
end

"""
    get_config(manager::ConfigManager, key_path...)

Retrieves the current configuration value.
Among the registered configuration files, fetches the value in order of priority (see `Base.lt(::ConfigFileOrder, path1, path2)`).
If the key path does not exist in any of the configurations, returns `nothing`.
"""
function get_config(manager::ConfigManager, key_path::String...)
    is_reload_required_key(key_path...) && return access_nested_dict(manager.reload_required_setting, key_path...)
    for config in values(manager.watched_files)
        v = access_nested_dict(config.actual_config, key_path...)
        if v !== nothing
            return v
        end
    end

    return nothing
end

