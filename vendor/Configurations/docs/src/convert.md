```@meta
CurrentModule = Configurations
```

# [Type Conversion and Custom Parsing](@id type-conversion)

If you find [`from_dict`](@ref) or [`from_toml`](@ref) doesn't not support a Julia type, such as `Symbol`,
this is usually because the corresponding parser or format doesn't support this Julia type natively, in this
case you will need to define your own type conversion for this option type by
overloading [`Configurations.from_dict`](@ref)

## How does it work?

The type conversion for option types work as following:

1. if we find the target type does not match the value type, we will call [`Configurations.from_dict`](@ref)
2. if [`Configurations.from_dict`](@ref) is not overloaded, it will try to call `Base.convert`
3. if `Base.convert` doesn't work, a standard conversion failure error will be thrown by `Base.convert`.

Thus, if `Base.convert` is already overloaded, this will just work, or if the conversion rule is contextual based
on the option type, one can also overload [`Configurations.from_dict`](@ref), this also avoids potential type piracy.

For serialization, one can overload [`Configurations.to_dict`](@ref), this 

## The Overloading Interface

[`from_dict`](@ref) provides two overloading interface

```@docs
from_dict(::Type{OptionType}, ::OptionField, ::Type{T}, x) where {OptionType,T}
from_dict(::Type{OptionType}, ::Type{T}, x) where {OptionType,T}
to_dict(::Type{T}, x, option::ToDictOption) where T
```

## Example: Contextual Conversion

```@repl conversion
using Configurations

@option struct MyOption
    a::Int
    b::Symbol
end
```

directly calling `from_dict` will have the following error

```@repl conversion
@option struct MyOption
    a::Int
    b::Symbol
end

d = Dict{String, Any}(
    "a" => 1,
    "b" => "ccc"
)

from_dict(MyOption, d)
```

now if we define the following type conversion

```@repl conversion
Configurations.from_dict(::Type{MyOption}, ::Type{Symbol}, s) = Symbol(s)
```

it will just work

```@repl conversion
from_dict(MyOption, d)
```
