module StructTypes

using UUIDs, Dates

"Abstract super type of various `StructType`s; see `StructTypes.DataType`, `StructTypes.CustomType`, `StructTypes.InterfaceType`, and `StructTypes.AbstractType` for more specific kinds of `StructType`s"
abstract type StructType end

StructType(x::T) where {T} = StructType(T)

"Default `StructTypes.StructType` for types that don't have a `StructType` defined; this ensures objects must have an explicit `StructType` to avoid unanticipated issues"
struct NoStructType <: StructType end
struct SingletonType <: StructType end

StructType(::Type{<:Function}) = NoStructType()


"""
    StructTypes.StructType(::Type{T}) = StructTypes.CustomStruct()

Signal that `T` has a custom serialization/deserialization pattern that doesn't quite fit `StructTypes.DataType`
or `StructTypes.InterfaceType`. One common example are wrapper types, where you want to serialize as the wrapped
type and can reconstruct `T` manually from deserialized fields directly. Defining `CustomStruct()` requires
overloading `StructTypes.lower(x::T)`, which should return any serializable object, and optionally overload
`StructTypes.lowertype(::Type{T})`, which returns the type of the lowered object (it returns `Any` by default).
`lowertype` is used to deserialize an object, which is then passed to `StructTypes.construct(T, obj)`
for construction (which defaults to calling `T(obj)`).
"""
struct CustomStruct <: StructType end

"""
    StructTypes.lower(x::T)

"Unwrap" or otherwise transform `x` to another object that has a well-defined `StructType` definition.
This is a required method for types declaring `StructTypes.CustomStruct`.
Allows objects of type `T` to conveniently serialize/deserialize as another type, when their own
structure/definition isn't significant. Useful for wrapper types. See also
[`StructTypes.CustomStruct`](@ref) and [`StructType.lowertype`](@ref).
"""
function lower end

"""
    StructTypes.lowertype(::Type{T})

For `StructTypes.CustomStruct` types, they may optionally define `lowertype` to provide a
"deserialization" type, which defaults to `Any`. When deserializing a type `T`, the
deserializer will first call `StructTypes.lowertype(T) = S` and proceed with deserializing the
type `S` that was returned. Once `S` has been deserialized, the deserializer will call
`StructTypes.construct(T, x::S)`. With the default of `Any`, deserializers should return
an `AbstractDict` object where key/values can be enumerated/checked/retrieved to make it
decently convenient for `CustomStruct`s to construct themselves.
"""
function lowertype end

lowertype(::Type{T}) where {T} = Any

StructType(::Type{Some{T}}) where {T} = CustomStruct()
lower(x::Some) = x.value
lowertype(::Type{Some{T}}) where {T} = T

"A kind of `StructType` where an object's \"data\" is made up, at least in part, by its direct fields. When serializing, appropriate fields will be accessed directly."
abstract type DataType <: StructType end

"""
    StructTypes.StructType(::Type{T}) = StructTypes.Struct()
    StructTypes.StructType(::Type{T}) = StructTypes.UnorderedStruct()
    StructTypes.StructType(::Type{T}) = StructTypes.OrderedStruct()

Signal that `T` is an immutable type who's fields should be used directly when serializing/deserializing.
If a type is defined as `StructTypes.Struct`, it defaults to `StructTypes.UnorderedStruct`, which means its fields
are allowed to be serialized/deserialized in any order, as opposed to `StructTypes.OrderedStruct` which signals that
serialization/deserialization *must* occur in its defined field order exclusively. This can enable optimizations when
an order can be guaranteed, but care must be taken to ensure any serialization formats can properly guarantee the order
(for example, the JSON specification doesn't explicitly require ordered fields for "objects", though most implementations
have a way to support this).

For `StructTypes.UnorderedStruct`, if a field is missing from the serialization, `nothing` should be passed to the `StructTypes.construct` method.

For example, when deserializing a `Struct.OrderedStruct`, parsed input fields are passed directly, in input order to the `T` constructor, like `T(field1, field2, field3)`.
This means that field names may be ignored when deserializing; fields are directly passed to `T` in the order they're encountered.

Another example, for reading a `StructTypes.OrderedStruct()` from a JSON string input, each key-value pair is read in the order it is encountered in the JSON input, the keys are ignored, and the values are directly passed to the type at the end of the object parsing like `T(val1, val2, val3)`.
Yes, the JSON specification says that Objects are specifically **un-ordered** collections of key-value pairs,
but the truth is that many JSON libraries provide ways to maintain JSON Object key-value pair order when reading/writing.
Because of the minimal processing done while parsing, and the "trusting" that the Julia type constructor will be able to handle fields being present, missing, or even extra fields that should be ignored,
this is the fastest possible method for mapping a JSON input to a Julia structure.
If your workflow interacts with non-Julia APIs for sending/receiving JSON, you should take care to test and confirm the use of `StructTypes.OrderedStruct()` in the cases mentioned above: what if a field is missing when parsing? what if the key-value pairs are out of order? what if there extra fields get included that weren't anticipated? If your workflow is questionable on these points, or it would be too difficult to account for these scenarios in your type constructor, it would be better to consider the `StructTypes.UnorderedStruct` or `StructTypes.Mutable()` options.

```@example
struct CoolType
    val1::Int
    val2::Int
    val3::String
end

StructTypes.StructType(::Type{CoolType}) = StructTypes.OrderedStruct()

# JSON3 package as example
@assert JSON3.read("{\"val1\": 1, \"val2\": 2, \"val3\": 3}", CoolType) == CoolType(1, 2, "3")
# note how `val2` field is first, then `val1`, but fields are passed *in-order* to `CoolType` constructor; BE CAREFUL!
@assert JSON3.read("{\"val2\": 2, \"val1\": 1, \"val3\": 3}", CoolType) == CoolType(2, 1, "3")
# if we instead define `Struct`, which defaults to `StructTypes.UnorderedStruct`, then the above example works
StructTypes.StructType(::Type{CoolType}) = StructTypes.Struct()
@assert JSON3.read("{\"val2\": 2, \"val1\": 1, \"val3\": 3}", CoolType) == CoolType(1, 2, "3")
```
"""
abstract type Struct <: DataType end


# Check for structs we can't use multiple dispatch for
StructType(::Type{T}) where {T} = Base.issingletontype(T) ? SingletonType() : Struct()
StructType(::Type{Union{}}) = SingletonType()

struct UnorderedStruct <: Struct end
struct OrderedStruct <: Struct end

Struct() = UnorderedStruct()

StructType(u::Union) = Struct()
StructType(::Type{Any}) = Struct()
StructType(::Type{<:NamedTuple}) = Struct()

"""
    StructTypes.StructType(::Type{T}) = StructTypes.Mutable()

Signal that `T` is a mutable struct with an empty constructor for serializing/deserializing.
Though slightly less performant than `StructTypes.Struct`, `Mutable` is a much more robust method for mapping Julia struct fields for serialization. This technique requires your Julia type to be defined, **at a minimum**, like:
```julia
mutable struct T
    field1
    field2
    field3
    # etc.

    T() = new()
end
```
Note specifically that we're defining a `mutable struct` to allow field mutation, and providing a `T() = new()` inner constructor which constructs an "empty" `T` where `isbitstype` fields will be randomly initialized, and reference fields will be `#undef`. (Note that the inner constructor doesn't need to be **exactly** this, but at least needs to be callable like `T()`. If certain fields need to be intialized or zeroed out for security, then this should be accounted for in the inner constructor). For these mutable types, the type will first be initialized like `T()`, then serialization will take each key-value input pair, setting the field as the key is encountered, and converting the value to the appropriate field value. This flow has the nice properties of: allowing object construction success even if fields are missing in the input, and if "extra" fields exist in the input that aren't apart of the Julia struct's fields, they will automatically be ignored. This allows for maximum robustness when mapping Julia types to arbitrary data foramts that may be generated via web services, databases, other language libraries, etc.

There are a few additional helper methods that can be utilized by `StructTypes.Mutable()` types to hand-tune field reading/writing behavior:

* `StructTypes.names(::Type{T}) = ((:juliafield1, :serializedfield1), (:juliafield2, :serializedfield2))`: provides a mapping of Julia field name to expected serialized object key name. This affects both serializing and deserializing. When deserializing the `serializedfield1` key, the `juliafield1` field of `T` will be set. When serializing the `juliafield2` field of `T`, the output key will be `serializedfield2`. Field name mappings are provided as a `Tuple` of `Tuple{Symbol, Symbol}`s, i.e. each field mapping is a Julia field name `Symbol` (first) and serialized field name `Symbol` (second).
* `StructTypes.excludes(::Type{T}) = (:field1, :field2)`: specify fields of `T` to ignore when serializing and deserializing, provided as a `Tuple` of `Symbol`s. When deserializing, if `field1` is encountered as an input key, it's value will be read, but the field will not be set in `T`. When serializing, `field1` will be skipped when serializing out `T` fields as key-value pairs.

* `StructTypes.omitempties(::Type{T}) = (:field1, :field2)`: specify fields of `T` that shouldn't be serialized if they are "empty", provided as a `Tuple` of `Symbol`s. This only affects serializing. If a field is a collection (AbstractDict, AbstractArray, etc.) and `isempty(x) === true`, then it will not be serialized. If a field is `#undef`, it will not be serialized. If a field is `nothing`, it will not be serialized. To apply this to all fields of `T`, set `StructTypes.omitempties(::Type{T}) = true`. You can customize this behavior. For example, by default, `missing` is not considered to be "empty". If you want `missing` to be considered "empty" when serializing your type `MyType`, simply define:
```julia
@inline StructTypes.isempty(::Type{T}, ::Missing) where {T <: MyType} = true
```

* `StructTypes.keywordargs(::Type{T}) = (field1=(dateformat=dateformat"mm/dd/yyyy",), field2=(dateformat=dateformat"HH MM SS",))`: provide keyword arguments for fields of type `T` that should be passed to functions that set values for this field. Define `StructTypes.keywordargs` as a NamedTuple of NamedTuples.
"""
struct Mutable <: DataType end

"""
    StructTypes.names(::Type{T}) = ((:juliafield1, :serializedfield1), (:juliafield2, :serializedfield2))

Provides a mapping of Julia field name to expected serialized object key name.
This affects both reading and writing.
When reading the `serializedfield1` key, the `juliafield1` field of `T` will be set.
When writing the `juliafield2` field of `T`, the output key will be `serializedfield2`.
"""
function names end

names(x::T) where {T} = names(T)
names(::Type{T}) where {T} = ()

Base.@pure function julianame(names::Tuple{Vararg{Tuple{Symbol, Symbol}}}, serializationname::Symbol)
    for nm in names
        nm[2] === serializationname && return nm[1]
    end
    return serializationname
end

Base.@pure julianame(names::Tuple{}, serializationname::Int) = serializationname

Base.@pure function serializationname(names::Tuple{Vararg{Tuple{Symbol, Symbol}}}, julianame::Symbol)
    for nm in names
        nm[1] === julianame && return nm[2]
    end
    return julianame
end

Base.@pure serializationname(names::Tuple{}, julianame::Int) = julianame

"""
    StructTypes.excludes(::Type{T}) = (:field1, :field2)

Specify for a `StructTypes.Mutable` `StructType` the fields, given as a `Tuple` of `Symbol`s, that should be ignored when deserializing, and excluded from serializing.
"""
function excludes end

excludes(x::T) where {T} = excludes(T)
excludes(::Type{T}) where {T} = ()

"""
    StructTypes.omitempties(::Type{T}) = (:field1, :field2)
    StructTypes.omitempties(::Type{T}) = true

Specify for a `StructTypes.Mutable` `StructType` the fields, given as a `Tuple` of `Symbol`s, that should not be serialized if they're considered "empty".

If a field is a collection (AbstractDict, AbstractArray, etc.) and `isempty(x) === true`, then it will not be serialized. If a field is `#undef`, it will not be serialized. If a field is `nothing`, it will not be serialized. To apply this to all fields of `T`, set `StructTypes.omitempties(::Type{T}) = true`. You can customize this behavior. For example, by default, `missing` is not considered to be "empty". If you want `missing` to be considered "empty" when serializing your type `MyType`, simply define:
```julia
@inline StructTypes.isempty(::Type{T}, ::Missing) where {T <: MyType} = true
```
"""
function omitempties end

omitempties(x::T) where {T} = omitempties(T)
omitempties(::Type{T}) where {T} = ()

function isempty end

isempty(x::Union{AbstractDict, AbstractArray, AbstractString, Tuple, NamedTuple}) = Base.isempty(x)
isempty(::Number) = false
isempty(::Nothing) = true
isempty(x) = false
isempty(x, i) = isempty(Core.getfield(x, i))
isempty(::Type{T}, x) where {T} = isempty(x) # generic fallback
isempty(::Type{T}, x, i) where {T} = isempty(T, Core.getfield(x, i)) # generic fallback

"""
    StructTypes.defaults(::Type{MyType}) = (:field_a=default_value, :field_b=>default_value)

Define default arguments for various fields of `MyType`, which will be used to initialize the name-value
dictionary used in `StructTypes.construct`.
"""
function defaults end

defaults(x::T) where {T} = defaults(T)
defaults(::Type{T}) where {T} = NamedTuple()

"""
    StructTypes.keywordargs(::Type{MyType}) = (field1=(dateformat=dateformat"mm/dd/yyyy",), field2=(dateformat=dateformat"HH MM SS",))

Specify for a `StructTypes.Mutable` the keyword arguments by field, given as a `NamedTuple` of `NamedTuple`s, that should be passed
to the `StructTypes.construct` method when deserializing `MyType`. This essentially allows defining specific keyword arguments you'd like to be passed for each field
in your struct. Note that keyword arguments can be passed when reading, like `JSON3.read(source, MyType; dateformat=...)` and they will be passed down to each `StructTypes.construct` method.
`StructTypes.keywordargs` just allows the defining of specific keyword arguments per field.
"""
function keywordargs end

keywordargs(x::T) where {T} = keywordargs(T)
keywordargs(::Type{T}) where {T} = NamedTuple()

"""
    StructTypes.idproperty(::Type{MyType}) = :id

Specify which field of a type uniquely identifies it. The unique identifier field name is given as a Symbol.
Useful in database applications where the id field can be used to distinguish separate objects.
"""
function idproperty end

idproperty(x::T) where {T} = idproperty(T)
idproperty(::Type{T}) where {T} = :_

"""
    StructTypes.fieldprefix(::Type{MyType}, field::Symbol) = :field_

When interacting with database tables and other strictly 2D data formats, objects with aggregate fields
must be flattened into a single set of column names. When deserializing a set of columns into an
object with aggregate fields, a field type's `fieldprefix` signals that column names beginning with, in
the example above, `:field_`, should be collected together when constructing the `field` field of `MyType`.
Note the default definition is `StructTypes.fieldprefix(T, nm) = Symbol(nm, :_)`.

Here's a more concrete, albeit contrived, example:
```julia
struct Spouse
    id::Int
    name::String
end

StructTypes.StructType(::Type{Spouse}) = StructTypes.Struct()

struct Person
    id::Int
    name::String
    spouse::Spouse
end

StructTypes.StructType(::Type{Person}) = StructTypes.Struct()
StructTypes.fieldprefix(::Type{Person}, field::Symbol) = field == :spouse ? :spouse_ : :_
```
Here we have two structs, `Spouse` and `Person`, and a `Person` has a `spouse::Spouse`.
The database tables to represent these entities might look like:
```SQL
CREATE TABLE spouse (id INT, name VARCHAR);
CREATE TABLE person (id INT, name VARCHAR, spouse_id INT);
```
If we want to leverage a package like Strapping.jl to automatically handle the object construction
for us, we could write a get query like the following to ensure a full `Person` with field `spouse::Spouse`
can be constructed:
```julia
getPerson(id::Int) = Strapping.construct(Person, DBInterface.execute(db,
    \"\"\"
        SELECT person.id as id, person.name as name, spouse.id as spouse_id, spouse.name as spouse_name
        FROM person
        LEFT JOIN spouse ON person.spouse_id = spouse.id
        WHERE person.id = \$id
    \"\"\"))
```
This works because the column names in the resultset of this query are "id, name, spouse\\_id, spouse\\_name";
because we defined `StructTypes.fieldprefix` for `Person`, Strapping.jl knows that each
column starting with "spouse\\_" should be used in constructing the `Spouse` field of `Person`.
"""
function fieldprefix end

Base.@pure fieldprefix(::Type{T}, nm::Symbol) where {T} = Symbol(nm, :_)

"""
    StructTypes.InterfaceType

An abstract type used in the API for "interface types" to map Julia types to a "standard" set of common types. See docs for the following concrete subtypes for more details:

  * StructTypes.DictType
  * StructTypes.ArrayType
  * StructTypes.StringType
  * StructTypes.NumberType
  * StructTypes.BoolType
  * StructTypes.NullType
"""
abstract type InterfaceType <: StructType end

"""
    StructTypes.construct(T, args...; kw...)

Function that custom types can overload for their `T` to construct an instance, given `args...` and `kw...`.
The default definition is `StructTypes.construct(T, args...; kw...) = T(args...; kw...)`.
"""
construct(T, args...; kw...) = T(args...; kw...)
construct(::Type{T}, x::T; kw...) where {T} = x
construct(::Type{T}, arg::String; kw...) where {T<:Number} = tryparse(T, arg)

"""
    StructTypes.StructType(::Type{T}) = StructTypes.DictType()

Declare that `T` should map to a dict-like object of unordered key-value pairs, where keys are `Symbol`, `String`, or `Int64`, and values are any other type (or `Any`).

Types already declared as `StructTypes.DictType()` include:
  * Any subtype of `AbstractDict`
  * Any `NamedTuple` type
  * The `Pair` type

So if your type subtypes `AbstractDict` and implements its interface, then it will inherit the `DictType` definition and serializing/deserializing should work automatically.

Otherwise, the interface to satisfy `StructTypes.DictType()` for deserializing is:

  * `T(x::Dict{Symbol, Any})`: implement a constructor that takes a `Dict{Symbol, Any}` of input key-value pairs
  * `StructTypes.construct(::Type{T}, x::Dict; kw...)`: alternatively, you may overload the `StructTypes.construct` method for your type if defining a constructor is undesirable (or would cause other clashes or ambiguities)

The interface to satisfy for serializing is:

  * `pairs(x)`: implement the `pairs` iteration function (from Base) to iterate key-value pairs to be serialized
  * `StructTypes.keyvaluepairs(x::T)`: alternatively, you can overload the `StructTypes.keyvaluepairs` function if overloading `pairs` isn't possible for whatever reason
"""
struct DictType <: InterfaceType end

StructType(::Type{<:AbstractDict}) = DictType()
StructType(::Type{<:Pair}) = DictType()

keyvaluepairs(x) = pairs(x)
keyvaluepairs(x::Pair) = (x,)

construct(::Type{NamedTuple}, x::Dict; kw...) = NamedTuple{Tuple(keys(x))}(values(x))
construct(::Type{NamedTuple{names}}, x::Dict; kw...) where {names} = NamedTuple{names}(Tuple(x[nm] for nm in names))
construct(::Type{NamedTuple{names, types}}, x::Dict; kw...) where {names, types} = NamedTuple{names, types}(Tuple(x[nm] for nm in names))

"""
    StructTypes.StructType(::Type{T}) = StructTypes.ArrayType()

Declare that `T` should map to an array of ordered elements, homogenous or otherwise.

Types already declared as `StructTypes.ArrayType()` include:
  * Any subtype of `AbstractArray`
  * Any subtype of `AbstractSet`
  * Any `Tuple` type

So if your type already subtypes these and satifies their interface, things should just work.

Otherwise, the interface to satisfy `StructTypes.ArrayType()` for deserializing is:

  * `T(x::Vector)`: implement a constructor that takes a `Vector` argument of values and constructs a `T`
  * `StructTypes.construct(::Type{T}, x::Vector; kw...)`: alternatively, you may overload the `StructTypes.construct` method for your type if defining a constructor isn't possible
  * Optional: `Base.IteratorEltype(::Type{T}) = Base.HasEltype()` and `Base.eltype(x::T)`: this can be used to signal that elements for your type are expected to be a homogenous type

The interface to satisfy for serializing is:

  * `iterate(x::T)`: just iteration over each element is required; note if you subtype `AbstractArray` and define `getindex(x::T, i::Int)`, then iteration is inherited for your type
"""
struct ArrayType <: InterfaceType end

StructType(::Type{<:AbstractArray}) = ArrayType()
StructType(::Type{<:AbstractSet}) = ArrayType()
StructType(::Type{<:Tuple}) = ArrayType()

"""
    StructTypes.StructType(::Type{T}) = StructTypes.StringType()

Declare that `T` should map to a string value.

Types already declared as `StructTypes.StringType()` include:
  * Any subtype of `AbstractString`
  * The `Symbol` type
  * Any subtype of `Enum` (values are written with their symbolic name)
  * Any subtype of `AbstractChar`
  * The `UUID` type
  * Any `Dates.TimeType` subtype (`Date`, `DateTime`, `Time`, etc.)

So if your type is an `AbstractString` or `Enum`, then things should already work.

Otherwise, the interface to satisfy `StructTypes.StringType()` for deserializing is:

  * `T(x::String)`: define a constructor for your type that takes a single String argument
  * `StructTypes.construct(::Type{T}, x::String; kw...)`: alternatively, you may overload `StructTypes.construct` for your type
  * `StructTypes.construct(::Type{T}, ptr::Ptr{UInt8}, len::Int; kw...)`: another option is to overload `StructTypes.construct` with pointer and length arguments, if it's possible for your custom type to take advantage of avoiding the full string materialization; note that your type should implement both `StructTypes.construct` methods, since direct pointer/length deserialization may not be possible for some inputs

The interface to satisfy for serializing is:

  * `Base.string(x::T)`: overload `Base.string` for your type to return a "stringified" value, or more specifically, that returns an `AbstractString`, and should implement `ncodeunits(x)` and `codeunit(x, i)`.
"""
struct StringType <: InterfaceType end

StructType(::Type{<:AbstractString}) = StringType()
StructType(::Type{Symbol}) = StringType()
StructType(::Type{<:Enum}) = StringType()
StructType(::Type{<:AbstractChar}) = StringType()
StructType(::Type{UUID}) = StringType()
StructType(::Type{T}) where {T <: Dates.TimeType} = StringType()
StructType(::Type{VersionNumber}) = StringType()
StructType(::Type{Base.Cstring}) = StringType()
StructType(::Type{Base.Cwstring}) = StringType()
StructType(::Type{Base.Regex}) = StringType()

function construct(::Type{Char}, str::String; kw...)
    if length(str) == 1
        return Char(str[1])
    else
        throw(ArgumentError("invalid conversion from string to Char: '$str'"))
    end
end

_symbol(ptr, len) = ccall(:jl_symbol_n, Ref{Symbol}, (Ptr{UInt8}, Int), ptr, len)

construct(::Type{E}, ptr::Ptr{UInt8}, len::Int; kw...) where {E <: Enum} = construct(E, _symbol(ptr, len))
construct(::Type{E}, str::String; kw...) where {E <: Enum} = construct(E, Symbol(str))

function construct(::Type{E}, sym::Symbol; kw...) where {E <: Enum}
    @static if VERSION < v"1.2.0-DEV.272"
        Core.eval(parentmodule(E), sym)
    else
        for (k, v) in Base.Enums.namemap(E)
            sym == v && return E(k)
        end
        throw(ArgumentError("invalid $E string value: \"$sym\""))
    end
end

construct(::Type{T}, str::String; kw...) where {T <: AbstractString} = convert(T, str)
construct(::Type{T}, ptr::Ptr{UInt8}, len::Int; kw...) where {T} = construct(T, unsafe_string(ptr, len); kw...)
construct(::Type{Symbol}, ptr::Ptr{UInt8}, len::Int; kw...) = _symbol(ptr, len)
construct(::Type{T}, str::String; dateformat::Dates.DateFormat=Dates.default_format(T), kw...) where {T <: Dates.TimeType} = T(str, dateformat)

construct(::Type{UUID}, arg; kw...) = UUID(arg)

"""
    StructTypes.StructType(::Type{T}) = StructTypes.NumberType()

Declare that `T` should map to a number value.

Types already declared as `StructTypes.NumberType()` include:
  * Any subtype of `Signed`
  * Any subtype of `Unsigned`
  * Any subtype of `AbstractFloat`

In addition to declaring `StructTypes.NumberType()`, custom types can also specify a specific, **existing** number type it should map to. It does this like:
```julia
StructTypes.numbertype(::Type{T}) = Float64
```

In this case, `T` declares it should map to an already-supported number type: `Float64`. This means that when deserializing, an input will be parsed/read/deserialiezd as a `Float64` value, and then call `T(x::Float64)`. Note that custom types may also overload `StructTypes.construct(::Type{T}, x::Float64; kw...)` if using a constructor isn't possible. Also note that the default for any type declared as `StructTypes.NumberType()` is `Float64`.

Similarly for serializing, `Float64(x::T)` will first be called before serializing the resulting `Float64` value.
"""
struct NumberType <: InterfaceType end

StructType(::Type{<:Real}) = NumberType()
numbertype(::Type{T}) where {T <: Real} = T
numbertype(x) = Float64

"""
    StructTypes.StructType(::Type{T}) = StructTypes.BoolType()

Declare that `T` should map to a boolean value.

Types already declared as `StructTypes.BoolType()` include:
  * `Bool`

The interface to satisfy for deserializing is:
  * `T(x::Bool)`: define a constructor that takes a single `Bool` value
  * `StructTypes.construct(::Type{T}, x::Bool; kw...)`: alternatively, you may overload `StructTypes.construct`

The interface to satisfy for serializing is:
  * `Bool(x::T)`: define a conversion to `Bool` method
"""
struct BoolType <: InterfaceType end

StructType(::Type{Bool}) = BoolType()

"""
    StructTypes.StructType(::Type{T}) = StructTypes.NullType()

Declare that `T` should map to a "null" value.

Types already declared as `StructTypes.NullType()` include:
  * `nothing`
  * `missing`

The interface to satisfy for serializing is:
  * `T()`: an empty constructor for `T`
  * `StructTypes.construct(::Type{T}, x::Nothing; kw...)`: alternatively, you may overload `StructTypes.construct`

There is no interface for serializing; if a custom type is declared as `StructTypes.NullType()`, then serializing will be handled specially; writing `null` in JSON, `NULL` in SQL, etc.
"""
struct NullType <: InterfaceType end

StructType(::Type{Nothing}) = NullType()
StructType(::Type{Missing}) = NullType()
construct(::Type{T}, ::Nothing; kw...) where {T} = T()

"""
    StructTypes.StructType(::Type{T}) = StructTypes.AbstractType()

Signal that `T` is an abstract type, and when deserializing, one of its concrete subtypes will be materialized,
based on a "type" key/field in the serialization object.

Thus, `StructTypes.AbstractType`s *must* define `StructTypes.subtypes`, which should be a NamedTuple with subtype keys mapping to concrete Julia subtype values. You may optionally define `StructTypes.subtypekey` that indicates which input key/field name should be used for identifying the appropriate concrete subtype. A quick example using the JSON3.jl package should help illustrate proper use of this `StructType`:
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

# example from StructTypes deserialization
car = JSON3.read(\"\"\"
{
    "type": "car",
    "make": "Mercedes-Benz",
    "model": "S500",
    "seatingCapacity": 5,
    "topSpeed": 250.1
}\"\"\", Vehicle)
```
Here we have a `Vehicle` type that is defined as a `StructTypes.AbstractType()`.
We also have two concrete subtypes, `Car` and `Truck`. In addition to the `StructType` definition,
we also define `StructTypes.subtypekey(::Type{Vehicle}) = :type`, which signals that when deserializing,
when it encounters the `type` key, it should use the **value**, in the above example: `car`,
to discover the appropriate concrete subtype to parse the structure as, in this case `Car`.
The mapping of subtype key value to concrete Julia subtype is defined in our example via
`StructTypes.subtypes(::Type{Vehicle}) = (car=Car, truck=Truck)`.
Thus, `StructTypes.AbstractType` is useful when the object to deserialize includes a "subtype"
key-value pair that can be used to parse a specific, concrete type; in our example,
parsing the structure as a `Car` instead of a `Truck`.
"""
struct AbstractType <: StructType end

subtypekey(x::T) where {T} = subtypekey(T)
subtypekey(::Type{T}) where {T} = :type
subtypes(x::T) where {T} = subtypes(T)
subtypes(::Type{T}) where {T} = NamedTuple()

struct SubTypeClosure
    _subtypes::Dict{Symbol, Type}
    f::Function
    SubTypeClosure(f::Function) = new(Dict{Symbol, Type}(), f)
end
Base.haskey(s::SubTypeClosure, k::Symbol) = haskey(s._subtypes, k)
Base.get(s::SubTypeClosure, k::Symbol, default)  = get(s._subtypes, k, s.f(k))
Base.getindex(s::SubTypeClosure, k::Symbol) = get!(s, k, s.f(k))
Base.get!(s::SubTypeClosure, k::Symbol, default) = get!(s._subtypes, k, s.f(k))
# we hard-code length here because we still want to fulfill AbstractDict interface
# but our closure approach is "lazy" in that we don't know subtypes until they're encountered
Base.length(s::SubTypeClosure) = typemax(Int) 
Base.keys(s::SubTypeClosure) = keys(s._subtypes)
Base.values(s::SubTypeClosure) = values(s._subtypes)

# helper functions for type-stable reflection while operating on struct fields

"""
    StructTypes.construct(f, T) => T

Apply function `f(i, name, FT)` over each field index `i`, field name `name`, and field type `FT`
of type `T`, passing the function results to `T` for construction, like `T(x_1, x_2, ...)`.
Note that any `StructTypes.names` mappings are applied, as well as field-specific keyword arguments via `StructTypes.keywordargs`.
"""
@inline function construct(f, ::Type{T}) where {T}
    N = fieldcount(T)
    N == 0 && return T()
    nms = names(T)
    kwargs = keywordargs(T)
    constructor = T <: Tuple ? tuple : T <: NamedTuple ? ((x...) -> T(tuple(x...))) : T
    # unroll first 32 fields
    Base.@nexprs 32 i -> begin
        k_i = fieldname(T, i)
        if haskey(kwargs, k_i)
            x_i = f(i, serializationname(nms, k_i), fieldtype(T, i); kwargs[k_i]...)
        else
            x_i = f(i, serializationname(nms, k_i), fieldtype(T, i))
        end
        if N == i
            return Base.@ncall(i, constructor, x)
        end
    end
    vals = []
    for i = 33:N
        k_i = fieldname(T, i)
        if haskey(kwargs, k_i)
            x_i = f(i, serializationname(nms, k_i), fieldtype(T, i); kwargs[k_i]...)
        else
            x_i = f(i, serializationname(nms, k_i), fieldtype(T, i))
        end
        push!(vals, x_i)
    end
    return constructor(x_1, x_2, x_3, x_4, x_5, x_6, x_7, x_8, x_9, x_10, x_11, x_12, x_13, x_14, x_15, x_16,
             x_17, x_18, x_19, x_20, x_21, x_22, x_23, x_24, x_25, x_26, x_27, x_28, x_29, x_30, x_31, x_32, vals...)
end

Base.@pure function symbolin(names::Union{Tuple{Vararg{Symbol}}, Bool}, name)
    names isa Bool && return names
    for nm in names
        nm === name && return true
    end
    return false
end

"""
    StructTypes.foreachfield(f, x::T) => Nothing

Apply function `f(i, name, FT, v; kw...)` over each field index `i`, field name `name`, field type `FT`,
field value `v`, and any `kw` keyword arguments defined in `StructTypes.keywordargs` for `name` in `x`.
Nothing is returned and results from `f` are ignored. Similar to `Base.foreach` over collections.

Various "configurations" are respected when applying `f` to each field:
  * If keyword arguments have been defined for a field via `StructTypes.keywordargs`, they will be passed like `f(i, name, FT, v; kw...)`
  * If `StructTypes.names` has been defined, `name` will be the serialization name instead of the defined julia field name
  * If a field is undefined or empty and `StructTypes.omitempties` is defined, `f` won't be applied to that field
  * If a field has been excluded via `StructTypes.excludes`, it will be skipped
"""
@inline function foreachfield(f, x::T) where {T}
    N = fieldcount(T)
    N == 0 && return
    excl = excludes(T)
    nms = names(T)
    kwargs = keywordargs(T)
    emp = omitempties(T) === true ? fieldnames(T) : omitempties(T)
    Base.@nexprs 32 i -> begin
        k_i = fieldname(T, i)
        if !symbolin(excl, k_i) && isdefined(x, i)
            v_i = Core.getfield(x, i)
            if !symbolin(emp, k_i) || !isempty(T, x, i)
                if haskey(kwargs, k_i)
                    f(i, serializationname(nms, k_i), fieldtype(T, i), v_i; kwargs[k_i]...)
                else
                    f(i, serializationname(nms, k_i), fieldtype(T, i), v_i)
                end
            end
        end
        N == i && @goto done
    end
    if N > 32
        for i = 33:N
            k_i = fieldname(T, i)
            if !symbolin(excl, k_i) && isdefined(x, i)
                v_i = Core.getfield(x, i)
                if !symbolin(emp, k_i) || !isempty(T, x, i)
                    if haskey(kwargs, k_i)
                        f(i, serializationname(nms, k_i), fieldtype(T, i), v_i; kwargs[k_i]...)
                    else
                        f(i, serializationname(nms, k_i), fieldtype(T, i), v_i)
                    end
                end
            end
        end
    end

@label done
    return
end

"""
    StructTypes.foreachfield(f, T) => Nothing

Apply function `f(i, name, FT; kw...)` over each field index `i`, field name `name`, field type `FT`, 
and any `kw` keyword arguments defined in `StructTypes.keywordargs` for `name` on type `T`.
Nothing is returned and results from `f` are ignored. Similar to `Base.foreach` over collections.

Various "configurations" are respected when applying `f` to each field:
  * If keyword arguments have been defined for a field via `StructTypes.keywordargs`, they will be passed like `f(i, name, FT, v; kw...)`
  * If `StructTypes.names` has been defined, `name` will be the serialization name instead of the defined julia field name
  * If a field has been excluded via `StructTypes.excludes`, it will be skipped
"""
@inline function foreachfield(f, ::Type{T}) where {T}
    N = fieldcount(T)
    N == 0 && return
    excl = excludes(T)
    nms = names(T)
    kwargs = keywordargs(T)
    Base.@nexprs 32 i -> begin
        k_i = fieldname(T, i)
        if !symbolin(excl, k_i)
            if haskey(kwargs, k_i)
                f(i, serializationname(nms, k_i), fieldtype(T, i); kwargs[k_i]...)
            else
                f(i, serializationname(nms, k_i), fieldtype(T, i))
            end
        end
        N == i && @goto done
    end
    if N > 32
        for i = 33:N
            k_i = fieldname(T, i)
            if !symbolin(excl, k_i)
                if haskey(kwargs, k_i)
                    f(i, serializationname(nms, k_i), fieldtype(T, i); kwargs[k_i]...)
                else
                    f(i, serializationname(nms, k_i), fieldtype(T, i))
                end
            end
        end
    end

@label done
    return
end

"""
    StructTypes.mapfields!(f, x::T)

Applys the function `f(i, name, FT; kw...)` to each field index `i`, field name `name`, field type `FT`,
and any `kw` defined in `StructTypes.keywordargs` for `name` of `x`, and calls `setfield!(x, name, y)`
where `y` is returned from `f`.

This is a convenience function for working with `StructTypes.Mutable`, where a function can be
applied over the fields of the mutable struct to set each field value. It respects the various
StructTypes configurations in terms of skipping/naming/passing keyword arguments as defined.
"""
@inline function mapfields!(f, x::T) where {T}
    N = fieldcount(T)
    N == 0 && return
    excl = excludes(T)
    nms = names(T)
    kwargs = keywordargs(T)
    Base.@nexprs 32 i -> begin
        k_i = fieldname(T, i)
        if !symbolin(excl, k_i)
            if haskey(kwargs, k_i)
                setfield!(x, k_i, f(i, serializationname(nms, k_i), fieldtype(T, i); kwargs[k_i]...))
            else
                setfield!(x, k_i, f(i, serializationname(nms, k_i), fieldtype(T, i)))
            end
        end
        N == i && @goto done
    end
    if N > 32
        for i = 33:N
            k_i = fieldname(T, i)
            if !symbolin(excl, k_i)
                if haskey(kwargs, k_i)
                    setfield!(x, k_i, f(i, serializationname(nms, k_i), fieldtype(T, i); kwargs[k_i]...))
                else
                    setfield!(x, k_i, f(i, serializationname(nms, k_i), fieldtype(T, i)))
                end
            end
        end
    end

@label done
    return
end

"""
    StructTypes.applyfield!(f, x::T, nm::Symbol) => Bool

Convenience function for working with a `StructTypes.Mutable` object. For a given serialization name `nm`,
apply the function `f(i, name, FT; kw...)` to the field index `i`, field name `name`, field type `FT`, and
any keyword arguments `kw` defined in `StructTypes.keywordargs`, setting the field value to the return
value of `f`. Various StructType configurations are respected like keyword arguments, names, and exclusions.
`applyfield!` returns whether `f` was executed or not; if `nm` isn't a valid field name on `x`, `false`
will be returned (important for applications where the input still needs to consume the field, like json parsing).
Note that the input `nm` is treated as the serialization name, so any `StructTypes.names`
mappings will be applied, and the function will be passed the Julia field name.
"""
@inline function applyfield!(f, x::T, nm::Symbol) where {T}
    N = fieldcount(T)
    excl = excludes(T)
    nms = names(T)
    kwargs = keywordargs(T)
    nm = julianame(nms, nm)
    f_applied = false
    # unroll the first 32 field checks to avoid dynamic dispatch if possible
    Base.@nif(
        33,
        i -> (i <= N && fieldname(T, i) === nm && !symbolin(excl, nm)),
        i -> begin
            FT_i = fieldtype(T, i)
            if haskey(kwargs, nm)
                y_i = f(i, nm, FT_i; kwargs[nm]...)
            else
                y_i = f(i, nm, FT_i)
            end
            setfield!(x, i, y_i)
            f_applied = true
        end,
        i -> begin
            for j in 33:N
                (fieldname(T, j) === nm && !symbolin(excl, nm)) || continue
                FT_j = fieldtype(T, j)
                if haskey(kwargs, nm)
                    y_j = f(j, nm, FT_j; kwargs[nm]...)
                else
                    y_j = f(j, nm, FT_j)
                end
                setfield!(x, j, y_j)
                f_applied = true
                break
            end
        end
    )
    return f_applied
end

"""
    StructTypes.applyfield(f, ::Type{T}, nm::Symbol) => Bool

Convenience function for working with a `StructTypes.Mutable` object. For a given serialization name `nm`,
apply the function `f(i, name, FT; kw...)` to the field index `i`, field name `name`, field type `FT`, and
any keyword arguments `kw` defined in `StructTypes.keywordargs`.
Various StructType configurations are respected like keyword arguments, names, and exclusions.
`applyfield` returns whether `f` was executed or not; if `nm` isn't a valid field name on `x`, `false`
will be returned (important for applications where the input still needs to consume the field, like json parsing).
Note that the input `nm` is treated as the serialization name, so any `StructTypes.names`
mappings will be applied, and the function will be passed the Julia field name.
"""
@inline function applyfield(f, ::Type{T}, nm::Symbol) where {T}
    N = fieldcount(T)
    excl = excludes(T)
    nms = names(T)
    kwargs = keywordargs(T)
    nm = julianame(nms, nm)
    f_applied = false
    # unroll the first 32 field checks to avoid dynamic dispatch if possible
    Base.@nif(
        33,
        i -> (i <= N && fieldname(T, i) === nm && !symbolin(excl, nm)),
        i -> begin
            FT_i = fieldtype(T, i)
            if haskey(kwargs, nm)
                y_i = f(i, nm, FT_i; kwargs[nm]...)
            else
                y_i = f(i, nm, FT_i)
            end
            f_applied = true
        end,
        i -> begin
            for j in 33:N
                (fieldname(T, j) === nm && !symbolin(excl, nm)) || continue
                FT_j = fieldtype(T, j)
                if haskey(kwargs, nm)
                    y_j = f(j, nm, FT_j; kwargs[nm]...)
                else
                    y_j = f(j, nm, FT_j)
                end
                f_applied = true
                break
            end
        end
    )
    if !f_applied && haskey(defaults(T), nm)
        setfield!(x, nm, defaults(T)[nm])
    end
    return f_applied
end

@inline function construct(values::Vector{Any}, ::Type{T}) where {T}
    N = fieldcount(T)
    N == 0 && return T()
    nms = names(T)
    kwargs = keywordargs(T)
    constructor = T <: Tuple ? tuple : T <: NamedTuple ? ((x...) -> T(tuple(x...))) : T
    # unroll first 32 fields
    Base.@nexprs 32 i -> begin
        if isassigned(values, i)
            x_i = values[i]::fieldtype(T, i)
        elseif !isempty(defaults(T))
            x_i = get(defaults(T), fieldname(T, i), nothing)
        else
            x_i = nothing
        end
        if N == i
            return Base.@ncall(i, constructor, x)
        end
    end
    return constructor(x_1, x_2, x_3, x_4, x_5, x_6, x_7, x_8, x_9, x_10, x_11, x_12, x_13, x_14, x_15, x_16,
             x_17, x_18, x_19, x_20, x_21, x_22, x_23, x_24, x_25, x_26, x_27, x_28, x_29, x_30, x_31, x_32, map(i->isassigned(values, i) ? values[i] : nothing, 33:N)...)
end

@static if Base.VERSION < v"1.2"
    function hasfield(::Type{T}, name::Symbol) where T
        return name in fieldnames(T)
    end
end

"""
    StructTypes.constructfrom(T, obj)
    StructTypes.constructfrom!(x::T, obj)

Construct an object of type `T` (`StructTypes.constructfrom`) or populate an existing
object of type `T` (`StructTypes.constructfrom!`) from another object `obj`. Utilizes
and respects StructTypes.jl package properties, querying the `StructType` of `T`
and respecting various serialization/deserialization names, keyword args, etc.

Most typical use-case is construct a custom type `T` from an `obj::AbstractDict`, but
`constructfrom` is fully generic, so the inverse is also supported (turning any custom
struct into an `AbstractDict`). For example, an external service may be providing JSON
data with an evolving schema; as opposed to trying a strict "typed parsing" like
`JSON3.read(json, T)`, it may be preferrable to setup a local custom struct with just
the desired properties and call `StructTypes.constructfrom(T, JSON3.read(json))`. This
would first do a generic parse of the JSON data into a `JSON3.Object`, which is an
`AbstractDict`, which is then used as a "property source" to populate the fields of
our custom type `T`.
"""
function constructfrom end

constructfrom(::Type{T}, obj) where {T} =
    constructfrom(StructType(T), T, obj)

constructfrom!(x::T, obj) where {T} =
    constructfrom!(StructType(T), x, obj)

function constructfrom(::Struct, U::Union, obj)
    !(U.a isa Union) && obj isa U.a && return obj
    !(U.b isa Union) && obj isa U.b && return obj
    try
        return constructfrom(StructType(U.a), U.a, obj)
    catch e
        return constructfrom(StructType(U.b), U.b, obj)
    end
end

constructfrom(::Struct, ::Type{Any}, obj) = obj

constructfrom(::Union{StringType, BoolType, NullType}, ::Type{T}, obj) where {T} =
    construct(T, obj)

constructfrom(::NumberType, ::Type{T}, obj) where {T} =
    construct(T, numbertype(T)(obj))

constructfrom(::NumberType, ::Type{T}, obj::Symbol) where {T} =
    constructfrom(NumberType(), T, string(obj))

constructfrom(::NumberType, ::Type{T}, obj::String) where {T} =
    construct(T, tryparse(T, obj))

constructfrom(::ArrayType, ::Type{T}, obj) where {T} =
    constructfrom(ArrayType(), T, Base.IteratorEltype(T) == Base.HasEltype() ? eltype(T) : Any, obj)
constructfrom(::ArrayType, ::Type{Vector}, obj) =
    constructfrom(ArrayType(), Vector, Any, obj)

function constructfrom(::ArrayType, ::Type{T}, ::Type{eT}, obj) where {T, eT}
    if Base.haslength(obj)
        x = Vector{eT}(undef, length(obj))
        for (i, val) in enumerate(obj)
            @inbounds x[i] = constructfrom(eT, val)
        end
    else
        x = eT[]
        for val in obj
            push!(x, constructfrom(eT, val))
        end
    end
    return construct(T, x)
end

constructfrom(::DictType, ::Type{T}, obj) where {T} =
    constructfrom(DictType(), T, Any, Any, obj)
constructfrom(::DictType, ::Type{NamedTuple}, obj) =
    constructfrom(DictType(), NamedTuple, Symbol, Any, obj)
constructfrom(::DictType, ::Type{Dict}, obj) =
    constructfrom(DictType(), Dict, Any, Any, obj)
constructfrom(::DictType, ::Type{AbstractDict}, obj) =
    constructfrom(DictType(), Dict, Any, Any, obj)
constructfrom(::DictType, ::Type{T}, obj) where {T <: AbstractDict} =
    constructfrom(DictType(), T, keytype(T), valtype(T), obj)

@inline constructfrom(::DictType, ::Type{T}, ::Type{K}, ::Type{V}, obj::S) where {T, K, V, S} =
    constructfrom(DictType(), T, K, V, StructType(S), obj)

function constructfrom(::DictType, ::Type{T}, ::Type{K}, ::Type{V}, ::DictType, obj) where {T, K, V}
    d = Dict{K, V}()
    for (k, v) in keyvaluepairs(obj)
        d[constructfrom(K, k)] = constructfrom(V, v)
    end
    return construct(T, d)
end

struct ToDictClosure{K, V}
    x::Dict{K, V}
end

@inline function (f::ToDictClosure{K, V})(i, nm, ::Type{FT}, v::T; kw...) where {K, V, FT, T}
    f.x[constructfrom(K, nm)] = constructfrom(V, v)
    return
end

function constructfrom(::DictType, ::Type{T}, ::Type{K}, ::Type{V}, ::Union{Struct, Mutable}, obj) where {T, K, V}
    d = Dict{K, V}()
    foreachfield(ToDictClosure(d), obj)
    return construct(T, d)
end

constructfrom(::Mutable, ::Type{T}, obj) where {T} =
    constructfrom!(Mutable(), T(), obj)

struct Closure{T}
    v::T
end

@inline (f::Closure{T})(i, nm, TT; kw...) where {T} =
    constructfrom(TT, f.v)

constructfrom!(::Mutable, x::T, obj::S) where {T, S} =
    constructfrom!(Mutable(), x::T, StructType(S), obj)

function constructfrom!(::Mutable, x::T, ::DictType, obj) where {T}
    if !isempty(defaults(T))
        # must be in this order to allow overriding of defaults
        obj = merge(defaults(T), obj)
    end
    for (k, v) in keyvaluepairs(obj)
        applyfield!(Closure(v), x, k)
    end
    return x
end

struct ObjClosure{T}
    x::T
end

@inline function (f::ObjClosure{TT})(i, nm, ::Type{FT}, v::T; kw...) where {TT, FT, T}
    applyfield!(Closure(v), f.x, nm)
    return
end

function constructfrom!(::Mutable, x::T, ::Union{Struct, Mutable}, obj) where {T}
    foreachfield(ObjClosure(x), obj)
    return x
end

constructfrom(::Struct, ::Type{T}, obj::S) where {T, S} =
    constructfrom(Struct(), T, StructType(S), obj)

struct DictClosure{T}
    obj::T
end

@inline function (f::DictClosure{T})(i, nm, ::Type{FT}) where {T, FT}
    if haskey(f.obj, nm)
        return constructfrom(FT, getindex(f.obj, nm))
    end
    return nothing
end

function constructfrom(::Struct, ::Type{T}, ::DictType, obj) where {T}
    isempty(defaults(T)) && return construct(DictClosure(obj), T)
    # populate a new obj with defined defaults
    return construct(DictClosure(merge(defaults(T), obj)), T)
end

struct StructClosure{T}
    obj::T
end

@inline function (f::StructClosure{T})(i, nm, ::Type{FT}) where {T, FT}
    if hasfield(T, nm)
        return constructfrom(FT, getfield(f.obj, nm))
    end
    return nothing
end

constructfrom(::Struct, ::Type{T}, ::Union{Struct, Mutable}, obj) where {T} =
    construct(StructClosure(obj), T)

struct TupleClosure{T}
    obj::T
end

@inline (f::TupleClosure{T})(i, nm, ::Type{FT}) where {T, FT} =
    constructfrom(FT, f.obj[i])

constructfrom(::ArrayType, ::Type{T}, obj) where {T <: Tuple} =
    construct(TupleClosure(obj), T)

function constructfrom(::AbstractType, ::Type{T}, obj::S) where {T, S}
    types = subtypes(T)
    if length(types) == 1
        return constructfrom(types[1], obj)
    end
    skey = subtypekey(T)
    TT = types[Symbol(StructType(S) == DictType() ? obj[skey] : getfield(obj, skey))]
    return constructfrom(TT, obj)
end

include("macros.jl")

end # module
