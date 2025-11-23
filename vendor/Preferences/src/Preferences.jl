module Preferences

if VERSION < v"1.6.0-DEV"
    error("Preferences.jl can only be used on Julia v1.6+!")
end

using TOML
using Base: UUID, TOMLCache

export load_preference, @load_preference,
       has_preference, @has_preference,
       set_preferences!, @set_preferences!,
       delete_preferences!, @delete_preferences!

include("utils.jl")

"""
    load_preference(uuid_or_module_or_name, key, default = nothing)

Load a particular preference from the `Preferences.toml` file, shallowly merging keys
as it walks the hierarchy of load paths, loading preferences from all environments that
list the given UUID as a direct dependency.

Most users should use the `@load_preference` convenience macro which auto-determines the
calling `Module`.
"""
function load_preference end
function load_preference(uuid::UUID, key::String, default = nothing)
    # Re-use definition in `base/loading.jl` so as to not repeat code.
    d = Base.get_preferences(uuid)
    if currently_compiling()
        Base.record_compiletime_preference(uuid, key)
    end
    return drop_clears(get(d, key, default))
end
function load_preference(m::Module, key::String, default = nothing)
    return load_preference(get_uuid(m), key, default)
end
function load_preference(name::String, key::String, default = nothing)
    uuid = get_uuid(name)
    if uuid === nothing
        package_lookup_error(name)
    end
    return load_preference(uuid, key, default)
end

"""
    @load_preference(key)

Convenience macro to call `load_preference()` for the current package.
"""
macro load_preference(key, default = nothing)
    return quote
        load_preference($(esc(get_uuid(__module__))), $(esc(key)), $(esc(default)))
    end
end

"""
    has_preference(uuid_or_module_or_name, key)

Return `true` if the particular preference is found, and `false` otherwise.

See the `has_preference` docstring for more details.
"""
function has_preference end
function has_preference(uuid::UUID, key::String)
    value = load_preference(uuid, key, nothing)
    return !(value isa Nothing)
end
function has_preference(m::Module, key::String)
    return has_preference(get_uuid(m), key)
end
function has_preference(name::String, key::String)
    uuid = get_uuid(name)
    if uuid === nothing
        package_lookup_error(name)
    end
    return has_preference(uuid, key)
end

"""
    @has_preference(key)

Convenience macro to call `has_preference()` for the current package.
"""
macro has_preference(key)
    return quote
        has_preference($(esc(get_uuid(__module__))), $(esc(key)))
    end
end

"""
    process_sentinel_values!(prefs::Dict)

Recursively search for preference values that end in `nothing` or `missing` leaves,
which we handle specially, see the `set_preferences!()` docstring for more detail.
"""
function process_sentinel_values!(prefs::Dict)
    # Need to widen `prefs` so that when we try to assign to `__clear__` below,
    # we don't error due to a too-narrow type on `prefs`
    prefs = Base._typeddict(prefs, Dict{String,Vector{String}}())

    clear_keys = get(prefs, "__clear__", String[])
    for k in collect(keys(prefs))
        if prefs[k] === nothing
            # If this should add `k` to the `__clear__` list, do so, then remove `k`
            push!(clear_keys, k)
            delete!(prefs, k)
        else
            # `k` is not nothing, so drop it from `clear_keys`
            filter!(x -> x != k, clear_keys)
            if prefs[k] === missing
                # If this should clear out the mapping for `k`, do so
                delete!(prefs, k)
            elseif isa(prefs[k], Dict)
                # Recurse for nested dictionaries
                prefs[k] = process_sentinel_values!(prefs[k])
            end
        end
    end
    # Store the updated list of clear_keys
    if !isempty(clear_keys)
        prefs["__clear__"] = collect(Set(clear_keys))
    else
        delete!(prefs, "__clear__")
    end
    return prefs
end

# See the `set_preferences!()` docstring below for more details
function set_preferences!(target_toml::String, pkg_name::String, pairs::Pair{String,<:Any}...; force::Bool = false)
    # Load the old preferences in first, as we'll merge ours into whatever currently exists
    d = Dict{String,Any}()
    if isfile(target_toml)
        d = Base.parsed_toml(target_toml)
    end
    prefs = d
    if endswith(target_toml, "Project.toml")
        if !haskey(prefs, "preferences")
            prefs["preferences"] = Dict{String,Any}()
        end
        # If this is a `(Julia)Project.toml` file, we squirrel everything away under the
        # "preferences" key, while for a `Preferences.toml` file it sits at top-level.
        prefs = prefs["preferences"]
    end
    # Index into our package name
    if !haskey(prefs, pkg_name)
        prefs[pkg_name] = Dict{String,Any}()
    end
    # Set each preference, erroring unless `force` is set to `true`
    for (k, v) in pairs
        if !force && haskey(prefs[pkg_name], k) && (v === missing || prefs[pkg_name][k] != v)
            throw(ArgumentError("Cannot set preference '$(k)' to '$(v)' for $(pkg_name) in $(target_toml): preference already set to '$(prefs[pkg_name][k])'!"))
        end
        prefs[pkg_name][k] = v

        # Recursively scan for `nothing` and `missing` values that we need to handle specially
        prefs[pkg_name] = process_sentinel_values!(prefs[pkg_name])
    end
    open(target_toml, "w") do io
        TOML.print(io, d, sorted=true)
    end
    return nothing
end

"""
    set_preferences!(uuid_or_module_or_name_or_tuple, prefs::Pair{String,Any}...;
                     export_prefs=false, active_project_only=true, force=false)

Sets a series of preferences for the given uuid::UUID/module::Module/name::String/uuid_and_name::Tuple{UUID, String),
identified by the pairs passed in as `prefs`.  Preferences are loaded from `Project.toml`
and `LocalPreferences.toml` files on the load path, merging values together into a cohesive
view, with preferences taking precedence in `LOAD_PATH` order, just as package resolution
does.  Preferences stored in `Project.toml` files are considered "exported", as they are
easily shared across package installs, whereas the `LocalPreferences.toml` file is meant to
represent local preferences that are not typically shared.  `LocalPreferences.toml` settings
override `Project.toml` settings where appropriate.

After running `set_preferences!(uuid, "key" => value)`, a future invocation of
`load_preference(uuid, "key")` will generally result in `value`, with the exception of
the merging performed by `load_preference()` due to inheritance of preferences from
elements higher up in the `load_path()`.  To control this inheritance, there are two
special values that can be passed to `set_preferences!()`: `nothing` and `missing`.

* When only one of module/name/UUID are passed, the missing information is extracted from the current project, and therefore it must be installed.
  On the other hand, the (UUID, name) tuple form can be used to set preferences on a package that is not yet installed in the active project.
  It will be added as extra dependency during the process.
* Passing `missing` as the value causes all mappings of the associated key to be removed
  from the current level of `LocalPreferences.toml` settings, allowing preferences set
  higher in the chain of preferences to pass through.  Use this value when you want to
  clear your settings but still inherit any higher settings for this key.

* Passing `nothing` as the value causes all mappings of the associated key to be removed
  from the current level of `LocalPreferences.toml` settings and blocks preferences set
  higher in the chain of preferences from passing through.  Internally, this adds the
  preference key to a `__clear__` list in the `LocalPreferences.toml` file, that will
  prevent any preferences from leaking through from higher environments.

Note that the behaviors of `missing` and `nothing` are both similar (they both clear the
current settings) and diametrically opposed (one allows inheritance of preferences, the
other does not).  They can also be composed with a normal `set_preferences!()` call:

```julia
@set_preferences!("compiler_options" => nothing)
@set_preferences!("compiler_options" => Dict("CXXFLAGS" => "-g", LDFLAGS => "-ljulia"))
```

The above snippet first clears the `"compiler_options"` key of any inheriting influence,
then sets a preference option, which guarantees that future loading of that preference
will be exactly what was saved here.  If we wanted to re-enable inheritance from higher
up in the chain, we could do the same but passing `missing` first.

The `export_prefs` option determines whether the preferences being set should be stored
within `LocalPreferences.toml` or `Project.toml`.

The `active_project_only` flag ensures that the preference is set within the currently
active project (as determined by `Base.active_project()`), and if the target package is
not listed as a dependency, it is added under the `extras` section.  Without this flag
set, if the target package is not found in the active project, `set_preferences!()` will
search up the load path for an environment that does contain that module, setting the
preference in the first one it finds.  If none are found, it falls back to setting the
preference in the active project and adding it as an extra dependency.
"""
function set_preferences! end

function _get_project_toml(u, active_project_only)
    if active_project_only
        project_toml = Base.active_project()
    else
        project_toml, pkg_name = find_first_project_with_uuid(u)
        if project_toml === nothing && pkg_name === nothing
            project_toml = Base.active_project()
        end
    end

    # X-ref: https://github.com/JuliaPackaging/Preferences.jl/issues/34
    # We need to handle the edge cases where `project_toml` doesn't exist yet
    if !isfile(project_toml)
        touch(project_toml)
    end
    return project_toml
end

function set_preferences!((u, pkg_name)::Tuple{UUID, String},
                          prefs::Pair{String,<:Any}...;
                          export_prefs=false,
                          active_project_only::Bool=true,
                          project_toml=nothing,
                          kwargs...)
    if project_toml === nothing
        project_toml = _get_project_toml(u, active_project_only)
    end
    # If we try to add preferences for a dependency, we need to make sure
    # it is listed as a dependency, so if it's not, we'll add it in the
    # "extras" section in the `Project.toml`.
    function ensure_dep_added(project_toml, uuid, pkg_name)
        # If this project already has a mapping for this UUID, early-exit
        if Base.get_uuid_name(project_toml, uuid) !== nothing
            return
        end

        # Otherwise, insert it into `extras`, creating the section if
        # it doesn't already exist.
        project = Base.parsed_toml(project_toml)
        if !haskey(project, "extras")
            project["extras"] = Dict{String,Any}()
        end
        project["extras"][pkg_name] = string(u)
        open(project_toml, "w") do io
            TOML.print(io, project; sorted=true)
        end
        return project_toml, pkg_name
    end

    ensure_dep_added(project_toml, u, pkg_name)

    # Finally, save the preferences out to either `Project.toml` or
    # `(Julia)LocalPreferences.toml` keyed under that `pkg_name`:
    target_toml = project_toml
    if !export_prefs
        # We'll default to calling it `LocalPreferneces.toml`
        target_toml = joinpath(dirname(project_toml), "LocalPreferences.toml")

        # But if there's already a `JuliaLocalPreferneces.toml`, use that.
        for pref_name in Base.preferences_names
            maybe_file = joinpath(dirname(project_toml), pref_name)
            if isfile(maybe_file)
                target_toml = maybe_file
            end
        end
    end
    return set_preferences!(target_toml, pkg_name, prefs...; kwargs...)
end
function set_preferences!(u::UUID, prefs::Pair{String,<:Any}...;
                          export_prefs=false,
                          active_project_only::Bool=true,
                          project_toml=_get_project_toml(u, active_project_only),
                          kwargs...)

    # Get the pkg name from the current environment if we can't find a
    # mapping for it in any environment block.  This assumes that the name
    # mapping should be the same as what was used in when it was loaded.
    function get_pkg_name_from_env()
        pkg_uuid_matches = filter(d -> d.uuid == u, keys(Base.loaded_modules))
        if isempty(pkg_uuid_matches)
            return nothing
        end
        return first(pkg_uuid_matches).name
    end
    pkg_name = something(
        Base.get_uuid_name(project_toml, u),
        get_pkg_name_from_env(),
        Some(nothing),
    )
    # This only occurs if we couldn't find any hint of the given pkg
    if pkg_name === nothing
        error(
            "Cannot set preferences of an unknown package that is not loaded! " *
            "(Hint: You can set the preference if you pass the name and UUID as a tuple.)"
        )
    end
    set_preferences!((u, pkg_name), prefs...;
                     export_prefs=export_prefs,
                     active_project_only=active_project_only,
                     project_toml=project_toml,
                     kwargs...)
end
function set_preferences!(m::Module, prefs::Pair{String,<:Any}...; kwargs...)
    return set_preferences!(get_uuid(m), prefs...; kwargs...)
end
function set_preferences!(name::String, prefs::Pair{String,<:Any}...; kwargs...)
    # Look up UUID
    uuid = get_uuid(name)
    if uuid === nothing
        throw(ArgumentError("Cannot resolve package '$(name)' in load path; have you added the package as a top-level dependency?"))
    end
    return set_preferences!(uuid, prefs...; kwargs...)
end

"""
    @set_preferences!(prefs...)

Convenience macro to call `set_preferences!()` for the current package.  Defaults to
setting `force=true`, since a package should have full control over itself, but not
so for setting the preferences in other packages, pending private dependencies.
"""
macro set_preferences!(prefs...)
    return quote
        set_preferences!($(esc(get_uuid(__module__))), $(map(esc,prefs)...), force=true)
    end
end

"""
    delete_preferences!(uuid_or_module_or_name, prefs::String...;
                        block_inheritance::Bool = false, export_prefs=false, force=false)

Deletes a series of preferences for the given uuid::UUID/module::Module/name::String,
identified by the keys passed in as `prefs`.

See the docstring for [`set_preferences!`](@ref) for more details.
"""
function delete_preferences!(u::UUID, pref_keys::String...; block_inheritance::Bool = false, kwargs...)
    if block_inheritance
        return set_preferences!(u::UUID, [k => nothing for k in pref_keys]...; kwargs...)
    else
        return set_preferences!(u::UUID, [k => missing for k in pref_keys]...; kwargs...)
    end
end
function delete_preferences!(m::Module, pref_keys::String...; kwargs...)
    return delete_preferences!(get_uuid(m), pref_keys...; kwargs...)
end
function delete_preferences!(name::String, pref_keys::String...; kwargs...)
    uuid = get_uuid(name)
    if uuid === nothing
        package_lookup_error(name)
    end
    return delete_preferences!(uuid, pref_keys...; kwargs...)
end

"""
    @delete_preferences!(prefs...)

Convenience macro to call `delete_preferences!()` for the current package.  Defaults to
setting `force=true`, since a package should have full control over itself, but not
so for deleting the preferences in other packages, pending private dependencies.
"""
macro delete_preferences!(prefs...)
    return quote
        delete_preferences!($(esc(get_uuid(__module__))), $(map(esc,prefs)...), force=true)
    end
end

# Precompilation to reduce latency (https://github.com/JuliaLang/julia/pull/43990#issuecomment-1025692379)
get_uuid(Preferences)
currently_compiling()
precompile(Tuple{typeof(drop_clears), Any})
if hasmethod(Base.BinaryPlatforms.Platform, (String, String, Dict{String}))
    precompile(load_preference, (Base.UUID, String, Nothing))
end

end # module Preferences
