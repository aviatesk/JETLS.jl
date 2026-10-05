"""
    Span(first::Int, past_last::Int)

A half-open range of 1-based UTF-8 byte offsets into a document's source.
"""
struct Span
    first::Int
    past_last::Int
end

"""
    Path

The location of an item in the parsed data: string keys for table entries and 1-based
indices for array elements. The empty path is the root table.
"""
const Path = Vector{Union{String,Int}}

"""
    ItemKind

How an item is written in the source:

- `ROOT_TABLE`: the document itself
- `HEADER_TABLE`: a table opened by a `[a.b]` header
- `IMPLICIT_TABLE`: a table only created by dotted keys or by the prefix of a header
- `INLINE_TABLE`: a `{ ... }` literal
- `TABLE_ARRAY`: an array of tables, built by `[[a.b]]` headers
- `TABLE_ARRAY_ELEMENT`: one element of an array of tables, opened by its `[[a.b]]` header
- `ARRAY`: a `[ ... ]` literal
- `SCALAR`: a string, number, boolean, or date/time literal
"""
@enum ItemKind begin
    ROOT_TABLE
    HEADER_TABLE
    IMPLICIT_TABLE
    INLINE_TABLE
    TABLE_ARRAY
    TABLE_ARRAY_ELEMENT
    ARRAY
    SCALAR
end

"""
    Item

The source location of an item.

- `key`: the key segment naming the item; `nothing` for the root table and array elements.
  For headers, the last segment of the header key.
- `value`: the value literal, or the whole header for `HEADER_TABLE` and
  `TABLE_ARRAY_ELEMENT`; `nothing` for implicit tables and arrays of tables
- `entry`: the whole `key = value` entry defining the item, from the first key segment to
  the end of the value; `nothing` for items not defined by an entry
"""
struct Item
    kind::ItemKind
    key::Union{Nothing,Span}
    value::Union{Nothing,Span}
    entry::Union{Nothing,Span}
end
Item(kind::ItemKind, key::Union{Nothing,Span}, value::Union{Nothing,Span}) =
    Item(kind, key, value, nothing)

# An item can be mentioned several times, e.g. `a` in `a.b = 1` and `a.c = 2`. Keep the
# first mention, unless an explicit definition supersedes an implicit table.
function record!(items::Dict{Path,Item}, path::Path, item::Item)
    old = get(items, path, nothing)
    if old === nothing || (old.kind === IMPLICIT_TABLE && item.kind !== IMPLICIT_TABLE)
        items[copy(path)] = item
    end
    return items
end

# A local date may be followed by a space that the parser consumes while checking for a time.
function trimmed_span(source::String, first::Int, past_last::Int)
    bytes = codeunits(source)
    while past_last > first && bytes[past_last-1] in (UInt8(' '), UInt8('\t'))
        past_last -= 1
    end
    return Span(first, past_last)
end
