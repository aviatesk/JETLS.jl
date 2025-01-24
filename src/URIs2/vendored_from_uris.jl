# RFC3986 Unreserved Characters (and '~' Unsafe per RFC1738).
@inline issafe(c::Char) = c == '-' ||
                          c == '.' ||
                          c == '_' ||
                          (isascii(c) && (isletter(c) || isnumeric(c)))

"""
    _bytes(s::String)
Get a `Vector{UInt8}`, a vector of bytes of a string.
"""
function _bytes end
_bytes(s::SubArray{UInt8}) = unsafe_wrap(Array, pointer(s), length(s))

_bytes(s::Union{Vector{UInt8}, Base.CodeUnits}) = _bytes(String(s))
_bytes(s::AbstractString) = codeunits(s)

_bytes(s::Vector{UInt8}) = s


utf8_chars(str::AbstractString) = (Char(c) for c in _bytes(str))

ispathsafe(c::Char) = c == '/' || issafe(c)

"""
    escapeuri(x)
Apply URI percent-encoding to escape special characters in `x`.
"""
function escapeuri end

escapeuri(c::Char) = string('%', uppercase(string(Int(c), base=16, pad=2)))
escapeuri(str::AbstractString, safe::Function=issafe) =
    join(safe(c) ? c : escapeuri(c) for c in utf8_chars(str))

escapeuri(bytes::Vector{UInt8}) = bytes
escapeuri(v::Number) = escapeuri(string(v))
escapeuri(v::Symbol) = escapeuri(string(v))

"""
    escapeuri(key, value)
    escapeuri(query_vals)
Percent-encode and concatenate a value pair(s) as they would conventionally be
encoded within the query part of a URI.
"""
escapeuri(key, value) = string(escapeuri(key), "=", escapeuri(value))
escapeuri(key, values::Vector) = escapeuri(key => v for v in values)
escapeuri(query) = isempty(query) ? absent : join((escapeuri(k, v) for (k,v) in query), "&")
escapeuri(nt::NamedTuple) = escapeuri(pairs(nt))

"""
    escapepath(path)
Escape the path portion of a URI, given the string `path` containing embedded
`/` characters which separate the path segments.
"""
escapepath(path) = escapeuri(path, ispathsafe)

"""
    unescapeuri(str)
Percent-decode a string according to the URI escaping rules.
"""
function unescapeuri(str)
    occursin("%", str) || return str
    out = IOBuffer()
    i = 1
    io = IOBuffer(str)
    while !eof(io)
        c = read(io, Char)
        if c == '%'
            c1 = read(io, Char)
            c = read(io, Char)
            write(out, parse(UInt8, string(c1, c); base=16))
        else
            write(out, c)
        end
    end
    return String(take!(out))
end
