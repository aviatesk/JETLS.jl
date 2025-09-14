# TODO (later): move this definition to external files
const DEFAULT_CONFIG = ConfigDict(
    "full_analysis" => ConfigDict(
        "debounce" => 1.0
    ),
    "testrunner" => ConfigDict(
        "executable" => "testrunner"
    ),
    "internal" => ConfigDict(
        "static_setting" => 0
    ),
)

const STATIC_CONFIG = ConfigDict(
    "full_analysis" => ConfigDict(
        "debounce" => false
    ),
    "testrunner" => ConfigDict(
        "executable" => false
    ),
    "internal" => ConfigDict(
        "static_setting" => true
    ),
)

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

is_config_file(filepath::AbstractString) = filepath == "__DEFAULT_CONFIG__" || basename(filepath) == ".JETLSConfig.toml"

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

function merge_settings(base::ConfigDict, overlay::ConfigDict)
    return traverse_merge(base, overlay) do _, v
        v
    end |> cleanup_empty_dicts
end

function get_settings(data::ConfigManagerData)
    result = ConfigDict()
    for config in Iterators.reverse(values(data.watched_files))
        result = merge_settings(result, config)
    end
    return result
end

function merge_static_settings(base::ConfigDict, overlay::ConfigDict)
    return traverse_merge(base, overlay) do path, v
        is_static_setting(path...) ? v : nothing
    end |> cleanup_empty_dicts
end

function get_static_settings(data::ConfigManagerData)
    result = ConfigDict()
    for config in Iterators.reverse(values(data.watched_files))
        result = merge_static_settings(result, config)
    end
    return result
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
    get_config(manager::ConfigManager, key_path...)

Retrieves the current configuration value.
Among the registered configuration files, fetches the value in order of priority (see `Base.lt(::ConfigFileOrder, path1, path2)`).
If the key path does not exist in any of the configurations, returns `nothing`.
"""
function get_config(manager::ConfigManager, key_path::String...)
    is_static_setting(key_path...) &&
        return access_nested_dict(load(manager).static_settings, key_path...)
    for config in values(load(manager).watched_files)
        return @something access_nested_dict(config, key_path...) continue
    end
    return nothing
end

function fix_static_settings!(manager::ConfigManager)
    store!(manager) do old_data
        new_static = get_static_settings(old_data)
        new_data = ConfigManagerData(new_static, old_data.watched_files)
        return new_data, new_static
    end
end

"""
Loads the configuration from the specified path into the server's config manager.

If the file does not exist or cannot be parsed, just return leaving the current
configuration unchanged. When there are unknown keys in the config file,
send error message while leaving current configuration unchanged.
"""
function load_config!(on_leaf, server::Server, filepath::AbstractString;
                      reload::Bool = false)
    store!(server.state.config_manager) do old_data
        if reload
            haskey(old_data.watched_files, filepath) ||
                show_warning_message(server, "Loading unregistered configuration file: $filepath")
        end

        isfile(filepath) || return old_data, nothing
        parsed = TOML.tryparsefile(filepath)
        parsed isa TOML.ParserError && return old_data, nothing

        new_config = to_config_dict(parsed)

        unknown_keys = collect_unmatched_keys(new_config)
        if !isempty(unknown_keys)
            show_error_message(server, """
                Configuration file at $filepath contains unknown keys:
                $(join(map(x -> string('`', join(x, "."), '`'), unknown_keys), ", "))
                """)
            return old_data, nothing
        end

        current_config = get(old_data.watched_files, filepath, DEFAULT_CONFIG)
        merged_config = traverse_merge(current_config, new_config) do filepath, v
            on_leaf(current_config, filepath, v)
            v
        end
        new_watched_files = copy(old_data.watched_files)
        new_watched_files[filepath] = merged_config
        new_data = ConfigManagerData(old_data.static_settings, new_watched_files)
        return new_data, nothing
    end
end

to_config_dict(dict::Dict{String,Any}) = ConfigDict(
    (k => (v isa Dict{String,Any} ? to_config_dict(v) : v) for (k, v) in dict)...)

function delete_config!(on_leaf, manager::ConfigManager, filepath::AbstractString)
    store!(manager) do old_data
        old_settings = get_settings(old_data)
        new_watched_files = copy(old_data.watched_files)
        delete!(new_watched_files, filepath)
        new_data = ConfigManagerData(old_data.static_settings, new_watched_files)
        new_settings = get_settings(new_data)
        traverse_merge(old_settings, new_settings) do path, v
            on_leaf(old_settings, path, v)
            nothing
        end
        return new_data, nothing
    end
end
