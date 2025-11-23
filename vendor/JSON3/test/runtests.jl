using Test, JSON3, StructTypes, UUIDs, Dates

@static if Base.VERSION < v"1.5"
    ismutable(o::T) where {T} = T.mutable
end

struct data
    t :: Tuple{Symbol, String}
end

@enum Fruit apple banana

struct XInt
    x::Int64
end

struct A
    a::Int
    b::Int
    c::Int
    d::Int
end

mutable struct B
    a::Int
    b::Int
    c::Int
    d::Int
    B() = new()
end

struct C
end

struct D
    a::Int
    b::Float64
    c::String
end

struct ParametricSingleton{T} end

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

abstract type Vehicle2 end

mutable struct Car2 <: Vehicle2
    make::String
    model::String
    seatingCapacity::Int
    topSpeed::Float64
    Car2() = new()
end

abstract type Expression end

abstract type Literal <: Expression end

abstract type BinaryFunction <: Expression end

struct LiteralValue <: Literal
    exprType::String
    value::Any
end

struct AndFunction <: BinaryFunction
    exprType::String
    lhs::Expression
    rhs::Expression
end

struct LotsOfFields
    x1::String
    x2::String
    x3::String
    x4::String
    x5::String
    x6::String
    x7::String
    x8::String
    x9::String
    x10::String
    x11::String
    x12::String
    x13::String
    x14::String
    x15::String
    x16::String
    x17::String
    x18::String
    x19::String
    x20::String
    x21::String
    x22::String
    x23::String
    x24::String
    x25::String
    x26::String
    x27::String
    x28::String
    x29::String
    x30::String
    x31::String
    x32::String
    x33::String
    x34::String
    x35::String
end

mutable struct DateStruct
    date::Date
    datetime::DateTime
    time::Time
end
DateStruct() = DateStruct(Date(0), DateTime(0), Time(0))

struct DictWithoutLength end

struct Wrapper
    x::NamedTuple{(:a, :b), Tuple{Int, String}}
end

struct NaNStruct
    x::Float64
end

StructTypes.StructType(::Type{NaNStruct}) = StructTypes.CustomStruct()
StructTypes.lower(x::NaNStruct) = x.x
StructTypes.construct(::Type{NaNStruct}, x) = NaNStruct(x)

Base.@kwdef mutable struct System
    duration::Real = 0 # mandatory
    cwd::Union{Nothing, String} = nothing
    environment::Union{Nothing, Dict} = nothing
    batch::Union{Nothing, Dict} = nothing
    shell::Union{Nothing, Dict} = nothing
end
StructTypes.StructType(::Type{System}) = StructTypes.Mutable()
StructTypes.omitempties(::Type{System}) = (:cwd, :environment, :batch, :shell)

roundtrip(x::T) where T = JSON3.read(JSON3.write(x), T)

mutable struct UndefGuy
    id::Int
    name::String
    UndefGuy() = new()
end

StructTypes.StructType(::Type{UndefGuy}) = StructTypes.Mutable()

@testset "JSON3" begin

@testset "read.jl" begin

for readfunc in [JSON3.read, JSON3.parse]
    @test_throws ArgumentError readfunc("")
    @test readfunc("{\"hey\":1}").hey == 1
    @test readfunc("[\"hey\",1]") == ["hey",1]
    @test readfunc("1.0") === Int64(1)
    @test readfunc("1") === Int64(1)
    @test readfunc("1.1") === 1.1
    @test readfunc("+1.1") === 1.1
    @test readfunc("-1.1") === -1.1
    @test readfunc("\"hey\"") == "hey"
    @test readfunc("null") === nothing
    @test readfunc("true") === true
    @test readfunc("false") === false
end

# numbertype
@test JSON3.read("1.0", numbertype=Float64) === 1.0
@test JSON3.read("1", numbertype=Float64) === 1.0
@test_throws ArgumentError JSON3.read("1", numbertype=Float32)
@test JSON3.read("{\"hey\":1}", numbertype=Float64).hey === 1.0
@test JSON3.read("[\"hey\",1]", numbertype=Float64)[2] === 1.0
@test JSON3.read("[[1]]", numbertype=Float64)[1][1] === 1.0
@test JSON3.read("1.0"; jsonlines=true, numbertype=Float64)[1] === 1.0

# more robust Int vs. Float detection: https://github.com/quinnj/JSON3.jl/issues/124
@test JSON3.read("9223372036854775807") == 9223372036854775807
@test JSON3.read("9223372036854775808") == 9.223372036854776e18 # overflowed Int64 promotes to Float64 (though slightly lossy)
@test JSON3.read("-9223372036854775808") == -9223372036854775808
@test JSON3.read("-9223372036854775809") == -9.223372036854776e18
# 2^53 boundaries
@test JSON3.read("9007199254740991") == 9007199254740991
@test JSON3.read("9007199254740992") == 9007199254740992
@test JSON3.read("9007199254740993") == 9007199254740993
@test JSON3.read("9007199254740994") == 9007199254740994
@test JSON3.read("1e17") == Int64(1e17)


@test_throws ArgumentError JSON3.read("{")
@test JSON3.read("{}") == JSON3.Object()
@test_throws ArgumentError JSON3.read("{a")
@test JSON3.read("{\"a\": 1}").a == 1
@test JSON3.read("{\"\\\"hey\\\"\": 1}")["\"hey\""] == 1
@test_throws ArgumentError JSON3.read("{\"a\"}")
@test JSON3.read("{\"a\": {\"a\": {\"a\": 1}}}").a.a.a == 1
@test JSON3.read("[3.14, 1]") == [3.14, 1]
@test JSON3.read("[1, 3.14]") == [1, 3.14]
@test JSON3.read("[null, 1]") == [nothing, 1]
@test JSON3.read("[1, null]") == [1, nothing]
@test JSON3.read("[null, null]") == [nothing, nothing]
@test JSON3.read("[null, \"hey\"]") == [nothing, "hey"]
@test_throws ArgumentError JSON3.read("{\"a\": 1\"")
@test_throws ArgumentError JSON3.read("{\"a\": 1, a")
@test JSON3.read("[]") == []
@test JSON3.read("[1]") == [1]
@test JSON3.read("[1,2,3]") == [1,2,3]
@test_throws ArgumentError JSON3.read("[1 a")
@test_throws ArgumentError JSON3.read("nulL")
@test_throws ArgumentError JSON3.read("\"\b\"")

obj = JSON3.read("""
{
    "int": 1,
    "float": 2.1,
    "bool1": true,
    "bool2": false,
    "none": null,
    "str": "\\"hey there sailor\\"",
    "obj": {
                "a": 1,
                "b": null,
                "c": [null, 1, "hey"],
                "d": [1.2, 3.4, 5.6]
            },
    "arr": [null, 1, "hey"],
    "arr2": [1.2, 3.4, 5.6]
}
""")
@test obj.int === Int64(1)
@test obj.float === 2.1
@test obj.bool1 === true
@test obj.bool2 === false
@test obj.none === nothing
@test obj.str == "\"hey there sailor\""
@test obj.obj.a === Int64(1)
@test obj.obj.b === nothing
@test obj.obj.c == [nothing, 1, "hey"]
@test obj.obj.d == [1.2, 3.4, 5.6]
@test obj.arr == [nothing, 1, "hey"]
@test obj.arr2 == [1.2, 3.4, 5.6]

@test_throws ArgumentError JSON3.read("trua")
@test_throws ArgumentError JSON3.read("tru")
@test_throws ArgumentError JSON3.read("fals")
@test_throws ArgumentError JSON3.read("falst")
@test_throws ArgumentError JSON3.read("f")

@test JSON3.read("\"\\u003e\\u003d\$1B\"") == ">=\$1B"

obj = JSON3.read("""
{ "a": 1,
  "b": 2,
  "c": 3,
  "d": 4
}""")

@test length(obj) == 4
for (i, (k, v)) in enumerate(obj)
    @test i == v
end

@test get(obj, :a) == 1
@test get(obj, Int, :a) == 1
@test_throws KeyError get(obj, :e)
@test_throws KeyError get(obj, Int, :e)
@test get(obj, :a, 2) == 1
@test get(obj, :e, 5) == 5
@test get(()->5, obj, :e) == 5
@test propertynames(obj) == [:a, :b, :c, :d]
@test obj["a"] == 1
@test get(obj, "a") == 1
@test get(obj, Int, "a") == 1
@test_throws KeyError get(obj, "e") == 1
@test_throws KeyError get(obj, Int, "e") == 1
@test get(obj, "a", 2) == 1
@test get(obj, Int, "a", 2) == 1
@test get(obj, "e", 5) == 5
@test get(obj, Int, "e", 5) == 5

arr = JSON3.read("""
[ 1,
  2,
  3,
  4
]""")

@test length(arr) == 4
@test size(arr) == (4,)

for (i, v) in enumerate(arr)
    @test i == v
end

@test arr[1] == 1
@test arr[end] == 4

arr = JSON3.read(SubString("""
[ 1,
  2,
  3,
  4
]""", 1, 20))

@test length(arr) == 4
@test size(arr) == (4,)

for (i, v) in enumerate(arr)
    @test i == v
end

@test arr[1] == 1
@test arr[end] == 4

end # @testset "read.jl"

@testset "structs.jl" begin

arr = JSON3.read(SubString("""
[ 1,
  2,
  3,
  4
]""", 1, 20), Vector{Int})

@test length(arr) == 4
@test size(arr) == (4,)

for (i, v) in enumerate(arr)
    @test i == v
end

@test arr[1] == 1
@test arr[end] == 4

@test JSON3.write(arr) == "[1,2,3,4]"

x = JSON3.read("1", Union{Int, Missing})
@test x == 1

x = JSON3.read("null", Union{Int, Missing})
@test x === missing

x = JSON3.read("1", Union{Int, Float64})
@test x === 1.0

StructTypes.construct(::Type{JSON3.PointerString}, ptr::Ptr{UInt8}, len::Int) = JSON3.PointerString(ptr, len)
str = "\"hey\""
x = JSON3.read(str, JSON3.PointerString);
@test x == "hey"
@test typeof(x) == JSON3.PointerString
@test JSON3.write(x) == str

@test JSON3.read("\"apple\"", Fruit) == apple
@test_throws Union{UndefVarError, ArgumentError} JSON3.read("\"watermelon\"", Fruit)
@test JSON3.write(apple) == "\"apple\""

@test JSON3.read("\"apple\"", Symbol) == :apple
@test JSON3.write(:apple) == "\"apple\""

@test JSON3.read("true", Bool)
@test JSON3.read("false", Bool) === false
@test JSON3.write(true) == "true"
@test JSON3.write(false) == "false"

StructTypes.StructType(::Type{XInt}) = StructTypes.NumberType()
StructTypes.numbertype(::Type{XInt}) = Int64
StructTypes.construct(::Type{Int64}, x::XInt) = x.x
x = XInt(10)
@test JSON3.read("10", XInt) == x
@test JSON3.write(x) == "10"

@test JSON3.read("[1,2,3]", Array) == Any[1,2,3]
@test JSON3.write(Any[1,2,3]) == "[1,2,3]"
@test JSON3.read("[1,2,3]", Tuple) == (1,2,3)
@test JSON3.write((1,2,3)) == "[1,2,3]"
@test JSON3.read("[1,2,3]", Set) == Set([1,2,3])
@test JSON3.write(Set([1,2])) in ("[1,2]", "[2,1]")

@test JSON3.read("{\"a\": 1, \"b\": 2}", Dict) == Dict("a"=>1, "b"=>2)
@test JSON3.write(Dict("a"=>1, "b"=>2)) in ("{\"a\":1,\"b\":2}", "{\"b\":2,\"a\":1}")
@test JSON3.read("{\"a\": 1, \"b\": 2}", Dict{String, Any}) == Dict("a"=>1, "b"=>2)
@test JSON3.read("{\"a\": 1, \"b\": 2}", Dict{Symbol, Int}) == Dict(:a=>1, :b=>2)
@test JSON3.write(Dict(:a=>1, :b=>2)) in ("{\"a\":1,\"b\":2}", "{\"b\":2,\"a\":1}")
@test JSON3.read("{\"a\": 1, \"b\": 2}", NamedTuple) == (a=1, b=2)
@test JSON3.write((a=1, b=2)) == "{\"a\":1,\"b\":2}"
@test JSON3.read("{\"a\": 1, \"b\": 2}", NamedTuple{(:a, :b)}) == (a=1, b=2)
@test JSON3.read("{\"a\": 1, \"b\": 2}", NamedTuple{(:a,)}) == (a=1,)
@test JSON3.write((a=1,)) == "{\"a\":1}"
@test JSON3.read("{\"a\": 1, \"b\": 2}", NamedTuple{(:a, :b), Tuple{Int, Int}}) == (a=1, b=2)
@test JSON3.read("{\"a\": 1, \"b\": 2}", NamedTuple{(:a, :b), Tuple{Float64, Float64}}) == (a=1.0, b=2.0)
@test JSON3.write((a=1.0, b=2.0)) == "{\"a\":1.0,\"b\":2.0}"

mktemp() do path, io
    str = "{\"a\":1.0,\"b\":2.0}"
    write(io, str)
    obj =  JSON3.read(str)
    close(io)
    @test JSON3.read(path) == obj
    @test JSON3.read(path, Dict) == Dict("a" => 1.0, "b" => 2.0)
end

# Test that writing DictType works even when length(pairs(dict_type)) isn't
# available. Issue #37.
StructTypes.StructType(::Type{DictWithoutLength}) = StructTypes.DictType()
Base.pairs(x::DictWithoutLength) =
    Iterators.filter(x -> last(x) !== nothing, ("a" => 1, "b" => nothing))
@test JSON3.write(DictWithoutLength()) == "{\"a\":1}"

StructTypes.StructType(::Type{A}) = StructTypes.Struct()

obj = JSON3.read("""
{ "a": 1,
  "b": 2,
  "c": 3,
  "d": 4
}
""", A)

@test obj.a == 1
@test obj.d == 4

# test order doesn't matter
obj2 = JSON3.read("""
{ "d": 1,
  "b": 2,
  "c": 3,
  "a": 4
}
""", A)

@test obj2.d == 1
@test obj2.a == 4

@test_throws ArgumentError JSON3.read("", A)
@test_throws ArgumentError JSON3.read("a", A)
@test_throws ArgumentError JSON3.read("{a", A)
@test_throws ArgumentError JSON3.read("{\"a\"a", A)
@test_throws ArgumentError JSON3.read("{\"a\": 1a", A)
@test_throws ArgumentError JSON3.read("{\"a\": 1, a", A)
@test_throws ArgumentError JSON3.read("}", A)

# `JSON3.read!` should not work for immutable structs
@test_throws ArgumentError JSON3.read!("", A(1, 2, 3, 4))
@test_throws ArgumentError JSON3.read!("a", A(1, 2, 3, 4))
@test_throws ArgumentError JSON3.read!("{a", A(1, 2, 3, 4))
@test_throws ArgumentError JSON3.read!("{\"a\"a", A(1, 2, 3, 4))
@test_throws ArgumentError JSON3.read!("{\"a\": 1a", A(1, 2, 3, 4))
@test_throws ArgumentError JSON3.read!("{\"a\": 1, a", A(1, 2, 3, 4))
@test_throws ArgumentError JSON3.read!("}", A(1, 2, 3, 4))

@test JSON3.write(C()) == "\"C()\""
@test JSON3.write(ParametricSingleton{Int64}()) == "\"ParametricSingleton{Int64}()\""

@test_throws MethodError JSON3.read("{}", C)
StructTypes.StructType(::Type{C}) = StructTypes.Struct()

@test JSON3.read("{}", C) == C()
@test JSON3.write(obj) == "{\"a\":1,\"b\":2,\"c\":3,\"d\":4}"

StructTypes.StructType(::Type{D}) = StructTypes.OrderedStruct()
obj = JSON3.read("""
{ "a": 1,
  "b": 3.14,
  "c": "hey"
}
""", D)

@test obj.a == 1
@test obj.b == 3.14
@test obj.c == "hey"

# if order of fields is switched, error is thrown
@test_throws ArgumentError JSON3.read("""
{ "c": "hey",
  "b": 3.14,
  "a": 1
}
""", D)

@test JSON3.read("1", Union{String, Int}) == 1
@test JSON3.read("\"1\"", Union{String, Int}) == "1"
@test JSON3.read("null", Union{Int, String, Nothing}) === nothing
@test JSON3.read("1.0", Union{Float64, Int}) === 1.0

@test JSON3.read("1", Any) == 1
@test JSON3.read("3.14", Any) == 3.14
@test JSON3.read("\"a\"", Any) == "a"
@test JSON3.read("true", Any) === true
@test JSON3.read("false", Any) === false
@test JSON3.read("null", Any) === nothing
@test JSON3.read("[1,2,3]", Any) == [1,2,3]
@test JSON3.read("\"a\"", String) == "a"
@test JSON3.read("1", Int64) === Int64(1)
@test JSON3.read("3.14", Float64) === 3.14
@test JSON3.read("true", Bool) === true
@test JSON3.read("false", Bool) === false
@test JSON3.read("null", Nothing) === nothing
@test JSON3.read("null", Missing) === missing
@test JSON3.read("\"a\"", Char) == 'a'
@test JSON3.read("{\"a\": 1}", Any)["a"] == 1
@test JSON3.read("{\"a\": 1}", Dict{Symbol, Any})[:a] == 1
@test JSON3.read("[1,2,3]", Base.Array{Any}) == [1,2,3]
@test JSON3.read("[]", Vector{Any}) == []
@test JSON3.read("{}", Dict{Symbol, Any}) == Dict{Symbol, Any}()
@test JSON3.read("{\"a\":\"b\\/c\"}").a == "b/c"

@test_throws ArgumentError JSON3.read("hey", Any)
@test_throws ArgumentError JSON3.read("hey", String)
@test_throws ArgumentError JSON3.read("\"hey", String)
@test_throws ArgumentError JSON3.read("\"hey\\", String)
@test_throws ArgumentError JSON3.read("\"hey\\\\", String)
@test_throws ArgumentError JSON3.read("\"a", Char)
@test_throws ArgumentError JSON3.read("\"ab\"", Char)
@test_throws ArgumentError JSON3.read("trua", Bool)
@test_throws ArgumentError JSON3.read("tru", Bool)
@test_throws ArgumentError JSON3.read("fals", Bool)
@test_throws ArgumentError JSON3.read("falst", Bool)
@test_throws ArgumentError JSON3.read("f", Bool)
@test_throws ArgumentError JSON3.read("a1bc", Int)
@test_throws ArgumentError JSON3.read("a1.0b", Float64)
@test_throws ArgumentError JSON3.read("a1bc", Vector{Any})
@test_throws ArgumentError JSON3.read("[1,2n", Vector{Any})
@test_throws ArgumentError JSON3.read("a1bc", Dict{Symbol, Any})
@test_throws ArgumentError JSON3.read("{a1bc", Dict{Symbol, Any})
@test_throws ArgumentError JSON3.read("{\"a\"1bc", Dict{Symbol, Any})
@test_throws ArgumentError JSON3.read("{\"a\": 1bc", Dict{Symbol, Any})
@test_throws ArgumentError JSON3.read("{\"a\": 1, bc", Dict{Symbol, Any})

StructTypes.StructType(::Type{B}) = StructTypes.Mutable()

b = JSON3.read("""
{
    "d": 4,
    "b": 2,
    "a": 1,
    "c": 3
}""", B)

@test b.a == 1
@test b.b == 2
@test b.c == 3
@test b.d == 4

b = B()
JSON3.read!("""
{
    "d": 4,
    "b": 2,
    "a": 1,
    "c": 3
}""", b)

@test b.a == 1
@test b.b == 2
@test b.c == 3
@test b.d == 4

@test_throws ArgumentError JSON3.read("", B)
@test_throws ArgumentError JSON3.read("a", B)
@test_throws ArgumentError JSON3.read("{a", B)
@test_throws ArgumentError JSON3.read("{\"a\": 1b", B)
@test_throws ArgumentError JSON3.read("{\"a\": 1, b", B)
@test_throws ArgumentError JSON3.read("}", B)
b = JSON3.read("{}", B)
@test typeof(b) == B

@test_throws ArgumentError JSON3.read!("", B())
@test_throws ArgumentError JSON3.read!("a", B())
@test_throws ArgumentError JSON3.read!("{a", B())
@test_throws ArgumentError JSON3.read!("{\"a\": 1b", B())
@test_throws ArgumentError JSON3.read!("{\"a\": 1, b", B())
@test_throws ArgumentError JSON3.read!("}", B())
b = JSON3.read("{}", B)
@test typeof(b) == B

b = JSON3.read("""
{
    "d": 4,
    "b": 2,
    "a": 1,
    "c": 3,
    "e": 5
}""", B)

@test b.a == 1
@test JSON3.write(b) == "{\"a\":1,\"b\":2,\"c\":3,\"d\":4}"

b = B()
JSON3.read!("""
{
    "d": 4,
    "b": 2,
    "a": 1,
    "c": 3,
    "e": 5
}""", b)

@test b.a == 1
@test JSON3.write(b) == "{\"a\":1,\"b\":2,\"c\":3,\"d\":4}"

# Incremental updating of mutable structs with `JSON3.read!`
@testset "Incremental updating of mutable structs with `JSON3.read!`" begin
    b = B()
    b.a = 0
    b.b = 0
    b.c = 0
    b.d = 0

    @test b.a == 0
    @test b.b == 0
    @test b.c == 0
    @test b.d == 0

    foo = JSON3.read!("""
    {
        "b": 1
    }""", b)
    @test b.a == 0
    @test b.b == 1
    @test b.c == 0
    @test b.d == 0
    @test foo == b
    @test foo === b

    bar = JSON3.read!("""
    {
        "d": 30,
        "b": 20,
        "a": 10,
        "e": 40
    }""", b)
    @test b.a == 10
    @test b.b == 20
    @test b.c == 0
    @test b.d == 30
    @test bar == b
    @test bar === b

    baz = JSON3.read!("""
    {
        "d": 400,
        "b": 200,
        "a": 100,
        "c": 300,
        "e": 500
    }""", b)
    @test b.a == 100
    @test b.b == 200
    @test b.c == 300
    @test b.d == 400
    @test baz == b
    @test baz === b
end

StructTypes.names(::Type{B}) = ((:a, :z),)
b = JSON3.read("""
{
    "d": 4,
    "b": 2,
    "z": 1,
    "c": 3,
    "e": 5
}""", B)

@test b.a == 1
@test JSON3.write(b) == "{\"z\":1,\"b\":2,\"c\":3,\"d\":4}"

StructTypes.excludes(::Type{B}) = (:c, :d)
b = JSON3.read("""
{
    "d": 4,
    "b": 2,
    "z": 1,
    "c": 3,
    "e": 5
}""", B)
@test JSON3.write(b) == "{\"z\":1,\"b\":2}"

StructTypes.StructType(::Type{Vehicle}) = StructTypes.AbstractType()
StructTypes.subtypes(::Type{Vehicle}) = (car=Car, truck=Truck)

StructTypes.StructType(::Type{Car}) = StructTypes.Struct()
StructTypes.StructType(::Type{Truck}) = StructTypes.Struct()

car = JSON3.read("""
{
    "type": "car",
    "make": "Mercedes-Benz",
    "model": "S500",
    "seatingCapacity": 5,
    "topSpeed": 250.1
}""", Vehicle)

@test typeof(car) == Car
@test car.make == "Mercedes-Benz"
@test car.topSpeed === 250.1
@test JSON3.write(car) == "{\"type\":\"car\",\"make\":\"Mercedes-Benz\",\"model\":\"S500\",\"seatingCapacity\":5,\"topSpeed\":250.1}"

truck = JSON3.read("""
{
    "type": "truck",
    "make": "Isuzu",
    "model": "NQR",
    "payloadCapacity": 7500.5
}""", Vehicle)

@test typeof(truck) == Truck
@test truck.make == "Isuzu"
@test truck.payloadCapacity == 7500.5
@test JSON3.write(truck) == "{\"type\":\"truck\",\"make\":\"Isuzu\",\"model\":\"NQR\",\"payloadCapacity\":7500.5}"

@test_throws ArgumentError JSON3.read("", Vehicle)
@test_throws ArgumentError JSON3.read("a", Vehicle)
@test_throws ArgumentError JSON3.read("{a", Vehicle)
@test_throws ArgumentError JSON3.read("{}", Vehicle)
@test_throws ArgumentError JSON3.read("{\"a\"a", Vehicle)
@test_throws ArgumentError JSON3.read("{\"a\": 1a", Vehicle)
@test_throws ArgumentError JSON3.read("{\"a\": 1, a", Vehicle)
@test_throws ArgumentError JSON3.read("{\"a\": 1}", Vehicle)

StructTypes.StructType(::Type{Vehicle2}) = StructTypes.AbstractType()
StructTypes.subtypes(::Type{Vehicle2}) = (Car2=Car2,)
StructTypes.StructType(::Type{Car2}) = StructTypes.Mutable()
car2 = JSON3.read("""
{
    "topSpeed": 250.1,
    "model": "S500",
    "make": "Mercedes-Benz",
    "seatingCapacity": 5
}""", Vehicle2)

@test typeof(car2) == Car2
@test car2.make == "Mercedes-Benz"
@test car2.topSpeed === 250.1
@test JSON3.write(car2) == "{\"make\":\"Mercedes-Benz\",\"model\":\"S500\",\"seatingCapacity\":5,\"topSpeed\":250.1}"

StructTypes.StructType(::Type{Expression}) = StructTypes.AbstractType()
StructTypes.subtypes(::Type{Expression}) = (AND=AndFunction, LITERAL=LiteralValue)
StructTypes.subtypekey(::Type{Expression}) = :exprType

StructTypes.StructType(::Type{AndFunction}) = StructTypes.Struct()
StructTypes.StructType(::Type{LiteralValue}) = StructTypes.Struct()

expr = JSON3.read("""
{
    "exprType": "AND",
    "lhs": {
        "exprType": "LITERAL",
        "value": 3.14
    },
    "rhs": {
        "exprType": "AND",
        "lhs": {
            "exprType": "LITERAL",
            "value": null
        },
        "rhs": {
            "exprType": "LITERAL",
            "value": "hey"
        }
    }
}
""", Expression)
@test expr.exprType == "AND"
@test JSON3.write(expr) == "{\"exprType\":\"AND\",\"lhs\":{\"exprType\":\"LITERAL\",\"value\":3.14},\"rhs\":{\"exprType\":\"AND\",\"lhs\":{\"exprType\":\"LITERAL\",\"value\":null},\"rhs\":{\"exprType\":\"LITERAL\",\"value\":\"hey\"}}}"

@test JSON3.write(Int64) == "\"Int64\""
@test JSON3.write(Float64) == "\"Float64\""
@test JSON3.write(String) == "\"String\""
@test startswith(JSON3.write(Dict{Symbol, Any}), "\"Dict{Symbol,")
@test JSON3.write(Bool) == "\"Bool\""
@test JSON3.write(Nothing) == "\"Nothing\""
@test JSON3.write(Missing) == "\"Missing\""
@test JSON3.write(A) == "\"A\""
@test JSON3.write(B) == "\"B\""
@test JSON3.write(Vehicle) == "\"Vehicle\""

StructTypes.StructType(::Type{LotsOfFields}) = StructTypes.Struct()
lotsoffields = LotsOfFields(fill("hey", 35)...)
jlots = JSON3.write(lotsoffields)
@test jlots == "{\"x1\":\"hey\",\"x2\":\"hey\",\"x3\":\"hey\",\"x4\":\"hey\",\"x5\":\"hey\",\"x6\":\"hey\",\"x7\":\"hey\",\"x8\":\"hey\",\"x9\":\"hey\",\"x10\":\"hey\",\"x11\":\"hey\",\"x12\":\"hey\",\"x13\":\"hey\",\"x14\":\"hey\",\"x15\":\"hey\",\"x16\":\"hey\",\"x17\":\"hey\",\"x18\":\"hey\",\"x19\":\"hey\",\"x20\":\"hey\",\"x21\":\"hey\",\"x22\":\"hey\",\"x23\":\"hey\",\"x24\":\"hey\",\"x25\":\"hey\",\"x26\":\"hey\",\"x27\":\"hey\",\"x28\":\"hey\",\"x29\":\"hey\",\"x30\":\"hey\",\"x31\":\"hey\",\"x32\":\"hey\",\"x33\":\"hey\",\"x34\":\"hey\",\"x35\":\"hey\"}"
@test JSON3.read(jlots, LotsOfFields) == lotsoffields
jlots = "{\"x1\":\"1\",\"x11\":\"11\",\"x2\":\"2\",\"x12\":\"12\",\"x3\":\"3\",\"x13\":\"13\",\"x4\":\"4\",\"x14\":\"14\",\"x5\":\"5\",\"x15\":\"15\",\"x6\":\"6\",\"x16\":\"16\",\"x7\":\"7\",\"x17\":\"17\",\"x8\":\"8\",\"x18\":\"18\",\"x9\":\"9\",\"x19\":\"19\",\"x10\":\"10\",\"x20\":\"20\",\"x26\":\"26\",\"x27\":\"27\",\"x28\":\"28\",\"x29\":\"29\",\"x30\":\"30\",\"x21\":\"21\",\"x22\":\"22\",\"x23\":\"23\",\"x24\":\"24\",\"x25\":\"25\",\"x35\":\"35\",\"x34\":\"34\",\"x33\":\"33\",\"x32\":\"32\",\"x31\":\"31\"}"
@test JSON3.read(jlots, LotsOfFields) == LotsOfFields(string.(collect(1:35))...)

StructTypes.StructType(::Type{Wrapper}) = StructTypes.CustomStruct()
StructTypes.lower(x::Wrapper) = x.x
StructTypes.lowertype(::Type{Wrapper}) = fieldtype(Wrapper, :x)
w = Wrapper((a=1, b="hey"))
json = JSON3.write(w)
@test json == "{\"a\":1,\"b\":\"hey\"}"
@test JSON3.read(json, Wrapper) == w

end # @testset "structs.jl"

@testset "show.jl" begin

@test repr(JSON3.read("{}")) == "{}"
@test repr(JSON3.read("{\"a\": 1}")) == "{\n   \"a\": 1\n}"
@test repr(JSON3.read("{\"a\": {\"b\": 2}}")) == "{\n   \"a\": {\n           \"b\": 2\n        }\n}"
# @test repr(JSON3.read("[]")) == "[]"
# @test repr(JSON3.read("[1,2,3]")) == "[\n  1,\n  2,\n  3\n]"
# @test repr(JSON3.read("[1,[2.1,2.2,2.3],3]")) == "[\n  1,\n  [\n    2.1,\n    2.2,\n    2.3\n  ],\n  3\n]"

end # @testset "show.jl"

include("json.jl")

# more tests for coverage
obj = JSON3.read("{\"hey\":1}")
@test get(obj, Int, :hey) == 1
@test get(obj, Int, :ho, 2) == 2

@test JSON3.read("{\"hey\":1}") == JSON3.read(b"{\"hey\":1}") == JSON3.read(IOBuffer("{\"hey\":1}"))

arr = JSON3.read("[\"hey\",1, null, false, \"ho\", {\"a\": 1}, 2]")
@test Base.IndexStyle(arr) == Base.IndexLinear()
@test arr[7] == 2

str = "hey"
ptr = JSON3.PointerString(pointer(str), 3)
@test hash(str) == hash(ptr)
@test codeunit(ptr) == UInt8
@test StructTypes.names(1) == ()
@test StructTypes.names(Any) == ()
@test StructTypes.excludes(1) == ()
@test StructTypes.excludes(Any) == ()
@test StructTypes.omitempties(1) == ()
@test StructTypes.omitempties(Any) == ()

@test StructTypes.subtypekey(1) == :type
@test StructTypes.subtypekey(Any) == :type
@test StructTypes.subtypes(1) == NamedTuple()
@test StructTypes.subtypes(Any) == NamedTuple()

@test JSON3.read(b"\"a\"", String) == "a"
@test JSON3.read(IOBuffer("\"a\""), String) == "a"
@test StructTypes.StructType(Char) == StructTypes.StringType()
@test StructTypes.construct(String, "hey") == "hey"
@test StructTypes.StructType(Bool) == StructTypes.BoolType()
@test StructTypes.construct(Bool, true) === true
@test StructTypes.StructType(UInt8) == StructTypes.NumberType()
@test StructTypes.numbertype(UInt8) == UInt8
@test StructTypes.numbertype(1) == Float64
@test StructTypes.construct(String, "hey") == "hey"
@test StructTypes.StructType(typeof((1,2))) == StructTypes.ArrayType()
x = Dict(:hey=>1)
@test StructTypes.construct(Dict{Symbol, Any}, x) == x

@test JSON3.gettapelen(Int64) == 2
@test JSON3.regularstride(Missing) == false
@test JSON3.regularstride(Int64) == true
@test JSON3.regularstride(Union{Int64, Float64}) == true
@test JSON3.getvalue(Nothing, [], [], 1, 2) === nothing
@test JSON3.defaultminimum(nothing) == 4
@test JSON3.defaultminimum(Int64) == 16
@test JSON3.defaultminimum('1') == 3

# https://github.com/quinnj/JSON3.jl/issues/1
txt = """
{ "a" : { "b" : [ 1, 2 ],
          "c" : [ 3, 4 ] } }
"""

@test JSON3.read(txt).a.b == [1,2]

# https://github.com/quinnj/JSON3.jl/issues/8
@test eltype(JSON3.read("[1.2, 2.0]")) === Float64
@test eltype(JSON3.read("[1.2, 2.0, 3.3]")) === Float64
@test eltype(JSON3.read("[1.2, null, 3.3]")) === Union{Float64, Nothing}
@test eltype(JSON3.read("[1.2, null, 3.0]")) === Union{Float64, Nothing}

# https://github.com/quinnj/JSON3.jl/issues/9
d = Dict(uuid1() => i for i in 1:3)
t = JSON3.write(d)
@test JSON3.read(t, Dict{UUID, Int}) == d
u = uuid1()
@test JSON3.read(JSON3.write(u), UUID) == u

d = Date(2019, 11, 16)
@test JSON3.read(JSON3.write(d), Date) == d
df = dateformat"dd-mm-yyyy"
@test JSON3.read(JSON3.write(d; dateformat=df), Date; dateformat=df) == d

# get issue
obj = JSON3.read("{\"hey\":1}")
@test get(obj, :hey) == get(obj, "hey") == get(obj, "hey", "") == get(()->"", obj, "hey")

# copy issue
obj = JSON3.read("{\"a\":\"b\", \"b\":null, \"c\":[null,null]}")
@test copy(obj) == Dict(:a => "b", :b => nothing, :c => [nothing, nothing])

# better Tuple reading support
@test JSON3.read("[\"car\",\"Mercedes\"]", Tuple{Symbol, String}) == (:car, "Mercedes")
@test JSON3.read("[\"hey\",\"hey\",\"hey\",\"hey\",\"hey\",\"hey\",\"hey\",\"hey\",\"hey\",\"hey\",\"hey\",\"hey\",\"hey\",\"hey\",\"hey\",\"hey\",\"hey\",\"hey\",\"hey\",\"hey\",\"hey\",\"hey\",\"hey\",\"hey\",\"hey\",\"hey\",\"hey\",\"hey\",\"hey\",\"hey\",\"hey\",\"hey\",\"hey\",\"hey\",\"hey\"]", NTuple{35, String}) ==
    ("hey", "hey", "hey", "hey", "hey", "hey", "hey", "hey", "hey", "hey", "hey", "hey", "hey", "hey", "hey", "hey", "hey", "hey", "hey", "hey", "hey", "hey", "hey", "hey", "hey", "hey", "hey", "hey", "hey", "hey", "hey", "hey", "hey", "hey", "hey")

StructTypes.StructType(::Type{data}) = StructTypes.Struct()
@test JSON3.read("{\"t\":[\"car\",\"Mercedes\"]}", data) == data((:car, "Mercedes"))

# new StructTypes.keywordargs option
StructTypes.StructType(::Type{DateStruct}) = StructTypes.Mutable()
StructTypes.keywordargs(::Type{DateStruct}) = (date=(dateformat=dateformat"dd-mm-yyyy",), datetime=(dateformat=dateformat"dd-mm-yyyy HH:MM:SS",), time=(dateformat=dateformat"HH MM SS",))
ds = DateStruct(Date(2019, 11, 16), DateTime(2019, 11, 16, 1, 25), Time(1, 26))
@test JSON3.write(ds) == "{\"date\":\"16-11-2019\",\"datetime\":\"16-11-2019 01:25:00\",\"time\":\"01 26 00\"}"
ds2 = JSON3.read(JSON3.write(ds), DateStruct)
@test ds.date == ds2.date && ds.datetime == ds2.datetime && ds.time == ds2.time

# 63
@test JSON3.read(JSON3.write([Symbol("before \" after")])) == ["before \" after"]

# @pretty
@testset "pretty.jl" begin
io = IOBuffer()
JSON3.pretty(io, 3.14)
@test String(take!(io)) == "3.14"
JSON3.pretty(io, "hey")
@test String(take!(io)) == "hey"
JSON3.pretty(io, "{}")
@test String(take!(io)) == "{\n}"
JSON3.pretty(io, "[]")
@test String(take!(io)) == "[\n]"
JSON3.pretty(io, (a=1, b=true, c=3.14, d="hey", e=(abcdefghijklmnopqrstuvwxyz=1000, aa=1e8, dd=[nothing, nothing, nothing, 3.14])), JSON3.AlignmentContext(alignment=:Colon, indent=2))
@test String(take!(io)) == """{
   "a": 1,
   "b": true,
   "c": 3.14,
   "d": "hey",
   "e": {
           "abcdefghijklmnopqrstuvwxyz": 1000,
                                   "aa": 100000000,
                                   "dd": [
                                           null,
                                           null,
                                           null,
                                           3.14
                                         ]
        }
}"""
JSON3.pretty(io, (a=1, b=true, c=3.14, d="hey", e=(abcdefghijklmnopqrstuvwxyz=1000, aa=1e8, dd=[nothing, nothing, nothing, 3.14])))
@test String(take!(io)) == """{
    "a": 1,
    "b": true,
    "c": 3.14,
    "d": "hey",
    "e": {
        "abcdefghijklmnopqrstuvwxyz": 1000,
        "aa": 100000000,
        "dd": [
            null,
            null,
            null,
            3.14
        ]
    }
}"""
JSON3.pretty(io, (a=1, b=D(1, 3.14, "cool")), JSON3.AlignmentContext(alignment=:Colon, indent=2))
@test String(take!(io)) == """{
   "a": 1,
   "b": {
           "a": 1,
           "b": 3.14,
           "c": "cool"
        }
}"""
JSON3.pretty(io, (a=1, b=D(1, 3.14, "cool")))
@test String(take!(io)) == """{
    "a": 1,
    "b": {
        "a": 1,
        "b": 3.14,
        "c": "cool"
    }
}"""

# 77
io = IOBuffer()
JSON3.pretty(io,  JSON3.write(Dict( "x" => Inf64), allow_inf=true), allow_inf=true )
@test String(take!(io)) == "{\n    \"x\": Infinity\n}"

end # @testset "pretty.jl"

# parsequoted
@test JSON3.read("{\"a\":\"10\",\"b\":\"1\",\"c\":\"45\",\"d\":\"100\"}", A; parsequoted=true) == A(10, 1, 45, 100)

json = "{\"a\": 1, \"b\": 2}\n{\"a\": 3, \"b\": 4}"
x = JSON3.read(json; jsonlines=true)
@test length(x) == 2
@test all(values(x[1]) .== (1, 2))

json = "1\r\n2\r\n3\r\n4\r\n5\r\n"
x = JSON3.read(json; jsonlines=true)
@test length(x) == 5
@test x == [1, 2, 3, 4, 5]

json = "1"
x = JSON3.read(json; jsonlines=true)
@test length(x) == 1
@test x == [1]

json = "  1\r\n\t2"
x = JSON3.read(json; jsonlines=true)
@test length(x) == 2
@test x == [1, 2]

# 171
for d_jsonl in [
    """
    { "a": 1,  "b": 3.14,  "c": "hey" }
    { "a": 2,  "b": 6.28,  "c": "hi"  }
    """,
    # No newline at end
    """
    { "a": 1,  "b": 3.14,  "c": "hey" }
    { "a": 2,  "b": 6.28,  "c": "hi"  }""",
    # No newline, extra whitespace at end
    """
    { "a": 1,  "b": 3.14,  "c": "hey" }
    { "a": 2,  "b": 6.28,  "c": "hi"  }   """,
    # Whitespace at start of line
    """
      { "a": 1,  "b": 3.14,  "c": "hey" }
      { "a": 2,  "b": 6.28,  "c": "hi"  }
    """,
    # Extra whitespace at beginning, end of lines, end of string
    " { \"a\": 1,  \"b\": 3.14,  \"c\": \"hey\" }  \n" *
    "  { \"a\": 2,  \"b\": 6.28,  \"c\": \"hi\"  }  \n  ",
]
    for nl in ["\n", "\r", "\r\n"]
        d_jsonl = replace(d_jsonl, "\n" => nl)
        dss = JSON3.read(d_jsonl, Vector{D}, jsonlines=true)

        @test length(dss) == 2
        @test dss[1].a == 1
        @test dss[1].b == 3.14
        @test dss[1].c == "hey"
        @test dss[2].a == 2
        @test dss[2].b == 6.28
        @test dss[2].c == "hi"

    end
end

# allow_inf consistency
@test_throws ArgumentError JSON3.read("-Infinity")

# https://discourse.julialang.org/t/json3-jl-parse-custom-type-with-nan/61295
str = JSON3.write(NaNStruct(NaN); allow_inf=true)
@test JSON3.read(str, NaNStruct; allow_inf=true).x === NaN

# https://github.com/quinnj/JSON3.jl/issues/172
@test JSON3.read("true", Union{Bool, Int})
@test JSON3.read("42", Union{Bool, Float64}) === 42.0

# https://github.com/quinnj/JSON3.jl/issues/187
x = System(duration=3600.0)
@test roundtrip(x).duration == x.duration

include("gentypes.jl")
include("stringnumber.jl")

# https://github.com/JuliaData/StructTypes.jl/issues/85
struct Struct1
    iarr::Vector{Integer}
end

StructTypes.StructType(::Type{Struct1}) = StructTypes.Struct()

s1 = Struct1([1,2,3,4,5]);
iob = IOBuffer();
JSON3.write(iob, s1);
s1_json = String(take!(iob))
s2 = JSON3.read(s1_json, Struct1)
@test s1.iarr == s2.iarr

# https://github.com/quinnj/JSON3.jl/issues/232
@test JSON3.write(3//2) == "1.5"
@test JSON3.write(π) == "3.141592653589793"

# https://github.com/quinnj/JSON3.jl/issues/242
@test JSON3.write(BigInt(-3)) == "-3"

# tests that we handle #undef correctly
x = UndefGuy()
x.id = 10
@test JSON3.write(x) == "{\"id\":10}"

y = Vector{UndefGuy}(undef, 2)
y[1] = x
@test JSON3.write(y) == "[{\"id\":10},null]"

# Arrow tests require a 64 bit system
@static if isdefined(Base, :get_extension) && Sys.WORD_SIZE == 64
    @testset "Arrow" include("arrow.jl")
end

# https://github.com/quinnj/JSON3.jl/issues/296
struct TypeWithoutExtraField
    a::Int
end
string_with_extra_field = "{\"a\": 1, \"b\": 2}"
@test JSON3.read(string_with_extra_field, TypeWithoutExtraField) == TypeWithoutExtraField(1)
@test_throws ArgumentError JSON3.read(string_with_extra_field, TypeWithoutExtraField, ignore_extra_fields=false)

end # @testset "JSON3"
