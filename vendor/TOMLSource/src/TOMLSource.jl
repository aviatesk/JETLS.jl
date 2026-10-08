module TOMLSource

using Dates: Dates
using PrecompileTools: @compile_workload
using TOML: TOML

public Document, Item, ItemKind, ParserError, Path, SourceEdit, Span, apply, delete_entry,
    format_value, insert_table_entry, item, key_span, minimal_edit, move_entry, parse,
    prepend_array_element, replace_value, tryparse, value_span
public ARRAY, HEADER_TABLE, IMPLICIT_TABLE, INLINE_TABLE, ROOT_TABLE, SCALAR, TABLE_ARRAY,
    TABLE_ARRAY_ELEMENT

include("sourcemap.jl")

"""
A fork of `Base.TOML`'s parser that also records source locations.
"""
module BaseTOML
using ..TOMLSource: ARRAY, HEADER_TABLE, IMPLICIT_TABLE, INLINE_TABLE, Item, Path, SCALAR,
    Span, TABLE_ARRAY, TABLE_ARRAY_ELEMENT, record!, trimmed_span
include("parser.jl")
end

const ParserError = BaseTOML.ParserError

"""
    Document

A parsed TOML document. `data` holds the parsed values, as `TOML.parse` returns them, and
`items` maps the path of every item in `data` to its location in `source`.
"""
struct Document
    source::String
    data::Dict{String,Any}
    items::Dict{Path,Item}
end

"""
    tryparse(text::AbstractString) -> Union{Document,ParserError}

Parse `text` with source locations, returning a `ParserError` for invalid TOML.
"""
function tryparse(text::AbstractString)
    source = String(text)::String
    items = Dict{Path,Item}()
    data = BaseTOML.tryparse(BaseTOML.Parser{Dates}(source; items))
    data isa ParserError && return data
    items[Path()] = Item(ROOT_TABLE, nothing, Span(1, ncodeunits(source) + 1))
    return Document(source, data, items)
end

"""
    parse(text::AbstractString) -> Document

Like `tryparse`, but throw a `ParserError` for invalid TOML.
"""
function parse(text::AbstractString)
    doc = tryparse(text)
    doc isa ParserError && throw(doc)
    return doc
end

parse_data(text::String) = BaseTOML.tryparse(BaseTOML.Parser{Dates}(text))

"""
    item(doc::Document, path::AbstractVector) -> Union{Item,Nothing}

Return the source location of the item at `path`, or `nothing` if there is no such item.
"""
item(doc::Document, path::AbstractVector) = get(doc.items, path, nothing)

"""
    key_span(doc::Document, path::AbstractVector) -> Union{Span,Nothing}

Return the span of the key naming the item at `path`.
"""
function key_span(doc::Document, path::AbstractVector)
    found = item(doc, path)
    return found === nothing ? nothing : found.key
end

"""
    value_span(doc::Document, path::AbstractVector) -> Union{Span,Nothing}

Return the span of the value of the item at `path`. See `Item` for what it covers.
"""
function value_span(doc::Document, path::AbstractVector)
    found = item(doc, path)
    return found === nothing ? nothing : found.value
end

include("editing.jl")

@compile_workload let text = "a.b = [1]\nc = [{ d = 1 }]\n[[e]]\nf = { g = 1 }\n"
    doc = parse(text)
    value_span(doc, ["e", 1, "f", "g"])
    prepend_array_element(doc, ["a", "b"], 0)
    prepend_array_element(doc, ["c"], Dict("d" => "value"))
    insert_table_entry(doc, ["e", 1], "h", "value")
    insert_table_entry(doc, ["e", 1, "f"], "h", 1)
    tryparse("a =")
end

end # module TOMLSource
