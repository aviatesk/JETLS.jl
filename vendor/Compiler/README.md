# The `Compiler` standard library

The `Compiler` standard library module provides an interface to Julia's internal compiler APIs.

This repository manages the special v0.1 release of the `Compiler` stdlib.
This version is a placeholder implementation that re‐exports the `Base.Compiler` module
under the `Compiler` name.
In other words, installing `Compiler` v0.1 gives you the same compiler implementation
bundled with Julia runtime (`Base.Compiler`).

The reason for providing this placeholder version is to minimize compatibility issues
between the `Compiler` standard library, the Julia runtime system, and dependent packages
until proper versioning for the `Compiler` stdlib is in place.
I.e. as long as you use `Compiler` v0.1, its implementation is identical to `Base.Compiler`,
so you don’t need to worry about compatibility gaps with the Julia runtime.

Using this `Compiler` stdlib instead of the bundled `Base.Compiler` module lets you switch
compiler implementations natively via the Julia package system.

For the actual compiler implementation,
see the [`/Compiler`](https://github.com/JuliaLang/julia/tree/master/Compiler) directory
in the [JuliaLang/julia](https://github.com/JuliaLang/julia) repository.

## How to use

To utilize this `Compiler.jl` standard library, you need to declare it as a dependency in
your `Project.toml` as follows:
> Project.toml
```toml
[deps]
Compiler = "807dbc54-b67e-4c79-8afb-eafe4df6f2e1"

[compat]
Compiler = "0.1"
```

With the setup above, the placeholder version of `Compiler` (v0.1) will be installed by default.[^1]

[^1]: Currently, only version v0.1 series is registered in the [General](https://github.com/JuliaRegistries/General) registry.

If needed, you can switch to a custom implementation of the `Compiler` module by running
```julia-repl
pkg> dev /path/to/Compiler.jl # to use a local implementation
```
or
```julia-repl
pkg> add https://url/of/Compiler/branch # to use a remote implementation
```
This feature is particularly useful for developing or experimenting with alternative compiler implementations.

> [!note]
> The Compiler.jl standard library is available starting from Julia v1.10.
> However, switching to a custom compiler implementation is supported only from
> Julia v1.12 onwards.

> [!warning]
> When using a custom, non-`Base` version of `Compiler` implementation, it may be necessary
> to run `InteractiveUtils.@activate Compiler` to ensure proper functionality of certain
> reflection utilities.
