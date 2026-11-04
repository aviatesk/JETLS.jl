# Correctly rounded decimal → Float16/Float32/Float64 conversion, ported from
# the Parsers 3 kernel:
#   1. exact small case (type-specific Clinger mantissa and exponent bounds):
#      one multiply/divide by an exactly representable power of ten
#   2. Eisel–Lemire: 128-bit product against the precomputed powers-of-five
#      table; bails (rarely) on rounding-boundary ambiguity
#   3. exact midpoint comparison in four UInt64 limbs, then a simple decimal
#      conversion over a fixed 800-digit buffer for larger cases
# Float32 is converted natively and Float16 through Float32 with an exact
# midpoint check, so neither double-rounds. Tiers 1-2 need only the first 19
# significant digits; tier 3 reads the token's digits again.

struct DecParts
    mant::UInt64      # up to 19 significant digits (truncated beyond)
    exp10::Int32      # power of ten applied to mant, saturated at ±typemax(Int32)
    ndig::Int32       # significant digits seen, saturated at typemax(Int32)
    truncated::Bool   # digits beyond 19 were dropped (a nonzero one ⇒ sticky)
    neg::Bool
end

const _DECPARTS_EXPONENT_CAP = UInt64(typemax(Int)) +
                               UInt64(typemax(Int32)) + UInt64(1)

@inline function _decimalexponentdigit(value::UInt64, digit::UInt8)
    limit = _DECPARTS_EXPONENT_CAP
    value > (limit - UInt64(digit)) ÷ UInt64(10) && return limit
    return UInt64(10) * value + UInt64(digit)
end

@inline _signeddecimalexponent(value::UInt64, neg::Bool) =
    neg ? -Int128(value) : Int128(value)

@inline function _boundedint(value::Int128)
    value > typemax(Int) && return typemax(Int)
    value < typemin(Int) && return typemin(Int)
    return Int(value)
end

@inline function _decpartsint32(value::Int)
    value > typemax(Int32) && return typemax(Int32)
    value < typemin(Int32) && return typemin(Int32)
    return Int32(value)
end

@inline function _decpartsexp32(value::Integer)
    limit = Int128(typemax(Int32))
    wide = Int128(value)
    wide > limit && return typemax(Int32)
    wide < -limit && return -typemax(Int32)
    return Int32(wide)
end

# Powers of five, 128-bit truncated significands, q ∈ POW5MIN:POW5MAX.
const POW5MIN = -342

const POW5MAX = 308

# Minimal limb machinery — exists solely to build the table at precompile time.
# Little-endian Vector{UInt64} limbs; operations: multiply by 5, bit length,
# extract top-128, and shifted compare/subtract driving one restoring division.
function _mul5!(a::Vector{UInt64})
    carry = zero(UInt64)
    @inbounds for k in eachindex(a)
        hi, lo = _mul64(a[k], UInt64(5))
        s = lo + carry
        a[k] = s
        carry = hi + (s < lo)
    end
    carry != 0 && push!(a, carry)
    return a
end

@inline function _mul64(x::UInt64, y::UInt64)
    p = UInt128(x) * UInt128(y)
    return (UInt64(p >> 64), UInt64(p & typemax(UInt64)))
end

function _bitlen(a::Vector{UInt64})
    @inbounds for k in length(a):-1:1
        a[k] != 0 && return 64 * (k - 1) + (64 - leading_zeros(a[k]))
    end
    return 0
end

@inline function _getbit(a::Vector{UInt64}, bit::Int)  # 0-based
    limb = bit >> 6 + 1
    limb > length(a) && return false
    return (a[limb] >> (bit & 63)) & 1 == 1
end

# top 128 bits of `a` (normalized so bit (bitlen-1) is the msb of hi)
function _top128(a::Vector{UInt64})
    bl = _bitlen(a)
    hi = zero(UInt64); lo = zero(UInt64)
    for b in 0:127
        src = bl - 1 - b
        bit = src >= 0 ? _getbit(a, src) : false
        if b < 64
            hi |= UInt64(bit) << (63 - b)
        else
            lo |= UInt64(bit) << (127 - b)
        end
    end
    sticky = false
    for b in 0:(bl - 129)
        if _getbit(a, b)
            sticky = true
            break
        end
    end
    return hi, lo, sticky
end

# is (a << s) <= r ?
function _shiftedle(a::Vector{UInt64}, s::Int, r::Vector{UInt64})
    bla = _bitlen(a) + s
    blr = _bitlen(r)
    bla != blr && return bla < blr
    for b in (blr - 1):-1:0
        ab = b - s >= 0 ? _getbit(a, b - s) : false
        rb = _getbit(r, b)
        ab != rb && return rb        # first difference: a<r iff r has the 1
    end
    return true
end

# r -= a << s   (requires (a<<s) ≤ r)
function _subshifted!(r::Vector{UInt64}, a::Vector{UInt64}, s::Int)
    limbshift = s >> 6
    bitshift = s & 63
    borrow = zero(UInt64)
    @inbounds for k in 1:length(r)
        ak = k - limbshift
        av = zero(UInt64)
        if 1 <= ak <= length(a)
            av = a[ak] << bitshift
            bitshift != 0 && ak > 1 && (av |= a[ak - 1] >> (64 - bitshift))
        elseif bitshift != 0 && 1 <= ak - 1 <= length(a) && ak == length(a) + 1
            av = a[ak - 1] >> (64 - bitshift)
        end
        d = r[k] - av
        b2 = d > r[k]
        d2 = d - borrow
        borrow = UInt64(b2 | (d2 > d))
        r[k] = d2
    end
    return r
end

function _buildpow5()
    n = POW5MAX - POW5MIN + 1
    HI = Vector{UInt64}(undef, n)
    LO = Vector{UInt64}(undef, n)
    # positive q (and q = 0): truncated top-128 of 5^q
    p = UInt64[1]
    for q in 0:POW5MAX
        hi, lo, _ = _top128(p)
        HI[q - POW5MIN + 1] = hi
        LO[q - POW5MIN + 1] = lo
        _mul5!(p)
    end
    # negative q: floor(2^(bitlen(5^p)+127) / 5^p) + 1  (reference table rule)
    p = UInt64[1]
    for q in -1:-1:POW5MIN
        _mul5!(p)                                 # p = 5^(-q)
        k = _bitlen(p) + 127
        # restoring division: quotient of 2^k / p has exactly 128 bits
        r = zeros(UInt64, (k >> 6) + 2)
        r[(k >> 6) + 1] |= UInt64(1) << (k & 63)
        qhi = zero(UInt64); qlo = zero(UInt64)
        for bit in 127:-1:0
            if _shiftedle(p, bit, r)
                _subshifted!(r, p, bit)
                if bit >= 64
                    qhi |= UInt64(1) << (bit - 64)
                else
                    qlo |= UInt64(1) << bit
                end
            end
        end
        qlo += 1                                   # the +1 (never overflows: quotient is odd-truncated)
        qlo == 0 && (qhi += 1)
        HI[q - POW5MIN + 1] = qhi
        LO[q - POW5MIN + 1] = qlo
    end
    return HI, LO
end

const POW5HI, POW5LO = _buildpow5()

# Eisel–Lemire core: value = mant × 10^q (mant ≠ 0, not truncated unless
# `truncated`). Returns reinterpretable bits, or -1 ⇒ tier 3 decides.
# Binary-format constants (fast_float's binary_format<T>): the same Eisel–
# Lemire and simple-decimal-conversion code serves Float64 and Float32 —
# Float32 is parsed NATIVELY (never Float64-then-round, which double-rounds).
@inline _mantbits(::Type{Float64}) = 52
@inline _mantbits(::Type{Float32}) = 23
@inline _mantbits(::Type{Float16}) = 10
@inline _bias(::Type{Float64}) = 1023
@inline _bias(::Type{Float32}) = 127
@inline _bias(::Type{Float16}) = 15
@inline _maxexp(::Type{Float64}) = 2047      # biased exponent of ±Inf
@inline _maxexp(::Type{Float32}) = 255
@inline _maxexp(::Type{Float16}) = 31
@inline _elshift(::Type{Float64}) = 9         # 64 - mantbits - 3: keeps mantbits+2 product bits
@inline _elshift(::Type{Float32}) = 38
@inline _tiemin(::Type{Float64}) = -4         # q range where the 128-bit product is exact
@inline _tiemax(::Type{Float64}) = 23
@inline _tiemin(::Type{Float32}) = -17
@inline _tiemax(::Type{Float32}) = 10
@inline _infbits(::Type{Float64}) = 0x7ff0000000000000
@inline _infbits(::Type{Float32}) = UInt64(0x7f800000)
@inline _infbits(::Type{Float16}) = UInt64(0x7c00)


# Returns the (unsigned) bit pattern of T as an Int64 ≥ 0, or a negative code:
# -1 ambiguous (tier 3 decides), -2 exponent outside the table (certain
# under/overflow — the caller decides which by q's sign), -3 overflow (±Inf).
# A ZERO bit pattern here means underflow-to-zero: mant is nonzero on entry.
@inline function _eisel_lemire(::Type{T}, mant::UInt64, q::Int) where {T <: Union{Float64, Float32}}
    (q < POW5MIN || q > POW5MAX) && return Int64(-2)   # certain under/overflow, sign applied by caller
    lz = leading_zeros(mant)
    w = mant << lz
    idx = q - POW5MIN + 1
    @inbounds t = UInt128(w) * UInt128(POW5HI[idx])
    hi = UInt64(t >> 64)
    lo = UInt64(t & typemax(UInt64))
    if (hi & 0x1ff) == 0x1ff                            # need more precision
        @inbounds t2 = UInt128(w) * UInt128(POW5LO[idx])
        hi2 = UInt64(t2 >> 64)
        lo0 = lo
        lo += hi2
        lo < lo0 && (hi += 1)
        (hi & 0x1ff) == 0x1ff && lo + 1 == 0 && return Int64(-1)  # still ambiguous
    end
    MB = _mantbits(T)
    upper = hi >> 63
    shift = Int(upper) + _elshift(T)
    m = hi >> shift                                     # MB+2 bits: MB+1 significand + round bit
    e2 = ((217706 * q) >> 16) + 63 + Int(upper) - lz    # unbiased binary exponent of hi's msb
    e2 += _bias(T)                                      # bias
    if e2 <= 0
        # Shift the guard-bit mantissa into the denormal range, then round it.
        # A carry can promote the result to the smallest normal. This is the
        # standard Eisel-Lemire subnormal step; rejecting here sends every
        # shortest subnormal through the cold exact-decimal tier.
        shift = -e2 + 1
        shift >= 64 && return Int64(0)                  # certain underflow
        m >>= shift
        m = (m + (m & 1)) >> 1
        e2 = m < (UInt64(1) << MB) ? 0 : 1
        return Int64((UInt64(e2) << MB) | (m & ((UInt64(1) << MB) - 1)))
    end
    # Exact halfway values in the small-power range: for -4 <= q <= 23 the
    # 128-bit product is EXACT (5^|q| fits; Mushtak & Lemire, "Fast Number
    # Parsing Without Fallback"), so a detected tie is a true tie and
    # round-half-even is applied here by clearing the low bit, without entering
    # the cold exact-conversion tier.
    if lo <= 1 && _tiemin(T) <= q <= _tiemax(T) && (m & 0b11) == 0b01 && (m << shift) == hi
        m &= ~UInt64(1)                                  # tie → even (do not round up)
    end
    m = (m + (m & 1)) >> 1                              # round to nearest, ties away resolved below
    if m == (UInt64(1) << (MB + 1))
        m >>= 1
        e2 += 1
    end
    e2 >= _maxexp(T) && return Int64(-3)                # overflow ⇒ ±Inf
    return Int64((UInt64(e2) << MB) | (m & ((UInt64(1) << MB) - 1)))
end

# Most tier-3 calls come from a long significand whose first 19 digits put the
# value on opposite sides of one IEEE rounding boundary. Resolve that boundary
# with four package-owned UInt64 limbs. This covers the common exact-halfway
# adversaries whenever the complete scaled comparison fits in 256 bits, without
# allocation. Inputs that need more precision continue to total SDC.
const _U256 = NTuple{4, UInt64}

const _POW5U64 = ntuple(k -> UInt64(5)^(k - 1), 28) # 5^0 through 5^27

const _POW5U128 = ntuple(k -> UInt128(5)^(k - 1), 56) # 5^0 through 5^55

@inline _u256(x::UInt64) = (x, zero(UInt64), zero(UInt64), zero(UInt64))

@inline function _u256mul(x::_U256, y::UInt64)
    mask = UInt128(typemax(UInt64))
    p = UInt128(x[1]) * y
    x1 = UInt64(p & mask)
    p = UInt128(x[2]) * y + (p >> 64)
    x2 = UInt64(p & mask)
    p = UInt128(x[3]) * y + (p >> 64)
    x3 = UInt64(p & mask)
    p = UInt128(x[4]) * y + (p >> 64)
    x4 = UInt64(p & mask)
    return ((x1, x2, x3, x4), (p >> 64) == 0)
end

@inline function _u256muladd10(x::_U256, digit::UInt8)
    mask = UInt128(typemax(UInt64))
    p = UInt128(x[1]) * 10 + digit
    x1 = UInt64(p & mask)
    p = UInt128(x[2]) * 10 + (p >> 64)
    x2 = UInt64(p & mask)
    p = UInt128(x[3]) * 10 + (p >> 64)
    x3 = UInt64(p & mask)
    p = UInt128(x[4]) * 10 + (p >> 64)
    x4 = UInt64(p & mask)
    return ((x1, x2, x3, x4), (p >> 64) == 0)
end

@inline function _u256pow5(x::_U256, exponent::Int)
    exponent >= 0 || return (x, false)
    exponent <= 110 || return (x, false) # 5^111 is wider than 256 bits
    while exponent >= 27
        x, ok = _u256mul(x, _POW5U64[28])
        ok || return (x, false)
        exponent -= 27
    end
    x, ok = _u256mul(x, _POW5U64[exponent + 1])
    return (x, ok)
end

@inline function _u256shl(x::_U256, shift::Int)
    shift >= 0 || return (x, false)
    shift == 0 && return (x, true)
    shift < 256 || return (x, false)
    words = shift >> 6
    bits = shift & 63
    x1, x2, x3, x4 = x
    z = zero(UInt64)
    if bits == 0
        words == 1 && return ((z, x1, x2, x3), x4 == 0)
        words == 2 && return ((z, z, x1, x2), (x3 | x4) == 0)
        return ((z, z, z, x1), (x2 | x3 | x4) == 0)
    end
    rshift = 64 - bits
    if words == 0
        return ((x1 << bits,
                 (x2 << bits) | (x1 >> rshift),
                 (x3 << bits) | (x2 >> rshift),
                 (x4 << bits) | (x3 >> rshift)),
                (x4 >> rshift) == 0)
    elseif words == 1
        return ((z, x1 << bits,
                 (x2 << bits) | (x1 >> rshift),
                 (x3 << bits) | (x2 >> rshift)),
                x4 == 0 && (x3 >> rshift) == 0)
    elseif words == 2
        return ((z, z, x1 << bits, (x2 << bits) | (x1 >> rshift)),
                (x3 | x4) == 0 && (x2 >> rshift) == 0)
    else
        return ((z, z, z, x1 << bits),
                (x2 | x3 | x4) == 0 && (x1 >> rshift) == 0)
    end
end

@inline function _u256cmp(x::_U256, y::_U256)
    x[4] != y[4] && return x[4] < y[4] ? -1 : 1
    x[3] != y[3] && return x[3] < y[3] ? -1 : 1
    x[2] != y[2] && return x[2] < y[2] ? -1 : 1
    return x[1] == y[1] ? 0 : x[1] < y[1] ? -1 : 1
end

# Parse the exact decimal as `significand * 10^exponent`. Pending zero digits
# are committed only when followed by a nonzero digit, so trailing zeros do not
# consume limb capacity.
function _u256decimal(buf::AbstractVector{UInt8}, i::Int, j::Int,
                      decimal::UInt8, groupmark=nothing)
    @inbounds if i <= j && (buf[i] == UInt8('-') || buf[i] == UInt8('+'))
        i += 1
    end
    x = _u256(zero(UInt64))
    started = false
    point = false
    fraction = 0
    pendingzeros = 0
    exponent = Int128(0)
    @inbounds while i <= j
        byte = buf[i]
        digit = byte - UInt8('0')
        if digit <= 0x09
            point && (fraction += 1)
            if !started
                if digit != 0
                    x, ok = _u256muladd10(x, digit)
                    ok || return (x, 0, false)
                    started = true
                end
            elseif digit == 0
                pendingzeros += 1
            else
                pendingzeros <= 76 || return (x, 0, false)
                for _ in 1:pendingzeros
                    x, ok = _u256muladd10(x, 0x00)
                    ok || return (x, 0, false)
                end
                x, ok = _u256muladd10(x, digit)
                ok || return (x, 0, false)
                pendingzeros = 0
            end
        elseif byte == decimal
            point = true
        elseif groupmark !== nothing && byte == groupmark
            # The prefix or grouped-span decomposer already validated that
            # marks occur only between integer digits. Exact rounding rereads
            # digits, not grammar.
        else
            i += 1
            eneg = false
            @inbounds if i <= j && (buf[i] == UInt8('-') || buf[i] == UInt8('+'))
                eneg = buf[i] == UInt8('-')
                i += 1
            end
            e = zero(UInt64)
            @inbounds while i <= j
                e = _decimalexponentdigit(e, buf[i] - UInt8('0'))
                i += 1
            end
            exponent = _signeddecimalexponent(e, eneg)
            break
        end
        i += 1
    end
    started || return (x, 0, false)
    decimalplaces = fraction - pendingzeros
    # The fixed-limb comparison necessarily overflows outside this range.
    # Check before subtracting so even a lazy, enormous byte vector cannot wrap.
    q = exponent - Int128(decimalplaces)
    -110 <= q <= 110 || return (x, 0, false)
    return (x, Int(q), true)
end

@inline function _floatmidpoint(::Type{T}, bits::UInt64) where {T <: Union{Float64, Float32, Float16}}
    MB = _mantbits(T)
    mask = (UInt64(1) << MB) - 1
    biased = Int(bits >> MB)
    mant = bits & mask
    if biased == 0
        exponent = 1 - _bias(T) - MB
    else
        mant |= UInt64(1) << MB
        exponent = biased - _bias(T) - MB
    end
    return (2mant + 1, exponent - 1)
end

function _u256midpointcmp(::Type{T}, buf::AbstractVector{UInt8}, i::Int, j::Int,
                          decimal::UInt8,
                          lowerbits::UInt64, groupmark=nothing) where
                          {T <: Union{Float64, Float32, Float16}}
    real, exponent10, ok = _u256decimal(buf, i, j, decimal, groupmark)
    ok || return (0, false)
    midpoint, exponent2 = _floatmidpoint(T, lowerbits)
    theoretical = _u256(midpoint)
    if exponent10 >= 0
        real, ok = _u256pow5(real, exponent10)
    else
        theoretical, ok = _u256pow5(theoretical, -exponent10)
    end
    ok || return (0, false)
    shift = exponent10 - exponent2
    if shift >= 0
        real, ok = _u256shl(real, shift)
    else
        theoretical, ok = _u256shl(theoretical, -shift)
    end
    ok || return (0, false)
    return (_u256cmp(real, theoretical), true)
end

# Short Float16 boundaries fit in one UInt128. Reusing the exact decimal parts
# avoids a second digit-by-digit fixed-limb parse on this latency-sensitive
# midpoint path.
@inline function _u128midpointcmp(parts::DecParts, lowerbits::UInt64)
    parts.truncated && return (0, false)
    real = UInt128(parts.mant)
    midpoint, exponent2 = _floatmidpoint(Float16, lowerbits)
    theoretical = UInt128(midpoint)
    exponent10 = Int(parts.exp10)
    power = abs(exponent10)
    power <= 55 || return (0, false)
    factor = @inbounds _POW5U128[power + 1]
    if exponent10 >= 0
        real <= typemax(UInt128) ÷ factor || return (0, false)
        real *= factor
    else
        theoretical <= typemax(UInt128) ÷ factor || return (0, false)
        theoretical *= factor
    end
    shift = exponent10 - exponent2
    if shift >= 0
        shift < 128 && real <= typemax(UInt128) >> shift || return (0, false)
        real <<= shift
    else
        shift = -shift
        shift < 128 && theoretical <= typemax(UInt128) >> shift || return (0, false)
        theoretical <<= shift
    end
    return (real == theoretical ? 0 : real < theoretical ? -1 : 1, true)
end

@inline function _decimalisexactfloat64(parts::DecParts)
    exponent = Int(parts.exp10)
    power = abs(exponent)
    power <= 27 || return false
    factor = @inbounds _POW5U64[power + 1]
    if exponent < 0
        return parts.mant % factor == 0
    end
    return parts.mant <= (UInt64(1) << 53) ÷ factor
end

@noinline function _exactfloatfromparts(::Type{T}, parts::DecParts,
                                        buf::AbstractVector{UInt8}, i::Int,
                                        j::Int, neg::Bool,
                                        decimal::UInt8, groupmark=nothing) where
                                        {T <: Union{Float64, Float32}}
    if parts.truncated || parts.ndig > 19
        lower = _eisel_lemire(T, parts.mant, Int(parts.exp10))
        upper = _eisel_lemire(T, parts.mant + 1, Int(parts.exp10))
        if 0 <= lower < _infbits(T) && upper == lower + 1 <= _infbits(T)
            cmp, resolved = _u256midpointcmp(T, buf, i, j, decimal,
                                             UInt64(lower), groupmark)
            if resolved
                bits = cmp < 0 || (cmp == 0 && iseven(lower)) ? UInt64(lower) : UInt64(upper)
                return _sign(T, bits, neg)
            end
        end
    end
    return _sdc(T, buf, i, j, neg, decimal, groupmark)
end

const SDC_MAXDIG = 800   # 768-digit worst case + slack

# Fixed-size decimal 0.d₁d₂…dₙ × 10^dp: d₁ is nonzero and dₙ is the last
# nonzero digit. Binary shifts are exact except that digits past the 800th are
# dropped; `sticky` records a dropped nonzero digit, which matters only when the
# kept digits sit exactly halfway between two results.
mutable struct HPD
    d::Vector{UInt8}
    n::Int
    dp::Int
    sticky::Bool
end

function _hpd(buf::AbstractVector{UInt8}, i::Int, j::Int, decimal::UInt8,
              groupmark=nothing)
    d = Vector{UInt8}(undef, SDC_MAXDIG)
    n = 0
    dp = 0
    sticky = false
    sawpoint = false
    sawdig = false
    k = i
    @inbounds if k <= j && (buf[k] == UInt8('-') || buf[k] == UInt8('+'))
        k += 1
    end
    @inbounds while k <= j
        b = buf[k]
        dig = b - UInt8('0')
        if dig <= 0x09
            sawdig = true
            if n == 0 && dig == 0
                sawpoint && (dp -= 1)
            else
                if n < SDC_MAXDIG
                    n += 1
                    d[n] = dig
                else
                    sticky |= dig != 0
                end
                sawpoint || (dp += 1)
            end
        elseif b == decimal
            sawpoint = true
        elseif groupmark !== nothing && b == groupmark
            # Shape was validated by the owning decomposer.
        else # exponent (structure already validated by _decompose)
            k += 1
            eneg = false
            @inbounds if k <= j && (buf[k] == UInt8('-') || buf[k] == UInt8('+'))
                eneg = buf[k] == UInt8('-')
                k += 1
            end
            e = zero(UInt64)
            @inbounds while k <= j
                e = _decimalexponentdigit(e, buf[k] - UInt8('0'))
                k += 1
            end
            dp = _boundedint(Int128(dp) + _signeddecimalexponent(e, eneg))
            break
        end
        k += 1
    end
    while n > 0 && d[n] == 0
        n -= 1
    end
    return HPD(d, n, dp, sticky)
end

@inline function _hpdtrim!(h::HPD)
    @inbounds while h.n > 0 && h.d[h.n] == 0
        h.n -= 1
    end
    h.n == 0 && (h.dp = 0)
    return h
end

# A shift moves at most _SDC_MAXSHIFT bits per pass, in machine words: a digit
# times 2^k plus a carry below 2^k stays below 10 · 2^k, which fits a word for
# k up to the word size minus 4 (60 bits on 64-bit hosts, 28 on 32-bit ones).
const _SDC_MAXSHIFT = Sys.WORD_SIZE - 4

# 5^k as decimal digits, most significant first
function _pow5decimal(k::Int)
    d = UInt8[1]
    for _ in 1:k
        carry = 0
        for idx in length(d):-1:1
            v = 5 * Int(d[idx]) + carry
            d[idx] = UInt8(v % 10)
            carry = v ÷ 10
        end
        carry == 0 || pushfirst!(d, UInt8(carry))
    end
    return d
end

# Multiplying by 2^k adds ndigits(2^k) leading digits, or one fewer when the
# digits compare below those of 5^k (because 2^k · 5^k = 10^k).
const _LSHIFTDIGITS = ntuple(k -> ndigits(UInt64(1) << k), _SDC_MAXSHIFT)
const _LSHIFTCUTOFF = [_pow5decimal(k) for k in 1:_SDC_MAXSHIFT]

@inline function _hpdbelow(h::HPD, cutoff::Vector{UInt8})
    @inbounds for k in eachindex(cutoff)
        k > h.n && return true
        h.d[k] == cutoff[k] || return h.d[k] < cutoff[k]
    end
    return false
end

# value *= 2^k for 1 ≤ k ≤ _SDC_MAXSHIFT
function _hpdleftshift!(h::HPD, k::Int)
    delta = @inbounds _LSHIFTDIGITS[k]
    _hpdbelow(h, @inbounds _LSHIFTCUTOFF[k]) && (delta -= 1)
    r = h.n            # next digit to read, from the right
    w = h.n + delta    # next digit to write
    n = zero(UInt)
    while r > 0 || n > 0
        if r > 0
            n += UInt(@inbounds(h.d[r])) << k
            r -= 1
        end
        q = n ÷ 10
        if w <= SDC_MAXDIG
            h.d[w] = UInt8(n - 10q)
        else
            h.sticky |= n != 10q
        end
        w -= 1
        n = q
    end
    h.n = min(h.n + delta, SDC_MAXDIG)
    h.dp += delta
    return _hpdtrim!(h)
end

# value /= 2^k for 1 ≤ k ≤ _SDC_MAXSHIFT
function _hpdrightshift!(h::HPD, k::Int)
    r = 0
    n = zero(UInt)
    while n >> k == 0  # read until the first quotient digit is nonzero
        if r < h.n
            r += 1
            n = 10n + @inbounds(h.d[r])
        elseif n == 0
            h.n = 0
            h.dp = 0
            return h
        else
            n *= 10    # past the last digit, read zeros
            r += 1
        end
    end
    h.dp -= r - 1
    mask = (one(UInt) << k) - one(UInt)
    w = 0
    while r < h.n
        r += 1
        c = @inbounds h.d[r]
        w += 1
        h.d[w] = UInt8(n >> k)
        n = 10 * (n & mask) + c
    end
    while n > 0
        if w < SDC_MAXDIG
            w += 1
            h.d[w] = UInt8(n >> k)
        else
            h.sticky |= n >> k != 0
        end
        n = 10 * (n & mask)
    end
    h.n = w
    return _hpdtrim!(h)
end

# value *= 2^k for any k, in passes of at most _SDC_MAXSHIFT bits
function _hpdshift!(h::HPD, k::Int)
    while k > 0
        s = min(k, _SDC_MAXSHIFT)
        _hpdleftshift!(h, s)
        k -= s
    end
    while k < 0
        s = min(-k, _SDC_MAXSHIFT)
        _hpdrightshift!(h, s)
        k += s
    end
    return h
end

# The integer nearest the value, ties to even; a sticky tail breaks a tie upward.
function _hpdroundedinteger(h::HPD)
    n = zero(UInt64)
    k = 0
    while k < h.dp
        k += 1
        n = 10n + (k <= h.n ? @inbounds(h.d[k]) : 0x00)
    end
    nd = h.dp
    roundup = false
    if 0 <= nd < h.n
        d = @inbounds h.d[nd + 1]
        roundup = d > 5 || (d == 5 && (nd + 1 < h.n || h.sticky ||
                                       (nd > 0 && isodd(@inbounds h.d[nd]))))
    end
    return n + roundup
end

# Scaling a decimal with dp = ±n shifts by _sdcshift(n) bits; 2^shift < 10^n,
# so a left shift from below 1 stays below 1.
const _SDC_POWERS = (3, 6, 9, 13, 16, 19, 23, 26, 29, 33, 36, 39, 43, 46, 49, 53, 56, 59)
@inline _sdcshift(n::Int) =
    n <= length(_SDC_POWERS) ? min(@inbounds(_SDC_POWERS[n]), _SDC_MAXSHIFT) : _SDC_MAXSHIFT

# Simple decimal conversion: scale the exact decimal into [1/2, 1) by binary
# shifts of up to _SDC_MAXSHIFT bits, then round the top MB + 1 bits half to even.
@noinline function _sdc(::Type{T}, buf::AbstractVector{UInt8}, i::Int, j::Int, neg::Bool,
                        decimal::UInt8, groupmark=nothing) where
                        {T <: Union{Float64, Float32, Float16}}
    MB = _mantbits(T)
    h = _hpd(buf, i, j, decimal, groupmark)
    h.n == 0 && return _sign(T, zero(UInt64), neg)
    # every target rounds a value below 10^-330 to zero and overflows from 10^310
    h.dp < -330 && return _sign(T, zero(UInt64), neg)
    h.dp > 310 && return _sign(T, _infbits(T), neg)
    e2 = 0                                   # value = h × 2^e2
    while h.dp > 0
        s = _sdcshift(h.dp)
        _hpdrightshift!(h, s)
        e2 += s
    end
    while h.dp < 0 || (h.dp == 0 && @inbounds(h.d[1]) < 5)
        s = h.dp < 0 ? _sdcshift(-h.dp) : @inbounds(h.d[1]) < 2 ? 2 : 1
        _hpdleftshift!(h, s)
        e2 -= s
    end
    e2 -= 1                                  # h in [1/2, 1), so value = 2h × 2^e2
    emin = 1 - _bias(T)
    if e2 < emin
        # subnormal: shift the value down to the smallest normal exponent; below
        # half the smallest subnormal it rounds to zero
        emin - e2 >= MB + 2 && return _sign(T, zero(UInt64), neg)
        _hpdshift!(h, e2 - emin)
        e2 = emin
    end
    e2 + _bias(T) >= _maxexp(T) && return _sign(T, _infbits(T), neg)
    _hpdshift!(h, MB + 1)                    # the implicit bit and MB stored bits
    mant = _hpdroundedinteger(h)
    if mant == UInt64(2) << MB               # rounding carried into a new bit
        mant >>= 1
        e2 += 1
        e2 + _bias(T) >= _maxexp(T) && return _sign(T, _infbits(T), neg)
    end
    biased = iszero(mant & (UInt64(1) << MB)) ? 0 : e2 + _bias(T)  # subnormal: biased 0
    return _sign(T, (UInt64(biased) << MB) | (mant & ((UInt64(1) << MB) - 1)), neg)
end

@inline _sign(::Type{Float64}, bits::UInt64, neg::Bool) =
    reinterpret(Float64, bits | (UInt64(neg) << 63))

@inline _sign(::Type{Float32}, bits::UInt64, neg::Bool) =
    reinterpret(Float32, UInt32(bits) | (UInt32(neg) << 31))

@inline _sign(::Type{Float16}, bits::UInt64, neg::Bool) =
    reinterpret(Float16, UInt16(bits) | (UInt16(neg) << 15))

@inline _lower(b::UInt8) = b | 0x20

# Clinger's exact case: one correctly rounded multiply or divide by an exactly
# representable power of ten. Both are computed and one is selected; a branch
# on the exponent's sign would resolve only after the whole token is scanned.
@inline function _clinger(f::T, q::Int, powers::Vector{T}) where {T}
    p = @inbounds powers[abs(q) + 1]
    return ifelse(q >= 0, f * p, f / p)
end

@inline function _convertparts(::Type{T}, parts::DecParts) where {T <: Union{Float64, Float32}}
    mant = parts.mant
    q = Int(parts.exp10)
    mant == 0 && return (parts.neg ? -zero(T) : zero(T), true)
    untrunc = !parts.truncated && parts.ndig <= 19
    # tier 1 (Clinger): mant and 10^|q| both exactly representable → one rounding
    if T === Float64
        if untrunc && -22 <= q <= 22 && mant <= 9007199254740992   # 2^53
            f = _clinger(Float64(mant), q, _POW10)
            return (parts.neg ? -f : f, true)
        end
    else
        if untrunc && -10 <= q <= 10 && mant <= 16777216             # 2^24
            f = _clinger(Float32(mant), q, _POW10F32)
            return (parts.neg ? -f : f, true)
        end
    end
    bits = _eisel_lemire(T, mant, q)
    if !untrunc && bits >= 0
        # truncated mantissa: decided only if mant and mant+1 round identically
        # (the reference fast_float rule); otherwise the digits must speak (tier 3)
        bits2 = _eisel_lemire(T, mant + 1, q)
        bits2 == bits || return (parts.neg ? -one(T) : one(T), false)
    end
    # mant is nonzero here, so a zero pattern is underflow and the Inf
    # pattern is overflow.
    bits >= 0 && return (_sign(T, UInt64(bits), parts.neg), true)
    if bits == Int64(-2)
        return (q < 0 ? (parts.neg ? -zero(T) : zero(T)) :
                        (parts.neg ? -T(Inf) : T(Inf)), true)
    elseif bits == Int64(-3)
        return (parts.neg ? -T(Inf) : T(Inf), true)
    end
    return (parts.neg ? -one(T) : one(T), false)   # tier 3 required; sign in value
end

@noinline function _exactfloat16fromparts(parts::DecParts,
                                          buf::AbstractVector{UInt8}, i::Int, j::Int,
                                          neg::Bool, decimal::UInt8,
                                          lowerbits::UInt64, groupmark=nothing)
    cmp, resolved = _u128midpointcmp(parts, lowerbits)
    if !resolved
        cmp, resolved = _u256midpointcmp(Float16, buf, i, j, decimal,
                                         lowerbits, groupmark)
    end
    if resolved
        bits = cmp < 0 || (cmp == 0 && iseven(lowerbits)) ? lowerbits : lowerbits + 1
        return _sign(Float16, bits, neg)
    end
    return _sdc(Float16, buf, i, j, neg, decimal, groupmark)
end

# Float64 and Float32 have enough precision to identify the only possible
# Float16 double-rounding hazard: an exact midpoint between adjacent Float16
# values. Re-read the original decimal only at that boundary.
@inline function _float16stage(value::T) where {T <: Union{Float64, Float32}}
    if !isfinite(value) || iszero(value)
        return (Float16(value), false, zero(UInt64))
    end
    value16 = Float16(value)
    magnitude = abs(value)
    magnitude16 = abs(value16)
    widened16 = T(magnitude16)
    widened16 == magnitude && return (value16, false, zero(UInt64))
    roundedbits = UInt64(reinterpret(UInt16, magnitude16))
    lowerbits = widened16 < magnitude ? roundedbits : roundedbits - 1
    midpoint, exponent = _floatmidpoint(Float16, lowerbits)
    exact = magnitude == ldexp(T(midpoint), exponent)
    return (value16, exact, lowerbits)
end

# Finish a bounded decimal decomposition through Float64. A decimal with at
# most 53 coefficient bits and a small power of ten is exact enough to detect
# the sole wider-to-Float16 hazard. The coefficient then resolves that midpoint
# directly, without reading the digits again.
@inline function _smallfloat16fromparts(parts::DecParts)
    mant = parts.mant
    q = Int(parts.exp10)
    (!parts.truncated && parts.ndig <= 19 && mant <= UInt64(1) << 53 && -22 <= q <= 22) ||
        return (zero(Float16), false)

    value64 = _clinger(Float64(mant), q, _POW10)
    parts.neg && (value64 = -value64)
    value16, exact, lowerbits = _float16stage(value64)
    exact || return (value16, true)

    if _decimalisexactfloat64(parts)
        bits = iseven(lowerbits) ? lowerbits : lowerbits + 1
    else
        cmp, resolved = _u128midpointcmp(parts, lowerbits)
        resolved || return (zero(Float16), false)
        bits = cmp < 0 || (cmp == 0 && iseven(lowerbits)) ? lowerbits : lowerbits + 1
    end
    return (_sign(Float16, bits, parts.neg), true)
end

# The correctly rounded `T` for `parts`, the decomposition of the token at
# source[startpos:pos-1]. Clinger's exact case stays inline at every caller;
# the other tiers are one shared call.
@inline function _finishfloat(::Type{T}, parts::DecParts, source, startpos, pos,
                              options) where {T}
    mant = parts.mant
    q = Int(parts.exp10)
    if !parts.truncated && parts.ndig <= 19
        if T === Float32
            if -10 <= q <= 10 && mant <= UInt64(1) << 24
                f = _clinger(Float32(mant), q, _POW10F32)
                return parts.neg ? -f : f
            end
        elseif -22 <= q <= 22 && mant <= UInt64(1) << 53
            f = _clinger(Float64(mant), q, _POW10)
            T === Float64 && return parts.neg ? -f : f
            # Float16: a Float64 that is not a Float16 midpoint rounds once
            value16, exact, _ = _float16stage(parts.neg ? -f : f)
            exact || return value16
        end
    end
    return _finishfloatslow(T, parts, source, startpos, pos, options)
end

# The tiers past Clinger's case. The digits are read again only for a value
# that the 64-bit tiers cannot place.
@noinline function _finishfloatslow(::Type{T}, parts::DecParts, source, startpos,
                                    pos, options) where {T <: Union{Float64, Float32}}
    value, done = _convertparts(T, parts)
    done && return value
    buf, i, j = _tokenspan(source, startpos, pos)
    return _exactfloatfromparts(T, parts, buf, i, j, parts.neg, options.decimal,
                                options.groupmark)
end

@noinline function _finishfloatslow(::Type{Float16}, parts::DecParts, source,
                                    startpos, pos, options)
    value16, handled = _smallfloat16fromparts(parts)
    handled && return value16
    value32, done = _convertparts(Float32, parts)
    exact = false
    lowerbits = zero(UInt64)
    if done
        value16, exact, lowerbits = _float16stage(value32)
        exact || return value16
    end
    buf, i, j = _tokenspan(source, startpos, pos)
    if !done
        value32 = _exactfloatfromparts(Float32, parts, buf, i, j, parts.neg,
                                       options.decimal, options.groupmark)
        value16, exact, lowerbits = _float16stage(value32)
        exact || return value16
    end
    return _exactfloat16fromparts(parts, buf, i, j, signbit(value32),
                                  options.decimal, lowerbits, options.groupmark)
end

# The token bytes source[startpos:pos-1] as a byte span.
@inline _tokenspan(source::AbstractVector{UInt8}, startpos, pos) =
    (source, Int(startpos), Int(pos) - 1)
@inline _tokenspan(source::AbstractString, startpos, pos) =
    (codeunits(source), Int(startpos), Int(pos) - 1)
# Exact digits `v` and exponent `e` in place of a token: from `scale` called
# directly, or from an `IO` source, which can't be read twice.
@noinline function _tokenspan(source::Tuple{Integer, Integer}, startpos, pos)
    buf = Vector{UInt8}(string(source[1], "e", source[2]))
    return (buf, 1, length(buf))
end

const _POW10F32 = Float32[10.0f0^k for k in 0:10]

const _POW10 = Float64[10.0^k for k in 0:22]
