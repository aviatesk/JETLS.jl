module test_parse

using Test
using TOML: TOML
using TOMLSource: TOMLSource as TS

source_text(doc::TS.Document, span::TS.Span) =
    String(codeunits(doc.source)[span.first:span.past_last-1])

@testset "Source ranges" begin
    let doc = TS.parse("[server]\nport = \"oops\"\n")
        @test doc.data == Dict("server" => Dict("port" => "oops"))
        @test source_text(doc, TS.key_span(doc, ["server", "port"])) == "port"
        @test source_text(doc, TS.value_span(doc, ["server", "port"])) == "\"oops\""
        @test source_text(doc, TS.value_span(doc, ["server"])) == "[server]"
        @test TS.value_span(doc, ["missing"]) === nothing
        @test TS.key_span(doc, ["missing"]) === nothing
    end
    for newline in ("\n", "\r\n")
        doc = TS.parse("\"😀\" = \"日😀本\"" * newline * "next = [10, 20]" * newline)
        @test doc.data["😀"] == "日😀本"
        @test source_text(doc, TS.key_span(doc, ["😀"])) == "\"😀\""
        @test source_text(doc, TS.value_span(doc, ["😀"])) == "\"日😀本\""
        @test source_text(doc, TS.value_span(doc, ["next", 2])) == "20"
    end
    let doc = TS.parse("a.\"b.c\" = {x = [true, false]}\n")
        @test doc.data["a"]["b.c"]["x"] == [true, false]
        @test source_text(doc, TS.key_span(doc, ["a", "b.c"])) == "\"b.c\""
        @test source_text(doc, TS.value_span(doc, ["a", "b.c"])) == "{x = [true, false]}"
        @test source_text(doc, TS.value_span(doc, ["a", "b.c", "x", 2])) == "false"
    end
    let doc = TS.parse("[[items]]\nname = \"first\"\n[[items]]\nname = \"second\"\n")
        @test source_text(doc, TS.value_span(doc, ["items", 2, "name"])) == "\"second\""
        @test source_text(doc, TS.key_span(doc, ["items", 1, "name"])) == "name"
    end
    let doc = TS.parse("text = \"\"\"日\n😀\"\"\"\n")
        @test source_text(doc, TS.value_span(doc, ["text"])) == "\"\"\"日\n😀\"\"\""
    end
    let doc = TS.parse("date = 2026-10-06 # comment\ntime = 07:32:00\t\n")
        @test source_text(doc, TS.value_span(doc, ["date"])) == "2026-10-06"
        @test source_text(doc, TS.value_span(doc, ["time"])) == "07:32:00"
    end
end

@testset "Item kinds" begin
    doc = TS.parse("""
        a.b = 1
        x = [{ y = 2 }]
        [t.u]
        [[arr]]
        v = 3
        [arr.sub]
        [[arr]]
        [[arr.nested]]
        """)
    kinds = Dict(path => item.kind for (path, item) in doc.items)
    @test length(kinds) == 15
    @test kinds[[]] === TS.ROOT_TABLE
    @test kinds[["a"]] === TS.IMPLICIT_TABLE
    @test kinds[["a", "b"]] === TS.SCALAR
    @test kinds[["x"]] === TS.ARRAY
    @test kinds[["x", 1]] === TS.INLINE_TABLE
    @test kinds[["x", 1, "y"]] === TS.SCALAR
    @test kinds[["t"]] === TS.IMPLICIT_TABLE
    @test kinds[["t", "u"]] === TS.HEADER_TABLE
    @test kinds[["arr"]] === TS.TABLE_ARRAY
    @test kinds[["arr", 1]] === TS.TABLE_ARRAY_ELEMENT
    @test kinds[["arr", 1, "v"]] === TS.SCALAR
    @test kinds[["arr", 1, "sub"]] === TS.HEADER_TABLE
    @test kinds[["arr", 2]] === TS.TABLE_ARRAY_ELEMENT
    @test kinds[["arr", 2, "nested"]] === TS.TABLE_ARRAY
    @test kinds[["arr", 2, "nested", 1]] === TS.TABLE_ARRAY_ELEMENT
    @test TS.value_span(doc, ["t"]) === nothing
    @test source_text(doc, TS.key_span(doc, ["t"])) == "t"
    @test source_text(doc, TS.value_span(doc, ["arr", 2])) == "[[arr]]"
    @test source_text(doc, TS.key_span(doc, ["arr", 2])) == "arr"
    @test source_text(doc, TS.value_span(doc, ["arr", 2, "nested", 1])) == "[[arr.nested]]"
    let doc = TS.parse("[a.b]\n[a]\n")
        @test TS.item(doc, ["a"]).kind === TS.HEADER_TABLE
        @test source_text(doc, TS.value_span(doc, ["a"])) == "[a]"
    end
    let doc = TS.parse("[ a . \"b\" ]\n[[ c ]]\n")
        @test source_text(doc, TS.value_span(doc, ["a", "b"])) == "[ a . \"b\" ]"
        @test source_text(doc, TS.value_span(doc, ["c", 1])) == "[[ c ]]"
    end
    let doc = TS.parse("a . \"b\" = { c = [1, 2] } # comment\n[d]\n")
        entry(path) = TS.item(doc, path).entry
        @test source_text(doc, entry(["a", "b"])) == "a . \"b\" = { c = [1, 2] }"
        @test source_text(doc, entry(["a", "b", "c"])) == "c = [1, 2]"
        @test entry(["a"]) === entry(["a", "b", "c", 1]) === entry(["d"]) === nothing
    end
end

@testset "Errors" begin
    for source in ("a = 1\na = 2\n", "a =\nb = 2\n", "[a\n", "a = \"unterminated",
            "a = 1\na.b = 2\n", "a = [1,,]")
        err = TS.tryparse(source)
        @test err isa TS.ParserError
        @test err.pos isa Int
        @test_throws TS.ParserError TS.parse(source)
    end
    # `Base.TOML`, and hence Pkg, does not skip a byte order mark.
    @test TS.tryparse("﻿a = 1") isa TS.ParserError
    @test TOML.tryparse("﻿a = 1") isa TOML.ParserError
end

end # module test_parse
