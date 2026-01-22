is_config_file(filepath::AbstractString) =
    basename(filepath) == ".JETLSConfig.toml"

@generated function merge_and_track(
        on_difference,
        old_config::T,
        new_config::T,
        path::Tuple{Vararg{Symbol}}
    ) where {T<:ConfigSection}
    entries = Expr[
        :(merge_and_track(
            on_difference,
            getfield(old_config, $(QuoteNode(fname))),
            getfield(new_config, $(QuoteNode(fname))),
            (path..., $(QuoteNode(fname)))))
        for fname in fieldnames(T)]
    :(T($(entries...)))
end

function merge_and_track(
        on_difference,
        old_config::Vector{T},
        new_config::Vector{T},
        path::Tuple{Vararg{Symbol}}
    ) where {T<:ConfigSection}
    key = merge_key(T)
    K = fieldtype(T, key)
    old_by_key = Dict{K,T}(getfield(item, key) => item for item in old_config)
    new_by_key = Dict{K,T}(getfield(item, key) => item for item in new_config)
    result = T[]
    for (k, old_item) in old_by_key
        if haskey(new_by_key, k)
            push!(result, merge_and_track(on_difference, old_item, new_by_key[k], path))
        else
            push!(result, merge_and_track(on_difference, old_item, nothing, path))
        end
    end
    for (k, new_item) in new_by_key
        if !haskey(old_by_key, k)
            push!(result, merge_and_track(on_difference, nothing, new_item, path))
        end
    end
    return result
end

function merge_and_track(
        on_difference,
        old_config::Vector{T},
        ::Nothing,
        path::Tuple{Vararg{Symbol}}
    ) where {T<:ConfigSection}
    for old_item in old_config
        merge_and_track(on_difference, old_item, nothing, path)
    end
    return old_config
end

function merge_and_track(
        on_difference,
        ::Nothing,
        new_config::Vector{T},
        path::Tuple{Vararg{Symbol}}
    ) where {T<:ConfigSection}
    return T[merge_and_track(on_difference, nothing, new_item, path) for new_item in new_config]
end

@generated function merge_and_track(
        on_difference,
        old_val::T,
        ::Nothing,
        path::Tuple{Vararg{Symbol}}
    ) where T <: ConfigSection
    entries = Expr[
        :(merge_and_track(
            on_difference,
            getfield(old_val, $(QuoteNode(fname))),
            nothing,
            (path..., $(QuoteNode(fname)))))
        for fname in fieldnames(T)]
    :(T($(entries...)))
end

@generated function merge_and_track(
        on_difference,
        ::Nothing,
        new_val::T,
        path::Tuple{Vararg{Symbol}}
    ) where T <: ConfigSection
    entries = Expr[
        :(merge_and_track(
            on_difference,
            nothing,
            getfield(new_val, $(QuoteNode(fname))),
            (path..., $(QuoteNode(fname)))))
        for fname in fieldnames(T)]
    :(T($(entries...)))
end

function merge_and_track(on_difference, old_val, new_val, path::Tuple{Vararg{Symbol}})
    old_val !== new_val && on_difference(old_val, new_val, path)
    return new_val === nothing ? old_val : new_val
end

"""
    track_setting_changes(on_difference, old_config, new_config) -> merged_config

Recursively compares two configuration objects and invokes `on_difference(old_val, new_val, path)`
for each leaf value that differs.
"""
track_setting_changes(on_difference, old_val, new_val) =
    merge_and_track(on_difference, old_val, new_val, ())

"""
    merge_settings(base::JETLSConfig, overlay::JETLSConfig)

Merges two configuration objects, with `overlay` taking precedence over `base`.
If a field in `overlay` is `nothing`, the corresponding field from `base` is retained.
"""
merge_settings(base::JETLSConfig, overlay::JETLSConfig) =
    merge_and_track(Returns(nothing), base, overlay, ())

# TODO: Remove this. Now this is used for `collect_unmatched_keys` only. See the comment there.
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

TODO: Remove this. This is a temporary workaround to report unknown keys in the config file
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
    get_config(server::Server, key_path...) -> config
    get_config(state::ServerState, key_path...) -> config
    get_config(manager::ConfigManager, key_path...) -> config

Retrieves the current configuration value.
Among the registered configuration files, fetches the value in order of priority.

Even when the specified configuration is not explicitly set, a default value is returned,
so `config` is guaranteed to not be `nothing`.
"""
Base.@constprop :aggressive get_config(server::Server, key_path::Symbol...) = get_config(server.state, key_path...)
Base.@constprop :aggressive get_config(state::ServerState, key_path::Symbol...) = get_config(state.config_manager, key_path...)
Base.@constprop :aggressive get_config(manager::ConfigManager, key_path::Symbol...) =
    @something getobjpath(load(manager).filled_settings, key_path...) error(lazy"Invalid default configuration value found at $key_path")

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
    const changed_settings::Vector{ConfigChange}
    diagnostic_setting_changed::Bool
end
ConfigChangeTracker() = ConfigChangeTracker(ConfigChange[], false)

function (tracker::ConfigChangeTracker)(old_val, new_val, path::Tuple{Vararg{Symbol}})
    @nospecialize old_val new_val
    if old_val !== new_val
        path_str = join(path, ".")
        push!(tracker.changed_settings, ConfigChange(path_str, old_val, new_val))
        if !isempty(path) && first(path) === :diagnostic
            tracker.diagnostic_setting_changed = true
        end
    end
end

function changed_settings_message(changed_settings::Vector{ConfigChange})
    applied = String[]
    pending_restart = String[]
    for config_change in changed_settings
        old_repr = repr(config_change.old_val)
        new_repr = repr(config_change.new_val)
        entry = "`$(config_change.path)` (`$old_repr` => `$new_repr`)"
        if startswith(config_change.path, "initialization_options")
            push!(pending_restart, entry)
        else
            push!(applied, entry)
        end
    end
    parts = String[]
    if !isempty(applied)
        push!(parts, "Changes applied: " * join(applied, ", "))
    end
    if !isempty(pending_restart)
        push!(parts, "Changes pending server restart: " * join(pending_restart, ", "))
    end
    return join(parts, ".\n")
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
