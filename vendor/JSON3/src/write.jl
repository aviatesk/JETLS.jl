defaultminimum(::Union{Nothing, Missing}) = 4
defaultminimum(::Number) = 20
defaultminimum(::T) where {T <: Base.IEEEFloat} = Parsers.neededdigits(T)
defaultminimum(x::Bool) = ifelse(x, 4, 5)
defaultminimum(x::AbstractString) = ncodeunits(x) + 2
defaultminimum(x::Symbol) = ccall(:strlen, Csize_t, (Cstring,), x) + 2
defaultminimum(x::Enum) = 16
defaultminimum(::Type{T}) where {T} = 16
defaultminimum(x::Char) = 3
defaultminimum(x::Union{Tuple, AbstractSet}) = isempty(x) ? 2 : sum(defaultminimum, x)
defaultminimum(x::AbstractArray) = isempty(x) ? 2 : sum(defaultminimum, (isassigned(x, i) ? defaultminimum(x[i]) : 4 for i in eachindex(x)))
defaultminimum(x::Union{AbstractDict, NamedTuple, Pair}) = isempty(x) ? 2 : sum(defaultminimum(k) + defaultminimum(v) for (k, v) in StructTypes.keyvaluepairs(x))
defaultminimum(x) = max(2, sizeof(x))

"""
    JSON3.write([io], x; kw...)

Write JSON.

## Args

* `io`: Optionally, an `IO` object to write the resulting JSON string to.  By default, will return a `String` if `io` is not provided.
* `x`: An object to serialize as JSON.  If not a [built in type](#Builtin-types), must have a "struct mapping" registered with [StructTypes.jl](#Struct-API).

## Keyword Args

* `allow_inf`: Allow writing of `Inf` and `NaN` values (not part of the JSON standard). [default `false`]
* `dateformat`: A [`DateFormat`](https://docs.julialang.org/en/v1/stdlib/Dates/#Dates.DateFormat) describing how to format `Date`s in the object. [default `Dates.default_format(T)`]
"""
function write(io::IO, obj::T; kw...) where {T}
    len = defaultminimum(obj)
    buf = Base.StringVector(len)
    buf, pos, len = write(StructType(obj), buf, 1, length(buf), obj; kw...)
    return Base.write(io, resize!(buf, pos - 1))
end

function write(obj::T; kw...) where {T}
    len = defaultminimum(obj)
    buf = Base.StringVector(len)
    buf, pos, len = write(StructType(obj), buf, 1, length(buf), obj; kw...)
    return String(resize!(buf, pos - 1))
end

function write(fname::String, obj::T; kw...) where {T}
    open(fname, "w") do io
        write(io, obj; kw...)
    end
    fname
end

@noinline function realloc!(buf, len, n)
    # println("re-allocing...")
    new = zeros(UInt8, max(n, trunc(Int, len * 1.25)))
    copyto!(new, 1, buf, 1, len)
    return new, length(new)
end

macro check(n)
    esc(quote
        if (pos + $n - 1) > len
            buf, len = realloc!(buf, len, pos + $n - 1)
        end
    end)
end

macro writechar(chars...)
    block = quote
        @check($(length(chars)))
    end
    for c in chars
        push!(block.args, quote
            @inbounds buf[pos] = UInt8($c)
            pos += 1
        end)
    end
    #println(macroexpand(@__MODULE__, block))
    return esc(block)
end

# we need to special-case writing Type{T} because of ambiguities w/ StructTypes
write(::Struct, buf, pos, len, ::Type{T}; kw...) where {T} = write(StringType(), buf, pos, len, Base.string(T))
write(::Mutable, buf, pos, len, ::Type{T}; kw...) where {T} = write(StringType(), buf, pos, len, Base.string(T))
write(::DictType, buf, pos, len, ::Type{T}; kw...) where {T} = write(StringType(), buf, pos, len, Base.string(T))
write(::ArrayType, buf, pos, len, ::Type{T}; kw...) where {T} = write(StringType(), buf, pos, len, Base.string(T))
write(::StringType, buf, pos, len, ::Type{T}; kw...) where {T} = write(StringType(), buf, pos, len, Base.string(T))
write(::NumberType, buf, pos, len, ::Type{T}; kw...) where {T} = write(StringType(), buf, pos, len, Base.string(T))
write(::NullType, buf, pos, len, ::Type{T}; kw...) where {T} = write(StringType(), buf, pos, len, Base.string(T))
write(::BoolType, buf, pos, len, ::Type{T}; kw...) where {T} = write(StringType(), buf, pos, len, Base.string(T))
write(::AbstractType, buf, pos, len, ::Type{T}; kw...) where {T} = write(StringType(), buf, pos, len, Base.string(T))
write(::SingletonType, buf, pos, len, ::Type{T}; kw...) where {T} = write(StringType(), buf, pos, len, Base.string(T))
write(::NoStructType, buf, pos, len, ::Type{T}; kw...) where {T} = write(StringType(), buf, pos, len, Base.string(T))

write(::NoStructType, buf, pos, len, ::T; kw...) where {T} = throw(ArgumentError("$T doesn't have a defined `StructTypes.StructType`"))

@inline function write(::RawType, buf, pos, len, x::T; kw...) where {T}
    bytes = rawbytes(x)
    @check length(bytes)
    for b in bytes
        @inbounds buf[pos] = b
        pos += 1
    end
    return buf, pos, len
end

mutable struct WriteClosure{T, KW}
    buf::T
    pos::Int
    len::Int
    afterfirst::Bool
    kw::KW
end

@inline function (f::WriteClosure)(i, nm, TT, v; kw...)
    buf, pos, len = f.buf, f.pos, f.len
    if f.afterfirst
        @writechar ','
    else
        f.afterfirst = true
    end
    kw2 = merge(values(kw), f.kw)
    buf, pos, len = write(StringType(), buf, pos, len, nm; kw2...)
    @writechar ':'
    buf, pos, len = write(StructType(v), buf, pos, len, v; kw2...)
    f.buf = buf
    f.pos = pos
    f.len = len
    return
end

# generic object writing
@inline function write(::Union{Struct, Mutable}, buf, pos, len, x::T; kw...) where {T}
    @writechar '{'
    c = WriteClosure(buf, pos, len, false, values(kw))
    StructTypes.foreachfield(c, x)
    buf = c.buf
    pos = c.pos
    len = c.len
    @writechar '}'
    return buf, pos, len
end

@inline function write(::CustomStruct, buf, pos, len, x; kw...)
    y = StructTypes.lower(x)
    return write(StructType(y), buf, pos, len, y; kw...)
end

function write(::DictType, buf, pos, len, x::T; kw...) where {T}
    @writechar '{'
    pairs = StructTypes.keyvaluepairs(x)

    next = iterate(pairs)
    while next !== nothing
        (k, v), state = next

        buf, pos, len = write(StringType(), buf, pos, len, Base.string(k))
        @writechar ':'
        buf, pos, len = write(StructType(v), buf, pos, len, v; kw...)

        next = iterate(pairs, state)
        next === nothing || @writechar ','
    end
    @writechar '}'
    return buf, pos, len
end

function write(::ArrayType, buf, pos, len, x::T; kw...) where {T}
    @writechar '['
    n = length(x)
    i = 1
    for y in x
        buf, pos, len = write(StructType(y), buf, pos, len, y; kw...)
        if i < n
            @writechar ','
        end
        i += 1
    end
    @writechar ']'
    return buf, pos, len
end

function write(::ArrayType, buf, pos, len, x::AbstractArray; kw...)
    @writechar '['
    n = 0
    for i in eachindex(x)
        if isassigned(x, i)
            y = x[i]
            buf, pos, len = write(StructType(y), buf, pos, len, y; kw...)
        else
            buf, pos, len = write(NullType(), buf, pos, len, nothing; kw...)
        end
        @writechar ','
        n += 1
    end
    if n > 0
        # for non-empty arrays, we eagerly write a comma after each element
        # so backtrack one pos where we'll write ']'
        pos -= 1
    end
    @writechar ']'
    return buf, pos, len
end

function write(::NullType, buf, pos, len, x; kw...)
    @writechar 'n' 'u' 'l' 'l'
    return buf, pos, len
end

write(::BoolType, buf, pos, len, x; kw...) = write(BoolType(), buf, pos, len, StructTypes.construct(Bool, x); kw...)
function write(::BoolType, buf, pos, len, x::Bool; kw...)
    if x
        @writechar 't' 'r' 'u' 'e'
    else
        @writechar 'f' 'a' 'l' 's' 'e'
    end
    return buf, pos, len
end

write(::SingletonType, buf, pos, len, x; kw...) = write(StringType(), buf, pos, len, x; kw...)

# adapted from base/intfuncs.jl
_split_sign(x) = Base.split_sign(x)
_split_sign(x::BigInt) = (abs(x), x < 0)

function write(::NumberType, buf, pos, len, y::Integer; kw...)
    x, neg = _split_sign(y)
    if neg
        @writechar UInt8('-')
    end
    n = i = ndigits(x, base=10, pad=1)
    @check i
    while i > 0
        @inbounds buf[pos + i - 1] = 48 + rem(x, 10)
        x = oftype(x, div(x, 10))
        i -= 1
    end
    return buf, pos + n, len
end

# default fallback for non-Integer/non-AbstractFloat numbers
# conver to Float64 and write the string representation
"""
    JSON3.tostring(x::Real) -> String

For some number types that are `<: Real`, but not `<: Integer` or `<: AbstractFloat`,
`tostring` provides an overload to convert `x` to an appropriate string representation
which will be used for the JSON numeric representation. By default, `x` is converted
to a `Float64` and then to a `String`.
"""
tostring(x::Real) = Base.string(convert(Float64, x))

function write(::NumberType, buf, pos, len, x::T; kw...) where {T}
    NT = StructTypes.numbertype(T)
    if NT === T
        # this means T hasn't overloaded numbertype
        # and we can't StructTypes.construct since we'll just stack overflow
        # so we call last-chance tostring that can be overloaded
        bytes = codeunits(tostring(x))
        sz = sizeof(bytes)
        @check sz
        for i = 1:sz
            @inbounds @writechar bytes[i]
        end

        return buf, pos, len
    else
        write(NumberType(), buf, pos, len, StructTypes.construct(NT, x); kw...)
    end
end

function write(::NumberType, buf, pos, len, x::AbstractFloat; allow_inf::Bool=false, kw...)
    isfinite(x) || allow_inf || error("$x not allowed to be written in JSON spec")
    bytes = codeunits(Base.string(x))
    sz = sizeof(bytes)
    @check sz
    for i = 1:sz
        @inbounds @writechar bytes[i]
    end

    return buf, pos, len
end

@inline function write(::NumberType, buf, pos, len, x::T; allow_inf::Bool=false, kw...) where {T <: Base.IEEEFloat}
    isfinite(x) || allow_inf || error("$x not allowed to be written in JSON spec")
    if isinf(x)
        # Although this is non-standard JSON, "Infinity" is commonly used.
        # See https://docs.python.org/3/library/json.html#infinite-and-nan-number-values.
        if sign(x) == -1
            @writechar '-'
        end
        @writechar 'I' 'n' 'f' 'i' 'n' 'i' 't' 'y'
        return buf, pos, len
    end
    @check Ryu.neededdigits(T)
    pos = Ryu.writeshortest(buf, pos, x)
    return buf, pos, len
end

const NEEDESCAPE = Set(map(UInt8, ('"', '\\', '\b', '\f', '\n', '\r', '\t')))

function escapechar(b)
    b == UInt8('"')  && return UInt8('"')
    b == UInt8('\\') && return UInt8('\\')
    b == UInt8('\b') && return UInt8('b')
    b == UInt8('\f') && return UInt8('f')
    b == UInt8('\n') && return UInt8('n')
    b == UInt8('\r') && return UInt8('r')
    b == UInt8('\t') && return UInt8('t')
    return 0x00
end

iscntrl(c::Char) = c <= '\x1f' || '\x7f' <= c <= '\u9f'
function escaped(b)
    if b == UInt8('/')
        return [UInt8('/')]
    elseif b >= 0x80
        return [b]
    elseif b in NEEDESCAPE
        return [UInt8('\\'), escapechar(b)]
    elseif iscntrl(Char(b))
        return UInt8[UInt8('\\'), UInt8('u'), Base.string(b, base=16, pad=4)...]
    else
        return [b]
    end
end

const ESCAPECHARS = [escaped(b) for b = 0x00:0xff]
const ESCAPELENS = [length(x) for x in ESCAPECHARS]

function escapelength(str)
    x = 0
    @simd for i = 1:ncodeunits(str)
        @inbounds len = ESCAPELENS[codeunit(str, i) + 1]
        x += len
    end
    return x
end

write(::StringType, buf, pos, len, x::T; dateformat::Dates.DateFormat=Dates.default_format(T), kw...) where {T <: Dates.TimeType} = write(StringType(), buf, pos, len, Dates.format(x, dateformat); kw...)
write(::StringType, buf, pos, len, x; kw...) = write(StringType(), buf, pos, len, Base.string(x); kw...)
function write(::StringType, buf, pos, len, x::AbstractString; kw...)
    sz = ncodeunits(x)
    el = escapelength(x)
    @check (el + 2)
    @inbounds @writechar '"'
    if el > sz
        for i = 1:sz
            @inbounds escbytes = ESCAPECHARS[codeunit(x, i) + 1]
            for j = 1:length(escbytes)
                @inbounds buf[pos] = escbytes[j]
                pos += 1
            end
        end
    else
        @simd for i = 1:sz
            @inbounds buf[pos] = codeunit(x, i)
            pos += 1
        end
    end
    @inbounds @writechar '"'
    return buf, pos, len
end

write(::StringType, buf, pos, len, x::Symbol; kw...) = write(StringType(), buf, pos, len, String(x); kw...)
