"""
    JSON3.@pretty json_str

Pretty print a JSON string or an object as JSON.
"""
macro pretty(json)
    return esc(:(JSON3.pretty($json)))
end

"""
    JSON3.AlignmentContext(alignment=:Left, indent=4, level=0, offset=0)

Specifies the indentation of a pretty JSON string.

## Keyword Args
* `alignment`: A Symbol specifying the alignment type. Can be `:Left` to left-align
               everything or `:Colon` to align at the `:`.
* `indent`: The number of spaces to indent each new level with.
* `level`: The indentation level.
* `offset`: The indentation offset.
"""
Base.@kwdef mutable struct AlignmentContext
    alignment::Symbol = :Left
    indent::UInt16 = 4
    level::UInt16 = 0
    offset::UInt16 = 0
    function AlignmentContext(alignment, indent, level, offset)
        if alignment != :Left && alignment != :Colon
            throw(ArgumentError("Alignment :$(alignment) is not supported. " * 
                                 "Only `:Left` and `:Colon` are supported so far"))
        end
        new(alignment, indent, level, offset)
    end
end

"""
    JSON3.pretty(x, ac=JSON3.AlignmentContext(); kw...)
    JSON3.pretty(io, x, ac=JSON3.AlignmentContext(); kw...)

Pretty print a JSON string.

## Args

* `x`: A JSON string, or an object to write to JSON then pretty print.
* `io`: The `IO` object to write the pretty printed string to. [default `stdout`]
* `ac`: The `AlignmentContext` for the pretty printing. Defaults to left-aligned
        with 4 spaces indent. See [`JSON3.AlignmentContext`](@ref) for more options.

## Keyword Args

See [`JSON3.write`](@ref) and [`JSON3.read`](@ref).
"""
pretty(str, ac=AlignmentContext(); kw...) = pretty(stdout, str, ac; kw...)
pretty(out::IO, x, ac=AlignmentContext(); kw...) = pretty(out, JSON3.write(x; kw...), ac; kw...)
function pretty(out::IO, str::AbstractString, ac=AlignmentContext(); kw...)
    buf = codeunits(str)
    len = length(buf)
    if len == 0
        return
    end
    pos = 1
    b = getbyte(buf, pos)
    @wh
    # printing object?
    if b == UInt8('{')
        Base.write(out, "{\n")

        obj = JSON3.read(str; kw...)

        if length(obj) == 0
            Base.write(out, ' '^(ac.indent * ac.level + ac.offset) * "}")
            return
        end

        ks = collect(keys(obj))
        maxlen = maximum(map(sizeof, ks)) + 5
        ac.alignment == :Colon && (ac.offset += maxlen)
        ac.level += 1

        i = 1
        for (key, value) in obj
            Base.write(out, ' '^(ac.level * ac.indent))
            Base.write(out, lpad("\"$(key)\"" * ": ", ac.offset, ' '))
            pretty(out, JSON3.write(value; kw...), ac; kw...)
            if i == length(obj)
                ac.level -= 1
                ac.alignment == :Colon && (ac.offset -= maxlen)
                Base.write(out, "\n" * ' '^(ac.indent * ac.level + ac.offset) * "}")
            else
                Base.write(out, ",\n")
                i += 1
            end
        end
    # printing array?
    elseif b == UInt8('[')
        Base.write(out, "[\n")

        arr = JSON3.read(str; kw...)

        if length(arr) == 0
            Base.write(out, ' '^(ac.indent * ac.level + ac.offset) * "]")
            return
        end

        ac.level += 1

        for (i, val) in enumerate(arr)
            Base.write(out, ' '^(ac.indent * ac.level + ac.offset))
            pretty(out, JSON3.write(val; kw...), ac; kw...)
            if i == length(arr)
                ac.level -= 1
                Base.write(out, "\n" * ' '^(ac.indent * ac.level + ac.offset) * "]")
            else
                Base.write(out, ",\n")
            end
        end
    # printing constant?
    else
        Base.write(out, str)
    end
    return
@label invalid
    Base.error("error pretty-fying json: $error")
end
