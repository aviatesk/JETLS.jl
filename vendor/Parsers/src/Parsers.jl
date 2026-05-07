module Parsers

export PosLen

using Dates
using UUIDs

include("utils.jl")

struct Format
    tokens::Vector{Dates.AbstractDateToken}
    locale::Dates.DateLocale
end

const SupportedFloats = Union{Float16, Float32, Float64, BigFloat}
const SupportedTypes = Union{Integer, SupportedFloats, Dates.TimeType, Bool, AbstractString, Symbol, Char}

supportedtype(::Type{T}) where {T} = T <: SupportedTypes

"""
    Parsers.Result{T}(code::Parsers.ReturnCode, tlen[, val])

Struct for holding the results of a parsing operations, returned from `Parsers.xparse`.
Contains 3 fields:
  * `code`: parsing bitmask with various flags set based on parsing (see [ReturnCode](@ref))
  * `tlen`: the total number of bytes consumed while parsing
  * `val`: the parsed value; note that `val` is optional when constructing; users *MUST* check `!Parsers.invalid(result.code)` before accessing `result.val`; if parsing fails, `result.val` is undefined
"""
struct Result{T}
    code::ReturnCode
    tlen::Int64
    val::T
    Result{T}(code::ReturnCode, tlen::Integer) where {T} = new{T}(code, tlen)
    Result{T}(code::ReturnCode, tlen::Integer, val) where {T} = new{T}(code, tlen, val)
end

Base.show(io::IO, x::Result{T}) where {T} = print(io, "Parsers.Result{$T}(code=`", codes(x.code), "`, tlen=", x.tlen, ", val=", isdefined(x, :val) ? x.val : "#undefined", ")")

# bit flags to hold several Bool options for Options
primitive type Flags 16 end

const SPACEDELIM      = 0b0000000000000001
const TABDELIM        = 0b0000000000000010
const STRIPQUOTED     = 0b0000000000000100
const STRIPWHITESPACE = 0b0000000000001000
const CHECKQUOTED     = 0b0000000000010000
const CHECKSENTINEL   = 0b0000000000100000
const CHECKDELIM      = 0b0000000001000000
const IGNOREREPEATED  = 0b0000000010000000
const IGNOREEMPTY     = 0b0000000100000000

function Flags(spacedelim, tabdelim, stripquoted, stripwhitespace, checkquoted, checksentinel, checkdelim, ignorerepeated, ignoreemptylines)
    x = 0x0000
    spacedelim && (x |= SPACEDELIM)
    tabdelim && (x |= TABDELIM)
    stripquoted && (x |= STRIPQUOTED)
    # stripquoted implies stripwhitespace
    (stripwhitespace || stripquoted) && (x |= STRIPWHITESPACE)
    checkquoted && (x |= CHECKQUOTED)
    checksentinel && (x |= CHECKSENTINEL)
    checkdelim && (x |= CHECKDELIM)
    ignorerepeated && (x |= IGNOREREPEATED)
    ignoreemptylines && (x |= IGNOREEMPTY)
    return Base.bitcast(Flags, x)
end

Base.show(io::IO, x::Flags) = print(io, "Parsers.Flags(spacedelim=", x.spacedelim, ", tabdelim=", x.tabdelim, ", stripquoted=", x.stripquoted, ", stripwhitespace=", x.stripwhitespace, ", checkquoted=", x.checkquoted, ", checksentinel=", x.checksentinel, ", checkdelim=", x.checkdelim, ", ignorerepeated=", x.ignorerepeated, ", ignoreemptylines=", x.ignoreemptylines, ")")

Base.write(io::IO, flag::Flags) = write(io, reinterpret(UInt16, flag))
Base.read(io::IO, ::Type{Flags}) = Base.bitcast(Flags, read(io, UInt16))

function Base.getproperty(x::Flags, nm::Symbol)
    if nm == :spacedelim
        return Base.bitcast(UInt16, x) & SPACEDELIM != 0x00
    elseif nm == :tabdelim
        return Base.bitcast(UInt16, x) & TABDELIM != 0x00
    elseif nm == :stripquoted
        return Base.bitcast(UInt16, x) & STRIPQUOTED != 0x00
    elseif nm == :stripwhitespace
        return Base.bitcast(UInt16, x) & STRIPWHITESPACE != 0x00
    elseif nm == :checkquoted
        return Base.bitcast(UInt16, x) & CHECKQUOTED != 0x00
    elseif nm == :checksentinel
        return Base.bitcast(UInt16, x) & CHECKSENTINEL != 0x00
    elseif nm == :checkdelim
        return Base.bitcast(UInt16, x) & CHECKDELIM != 0x00
    elseif nm == :ignorerepeated
        return Base.bitcast(UInt16, x) & IGNOREREPEATED != 0x00
    elseif nm == :ignoreemptylines
        return Base.bitcast(UInt16, x) & IGNOREEMPTY != 0x00
    else
        throw(ArgumentError("unknown Flags property: `$nm`"))
    end
end

"""
    `Parsers.Options` is a structure for holding various parsing settings when calling `Parsers.parse`, `Parsers.tryparse`, and `Parsers.xparse`. They include:

  * `sentinel=nothing`: valid values include: `nothing` meaning don't check for sentinel values; `missing` meaning an "empty field" should be considered a sentinel value; or a `Vector{String}` of the various string values that should each be checked as a sentinel value. Note that sentinels will always be checked longest to shortest, with the longest valid match taking precedence.
  * `openquotechar='"'`: the ascii character that signals a "quoted" field while parsing; subsequent characters will be treated as non-significant until a valid `closequotechar` is detected
  * `closequotechar='"'`: the ascii character that signals the end of a quoted field
  * `escapechar='"'`: an ascii character used to "escape" a `closequotechar` within a quoted field
  * `delim=','`: if `nothing`, no delimiter will be checked for; if a `Char` or `String`, a delimiter will be checked for directly after parsing a value or `closequotechar`; a newline (`\\n`), return (`\\r`), or CRLF (`"\\r\\n"`) are always considered "delimiters", in addition to EOF
  * `decimal='.'`: an ascii character to be used when parsing float values that separates a decimal value
  * `trues=nothing`: if `nothing`, `Bool` parsing will only check for the string `true` or an `Integer` value of `1` as valid values for `true`; as a `Vector{String}`, each string value will be checked to indicate a valid `true` value
  * `falses=nothing`: if `nothing`, `Bool` parsing will only check for the string `false` or an `Integer` value of `0` as valid values for `false`; as a `Vector{String}`, each string value will be checked to indicate a valid `false` value
  * `dateformat=nothing`: if `nothing`, `Date`, `DateTime`, and `Time` parsing will use a default `Dates.DateFormat` object while parsing; a `String` or `Dates.DateFormat` object can be provided for custom format parsing
  * `ignorerepeated=false`: if `true`, consecutive delimiter characters or strings will be consumed until a non-delimiter is encountered; if `false`, only a single delimiter character/string will be consumed. Useful for fixed-width delimited files where fields are padded with delimiters
  * `quoted=true`: whether parsing should check for `openquotechar` and `closequotechar` characters to signal quoted fields
  * `comment=nothing`: a string which, if matched at the start of a line, will make parsing consume the rest of the line
  * `ignoreemptylines=false`: after parsing a value, if a newline is detected, another immediately proceeding newline will be checked for and consumed
  * `stripwhitespace=nothing`: if true, leading and trailing whitespace is stripped from string fields, note that for *quoted* strings however, whitespace is preserved within quotes (but ignored before/after quote characters). To also strip *within* quotes, see `stripquoted`
  * `stripquoted=false`: if true, whitespace is also stripped within quoted strings. If true, `stripwhitespace` is also set to true.
  * `groupmark=nothing`: optionally specify a single-byte character denoting the number grouping mark, this allows parsing of numbers that have, e.g., thousand separators (`1,000.00`). When the `groupmark` is ambiguous with the `delim`, the user must quote the number if it contains group marks.
  * `rounding=RoundNearest`: optionally specify a rounding mode to use when parsing. No rounding means the result will be marked with `INEXACT` code if the value is not exactly representable in the target type.
"""
struct Options
    flags::Flags
    decimal::UInt8
    oq::Token
    cq::Token
    e::UInt8
    sentinel::Vector{Token}
    delim::Token
    cmt::Token
    trues::Union{Nothing, Vector{String}}
    falses::Union{Nothing, Vector{String}}
    dateformat::Union{Nothing, Format}
    groupmark::Union{Nothing,UInt8}
    rounding::Union{Nothing,RoundingMode}
end

# backwards compat
function Base.getproperty(x::Options, nm::Symbol)
    if nm == :ignorerepeated
        return x.flags.ignorerepeated
    elseif nm == :ignoreemptylines
        return x.flags.ignoreemptylines
    else
        return getfield(x, nm)
    end
end

# Get the default options for single-value parsing (i.e. not delimited), used
# by Parsers.parse and Parsers.tryparse via Parser.xparse2
function _get_default_options(;
    flags::Flags=Flags(false, false, false, false, false, false, false, false, false),
    decimal::UInt8=UInt8('.'),
    oq::Token=Token(UInt8('"')),
    cq::Token=Token(UInt8('"')),
    e::UInt8=UInt8('"'),
    sentinel::Vector{Token}=Token[],
    delim::Token=Token(""),
    cmt::Token=Token(""),
    trues::Union{Nothing, Vector{String}}=nothing,
    falses::Union{Nothing, Vector{String}}=nothing,
    dateformat::Union{Nothing, Format}=nothing,
    groupmark::Union{Nothing,UInt8}=nothing,
    rounding::Union{Nothing,RoundingMode}=nothing,
)
    return Options(flags, decimal, oq, cq, e, sentinel, delim, cmt, trues, falses, dateformat, groupmark, rounding)
end

# Get the default options for delimited parsing, used by Parsers.xparse
function _get_default_xoptions(;
    flags::Flags=Flags(false, false, false, false, true, true, true, false, false),
    decimal::UInt8=UInt8('.'),
    oq::Token=Token(UInt8('"')),
    cq::Token=Token(UInt8('"')),
    e::UInt8=UInt8('"'),
    sentinel::Vector{Token}=Token[],
    delim::Token=Token(UInt8(',')),
    cmt::Token=Token(""),
    trues::Union{Nothing, Vector{String}}=nothing,
    falses::Union{Nothing, Vector{String}}=nothing,
    dateformat::Union{Nothing, Format}=nothing,
    groupmark::Union{Nothing,UInt8}=nothing,
    rounding::Union{Nothing,RoundingMode}=nothing,
)
    return Options(flags, decimal, oq, cq, e, sentinel, delim, cmt, trues, falses, dateformat, groupmark, rounding)
end

# What is used by default in Parsers.parse, Parsers.tryparse, Parsers.xparse2
const OPTIONS = _get_default_options()
# What is used by default in Parsers.xparse
const XOPTIONS = _get_default_xoptions()

prepare!(x::Vector) = sort!(x, by=x->sizeof(x), rev=true)
asciival(c::Char) = isascii(c)
asciival(b::UInt8) = b < 0x80

_match(a::T, b::T) where {T<:Union{String,UInt8,Char}} = a == b
_match(a::T, b::S) where {T<:Union{String,UInt8,Char,Regex}, S<:Union{String,UInt8,Char}} = _match(b, a)
_match(a::String, b::Regex) = (m = match(b, a); isnothing(m) ? false : m.match == a)
_match(a::Char, b::Regex) = _match(string(a), b)
_match(a::UInt8, b::Regex) = _match(Char(a), b)
_match(a::UInt8, b::String) = ncodeunits(b) == 1 && Char(a) == first(b)
_match(a::Char, b::String) = ncodeunits(a) == ncodeunits(b) && a == first(b)
_match(a::UInt8, b::Char) = ncodeunits(b) == 1 && a == UInt8(b)
_match(a::Nothing, b) = false
_match(a, b::Nothing) = false
_match(a::Nothing, b::Nothing) = false
# TODO: this is not correct e.g. r"aa{1,1}a" is the same as r"aaa"
# but we won't catch that.
_match(a::Regex, b::Regex) = a == b

_startswith(s::UInt8, prefix::Union{String,Char}) = ncodeunits(prefix) == 1 && Char(s) == first(prefix)
_startswith(s::Char, prefix::Union{String,Char}) = ncodeunits(s) >= ncodeunits(prefix) && s == first(prefix)
_startswith(s::String, prefix::Union{Char,String,Regex}) = startswith(s, prefix)
_startswith(s::String, prefix::UInt8) = startswith(s, Char(prefix))
_startswith(s::Char, prefix::Regex) = startswith(string(s), prefix)
_startswith(s::UInt8, prefix::Regex) = startswith(string(Char(s)), prefix)
_startswith(s::UInt8, prefix::UInt8) = s == prefix
_startswith(s::Char, prefix::UInt8) = codepoint(s) == UInt32(prefix)
_startswith(a::Nothing, b) = false
_startswith(a, b::Nothing) = false
_startswith(a::Nothing, b::Nothing) = false

_nbytes(::UInt8) = 1
_nbytes(x::Char) = ncodeunits(x)

const MaybeToken = Union{Nothing, UInt8, Char, String, Regex}

function Options(
            sentinel::Union{Nothing, Missing, Vector},
            wh1::Union{UInt8, Char},
            wh2::Union{UInt8, Char},
            openquotechar::MaybeToken,
            closequotechar::MaybeToken,
            escapechar::MaybeToken,
            delim::MaybeToken,
            decimal::Union{UInt8, Char},
            trues::Union{Nothing, Vector{String}},
            falses::Union{Nothing, Vector{String}},
            dateformat::Union{Nothing, String, Dates.DateFormat, Format},
            ignorerepeated::Bool,
            ignoreemptylines::Bool,
            comment::MaybeToken,
            quoted::Bool,
            debug::Bool=false,
            stripwhitespace::Bool=false,
            stripquoted::Bool=false,
            groupmark::Union{Nothing,Char,UInt8}=nothing,
            rounding::Union{Nothing,RoundingMode}=nothing,
)
    # backwards compat; users previously had to pass wh1/wh2 as non-wh to avoid stripping
    if wh1 != UInt8(' ') || wh2 != UInt8('\t')
        stripwhitespace = false
    end
    if sentinel isa Vector{String}
        for sent in sentinel
            if stripwhitespace && (_contains(sent, " ") || _contains(sent, "\t"))
                throw(ArgumentError("`sentinel` value isn't allowed to contain ' ' or '\t' characters if `stripwhitespace=true`"))
            end
            if quoted && (_contains(sent, openquotechar) || _contains(sent, closequotechar) || _contains(sent, escapechar))
                throw(ArgumentError("`sentinel` value isn't allowed to contain `openquotechar`, `closequotechar`, or `escapechar` characters"))
            end
            if _contains(sent, delim)
                throw(ArgumentError("`sentinel` value isn't allowed to contain a delimiter character"))
            end
        end
    end

    oq = token(openquotechar, "openquotechar")
    cq = token(closequotechar, "closequotechar")
    e = token(escapechar, "escapechar")
    e.token isa UInt8 || throw(ArgumentError("`escapechar` must be a single ascii character"))
    e = e.token
    quoted && (isempty(oq) || isempty(cq) || isempty(e)) && throw(ArgumentError("quoted=true requires `openquotechar`, `closequotechar`, and `escapechar` to be specified"))
    sent = (sentinel === nothing || sentinel === missing) ? Token[] : map(x -> token(x, "sentinel"), prepare!(sentinel))
    checksentinel = sentinel !== nothing
    quoted && ((_match(openquotechar, delim) || _match(closequotechar, delim)) || _match(escapechar, delim)) &&
        throw(ArgumentError("`delim` argument must be different than `openquotechar`, `closequotechar`, and `escapechar` arguments"))
    del = delim
    delim = token(delim, "delim")
    checkdelim = delim !== nothing && !isempty(delim)
    spacedelim = checkdelim && _contains(delim, " ")
    tabdelim = checkdelim && _contains(delim, "\t")
    if trues !== nothing
        trues = prepare!(trues)
    end
    if falses !== nothing
        falses = prepare!(falses)
    end
    if groupmark !== nothing && (
        _match(groupmark, decimal) ||
        isnumeric(Char(groupmark)) ||
        (_match(del, groupmark) && !quoted) ||
        _match(openquotechar, groupmark) ||
        _match(closequotechar, groupmark) ||
        _nbytes(groupmark) != 1
    )
        throw(ArgumentError("`groupmark` cannot be a number, a quoting char, coincide with `decimal` and `delim` unless `quoted=true`."))
    end
    _nbytes(decimal) == 1 || throw(ArgumentError("`decimal` must be a single ascii character"))
    !isnumeric(Char(decimal)) || throw(ArgumentError("`decimal` cannot be a number"))

    df = dateformat === nothing ? nothing : dateformat isa String ? Format(dateformat) : dateformat isa Dates.DateFormat ? Format(dateformat) : dateformat
    flags = Flags(spacedelim, tabdelim, stripquoted, stripwhitespace, quoted, checksentinel, checkdelim, ignorerepeated, ignoreemptylines)
    return Options(flags, decimal, oq, cq, e, sent, delim, token(comment, "comment"), trues, falses, df, groupmark === nothing ? nothing : groupmark % UInt8, rounding)
end

function token(x::MaybeToken, arg)
    x === nothing && return Token("")
    if x isa UInt8
        asciival(x) || throw(ArgumentError("$arg argument must be ASCII"))
        return Token(x)
    elseif x isa Char
        return Token(asciival(x) ? UInt8(x) : string(x))
    elseif x isa Regex
        return Token(mkregex(x))
    else
        return Token(x)
    end
end

Options(;
    sentinel::Union{Nothing, Missing, Vector}=nothing,
    wh1::Union{UInt8, Char}=UInt8(' '),
    wh2::Union{UInt8, Char}=UInt8('\t'),
    openquotechar::MaybeToken=UInt8('"'),
    closequotechar::MaybeToken=UInt8('"'),
    escapechar::MaybeToken=UInt8('"'),
    delim::MaybeToken=UInt8(','),
    decimal::Union{UInt8, Char}=UInt8('.'),
    trues::Union{Nothing, Vector{String}}=nothing,
    falses::Union{Nothing, Vector{String}}=nothing,
    dateformat::Union{Nothing, String, Dates.DateFormat, Format}=nothing,
    ignorerepeated::Bool=false,
    ignoreemptylines::Bool=false,
    comment::MaybeToken=nothing,
    quoted::Bool=true,
    debug::Bool=false,
    stripwhitespace::Bool=false,
    stripquoted::Bool=false,
    groupmark::Union{Nothing,Char,UInt8}=nothing,
    rounding::Union{Nothing,RoundingMode}=nothing,
) = Options(sentinel, wh1, wh2, openquotechar, closequotechar, escapechar, delim, decimal, trues, falses, dateformat, ignorerepeated, ignoreemptylines, comment, quoted, debug, stripwhitespace, stripquoted, groupmark, rounding)

# "beta" for now, but allows custom types to define their own "Options"-like struct
# that can handle additional type-specific options
abstract type AbstractConf{T} end

struct DefaultConf{T} <: AbstractConf{T} end

conf(::Type{T}, opts::Options; kw...) where {T} = DefaultConf{T}()

result(::Type{T}, res::Result) where {T} = res

include("components.jl")

# high-level convenience functions like in Base
"""
    Parsers.parse(T, source[, options, pos, len]) => T

Parse a value of type `T` from `source`, which may be a byte buffer (`AbstractVector{UInt8}`), string, or `IO`. Optional arguments include `options`, a [`Parsers.Options`](@ref)
struct, `pos` which indicates the byte position where parsing should begin in a byte buffer `source`, and `len` which is the byte position where parsing should stop in a byte
buffer `source`. If parsing fails for any reason, either invalid value or non-value characters encountered before/after a value, an error will be thrown. To return `nothing`
instead of throwing an error, use [`Parsers.tryparse`](@ref).
"""
function parse(::Type{T}, buf::Union{AbstractVector{UInt8}, AbstractString, IO}, options=OPTIONS, pos::Integer=1, len::Integer=buf isa IO ? 0 : sizeof(buf)) where {T}
    res = xparse2(T, buf isa AbstractString ? codeunits(buf) : buf, pos, len, options)
    code = res.code
    tlen = res.tlen
    fin = buf isa IO || (tlen == (len - pos + 1))
    return ok(code) && fin ? (res.val::T) : throw(Error(buf, T, code, pos, tlen))
end

"""
    Parsers.tryparse(T, source[, options, pos, len]) => Union{T, Nothing}

Parse a value of type `T` from `source`, which may be a byte buffer (`AbstractVector{UInt8}`), string, or `IO`. Optional arguments include `options`, a [`Parsers.Options`](@ref)
struct, `pos` which indicates the byte position where parsing should begin in a byte buffer `source`, and `len` which is the byte position where parsing should stop in a byte
buffer `source`. If parsing fails for any reason, either invalid value or non-value characters encountered before/after a value, `nothing` will be returned. To instead throw
an error, use [`Parsers.parse`](@ref).
"""
function tryparse(::Type{T}, buf::Union{AbstractVector{UInt8}, AbstractString, IO}, options=OPTIONS, pos::Integer=1, len::Integer=buf isa IO ? 0 : sizeof(buf)) where {T}
    res = xparse2(T, buf isa AbstractString ? codeunits(buf) : buf, pos, len, options)
    fin = buf isa IO || (res.tlen == (len - pos + 1))
    return ok(res.code) && fin ? (res.val::T) : nothing
end

"""
    Parsers.xparse(T, buf, pos, len, options) => Parsers.Result{T}

The core parsing function for any type `T`. Takes a `buf`, which can be an `AbstractVector{UInt8}`, `AbstractString`,
or an `IO`. `pos` is the byte position to begin parsing at. `len` is the total # of bytes in `buf` (signaling eof).
`options` is an instance of `Parsers.Options`.

A [`Parsers.Result`](@ref) struct is returned, with the following fields:
* `res.val` is a value of type `T`, but only if parsing succeeded; for parsed `String`s, no string is returned to avoid excess allocating; if you'd like the actual parsed string value, you can call [`Parsers.getstring`](@ref)
* `res.code` is a bitmask of parsing codes, use `Parsers.codes(code)` or `Parsers.text(code)` to see the various bit values set. See [`Parsers.ReturnCode`](@ref) for additional details on the various parsing codes
* `res.tlen`: the total # of bytes consumed while parsing a value, including any quote or delimiter characters; this can be added to the starting `pos` to allow calling `Parsers.xparse` again for a subsequent field/value
"""
function xparse end

const SourceType = Union{AbstractVector{UInt8}, AbstractString, IO}

returntype(::Type{T}) where {T <: AbstractString} = PosLen
returntype(::Type{Number}) = Union{Int64, Int128, BigInt, Float32, Float64, BigFloat}
returntype(::Type{T}) where {T} = T

# for testing purposes only, it's much too slow to dynamically create Options for every xparse call
xparse(::Type{T}, source::SourceType, S=nothing; pos::Integer=1, len::Integer=source isa IO ? 0 : sizeof(source), kw...) where {T} =
    S === nothing ? xparse(T, source, pos, len, Options(; kw...)) : xparse(T, source, pos, len, Options(; kw...), S)

_xparse(conf::AbstractConf{T}, source::Union{AbstractVector{UInt8}, IO}, pos, len, options::Options=XOPTIONS, ::Type{S}=returntype(T)) where {T, S} =
    Result(emptysentinel(options)(delimiter(options)(whitespace(options)(
        quoted(options)(whitespace(options)(sentinel(options)(typeparser(options)
    )))))))(conf, source, pos, len, S)

xparse(::Type{T}, source::SourceType, pos, len, options=XOPTIONS, ::Type{S}=returntype(T)) where {T, S} =
    result(T, xparse(conf(T, options), source, pos, len, options, S))

function xparse(conf::AbstractConf{T}, source::SourceType, pos, len, options=XOPTIONS, ::Type{S}=returntype(T)) where {T, S}
    buf = source isa AbstractString ? codeunits(source) : source
    if T === Number || supportedtype(T)
        return _xparse(conf, buf, pos, len, options, S)
    else
        # generic fallback calls Base.tryparse
        res = _xparse(DefaultConf{String}(), source, pos, len, options)
        code = res.code
        pl = res.val
        if !Parsers.invalid(code) && !Parsers.sentinel(code)
            str = getstring(source, pl, options.e)
            x = Base.tryparse(T, str)
            if x === nothing
                return Result{S}(code | INVALID, res.tlen)
            else
                return Result{S}(code, res.tlen, x)
            end
        else
            return Result{S}(code, res.tlen)
        end
    end
end

# condensed version of xparse that doesn't worry about quoting or delimiters; called from Parsers.parse/Parsers.tryparse
_xparse2(conf::AbstractConf{T}, source::Union{AbstractVector{UInt8}, IO}, pos, len, opts::Options=OPTIONS, ::Type{S}=returntype(T)) where {T, S} =
    Result(whitespace(false, false, false, true)(typeparser(opts)))(conf, source, pos, len, S)

xparse2(::Type{T}, source::SourceType, pos, len, options=OPTIONS, ::Type{S}=returntype(T)) where {T, S} =
    result(T, xparse2(conf(T, options), source, pos, len, options, S))

function xparse2(conf::AbstractConf{T}, source::SourceType, pos, len, options=OPTIONS, ::Type{S}=returntype(T)) where {T, S}
    buf = source isa AbstractString ? codeunits(source) : source
    if T === Number || supportedtype(T)
        return _xparse2(conf, buf, pos, len, options, S)
    else
        # generic fallback calls Base.tryparse
        res = _xparse2(DefaultConf{String}(), source, pos, len, options)
        code = res.code
        pl = res.val
        if !Parsers.invalid(code) && !Parsers.sentinel(code)
            str = getstring(source, pl, options.e)
            x = Base.tryparse(T, str)
            if x === nothing
                return Result{S}(code | INVALID, res.tlen)
            else
                return Result{S}(code, res.tlen, x)
            end
        else
            return Result{S}(code, res.tlen)
        end
    end
end

function checkdelim!(source::AbstractVector{UInt8}, pos, len, options::Options)
    eof(source, pos, len) && return pos
    delim = options.delim
    b = peekbyte(source, pos)
    if !options.flags.ignorerepeated
        # we're checking for a single appearance of a delimiter
        match, pos = checktoken(source, pos, len, b, delim)
    else
        # keep parsing as long as we keep matching delim
        while true
            match, pos = checktoken(source, pos, len, b, delim)
            (match && !eof(source, pos, len)) || break
            b = peekbyte(source, pos)
        end
    end
    return pos
end

function _has_groupmark(opts::Options, code::ReturnCode)
    if opts.groupmark !== nothing
        isquoted = (code & QUOTED) != 0
        if isquoted || (opts.groupmark != opts.delim)
            return true
        end
    end
    return false
end


if isdefined(Base, :OncePerTask)
    const _get_bigint = OncePerTask{BigInt}(() -> BigInt(; nbits=256))
    # Note: This uses `() -> BigFloat()` instead of just `BigFloat` for --trim compatibility
    const _get_bigfloats = OncePerTask{BigFloat}(() -> BigFloat())
else
    # N.B This code is not thread safe in the presence of thread migration
    const BIGINT = BigInt[]
    const BIGFLOATS = BigFloat[]

    _get_bigfloats() = access_threaded(BigFloat, BIGFLOATS)
    _get_bigint() = access_threaded(() -> (@static VERSION > v"1.5" ? BigInt(; nbits=256) : BigInt()), BIGINT)

    function access_threaded(f, v::Vector)
        tid = Threads.threadid()
        0 < tid <= length(v) || _length_assert()
        if @inbounds isassigned(v, tid)
            @inbounds x = v[tid]
        else
            x = f()
            @inbounds v[tid] = x
        end
        return x
    end
    @noinline _length_assert() =  @assert false "0 < tid <= v"

    function __init__()
        nt = isdefined(Base.Threads, :maxthreadid) ? Threads.maxthreadid() : Threads.nthreads()
        resize!(empty!(BIGINT), nt)
        resize!(empty!(BIGFLOATS), nt)
        return
    end
end

include("ints.jl")
include("floats.jl")
include("strings.jl")
include("bools.jl")
include("dates.jl")
include("hexadecimal.jl")
include("precompile.jl")

end # module
