module JSON3

using Parsers, Mmap, UUIDs, Dates, StructTypes
using Base: Ryu

"""An immutable (read only) struct which provides an efficient view of a JSON object. Supports the `AbstractDict` interface. See [built in types](#Builtin-types) for more detail on why we have an `Object` type."""
struct Object{S <: AbstractVector{UInt8}, TT <: AbstractVector{UInt64}} <: AbstractDict{Symbol, Any}
    buf::S
    tape::TT
    inds::Dict{Symbol, Int}
end

Object() = Object(codeunits(""), UInt64[object(Int64(2)), 0], Dict{Symbol, Int}())

"""An immutable (read only) struct which provides an efficient view of a JSON array. Supports the `AbstractArray` interface. See [built in types](#Builtin-types) for more detail on why we have an `Array` type."""
struct Array{T, S <: AbstractVector{UInt8}, TT <: AbstractVector{UInt64}} <: AbstractVector{T}
    buf::S
    tape::TT
    inds::Vector{Int}
end

Array{T}(buf::S, tape::TT, inds::Vector{Int}) where {T, S, TT} = Array{T, S, TT}(buf, tape, inds)

getbuf(j::Union{Object, Array}) = getfield(j, :buf)
gettape(j::Union{Object, Array}) = getfield(j, :tape)
getinds(j::Union{Object, Array}) = getfield(j, :inds)

include("utils.jl")

@noinline invalid(error, buf, pos, T) = throw(ArgumentError("""
invalid JSON at byte position $pos while parsing type $T: $error
$(String(buf[max(1, pos-25):min(end, pos+25)]))
"""))

@enum Error UnexpectedEOF ExpectedOpeningObjectChar ExpectedOpeningQuoteChar ExpectedOpeningArrayChar ExpectedClosingArrayChar ExpectedComma ExpectedSemiColon ExpectedNewline InvalidChar InvalidNumber ExtraField

# AbstractDict interface
Base.length(obj::Object) = getnontypemask(gettape(obj)[2])

function populateinds!(x::Object)
    inds = getinds(x)
    buf = getbuf(x)
    tape = gettape(x)
    tapeidx = 3
    @inbounds len = getnontypemask(tape[2])
    i = 1
    while i <= len
        @inbounds t = tape[tapeidx]
        key = getvalue(Symbol, buf, tape, tapeidx, t)
        tapeidx += 2
        inds[key] = tapeidx
        @inbounds tapeidx += gettapelen(Any, tape[tapeidx])
        i += 1
    end
    return
end

function populateinds!(x::Array)
    inds = getinds(x)
    buf = getbuf(x)
    tape = gettape(x)
    tapeidx = 3
    @inbounds len = getnontypemask(tape[2])
    resize!(inds, len)
    i = 1
    while i <= len
        @inbounds inds[i] = tapeidx
        @inbounds tapeidx += gettapelen(Any, tape[tapeidx])
        i += 1
    end
    return
end

@inline function Base.iterate(obj::Object, (i, tapeidx)=(1, 3))
    i > length(obj) && return nothing
    tape = gettape(obj)
    @inbounds t = tape[tapeidx]
    key = getvalue(Symbol, getbuf(obj), tape, tapeidx, t)
    tapeidx += 2
    @inbounds t = tape[tapeidx]
    x = Pair{Symbol, Any}(key, getvalue(Any, getbuf(obj), tape, tapeidx, t))
    tapeidx += gettapelen(Any, t)
    return x, (i + 1, tapeidx)
end

function Base.get(obj::Object, key::Symbol)
    ind = getinds(obj)[key]
    tape = gettape(obj)
    @inbounds t = tape[ind]
    return getvalue(Any, getbuf(obj), tape, ind, t)
end

Base.get(obj::Object, key) = get(obj, Symbol(key))

function Base.get(obj::Object, ::Type{T}, key)::T where {T}
    return get(obj, key)
end

function Base.get(obj::Object, key::Symbol, default)
    ind = getinds(obj)
    if haskey(ind, key)
        return get(obj, key)
    else
        return default
    end
end

Base.get(obj::Object, key, default) = get(obj, Symbol(key), default)

function Base.get(obj::Object, ::Type{T}, key, default::T)::T where {T}
    return get(obj, key, default)
end

function Base.get(default::Base.Callable, obj::Object, key::Symbol)
    ind = getinds(obj)
    if haskey(ind, key)
        return get(obj, key)
    else
        return default()
    end
end

Base.get(default::Base.Callable, obj::Object, key) = get(default, obj, Symbol(key))

Base.propertynames(obj::Object) = collect(keys(obj))

Base.getproperty(obj::Object, prop::Symbol) = get(obj, prop)
Base.getindex(obj::Object, key) = get(obj, key)

"""
    copy(obj)

Recursively copy [`JSON3.Object`](@ref)s to `Dict`s and [`JSON3.Array`](@ref)s to `Vector`s.  This copy can then be mutated if needed.
"""
function Base.copy(obj::Object)
    dict = Dict{Symbol, Any}()
    for (k, v) in obj
        dict[k] = v isa Object || v isa Array ? copy(v) : v
    end
    return dict
end

# AbstractArray interface
Base.IndexStyle(::Type{<:Array}) = Base.IndexLinear()

Base.size(arr::Array) = (length(getinds(arr)),)

function Base.iterate(arr::Array{T}, (i, tapeidx)=(1, 3)) where {T}
    i > length(arr) && return nothing
    tape = gettape(arr)
    @inbounds t = tape[tapeidx]
    val = getvalue(T, getbuf(arr), tape, tapeidx, t)
    tapeidx += gettapelen(T, t)
    return val, (i + 1, tapeidx)
end

@inline Base.@propagate_inbounds function Base.getindex(arr::Array{T}, i::Int) where {T}
    @boundscheck checkbounds(arr, i)
    tape = gettape(arr)
    buf = getbuf(arr)
    @inbounds ind = getinds(arr)[i]
    @inbounds t = tape[ind]
    return getvalue(T, buf, tape, ind, t)
end

Base.copy(arr::Array) = map(x->x isa Object || x isa Array ? copy(x) : x, arr)

include("read.jl")
include("strings.jl")
include("show.jl")
include("structs.jl")
include("write.jl")
include("pretty.jl")
include("gentypes.jl")

include("workload.jl")

end # module
