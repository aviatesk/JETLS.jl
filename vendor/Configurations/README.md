# Configurations

[![CI][ci-img]][ci-url]
[![codecov][codecov-img]](codecov-url)
[![][docs-stable-img]][docs-stable-url]
[![][docs-dev-img]][docs-dev-url]
[![Aqua QA][aqua-img]][aqua-url]
[![Downloads][downloads-img]][downloads-url]

Configurations & Options made easy.

## Installation

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

```julia
pkg> add Configurations
```

## Usage

*There are more detailed guide in the [documentation][docs-stable-url].*

This package provides a macro `@option` to let you define `struct`s to represent options/configurations, and serialize between
different option/configuration file formats such as `TOML`.

You can easily create hierarchical struct types:

```julia
julia> using Configurations

julia> "Option A"
       @option "option_a" struct OptionA
           name::String
           int::Int = 1
       end

julia> "Option B"
       @option "option_b" struct OptionB
           opt::OptionA = OptionA(;name = "Sam")
           float::Float64 = 0.3
       end
```

and then convert from a `Dict` to your option type via [`from_dict`](@ref):

```julia
julia> d = Dict{String, Any}(
           "opt" => Dict{String, Any}(
               "name" => "Roger",
               "int" => 2,
           ),
           "float" => 0.33
       );

julia> option = from_dict(OptionB, d)
OptionB(;
    opt = OptionA(;
        name = "Roger",
        int = 2,
    ),
    float = 0.33,
)
```

## License

MIT License

[ci-img]: https://github.com/Roger-luo/Configurations.jl/workflows/CI/badge.svg
[ci-url]: https://github.com/Roger-luo/Configurations.jl/actions
[codecov-img]: https://codecov.io/gh/Roger-luo/Configurations.jl/branch/master/graph/badge.svg?token=U604BQGRV1
[codecov-url]: https://codecov.io/gh/Roger-luo/Configurations.jl
[docs-dev-img]: https://img.shields.io/badge/docs-dev-blue.svg
[docs-dev-url]: https://Roger-luo.github.io/Configurations.jl/dev/
[docs-stable-img]: https://img.shields.io/badge/docs-stable-blue.svg
[docs-stable-url]: https://Roger-luo.github.io/Configurations.jl/stable
[aqua-img]: https://raw.githubusercontent.com/JuliaTesting/Aqua.jl/master/badge.svg
[aqua-url]: https://github.com/JuliaTesting/Aqua.jl
[downloads-img]:https://shields.io/endpoint?url=https://pkgs.genieframework.com/api/v1/badge/Configurations
[downloads-url]:https://pkgs.genieframework.com?packages=Configurations
