# Configurations

[![CI](https://github.com/Roger-luo/Configurations.jl/workflows/CI/badge.svg)](https://github.com/Roger-luo/Configurations.jl/actions)
[![codecov](https://codecov.io/gh/Roger-luo/Configurations.jl/branch/master/graph/badge.svg?token=U604BQGRV1)](https://codecov.io/gh/Roger-luo/Configurations.jl)

Configurations & Options made easy.

## Installation

```@raw html
<p>
Configurations is a &nbsp;
    <a href="https://julialang.org">
        <img src="https://raw.githubusercontent.com/JuliaLang/julia-logo-graphics/master/images/julia.ico" width="16em">
        Julia Language
    </a>
    &nbsp; package. To install Configurations,
    please <a href="https://docs.julialang.org/en/v1/manual/getting-started/">open
    Julia's interactive session (known as REPL)</a> and press <kbd>]</kbd> key in the REPL to use the package mode, then type the following command
</p>
```

```julia
pkg> add Configurations
```

## Usage

This package provides a macro `@option` to let you define `struct`s to represent options/configurations, and serialize between different option/configuration file format.

```@docs
@option
```

## Frequently Asked Questions

- *When should I use this package?*
When you have a lot settings/preferences/keyword arguments for a package or a function, or you need
to validate a JSON schema, a REST API for your web server. A similar package in Python is
[pydantic](https://pydantic-docs.helpmanual.io/) in Python, but this package only provides the basic feature, a pydantic compatible package will be developed in the future in [KungIChi](https://github.com/Roger-luo/KungIChi.jl).

A common type of code is instead of writing many keyword arguments, like `foo(;kw_a=1, kw_b=2, kw_c, ...)`,
wrap them in an option type

```julia
@option struct FooOptions
    kw_a::Int = 1
    kw_b::Int = 2
    # ...
end

foo(x, y;kw...) = foo(x, y, FooOptions(;kw...))
foo(x, y, options::FooOptions) = #= actual implementation =#
```

this will make your keyword argument easy to read and serialize with readable markup language like TOML.

- *Why Configurations only supports TOML?*
This is not true, Configurations supports converting a dictionary type (subtype of `AbstractDict{String}`)
to option types defined by [`@option`](@ref). The reason why TOML is supported by default is because
Julia is shipped with a TOML parser already, so **we can support TOML without adding extra dependency**.
And depending on other format parsers such as `YAML`, `JSON` etc. will cause an extra loading latency
that is not necessary for most of the users who is fine with just TOML. 

On the other hand, `Configurations` aims to be lightweight because it is used by latency
sensitive packages like [Comonicon](https://comonicon.org/). We will put other features
into [KungIChi](https://github.com/Roger-luo/KungIChi.jl) in the future (it is still
work-in-progress).

- *Why do you need an [`@option`](@ref) macro?*
the [`@option`](@ref) macro provides the functionality of reflection in compile time, e.g
we support type alias and default value reflection. These feature is not implementable
without macros.

- *Why not just use a supertype but a macro?*
besides the reason in the previous question, for a specific project,
we can write a supertype and implement a set of generic interface,
which is fine. But as a package, we need to make things composable
and generic, thus, we do not want to block users from defining their
own supertype. In this package, we use traits instead of supertypes,
this makes things composable, e.g you can use the [option types defined
in Pluto](https://github.com/fonsp/Pluto.jl/blob/main/src/Configuration.jl)
as part of your own option types.

- *What is the difference between this package and [Preferences](https://github.com/JuliaPackaging/Preferences.jl)*
Preferences aims to provide a mechanism of reading package preferences that works with the package manager [Pkg](http://pkg.julialang.org/), but this package aims to provide a mechnism to read a setting/preference to Julia structs. Thus
these two are completely orthogonal packages and they can work together.

- *What is the difference between this package and [StructTypes](https://github.com/JuliaData/StructTypes.jl)*
StructTypes is mainly used to provide a standard interface to parse dict-like data to a Julia struct via
traits to make parsing faster, but this package aims to support the mapping between a dict-like data
and a specific kind of Julia struct defined by `@option` which provides limited semantic that is not
as general as a normal Julia struct (it is closer to `Base.@kwdef` semantic). And we have plans of supporting
StructTypes traits by default once [JuliaData/StructTypes#53](https://github.com/JuliaData/StructTypes.jl/issues/53)
is figured out.

## License

MIT License
