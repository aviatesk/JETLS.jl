function access_nested_dict(dict::ConfigDict, path::String, rest_path::String...)
    nextobj = @something get(dict, path, nothing) return nothing
    if !(nextobj isa ConfigDict)
        if isempty(rest_path)
            return nextobj
        else
            return nothing
        end
    end
    return access_nested_dict(nextobj, rest_path...)
end

"""
    traverse_merge(on_leaf, base::ConfigDict, overlay::ConfigDict) -> merged::ConfigDict

Return a new `ConfigDict` whose key value pairs are merged from `base` and `overlay`.

If a key in `overlay` is a dictionary, it will recursively merge it into the corresponding
key in `base`, creating new `ConfigDict` instances along the way.

When a value in `overlay` is not a dictionary, the `on_leaf` function is called with:
- `current_path`: the current path as a vector of strings
- `v`: the value from `overlay`
The `on_leaf(current_path, v) -> newv` function should return the value to be stored
in the result, or `nothing` to skip storing the key.
"""
function traverse_merge(
        on_leaf, base::ConfigDict, overlay::ConfigDict,
        key_path::Vector{String} = String[]
    )
    result = base
    for (k, v) in overlay
        current_path = [key_path; k]
        if v isa ConfigDict
            base_v = get(base, k, nothing)
            if base_v isa ConfigDict
                merged_v = traverse_merge(on_leaf, base_v, v, current_path)
                result = ConfigDict(result, k => merged_v)
            else
                merged_v = traverse_merge(on_leaf, ConfigDict(), v, current_path)
                result = ConfigDict(result, k => merged_v)
            end
        else
            on_leaf_result = on_leaf(current_path, v)
            if on_leaf_result !== nothing
                result = ConfigDict(result, k => on_leaf_result)
            end
        end
    end
    return result
end

is_static_setting(key_path::String...) = access_nested_dict(STATIC_CONFIG, key_path...) === true

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
    return false # unreachable
end

function register_config!(manager::ConfigManager,
                          filepath::AbstractString,
                          config::ConfigDict = ConfigDict())
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

function merge_static_settings(base::ConfigDict, overlay::ConfigDict)
    return traverse_merge(base, overlay) do path, v
        is_static_setting(path...) ? v : nothing
    end |> cleanup_empty_dicts
end

function cleanup_empty_dicts(dict::ConfigDict)
    result = dict
    for (k, v) in dict
        if v isa ConfigDict
            cleaned_v = cleanup_empty_dicts(v)
            if isempty(cleaned_v)
                result = Base.delete(result, k)
            elseif cleaned_v != v
                result = ConfigDict(result, k => cleaned_v)
            end
        end
    end
    return result
end

"""
    fix_static_settings!(manager::ConfigManager)

Traverse the static settings from the currently registered config files,
merge them based on priority, and set them as the settings that require a reload
for this server.
"""
function fix_static_settings!(manager::ConfigManager)
    result = manager.static_settings
    for config in Iterators.reverse(values(manager.watched_files))
        result = merge_static_settings(result, config)
    end
    manager.static_settings = result
end

"""
    collect_unmatched_keys(this::ConfigDict, ref::ConfigDict) -> Vector{Vector{String}}

Traverses the keys of `this` and returns a list of key paths that are not present in `ref`.
Note that this function does *not* perform deep structural comparison for keys whose values are dictionaries.

# Examples
```julia-repl
julia> collect_unmatched_keys(
            ConfigDict("key1" => ConfigDict("key2" => 0, "key3"  => 0, "key4"  => 0)),
            ConfigDict("key1" => ConfigDict("key2" => 0, "diff1" => 0, "diff2" => 0))
        )
2-element Vector{Vector{String}}:
 ["key1", "key3"]
 ["key1", "key4"]

julia> collect_unmatched_keys(
            ConfigDict("key1" => 0, "key2" => 0),
            ConfigDict("key1" => 1, "key2" => 1)
        )
Vector{String}[]

julia> collect_unmatched_keys(
           ConfigDict("key1" => ConfigDict("key2" => 0, "key3" => 0)),
           ConfigDict("diff" => ConfigDict("diff" => 0, "key3" => 0))
        )
1-element Vector{Vector{String}}:
 ["key1"]
```
"""
function collect_unmatched_keys(this::ConfigDict, ref::ConfigDict=DEFAULT_CONFIG)
    unknown_keys = Vector{String}[]
    collect_unmatched_keys!(unknown_keys, this, ref, String[])
    return unknown_keys
end

function collect_unmatched_keys!(
        unknown_keys::Vector{Vector{String}},
        this::ConfigDict, ref::ConfigDict, key_path::Vector{String}
    )
    for (k, v) in this
        current_path = [key_path; k]
        b = get(ref, k, nothing)
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
    merge_config!(on_static_setting, manager::ConfigManager, filepath::AbstractString, new_config::ConfigDict)

Merges `new_config` into the configuration file tracked by `manager` at `filepath`.
Updates the configuration stored in `manager.watched_files[filepath]` by merging in the new values.
If a key in `new_config` is marked as requiring a reload (using `is_static_setting`),
the `on_static_setting` function is called with the current config dictionary, value, key, and path.
If the filepath is not being watched by the manager, the operation is skipped with a warning in dev mode.
"""
function merge_config!(
        on_static_setting, manager::ConfigManager, filepath::AbstractString, new_config::ConfigDict
    )
    current_config = get(manager.watched_files, filepath, nothing)
    if current_config === nothing
        if JETLS_DEV_MODE
            @warn "File $filepath is not being watched, skipping merge."
        end
        return
    end
    manager.watched_files[filepath] = traverse_merge(current_config, new_config) do path, v
        if is_static_setting(path...)
            on_static_setting(current_config, path, v)
        end
        v
    end
end

"""
    get_config(manager::ConfigManager, key_path...)

Retrieves the current configuration value.
Among the registered configuration files, fetches the value in order of priority (see `Base.lt(::ConfigFileOrder, path1, path2)`).
If the key path does not exist in any of the configurations, returns `nothing`.
"""
function get_config(manager::ConfigManager, key_path::String...)
    is_static_setting(key_path...) && return access_nested_dict(manager.static_settings, key_path...)
    for config in values(manager.watched_files)
        v = access_nested_dict(config, key_path...)
        if v !== nothing
            return v
        end
    end
    return nothing
end
