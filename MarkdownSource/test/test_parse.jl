module test_parse

using Test
using MarkdownSource: MarkdownSource as MS
using MarkdownSource.Markdown: Admonition, Code, Image, Link, List, Paragraph, Table

source_text(doc::MS.Document, span::MS.Span) =
    String(codeunits(doc.source)[span.first:span.past_last-1])

item_texts(doc::MS.Document, items::AbstractVector) =
    [source_text(doc, span) for span in MS.spans(doc, items)]

# The elements of type `T` in `doc` with the source text of their spans
function elements(doc::MS.Document, T::Type)
    found = Pair{Any,String}[]
    MS.foreach_element(doc) do element, span
        element isa T && push!(found, element => source_text(doc, span))
    end
    return found
end

get_content_map(doc::MS.Document, @nospecialize code) = MS.content_map(doc, code)::MS.SourceMap

# The source text that the `code` of `element` comes from
function content_text(doc::MS.Document, element::Code)
    map = get_content_map(doc, element)
    return source_text(doc, MS.source_span(map, 1, ncodeunits(element.code) + 1))
end

@testset "Spans" begin
    let doc = MS.parse("# Title\n\nSome `code` and *emphasis*.\n")
        @test item_texts(doc, doc.md.content) == ["# Title", "Some `code` and *emphasis*."]
        @test item_texts(doc, doc.md.content[1].text) == ["Title"]
        @test item_texts(doc, doc.md.content[2].content) ==
            ["Some ", "`code`", " and ", "*emphasis*", "."]
    end
    # Spans include the markers of the nested lines.
    let doc = MS.parse("> quoted `a`\n> and `b`\n")
        quoted = only(doc.md.content)
        @test item_texts(doc, doc.md.content) == ["> quoted `a`\n> and `b`"]
        @test item_texts(doc, only(quoted.content).content) ==
            ["quoted ", "`a`", "\n> and ", "`b`"]
    end
    let doc = MS.parse("Value: \$x and \$(f(y)).")
        paragraph = only(doc.md.content)
        @test paragraph.content == ["Value: ", :x, " and ", :(f(y)), "."]
        @test item_texts(doc, paragraph.content) == ["Value: ", "\$x", " and ", "\$(f(y))", "."]
    end
    # Spans are byte offsets.
    let doc = MS.parse("日本 [`α`](@ref)")
        @test only(elements(doc, Link)) |> last == "[`α`](@ref)"
        @test (MS.spans(doc, only(doc.md.content).content)::Vector{MS.Span})[2] == MS.Span(8, 20)
    end
    let doc = MS.parse("")
        @test isempty(doc.md.content)
        @test MS.spans(doc, doc.md.content) === nothing
    end
end

get_link_spans(doc::MS.Document, @nospecialize link) = MS.link_spans(doc, link)::MS.LinkSpans

@testset "Links" begin
    let doc = MS.parse("See [`foo`](@ref), [the bar](@ref Foo.bar), and <https://julialang.org>.")
        links = elements(doc, Link)
        @test last.(links) ==
            ["[`foo`](@ref)", "[the bar](@ref Foo.bar)", "<https://julialang.org>"]
        let link = first(links[1]), parts = get_link_spans(doc, link)
            @test source_text(doc, parts.text) == "`foo`"
            @test source_text(doc, parts.url) == "@ref"
            @test content_text(doc, only(link.text)) == "foo"
        end
        let link = first(links[2]), parts = get_link_spans(doc, link)
            @test link.url == "@ref Foo.bar"
            @test source_text(doc, parts.text) == "the bar"
            @test source_text(doc, parts.url) == "@ref Foo.bar"
            @test item_texts(doc, link.text) == ["the bar"]
        end
        let link = first(links[3]), parts = get_link_spans(doc, link)
            @test parts.text == parts.url
            @test source_text(doc, parts.url) == "https://julialang.org"
        end
    end
    # The url span covers the destination as written.
    let doc = MS.parse("[a](b\\_c)")
        link = first(only(elements(doc, Link)))
        @test link.url == "b_c"
        @test source_text(doc, get_link_spans(doc, link).url) == "b\\_c"
    end
    let doc = MS.parse("![alt *text*](image.png)")
        image = first(only(elements(doc, Image)))
        parts = get_link_spans(doc, image)
        @test source_text(doc, parts.text) == "alt *text*"
        @test source_text(doc, parts.url) == "image.png"
    end
end

@testset "Nested blocks" begin
    let doc = MS.parse("""
            !!! note "Title"
                - an item with [`foo`](@ref)

                      indented code
            """)
        admonition = only(doc.md.content)::Admonition
        list = only(admonition.content)::List
        # The span of an item starts after its marker.
        @test item_texts(doc, list.items) ==
            ["an item with [`foo`](@ref)\n\n          indented code"]
        @test last(only(elements(doc, Link))) == "[`foo`](@ref)"
        code = first(elements(doc, Code)[end])
        @test code.code == "indented code"
        @test content_text(doc, code) == "indented code"
    end
    # The lines of a code block come from separate parts of the source.
    let doc = MS.parse("> ```julia\n> x = 1\n> y = 2\n> ```\n")
        code = first(only(elements(doc, Code)))
        map = get_content_map(doc, code)
        @test code.code == "x = 1\ny = 2"
        @test source_text(doc, MS.source_span(map, 1, 6)) == "x = 1"
        @test source_text(doc, MS.source_span(map, 7, 12)) == "y = 2"
        @test content_text(doc, code) == "x = 1\n> y = 2"
    end
    # Empty items are located right after their markers.
    let doc = MS.parse("-\n- b\n")
        list = only(doc.md.content)::List
        @test MS.spans(doc, list.items) == [MS.Span(2, 2), MS.Span(5, 6)]
    end
    let doc = MS.parse("*")
        list = only(doc.md.content)::List
        @test MS.spans(doc, list.items) == [MS.Span(2, 2)]
    end
end

@testset "Line ends" begin
    let doc = MS.parse("a `b`\r\nc `d`\r\n\r\n    code\r\n    more\r\n")
        paragraph, code = doc.md.content
        @test item_texts(doc, doc.md.content) == ["a `b`\r\nc `d`", "code\r\n    more"]
        # A `\r\n` that becomes `\n` is attributed to its `\n`.
        @test item_texts(doc, paragraph.content) == ["a ", "`b`", "\nc ", "`d`"]
        @test code.code == "code\nmore"
        @test content_text(doc, code) == "code\r\n    more"
    end
end

@testset "Tables" begin
    let doc = MS.parse("""
            | a | `b` |
            |---|-----|
            | x \\| y | |
            """)
        table = only(doc.md.content)::Table
        @test item_texts(doc, table.rows) == ["| a | `b` |", "| x \\| y | |"]
        @test item_texts(doc, table.rows[1]) == ["a", "`b`"]
        @test item_texts(doc, table.rows[2]) == ["x \\| y", ""]
        @test only(table.rows[2][1]) == "x | y"
        @test item_texts(doc, table.rows[2][1]) == ["x \\| y"]
    end
end

@testset "Flavors" begin
    text = "| a | b |\n|---|---|\n| 1 | 2 |\n"
    @test only(MS.parse(text; flavor = :common).md.content) isa Paragraph
    @test only(MS.parse(text; flavor = :github).md.content) isa Table
end

@testset "foreach_element" begin
    doc = MS.parse("- *a*\n- [b](c)\n")
    visited = Any[]
    MS.foreach_element(doc) do element, _
        push!(visited, element isa AbstractVector ? :item : nameof(typeof(element)))
    end
    @test visited ==
        [:List, :item, :Paragraph, :Italic, :String, :item, :Paragraph, :Link, :String]
end

end # module test_parse
