module MarkdownSource

using Base.ScopedValues: ScopedValue, with
using PrecompileTools: @compile_workload

public Document, LinkSpans, Markdown, SourceMap, Span, content_map, foreach_element,
    link_spans, parse, source_span, spans

include("sourcemap.jl")

"""
A fork of the parser of the `Markdown` standard library that also records source locations.
It defines its own element types, e.g. `MarkdownSource.Markdown.Link`, which are distinct
from those of the standard library.
"""
module Markdown
import Base: mapany, show
using ..MarkdownSource: cellstream, copyline!, linestream, record_blocks!, record_inline!,
    record_item!, record_link!, record_paragraph!, record_text!, sourced, substream,
    takebuffer!, wrappedstream
@static if !isdefinedglobal(Base, :takestring!)
    takestring!(io::IOBuffer) = String(take!(io))
end
include("Markdown/parse/config.jl")
include("Markdown/parse/util.jl")
include("Markdown/parse/parse.jl")
include("Markdown/Common/Common.jl")
include("Markdown/GitHub/GitHub.jl")
include("Markdown/IPython/IPython.jl")
include("Markdown/Julia/Julia.jl")
end

"""
    Document

A parsed Markdown document. `md` is the `Markdown.MD` that `Markdown.parse` of the `Markdown`
standard library returns for `source`, but built from the element types of
`MarkdownSource.Markdown`. The other fields record where the elements of `md` are in
`source`: see `spans`, `link_spans`, and `content_map`.
"""
struct Document
    source::String
    md::Markdown.MD
    spans::IdDict{Any,Vector{Span}}
    links::IdDict{Union{Markdown.Link,Markdown.Image},LinkSpans}
    contents::IdDict{Union{Markdown.Code,Markdown.LaTeX},SourceMap}
end

"""
    parse(text::AbstractString; flavor::Symbol = :julia) -> Document

Parse `text` like `Markdown.parse(text; flavor)`, recording the source locations of the
elements.
"""
function parse(text::AbstractString; flavor::Symbol = :julia)
    source = String(text)::String
    recorder = Recorder()
    stream = IOBuffer(source)
    recorder.maps[stream] = StreamMap(source, [Segment(0, 1, ncodeunits(source))])
    md = with(RECORDER => recorder) do
        Markdown.parse(stream; flavor)
    end
    return Document(source, md, recorder.spans, recorder.links, recorder.contents)
end

"""
    spans(doc::Document, items::AbstractVector) -> Union{Vector{Span},Nothing}

Return the spans of `items`, which is the content of `doc.md` or of one of its elements, e.g.
the `content` of a `Paragraph` or the `text` of a `Link`. They are aligned with `items`.

The span of a block covers it from its first non-whitespace character to the end of its last
non-blank line, including the markers of its nested lines, such as the `>` of a block quote.
The span of a list item starts after its marker. The span of an inline element covers its
delimiters, and the span of a string covers its characters as written, e.g. `\\*` for `*`.
"""
spans(doc::Document, items::AbstractVector) = get(doc.spans, items, nothing)

"""
    link_spans(doc::Document, element) -> Union{LinkSpans,Nothing}

Return the source locations of the parts of `element`, a `Link` or an `Image` of `doc`.
"""
link_spans(doc::Document, @nospecialize(element)) = get(doc.links, element, nothing)

"""
    content_map(doc::Document, element) -> Union{SourceMap,Nothing}

Return where in `doc.source` the `code` of `element`, a `Code` of `doc`, or the `formula` of
a `LaTeX`, comes from. Unlike inline code, the lines of code blocks may come from separate
parts of the source, e.g. without the indentation of a list item.
"""
content_map(doc::Document, @nospecialize(element)) = get(doc.contents, element, nothing)

# The items nested in `element` that have spans
function children(@nospecialize(element))
    element isa AbstractVector && return element
    element isa Union{Markdown.Paragraph,Markdown.BlockQuote,Markdown.Admonition} &&
        return element.content
    if element isa Union{Markdown.Header,Markdown.Italic,Markdown.Bold,
                         Markdown.Strikethrough,Markdown.Link,Markdown.Footnote}
        text = element.text
        return text isa AbstractVector ? text : nothing
    end
    element isa Markdown.List && return element.items
    element isa Markdown.Table && return element.rows
    return nothing
end

"""
    foreach_element(f, doc::Document)

Call `f(element, span)` for every element of `doc.md` with its span, in the order of the
source, each element before the elements nested in it. Besides the elements, the items of a
`List` and the rows and cells of a `Table`, which are vectors, are visited, as are the
strings of text between inline elements. See `spans` for what the spans cover.
"""
function foreach_element(f, doc::Document)
    foreach_element(f, doc, doc.md.content)
    return nothing
end

function foreach_element(f, doc::Document, items::AbstractVector)
    item_spans = spans(doc, items)
    item_spans === nothing && return nothing
    for (item, span) in zip(items, item_spans)
        f(item, span)
        nested = children(item)
        nested === nothing || foreach_element(f, doc, nested)
    end
    return nothing
end

@compile_workload let text = """
    # Title
    Some `code`, [`foo`](@ref), and *emphasis*.
    ```julia
    x = 1
    ```
    !!! note
        - an item with [a link](https://julialang.org)
    | a | b |
    |---|---|
    | 1 | 2 |
    """
    foreach_element(Returns(nothing), parse(text))
end

end # module MarkdownSource
