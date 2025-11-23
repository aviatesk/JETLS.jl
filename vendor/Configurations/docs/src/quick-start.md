# Quick Start

## Create an option type

Create an option type with macro `@option` as following

```julia
@option struct YouOptionType <: YourAbstractType
   a::Int = 1
   b::Float64 # required field
end
```

then you can use this as an option type, it can let you:

1. convert an option type defined in Julia to a markup language, such as TOML, JSON
2. read from plain `AbstractDict{String}`, TOML, JSON etc. and convert the data to the option type
3. compose several option types together

You can easily create hierarchical struct types as following

```julia
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

and convert a dict to an option type via [`from_dict`](@ref).

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

when there are multiple possible option type for one field,
one can use the alias to distinguish them

```julia
julia> @option struct OptionD
           opt::Union{OptionA, OptionB}
       end

julia> d1 = Dict{String, Any}(
               "opt" => Dict{String, Any}(
                   "option_b" => d
               )
           );

julia> from_dict(OptionD, d1)
OptionD(;
    opt = OptionB(;
        opt = OptionA(;
            name = "Roger",
            int = 2,
        ),
        float = 0.33,
    ),
)

julia> using Configurations

julia> @option struct OptionA
           name::String
           int::Int = 1
       end

julia> @option struct OptionB
           opt::OptionA = OptionA(;name = "Sam")
           float::Float64 = 0.3
       end

julia> d = Dict(
           "opt" => Dict(
               "name" => "Roger",
               "int" => 2,
           ),
           "float" => 0.33
       )
Dict{String, Any} with 2 entries:
  "opt"   => Dict{String, Any}("int"=>2, "name"=>"Roger")
  "float" => 0.33

julia> option = from_dict(OptionB, d)
OptionB(;
  opt = OptionA(;
    name = "Roger",
    int = 2,
  ),
  float = 0.33,
)
```

Or you can also create it from keyword arguments, e.g

```julia
julia> from_kwargs(OptionB; opt_name="Roger", opt_int=2, float=0.33)
OptionB(;
    opt = OptionA(;
        name = "Roger",
        int = 2,
    ),
    float = 0.33,
)
```

for option types you can always convert `AbstractDict` to a given option type,
or convert them back to dictionary via `to_dict`, e.g

```julia
julia> Configurations.to_dict(option)
OrderedDict{String, Any} with 2 entries:
  "opt"   => OrderedDict{String, Any}("name"=>"Roger", "int"=>2)
  "float" => 0.33
```

for serialization, you can use the builtin TOML support

```julia
julia> to_toml(option)
"float = 0.33\n\n[opt]\nname = \"Roger\"\nint = 2\n"
```

Or serialize it to other format from `OrderedDict`.

## The Reflect Type

One can use `Reflect` type to denote a field contains the type information of the struct.

```@docs
Reflect
```

This is useful when you have a few different option type for one field, e.g

```julia
@option struct Option
   field::Union{OptionA, OptionB, OptionC}
end
```

the type information of different type will be embeded in the corresponding string
of the `Reflect` field.
## Create pretty printing for your option type

One can overload the `Base.show` method to create your own pretty printing. However, if you are fine with
the printing style provided by [GarishPrint](https://rogerluo.dev/GarishPrint.jl/dev/), you can simply define
the following

```julia
# using GarishPrint
Base.show(io::IO, ::MIME"text/plain", x::MyOption) = GarishPrint.pprint_struct(io, x)
```

This will enable pretty printing provided by `GarishPrint` when a rich text environment is available,
and it will fallback to the default julia printing if `"text/plain"` [MIME type](https://en.wikipedia.org/wiki/Media_type)
is not available.

## Read from Keyword Arguments

Option types can be used to organize large number of keyword arguments, and one can also construct
an option type from keyword arguments via [`from_kwargs`](@ref)

```@docs
Configurations.from_kwargs
```

A real world example is [the Pluto configuration](https://github.com/fonsp/Pluto.jl/blob/main/src/Configuration.jl#L159).

## Modify Parsed Configurations

In some cases, user may want to change a few entries after
the configuration get parsed. This can be done via the keyword arguments
of [`from_dict`](@ref) or [`from_toml`](@ref).

```julia
@option struct SubOption
   field::Int
end

@option struct MyOption
   option::SubOption
end
```

by default [`from_dict`](@ref) or [`from_toml`](@ref) uses the [`from_underscore_kwargs!`](@ref)
convention, so one can change the `field` entry in `SubOption` above via

```julia
from_dict(d; option_field=2)
```

## Read from TOML files

Configurations supports TOML file by default via the TOML standard library, you can directly read a
TOML file to your option types via [`from_toml`](@ref).

```@docs
from_toml
```

## Read from YAML files

You can use the [JuliaData/YAML](https://github.com/JuliaData/YAML.jl) package to parse a YAML file to a `Dict{String, Any}`,

```julia
julia> using YAML, Configurations

julia> @option struct MyOption
           a::Int
           b::Float64
       end

julia> data = YAML.load_file("test.yml"; dicttype=Dict{String, Any})
Dict{String, Any} with 2 entries:
  "b" => 2
  "a" => 1

julia> from_dict(MyOption, data)
MyOption(1, 2.0)
```

but remember to tell the YAML parser that you would like the keys to be `String` since [`from_dict`](@ref) expects the dictionary to be `AbstractDict{String}`, this can be done via `dicttype` keyword as above example.

## Read JSON files

One can read JSON files as a dictionary via [JuliaIO/JSON](https://github.com/JuliaIO/JSON.jl).

```julia
julia> using JSON

julia> d = JSON.parse("{\"a\":1,\"b\":2.1}")
Dict{String, Any} with 2 entries:
  "b" => 2.1
  "a" => 1

julia> from_dict(MyOption, d)
MyOption(1, 2.1)
```

or for [JSON3](https://github.com/quinnj/JSON3.jl) you can use the following

```julia
julia> using JSON3, Configurations

julia> @option struct OptionA
        x::String = "hi"
        y::Vector{String} = String[]
           end

julia> d = JSON3.read("""
           {"y": ["a"]}
           """, Dict{String, Any})
Dict{String, Any} with 1 entry:
  "y" => Any["a"]

julia> from_dict(OptionA, d)
OptionA("hi", ["a"])
```

## Read other formats

For other formats, as long as you can convert them to a subtype of `AbstractDict{String}`,
you can always convert it to the option type you just defined via `from_dict`, however
for the sake of simplicity Configurations will not ship such functionality with it.

## Write to TOML
To write the option struct to a TOML file, simply use the `to_toml` function

```julia
julia> to_toml(option; include_defaults=false) # write to a String

julia> to_toml("test.toml", option; include_defaults=false) # write to a file
```

You may also be interested in the docstring of `to_toml`

```@docs
to_toml
```

## Write to YAML

To write the option struct to other formats, you need to convert it to a dictionary type
first via `to_dict`

```@docs
to_dict
```

Then you can use YAML package to write the dict to a YAML file

```julia
julia> using YAML, Configurations

julia> d = to_dict(your_option, YAMLStyle)

julia> YAML.write_file("myfile.yaml", d)
```

## Write to JSON

or for JSON, we recommend using [JSON](https://github.com/JuliaIO/JSON.jl) or [JSON3](https://github.com/quinnj/JSON3.jl) to write the file as following

for `JSON`

```julia
julia> using JSON, Configurations

julia> d = to_dict(your_option, JSONStyle)

julia> open("file.json", "w") do f
           JSON.print(f, d)
       end
```

for `JSON3` you can use the following code snippet

```julia
julia> using JSON3, Configurations

julia> @option struct OptionA
        x::String = "hi"
        y::Vector{String} = String[]
    end

julia> d = to_dict(OptionA(y=["a"]))

julia> JSON3.write(d)
"{\"x\":\"hi\",\"y\":[\"a\"]}"

julia> JSON3.write("file.json", d) # write to a file
"file.json"
```

## Write to other formats

For other formats, you can convert your option struct to an `OrderedDict{String, Any}` via
[`to_dict`](@ref) then serialize the dictionary to your desired format.

## Work with `StructTypes` and `JSON3`

One can work with [`StructType`](https://github.com/JuliaData/StructTypes.jl) with `Configurations`
to make `JSON.read(json_string, MyOptionType)` work automatically by copying the following code
and replace `MyOptionType` with your own option struct types.

```julia
using StructTypes
using Configurations
StructTypes.StructType(::Type{<:MyOptionType}) = StructTypes.CustomStruct()
StructTypes.lower(x::MyOptionType) = to_dict(x, JSONStyle)
StructTypes.lowertype(::Type{<:MyOptionType}) = OrderedDict{String, Any}
StructTypes.construct(::Type{T}, x) where {T <: MyOptionType} = from_dict(T, x)
```

then `JSON.read("// a json string or IO", MyOptionType)` will just work.

## Type Conversion

Since markup languages usually do not support arbitrary Julia types, thus, one may find the `from_dict`
complain that cannot `convert` an object of type `XXX` to an object of type `YYY`. Usually this is because
you haven't overload `Base.convert` from `XXX` to `YYY` for the custom struct type, usually this can be
resolved via the following overload

```julia
Base.convert(::Type{MyType}, x::String) = MyType(x)
```

where we assume you have written a constructor from `String` here.

However, in some cases, you may want to do the conversion only for one `OptionType` without causing
type piracy, for example, one may want to convert all the `String` to `Symbol` for `MyOption`, this
can be done by overloading [`Configurations.from_dict`](@ref)

```julia
Configurations.from_dict(::Type{MyOption}, ::Type{Symbol}, s) = Symbol(s)
```

For more detailed type conversion mechanism, please read the [Type Conversion](@ref type-conversion) section.
