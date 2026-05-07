_symbol(ptr, len) = ccall(:jl_symbol_n, Ref{Symbol}, (Ptr{UInt8}, Int), ptr, len)

function getbyte(buf, pos)
    unsafe_load(pointer(buf.s), pos)
end

function getbyte(buf::AbstractVector{UInt8}, pos)
    @inbounds b = buf[pos]
    return b
end

macro eof()
    esc(quote
        if pos > len
            error = UnexpectedEOF
            @goto invalid
        end
    end)
end

macro wh()
    esc(quote
        while b == UInt8('\t') || b == UInt8(' ') || b == UInt8('\n') || b == UInt8('\r')
            pos += 1
            if pos > len
                error = UnexpectedEOF
                @goto invalid
            end
            b = getbyte(buf, pos)
        end
    end)
end

macro wh_done()
    esc(quote
        while b == UInt8(' ') || b == UInt8('\t')
            pos += 1
            if pos > len
                @goto done
            end
            b = getbyte(buf, pos)
        end
    end)
end

const EMPTY   = UInt64(0b00000000) << 56
const OBJECT  = UInt64(0b00000001) << 56
const ARRAY   = UInt64(0b00000010) << 56
const STRING  = UInt64(0b00000100) << 56
const INT     = UInt64(0b00001000) << 56
const FLOAT   = UInt64(0b00010000) << 56
const BOOL    = UInt64(0b00100000) << 56
const NULL    = UInt64(0b01000000) << 56
const ANY     = UInt64(0b10000000) << 56

const TYPEMASK = 0xff00000000000000

empty(x::UInt64) = (x & TYPEMASK) == EMPTY
isany(x::UInt64) = (x & TYPEMASK) == ANY
isobject(x::UInt64) = (x & TYPEMASK) == OBJECT
isarray(x::UInt64) = (x & TYPEMASK) == ARRAY
isstring(x::UInt64) = (x & TYPEMASK) == STRING
isint(x::UInt64) = (x & TYPEMASK) == INT
isfloat(x::UInt64) = (x & TYPEMASK) == FLOAT
isbool(x::UInt64) = (x & TYPEMASK) == BOOL
isnull(x::UInt64) = (x & TYPEMASK) == NULL
isintfloat(x::UInt64) = (x & TYPEMASK) == (INT | FLOAT)
nonnull(x::UInt64) = (x & TYPEMASK) & ~NULL

function geteltype(T)
    if empty(T); return Union{}
    elseif isany(T); return Any
    elseif isobject(T); return Object
    elseif isarray(T); return Array
    elseif isstring(T); return String
    elseif isint(T); return Int64
    elseif isfloat(T); return Float64
    elseif isbool(T); return Bool
    elseif isnull(T); return Nothing
    elseif isintfloat(T); return Union{Int64, Float64}
    else return Union{geteltype(nonnull(T)), Nothing}
    end
end

object(tapelen) = OBJECT | Core.bitcast(UInt64, tapelen)
array(tapelen)  = ARRAY  | Core.bitcast(UInt64, tapelen)
eltypelen(T, len) = T | Core.bitcast(UInt64, len)
string(len) = STRING | Core.bitcast(UInt64, len)
const ESCAPE_BIT = UInt64(1) << 63

function promoteeltype(A, B)
    if A == B
        return A
    elseif A == EMPTY
        return B
    elseif (A | B) == A
        return A
    elseif A == INT && B == FLOAT
        return A | B
    elseif A == FLOAT && B == INT
        return A | B
    elseif A == (INT | NULL) && B == FLOAT
        return A | B
    elseif A == (FLOAT | NULL) && B == INT
        return A | B
    elseif A == NULL || B == NULL
        return A | B
    else
        return ANY
    end
end

gettypemask(x::UInt64) = x & TYPEMASK
getnontypemask(x::UInt64) = Core.bitcast(Int64, x & ~TYPEMASK)
getpos(x::UInt64) = Core.bitcast(Int64, getnontypemask(x) >> 16)
getlen(x::UInt64) = Core.bitcast(Int64, x & 0x000000000000ffff)

gettapelen(T, x::UInt64) = ifelse(isobject(x) | isarray(x), getnontypemask(x), 2)
gettapelen(::Union{Type{Int64}, Type{Float64}, Type{Bool}, Type{Nothing}}) = 2

regularstride(T) = false
regularstride(::Union{Type{Int64}, Type{Float64}, Type{Bool}, Type{Nothing}}) = true
regularstride(::Type{Union{Int64, Float64}}) = true

function getvalue(::Type{Object}, buf, tape, tapeidx, t)
    x = Object(buf, Base.unsafe_view(tape, tapeidx:tapeidx + getnontypemask(t)), Dict{Symbol, Int}())
    populateinds!(x)
    return x
end

function getvalue(::Type{Array}, buf, tape, tapeidx, t)
    T = tape[tapeidx+1]
    ttape = Base.unsafe_view(tape, tapeidx:tapeidx + getnontypemask(t))
    inds = Int[]
    if empty(T)
        x = Array{Union{},typeof(buf),typeof(ttape)}(buf, ttape, inds)
        populateinds!(x)
        return x
    elseif isany(T)
        x = Array{Any,typeof(buf),typeof(ttape)}(buf, ttape, inds)
        populateinds!(x)
        return x
    elseif isobject(T)
        x = Array{Object,typeof(buf),typeof(ttape)}(buf, ttape, inds)
        populateinds!(x)
        return x
    elseif isarray(T)
        x = Array{Array,typeof(buf),typeof(ttape)}(buf, ttape, inds)
        populateinds!(x)
        return x
    elseif isstring(T)
        x = Array{String,typeof(buf),typeof(ttape)}(buf, ttape, inds)
        populateinds!(x)
        return x
    elseif isint(T)
        x = Array{Int64,typeof(buf),typeof(ttape)}(buf, ttape, inds)
        populateinds!(x)
        return x
    elseif isfloat(T)
        x = Array{Float64,typeof(buf),typeof(ttape)}(buf, ttape, inds)
        populateinds!(x)
        return x
    elseif isbool(T)
        x = Array{Bool,typeof(buf),typeof(ttape)}(buf, ttape, inds)
        populateinds!(x)
        return x
    elseif isnull(T)
        x = Array{Nothing,typeof(buf),typeof(ttape)}(buf, ttape, inds)
        populateinds!(x)
        return x
    elseif isintfloat(T)
        x = Array{Union{Int64, Float64},typeof(buf),typeof(ttape)}(buf, ttape, inds)
        populateinds!(x)
        return x
    else
        x = Array{Union{geteltype(nonnull(T)), Nothing},typeof(buf),typeof(ttape)}(buf, ttape, inds)
        populateinds!(x)
        return x
    end
end

function getvalue(::Type{Symbol}, buf, tape, tapeidx, t)
    @inbounds t2 = tape[tapeidx + 1]
    if (t2 & ESCAPE_BIT) == ESCAPE_BIT
        return Symbol(unescape(PointerString(pointer(buf, getnontypemask(t2)), getnontypemask(t))))
    else
        return _symbol(pointer(buf, getnontypemask(t2)), getnontypemask(t))
    end
end
function getvalue(::Type{String}, buf, tape, tapeidx, t)
    @inbounds t2 = tape[tapeidx + 1]
    if (t2 & ESCAPE_BIT) == ESCAPE_BIT
        return unescape(PointerString(pointer(buf, getnontypemask(t2)), getnontypemask(t)))
    else
        return unsafe_string(pointer(buf, getnontypemask(t2)), getnontypemask(t))
    end
end
function getvalue(::Type{Int64}, buf, tape, tapeidx, t)
    @inbounds x = Core.bitcast(Int64, tape[tapeidx+1])
    return x
end
function getvalue(::Type{Float64}, buf, tape, tapeidx, t)
    @inbounds x = Core.bitcast(Float64, tape[tapeidx+1])
    return x
end
function getvalue(::Type{Union{Int64, Float64}}, buf, tape, tapeidx, t)
    @inbounds x = tape[tapeidx+1]
    return Core.bitcast(ifelse(isint(t), Int64, Float64), x)
end
getvalue(::Type{Bool}, buf, tape, tapeidx, t) = getnontypemask(t) == UInt64(1)
getvalue(::Type{Nothing}, buf, tape, tapeidx, t) = nothing
@inline function getvalue(T, buf, tape, tapeidx, t)
    if isobject(t)
        return getvalue(Object, buf, tape, tapeidx, t)
    elseif isarray(t)
        return getvalue(Array, buf, tape, tapeidx, t)
    elseif isstring(t)
        return getvalue(String, buf, tape, tapeidx, t)
    elseif isint(t)
        return getvalue(Int64, buf, tape, tapeidx, t)
    elseif isfloat(t)
        return getvalue(Float64, buf, tape, tapeidx, t)
    elseif isbool(t)
        return getvalue(Bool, buf, tape, tapeidx, t)
    elseif isnull(t)
        return nothing
    end
end

Base.@pure function symbolin(names::Tuple{Vararg{Symbol}}, name::Symbol)
    for nm in names
        nm === name && return true
    end
    return false
end

function read_json_str(json)
    # length check is to ensure that isfile doesn't thrown an error
    # see issue for details https://github.com/JuliaLang/julia/issues/39774
    !(json isa VectorString) && sizeof(json) < 255 && isfile(json) ?
          VectorString(Mmap.mmap(json)) : 
          json
end
