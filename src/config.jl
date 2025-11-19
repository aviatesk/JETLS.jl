is_config_file(filepath::AbstractString) =
    basename(filepath) == ".JETLSConfig.toml"

@generated function on_difference(
        callback,
        old_config::T,
        new_config::T,
        path::Tuple{Vararg{Symbol}}=()
    ) where {T<:ConfigSection}
    entries = Expr[
        :(on_difference(
            callback,
            getfield(old_config, $(QuoteNode(fname))),
            getfield(new_config, $(QuoteNode(fname))),
            (path..., $(QuoteNode(fname)))))
        for fname in fieldnames(T)]
    quote
        $T($(entries...))
    end
end

@generated function on_difference(
        callback,
        old_val::T,
        ::Nothing,
        path::Tuple{Vararg{Symbol}}
    ) where T <: ConfigSection
    entries = Expr[
        :(on_difference(
            callback,
            getfield(old_val, $(QuoteNode(fname))),
            nothing,
            (path..., $(QuoteNode(fname)))))
        for fname in fieldnames(T)]
    quote
        $T($(entries...))
    end
end

@generated function on_difference(
        callback,
        ::Nothing,
        new_val::T,
        path::Tuple{Vararg{Symbol}}
    ) where T <: ConfigSection
    entries = Expr[
        :(on_difference(
            callback,
            nothing,
            getfield(new_val, $(QuoteNode(fname))),
            (path..., $(QuoteNode(fname)))))
        for fname in fieldnames(T)]
    quote
        $T($(entries...))
    end
end

on_difference(callback, old_val, new_val, path::Tuple{Vararg{Symbol}}) =
    old_val !== new_val ? callback(old_val, new_val, path) : old_val

function parse_config_dict(config_dict::AbstractDict{String}, filepath::Union{Nothing,AbstractString} = nothing)
    try
        return Configurations.from_dict(JETLSConfig, config_dict)
    catch e
        # TODO: remove this when Configurations.jl support to report
        #       full path of unknown key.
        if e isa Configurations.InvalidKeyError
            unknown_keys = collect_unmatched_keys(to_untyped_config_dict(config_dict))
            if !isempty(unknown_keys)
                if isnothing(filepath)
                    return unmatched_keys_in_lsp_config_msg(unknown_keys)
                else
                    return unmatched_keys_in_config_file_msg(filepath, unknown_keys)
                end
            end
        elseif e isa DiagnosticConfigError
            if isnothing(filepath)
                return "Invalid diagnostic configuration: $(e.msg)"
            else
                return """
                Invalid diagnostic configuration in $filepath:
                $(e.msg)
                """
            end
        end
        if isnothing(filepath)
            return "Failed to parse LSP configuration: $(e)"
        else
            return """
            Failed to load configuration file at $filepath:
            $(e)
            """
        end
    end
end

"""
    merge_setting(base::T, overlay::T) where {T<:ConfigSection} -> T

Merges two configuration objects, with `overlay` taking precedence over `base`.
If a field in `overlay` is `nothing`, the corresponding field from `base` is retained.
"""
merge_setting(base::T, overlay::T) where {T<:ConfigSection} =
    on_difference((base_val, overlay_val, _) -> overlay_val === nothing ? base_val : overlay_val, base, overlay)

# TODO: remove this.
#       (now this is used for `collect_unmatched_keys` only. see that's comment)
const UntypedConfigDict = Base.PersistentDict{String, Any}
to_untyped_config_dict(dict::AbstractDict) =
    UntypedConfigDict((k => (v isa AbstractDict ? to_untyped_config_dict(v) : v) for (k, v) in dict)...)

const DEFAULT_UNTYPED_CONFIG_DICT = to_untyped_config_dict(Configurations.to_dict(DEFAULT_CONFIG))

"""
    collect_unmatched_keys(this::UntypedConfigDict, ref::UntypedConfigDict) -> Vector{Vector{String}}

Traverses the keys of `this` and returns a list of key paths that are not present in `ref`.
Note that this function does *not* perform deep structural comparison for keys whose values are dictionaries.

# Examples
```julia-repl
julia> collect_unmatched_keys(
            UntypedConfigDict("key1" => UntypedConfigDict("key2" => 0, "key3"  => 0, "key4"  => 0)),
            UntypedConfigDict("key1" => UntypedConfigDict("key2" => 0, "diff1" => 0, "diff2" => 0))
        )
2-element Vector{Vector{String}}:
 ["key1", "key3"]
 ["key1", "key4"]

julia> collect_unmatched_keys(
            UntypedConfigDict("key1" => 0, "key2" => 0),
            UntypedConfigDict("key1" => 1, "key2" => 1)
        )
Vector{String}[]

julia> collect_unmatched_keys(
           UntypedConfigDict("key1" => UntypedConfigDict("key2" => 0, "key3" => 0)),
           UntypedConfigDict("diff" => UntypedConfigDict("diff" => 0, "key3" => 0))
        )
1-element Vector{Vector{String}}:
 ["key1"]
```

TODO: remove this. This is a temporary workaround to report unknown keys in the config file
      until Configurations.jl supports reporting full path of unknown keys.
"""
function collect_unmatched_keys(this::UntypedConfigDict, ref::UntypedConfigDict=DEFAULT_UNTYPED_CONFIG_DICT)
    unknown_keys = Vector{String}[]
    collect_unmatched_keys!(unknown_keys, this, ref, String[])
    return unknown_keys
end

function collect_unmatched_keys!(
        unknown_keys::Vector{Vector{String}},
        this::UntypedConfigDict, ref::UntypedConfigDict, key_path::Vector{String}
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
    get_config(manager::ConfigManager, key_path...) -> config

Retrieves the current configuration value.
Among the registered configuration files, fetches the value in order of priority.

Even when the specified configuration is not explicitly set, a default value is returned,
so `config` is guaranteed to not be `nothing`.
"""
Base.@constprop :aggressive function get_config(manager::ConfigManager, key_path::Symbol...)
    data = load(manager)
    config = getobjpath(data.filled_settings, key_path...)
    @assert !isnothing(config) "Invalid default configuration values"
    return config
end

function initialize_config!(manager::ConfigManager)
    store!(manager) do old_data::ConfigManagerData
        return ConfigManagerData(old_data; initialized=true), nothing
    end
end

struct ConfigChange
    path::String
    old_val
    new_val
    ConfigChange(path::AbstractString, @nospecialize(old_val), @nospecialize(new_val)) = new(path, old_val, new_val)
end

mutable struct ConfigChangeTracker
    changed_settings::Vector{ConfigChange}
    diagnostic_setting_changed::Bool
end
ConfigChangeTracker() = ConfigChangeTracker(ConfigChange[], false)

function (tracker::ConfigChangeTracker)(old_val, new_val, path::Tuple{Vararg{Symbol}})
    if old_val !== new_val
        path_str = join(path, ".")
        push!(tracker.changed_settings, ConfigChange(path_str, old_val, new_val))
        if !isempty(path) && first(path) === :diagnostic
            tracker.diagnostic_setting_changed = true
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

function notify_config_changes(
        server::Server,
        tracker::ConfigChangeTracker,
        source::AbstractString
    )
    if !isempty(tracker.changed_settings)
        show_info_message(server, """
            Configuration changed.
            Source: $source
            $(changed_settings_message(tracker.changed_settings))
            """)
    end
end

unmatched_keys_msg(header_msg::AbstractString, unmatched_keys) =
    header_msg * "\n" * join(map(x -> string('`', join(x, "."), '`'), unmatched_keys), ", ")
