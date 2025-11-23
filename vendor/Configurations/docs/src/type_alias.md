# Option Type Alias

Option type alias is useful when you don't want to type complicated Julia type
expression, or your upstream schema doesn't use an explicit field to indicate
the type of the sub-field.

## Use an Alias for the Reflect Type Field

Sometimes, it can be tedious to have a long Julia expression (which may contain the module path)
in the string for a [`Reflect`](@ref) type, e.g

```@example tedious-reflect
using Configurations
@option struct ALongOptionNameA
    type::Reflect
    x::Int = 1
end

@option struct ALongOptionNameB
    type::Reflect
    x::Int = 1
    y::Int = 2
end

@option struct Composite
    xxx::Union{ALongOptionNameA, ALongOptionNameB}
end
```

```@repl tedious-reflect
d = to_dict(Composite(ALongOptionNameA()))
d["xxx"]
```

They can be relatively hard for human to edit in a markup language,
or just hard to memorize as part of a schema specification.
We can declare an alias name for such types to make things cleaner.

```@example better-reflect
using Configurations
@option "case_a" struct ALongOptionNameA
    type::Reflect
    x::Int = 1
end

@option "case_b" struct ALongOptionNameB
    type::Reflect
    x::Int = 1
    y::Int = 2
end

@option struct Composite
    xxx::Union{ALongOptionNameA, ALongOptionNameB}
end
```

```@repl better-reflect
d = to_dict(Composite(ALongOptionNameA()))
d["xxx"]
```

## Multiple Possible Choices of Option Types without Explicit Type Field

When there are multiple possible choices for an option-typed field, e.g

```julia
@option struct Options
    options::Union{OptionA, OptionB}
end
```

where `OptionA` and `OptionB` are also option types, one can specific which
option type is it by using an alias when defining `OptionA` and `OptionB`

```julia
@option "A" struct OptionA
    name::String
end

@option "B" struct OptionB
    age::Int
end
```

but they do not contain a field of type [`Reflect`](@ref),
then you can create an `Options` from the following Julia `Dict`

```julia
Dict{String, Any}(
    "options" => Dict{String, Any}(
        "A" => Dict{String, Any}(
            "name"=>"Roger",
        )
    )
)
```

or by using the following TOML file,

```toml
[options.A]
name="Roger"
```

the `@option <alias> <struct def>` syntax is only applicable to concrete types.
for parametric types, one will need to manually define the string alias for the
corresponding specialization.

You can declare these specialization using the [`@type_alias`](@ref) macro

```@docs
@type_alias
```