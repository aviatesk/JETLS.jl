# Preferences.jl

[![Docs-stable](https://img.shields.io/badge/docs-stable-blue.svg)](https://juliapackaging.github.io/Preferences.jl/stable)
[![Docs-dev](https://img.shields.io/badge/docs-dev-blue.svg)](https://juliapackaging.github.io/Preferences.jl/dev)
[![Continuous Integration](https://github.com/JuliaPackaging/Preferences.jl/workflows/CI/badge.svg)](https://github.com/JuliaPackaging/Preferences.jl/actions?query=workflow%3ACI)
[![Code Coverage](https://codecov.io/gh/JuliaPackaging/Preferences.jl/branch/master/graph/badge.svg)](https://codecov.io/gh/JuliaPackaging/Preferences.jl)
[![License: MIT](https://img.shields.io/badge/License-MIT-success.svg)](https://opensource.org/licenses/MIT)

The `Preferences` package provides a convenient, integrated way for packages to store configuration switches to persistent TOML files, and use those pieces of information at both run time and compile time in Julia v1.6+.
This enables the user to modify the behavior of a package, and have that choice reflected in everything from run time algorithm choice to code generation at compile time.
Preferences are stored as TOML dictionaries and are, by default, stored within a `(Julia)LocalPreferences.toml` file next to the currently-active project.
If a preference is "exported" (`export_prefs=true`), it is instead stored within the `(Julia)Project.toml`.
The intention is to allow shared projects to contain shared preferences, while allowing for users themselves to override those preferences with their own settings in the `LocalPreferences.toml` file, which should be `.gitignore`d as the name implies.

Preferences can be set with depot-wide defaults; if package `Foo` is installed within your global environment and it has preferences set, these preferences will apply as long as your global environment is part of your [`LOAD_PATH`](https://docs.julialang.org/en/v1/manual/code-loading/#Environment-stacks).
Preferences in environments higher up in the environment stack get overridden by the more proximal entries in the load path, ending with the currently active project.
This allows depot-wide preference defaults to exist, with active projects able to merge or even completely overwrite these inherited preferences.
See the docstring for `set_preferences!()` for the full details of how to set preferences to allow or disallow merging.

Preferences that are accessed during compilation are automatically marked as compile-time preferences, and any change recorded to these preferences will cause the Julia compiler to recompile any cached precompilation `.ji` files for that module.
This allows preferences to be used to influence code generation.
When your package sets a compile-time preference, it is usually best to suggest to the user that they should restart Julia, to allow recompilation to occur.

Note that the package can be installed on Julia v1.0+ but is only functional on Julia v1.6+.

## API

Preferences use is very simple; it is all based around four functions (which each have convenience macros): `@set_preferences!()`, `@load_preference()`, `@has_preference()`, and `@delete_preferences!()`.

* `@load_preference(key, default = nothing)`: This loads a preference named `key` for the current package.  If no such preference is found, it returns `default`.

* `@set_preferences!(pairs...; export_prefs=false)`: This allows setting multiple preferences at once as pairs.

* `@has_preference(key)`: Returns true if the preference named `key` is found, and `false` otherwise.

* `@delete_preferences!(keys...)`: Delete one or more preferences.

To illustrate the usage, we show a toy module, taken directly from this package's tests:

```julia
module UsesPreferences

function set_backend(new_backend::String)
    if !(new_backend in ("OpenCL", "CUDA", "jlFPGA"))
        throw(ArgumentError("Invalid backend: \"$(new_backend)\""))
    end

    # Set it in our runtime values, as well as saving it to disk
    @set_preferences!("backend" => new_backend)
    @info("New backend set; restart your Julia session for this change to take effect!")
end

const backend = @load_preference("backend", "OpenCL")

# An example that helps us to prove that things are happening at compile-time
function do_computation()
    @static if backend == "OpenCL"
        return "OpenCL is the best!"
    elseif backend == "CUDA"
        return "CUDA; so fast, so fresh!"
    elseif backend == "jlFPGA"
        return "The Future is Now, jlFPGA online!"
    else
        return nothing
    end
end


# A non-compiletime preference
function set_username(username::String)
    @set_preferences!("username" => username)
end
function get_username()
    return @load_preference("username")
end

end # module UsesPreferences
```

## Conditional Loading

To use `Preferences` with Julia 1.6 and later but falling back to a
default value for older Julia versions, you can conditionally load
`Preferences` like this:
```
@static if VERSION >= v"1.6"
    using Preferences
end

@static if VERSION >= v"1.6"
    preference = @load_preference("preference", "default")
else
    preference = "default"
end
```
Note that these cannot be merged into a single `@static if`. Loading
the package with `using Preferences` must be done on its own.

## Authors
This repository was initiated by Elliot Saba
([@staticfloat](https://github.com/staticfloat)) and continues to be maintained by him and
other contributors.

## License and contributing
Preferences.jl is licensed under the MIT license (see [LICENSE.md](LICENSE.md)).
Contributions by volunteers are welcome!
