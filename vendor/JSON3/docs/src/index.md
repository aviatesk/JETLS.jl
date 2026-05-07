# JSON3.jl Documentation

```@contents
Depth = 4
```

## Getting Started

> Yet another JSON package for Julia; this one is for speed and slick struct mapping

JSON3 provides two main functions: [`JSON3.read`](@ref) and [`JSON3.write`](@ref).  These allow, in the basic case, reading a JSON string into a [`JSON3.Object`](@ref) or [`JSON3.Array`](@ref), which allow for dot or bracket indexing and can be copied into base `Dict`s or `Vector`s if needed.  The slick struct mapping allows reading a JSON string directly into (almost) any type you wish and then writing directly from those types into JSON as well.

### Examples

#### Basic reading and writing
```@example
using JSON3 # hide
json_string = """{"a": 1, "b": "hello, world"}"""

hello_world = JSON3.read(json_string)

# can access the fields with dot or bracket notation
println(hello_world.b)
println(hello_world["a"])

JSON3.write(hello_world)
```

#### Write with pretty printing
```@example
using JSON3 # hide
json_string = """{"a": 1, "b": "hello, world"}"""

hello_world = JSON3.read(json_string)
JSON3.pretty(hello_world)
```

The alignment of the string produced  by `JSON3.pretty` can be controlled by
passing an [`JSON3.AlignmentContext`](@ref) to `JSON3.pretty`. To align each
level at the `:` Symbol and indent each new level by 2 additional spaces, use
```@example
using JSON3 # hide
json_string = """{"a":"abc","aaaaaaaaaaaaaa":{"a":"abc","aaaaaaaaaaaaaa":"abc"},"c":"abc"}""";
JSON3.pretty(JSON3.read(json_string), JSON3.AlignmentContext(alignment=:Colon, indent=2))
```
to left align the JSON string and indent each new level by 4 additional spaces
(this is also the default) use
```@example
using JSON3 # hide
json_string = """{"a":"abc","aaaaaaaaaaaaaa":{"a":"abc","aaaaaaaaaaaaaa":"abc"},"c":"abc"}""";
JSON3.pretty(JSON3.read(json_string), JSON3.AlignmentContext(alignment=:Left, indent=4))
```


#### Read and write from/to a file
```jl
json_string = read("my_file.json", String)

hello_world = JSON3.read(json_string)

open("my_new_file.json", "w") do io
    JSON3.write(io, hello_world)
end
```

#### Write pretty JSON to a file
```jl
hello_world = Dict("a" => Dict("b" => 1, "c" => 2), "b" => Dict("c" =>3, "d" => 4))

open("my_new_file.json", "w") do io
    JSON3.pretty(io, hello_world)
end
```

#### Read JSON into a type

See more details on the types that are provided and how to customize parsing [below](#Struct-API).

```@example
using JSON3 # hide
using StructTypes

json_string = """{"a": 1, "b": "hello, world"}"""

struct MyType
    a::Int
    b::String
end

StructTypes.StructType(::Type{MyType}) = StructTypes.Struct()

hello_world = JSON3.read(json_string, MyType)

println(hello_world)

JSON3.write(hello_world)
```

#### Read JSON into an already instantiated struct

```@example
using JSON3 # hide
using StructTypes

Base.@kwdef mutable struct MyType
    a::Int = 0
    b::String = ""
    c::String = ""
end

StructTypes.StructType(::Type{MyType}) = StructTypes.Mutable()

t = MyType(c = "foo")

json_string = """{"a": 1, "b": "hello, world"}"""

JSON3.read!(json_string, t)
```

#### Mutating read-JSON

Note that the `JSON3.Object` and `JSON3.Array` types are immutable, and hence can't be used like a normal `Dict` or `Array` to replace or add additional values. Calling `copy(obj_or_arr)` will convert a `JSON3.Object` into a mutable `Dict` or a `JSON3.Array` into a `Base.Array`, recursively calling `copy` on any nested objects/arrays.

```@example
using JSON3 # hide
read_only_json = JSON3.read("{\"a\": 3}")

writable_json = copy(read_only_json) # writable_json is now mutable
writable_json[:a] = 2 
```

#### Generate a type from your JSON

See the [section on generating types](#Generated-Types) for more details.

```@example
using JSON3 # hide
using StructTypes

json_string = """{"a": 1, "b": "hello, world"}"""

JSON3.@generatetypes json_string
hello_world = JSON3.read(json_string, JSONTypes.Root)
```

#### Read in a date
```@example
using JSON3 # hide
using Dates

json_string = "\"2000-01-01\""
df = dateformat"yyyy-mm-dd"
my_date = JSON3.read(json_string, Date; dateformat=df)
```

#### Read a quoted number
```@example
using JSON3 # hide
using StructTypes

json_string = """{"a": "1", "b": "hello, world"}"""

struct MyType
    a::Int
    b::String
end

StructTypes.StructType(::Type{MyType}) = StructTypes.Struct()

hello_world = JSON3.read(json_string, MyType; parsequoted=true)
```

### API

```@docs
JSON3.read
JSON3.read!
JSON3.write
JSON3.pretty
JSON3.@pretty
JSON3.AlignmentContext
JSON3.Object
JSON3.Array
Base.copy
JSON3.tostring
```

### In Relation to Other JSON Packages

#### JSON.jl

While the [JSON.jl](https://github.com/JuliaIO/JSON.jl) package has been around since the very early days of Julia, JSON3.jl aims a faster core implementation of JSON parsing (via [`JSON3.read`](@ref)), as well as better integration with custom types using the [Struct API](#Struct-API). Via the [StructTypes.jl](https://github.com/JuliaData/StructTypes.jl) package, JSON3 provides numerous configurations for reading/writing custom types.

#### JSONTables.jl

[JSONTables.jl](https://github.com/JuliaData/JSONTables.jl) uses JSON3 under the hood to read and write JSON sources to/from [Tables.jl](https://github.com/JuliaData/Tables.jl) compatible tables.

## Builtin types

The JSON format is made up of just a few types: Object, Array, String, Number, Bool, and Null.
In the JSON3 package, there are two main interfaces for interacting with these JSON types: 1) builtin and 2) struct mapping.
For builtin reading, called like `JSON3.read(json_string)`, the JSON3 package will parse a string or `Vector{UInt8}`,
returning a default object that maps to the type of the JSON. For a JSON Object, it will return a `JSON3.Object` type, which
acts like an immutable `Dict`, but has a more efficient view representation. For a JSON Array, it will return a `JSON3.Array` type,
which acts like an immutable `Vector`, but also has a more efficient view representation. If the JSON Array has homogenous elements,
the resulting `JSON3.Array` will be strongly typed accordingly. For the other JSON types (string, number, bool, and null),
they are returned as Julia equivalents (`String`, `Int64` or `Float64`, `Bool`, and `nothing`).

One might wonder why custom `JSON3.Object` and `JSON3.Array` types exist instead of just returning `Dict` and `Vector` directly. JSON3 employs a novel technique [inspired by the simdjson project](https://github.com/lemire/simdjson), that is a
semi-lazy parsing of JSON to the `JSON3.Object` or `JSON3.Array` types. The technique involves using a type-less "tape" to note
the *positions* of objects, arrays, and strings in a JSON structure, while avoiding the cost of *materializing* such
objects. For "scalar" types (number, bool, and null), the values are parsed immediately and stored inline in the "tape". This can result in best of both worlds performance: very fast initial parsing of a JSON input, and very cheap access afterwards. It also enables efficiencies in workflows where only small pieces of a JSON structure are needed, because expensive objects, arrays, and strings aren't materialized unless accessed. One additional advantage this technique allows is strong typing of `JSON3.Array{T}`; because the type of each element is noted while parsing, the `JSON3.Array` object can then be constructed with the most narrow type possible without having to reallocate any underlying data (since all data is stored in a type-less "tape" anyway).

The `JSON3.Object` supports the `AbstractDict` interface, but is read-only (it represents a *view* into the JSON source input), thus it supports `obj[:x]` and `obj["x"]`, as well as `obj.x` for accessing fields. It supports `keys(obj)` to see available keys in the object structure. You can call `length(obj)` to see how many key-value pairs there are, and it iterates `(k, v)` pairs like a normal `Dict`. It also supports the regular `get(obj, key, default)` family of methods.

The `JSON3.Array{T}` supports the `AbstractArray` interface, but like `JSON3.Object` is a *view* into the input JSON, hence is read-only. It supports normal array methods like `length(A)`, `size(A)`, iteration, and `A[i]` `getindex` methods.

If you really need `Dict`s and `Vector`s, then you can use `copy(x)` to recursively convert `JSON3.Object`s to `Dict`s and `JSON3.Array`s to `Vector`s.

## Struct API

The builtin JSON API in JSON3 is efficient and simple, but sometimes a direct mapping to a Julia structure is desirable. JSON3 uses the simple, yet powerful "struct mapping" techniques from the [StructTypes.jl](https://github.com/JuliaData/StructTypes.jl) package.

In general, custom Julia types tend to be one of: 1) "data types", 2) "interface types" and sometimes 3) "abstract types" with a known set of concrete subtypes or 4) "custom types" that just don't really fit in any other categories. Data types tend to be "collection of fields" kind of types; fields are generally public and directly accessible, they might also be made to model "objects" in the object-oriented sense. In any case, the type is "nominal" in the sense that it's "made up" of the fields it has, sometimes even if just for making it more convenient to pass them around together in functions.

Interface types, on the other hand, are characterized by *private* fields; they contain optimized representations "under the hood" to provide various features/functionality and are useful via interface methods implemented: iteration, `getindex`, accessor methods, etc. Many package-provided libraries or Base-provided structures are like this: `Dict`, `Array`, `Socket`, etc. For these types, their underlying fields are mostly cryptic and provide little value to users directly, and are often explictly documented as being implementation details and not to be accessed under warning of breakage.

What does all this have to do with mapping Julia structures to JSON? A lot! For data types, the most typical JSON representation is for each field name to be a JSON key, and each field value to be a JSON value. And when *reading* data types from JSON, we need to specify how to construct the Julia structure for the key-value pairs encountered while parsing. This can be considered a "direct" mapping of Julia struct types to JSON objects in that we try to map field to key directly. This is the "data type" view of json-to-Julia struct mapping.

For interface types, however, we don't want to consider the type's fields at all, since they're "private" and not very meaningful. For these types, an alternative API is provided where a user can specify the `StructTypes.StructType` their type most closely maps to, one of `StructTypes.DictType()`, `StructTypes.ArrayType()`, `StructTypes.StringType()`, `StructTypes.NumberType()`, `StructTypes.BoolType()`, or `StructTypes.NullType()`.

For abstract types, it can sometimes be useful when reading a JSON structure to say that it will be one of a limited set of related types, with a specific JSON key in the structure signaling which concrete type the rest of the structure represents. JSON3 uses StructTypes.jl functionality to specify a `StructTypes.AbstractType()` for a type, along with a mapping of JSON key-type values to Julia subtypes that can be used to identify the concrete type while parsing.

We briefly mentioned a 4th category above: "custom types". Sometimes a type is just a "wrapper" around an internal type that has a well defined representation, be that data or interface. Sometimes, we're just in the middle of developing something and our structs are just not that well defined. `StructTypes.CustomStruct` provides a bit of an "escape hatch" of sorts in that we get explicit "hooks" into the pre-serialization and pre-deserialization steps when calling `JSON3.read(json, T)`. These are available via the `StructTypes.lower(x::T)` and `StructTypes.lowertype(::Type{T})` methods. The former will be called on any type with the `StructTypes.CustomStruct` trait before serializing, and then serializing will continue anew on whatever was returned, hence `StructTypes.lower` needs to return or transform `x::T` into something that also has a well-defined `StructType` trait. So our custom type `T` can essentially be serialized however we want by whatever we return from `StructTypes.lower`. `StructTypes.lowertype` works similarly, but for deserialization. We defined a mapping from our custom type to the type of object that should first be deserialized, which will then be passed to our type's `StructType.construct` method. An example of all this is:

```julia
struct Person
    id::Int
    name::String
end
StructTypes.StructType(::Type{Person}) = StructTypes.Struct()
struct PersonWrapper
    person::Person
end
StructTypes.StructType(::Type{PersonWrapper}) = StructTypes.CustomStruct()
StructTypes.lower(x::PersonWrapper) = x.person
StructTypes.lowertype(::Type{PersonWrapper}) = Person
StructTypes.construct(::Type{PersonWrapper}, x::Person) = PersonWrapper(x) # not strictly needed, because the default is `construct(T, x) = T(x)`
```

### DataTypes

For "data types", we aim to directly specify the JSON reading/writing behavior with respect to a Julia type's fields. This kind of data type can signal its struct type in a couple of ways:
```julia
StructTypes.StructType(::Type{MyType}) = StructTypes.Struct()
# or
StructTypes.StructType(::Type{MyType}) = StructTypes.Mutable()
# or assuming certain conditions
StructTypes.StructType(::Type{MyType}) = StructTypes.OrderedStruct()
```
`StructTypes.Struct` and `StructTypes.Mutable` correspond to the existing difference between Julia `struct` and `mutable struct` types: that is, immutable (`Struct`) vs. mutable (`Mutable`).
`StructTypes.OrderedStruct()` is less flexible, yet more performant. For reading a `StructTypes.OrderedStruct()` from a JSON string input, each key-value pair is read in the order it is encountered in the JSON input, the keys are ignored, and the values are directly passed to the type at the end of the object parsing like `MyType(val1, val2, val3)`. Yes, the JSON specification says that Objects are specifically *un-ordered* collections of key-value pairs, but the truth is that many JSON libraries provide ways to maintain JSON Object key-value pair order when reading/writing. Because of the minimal processing done while parsing, and the "trusting" that the Julia type constructor will be able to handle fields being present, missing, or even extra fields that should be ignored, this is the fastest possible method for mapping a JSON input to a Julia structure. If your workflow interacts with non-Julia APIs for sending/receiving JSON, you should take care to test and confirm the use of `StructTypes.OrderedStruct()` in the cases mentioned above: what if a field is missing when parsing? what if the key-value pairs are out of order? what if there extra fields get included that weren't anticipated? If your workflow is questionable on these points, or it would be too difficult to account for these scenarios in your type constructor, it would be better to consider the `StructTypes.Struct` or `StructTypes.Mutable()` options.

The slightly less performant, yet much more robust method for directly mapping Julia struct fields to JSON objects is via `StructTypes.Mutable()`. This technique requires your Julia type to be defined, *at a minimum*, like:
```julia
mutable struct MyType
    field1
    field2
    field3
    # etc.

    MyType() = new()
end
# or if not an "empty" inner construct, can be empty outer constructor
MyType() = ...
```
Note specifically that we're defining a `mutable struct` to allow field mutation, and providing a `MyType() = new()` inner constructor which constructs an "empty" `MyType` where isbits fields will be randomly initialized, and reference fields will be `#undef`. (Note that the constructor doesn't need to be *exactly* this (i.e. inner), but at least needs to be callable like `MyType()`. If certain fields need to be intialized or zeroed out for security, then this should be accounted for in the constructor). For these mutable types, the type will first be initizlied like `MyType()`, then JSON parsing will parse each key-value pair in a JSON object, setting the field as the key is encountered, and converting the JSON value to the appropriate field value. This flow has the nice properties of: allowing parsing success even if fields are missing in the JSON structure, and if "extra" fields exist in the JSON structure that aren't apart of the Julia struct's fields, they will automatically be ignored. This allows for maximum robustness when mapping Julia types to arbitrary JSON objects that may be generated via web services, other language JSON libraries, etc.

`StructTypes.Struct` work similarly, but due to their immutability, fields are parsed from JSON, then passed to `StructTypes.construct(T, x...)` where `T` is our struct type, and `x...` are the fields we've parsed from the JSON, provided _in field order_, even if the JSON had fields out of order. If fields are missing from the JSON itself, the `nothing` value will be passed for those fields, so constructors should account for the potential of missing fields by setting a default value in case of `nothing` or perhaps typeing the field like `Union{String, Nothing}` explicitly.

There are a few additional helper methods that can be utilized by these `StructTypes.DataType` types to hand-tune field reading/writing behavior:

* `StructTypes.names(::Type{MyType}) = ((:field1, :json1), (:field2, :json2))`: provides a mapping of Julia field name to expected JSON object key name. This affects both reading and writing. When reading the `json1` key, the `field1` field of `MyType` will be set. When writing the `field2` field of `MyType`, the JSON key will be `json2`.
* `StructTypes.excludes(::Type{MyType}) = (:field1, :field2)`: specify fields of `MyType` to ignore when reading and writing, provided as a `Tuple` of `Symbol`s. When reading, if `field1` is encountered as a JSON key, it's value will be read, but the field will not be set in `MyType`. When writing, `field1` will be skipped when writing out `MyType` fields as key-value pairs.
* `StructTypes.omitempties(::Type{MyType}) = (:field1, :field2)`: specify fields of `MyType` that shouldn't be written if they are "empty", provided as a `Tuple` of `Symbol`s. This only affects writing. If a field is a collection (AbstractDict, AbstractArray, etc.) and `isempty(x) === true`, then it will not be written. If a field is `#undef`, it will not be written. If a field is `nothing`, it will not be written.
* `StructTypes.keywordargs(::Type{MyType}) = (field1=(dateformat=dateformat"mm/dd/yyyy",), field2=(dateformat=dateformat"HH MM SS",))`: Specify for a `StructTypes.Mutable` `StructType` the keyword arguments by field, given as a `NamedTuple` of `NamedTuple`s, that should be passed to the `StructTypes.construct` method when deserializing `MyType`. This essentially allows defining specific keyword arguments you'd like to be passed for each field in your struct. Note that keyword arguments can be passed when reading, like `JSON3.read(source, MyType; dateformat=...)` and they will be passed down to each `StructTypes.construct` method. `StructTypes.keywordargs` just allows the defining of specific keyword arguments per field.

### Interface Types

For interface types, we don't want the internal fields of a type exposed, so an alternative API is to define the closest JSON type that our custom type should map to. This is done by choosing one of the following definitions:
```julia
StructTypes.StructType(::Type{MyType}) = StructTypes.DictType()
StructTypes.StructType(::Type{MyType}) = StructTypes.ArrayType()
StructTypes.StructType(::Type{MyType}) = StructTypes.StringType()
StructTypes.StructType(::Type{MyType}) = StructTypes.NumberType()
StructTypes.StructType(::Type{MyType}) = StructTypes.BoolType()
StructTypes.StructType(::Type{MyType}) = StructTypes.NullType()
StructTypes.StructType(::Type{MyType}) = JSON3.RawType()
```

Now we'll walk through each of these and what it means to map my custom Julia type to an interface type.

#### StructTypes.DictType

    StructTypes.StructType(::Type{MyType}) = StructTypes.DictType()

Declaring my type is `StructTypes.DictType()` means it should map to a JSON object of unordered key-value pairs, where keys are `Symbol` or `String`, and values are any other type (or `Any`).

Types already declared as `StructTypes.DictType()` include:
  * Any subtype of `AbstractDict`
  * Any `NamedTuple` type
  * Any `Pair` type

So if your type subtypes `AbstractDict` and implements its interface, then JSON reading/writing should just work!

Otherwise, the interface to satisfy `StructTypes.DictType()` for reading is:

  * `MyType(x::Dict{Symbol, Any})`: implement a constructor that takes a `Dict{Symbol, Any}` of key-value pairs parsed from JSON
  * `StructTypes.construct(::Type{MyType}, x::Dict; kw...)`: alternatively, you may overload the `StructTypes.construct` method for your type if defining a constructor is undesirable (or would cause other clashes or ambiguities)

The interface to satisfy for writing is:

  * `pairs(x)`: implement the `pairs` iteration function (from Base) to iterate key-value pairs to be written out to JSON
  * `StructTypes.keyvaluepairs(x::MyType)`: alternatively, you can overload the `StructTypes.keyvaluepairs` function if overloading `pairs` isn't possible for whatever reason

#### StructTypes.ArrayType

    StructTypes.StructType(::Type{MyType}) = StructTypes.ArrayType()

Declaring my type is `StructTypes.ArrayType()` means it should map to a JSON array of ordered elements, homogenous or otherwise.

Types already declared as `StructTypes.ArrayType()` include:
  * Any subtype of `AbstractArray`
  * Any subtype of `AbstractSet`
  * Any `Tuple` type

So if your type already subtypes these and satifies the interface, things should just work.

Otherwise, the interface to satisfy `StructTypes.ArrayType()` for reading is:

  * `MyType(x::Vector)`: implement a constructo that takes a `Vector` argument of values and constructs a `MyType`
  * `StructTypes.construct(::Type{MyType}, x::Vector; kw...)`: alternatively, you may overload the `StructTypes.construct` method for your type if defining a constructor isn't possible
  * Optional: `Base.IteratorEltype(::Type{MyType})` and `Base.eltype(x::MyType)`: this can be used to signal to JSON3 that elements for your type are expected to be a single type and JSON3 will attempt to parse as such

The interface to satisfy for writing is:

  * `iterate(x::MyType)`: just iteration over each element is required; note if you subtype `AbstractArray` and define `getindex(x::MyType, i::Int)`, then iteration is already defined for your type

#### StructTypes.StringType

    StructTypes.StructType(::Type{MyType}) = StructTypes.StringType()

Declaring my type is `StructTypes.StringType()` means it should map to a JSON string value.

Types already declared as `StructTypes.StringType()` include:
  * Any subtype of `AbstractString`
  * The `Symbol` type
  * Any subtype of `Enum` (values are written with their symbolic name)
  * The `Char` type

So if your type is an `AbstractString` or `Enum`, then things should already work.

Otherwise, the interface to satisfy `StructTypes.StringType()` for reading is:

  * `MyType(x::String)`: define a constructor for your type that takes a single String argument
  * `StructTypes.construct(::Type{MyType}, x::String; kw...)`: alternatively, you may overload `StructTypes.construct` for your type
  * `StructTypes.construct(::Type{MyType}, ptr::Ptr{UInt8}, len::Int; kw...)`: another option is to overload `StructTypes.construct` with pointer and length arguments, if it's possible for your custom type to take advantage of avoiding the full string materialization; note that your type should implement both `StructTypes.construct` methods, since JSON strings with escape characters in them will be fully unescaped before calling `StructTypes.construct(::Type{MyType}, x::String)`, i.e. there is no direct pointer/length method for escaped strings

The interface to satisfy for writing is:

  * `Base.string(x::MyType)`: overload `Base.string` for your type to return a "stringified" value

#### StructTypes.NumberType

    StructTypes.StructType(::Type{MyType}) = StructTypes.NumberType()

Declaring my type is `StructTypes.NumberType()` means it should map to a JSON number value.

Types already declared as `StructTypes.NumberType()` include:
  * Any subtype of `Signed`
  * Any subtype of `Unsigned`
  * Any subtype of `AbstractFloat`

In addition to declaring `StructTypes.NumberType()`, custom types can also specify a specific, *existing* number type it should map to. It does this like:
```julia
StructTypes.numbertype(::Type{MyType}) = Float64
```

In this case, I'm declaring the `MyType` should map to an already-supported number type `Float64`. This means that when reading, JSON3 will first parse a `Float64` value, and then call `MyType(x::Float64)`. Note that custom types may also overload `StructTypes.construct(::Type{MyType}, x::Float64; kw...)` if using a constructor isn't possible. Also note that the default for any type declared as `StructTypes.NumberType()` is `Float64`.

Similarly for writing, JSON3 will first call `Float64(x::MyType)` before writing the resulting `Float64` value out as a JSON number.

#### StructTypes.BoolType

    StructTypes.StructType(::Type{MyType}) = StructTypes.BoolType()

Declaring my type is `StructTypes.BoolType()` means it should map to a JSON boolean value.

Types already declared as `StructTypes.BoolType()` include:
  * `Bool`

The interface to satisfy for reading is:
  * `MyType(x::Bool)`: define a constructor that takes a single `Bool` value
  * `StructTypes.construct(::Type{MyType}, x::Bool; kw...)`: alternatively, you may overload `StructTypes.construct`

The interface to satisfy for writing is:
  * `Bool(x::MyType)`: define a conversion to `Bool` method

#### StructTypes.NullType

    StructTypes.StructType(::Type{MyType}) = StructTypes.NullType()

Declaring my type is `StructTypes.NullType()` means it should map to the JSON value `null`.

Types already declared as `StructTypes.NullType()` include:
  * `nothing`
  * `missing`

The interface to satisfy for reading is:
  * `MyType()`: an empty constructor for `MyType`
  * `StructTypes.construct(::Type{MyType}, x::Nothing; kw...)`: alternatively, you may overload `StructTypes.construct`

There is no interface for writing; if a custom type is declared as `StructTypes.NullType()`, then the JSON value `null` will be written.

#### JSON3.RawType

`JSON3.RawType` is a `StructType` that
custom types may define as their trait in order to get access to the
"raw value" while parsing. After declaring
`StructTypes.StructType(::Type{MyType}) = JSON3.RawType()`, the custom
`MyType` must also define
`StructTypes.construct(::Type{MyType}, x::JSON3.RawValue) = ...`. A
`JSON3.RawValue` has 3 fields, `bytes`,
`pos`, and `len`, corresponding to the raw byte buffer, byte position at
which the raw value starts, and the length of the raw value,
respectively. Users are then free to "construct" an instance of their
`MyType` however they want from the `JSON3.RawValue`.

For serializing, i.e. `JSON3.write`, `MyType` must implement a method
like `JSON3.rawbytes(x::MyType) = ...`, which must return an iterator of
bytes (`UInt8`) with known length (`Base.IteratorSize` must be
`Base.HasLength()` and `length(JSON3.rawbytes(x))` must work). Care must be taken in providing bytes as no
additional processing or escape analysis is done, the bytes are written
"as-is". If bytes are written with unescaped control characters (`'{'`,
`','`, etc.), it will result in corrupt JSON documents.

For example, suppose that you want to read a JSON number verbatim into a
Julia string:
```jldoctest
julia> using JSON3, StructTypes

julia> struct StringNumber
       value::String
       end

julia> @inline StructTypes.StructType(::Type{StringNumber}) = JSON3.RawType()

julia> @inline StructTypes.construct(::Type{StringNumber}, x::JSON3.RawValue) = StringNumber(unsafe_string(pointer(x.bytes, x.pos), x.len))

julia> @inline JSON3.rawbytes(x::StringNumber) = codeunits(x.value)

julia> j = "1.200"
"1.200"

julia> x = JSON3.read(j, StringNumber)
StringNumber("1.200")

julia> JSON3.write(x)
"1.200"
```

### AbstractTypes

A final, uncommon option for struct mapping is declaring:
```julia
StructTypes.StructType(::Type{MyType}) = StructTypes.AbstractType()
```
When declaring my type as `StructTypes.AbstractType()`, you must also define `StructTypes.subtypes`, which should be a NamedTuple with subtype keys mapping to Julia subtype Type values. You may optionally define `StructTypes.subtypekey` that indicates which JSON key should be used for identifying the appropriate concrete subtype. A quick example should help illustrate proper use of this `StructType`:
```julia
abstract type Vehicle end

struct Car <: Vehicle
    type::String
    make::String
    model::String
    seatingCapacity::Int
    topSpeed::Float64
end

struct Truck <: Vehicle
    type::String
    make::String
    model::String
    payloadCapacity::Float64
end

StructTypes.StructType(::Type{Vehicle}) = StructTypes.AbstractType()
StructTypes.StructType(::Type{Car}) = StructTypes.Struct()
StructTypes.StructType(::Type{Truck}) = StructTypes.Struct()
StructTypes.subtypekey(::Type{Vehicle}) = :type
StructTypes.subtypes(::Type{Vehicle}) = (car=Car, truck=Truck)

car = JSON3.read("""
{
    "type": "car",
    "make": "Mercedes-Benz",
    "model": "S500",
    "seatingCapacity": 5,
    "topSpeed": 250.1
}""", Vehicle)
```
Here we have a `Vehicle` type that is defined as a `StructTypes.AbstractType()`. We also have two concrete subtypes, `Car` and `Truck`. In addition to the `StructType` definition, we also define `StructTypes.subtypekey(::Type{Vehicle}) = :type`, which signals to JSON3 that, when parsing a JSON structure, when it encounters the `type` key, it should use the value, in our example it's `car`, to discover the appropriate concrete subtype to parse the structure as, in this case `Car`. The mapping of JSON subtype key value to Julia Type is defined in our example via `StructTypes.subtypes(::Type{Vehicle}) = (car=Car, truck=Truck)`. Thus, `StructTypes.AbstractType` is useful when the JSON structure to read includes a "subtype" key-value pair that can be used to parse a specific, concrete type; in our example, parsing the structure as a `Car` instead of a `Truck`.

### Parametric types

For Julia dispatch and thereby for both `StructTypes` and `JSON3.jl` parametric types with different parameters are their own type. Consider this example where subtype of `data` depens on properties of the surrounding envelope object.
```julia
abstract type MessageTypes end
struct Envelope{MsgType <: MessageTypes}
    _id :: Int
    data :: MsgType
    _type :: String
    Envelope{MsgType}(n,t, tnm) where {MsgType} = new(n,t, tnm)
end

StructTypes.StructType(::Type{Envelope}) = StructTypes.AbstractType()
StructTypes.StructType(::Type{Envelope{T}}) where T <: MessageTypes  = StructTypes.Struct()
StructTypes.subtypekey(::Type{Envelope}) = :_type
StructTypes.subtypes(::Type{Envelope}) = (ping=Envelope{Ping}, pong=Envelope{Pong})

struct Ping <: MessageTypes
  now::String
end
StructTypes.StructType(::Type{Ping}) = StructTypes.Struct()
  
struct Pong <: MessageTypes
  now::Int
end
StructTypes.StructType(::Type{Pong}) = StructTypes.Struct()
```
So `Type{Envelope}`, `Type{Envelope{Ping}}` and `Type{Envelope{Pong}}` are distinct Julia types which each can have their own dispatch. Here `Type{Envelope}` is choosen to be an `StructTypes.AbstractType()`. Note that `Envelope` is not an abstract type. `StructTypes.AbstractType()` makes no claims about properties of the Julia type and instead causes a subtype lookup when this type is used for deserialization. Deserializing against `Envelope` triggers a look-up of a type based one value in the field `_type` in this example.
```julia
  @assert JSON3.read("""{"_id":1,"data":{"now":2023},"_type":"pong"}""", Envelope) isa Envelope{Pong}
  @assert JSON3.read("""{"_id":1,"data":{"now":"2023"},"_type":"ping"}""", Envelope) isa Envelope{Ping}
```
If given a parametric types we want define all subtypes to be a `StructTypes.StructType` `<:` is useful.
```julia
struct MyParametricType{T}
    t::T
    MyParametricType{T}(t) where {T} = new(t)
end
MyParametricType(t::T) where {T} = MyParametricType{T}(t)

x = MyParametricType(1)

StructTypes.StructType(::Type{<:MyParametricType}) = StructTypes.Struct() 
```
This match all possible parametric types `MyParametricType{T}`. When deserializing, the type parameter(s) should be provided:
```julia
JSON3.read(json_string, MyParametricType{Int}) # NOT JSON3.read(json_string, MyParametricType)
```
In the previous example `Envelope` was ultimatetly resolved to a fully parametrized type.
## Generated Types

JSON3 has the ability to generate types from sample JSON, which then can be used to parse JSON into. Inspired by the [F# type provider](http://tomasp.net/academic/papers/fsharp-data/fsharp-data.pdf).

```julia
JSON3.@generatetypes sample :MyModule
JSON3.read(full_json, MyModule.Root)

# or if sample is an array of objects
JSON3.read(full_json, Vector{MyModule.Root})
```

The [`JSON3.@generatetypes`](@ref) macro takes a JSON string or file name, generates a raw type from it, then parses that raw type into a series of mutable structs, which are then evaluated in a module (default `JSONTypes`) in the local scope.  Alternately, the [`JSON3.writetypes`](@ref) function can be used to perform these same steps, but instead write the generated module to file.

```julia
# writes a module called JSONTypes with the root struct Root as mutable
JSON3.writetypes(sample, "json_types.jl")

# write the same module, but with custom names and immutable
JSON3.writetypes(sample, "json_types.jl"; module_name=:MyModule, root_name=:ABC, mutable=false)

# these files can then be edited as needed (perhaps to prune the imported json)
include("json_types.jl")
```

### API

```@docs
JSON3.generatetypes
JSON3.@generatetypes
JSON3.writetypes
JSON3.generate_type
JSON3.generate_exprs
JSON3.write_exprs
JSON3.generate_struct_type_module
```
