is_config_file(filepath::AbstractString) =
    basename(filepath) == ".JETLSConfig.toml"

@generated function on_difference(
    callback,
    old_config::T,
    new_config::T,
    path::NTuple{N,Symbol}=()
) where {T<:ConfigSection,N}
    entries = (
        :(on_difference(
            callback,
            getfield(old_config, $(QuoteNode(fname))),
            getfield(new_config, $(QuoteNode(fname))),
            (path..., $(QuoteNode(fname)))
        ))
        for fname in fieldnames(T)
    )

    quote
        $T($(entries...))
    end
end

@generated function on_difference(
    callback,
    old_val::T,
    new_val::Nothing,
    path::Tuple
) where T <: ConfigSection
    entries = (
        :(on_difference(
            callback,
            getfield(old_val, $(QuoteNode(fname))),
            nothing,
            (path..., $(QuoteNode(fname)))
        ))
        for fname in fieldnames(T)
    )

    quote
        $T($(entries...))
    end
end

@generated function on_difference(
    callback,
    old_val::Nothing,
    new_val::T,
    path::Tuple
) where T <: ConfigSection
    entries = (
        :(on_difference(
            callback,
            nothing,
            getfield(new_val, $(QuoteNode(fname))),
            (path..., $(QuoteNode(fname)))
        ))
        for fname in fieldnames(T)
    )

    quote
        $T($(entries...))
    end
end

on_difference(callback, old_val, new_val, path::Tuple) =
    old_val !== new_val ? callback(old_val, new_val, path) : old_val

"""
    merge_setting(base::T, overlay::T) where {T<:ConfigSection} -> T

Merges two configuration objects, with `overlay` taking precedence over `base`.
If a field in `overlay` is `nothing`, the corresponding field from `base` is retained.
"""
merge_setting(base::T, overlay::T) where {T<:ConfigSection} =
    on_difference((base_val, overlay_val, _) -> overlay_val === nothing ? base_val : overlay_val, base, overlay)

# TODO: remove this.
#       (now this is used for `collect_unmatched_keys` only. see that's comment)
const ConfigDict = Base.PersistentDict{String, Any}
to_config_dict(dict::AbstractDict) = ConfigDict((k => (v isa AbstractDict ? to_config_dict(v) : v) for (k, v) in dict)...)

const DEFAULT_CONFIG_DICT = to_config_dict(Configurations.to_dict(DEFAULT_CONFIG))

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

TODO: remove this. This is a temporary workaround to report unknown keys in the config file
      until Configurations.jl supports reporting full path of unknown keys.
"""
function collect_unmatched_keys(this::ConfigDict, ref::ConfigDict=DEFAULT_CONFIG_DICT)
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
Among the registered configuration files, fetches the value in order of priority.
If the key path does not exist in any of the configurations, returns `nothing`.
"""
Base.@constprop :aggressive function get_config(manager::ConfigManager, key_path::Symbol...)
    try
        data = load(manager)
        if is_static_setting(key_path...)
            return getobjpath(data.static_settings, key_path...)
        else
            settings = get_settings(data)
            return getobjpath(settings, key_path...)
        end
    catch e
        e isa FieldError ? nothing : rethrow()
    end
end

function fix_static_settings!(manager::ConfigManager)
    store!(manager) do old_data::ConfigManagerData
        new_static = get_settings(old_data)
        new_data = ConfigManagerData(old_data; static_settings=new_static)
        return new_data, new_static
    end
end

struct ConfigChange
    path::String
    old_val
    new_val
    ConfigChange(path::String, @nospecialize(old_val), @nospecialize(new_val)) = new(path, old_val, new_val)
end

struct ConfigChangeTracker
    changed_settings::Vector{ConfigChange}
    changed_static_settings::Vector{ConfigChange}
end
ConfigChangeTracker() = ConfigChangeTracker(ConfigChange[], ConfigChange[])

function (tracker::ConfigChangeTracker)(old_val, new_val, path::Tuple{Vararg{Symbol}})
    if old_val !== new_val
        path_str = join(path, ".")
        if is_static_setting(path...)
            push!(tracker.changed_static_settings, ConfigChange(path_str, old_val, new_val))
        else
            push!(tracker.changed_settings, ConfigChange(path_str, old_val, new_val))
        end
    end
    return new_val
end

function changed_settings_message(changed_settings::Vector{ConfigChange})
    body = map(changed_settings) do config_change
        old_repr = repr(config_change.old_val)
        new_repr = repr(config_change.new_val)
        "`$(config_change.path)` (`$old_repr` => `$new_repr`)"
    end |> (x -> join(x, ", "))
    return "Changes applied: $body"
end

function changed_static_settings_message(changed_settings::Vector{ConfigChange})
    body = map(changed_settings) do config_change
        old_repr = repr(config_change.old_val)
        new_repr = repr(config_change.new_val)
        "`$(config_change.path)` (`$old_repr` => `$new_repr`)"
    end |> (x -> join(x, ", "))
    return "Static settings affected (requires restart to apply): $body"
end

function notify_config_changes(
        server::Server,
        tracker::ConfigChangeTracker,
        source::AbstractString
    )
    if !isempty(tracker.changed_static_settings) && !isempty(tracker.changed_settings)
        show_warning_message(server, """
            Configuration changed.
            Source: $source
            $(changed_settings_message(tracker.changed_settings))
            $(changed_static_settings_message(tracker.changed_static_settings))
            """)
    elseif !isempty(tracker.changed_static_settings)
        show_warning_message(server, """
            Configuration changed.
            Source: $source
            $(changed_static_settings_message(tracker.changed_static_settings))
            """)
    elseif !isempty(tracker.changed_settings)
        show_info_message(server, """
            Configuration changed.
            Source: $source
            $(changed_settings_message(tracker.changed_settings))
            """)
    end
end

unmatched_keys_msg(header_msg::AbstractString, unmatched_keys) =
    header_msg * "\n" * join(map(x -> string('`', join(x, "."), '`'), unmatched_keys), ", ")
