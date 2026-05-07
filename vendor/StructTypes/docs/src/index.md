# StructTypes.jl

This guide provides documentation around the `StructTypes.StructType` trait for Julia objects
and its associated functions. This package was born from a desire to make working with, and
especially constructing, Julia objects more programmatic and customizable. This allows powerful
workflows when doing generic object transformations and serialization.

If anything isn't clear or you find bugs, don't hesitate to [open a new issue](https://github.com/JuliaData/StructTypes.jl/issues/new), even just for a question, or come chat with us on the
[#data](https://julialang.slack.com/messages/data/) slack channel with questions, concerns, or clarifications.

```@contents
Depth = 3
```

## `StructTypes.StructType`

In general, custom Julia types tend to be one of: 1) "data types", 2) "interface types" or sometimes 3) "custom types" or 4) "abstract types" with a known set of concrete subtypes. Data types tend to be "collection of fields" kind of types; fields are generally public and directly accessible, they might also be made to model "objects" in the object-oriented sense. In any case, the type is "nominal" in the sense that it's "made up" of the fields it has, sometimes even if just for making it more convenient to pass them around together in functions.

Interface types, on the other hand, are characterized by **private** fields; they contain optimized representations "under the hood" to provide various features/functionality and are useful via interface methods implemented: iteration, `getindex`, accessor methods, etc. Many package-provided libraries or Base-provided structures are like this: `Dict`, `Array`, `Socket`, etc. For these types, their underlying fields are mostly cryptic and provide little value to users directly, and are often explictly documented as being implementation details and not to be relied upon directly under warning of breakage.

What does all this have to do with the `StructTypes.StructType` trait? A lot! There's often a desire to
programmatically access the "public" names and values of an object, whether it's a data, interface, custom or abstract type.
For data types, this means each direct field name and value. For interface types, this means having an API
to get the names and values (_ignoring_ direct fields). Similarly for programmatic _construction_, we need to specify how to construct the Julia structure given an arbitrary set of key-value pairs.

For "custom" types, this is kind of a catchall for those types that don't really fit in the "data" or "interface" buckets; like wrapper types. You don't really care about the wrapper type itself
but about the type it wraps with a few modifications.

For abstract types, it can be useful to "bundle" the behavior of concrete subtypes under a single abstract type; and
when serializing/deserializing, an extra key-value pair is added to encode the true concrete type.

Each of these 4 kinds of struct type categories will be now be detailed.

### DataTypes

You'll remember that "data types" are Julia structs that are "made up" of their fields. In the object-oriented world,
this would be characterized by marking a field as `public`. A quick example is:

```julia
struct Vehicle
    make::String
    model::String
    year::Int
end
```

In this case, our `Vehicle` type is entirely "made up" by its fields, `make`, `model`, and `year`.

There are three ways to define the `StructTypes.StructType` of these kinds of objects:

```julia
StructTypes.StructType(::Type{MyType}) = StructTypes.Struct() # an alias for StructTypes.UnorderedStruct()
# or
StructTypes.StructType(::Type{MyType}) = StructTypes.Mutable()
# or
StructTypes.StructType(::Type{MyType}) = StructTypes.OrderedStruct()
```

#### `StructTypes.Struct`

```@docs
StructTypes.Struct
```

#### `StructTypes.Mutable`

```@docs
StructTypes.Mutable
```

Support functions for `StructTypes.DataType`s:

```@docs
StructTypes.names
StructTypes.excludes
StructTypes.omitempties
StructTypes.keywordargs
StructTypes.idproperty
StructTypes.fieldprefix
```

### Interface Types

For interface types, we don't want the internal fields of a type exposed, so an alternative API is to define the closest "basic" type that our custom type should map to. This is done by choosing one of the following definitions:
```julia
StructTypes.StructType(::Type{MyType}) = StructTypes.DictType()
StructTypes.StructType(::Type{MyType}) = StructTypes.ArrayType()
StructTypes.StructType(::Type{MyType}) = StructTypes.StringType()
StructTypes.StructType(::Type{MyType}) = StructTypes.NumberType()
StructTypes.StructType(::Type{MyType}) = StructTypes.BoolType()
StructTypes.StructType(::Type{MyType}) = StructTypes.NullType()
```

Now we'll walk through each of these and what it means to map my custom Julia type to an interface type.

#### `StructTypes.DictType`

```@docs
StructTypes.DictType
```

#### `StructTypes.ArrayType`

```@docs
StructTypes.ArrayType
```

#### `StructTypes.StringType`

```@docs
StructTypes.StringType
```

#### `StructTypes.NumberType`

```@docs
StructTypes.NumberType
```

#### `StructTypes.BoolType`

```@docs
StructTypes.BoolType
```

#### `StructTypes.NullType`

```@docs
StructTypes.NullType
```

### CustomStruct

```@docs
StructTypes.CustomStruct
StructTypes.lower
StructTypes.lowertype
```

### AbstractTypes

```@docs
StructTypes.AbstractType
```

### Utilities

Several utility functions are provided for fellow package authors wishing to utilize the `StructTypes.StructType` trait to integrate in their package. Due to the complexity of correctly handling the various configuration options with `StructTypes.Mutable` and some of the interface types, it's strongly recommended to rely on these utility functions and open issues for concerns or missing functionality.

```@docs
StructTypes.constructfrom
StructTypes.construct
StructTypes.foreachfield
StructTypes.mapfields!
StructTypes.applyfield!
StructTypes.applyfield
```

## Macros

The `StructType` of a type can be set using the following utility macros


```@docs
StructTypes.@Struct
```

And similarly for 
- `StructTypes.@Mutable`
- `StructTypes.@CustomStruct`
- `StructTypes.@OrderedStruct`
- `StructTypes.@AbstractType`
- `StructTypes.@DictType`
- `StructTypes.@ArrayType`
- `StructTypes.@StringType`
- `StructTypes.@NumberType`
- `StructTypes.@BoolType`
- `StructTypes.@NullType`