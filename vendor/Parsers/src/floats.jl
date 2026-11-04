using Base.MPFR, Base.GMP, Base.GMP.MPZ

_widen(x::UInt64) = UInt128(x)
_widen(x::Int64) = Int128(x)
_unwiden(x::UInt128) = x % UInt64
_unwiden(x::Int128) = x % Int64
_unwiden(x::BigInt) = x % Int128

function _widen(v::T) where {T <: Union{Int128, UInt128}}
    x = _get_bigint()
    ccall((:__gmpz_import, :libgmp), Int32,
        (Ref{BigInt}, Csize_t, Cint, Csize_t, Cint, Csize_t, Ref{T}),
        x, 1, 1, 16, 0, 0, v)
    return x
end

# Parsers that build on `parsedigits` may bound a token's significant digits;
# the float targets have no limit, since long coefficients cost O(1) per digit.
maxdigits(T) = typemax(Int64)

ten(::Type{T}) where {T} = T(10)
const TEN = BigInt(10)
ten(::Type{BigInt}) = TEN

_muladd(ten, digits, b) = ten * digits + b

function _muladd(ten, digits::BigInt, b)
    Base.GMP.MPZ.mul!(digits, ten)
    Base.GMP.MPZ.add_ui!(digits, b)
    return digits
end

# A float coefficient too long for UInt64: its leading digits, how many later
# digits were dropped, and whether any of them was nonzero. Each further digit
# costs O(1), and the conversion re-reads the token when the dropped digits
# decide the rounding.
struct LongMantissa
    mant::UInt64
    dropped::Int
    sticky::Bool
end

overflows(::Type{LongMantissa}) = false
ten(::Type{LongMantissa}) = 0x0a
_muladd(ten, digits::LongMantissa, b) =
    LongMantissa(digits.mant, digits.dropped + 1, digits.sticky | (b != 0))

const FloatConf = DefaultConf{<:Union{Float16, Float32, Float64}}

# Significant digits so far, without leading zeros, for parsers that use the
# count in `scale`/`noscale`; the built-in targets don't.
@inline _countdigit(::AbstractConf, ndigits, b) = ndigits + (!iszero(ndigits) || !iszero(b))
@inline _countdigit(::Union{FloatConf, DefaultConf{Number}}, ndigits, b) = ndigits

# The built-in float targets keep only a long coefficient's leading digits and
# read the token again if those can't decide the rounding. `Number` integers,
# other parsers built on `parsedigits` (which receive the digits in their
# `scale`/`noscale` methods), and `IO` sources, which can't be read twice, keep
# every digit.
_widen(::AbstractConf, source, x) = _widen(x)
_widen(::FloatConf, source, x::UInt64) = LongMantissa(x, 0, false)
_widen(::FloatConf, source::IO, x::UInt64) = _widen(x)
# An IO read can block and yield mid-token, so its wide digits never use the
# task-shared scratch BigInt.
_widen(::AbstractConf, source::IO, x::Union{Int128, UInt128}) = BigInt(x)
# Fraction digits make a `Number` result a float, so it keeps leading digits too.
_widenfrac(conf::AbstractConf, source, x) = _widen(conf, source, x)
function _widenfrac(::DefaultConf{Number}, source, x::Union{Int64, Int128})
    mant, dropped, sticky, _ = _mantissa(x)
    return LongMantissa(mant, dropped, sticky)
end
_widenfrac(conf::DefaultConf{Number}, source::IO, x::Union{Int64, Int128}) = _widen(conf, source, x)

@enum FloatType FLOAT16 FLOAT32 FLOAT64 BIGFLOAT

# for non SupportedFloat Reals, parse as Float64, then convert
function typeparser(conf::AbstractConf{T}, source, pos, len, b, code, pl, options) where {T <: Real}
    pos, code, pl, x = typeparser(DefaultConf{Float64}(), source, pos, len, b, code, pl, options)
    return pos, code, pl, T(x)
end

function _copy_nulterminated(source::AbstractVector{UInt8}, pos, len)
    vlen = max(0, len)
    buf = Vector{UInt8}(undef, vlen + 1)
    vlen > 0 && copyto!(buf, 1, source, pos, vlen)
    @inbounds buf[vlen + 1] = 0x00
    return buf
end

@inline _contiguous(source) = false
@inline _contiguous(source::StridedVector{UInt8}) = stride(source, 1) == 1
@inline _writable_contiguous(source) = false
@inline _writable_contiguous(source::Vector{UInt8}) = true
@inline _writable_contiguous(source::SubArray{UInt8,1}) =
    parent(source) isa Vector{UInt8} && _contiguous(source)

@inline _nulterminated(source, len) = false
@inline _nulterminated(source::String, len) = len == sizeof(source)
@inline _nulterminated(source::Base.CodeUnits{UInt8,String}, len) = len == length(source)
@inline function _nulterminated(source::AbstractVector{UInt8}, len)
    return _contiguous(source) && len < length(source) && @inbounds(source[len + 1]) == 0x00
end

@inline function _ends_on_delimiter(source::AbstractVector{UInt8}, len, options)
    0 < len <= length(source) || return false
    @inbounds b = source[len]
    return b == UInt8('\n') || b == UInt8('\r') || (options.flags.checkdelim && options.delim == b)
end

function _bigfloat_buffer(source::AbstractVector{UInt8}, pos, len, b, code, options)
    _, _, pl, _ = typeparser(DefaultConf{String}(), source, pos, len, b, code, poslen(pos, 0), options)
    return _copy_nulterminated(source, pl.pos, pl.len)
end

_bigfloat_buffer(source::AbstractString, pos, len, b, code, options) =
    _bigfloat_buffer(codeunits(source), pos, len, b, code, options)

function _bigfloat_buffer(source::IO, pos, len, b, code, options)
    _, _, pl, _ = typeparser(DefaultConf{String}(), source, pos, len, b, code, poslen(pos, 0), options)
    vlen = max(0, pl.len)
    buf = Vector{UInt8}(undef, vlen + 1)
    fastseek!(source, pl.pos - 1)
    readbytes!(source, buf, vlen)
    @inbounds buf[vlen + 1] = 0x00
    fastseek!(source, pos - 1)
    return buf
end

@inline function _mpfr_strtofr(z, ptr, endptr, base, rounding)
    return ccall((:mpfr_strtofr, :libmpfr), Int32, (Ref{BigFloat}, Cstring, Ref{Ptr{UInt8}}, Int32, Base.MPFR.MPFRRoundingMode), z, ptr, endptr, base, rounding)
end

@inline function _finish_bigfloat(source, pos, code, pl, z, ptr, base, rounding)
    endptr = Ref{Ptr{UInt8}}()
    err = _mpfr_strtofr(z, ptr, endptr, base, rounding)
    code |= endptr[] == ptr ? INVALID : OK
    pos += Int(endptr[] - ptr)
    source isa IO && fastseek!(source, pos - 1)
    return pos, code, PosLen(pl.pos, max(0, pos - pl.pos)), z
end

function typeparser(::AbstractConf{BigFloat}, source, pos, len, b, code, pl, options)
    base = 0
    rounding = Base.MPFR.ROUNDING_MODE[]
    z = BigFloat(precision=Base.MPFR.DEFAULT_PRECISION[])
    if _nulterminated(source, len)
        GC.@preserve source begin
            return _finish_bigfloat(source, pos, code, pl, z, pointer(source, pos), base, rounding)
        end
    elseif _writable_contiguous(source)
        nulpos = if _ends_on_delimiter(source, len, options)
            len
        else
            _, _, strpl, _ = typeparser(DefaultConf{String}(), source, pos, len, b, code, poslen(pos, 0), options)
            strpl.pos + strpl.len
        end
        if nulpos <= length(source)
            @inbounds byte = source[nulpos]
            @inbounds source[nulpos] = 0x00
            try
                GC.@preserve source begin
                    return _finish_bigfloat(source, pos, code, pl, z, pointer(source, pos), base, rounding)
                end
            finally
                @inbounds source[nulpos] = byte
            end
        else
            _, _, strpl, _ = typeparser(DefaultConf{String}(), source, pos, len, b, code, poslen(pos, 0), options)
            buf = _copy_nulterminated(source, strpl.pos, strpl.len)
            GC.@preserve buf begin
                return _finish_bigfloat(source, pos, code, pl, z, pointer(buf), base, rounding)
            end
        end
    else
        buf = _bigfloat_buffer(source, pos, len, b, code, options)
        GC.@preserve buf begin
            return _finish_bigfloat(source, pos, code, pl, z, pointer(buf), base, rounding)
        end
    end
end

@inline function typeparser(conf::AbstractConf{T}, source, pos, len, b, code, pl, options) where {T <: SupportedFloats}
    # keep track of starting pos in case of invalid, we can rewind to start of parsing
    startpos = pos
    x = zero(T)
    neg = b == UInt8('-')
    if neg || b == UInt8('+')
        pos += 1
        incr!(source)
    end
    if eof(source, pos, len)
        # invalid because input is empty or contained only '-' or '+'
        code |= INVALID | EOF
        @goto done
    end
    b = peekbyte(source, pos)
    if b != options.decimal && (b - UInt8('0')) > 0x09
        # character isn't a digit or decimal point, check for special values, otherwise INVALID
        if b == UInt8('n') || b == UInt8('N')
            pos += 1
            incr!(source)
            if eof(source, pos, len)
                code |= EOF
                @goto invalid
            end
            b = peekbyte(source, pos)
            if b == UInt8('a') || b == UInt8('A')
                pos += 1
                incr!(source)
                if eof(source, pos, len)
                    code |= EOF
                    @goto invalid
                end
                b = peekbyte(source, pos)
                if b == UInt8('n') || b == UInt8('N')
                    x = T(NaN)
                    pos += 1
                    incr!(source)
                    if eof(source, pos, len)
                        code |= EOF
                    end
                    code |= OK | SPECIAL_VALUE
                    @goto done
                end
            end
        elseif b == UInt8('i') || b == UInt8('I')
            pos += 1
            incr!(source)
            if eof(source, pos, len)
                code |= EOF
                @goto invalid
            end
            b = peekbyte(source, pos)
            if b == UInt8('n') || b == UInt8('N')
                pos += 1
                incr!(source)
                if eof(source, pos, len)
                    code |= EOF
                    @goto invalid
                end
                b = peekbyte(source, pos)
                if b == UInt8('f') || b == UInt8('F')
                    x = ifelse(neg, T(-Inf), T(Inf))
                    code |= OK | SPECIAL_VALUE
                    pos += 1
                    incr!(source)
                    if eof(source, pos, len)
                        code |= EOF
                        @goto done
                    end
                    b = peekbyte(source, pos)
                    if b == UInt8('i') || b == UInt8('I')
                        pos += 1
                        incr!(source)
                        if eof(source, pos, len)
                            code |= EOF
                            @goto done
                        end
                        b = peekbyte(source, pos)
                        if b == UInt8('n') || b == UInt8('N')
                            pos += 1
                            incr!(source)
                            if eof(source, pos, len)
                                code |= EOF
                                @goto done
                            end
                            b = peekbyte(source, pos)
                            if b == UInt8('i') || b == UInt8('I')
                                pos += 1
                                incr!(source)
                                if eof(source, pos, len)
                                    code |= EOF
                                    @goto done
                                end
                                b = peekbyte(source, pos)
                                if b == UInt8('t') || b == UInt8('T')
                                    pos += 1
                                    incr!(source)
                                    if eof(source, pos, len)
                                        code |= EOF
                                        @goto done
                                    end
                                    b = peekbyte(source, pos)
                                    if b == UInt8('y') || b == UInt8('Y')
                                        pos += 1
                                        incr!(source)
                                        if eof(source, pos, len)
                                            code |= EOF
                                        end
                                        @goto done
                                    end
                                end
                            end
                        end
                    end
                    @goto done
                end
            end
        else
        end
@label invalid
        fastseek!(source, startpos - 1)
        pos = startpos
        code |= INVALID
        @goto done
    end

    # start parsing digits or decimal point; we start digits as UInt64(0) and can _widen type if needed
    x, code, pos = parsedigits(conf, source, pos, len, b, code, options, UInt64(0), neg, startpos)
    if !isfinite(x)
        code |= SPECIAL_VALUE
    end

@label done
    return pos, code, PosLen(pl.pos, pos - pl.pos), x
end

function handlef(x::T, f::F) where {T, F}
    if f === nothing
        return x
    else
        f(x)
        return nothing
    end
end

rettype(::Type{T}) where {T} = T === Number ? Nothing : T

# when a function is passed to apply to the parsed value, we have to be really careful that the `x`
# returned from parsedigits is `Nothing`, otherwise we end up with an overall return type like
# `Tuple{Union{Nothing, T}, ReturnCode, Int}`, which can cause dynamic dispatches/inlining issues
# for callers. The rule to follow is that before any call to `@goto done`, we need to ensure `x`
# has been "handled" properly: either applied or in error cases, set to `nothing`
getx(x, f) = f === nothing ? x : nothing

# if we need to _widen the type due to `digits` overflow, we want a non-inlined version so base case compilation doesn't get out of control.
# NOTE: the widened recursive calls deliberately do NOT use `Base.inferencebarrier` — the
# widening ladder is bounded in type space (UInt64 → UInt128 → BigInt, or UInt64 →
# LongMantissa for the float targets; `overflows` is false for the last step of each),
# and a barrier makes the widened
# continuation reachable only through runtime dispatch: fine under the JIT, but in a
# statically compiled (`juliac --trim`) binary the widened instance doesn't exist, so
# parsing a wide-digit float would fail at runtime. The `@noinline` wrappers keep each
# ladder step compiling separately, which is what bounds base-case compilation.
@noinline _parsedigits(conf::AbstractConf{T}, source, pos, len, b, code, options, digits::IntType, neg::Bool, startpos, overflow_invalid::Bool, ndigits::Int, f::F) where {T, IntType, F} =
    parsedigits(conf, source, pos, len, b, code, options, digits, neg, startpos, overflow_invalid, ndigits, f)::Tuple{rettype(T), ReturnCode, Int}

@inline function parsedigits(conf::AbstractConf{T}, source, pos, len, b, code, options, digits::IntType, neg::Bool, startpos, overflow_invalid::Bool=false, ndigits::Int=0, f::F=nothing) where {T, IntType, F}
    x = zero(T)
    anydigits = false
    has_groupmark = _has_groupmark(options, code)
    groupmark0 = something(options.groupmark, 0xff) - UInt8('0')

    # we already previously checked if `b` was decimal or a digit, so don't need to check explicitly again
    if b != options.decimal
        b -= UInt8('0')
        prev_b0 = b
        anydigits = b <= 0x09
        while true
            if b <= 0x09
                if overflows(IntType) && digits > overflowval(IntType)
                    return _parsedigits(conf, source, pos, len, b + UInt8('0'), code, options, _widen(conf, source, digits), neg, startpos, overflow_invalid, ndigits, f)::Tuple{rettype(T), ReturnCode, Int}
                elseif ndigits > maxdigits(T)
                    # if input is way too big, just bail
                    fastseek!(source, startpos - 1)
                    pos = startpos
                    code |= INVALID
                    x = getx(x, f)
                    @goto done
                end
                digits = _muladd(ten(IntType), digits, b)
                pos += 1
                incr!(source)
                ndigits = _countdigit(conf, ndigits, b)
                if eof(source, pos, len)
                    # input is integer, like "1"
                    if T === Number && IntType != Int64 && digits <= _unwiden(digits)
                        # if T is Number, let's do a quick check if we tripped the
                        # overflow and can actually unwiden
                        y = _unwiden(digits)
                        x = handlef(ifelse(neg, -y, y), f)
                    else
                        x, code = _noscaletoken(conf, source, startpos, pos, digits, neg, code, ndigits, f, options)
                    end
                    code |= OK | EOF
                    @goto done
                end
            elseif has_groupmark && b == groupmark0
                prev_b0 == groupmark0 && (code |= INVALID; x = getx(x, f); @goto done) # two groupmarks in a row
                pos += 1
                Parsers.incr!(source)
                Parsers.eof(source, pos, len) && (code |= INVALID | EOF; x = getx(x, f); @goto done) # groupmark at end of input
            else
                # if `b` isn't a digit or a groupmark, time to break out of digit parsing while loop
                ((has_groupmark && prev_b0 == groupmark0) || !anydigits) && (code |= INVALID; x = getx(x, f); @goto done) # ended with groupmark
                break
            end
            prev_b0 = b
            b = peekbyte(source, pos) - UInt8('0')
        end
        # b wasn't a digit, so add back '0' to recover original Char value
        b += UInt8('0')
    end
    if b == options.decimal
        pos += 1
        incr!(source)
        if eof(source, pos, len)
            # if input is "." then invalid, otherwise ok, like "1."
            if T === Number
                x = handlef(ifelse(neg, -Float64(digits), Float64(digits)), f)
            else
                x, code = _noscaletoken(conf, source, startpos, pos, digits, neg, code, ndigits, f, options)
            end
            code |= ((startpos + 1) == pos ? INVALID : OK) | EOF
            @goto done
        end
        b = peekbyte(source, pos)
        if b - UInt8('0') > 0x09 && !(b == UInt8('e') || b == UInt8('E') || b == UInt8('f') || b == UInt8('F'))
            # if the next byte after decimal point isn't a digit or exponent char ('e', 'E', 'f', 'F')
            # and we haven't parsed any digits, like ".a", then invalid
            # otherwise ok, like "1.a" (only "1." is parsed)
            if !anydigits
                code |= INVALID
                x = getx(x, f)
                @goto done
            else
                if T === Number
                    x = handlef(ifelse(neg, -Float64(digits), Float64(digits)), f)
                else
                    x, code = _noscaletoken(conf, source, startpos, pos, digits, neg, code, ndigits, f, options)
                end
                code |= OK
                @goto done
            end
        end
    end

    # we've parsed any digits preceding decimal point and consumed decimal point if any
    # now we parse any digits following decimal point (if any); start `frac` at UInt64(0)
    # `digits` still receives any fractional digits, `frac` just keeps track of how many digits
    # were parsed to combine with any "e123" exponent numbers to determine final exponent value
    if overflows(IntType) && digits > overflowval(IntType)
        x, code, pos = _parsefrac(conf, source, pos, len, b, code, options, _widen(conf, source, digits), neg, startpos, UInt64(0), overflow_invalid, ndigits, f)::Tuple{rettype(T), ReturnCode, Int}
    else
        x, code, pos = parsefrac(conf, source, pos, len, b, code, options, digits, neg, startpos, UInt64(0), overflow_invalid, ndigits, f)
    end

@label done
    return x, code, pos
end

# same as above; if digits overflows, we want a non-inlined version to call with a wider type
# note that we never expect `frac` to overflow, since it's just keep track of the # of digits
# we parse post-decimal point
@noinline _parsefrac(conf::AbstractConf{T}, source, pos, len, b, code, options, digits::IntType, neg::Bool, startpos, frac, overflow_invalid, ndigits, f::F) where {T, IntType, F} =
    parsefrac(conf, source, pos, len, b, code, options, digits, neg, startpos, frac, overflow_invalid, ndigits, f)::Tuple{rettype(T), ReturnCode, Int}

@inline function parsefrac(conf::AbstractConf{T}, source, pos, len, b, code, options, digits::IntType, neg::Bool, startpos, frac, overflow_invalid, ndigits, f::F) where {T, IntType, F}
    x = zero(T)
    parsedanyfrac = false
    FT = FLOAT64
    # check if `b` is a digit
    if b - UInt8('0') < 0x0a
        b -= UInt8('0')
        parsedanyfrac = true
        # if so, parse fractional digits
        while true
            digits = _muladd(ten(IntType), digits, b)
            ndigits = _countdigit(conf, ndigits, b)
            pos += 1
            incr!(source)
            frac += UInt64(1)
            if eof(source, pos, len)
                # input is simple non-scientific-notation floating number, like "1.1"
                if overflow_invalid && -signed(frac) > 308
                    code |= INVALID
                    x = getx(x, f)
                else
                    x, code = _scaletoken(conf, FT, source, startpos, pos, digits, -signed(frac), neg, code, ndigits, f, options)
                    code |= OK | EOF
                end
                @goto done
            end
            b = peekbyte(source, pos) - UInt8('0')
            b > 0x09 && break
            if overflows(IntType) && digits > overflowval(IntType)
                return _parsefrac(conf, source, pos, len, b + UInt8('0'), code, options, _widenfrac(conf, source, digits), neg, startpos, frac, overflow_invalid, ndigits, f)::Tuple{rettype(T), ReturnCode, Int}
            end
        end
        b += UInt8('0')
    end
    # check for exponent notation
    if b == UInt8('e') || b == UInt8('E') || b == UInt8('f') || b == UInt8('F')
        if b == UInt8('f') || b == UInt8('F')
            FT = FLOAT32
        end
        pos += 1
        incr!(source)
        if eof(source, pos, len)
            # it's an error to have a "dangling" 'e', so input was something like "1.1e"
            code |= INVALID | EOF
            x = getx(x, f)
            @goto done
        end
        b = peekbyte(source, pos)
        # check for plus or minus sign for exponent number
        negexp = b == UInt8('-')
        if negexp || b == UInt8('+')
            pos += 1
            incr!(source)
            if eof(source, pos, len)
                # it's an error to have a "dangling" '-' or '+', so input was something like "1.1e-"
                code |= INVALID | EOF
                x = getx(x, f)
                @goto done
            end
            b = peekbyte(source, pos)
        end
        b -= UInt8('0')
        if b > 0x09
            # invalid to have a "dangling" 'e'
            code |= INVALID
            x = getx(x, f)
            @goto done
        end

        # at this point, we've parsed X and Y in "X.YeZ", but not Z in a scientific notation exponent number
        # we start our exponent number at UInt64(0)
        return parseexp(conf, source, pos, len, b, code, options, digits, neg, startpos, frac, UInt64(0), negexp, FT, overflow_invalid, ndigits, f)
    else
        # if no scientific notation, we're done, so scale digits + frac and return
        if parsedanyfrac
            if overflow_invalid && -signed(frac) > 308
                code |= INVALID
                x = getx(x, f)
                @goto done
            else
                x, code = _scaletoken(conf, FT, source, startpos, pos, digits, -signed(frac), neg, code, ndigits, f, options)
            end
        else
            x, code = _noscaletoken(conf, source, startpos, pos, digits, neg, code, ndigits, f, options)
        end
        code |= OK
    end

@label done
    return x, code, pos
end

# The exponent saturates (see `_decimalexponentdigit`), so any number of exponent
# digits fits in a UInt64 and the scale exponent is exact up to that bound.
@inline function parseexp(conf::AbstractConf{T}, source, pos, len, b, code, options, digits, neg::Bool, startpos, frac, exp::UInt64, negexp, FT, overflow_invalid, ndigits, f::F) where {T, F}
    x = zero(T)
    # note that `b` has already had `b - UInt8('0')` applied to it for parseexp
    ateof = false
    while true
        exp = _decimalexponentdigit(exp, b)
        pos += 1
        incr!(source)
        ateof = eof(source, pos, len)
        ateof && break
        b = peekbyte(source, pos) - UInt8('0')
        # if we encounter a non-digit, that must mean we're done
        b > 0x09 && break
    end
    ee = _signeddecimalexponent(exp, negexp) - Int128(frac)
    if overflow_invalid && ee > 308
        # an exponent past 308 is invalid for these parsers; EOF marks only valid input
        code |= INVALID
        x = getx(x, f)
    else
        x, code = _scaletoken(conf, FT, source, startpos, pos, digits, ee, neg, code, ndigits, f, options)
        code |= ateof ? (OK | EOF) : OK
    end
    return x, code, pos
end

# Parsers built on `parsedigits` (FixedPointDecimals, for one) extend `scale` and
# `noscale` for their own `AbstractConf`. The built-in float and `Number` targets
# go through `_scaletoken`/`_noscaletoken`, which also know where the token is,
# so the conversion can re-read its digits.

# No fractional part or exponent: `v` holds every digit.
function noscale(::AbstractConf{T}, v::Integer, neg::Bool, code, ndigits, f::F, ::Options) where {T, F}
    return handlef(ifelse(neg, -T(v), T(v)), f), code
end

# Digits in `v` scaled by 10^exp, for parsers that don't define their own `scale`.
scale(::AbstractConf{T}, FT::FloatType, v, exp, neg, code, ndigits, f::F, options::Options) where {T, F} =
    _scalefloat(T, FT, (v, exp), 0, 0, v, exp, neg, code, f, options)

@inline _noscaletoken(conf::AbstractConf, source, startpos, pos, v, neg, code, ndigits, f, options) =
    noscale(conf, v, neg, code, ndigits, f, options)
@inline _noscaletoken(conf::AbstractConf, source, startpos, pos, v::LongMantissa, neg, code, ndigits, f, options) =
    _scaletoken(conf, FLOAT64, source, startpos, pos, v, 0, neg, code, ndigits, f, options)
# A `Number` integer too wide for Int128 accumulates in the shared BigInt that
# `_widen` returns; the result is a new BigInt (`copy` of a BigInt returns the
# same object).
@inline _noscaletoken(conf::DefaultConf{Number}, source, startpos, pos, v::BigInt, neg, code, ndigits, f, options) =
    noscale(conf, MPZ.set(v), neg, code, ndigits, f, options)

# Other parsers' `scale` methods receive the exponent as an Int64, as before.
@inline _scaletoken(conf::AbstractConf, FT, source, startpos, pos, v, exp, neg, code, ndigits, f, options) =
    scale(conf, FT, v, Int64(clamp(exp, typemin(Int64), typemax(Int64))), neg, code, ndigits, f, options)
@inline _scaletoken(::DefaultConf{T}, FT, source, startpos, pos, v, exp, neg, code, ndigits, f, options) where {T <: Union{Float16, Float32, Float64}} =
    _scalefloat(T, FT, source, startpos, pos, v, exp, neg, code, f, options)
@inline _scaletoken(::DefaultConf{Number}, FT, source, startpos, pos, v, exp, neg, code, ndigits, f, options) =
    _scalefloat(Number, FT, source, startpos, pos, v, exp, neg, code, f, options)

# `v` × 10^exp correctly rounded; source[startpos:pos-1] is the token. `Number`
# targets produce Float64 (Float32 for an `f` exponent marker) and are invalid
# if not finite.
@inline function _scalefloat(::Type{T}, FT::FloatType, source, startpos, pos, v, exp, neg, code, f::F, options::Options) where {T, F}
    if T === Float64 || T === Float32 || T === Float16
        return handlef(_tofloat(T, source, startpos, pos, v, exp, neg, options), f), code
    elseif T === Number
        x = FT == FLOAT32 ? _tofloat(Float32, source, startpos, pos, v, exp, neg, options) :
                            _tofloat(Float64, source, startpos, pos, v, exp, neg, options)
        isfinite(x) || return nothing, code | INVALID
        return handlef(x, f), code
    end
    error("invalid float type for scale: `$T`")
end

@inline function _tofloat(::Type{T}, source, startpos, pos, v, exp, neg, options) where {T}
    mant, dropped, truncated, exact = _mantissa(v)
    parts = DecParts(mant, _decpartsexp32(Int128(exp) + dropped),
                     exact ? Int32(19) : Int32(20), truncated, neg)
    return _finishfloat(T, parts, _exactsource(source, v, exp), startpos, pos, options)
end

# Where the exact tier reads the digits: the token in the source, or for an `IO`
# source the exact digits kept while parsing.
@inline _exactsource(source, v, exp) = source
@inline _exactsource(::IO, v::Integer, exp) = (v, exp)

# (leading digits, dropped digit count, any dropped digit nonzero, all digits kept)
@inline _mantissa(v::UInt64) = (v, 0, false, true)
@inline _mantissa(v::Int64) = (unsigned(v), 0, false, true)
@inline _mantissa(v::LongMantissa) = (v.mant, v.dropped, v.sticky, false)
# Coefficients wider than 64 bits (`Number`, `IO` sources, or `scale` called
# directly) keep their first 19 digits.
function _mantissa(v::Union{Int128, UInt128})
    dropped = ndigits(v) - 19
    dropped <= 0 && return (UInt64(v), 0, false, true)
    q, r = divrem(v, oftype(v, 10)^dropped)
    return (UInt64(q), dropped, !iszero(r), false)
end
function _mantissa(v::Integer)
    dropped = ndigits(v) - 19
    dropped <= 0 && return (UInt64(v), 0, false, true)
    q, r = divrem(v, big(10)^dropped)
    return (UInt64(q), dropped, !iszero(r), false)
end

include("floatkernel.jl")
