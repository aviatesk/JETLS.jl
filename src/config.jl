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
    old_by_key = Dict(merge_key_value(item) => item for item in old_config)
    new_by_key = Dict(merge_key_value(item) => item for item in new_config)
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
    if old_val === missing
        changed = new_val !== missing
    elseif new_val === missing
        changed = true
    else
        changed = (old_val != new_val)::Bool
    end
    changed && on_difference(old_val, new_val, path)
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

"""
    InvalidKeyError(path, expected_keys)

Thrown by [`parse_config_from_dict`](@ref) when a config dict contains a key that does not
match any field of the target [`ConfigSection`](@ref). `path` is the dotted key path to the
offending entry (e.g. `["diagnostic", "patterns"]`); `expected_keys` is the list of
field names of the target type at that path.
"""
struct InvalidKeyError <: Exception
    path::Vector{String}
    expected_keys::Vector{String}
end
function Base.showerror(io::IO, e::InvalidKeyError)
    print(io, "InvalidKeyError: invalid key `", join(e.path, "."), "`",
          ", expected one of: ", join((string('`', k, '`') for k in e.expected_keys), ", "))
end

"""
    parse_config_from_dict(::Type{T}, d::AbstractDict{String}, path=String[])
        where T<:ConfigSection -> T

Recursively populate a [`ConfigSection`](@ref) struct from a config dict (typically
parsed from `.JETLSConfig.toml` or `workspace/configuration`). Throws
[`InvalidKeyError`](@ref) — carrying the full dotted path — on unknown keys; missing
fields keep the struct's `@kwdef` defaults. `path` is threaded through nested calls
so any error surfaced downstream knows where in the dict it originated; callers
typically leave it at the default.
"""
function parse_config_from_dict(
        ::Type{T}, d::AbstractDict{String}, path::Vector{String} = String[]
    ) where T<:ConfigSection
    valid_keys = String[String(name) for name in fieldnames(T)]
    for key::String in keys(d)
        key in valid_keys || throw(InvalidKeyError(String[path; key], valid_keys))
    end
    kwargs = Pair{Symbol,Any}[]
    for fname in fieldnames(T)
        sname = String(fname)
        haskey(d, sname) || continue
        v = parse_config_dict_value(fieldtype(T, fname), d[sname], String[path; sname])
        push!(kwargs, fname => v)
    end
    return T(; kwargs...)
end

# Format an error message rooted at `path` (or unrooted at the top level). Messages
# share the capital-prefix convention with `DiagnosticConfigError` thrown from
# `parse_diagnostic_pattern` / `parse_analysis_override`.
function parse_dict_error(path::Vector{String}, msg::AbstractString)
    if isempty(path)
        error(uppercasefirst(msg))
    else
        error("Invalid value at `", join(path, "."), "`: ", msg)
    end
end

# Drives `parse_config_from_dict`'s field-by-field hydration: turns the raw dict value `x`
# into the field's declared type `T`. Handles the small type tree we actually use — Maybe,
# nested `ConfigSection`, vectors of `ConfigSection`, the formatter union, and plain
# `convert`-able leaves. `DiagnosticPattern` / `AnalysisOverride` need bespoke validation
# and are inlined here for the same reason `Maybe{FormatterConfig}` is — the set of special
# cases is small and closed, so a dispatch hook would be over-built.
function parse_config_dict_value(
        T::Type, @nospecialize(x), path::Vector{String} = String[]
    )
    x === nothing && Nothing <: T && return nothing
    if T isa Union
        non_nothing = Type[U for U in Base.uniontypes(T) if U !== Nothing]
        if length(non_nothing) == 1
            # `Maybe{T}` for a single concrete `T` — dispatch directly so inner errors
            # (e.g. `DiagnosticConfigError`, `InvalidKeyError`) bubble up unswallowed.
            return parse_config_dict_value(non_nothing[1], x, path)
        end
        # `Maybe{FormatterConfig}` is the only union we parse from a dict that mixes a plain
        # string and an alias-tagged option type. Hard-code it rather than building a
        # general alias dispatch.
        if String <: T && CustomFormatterConfig <: T
            if x isa AbstractString
                return convert(String, x)
            elseif x isa AbstractDict{String}
                haskey(x, CUSTOM_FORMATTER_ALIAS) ||
                    parse_dict_error(path, "expected formatter table key `$(CUSTOM_FORMATTER_ALIAS)`, got keys $(collect(keys(x)))")
                return parse_config_from_dict(
                    CustomFormatterConfig, x[CUSTOM_FORMATTER_ALIAS], String[path; CUSTOM_FORMATTER_ALIAS])
            else
                parse_dict_error(path, "expected formatter string or table, got $(typeof(x))")
            end
        end
        # Generic multi-type union (e.g. `Maybe{Union{Missing,Bool}}`): try each
        # non-`Nothing` branch in order; the first one that converts wins.
        for U in non_nothing
            try
                return parse_config_dict_value(U, x, path)
            catch
                continue
            end
        end
        parse_dict_error(path, "expected $T, got $(typeof(x))")
    end
    if T <: ConfigSection
        x isa AbstractDict{String} || parse_dict_error(path, "expected a table for $T, got $(typeof(x))")
        T === DiagnosticPattern && return parse_diagnostic_pattern(x)
        T === AnalysisOverride && return parse_analysis_override(x)
        return parse_config_from_dict(T, x, path)
    end
    if T <: AbstractVector
        x isa AbstractVector || parse_dict_error(path, "expected an array for $T, got $(typeof(x))")
        E = eltype(T)
        return E[parse_config_dict_value(E, e, path) for e in x]
    end
    try
        return convert(T, x)
    catch e
        e isa MethodError || rethrow(e)
        parse_dict_error(path, "expected $T, got $(typeof(x))")
    end
end

"""
    parse_config_dict(config_dict::AbstractDict{String}, filepath=nothing)
        -> Union{JETLSConfig,String}

Parse a raw `JETLSConfig` dict from `workspace/configuration` (`filepath=nothing`)
or `.JETLSConfig.toml` (`filepath` set). Returns the parsed config on success, or a
user-facing error message string on failure — covering unknown keys (with the full
dotted path), invalid `[diagnostic]` patterns, and any other parse error.
"""
function parse_config_dict(
        config_dict::AbstractDict{String}, filepath::Union{Nothing,AbstractString} = nothing
    )
    try
        return parse_config_from_dict(JETLSConfig, config_dict)
    catch e
        if e isa InvalidKeyError
            if isnothing(filepath)
                return unmatched_key_in_lsp_config_msg(e.path)
            else
                return unmatched_key_in_config_file_msg(filepath, e.path)
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

unmatched_key_msg(header_msg::AbstractString, path::Vector{String}) =
    string(header_msg, "\n`", join(path, "."), "`")

# Rewrite raw user config dicts so deprecated key paths land at their new
# location before `parse_config_from_dict` sees them. Returns a list of
# user-facing warnings — one per deprecation actually present.
#
# The struct schema only knows the current key paths, so callers must invoke
# this *before* parsing. Already-migrated values win over the legacy alias.
function migrate_deprecated_config_keys!(
        config_dict::AbstractDict,
        deprecated_configs::Vector{Pair{Vector{String},Union{Nothing,Vector{String}}}} = deprecated_configurations
    )
    warnings = String[]
    for (old_path, new_path) in deprecated_configs
        popped = @something pop_nested!(config_dict, old_path) continue
        old_value = something(popped)
        if new_path === nothing
            push!(warnings,
                "`" * join(old_path, ".") * "` is deprecated and no longer has " *
                "any effect; please remove it from your config.")
        else
            new_parent = ensure_nested_dict!(config_dict, @view new_path[1:end-1])
            if new_parent !== nothing && !haskey(new_parent, new_path[end])
                new_parent[new_path[end]] = old_value
            end
            push!(warnings,
                "`" * join(old_path, ".") * "` is deprecated; " *
                "use `" * join(new_path, ".") * "` instead.")
        end
    end
    return warnings
end

# Follow `path` into `d`; return the dict at the end, or `nothing` if any step
# is missing or non-dict-shaped.
function walk_nested_dict(d::AbstractDict, path)
    for k in path
        d = get(d, k, nothing)
        d isa AbstractDict || return nothing
    end
    return d
end

# Pop `path[end]` from the nested location in `d`. Empty parent dicts along the
# walk are pruned bottom-up so the schema doesn't reject leftover table headers
# (e.g. an empty `[completion.method_signature]` after removing its only key).
# Returns `Some(value)` on success, or `nothing` if any step is missing.
function pop_nested!(d::AbstractDict, path)
    isempty(path) && return nothing
    if length(path) == 1
        return haskey(d, path[1]) ? Some(pop!(d, path[1])) : nothing
    end
    child = get(d, path[1], nothing)
    child isa AbstractDict || return nothing
    result = pop_nested!(child, @view path[2:end])
    isempty(child) && pop!(d, path[1])
    return result
end

# Like `walk_nested_dict` but creates missing intermediate dicts.
# Returns `nothing` only if a non-dict value blocks the path.
function ensure_nested_dict!(d::AbstractDict, path)
    for k in path
        d = get!(() -> Dict{String,Any}(), d, k)
        d isa AbstractDict || return nothing
    end
    return d
end
