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

"""
    notice_difference(on_difference::Function, base::T, overlay::T) -> T

"""
@generated function notice_difference(on_difference::Function, base::T, overlay::T,
    path::Vector{Symbol}=Symbol[]) where T
    exprs = Expr[]
    for field in fieldnames(T)
        field_type = fieldtype(T, field)
        is_leaf = is_leaf_setting(T, field)
        comparison = quote
            base_val = getfield(base, $(QuoteNode(field)))
            overlay_val = getfield(overlay, $(QuoteNode(field)))
            if base_val != overlay_val
                if $is_leaf
                    on_difference(($(QuoteNode(field)),), overlay_val)
                else
                    notice_difference(on_difference, base_val, overlay_val, [path; $(QuoteNode(field))])
                end
            end
        end
        push!(exprs, comparison)
    end
    return quote
        $(exprs...)
        return overlay
    end
end

function get_settings(data::ConfigManagerData)
    result = ConfigDict()
    for config in Iterators.reverse(values(data.watched_files))
        result = merge_settings(result, config)
    end
    return result
end

function get_static_settings(data::ConfigManagerData)
    result = ConfigDict()
    for config in Iterators.reverse(values(data.watched_files))
        result = merge_static_settings(result, config)
    end
    return result
end


"""
    get_config(manager::ConfigManager, key_path...)

Retrieves the current configuration value.
Among the registered configuration files, fetches the value in order of priority (see `Base.lt(::ConfigFileOrder, path1, path2)`).
If the key path does not exist in any of the configurations, returns `nothing`.
"""
function get_config(manager::ConfigManager, key_path::Symbol...)
    is_static_setting(JETLSConfig, key_path...) &&
        return getobjpath(load(manager).static_settings, key_path...)
    for config in values(load(manager).watched_files)
        return @something getobjpath(config, key_path...) continue
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
        merged_config::JETLSConfig = Configurations.from_dict(JETLSConfig, merged_config)
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
