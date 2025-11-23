@inline function parseint(io::IO, len::Int)
    if len == 1
        return Int(Parsers.readbyte(io) - Parsers.ZERO)
    end
    v = zero(Int)
    b = Parsers.readbyte(io)
    negative = false
    if b === Parsers.MINUS # check for leading '-' or '+'
        negative = true
    elseif b !== Parsers.PLUS
        v = Int(b - Parsers.ZERO)
    end
    for _ = 1:(len - 1)
        v *= Int(10)
        v += Int(Parsers.readbyte(io) - Parsers.ZERO)
    end
    return ifelse(negative, -v, v)
end

function checkint2(str::String)
    len = sizeof(str)
    BUF.data = str
    BUF.ptr = 1
    BUF.size = len
    return checkint(BUF)
end

@inline function checkint(io::IO)
    eof(io) && return false
    b = Parsers.peekbyte(io)
    negative = false
    if b === Parsers.MINUS # check for leading '-' or '+'
        negative = true
        Parsers.readbyte(io)
        eof(io) && return false
        b = Parsers.peekbyte(io)
    elseif b === Parsers.PLUS
        Parsers.readbyte(io)
        eof(io) && return false
        b = Parsers.peekbyte(io)
    end
    parseddigits = false
    while Parsers.NEG_ONE < b < Parsers.TEN
        parseddigits = true
        b = Parsers.readbyte(io)
        eof(io) && break
        b = Parsers.peekbyte(io)
    end
    return parseddigits
end
