module test_editing

using Test
using TOML: TOML
using TOMLSource: TOMLSource as TS

@testset "Value formatting" begin
    let value = Dict{String,Any}("pattern" => "A\nB\t\u0001\\\"雪😀\0",
            "path" => "src/A.jl", "enabled" => true, "nested" => Dict("x" => [1, 2]),
            "tables" => [Dict("y" => 1)], "empty" => Dict{String,Any}())
        text = TS.format_value(value)
        @test !occursin('\n', text)
        @test TOML.parse("value = $text")["value"] == value
    end
    @test TS.format_value(Dict("key with space" => 1)) == "{\"key with space\" = 1}"
    @test TS.format_value(Any[1, "s", 2.5, [true]]) == "[1, \"s\", 2.5, [true]]"
    @test_throws ArgumentError TS.format_value(Dict(1 => 2))
end

@testset "Array insertion preserves source text" begin
    cases = [
        "a=[]" => "a=[2]",
        "a = [  ]" => "a = [  2]",
        "a=[1]" => "a=[2, 1]",
        "a = [\n    ]" => "a = [\n    2\n    ]",
        "a = [\r\n\t1, # old\r\n]\r\n" =>
            "a = [\r\n\t2,\r\n\t1, # old\r\n]\r\n",
        "a = [ # opening\n  # before [\n  1, # after ]\n] # ending" =>
            "a = [ # opening\n  # before [\n  2,\n  1, # after ]\n] # ending",
        "a = [ # empty\r\n\t# retained\r\n]" =>
            "a = [ # empty\r\n\t# retained\r\n2\r\n]",
        "a = [\"\"\"first\n# second\"\"\"]" =>
            "a = [2, \"\"\"first\n# second\"\"\"]",
        "a=[[1]]" => "a=[2, [1]]",
        "a=[{x = 1}]" => "a=[2, {x = 1}]",
        "a=[{x = [1]}]" => "a=[2, {x = [1]}]",
        "\"😀\" = 0\r\na = [] # 雪" => "\"😀\" = 0\r\na = [2] # 雪",
    ]
    for (source, expected_source) in cases
        doc = TS.parse(source)
        before = deepcopy(doc.data)
        edit = TS.prepend_array_element(doc, ["a"], 2)::TS.SourceEdit
        @test edit.span.first == edit.span.past_last
        @test TS.apply(source, edit) == expected_source
        expected = deepcopy(before)
        expected["a"] = pushfirst!(Vector{Any}(expected["a"]), 2)
        @test TOML.parse(expected_source) == expected
        @test doc.data == before
        @test doc.source == source
    end
end

@testset "Array insertion paths and values" begin
    cases = [
        ("a.b = []", ["a", "b"]),
        ("a = { b = [] }", ["a", "b"]),
        ("\"a\\u0062\" = []", ["ab"]),
        ("a = [[]]", ["a", Int32(1)]),
        ("[[groups]]\na = []\n", ["groups", 1, "a"]),
        ("a = []", [SubString("a-key", 1, 1)]),
    ]
    value = Dict("nested" => Dict("x" => [1, 2]), "text" => "\"\n#😀")
    for (source, path) in cases
        doc = TS.parse(source)
        edit = TS.prepend_array_element(doc, path, value)::TS.SourceEdit
        result = TOML.parse(TS.apply(source, edit))
        target = result
        for component in path
            target = target[component]
        end
        @test only(target) == value
    end
    let source = "a = [nan]\nother = nan\n", doc = TS.parse(source)
        edit = TS.prepend_array_element(doc, ["a"], Inf)::TS.SourceEdit
        @test isequal(TOML.parse(TS.apply(source, edit)),
            Dict("a" => [Inf, NaN], "other" => NaN))
    end
    let source = "a = []", doc = TS.parse(source)
        value = view(Int32[1, 2, 3], 2:3)
        edit = TS.prepend_array_element(doc, ["a"], value)::TS.SourceEdit
        @test TOML.parse(TS.apply(source, edit))["a"] == [[2, 3]]
    end
end

@testset "Array insertion declines unsupported targets" begin
    for source in ("a = 1", "[a]\nx = 1", "[[a]]\nx = 1", "[[a]]\n[[a]]")
        @test TS.prepend_array_element(TS.parse(source), ["a"], 2) === nothing
    end
    let doc = TS.parse("a = []")
        @test TS.prepend_array_element(doc, ["missing"], 2) === nothing
        @test TS.prepend_array_element(doc, ["a", 0], 2) === nothing
        @test TS.prepend_array_element(doc, [], 2) === nothing
        @test_throws Exception TS.prepend_array_element(doc, ["a"], nothing)
        push!(doc.data["a"], 99)
        @test TS.prepend_array_element(doc, ["a"], 2) === nothing
    end
end

@testset "Table entry insertion preserves source text" begin
    cases = [
        ("[deps]\nA = \"x\" # comment\n\n[compat]\n", ["deps"]) =>
            "[deps]\nA = \"x\" # comment\nB = 2\n\n[compat]\n",
        ("[compat]\n[deps]\n", ["compat"]) => "[compat]\nB = 2\n[deps]\n",
        ("[compat] # header\n", ["compat"]) => "[compat] # header\nB = 2\n",
        ("[deps]\nA = 1", ["deps"]) => "[deps]\nA = 1\nB = 2",
        ("[deps]\r\nA = 1\r\n", ["deps"]) => "[deps]\r\nA = 1\r\nB = 2\r\n",
        ("[deps]\n  A = 1\n", ["deps"]) => "[deps]\n  A = 1\n  B = 2\n",
        ("[a]\nx = 1\n[a.b]\ny = 2\n", ["a"]) => "[a]\nx = 1\nB = 2\n[a.b]\ny = 2\n",
        ("[a]\nb.c = 1\n", ["a"]) => "[a]\nb.c = 1\nB = 2\n",
        ("[a]\nx = [\n  1,\n] # end\n", ["a"]) => "[a]\nx = [\n  1,\n] # end\nB = 2\n",
        ("[[a]]\nx = 1\n[[a]]\nx = 2\n", ["a", 1]) => "[[a]]\nx = 1\nB = 2\n[[a]]\nx = 2\n",
        ("[[a]]\nx = 1\n[[a]]\nx = 2\n", ["a", 2]) => "[[a]]\nx = 1\n[[a]]\nx = 2\nB = 2\n",
        ("name = \"x\"\n\n[deps]\n", []) => "name = \"x\"\nB = 2\n\n[deps]\n",
        ("# header comment\n[deps]\n", []) => "B = 2\n# header comment\n[deps]\n",
        ("", []) => "B = 2\n",
        ("a = {x = 1}", ["a"]) => "a = {x = 1, B = 2}",
        ("a = { x = { y = 1 } }", ["a"]) => "a = { x = { y = 1 }, B = 2 }",
        ("a = {}", ["a"]) => "a = {B = 2}",
        ("a = [{}]", ["a", 1]) => "a = [{B = 2}]",
    ]
    for ((source, path), expected_source) in cases
        doc = TS.parse(source)
        edit = TS.insert_table_entry(doc, path, "B", 2)::TS.SourceEdit
        @test TS.apply(source, edit) == expected_source
    end
    let doc = TS.parse("[deps]\n")
        edit = TS.insert_table_entry(doc, ["deps"], "a b", Dict("x" => [1]))::TS.SourceEdit
        @test TS.apply(doc.source, edit) == "[deps]\n\"a b\" = {x = [1]}\n"
    end
end

@testset "Table entry insertion declines unsupported targets" begin
    doc = TS.parse("a.b = 1\nc = [1]\n[d]\ne = 1\n")
    @test TS.insert_table_entry(doc, ["a"], "x", 1) === nothing
    @test TS.insert_table_entry(doc, ["c"], "x", 1) === nothing
    @test TS.insert_table_entry(doc, ["d"], "e", 1) === nothing
    @test TS.insert_table_entry(doc, ["missing"], "x", 1) === nothing
    @test TS.insert_table_entry(doc, ["a", "b"], "x", 1) === nothing
    @test TS.insert_table_entry(doc, ["d"], "x", 1) isa TS.SourceEdit
    doc.data["d"]["x"] = 0
    @test TS.insert_table_entry(doc, ["d"], "x", 1) === nothing
end

@testset "Minimal edits keep characters whole" begin
    @test TS.minimal_edit("a = \"é\"", "a = \"è\"") == TS.SourceEdit(TS.Span(6, 8), "è")
    @test TS.minimal_edit("x", "xy") == TS.SourceEdit(TS.Span(2, 2), "y")
    @test TS.minimal_edit("abc", "abc") == TS.SourceEdit(TS.Span(4, 4), "")
end

@testset "Entry deletion" begin
    cases = [
        ("a = 1\nb = 2 # comment\nc = 3\n", ["b"], false) => "a = 1\nc = 3\n",
        ("a = 1\r\nb = 2\r\n", ["b"], false) => "a = 1\r\n",
        ("a = 1\nb = 2", ["b"], false) => "a = 1\n",
        ("x = [\n  1,\n]\ny = 2\n", ["x"], false) => "y = 2\n",
        ("[t]\n  a = 1\n  b = 2\n", ["t", "b"], false) => "[t]\n  a = 1\n",
        ("a.b = 1\na.c = 2\n", ["a", "b"], false) => "a.c = 2\n",
        ("t = { a = 1, b = 2 }", ["t", "a"], false) => "t = { b = 2 }",
        ("t = { a = 1, b = 2 }", ["t", "b"], false) => "t = { a = 1 }",
        ("t = { a = 1 }", ["t", "a"], false) => "t = { }",
        ("[a]\nx = 1\n\n# about b\n[b]\ny = 2\n", ["a"], false) => "# about b\n[b]\ny = 2\n",
        ("a = 1\n\nb = 2\n\nc = 3\n", ["b"], false) => "a = 1\n\nc = 3\n",
        ("a = 1\r\n\r\nb = 2\r\n\r\nc = 3\r\n", ["b"], false) => "a = 1\r\n\r\nc = 3\r\n",
        ("a = 1\n \nb = 2\n\t\nc = 3\n", ["b"], false) => "a = 1\n \nc = 3\n",
        ("a = 1\n\nb = 2\nc = 3\n", ["b"], false) => "a = 1\n\nc = 3\n",
        ("a = 1\n\nb = 2", ["b"], false) => "a = 1\n",
        ("p = 1\n\n[t]\nx = \"foo\"\n\n[[u]]\nq = 2\n", ["t", "x"], true) =>
            "p = 1\n\n[[u]]\nq = 2\n",
        ("p = 1\n\n[t]\nx = 1\n", ["t"], false) => "p = 1\n",
        ("[c.m]\np = true\n", ["c", "m", "p"], false) => "[c.m]\n",
        ("[c.m]\np = true\n[d]\ne = 1\n", ["c", "m", "p"], true) => "[d]\ne = 1\n",
        ("t = { a = 1 }\nu = 2\n", ["t", "a"], true) => "u = 2\n",
        ("[t]\na = 1\nb = 2\n", ["t", "a"], true) => "[t]\nb = 2\n",
        ("[t]\nx.y = 1\n[u]\n", ["t", "x", "y"], true) => "[u]\n",
        ("[[a]]\nx = 1\n", ["a", 1, "x"], true) => "[[a]]\n",
        ("test = [\"Test\", \"Foo\"]\n", ["test", 2], false) => "test = [\"Test\"]\n",
        ("test = [\"Test\", \"Foo\"]\n", ["test", 1], false) => "test = [\"Foo\"]\n",
        ("x = [1]\n", ["x", 1], false) => "x = []\n",
        ("x = [[1, 2], [3]]\n", ["x", 1, 2], false) => "x = [[1], [3]]\n",
        ("x = [\n  \"a\",\n  \"b\", # c\n]\n", ["x", 2], false) => "x = [\n  \"a\",\n]\n",
        ("x = [\n  \"a\",\n  \"b\"\n]\n", ["x", 2], false) => "x = [\n  \"a\",\n]\n",
        ("x = [\r\n  1,\r\n  2,\r\n]\r\n", ["x", 1], false) => "x = [\r\n  2,\r\n]\r\n",
        ("x = [\n  1, 2,\n]\n", ["x", 1], false) => "x = [\n  2,\n]\n",
        ("[targets]\ntest = [\"Test\", \"Foo\"]\n", ["targets", "test", 2], true) =>
            "[targets]\ntest = [\"Test\"]\n",
    ]
    for ((source, path, prune), expected_source) in cases
        doc = TS.parse(source)
        edit = TS.delete_entry(doc, path; prune)::TS.SourceEdit
        @test TS.apply(source, edit) == expected_source
    end
    let doc = TS.parse("[b]\nx = 1\n[b.c]\ny = 2\n[[t]]\nz = 1\n")
        @test TS.delete_entry(doc, ["t", 1]) === nothing
        @test TS.delete_entry(doc, ["missing"]) === nothing
        @test TS.delete_entry(doc, ["b"]) === nothing
    end
end

@testset "Entry moves" begin
    cases = [
        ("[t]\nold = 1 # c\n", ["t", "old"], ["t", "new"], false) => "[t]\nnew = 1 # c\n",
        ("[i]\nend_lines = 7\n", ["i", "end_lines"], ["i", "end", "lines"], false) =>
            "[i]\nend.lines = 7\n",
        ("i.end_lines = 7\n", ["i", "end_lines"], ["i", "end", "lines"], false) =>
            "i.end.lines = 7\n",
        ("i = { end_lines = 7 }\n", ["i", "end_lines"], ["i", "end", "lines"], false) =>
            "i = { end.lines = 7 }\n",
        ("[a]\nx = [1, 2]\ny = 2\n[b]\nz = 3\n", ["a", "x"], ["b", "x"], false) =>
            "[a]\ny = 2\n[b]\nz = 3\nx = [1, 2]\n",
        ("[c.m]\np = 1\n[c]\nq = 2\n", ["c", "m", "p"], ["c", "p"], true) =>
            "[c]\nq = 2\np = 1\n",
        ("[a]\nx = 1\n[a.b]\ny = 2\n", ["a", "x"], ["a", "b", "x"], false) =>
            "[a]\n[a.b]\ny = 2\nx = 1\n",
    ]
    for ((source, old_path, new_path, prune), expected_source) in cases
        doc = TS.parse(source)
        edit = TS.move_entry(doc, old_path, new_path; prune)::TS.SourceEdit
        @test TS.apply(source, edit) == expected_source
    end
    let doc = TS.parse("[a]\nx = 1\ny = 2\n")
        @test TS.move_entry(doc, ["a", "x"], ["a", "y"]) === nothing
        @test TS.move_entry(doc, ["a"], ["b"]) === nothing
        @test TS.move_entry(doc, ["a", "x"], []) === nothing
    end
end

@testset "Value replacement" begin
    cases = [
        ("a = true # c\n", ["a"], "always") => "a = \"always\" # c\n",
        ("[t]\nx = [1, 2]\n", ["t", "x"], Dict("k" => 1)) => "[t]\nx = {k = 1}\n",
        ("t = { a = 1, b = 2 }", ["t", "b"], 3) => "t = { a = 1, b = 3 }",
        ("t.u = 'x'\n", ["t", "u"], 1.5) => "t.u = 1.5\n",
    ]
    for ((source, path, value), expected_source) in cases
        edit = TS.replace_value(TS.parse(source), path, value)::TS.SourceEdit
        @test TS.apply(source, edit) == expected_source
    end
    let doc = TS.parse("[t]\nx = [1, 2]\n")
        @test TS.replace_value(doc, ["t"], 1) === nothing
        @test TS.replace_value(doc, ["t", "x", 1], 3) === nothing
        @test TS.replace_value(doc, ["missing"], 1) === nothing
    end
end

end # module test_editing
