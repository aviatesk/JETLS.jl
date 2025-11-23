abstract type StructParent{T,N} <: AbstractArray{T,N} end
struct Struct{T} <: StructParent{T,1}
    x::Vector{T}
end
primitive type MyInt8 <: Integer 8 end
MyInt8(x::Integer) = Base.bitcast(MyInt8, convert(Int8, x))

myint = MyInt8(2)

const TypeAlias = Float32

# Methods and signatures
f1(x::Int) = 1
f1(x) = 2
f1(x::TypeAlias) = 3
# where signatures
f2(x::T) where T = -1
f2(x::T) where T<:Integer = T
f2(x::T) where Unsigned<:T<:Real = 0
f2(x::V) where V<:SubArray{T} where T = 2
f2(x::V) where V<:Array{T,N} where {T,N} = 3
f2(x::V) where V<:Base.ReshapedArray{T,N} where T where N = 4
# Varargs
f3(x::Int, y...) = 1
f3(x::Int, y::Symbol...) = 2
f3(x::T, y::U...) where {T<:Integer,U} = U
f3(x::Array{Float64,K}, y::Vararg{Symbol,K}) where K = K
# Default args
f4(x, y=0) = 1
f4(x, y::Int) = 2
f4(x::UInt, y="hello", z::Int=0) = 3
f4(x::Array{Float64,K}, y::Int=0) where K = K
# Keyword args
f5(x::Int8; y=0) = y
f5(x::Int16; y::Int=0) = 2
f5(x::Int32; y="hello", z::Int=0) = 3
f5(x::Int64;) = 4
f5(x::Array{Float64,K}; y::Int=0) where K = K
# Default and keyword args
f6(x, y="hello"; z::Int=0) = 1
# Destructured args
f7(x, (count, name)) = 1
# Return-type annotations
f8(x)::Int = 1
# generated functions
@generated function f9(x)
    if x <: Integer
        return :(x ^ 2)
    else
        return :(x)
    end
end
# Call overloading
(i::Struct)(::String) = i.x
(::Type{Struct{T}})(::Dict) where T = sizeof(T)

const first_two_funcs = (f1, f2)

# Conditional methods
if false
    ffalse(x) = 2
end
if true
    ftrue(x) = 3
end

if 0.8 > 0.2
    fctrue(x) = 1
else
    fcfalse(x) = 1
end

module Consts
export b1
b1 = true
b2 = false
g() = 2
end
using .Consts
if b1
    fb1true(x) = 1
else
    fb1false(x) = 1
end
if Consts.b2
    fb2true(x) = 1
else
    fb2false(x) = 1
end

if @isdefined(sum)
    fstrue(x) = 1
end

# Inner methods
function fouter(x)
    finner(::Float16) = 2x
    return finner(Float16(1))
end

## Evaled methods
for T in (Float32, Float64)
    @eval feval1(::$T) = 1
end
for T1 in (Float32, Float64), T2 in (Int8,)
    @eval feval2(::$T1, ::$T2) = 2
end
for f in (:length, :size)
    @eval Base.$f(i::Struct, args...) = nothing
end
for (T, v) in Dict(Float32=>4, Float64=>8)
    @eval nbytes(::Type{$T}) = $v
end
for x in (1, 1.1)
    @eval typestring(::$(typeof(x))) = $(string(typeof(x)))
end
for name in (:feval3,)
    _f = Symbol("_", name)
    @eval ($_f)(arg) = 3
end
const opnames = Dict{Symbol, Symbol}(:+ => :add, :- => :sub)
for op in [:+, :-, :max, :min]
    opname = get(opnames, op, op)
    @eval $(Symbol("feval_", opname, "!"))(var) = 1
end

# Methods with @isdefined
struct NoParam end
myeltype(::Type{Vector{T}}) where T = @isdefined(T) ? T : NoParam
paramtype(::Type{V}) where V<:Vector = isa(V, UnionAll) ? myeltype(Base.unwrap_unionall(V)) : myeltype(V)

## Submodules
module Inner
g() = 5
module InnerInner
g() = 6
end
end

module DatesMod
    abstract type Period end
end

struct Beat <: DatesMod.Period
    value::Int64
end

module Empty end
