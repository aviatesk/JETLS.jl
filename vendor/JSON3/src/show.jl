Base.show(io::IO, j::Object) = _show(io, j)
# use the Base fallback AbstractArray show method instead
# Base.show(io::IO, j::Array) = _show(io, j)
_show(io::IO, x, indent=0, offset=0) = show(io, x)

function _show(io::IO, obj::Object, indent=0, offset=0)
    if isempty(obj)
        print(io, "{}")
        return
    end
    println(io, "{")
    indent += 1
    keyvals = collect(obj)
    keys = map(x->x[1], keyvals)
    vals = map(x->x[2], keyvals)
    maxlen = maximum(map(sizeof, keys)) + 5
    # @show maxlen
    for i = 1:length(keys)
        Base.write(io, "  "^indent)
        Base.write(io, lpad("\"$(keys[i])\"" * ": ", maxlen + offset, ' '))
        _show(io, vals[i], indent, maxlen + offset)
        if i == length(keys)
            indent -= 1
            Base.write(io, "\n" * ("  "^indent * " "^offset) * "}")
        else
            Base.write(io, ",\n")
        end
    end
    return
end

function _show(io::IO, arr::Array, indent=0, offset=0)
    if isempty(arr)
        print(io, "[]")
        return
    end
    println(io, "[")
    indent += 1
    vals = collect(arr)
    for (i, val) in enumerate(vals)
        Base.write(io, "  "^indent * " "^offset)
        _show(io, vals[i], indent, offset)
        if i == length(vals)
            indent -= 1
            Base.write(io, "\n" * ("  "^indent * " "^offset) * "]")
        else
            Base.write(io, ",\n")
        end
    end
    return
end
