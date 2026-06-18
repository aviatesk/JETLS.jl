isgreedy(::Type{T}) where {T <: AbstractString} = true
isgreedy(::Type{Symbol}) = true
isgreedy(T) = false

@inline function typeparser(::AbstractConf{T}, source, pos, len, b, code, pl, opts) where {T <: AbstractString}
    if quoted(code)
        code |= OK
        return findendquoted(T, source, pos, len, b, code, pl, true, opts.cq, opts.e, opts.flags.stripquoted)
    elseif opts.flags.checkdelim
        code |= OK
        return finddelimiter(T, source, pos, len, b, code, pl, opts.delim, opts.flags.ignorerepeated, opts.cmt, opts.flags.ignoreemptylines, opts.flags.stripwhitespace)
    else
        code |= OK
        return findeof(source, pos, len, b, code, pl, opts)
    end
end

function findeof(source, pos, len, b, code, pl, opts)
    # no delimiter, so read until EOF
    # if stripwhitespace, then we need to keep track of the last non-whitespace character
    # in order to strip trailing whitespace
    lastnonwhitepos = pos
    while !eof(source, pos, len)
        b = peekbyte(source, pos)
        wh = iswh(b)
        lastnonwhitepos = opts.flags.stripwhitespace ? (wh ? lastnonwhitepos : pos) : pos
        pos += 1
        incr!(source)
    end
    code |= EOF
    pl = poslen(typeof(pl), pl.pos, (lastnonwhitepos - pl.pos) + 1)
    return pos, code, pl, pl
end

function typeparser(::AbstractConf{Char}, source, pos, len, b, code, pl, opts)
    startpos = pos
    l = 8 * (4 - leading_ones(b))
    c = UInt32(b) << 24
    if eof(source, pos, len)
        code |= INVALID | EOF
        @goto done
    end
    s = 16
    while true
        pos += 1
        incr!(source)
        if eof(source, pos, len)
            code |= EOF
            @goto done
        end
        b = peekbyte(source, pos)
        if l >= 24 || s < l || (b & 0xc0) != 0x80
            @goto done
        end
        c |= UInt32(b) << s
        s -= 8
    end

@label done
    # Char is *almost* not greedy; it's not greedy in that we know how much
    # to parse, independent of parsing stream contents, but we still need
    # to account for the possibility of the Options.delim being a Char
    # and treating that as a delim instead of a successfully parsed Char
    # hence the checkdelim + _contains check before setting OK
    ch = reinterpret(Char, c)
    if Base.isoverlong(ch) || Base.ismalformed(ch)
        code |= INVALID
    elseif opts.flags.checkdelim && _contains(opts.delim, ch)
        code |= INVALID
        code &= ~EOF
        pos = startpos
        fastseek!(source, startpos)
    else
        code |= OK
    end
    return pos, code, PosLen(pl.pos, pos - pl.pos), ch
end

function typeparser(::AbstractConf{Symbol}, source, pos, len, b, code, pl, opts)
    if quoted(code)
        code |= OK
        pos, code, pl, _ = findendquoted(Symbol, source, pos, len, b, code, pl, true, opts.cq, opts.e, opts.stripquoted)
    elseif opts.flags.checkdelim
        code |= OK
        pos, code, pl, _ = finddelimiter(Symbol, source, pos, len, b, code, pl, opts.delim, opts.flags.ignorerepeated, opts.cmt, opts.ignoreemptylines, opts.flags.stripwhitespace)
    else
        code |= OK
        pos, code, pl, _ = findeof(source, pos, len, b, code, pl, opts)
    end
    if source isa AbstractVector{UInt8}
        sym = ccall(:jl_symbol_n, Ref{Symbol}, (Ptr{UInt8}, Int), pointer(source, pl.pos), pl.len)
    else
        sym = Symbol(getstring(source, pl, opts.e))
    end
    return pos, code, pl, sym
end
