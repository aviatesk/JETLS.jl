struct Delim{T} <: Dates.AbstractDateToken
    d::T
end

charactercode(::Dates.DatePart{c}) where {c} = c

function Format(f::AbstractString, locale::Dates.DateLocale=Dates.ENGLISH)
    tokens = Dates.AbstractDateToken[]
    prev = ()
    prev_offset = 1

    letters = String(collect(keys(Dates.CONVERSION_SPECIFIERS)))
    for m in eachmatch(Regex("(?<!\\\\)([\\Q$letters\\E])\\1*"), f)
        tran = replace(f[prev_offset:prevind(f, m.offset)], r"\\(.)" => s"\1")

        if !isempty(prev)
            letter, width = prev
            typ = Dates.CONVERSION_SPECIFIERS[letter]

            push!(tokens, Dates.DatePart{letter}(width, isempty(tran)))
        end

        if !isempty(tran)
            push!(tokens, length(tran) == 1 ? Delim(first(tran)) : Delim(tran))
        end

        letter = f[m.offset]
        width = length(m.match)

        prev = (letter, width)
        prev_offset = m.offset + width
    end

    tran = replace(f[prev_offset:lastindex(f)], r"\\(.)" => s"\1")

    if !isempty(prev)
        letter, width = prev
        typ = Dates.CONVERSION_SPECIFIERS[letter]

        push!(tokens, Dates.DatePart{letter}(width, false))
    end

    if !isempty(tran)
        push!(tokens, length(tran) == 1 ? Delim(first(tran)) : Delim(tran))
    end

    return Format(tokens, locale)
end

function Format(f::AbstractString, locale::AbstractString)
    Format(f, Dates.LOCALES[locale])
end

function Format(df::Dates.DateFormat{S, T}) where {S, T}
    N = fieldcount(T)
    dftokens = df.tokens
    tokens = Vector{Dates.AbstractDateToken}(undef, fieldcount(T))
    Base.@nexprs 15 i -> begin
        if i <= N
            @inbounds tok = dftokens[i]
            @inbounds tokens[i] = tok isa Dates.Delim ? Delim(tok.d) : dftokens[i]
        end
    end
    if N > 15
        for i = 16:N
            @inbounds tok = dftokens[i]
            @inbounds tokens[i] = tok isa Dates.Delim ? Delim(tok.d) : dftokens[i]
        end
    end
    return Format(tokens, df.locale)
end

function Base.show(io::IO, df::Format)
    print(io, "Parsers.dateformat\"")
    for t in df.tokens
        _show_content(io, t)
    end
    print(io, '"')
end
Base.Broadcast.broadcastable(x::Format) = Ref(x)

function _show_content(io::IO, d::Dates.DatePart{c}) where c
    for i = 1:d.width
        print(io, c)
    end
end

function _show_content(io::IO, d::Delim{<:AbstractChar})
    if d.d in keys(Dates.CONVERSION_SPECIFIERS)
        for i = 1:1
            print(io, '\\', d.d)
        end
    else
        for i = 1:1
            print(io, d.d)
        end
    end
end

function _show_content(io::IO, d::Delim)
    for c in d.d
        if c in keys(Dates.CONVERSION_SPECIFIERS)
            print(io, '\\')
        end
        print(io, c)
    end
end

function Base.show(io::IO, d::Delim)
    print(io, "Delim(")
    _show_content(io, d)
    print(io, ")")
end

macro dateformat_str(str)
    Format(str)
end

# Standard formats
const ISODateTimeFormat = Format("yyyy-mm-dd\\THH:MM:SS.s")
const ISODateFormat = Format("yyyy-mm-dd")
const ISOTimeFormat = Format("HH:MM:SS.s")
const RFC1123Format = Format("e, dd u yyyy HH:MM:SS")

default_format(::Type{DateTime}) = ISODateTimeFormat
default_format(::Type{Date}) = ISODateFormat
default_format(::Type{Time}) = ISOTimeFormat

maxdigits(d::Dates.DatePart) = d.fixed ? d.width : typemax(Int64)

for c in "yYmdHIMS"
    @eval begin
        function tryparsenext(d::Dates.DatePart{$c}, source, pos, len, b, code)
            return tryparsenext_base10(source, pos, len, b, code, maxdigits(d))
        end
    end
end

function tryparsenext_base10(source, pos, len, b, code, maxdigits)
    x::Int64 = 0
    b -= UInt8('0')
    if b > 0x09
        # character isn't a digit, INVALID value
        code |= INVALID
        b += UInt8('0')
        @goto done
    end
    ndigits = 0
    @inbounds while true
        x = Int64(10) * x + Int64(b)
        ndigits += 1
        pos += 1
        incr!(source)
        if eof(source, pos, len)
            code |= EOF
            @goto done
        end
        b = peekbyte(source, pos) - UInt8('0')
        if b > 0x09 || ndigits == maxdigits
            b += UInt8('0')
            @goto done
        end
    end
    @label done
    return x, pos, b, code
end

ascii_lc(c::UInt8) = c in UInt8('A'):UInt8('Z') ? c + 0x20 : c

function tryparsenext(d::Dates.DatePart{'p'}, source, pos, len, b, code)
    ap = ascii_lc(b)
    pos += 1
    incr!(source)
    if !(ap == UInt8('a') || ap == UInt8('p')) || eof(source, pos, len)
        code |= INVALID_TOKEN
    else
        b = peekbyte(source, pos)
        if ascii_lc(b) != UInt8('m')
            code |= INVALID_TOKEN
        end
        pos += 1
        incr!(source)
        if eof(source, pos, len)
            code |= EOF
        else
            b = peekbyte(source, pos)
        end
    end
    return ap == UInt8('a') ? Dates.AM : Dates.PM, pos, b, code
end

function nextchar(source, pos, len, b)
    u = UInt32(b) << 24
    if !Base.between(b, 0x80, 0xf7)
        pos += 1
        incr!(source)
        return reinterpret(Char, u), pos
    end
    return nextchar_continued(source, pos, len, u)
end

function nextchar_continued(source, pos, len, u)
    u < 0xc0000000 && (pos += 1; incr!(source); @goto ret)
    # first continuation byte
    pos += 1
    incr!(source)
    eof(source, pos, len) && @goto ret
    b = peekbyte(source, pos)
    b & 0xc0 == 0x80 || @goto ret
    u |= UInt32(b) << 16
    # second continuation byte
    pos += 1
    incr!(source)
    (eof(source, pos, len)) | (u < 0xe0000000) && @goto ret
    b = peekbyte(source, pos)
    b & 0xc0 == 0x80 || @goto ret
    u |= UInt32(b) << 8
    # third continuation byte
    pos += 1
    incr!(source)
    (eof(source, pos, len)) | (u < 0xf0000000) && @goto ret
    b = peekbyte(source, pos)
    b & 0xc0 == 0x80 || @goto ret
    u |= UInt32(b); pos += 1; incr!(source)
@label ret
    return reinterpret(Char, u), pos
end

for (tok, fn) in zip("uUeE", Any[Dates.monthabbr_to_value, Dates.monthname_to_value, Dates.dayabbr_to_value, Dates.dayname_to_value])
    @eval function tryparsenext(d::Dates.DatePart{$tok}, source, pos, len, b, code, locale)
        startpos = pos
        while true
            c, pos = nextchar(source, pos, len, b)
            if !isletter(c) || eof(source, pos, len)
                pos -= 1
                break
            end
            b = peekbyte(source, pos)
        end
        val = 0
        if startpos == pos
            code |= INVALID_TOKEN
        else
            if source isa AbstractVector{UInt8}
                word = unsafe_string(pointer(source, startpos), pos - startpos)
            else # source isa IO
                fastseek!(source, startpos - 1)
                word = String(read(source, pos - startpos))
            end
            val = $fn(word, locale)
            if val == 0
                code |= INVALID_TOKEN
            end
        end
        return Int64(val), pos, b, code
    end
end

function tryparsenext(d::Dates.DatePart{'s'}, source, pos, len, b, code, options)
    ms0, newpos, b, code = tryparsenext_base10(source, pos, len, b, code, maxdigits(d))
    invalid(code) && return ms0, newpos, b, code
    rounding = options.rounding
    len = newpos - pos
    if len > 3
        if rounding === nothing
            ms, r = divrem(ms0, Int64(10) ^ (len - 3))
            if r != 0
                code |= INEXACT
            end
        elseif rounding === RoundNearest
            ms = div(ms0, Int64(10) ^ (len - 3), RoundNearest)
        elseif rounding === RoundToZero
            ms = div(ms0, Int64(10) ^ (len - 3), RoundToZero)
        else
            ms = div(ms0, Int64(10) ^ (len - 3), rounding::RoundingMode)
        end
    else
        ms = ms0 * Int64(10) ^ (3 - len)
    end
    return ms, newpos, b, code
end

function tryparsenext(d::Delim{<:AbstractChar}, source, pos, len, b, code)
    u = bswap(reinterpret(UInt32, d.d))
    while true
        if b != (u & 0x000000ff)
            code |= INVALID_TOKEN
            break
        end
        u >>= 8
        pos += 1
        incr!(source)
        if eof(source, pos, len)
            code |= EOF | (u == UInt32(0) ? SUCCESS : INVALID_TOKEN)
            break
        end
        b = peekbyte(source, pos)
        u == UInt32(0) && break
    end
    return pos, b, code
end

function tryparsenext(d::Delim{String}, source, pos, len, b, code)
    bytes = codeunits(d.d)
    tlen = length(bytes)
    for dpos = 1:tlen
        @inbounds c = bytes[dpos]
        if b != c
            code |= INVALID_TOKEN
            break
        end
        pos += 1
        incr!(source)
        if eof(source, pos, len)
            code |= EOF | (dpos == tlen ? SUCCESS : INVALID_TOKEN)
            break
        end
        b = peekbyte(source, pos)
    end
    return pos, b, code
end

# fallback that would call custom DatePart overloads that are expecting a string
function tryparsenext(tok, source, pos, len, b, code)::Tuple{Any, Int, UInt8, ReturnCode}
    strlen = min(len - pos + 1, 64)
    str = getstring(source, PosLen(pos, strlen), 0x00)
    res = Dates.tryparsenext(tok, str, 1, strlen)
    if res === nothing
        val = nothing
        code |= INVALID_TOKEN
    else
        val, i = res
        pos += i - 1
        if eof(source, pos, len)
            code |= EOF
        else
            b = peekbyte(source, pos)
        end
    end
    return val, pos, b, code
end

function typeparser(::AbstractConf{T}, source::Union{AbstractVector{UInt8}, IO}, pos, len, b, code, pl, options) where {T <: Dates.TimeType}
    fmt = options.dateformat
    df = fmt === nothing ? default_format(T) : fmt
    tokens = df.tokens
    locale::Dates.DateLocale = df.locale
    year = month = day = Int64(1)
    hour = minute = second = millisecond = Int64(0)
    tz = ""
    ampm = Dates.TWENTYFOURHOUR
    extras = nothing
    for tok in tokens
        # @show pos, Char(b), code, typeof(tok)
        eof(code) && break
        if tok isa Delim{Char}
            pos, b, code = tryparsenext(tok, source, pos, len, b, code)
        elseif tok isa Delim{String}
            pos, b, code = tryparsenext(tok, source, pos, len, b, code)
        elseif T !== Time && tok isa Dates.DatePart{'y'}
            year, pos, b, code = tryparsenext(tok, source, pos, len, b, code)
        elseif T !== Time && tok isa Dates.DatePart{'Y'}
            year, pos, b, code = tryparsenext(tok, source, pos, len, b, code)
        elseif T !== Time && tok isa Dates.DatePart{'m'}
            month, pos, b, code = tryparsenext(tok, source, pos, len, b, code)
        elseif T !== Time && tok isa Dates.DatePart{'u'}
            month, pos, b, code = tryparsenext(tok, source, pos, len, b, code, locale)
        elseif T !== Time && tok isa Dates.DatePart{'U'}
            month, pos, b, code = tryparsenext(tok, source, pos, len, b, code, locale)
        elseif T !== Time && tok isa Dates.DatePart{'d'}
            day, pos, b, code = tryparsenext(tok, source, pos, len, b, code)
        elseif T !== Time && tok isa Dates.DatePart{'e'}
            _, pos, b, code = tryparsenext(tok, source, pos, len, b, code, locale)
        elseif T !== Time && tok isa Dates.DatePart{'E'}
            _, pos, b, code = tryparsenext(tok, source, pos, len, b, code, locale)
        elseif T !== Date && tok isa Dates.DatePart{'H'}
            hour, pos, b, code = tryparsenext(tok, source, pos, len, b, code)
        elseif T !== Date && tok isa Dates.DatePart{'I'}
            hour, pos, b, code = tryparsenext(tok, source, pos, len, b, code)
        elseif T !== Date && tok isa Dates.DatePart{'M'}
            minute, pos, b, code = tryparsenext(tok, source, pos, len, b, code)
        elseif T !== Date && tok isa Dates.DatePart{'S'}
            second, pos, b, code = tryparsenext(tok, source, pos, len, b, code)
        elseif T !== Date && tok isa Dates.DatePart{'p'}
            ampm, pos, b, code = tryparsenext(tok, source, pos, len, b, code)
        elseif T !== Date && tok isa Dates.DatePart{'s'}
            millisecond, pos, b, code = tryparsenext(tok, source, pos, len, b, code, options)
        elseif tok isa Dates.DatePart{'z'}
            tz, pos, b, code = tryparsenext(tok, source, pos, len, b, code)
        elseif tok isa Dates.DatePart{'Z'}
            tz, pos, b, code = tryparsenext(tok, source, pos, len, b, code)
        else
            # non-Dates defined character code
            # allocate extras if not already and parse
            if extras === nothing
                extras = IdDict{Type, Any}()
            end
            extraval, pos, b, code = tryparsenext(tok, source, pos, len, b, code)::Tuple{Any, Int, UInt8, ReturnCode}
            extras[Dates.CONVERSION_SPECIFIERS[charactercode(tok)]] = extraval
        end
        if invalid(code)
            if invalidtoken(code)
                code &= ~INVALID_TOKEN
            end
            break
        end
        # @show pos, Char(b), code
    end

    if T === Time
        @static if VERSION >= v"1.3-DEV"
            valid = Dates.validargs(T, hour, minute, second, millisecond, Int64(0), Int64(0), ampm)
        else
            valid = Dates.validargs(T, hour, minute, second, millisecond, Int64(0), Int64(0))
        end
    elseif T === Date
        valid = Dates.validargs(T, year, month, day)
    elseif T === DateTime
        @static if VERSION >= v"1.3-DEV"
            valid = Dates.validargs(T, year, month, day, hour, minute, second, millisecond, ampm)
        else
            valid = Dates.validargs(T, year, month, day, hour, minute, second, millisecond)
        end
    elseif T.name.name === :ZonedDateTime
        valid = Dates.validargs(T, year, month, day, hour, minute, second, millisecond, tz)
    else
        # custom TimeType
        if extras === nothing
            extras = IdDict{Type, Any}()
        end
        extras[Year] = year; extras[Month] = month; extras[Day] = day;
        extras[Hour] = hour; extras[Minute] = minute; extras[Second] = second; extras[Millisecond] = millisecond;
        types = Dates.CONVERSION_TRANSLATIONS[T]
        vals = Vector{Any}(undef, length(types))
        for (i, type) in enumerate(types)
            vals[i] = get(extras, type) do
                Dates.CONVERSION_DEFAULTS[type]
            end
        end
        valid = Dates.validargs(T, vals...)
    end
    if invalid(code) || valid !== nothing
        if T.name.name === :ZonedDateTime
            x = T(0, TimeZone("UTC"))
        else
            x = T(0)
        end
        code |= INVALID
    else
        if T === Time
            @static if VERSION >= v"1.3-DEV"
                x = Time(Nanosecond(1000000 * millisecond + 1000000000 * second + 60000000000 * minute + 3600000000000 * (Dates.adjusthour(hour, ampm))))
            else
                x = Time(Nanosecond(1000000 * millisecond + 1000000000 * second + 60000000000 * minute + 3600000000000 * hour))
            end
        elseif T === Date
            x = Date(Dates.UTD(Dates.totaldays(year, month, day)))
        elseif T === DateTime
            @static if VERSION >= v"1.3-DEV"
                x = DateTime(Dates.UTM(millisecond + 1000 * (second + 60 * minute + 3600 * (Dates.adjusthour(hour, ampm)) + 86400 * Dates.totaldays(year, month, day))))
            else
                x = DateTime(Dates.UTM(millisecond + 1000 * (second + 60 * minute + 3600 * hour + 86400 * Dates.totaldays(year, month, day))))
            end
        elseif T.name.name === :ZonedDateTime
            x = T(year, month, day, hour, minute, second, millisecond, tz)
        else
            # custom TimeType
            x = T(vals...)
        end
        code |= OK
    end
    if eof(source, pos, len)
        code |= EOF
    end
    return pos, code, PosLen(pl.pos, pos - pl.pos), x
end
