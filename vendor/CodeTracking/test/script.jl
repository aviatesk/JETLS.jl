# NOTE: tests are sensitive to the line number at which statements appear
function f1(x, y)
    # A comment
    return x + y
end

@noinline function throws()
    x = nothing
    error("oops")
end
@inline inlined() = throws()
call_throws() = inlined()

f2(x, y) = x + y

@inline function multilinesig(x::Int,
                              y::String)
    z = x + 1
    return z
end

function f50()   # issue #50
    todB(x) = 10*log10(x)
    println("100x is $(todB(100)) dB.")
end

func_1st_nokwarg() = true
func_2nd_kwarg(a, b; kw=2) = true

module Foo
module Bar
function fit end
end
end

function Foo.Bar.fit(m)
    return m
end

Foo.Bar.fit(a, b) = a + b

# Issue #81
function hasrettype(x::Real)::Float32
    return x*x + x
end

function fkw(; x=1)
    x
end

# Issue #80
f80 = x -> 2 * x^3 + 1
f80_2 = (x, y) -> x*y

# Issue #103
if isdefined(Base, Symbol("@assume_effects"))
    @eval begin
        Base.@assume_effects :terminates_locally  function pow103(x)
            # this :terminates_locally allows `pow` to be constant-folded
            res = 1
            1 < x < 20 || error("bad pow")
            while x > 1
                res *= x
                x -= 1
            end
            return res
        end
    end
end

has_semicolon1(x, y) = x + y;

struct LikeNamedTuple{names,V}
    vals::V
end

LikeNamedTuple() = LikeNamedTuple{(),Tuple{}}(())

LikeNamedTuple{names}(args::Tuple) where {names} = LikeNamedTuple{names,typeof(args)}(args)

# Test @eval-ed methods
# This is taken from the definition of `sin(::Int)` in Base, copied here for testing purposes
# in case the implementation changes. Also added a (useless) kw.
for f in (:mysin,)
    @eval function ($f)(x::Real; return_zero::Bool=false)
        xf = float(x)
        x === xf && throw(MethodError($f, (x,)))
        return ($f)(xf)
    end
end
mysin(x::AbstractFloat) = sin(x)
let args = [:(y::Real), :(x::Real)]
    @eval dollaratan($(args...)) = atan(y, x)
    @eval hasthreeargs($(args...), z::Bool) = x + y + z
end

unnamedarg(::Type{String}, x) = string(x)   # see more unnamed on line 108

# "decorated" args
nospec(@nospecialize(x)) = 2x
nospec2(@nospecialize(x::AbstractVecOrMat)) = first(x)
nospec3(name::Symbol, @nospecialize(arg=nothing)) = name
withva(a...) = length(a)
hasdefault(xd, yd=2) = xd + yd
hasdefaulttypearg(::Type{T}=Rational{Int}) where T = zero(T)

# tuple-destructuring
diffminmax((min, max)) = max - min

# _ args
struct Nowhere end
mypush!(::Nowhere, _) = nothing

# global
let
    global inlet(x) = x^2
end

# Callables
struct Gaussian
    σ::Float64
end
(g::Gaussian)(x) = exp(-x^2 / (2*g.σ^2)) / (sqrt(2*π)*g.σ)
struct Invert end
(::Invert)(v::AbstractVector{Bool}) = (!).(v)
(::Type{T})(itr) where {T<:Invert} = [!x for x in itr]

# USERID gets parsed into a Symbol
struct symbol_struct2
    USERID
end; '\n' ;symbol_function(x) = x

# https://github.com/JuliaDebug/Cthulhu.jl/issues/470
# (arguments with evaled-names)
let argnames = :args
    eval(quote
        function c470($argnames...)
            return $argnames
        end
    end)
end

wrongline() = 1    # for use testing #124
only(methods(wrongline)).line = 9999   # unclear how it happened in the wild, but this at least catches the problem

# Nested `where`s
struct Parametric{N} end
(::Type{P})(x::Int) where P<:Parametric{N} where N = P()

# `where`s that are not simply `(::Type{T})(args...) where T<:SomeSpecialType`
struct MyArray1{T,N}
    data::T
end
function (self::Type{MyArray1{T,1}})(::UndefInitializer, m::Int) where {T}
    return nothing
end
struct MyArray2{T,N}
    data::T
end
function (::Type{MyArray2{T,1}})(::UndefInitializer, m::Int) where {T}
    return nothing
end

# Issue #115
struct MyNamedTuple{names, T} end
@eval (MyNamedTuple{names, T}(args::T) where {names, T <: Tuple}) = begin
    $(Expr(:splatnew, :(MyNamedTuple{names, T}), :args))
end
