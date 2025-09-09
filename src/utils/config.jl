function access_nested_dict(dict::Dict{String,Any}, path::String, rest_path::String...)
    nextobj = @something get(dict, path, nothing) return nothing
    if !(nextobj isa Dict{String,Any})
        if isempty(rest_path)
            return nextobj
        else
            return nothing
        end
    end
    return access_nested_dict(nextobj, rest_path...)
end

"""
    traverse_merge!(on_leaf, target::Dict{String,Any},
                    source::Dict{String,Any}, key_path::Vector{String})

Recursively merges `source` into `target`, traversing nested dictionaries.
If a key in `source` is a dictionary, it will recursively merge it into the corresponding key in `target`.
If a key in `source` is not a dictionary, the `on_leaf` function is called with:
- `target`: the target dictionary being modified
- `k`: the key from `source`
- `v`: the value from `source`
- `path`: the current path as a vector of strings

If the key does not exist in `target`, it will be created as an empty dictionary before merging.
"""
function traverse_merge!(on_leaf, target::Dict{String,Any},
                         source::Dict{String,Any}, key_path::Vector{String})
    for (k, v) in source
        current_path = [key_path; k]
        if v isa Dict{String,Any}
            tv = get(target, k, nothing)
            if tv isa Dict{String,Any}
                traverse_merge!(on_leaf, tv, v, current_path)
            else
                tv = target[k] = Dict{String,Any}()
                traverse_merge!(on_leaf, tv, v, current_path)
            end
        else
            on_leaf(target, k, v, current_path)
        end
    end
    return target
end

is_reload_required_key(key_path::String...) = access_nested_dict(CONFIG_RELOAD_REQUIRED, key_path...) === true

is_config_file(filepath::AbstractString) = filepath == "__DEFAULT_CONFIG__" || endswith(filepath, ".JETLSConfig.toml")

is_watched_file(manager::ConfigManager, filepath::AbstractString) = haskey(manager.watched_files, filepath)

"""
    Base.lt(::ConfigFileOrder, path1, path2)

Compare two paths to determine **reverse of** their priority.
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

function register_config!(manager::ConfigManager,
                          filepath::AbstractString,
                          config::Dict{String,Any} = Dict{String,Any}())
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

    manager.watched_files[filepath] = config
end

function selective_merge!(target::Dict{String,Any}, source::Dict{String,Any},
                          on_leaf_filter = Returns(true),
                          key_path::Vector{String} = String[])
    traverse_merge!(target, source, key_path) do t, k, v, path
        on_leaf_filter(path) && (t[k] = v)
    end
end

function merge_reload_required_keys!(target::Dict{String,Any}, source::Dict{String,Any})
    selective_merge!(target, source, Base.Splat(is_reload_required_key), String[])
    cleanup_empty_dicts!(target)
end

function cleanup_empty_dicts!(dict::Dict{String,Any})
    for (k, v) in dict
        if v isa Dict{String,Any}
            cleanup_empty_dicts!(v)
            if isempty(v)
                delete!(dict, k)
            end
        end
    end
end

"""
    fix_reload_required_settings!(manager::ConfigManager)

Traverse the reload-required settings from the currently registered config files,
merge them based on priority, and set them as the settings that require a reload
for this server.
"""
function fix_reload_required_settings!(manager::ConfigManager)
    for config in Iterators.reverse(values(manager.watched_files))
        merge_reload_required_keys!(manager.reload_required_setting, config)
    end
end

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

"""
    merge_config!(on_reload_required, current_config::Dict{String, Any},
                  new_config::Dict{String, Any}, key_path::Vector{String} = String[])

Merges `new_config` into `current_config`, updating the values in `current_config`.
If a key in `new_config` is marked as requiring a reload (using `is_reload_required_key`),
the `on_reload_required` function is called with the target dictionary, value, key, and path.
"""
function merge_config!(on_reload_required, current_config::Dict{String, Any},
                       new_config::Dict{String, Any}, key_path::Vector{String} = String[])
    traverse_merge!(current_config, new_config, key_path) do t, k, v, path
        if is_reload_required_key(path...)
            on_reload_required(t, v, k, path)
        end
        t[k] = v
    end
end

function merge_config!(on_reload_required, manager::ConfigManager, filepath::AbstractString, new_config::AbstractDict)
    current_config = get(manager.watched_files, filepath, nothing)
    if current_config === nothing
        if JETLS_DEV_MODE
            @warn "File $filepath is not being watched, skipping merge."
        end
        return
    end

    merge_config!(on_reload_required,
                  current_config,
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
        v = access_nested_dict(config, key_path...)
        if v !== nothing
            return v
        end
    end

    return nothing
end
