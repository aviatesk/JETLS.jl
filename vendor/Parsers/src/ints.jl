overflows(::Type{T}) where {T} = true
overflows(::Type{BigInt}) = false
overflowval(::Type{T}) where {T <: Integer} = div(typemax(T) - T(9), T(10))
# if we eventually support non-base 10
# overflowval(::Type{T}, base) where {T <: Integer} = div(typemax(T) - base + 1, base)

# BigInt magnitude from a buffer of raw decimal digit values (each 0..9) using
# GMP's string-to-limb converter. The limb multiply-accumulate used for other
# integer widths is quadratic in the digit count; GMP's converter is
# subquadratic. `__gmpn_set_str` can touch one limb past the value's
# significant limbs while it accumulates, so the destination carries a two-limb
# scratch margin, matching GMP's own `mpz_set_str`.
const _BIGINT_SETSTR_SCRATCH_LIMBS = 2

@inline function _bigint_decimal_limbs(ndig::Int)
    bits = (widemul(ndig, 3402) >> 10) + 1   # ⌈ndig·log2(10)⌉ + 1, base 10
    return Int(cld(bits, 8 * sizeof(Base.GMP.Limb)))
end

function _bigint_from_digit_values(digits::Vector{UInt8}, ndig::Int, neg::Bool)
    # Skip leading zero digits, as mpz_set_str does: from a zero leading digit
    # __gmpn_set_str may return zero high limbs, and a BigInt's top limb must
    # be nonzero.
    first = 1
    while first <= ndig && @inbounds(digits[first]) == 0x00
        first += 1
    end
    ndig -= first - 1
    ndig == 0 && return BigInt(0)
    nlimbs = _bigint_decimal_limbs(ndig) + _BIGINT_SETSTR_SCRATCH_LIMBS
    big = BigInt(; nbits = nlimbs * 8 * sizeof(Base.GMP.Limb))
    rawsize = GC.@preserve big digits ccall((:__gmpn_set_str, :libgmp), Clong,
        (Ptr{Base.GMP.Limb}, Ptr{UInt8}, Csize_t, Cint),
        big.d, pointer(digits, first), ndig, 10)
    big.size = (neg && rawsize != 0) ? -(rawsize % Cint) : (rawsize % Cint)
    return big
end

# BigInt integer parsing collects digit values and converts with GMP so a long
# token takes subquadratic time. The control flow mirrors the generic integer
# `typeparser` first loop (BigInt never overflows, so the widening loop below it
# is unreachable); only the per-digit accumulation differs.
@inline function typeparser(::AbstractConf{BigInt}, source, pos, len, b, code, pl, opts)
    digits = UInt8[]
    neg = false
    has_groupmark = _has_groupmark(opts, code)
    groupmark0 = something(opts.groupmark, 0xff) - UInt8('0')
    neg = b == UInt8('-')
    if neg || b == UInt8('+')
        pos += 1
        incr!(source)
    end
    if eof(source, pos, len)
        code |= INVALID | EOF
        @goto done
    end
    b = peekbyte(source, pos) - UInt8('0')
    if b > 0x09
        code |= INVALID
        @goto done
    end
    prev_b0 = b
    while true
        if b <= 0x09
            push!(digits, b)
            pos += 1
            incr!(source)
            if eof(source, pos, len)
                code |= OK | EOF
                @goto done
            end
        elseif has_groupmark && b == groupmark0
            prev_b0 == groupmark0 && (code |= INVALID; @goto done) # two groupmarks in a row
            pos += 1
            Parsers.incr!(source)
            Parsers.eof(source, pos, len) && (code |= INVALID | EOF; @goto done) # groupmark at end of input
        else
            # non-digit terminator; cannot end on a groupmark
            (has_groupmark && prev_b0 == groupmark0) ? (code |= INVALID) : (code |= OK)
            @goto done
        end
        prev_b0 = b
        b = peekbyte(source, pos) - UInt8('0')
    end

@label done
    x = ok(code) ? _bigint_from_digit_values(digits, length(digits), neg) : BigInt(0)
    return pos, code, PosLen(pl.pos, pos - pl.pos), x
end

@inline function typeparser(::AbstractConf{T}, source, pos, len, b, code, pl, opts) where {T <: Integer}
    x = zero(T)
    neg = false
    has_groupmark = _has_groupmark(opts, code)
    groupmark0 = something(opts.groupmark, 0xff) - UInt8('0')
    # start actual int parsing
    neg = b == UInt8('-')
    if neg || b == UInt8('+')
        pos += 1
        incr!(source)
    end
    if eof(source, pos, len)
        code |= INVALID | EOF
        @goto done
    end
    b = peekbyte(source, pos) - UInt8('0')
    if b > 0x09
        # character isn't a digit, INVALID value
        code |= INVALID
        @goto done
    end
    prev_b0 = b
    while true
        if b <= 0x09
            overflows(T) && x > overflowval(T) && break
            x = T(10) * x + unsafe_trunc(T, b)
            pos += 1
            incr!(source)
            if eof(source, pos, len)
                x = ifelse(neg, -x, x)
                code |= OK | EOF
                @goto done
            end
        elseif has_groupmark && b == groupmark0
            prev_b0 == groupmark0 && (code |= INVALID; @goto done) # two groupmarks in a row
            pos += 1
            Parsers.incr!(source)
            Parsers.eof(source, pos, len) && (code |= INVALID | EOF; @goto done) # groupmark at end of input
        else
            # detected a non-digit, time to bail on value parsing
            x = ifelse(neg, -x, x)
            # Cannot end on a groupmark
            (has_groupmark && prev_b0 == groupmark0) ? (code |= INVALID) : (code |= OK)
            @goto done
        end
        prev_b0 = b
        b = peekbyte(source, pos) - UInt8('0')
    end
    # extra loop because we got too close to overflowing while parsing digits
    x = ifelse(neg, -x, x)
    while true
        if b <= 0x09
            x, ov_mul = Base.mul_with_overflow(x, T(10))
            x, ov_add = Base.add_with_overflow(x, ifelse(neg, -T(b), T(b)))
            if ov_mul | ov_add
                # we overflowed, mark as OVERFLOW
                code |= OVERFLOW
                # in this case, we know b is a digit that caused us
                # to overflow, so we don't really want to consider it for
                # a close quote character or delimiter, so if b is the last character
                # let's just bail as eof
                pos += 1
                incr!(source)
                if eof(source, pos, len)
                    code |= EOF
                end
                @goto done
            end
            pos += 1
            incr!(source)
            if eof(source, pos, len)
                code |= OK | EOF
                @goto done
            end
        elseif has_groupmark && b == groupmark0
            prev_b0 == groupmark0 && (code |= INVALID; @goto done) # two groupmarks in a row
            pos += 1
            Parsers.incr!(source)
            Parsers.eof(source, pos, len) && (code |= INVALID | EOF; @goto done) # groupmark at end of input
        else
            # detected a non-digit, time to bail on value parsing
            x = ifelse(neg, -x, x)
            # Cannot end on a groupmark
            (has_groupmark && prev_b0 == groupmark0) ? (code |= INVALID) : (code |= OK)
            @goto done
        end
        prev_b0 = b
        b = peekbyte(source, pos) - UInt8('0')
    end

@label done
    return pos, code, PosLen(pl.pos, pos - pl.pos), x
end

function typeparser(::AbstractConf{Number}, source, pos, len, b, code, pl, opts)
    x = Ref{Number}()
    pos, code = parsenumber(source, pos, len, b, y -> (x[] = y), opts)
    return pos, code, PosLen(pl.pos, pos - pl.pos), isdefined(x, :x) ? x[] : (0::Number)
end

function parsenumber(source, pos, len, b, f::F, opts=OPTIONS) where {F}
    startpos = pos
    code = startcode = SUCCESS
    # begin parsing
    neg = b == UInt8('-')
    if neg || b == UInt8('+')
        pos += 1
        incr!(source)
    end
    if eof(source, pos, len)
        code |= INVALID | EOF
        @goto done
    end
    b = peekbyte(source, pos)
    # parse rest of number
    _, code, pos = parsedigits(DefaultConf{Number}(), source, pos, len, b, code, OPTIONS, Int64(0), neg, startpos, true, 0, f)
    if invalid(code)
        # by default, parsedigits only has up to Float64 precision; if we overflow
        # let's try BigFloat
        pos, code, _, x = typeparser(DefaultConf{BigFloat}(), source, startpos, len, b, startcode, poslen(pos, 0), opts)
        if ok(code)
            f(x)
        end
    end

@label done
    return pos, code
end
