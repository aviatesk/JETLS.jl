# Helper function to detect if we're currently compiling
currently_compiling() = ccall(:jl_generating_output, Cint, ()) != 0

@doc """
    Preferences.main_uuid::Ref{Union{Nothing,UUID}}

If this global variable is set to `UUID` object, Preferences.jl will use it as a temporary
package UUID for the `Main` module and its children modules.
This allows us to use the configurations for a package for non-package modules,
and may be useful for debugging or analyzing a package code.

```julia
julia> using Preferences, Pkg, PrecompileTools

julia> try
           # Run the package code of XXX.jl as a top-level script and check
           # what gets precompiled while loading the configurations for XXX.jl:
           Preferences.main_uuid[] = Pkg.project().dependencies["XXX"]
           PrecompileTools.verbose[] = true
           include("src/XXX.jl")
       finally
           Preferences.main_uuid[] = nothing
           PrecompileTools.verbose[] = false
       end
```

!!! warning
    Improper manipulation on this variable may cause unexpected behaviors.
    Use with care and only as a last resort if absolutely required.
"""
const main_uuid = Ref{Union{Nothing,UUID}}(nothing)

const uuid_cache = Dict{Module,UUID}()

# Helper function to get the UUID of a module, throwing an error if it can't.
function get_uuid(m::Module)
    if haskey(uuid_cache, m)
        return uuid_cache[m]
    elseif parentmodule(m) !== m
        # traverse up the module hierarchy while caching the results
        return uuid_cache[m] = get_uuid(parentmodule(m))
    elseif m === Main && main_uuid[] !== nothing
        # load a specified package configuration for running script
        return main_uuid[]::UUID
    else
        # get package UUID
        uuid = Base.PkgId(m).uuid
        if uuid === nothing
            throw(ArgumentError("Module $(m) does not correspond to a loaded package!"))
        end
        return uuid_cache[m] = uuid
    end
end

function load_path_walk(f::Function)
    for env in Base.load_path()
        project_toml = Base.env_project_file(env)
        if !isa(project_toml, String)
            continue
        end

        ret = f(project_toml)
        if ret !== nothing
            return ret
        end
    end
    return nothing
end

function get_uuid(name::String)
    return load_path_walk() do project_toml
        project = Base.parsed_toml(project_toml)
        if haskey(project, "uuid") && get(project, "name", "") == name
            return parse(Base.UUID, project["uuid"]::String)
        end
        for sect in ["deps", "extras"]
            if haskey(project, sect)
                deps = project[sect]::Dict{String,Any}
                if haskey(deps, name)
                    return parse(Base.UUID, deps[name]::String)
                end
            end
        end
        return nothing
   end
end

package_lookup_error(name::String) = throw(ArgumentError(
    "Cannot resolve package '$(name)' in load path; have you added the package as a top-level dependency?"))

function find_first_project_with_uuid(uuid::UUID)
    # Find first element in `Base.load_path()` that contains this UUID
    # This code should look similar to the search in `Base.get_preferences()`
    return load_path_walk() do project_toml
        # Check to see if this project has a name mapping
        pkg_name = Base.get_uuid_name(project_toml, uuid)
        if pkg_name !== nothing
            return (project_toml, pkg_name)
        end
        return nothing
    end
end

# Drop any nested `__clear__` keys:
function drop_clears(@nospecialize(data))
    if isa(data, Dict{String,Any})
        delete!(data, "__clear__")
        for (_, v) in data
            drop_clears(v)
        end
    end
    return data
end
