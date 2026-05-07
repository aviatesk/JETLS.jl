# temporary wrapper to pass byte vector through
struct VectorString{T <: AbstractVector{UInt8}} <: AbstractString
    bytes::T
end

Base.codeunits(x::VectorString) = x.bytes

# high-level user API functions
read(io::Union{IO, Base.AbstractCmd}; kw...) = read(Base.read(io, String); kw...)
read(bytes::AbstractVector{UInt8}; kw...) = read(VectorString(bytes); kw...)

"""
    JSON3.read(json, [type]; kw... )

Read JSON.

## Args

* `json`: A file, string, IO, or bytes (`AbstractVector{UInt8`) containing JSON to read
* `type`: Optionally, a type to read the JSON into. If not a [built in type](#Builtin-types), must have a "struct mapping" registered with [StructTypes.jl](#Struct-API).

## Keyword Args

* `jsonlines`: A Bool indicating that the `json_str` contains newline delimited JSON strings, which will be read into a `JSON3.Array` of the JSON values.  See [jsonlines](https://jsonlines.org/) for reference. [default `false`]
* `allow_inf`: Allow reading of `Inf` and `NaN` values (not part of the JSON standard). [default `false`]
* `dateformat`: A [`DateFormat`](https://docs.julialang.org/en/v1/stdlib/Dates/#Dates.DateFormat) describing the format of dates in the JSON so that they can be read into `Date`s, `Time`s, or `DateTime`s when reading into a type. [default `Dates.default_format(T)`]
* `parsequoted`: Accept quoted values when reading into a NumberType. [default `false`]
* `numbertype`: Type to parse numbers as. [default `nothing`, which parses numbers as Int if possible, Float64 otherwise]
* `ignore_extra_fields`: Ignore extra fields in the JSON when reading into a struct. [default `true`]
"""
function read(json::AbstractString; jsonlines::Bool=false,
              numbertype::Union{DataType, Nothing}=nothing, kw...)
    return parse(read_json_str(json); jsonlines, numbertype, kw...)
end

function parse(str::AbstractString; jsonlines::Bool=false,
               numbertype::Union{DataType, Nothing}=nothing, kw...)
    buf = codeunits(str)
    len = length(buf)
    if len == 0
        error = UnexpectedEOF
        pos = 0
        @goto invalid
    end
    pos = 1
    b = getbyte(buf, pos)
    @wh
    tape = len < 1000 ? Vector{UInt64}(undef, len + 4) :
        Vector{UInt64}(undef, div(len, 10))
    if numbertype === nothing
        checkint = true
    elseif numbertype == Float64
        checkint = false
    else
        throw(ArgumentError("numbertype $numbertype is not supported. " *
                            "Only `nothing` (default) and `Float64` are supported so far."))
    end
    if jsonlines
        pos, tapeidx = jsonlines!(buf, pos, len, b, tape, Int64(1), checkint; kw...)
    else
        pos, tapeidx = read!(buf, pos, len, b, tape, Int64(1), Any, checkint; kw...)
    end
    @inbounds t = tape[1]
    if isobject(t)
        obj = Object(buf, tape, Dict{Symbol, Int}())
        populateinds!(obj)
        return obj
    elseif isarray(t)
        arr = Array{geteltype(tape[2])}(buf, tape, Int[])
        populateinds!(arr)
        return arr
    else
        return getvalue(Any, buf, tape, 1, t)
    end
@label invalid
    invalid(error, buf, pos, Any)
end

function parsefile(fname::AbstractString; jsonlines::Bool=false,
                   numbertype::Union{DataType, Nothing}=nothing, kw...)
    return parse(VectorString(Mmap.mmap(fname)); jsonlines, numbertype, kw...)
end

macro check()
    esc(quote
        if (tapeidx + 1) > length(tape)
            newsize = ceil(Int64, ((1 - pos / len) + 1) * tapeidx) + 20
            # println("resizing tape from $(pointer(tape)) $tapeidx to $newsize")
            resize!(tape, newsize)
        end
    end)
end

const FLOAT_INT_BOUND = 2.0^53

function read!(buf, pos, len, b, tape, tapeidx, ::Type{Any}, checkint=true; allow_inf::Bool=false)
    if b == UInt8('{')
        return read!(buf, pos, len, b, tape, tapeidx, Object, checkint; allow_inf=allow_inf)
    elseif b == UInt8('[')
        return read!(buf, pos, len, b, tape, tapeidx, Array, checkint; allow_inf=allow_inf)
    elseif b == UInt8('"')
        return read!(buf, pos, len, b, tape, tapeidx, String)
    elseif b == UInt8('n')
        return read!(buf, pos, len, b, tape, tapeidx, Nothing)
    elseif b == UInt8('t')
        return read!(buf, pos, len, b, tape, tapeidx, True)
    elseif b == UInt8('f')
        return read!(buf, pos, len, b, tape, tapeidx, False)
    elseif (UInt8('0') <= b <= UInt8('9')) || b == UInt8('-') || b == UInt8('+') || (allow_inf && (b == UInt8('N') || b == UInt8('I')))
        float, code, floatpos = Parsers.typeparser(Float64, buf, pos, len, b, Int16(0), Parsers.OPTIONS)
        if code > 0
            !isfinite(float) && !allow_inf && @goto invalid
            @check
            # if, for example, we've already parsed floats in an array, just keep them all as floats and don't check for ints
            if checkint
                fp, ip = modf(float)
                if fp == 0 && Float64(typemin(Int64)) <= float <= Float64(typemax(Int64))
                    # ok great, we know the number is integral and pretty much in Int64 range
                    if -FLOAT_INT_BOUND < float < FLOAT_INT_BOUND
                        # easy case, integer w/ less than or equal to 53-bits of precision
                        int = unsafe_trunc(Int64, float)
                    else
                        # if our integral float is > 53-bit precision, we need to reparse the Int so we don't get a lossy conversion
                        # there are also a few floats that satisfy Float64(typemin(Int64)) <= float <= Float64(typemax(Int64))
                        # that actually overflow Int64, like -9223372036854775809 and 9223372036854775808
                        # in those cases, we're going to verify that this Int64 parsing doesn't overflow
                        int, code, floatpos2 = Parsers.typeparser(Int64, buf, pos, len, b, Int16(0), Parsers.OPTIONS)
                        if floatpos2 < floatpos
                            # ah, but there's one more case we need to handle: a > 53-bit precision integer given in
                            # exponent form, like 1e17 or 9.007199254740994e15; in those cases, the truncation to Int64 *isn't* lossy
                            int = unsafe_trunc(Int64, float)
                        end
                    end
                    if code > 0
                        @inbounds tape[tapeidx] = INT
                        @inbounds tape[tapeidx + 1] = Core.bitcast(UInt64, int)
                        return floatpos, tapeidx + 2
                    end
                end
            end
            @inbounds tape[tapeidx] = FLOAT
            @inbounds tape[tapeidx + 1] = Core.bitcast(UInt64, float)
            return floatpos, tapeidx + 2
        end
        invalid(InvalidNumber, buf, pos, Float64)
    end
@label invalid
    invalid(InvalidChar, buf, pos, Any)
end

function read!(buf, pos, len, b, tape, tapeidx, ::Type{String})
    pos += 1
    @eof
    strpos = pos
    strlen = Int64(0)
    escaped = false
    b = getbyte(buf, pos)
    while b != UInt8('"')
        if b == UInt8('\\')
            escaped = true
            # skip next character
            pos += 2
            strlen += 2
        elseif b < UInt8(' ')
            unescaped_control(b)
        else
            pos += 1
            strlen += 1
        end
        @eof
        b = getbyte(buf, pos)
    end
    @check
    @inbounds tape[tapeidx] = string(strlen)
    @inbounds tape[tapeidx+1] = ifelse(escaped, ESCAPE_BIT | strpos, strpos)
    return pos + 1, tapeidx + 2

@label invalid
    invalid(error, buf, pos, String)
end

struct True end
function read!(buf, pos, len, b, tape, tapeidx, ::Type{True})
    if pos + 3 <= len &&
        b            == UInt8('t') &&
        buf[pos + 1] == UInt8('r') &&
        buf[pos + 2] == UInt8('u') &&
        buf[pos + 3] == UInt8('e')
        @check
        @inbounds tape[tapeidx] = BOOL | UInt64(1)
        return pos + 4, tapeidx + 2
    else
        invalid(InvalidChar, buf, pos, True)
    end
end

struct False end
function read!(buf, pos, len, b, tape, tapeidx, ::Type{False})
    if pos + 4 <= len &&
        b            == UInt8('f') &&
        buf[pos + 1] == UInt8('a') &&
        buf[pos + 2] == UInt8('l') &&
        buf[pos + 3] == UInt8('s') &&
        buf[pos + 4] == UInt8('e')
        @check
        @inbounds tape[tapeidx] = BOOL
        return pos + 5, tapeidx + 2
    else
        invalid(InvalidChar, buf, pos, False)
    end
end

function read!(buf, pos, len, b, tape, tapeidx, ::Type{Nothing})
    if pos + 3 <= len &&
        b            == UInt8('n') &&
        buf[pos + 1] == UInt8('u') &&
        buf[pos + 2] == UInt8('l') &&
        buf[pos + 3] == UInt8('l')
        @check
        @inbounds tape[tapeidx] = NULL
        return pos + 4, tapeidx + 2
    else
        invalid(InvalidChar, buf, pos, Nothing)
    end
end

function read!(buf, pos, len, b, tape, tapeidx, ::Type{Object}, checkint=true; kw...)
    objidx = tapeidx
    eT = EMPTY
    pos += 1
    @eof
    b = getbyte(buf, pos)
    @wh
    if b == UInt8('}')
        @check
        @inbounds tape[tapeidx] = object(Int64(2))
        @inbounds tape[tapeidx+1] = eltypelen(eT, Int64(0))
        tapeidx += 2
        pos += 1
        @goto done
    elseif b != UInt8('"')
        error = ExpectedOpeningQuoteChar
        @goto invalid
    end
    pos += 1
    @eof
    tapeidx += 2
    nelem = Int64(0)
    while true
        keypos = pos
        keylen = Int64(0)
        escaped = false
        # read first key character
        b = getbyte(buf, pos)
        # positioned at first character of object key
        while b != UInt8('"')
            if b == UInt8('\\')
                escaped = true
                # skip next character
                pos += 2
                keylen += 2
            else
                pos += 1
                keylen += 1
            end
            @eof
            b = getbyte(buf, pos)
        end
        @check
        @inbounds tape[tapeidx] = string(keylen)
        @inbounds tape[tapeidx+1] = ifelse(escaped, ESCAPE_BIT | keypos, keypos)
        tapeidx += 2
        pos += 1
        @eof
        b = getbyte(buf, pos)
        @wh
        if b != UInt8(':')
            error = ExpectedSemiColon
            @goto invalid
        end
        pos += 1
        @eof
        b = getbyte(buf, pos)
        @wh
        # now positioned at start of value
        prevtapeidx = tapeidx
        pos, tapeidx = read!(buf, pos, len, b, tape, tapeidx, Any, checkint; kw...)
        @eof
        b = getbyte(buf, pos)
        @wh
        @inbounds eT = promoteeltype(eT, gettypemask(tape[prevtapeidx]))
        nelem += 1
        if b == UInt8('}')
            @check
            @inbounds tape[objidx] = object(tapeidx - objidx)
            @inbounds tape[objidx+1] = eltypelen(eT, nelem)
            pos += 1
            @goto done
        elseif b != UInt8(',')
            error = ExpectedComma
            @goto invalid
        end
        pos += 1
        @eof
        b = getbyte(buf, pos)
        @wh
        if b != UInt8('"')
            error = ExpectedOpeningQuoteChar
            @goto invalid
        end
        pos += 1
        @eof
    end

@label done
    return pos, tapeidx
@label invalid
    invalid(error, buf, pos, Object)
end

function read!(buf, pos, len, b, tape, tapeidx, ::Type{Array}, checkint=true; kw...)
    arridx = tapeidx
    eT = EMPTY
    pos += 1
    @eof
    b = getbyte(buf, pos)
    @wh
    if b == UInt8(']')
        @check
        @inbounds tape[tapeidx] = array(Int64(2))
        @inbounds tape[tapeidx+1] = eltypelen(eT, Int64(0))
        tapeidx += 2
        pos += 1
        @goto done
    end
    tapeidx += 2
    nelem = Int64(0)
    while true
        # positioned at start of value
        prevtapeidx = tapeidx
        check_int = checkint ? eT != FLOAT && eT != (FLOAT | NULL) : false
        pos, tapeidx = read!(buf, pos, len, b, tape, tapeidx, Any, check_int; kw...)
        @eof
        b = getbyte(buf, pos)
        @wh
        @inbounds eT = promoteeltype(eT, gettypemask(tape[prevtapeidx]))
        nelem += 1
        if b == UInt8(']')
            @check
            @inbounds tape[arridx] = array(tapeidx - arridx)
            @inbounds tape[arridx+1] = eltypelen(eT, nelem)
            pos += 1
            @goto done
        elseif b != UInt8(',')
            error = ExpectedComma
            @goto invalid
        end
        pos += 1
        @eof
        b = getbyte(buf, pos)
        @wh
    end

@label done
    return pos, tapeidx
@label invalid
    invalid(error, buf, pos, Array)
end

function jsonlines!(buf, pos, len, b, tape, tapeidx, checkint=true; kw...)
    arridx = tapeidx
    eT = EMPTY
    if pos > len
        @check
        @inbounds tape[tapeidx] = array(Int64(2))
        @inbounds tape[tapeidx+1] = eltypelen(eT, Int64(0))
        tapeidx += 2
        @goto done
    end
    tapeidx += 2
    nelem = Int64(0)
    while true
        @wh
        # positioned at start of value
        prevtapeidx = tapeidx
        check_int = checkint ? eT != FLOAT && eT != (FLOAT | NULL) : false
        pos, tapeidx = read!(buf, pos, len, b, tape, tapeidx, Any, check_int; kw...)
        @inbounds eT = promoteeltype(eT, gettypemask(tape[prevtapeidx]))
        nelem += 1
        if pos > len
            @check
            @inbounds tape[arridx] = array(tapeidx - arridx)
            @inbounds tape[arridx+1] = eltypelen(eT, nelem)
            @goto done
        end
        b = getbyte(buf, pos)
        if b != UInt8('\n') && b != UInt8('\r')
            error = ExpectedNewline
            @goto invalid
        end
        pos += 1
        if pos > len
            @check
            @inbounds tape[arridx] = array(tapeidx - arridx)
            @inbounds tape[arridx+1] = eltypelen(eT, nelem)
            @goto done
        end
        if b == UInt8('\r')
            b = getbyte(buf, pos)
            if b == UInt8('\n')
                pos += 1
                if pos > len
                    @check
                    @inbounds tape[arridx] = array(tapeidx - arridx)
                    @inbounds tape[arridx+1] = eltypelen(eT, nelem)
                    @goto done
                end
            end
        end
        b = getbyte(buf, pos)
    end

@label done
    return pos, tapeidx
@label invalid
    invalid(error, buf, pos, Array)
end
