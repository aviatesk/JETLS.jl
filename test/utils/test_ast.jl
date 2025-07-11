module test_ast

using Test
using JETLS
using JETLS: JL, JS

include(normpath(pkgdir(JETLS), "test", "jsjl_utils.jl"))

function test_string_positions(s)
    v = Vector{UInt8}(s)
    for b in eachindex(s)
        pos = JETLS.offset_to_xy(v, b)
        b2 =  JETLS.xy_to_offset(v, pos)
        @test b === b2
    end
    # One past the last byte is a valid position in an editor
    b = length(v) + 1
    pos = JETLS.offset_to_xy(v, b)
    b2 =  JETLS.xy_to_offset(v, pos)
    @test b === b2
end

@testset "Cursor file position <-> byte" begin
    fake_files = [
        "",
        "1",
        "\n\n\n",
        """
        aaa
        b
        ccc
        Αα,Ββ,Γγ,Δδ,Εε,Ζζ,Ηη,Θθ,Ιι,Κκ,Λλ,Μμ,Νν,Ξξ,Οο,Ππ,Ρρ,Σσς,Ττ,Υυ,Φφ,Χχ,Ψψ,Ωω
        """
    ]
    for i in eachindex(fake_files)
        @testset "fake_files[$i]" begin
            test_string_positions(fake_files[i])
        end
    end
end

@testset "Guard against invalid positions" begin
    let code = """
        sin
        @nospecialize
        cos(
        """ |> Vector{UInt8}
        ok = true
        for i = 0:10, j = 0:10
            ok &= JETLS.xy_to_offset(code, JETLS.Position(i, j)) isa Int
        end
        @test ok
    end
end

@testset "`get_text_and_positions`" begin
    # Test with simple ASCII text
    let text = "hello │world"
        clean_text, positions = JETLS.get_text_and_positions(text)
        @test clean_text == "hello world"
        @test length(positions) == 1
        @test positions[1] == JETLS.Position(; line=0, character=length("hello "))
    end

    # Test with multiple markers on same line
    let text = "a│b│c│d"
        clean_text, positions = JETLS.get_text_and_positions(text)
        @test clean_text == "abcd"
        @test length(positions) == 3
        @test positions[1] == JETLS.Position(; line=0, character=length("a"))
        @test positions[2] == JETLS.Position(; line=0, character=length("ab"))
        @test positions[3] == JETLS.Position(; line=0, character=length("abc"))
    end

    # Test with multi-line text
    let text = """
        line1│
        line2
        │line3│
        """
        clean_text, positions = JETLS.get_text_and_positions(text)
        @test clean_text == """
        line1
        line2
        line3
        """
        @test length(positions) == 3
        @test positions[1] == JETLS.Position(; line=0, character=length("line1"))
        @test positions[2] == JETLS.Position(; line=2, character=length(""))
        @test positions[3] == JETLS.Position(; line=2, character=length("line3"))
    end

    # Test with multi-byte characters (Greek letters)
    let text = "α│β│γ"
        clean_text, positions = JETLS.get_text_and_positions(text)
        @test clean_text == "αβγ"
        @test length(positions) == 2
        @test positions[1] == JETLS.Position(; line=0, character=length("α"))
        @test positions[2] == JETLS.Position(; line=0, character=length("αβ"))
    end

    # Test with mixed ASCII and multi-byte characters
    let text = "hello α│β world │γ"
        clean_text, positions = JETLS.get_text_and_positions(text)
        @test clean_text == "hello αβ world γ"
        @test length(positions) == 2
        @test positions[1] == JETLS.Position(; line=0, character=length("hello α"))
        @test positions[2] == JETLS.Position(; line=0, character=length("hello αβ world "))
    end

    # Test with emoji (4-byte UTF-8 characters)
    let text = "😀│😎│🎉"
        clean_text, positions = JETLS.get_text_and_positions(text)
        @test clean_text == "😀😎🎉"
        @test length(positions) == 2
        @test positions[1] == JETLS.Position(; line=0, character=length("😀"))
        @test positions[2] == JETLS.Position(; line=0, character=length("😀😎"))
    end

    # Test with custom marker
    let text = "foo<HERE>bar<HERE>baz"
        clean_text, positions = JETLS.get_text_and_positions(text, r"<HERE>")
        @test clean_text == "foobarbaz"
        @test length(positions) == 2
        @test positions[1] == JETLS.Position(; line=0, character=length("foo"))
        @test positions[2] == JETLS.Position(; line=0, character=length("foobar"))
    end

    # Test empty text
    let text = ""
        clean_text, positions = JETLS.get_text_and_positions(text)
        @test clean_text == ""
        @test isempty(positions)
    end

    # Test text with no markers
    let text = "no markers here"
        clean_text, positions = JETLS.get_text_and_positions(text)
        @test clean_text == "no markers here"
        @test isempty(positions)
    end

    # Test markers at beginning and end
    let text = "│start middle end│"
        clean_text, positions = JETLS.get_text_and_positions(text)
        @test clean_text == "start middle end"
        @test length(positions) == 2
        @test positions[1] == JETLS.Position(; line=0, character=0)
        @test positions[2] == JETLS.Position(; line=0, character=length("start middle end"))
    end

    # Test complex multi-byte scenario matching our byte_ancestors test
    let text = "α = β + │γ"
        clean_text, positions = JETLS.get_text_and_positions(text)
        @test clean_text == "α = β + γ"
        @test length(positions) == 1
        @test positions[1] == JETLS.Position(; line=0, character=length("α = β + "))
    end
end

@testset "`byte_ancestors`" begin
    # Test with a simple function
    let code = """
        function foo(x)
            return x│ + 1
        end
        """
        clean_code, positions = JETLS.get_text_and_positions(code, r"│")
        return_pos = JETLS.xy_to_offset(Vector{UInt8}(clean_code), positions[1])

        st = jlparse(clean_code)
        let ancestors = JETLS.byte_ancestors(st, 1)
            @test length(ancestors) >= 2
            @test JS.kind(ancestors[1]) === JS.K"function"
            @test JS.kind(ancestors[end]) === JS.K"toplevel"
        end
        let ancestors = JETLS.byte_ancestors(st, return_pos)
            @test length(ancestors) >= 4
            @test JS.kind(ancestors[1]) === JS.K"call"  # x + 1
            @test JS.kind(ancestors[2]) === JS.K"return"
            @test JS.kind(ancestors[3]) === JS.K"block"
            @test JS.kind(ancestors[4]) === JS.K"function"
            @test JS.kind(ancestors[end]) === JS.K"toplevel"
        end

        sn = jsparse(clean_code)
        let ancestors = JETLS.byte_ancestors(sn, 1)
            @test length(ancestors) >= 2
            @test JS.kind(ancestors[1]) === JS.K"function"
            @test JS.kind(ancestors[end]) === JS.K"toplevel"
        end
        let ancestors = JETLS.byte_ancestors(sn, return_pos)
            @test length(ancestors) >= 4
            @test JS.kind(ancestors[1]) === JS.K"call"  # x + 1
            @test JS.kind(ancestors[2]) === JS.K"return"
            @test JS.kind(ancestors[3]) === JS.K"block"
            @test JS.kind(ancestors[4]) === JS.K"function"
            @test JS.kind(ancestors[end]) === JS.K"toplevel"
        end
    end

    # Test with range
    let code = """
        module MyModule
            function test()
                println("h│ell│o")
            end
        end
        """
        clean_code, positions = JETLS.get_text_and_positions(code, r"│")
        @assert length(positions) == 2
        hello_start = JETLS.xy_to_offset(Vector{UInt8}(clean_code), positions[1])
        hello_end = JETLS.xy_to_offset(Vector{UInt8}(clean_code), positions[2]) - 1

        let st = jlparse(clean_code),
            ancestors = JETLS.byte_ancestors(st, hello_start:hello_end)
            @test any(node -> JS.kind(node) === JS.K"string" && JS.sourcetext(node) == "\"hello\"", ancestors)
            @test any(node -> JS.kind(node) === JS.K"call", ancestors)
            @test any(node -> JS.kind(node) === JS.K"function", ancestors)
            @test any(node -> JS.kind(node) === JS.K"module", ancestors)
        end
        let sn = jsparse(clean_code),
            ancestors = JETLS.byte_ancestors(sn, hello_start:hello_end)
            @test any(node -> JS.kind(node) === JS.K"string" && JS.sourcetext(node) == "\"hello\"", ancestors)
            @test any(node -> JS.kind(node) === JS.K"call", ancestors)
            @test any(node -> JS.kind(node) === JS.K"function", ancestors)
            @test any(node -> JS.kind(node) === JS.K"module", ancestors)
        end
    end

    # Test edge cases
    let code = """
        # comment
        │x = 1
        """
        clean_code, positions = JETLS.get_text_and_positions(code, r"│")
        x_pos = JETLS.xy_to_offset(Vector{UInt8}(clean_code), positions[1])

        st = jlparse(clean_code)
        sn = jsparse(clean_code)

        # Test at position beyond code length should return empty
        @test isempty(JETLS.byte_ancestors(st, 1000))
        @test isempty(JETLS.byte_ancestors(sn, 1000))

        # Test at exact boundaries
        let ancestors = JETLS.byte_ancestors(st, x_pos)
            @test any(node -> JS.kind(node) === JS.K"Identifier" && JS.sourcetext(node) == "x", ancestors)
        end
        let ancestors = JETLS.byte_ancestors(sn, x_pos)
            @test any(node -> JS.kind(node) === JS.K"Identifier" && JS.sourcetext(node) == "x", ancestors)
        end
    end

    let code = """
        a = b + │c
        """
        clean_code, positions = JETLS.get_text_and_positions(code, r"│")
        @test length(positions) == 1
        c_pos = JETLS.xy_to_offset(Vector{UInt8}(clean_code), positions[1])

        let st = jlparse(clean_code),
            ancestors = JETLS.byte_ancestors(st, c_pos)
            @test any(node -> JS.kind(node) === JS.K"Identifier" && JS.sourcetext(node) == "c", ancestors)
        end

        let sn = jsparse(clean_code),
            ancestors = JETLS.byte_ancestors(sn, c_pos)
            @test any(node -> JS.kind(node) === JS.K"Identifier" && JS.sourcetext(node) == "c", ancestors)
        end
    end

    # Test with multi-byte characters
    let code = "α = β + │γ"
        clean_code, positions = JETLS.get_text_and_positions(code, r"│")
        @test length(positions) == 1
        γ_pos = JETLS.xy_to_offset(Vector{UInt8}(clean_code), positions[1])
        @test γ_pos == sizeof("α = β + ")+1

        let st = jlparse(clean_code),
            ancestors = JETLS.byte_ancestors(st, γ_pos)
            @test any(node -> JS.kind(node) === JS.K"Identifier" && JS.sourcetext(node) == "γ", ancestors)
        end

        let sn = jsparse(clean_code)
            ancestors = JETLS.byte_ancestors(sn, γ_pos)
            @test any(node -> JS.kind(node) === JS.K"Identifier" && JS.sourcetext(node) == "γ", ancestors)
        end
    end

    # Test with multiple multi-byte characters and positions
    let code = """
        αβγ = │δεζ + ηθι│
        """
        clean_code, positions = JETLS.get_text_and_positions(code, r"│")
        @test length(positions) == 2

        pos1 = JETLS.xy_to_offset(Vector{UInt8}(clean_code), positions[1])
        @test pos1 == sizeof("αβγ = ")+1

        pos2 = JETLS.xy_to_offset(Vector{UInt8}(clean_code), positions[2])
        @test pos2 == sizeof("αβγ = δεζ + ηθι")+1

        st = jlparse(clean_code)
        ancestors1 = JETLS.byte_ancestors(st, pos1)
        @test any(node -> JS.kind(node) === JS.K"Identifier" && JS.sourcetext(node) == "δεζ", ancestors1)
        ancestors2 = JETLS.byte_ancestors(st, pos2-1)
        @test any(node -> JS.kind(node) === JS.K"Identifier" && JS.sourcetext(node) == "ηθι", ancestors2)
    end
end

@testset "token_at_offset / token_before_offset" begin
    # Test token_at_offset with simple identifiers
    let code = "alpha beta gamma"
        ps = parsedstream(code)
        @test String(ps.textbuf[JETLS.byte_range(@something(JETLS.token_at_offset(ps, 1)))]) == "alpha"
        @test String(ps.textbuf[JETLS.byte_range(@something(JETLS.token_at_offset(ps, 3)))]) == "alpha"
        @test String(ps.textbuf[JETLS.byte_range(@something(JETLS.token_at_offset(ps, 5)))]) == "alpha"
        @test String(ps.textbuf[JETLS.byte_range(@something(JETLS.token_at_offset(ps, 6)))]) == " "
        @test String(ps.textbuf[JETLS.byte_range(@something(JETLS.token_at_offset(ps, 8)))]) == "beta"
        @test isnothing(JETLS.token_at_offset(ps, 100))
    end
    let code = "foo(bar)"
        ps = parsedstream(code)
        @test String(ps.textbuf[JETLS.byte_range(@something(JETLS.token_at_offset(ps, 2)))]) == "foo"
        @test String(ps.textbuf[JETLS.byte_range(@something(JETLS.token_at_offset(ps, 4)))]) == "("
        @test String(ps.textbuf[JETLS.byte_range(@something(JETLS.token_at_offset(ps, 6)))]) == "bar"
    end

    # Test token_before_offset
    let code = "a + b"
        ps = parsedstream(code)
        @test String(ps.textbuf[JETLS.byte_range(@something(JETLS.token_before_offset(ps, 2)))]) == "a"
        @test String(ps.textbuf[JETLS.byte_range(@something(JETLS.token_before_offset(ps, 3)))]) == " "
        @test String(ps.textbuf[JETLS.byte_range(@something(JETLS.token_before_offset(ps, 4)))]) == "+"
        @test JETLS.token_before_offset(ps, 1) !== nothing  # COMBAK should probably return nothing instead
    end

    # Test with multi-byte characters
    let code = "α + β"
        ps = parsedstream(code)
        @test String(ps.textbuf[JETLS.byte_range(@something(JETLS.token_at_offset(ps, 1)))]) == "α"
        @test String(ps.textbuf[JETLS.byte_range(@something(JETLS.token_at_offset(ps, sizeof("α"))))]) == "α"
        @test String(ps.textbuf[JETLS.byte_range(@something(JETLS.token_at_offset(ps, sizeof("α")+1)))]) == " "
        @test String(ps.textbuf[JETLS.byte_range(@something(JETLS.token_before_offset(ps, sizeof("α")+1)))]) == "α"
    end
end

@testset "next_nontrivia" begin
    # Test that next_nontrivia correctly finds the next non-trivia token
    # at or after a given byte position.

    # Test basic functionality - when starting on a non-trivia token
    let code = "x   y"
        ps = parsedstream(code)
        @test String(ps.textbuf[JETLS.byte_range(@something JETLS.next_nontrivia(ps, 1))]) == "x"
        @test String(ps.textbuf[JETLS.byte_range(@something JETLS.next_nontrivia(ps, 2))]) == "y"
        @test String(ps.textbuf[JETLS.byte_range(@something JETLS.next_nontrivia(ps, sizeof(code)))]) == "y"
        @test isnothing(JETLS.next_nontrivia(ps, sizeof(code)+1))
    end

    # Test with pass_newlines=true
    let code = "x\n  y"
        ps = parsedstream(code)
        @test JETLS.JS.kind(JETLS.this(@something JETLS.next_nontrivia(ps, 2))) == JETLS.JS.K"NewlineWs"
        @test String(ps.textbuf[JETLS.byte_range(@something JETLS.next_nontrivia(ps, 2; pass_newlines=true))]) == "y"
    end

    # Test with comments (comments are considered trivia)
    let code = "x # comment\ny"
        ps = parsedstream(code)
        @test JETLS.JS.kind(JETLS.this(@something JETLS.next_nontrivia(ps, sizeof("x #")))) == JETLS.JS.K"NewlineWs"
        @test String(ps.textbuf[JETLS.byte_range(@something JETLS.next_nontrivia(ps, sizeof("x #"); pass_newlines=true))]) == "y"

        code = "x \n#= multi-line\ncomment =#\ny"
        ps = parsedstream(code)
        @test JETLS.JS.kind(JETLS.this(@something JETLS.next_nontrivia(ps, sizeof("x \n#")))) == JETLS.JS.K"NewlineWs"
        @test String(ps.textbuf[JETLS.byte_range(@something JETLS.next_nontrivia(ps, sizeof("x \n#"); pass_newlines=true))]) == "y"
    end

    let code = "foo(bar)"
        ps = parsedstream(code)
        @test String(ps.textbuf[JETLS.byte_range(@something JETLS.next_nontrivia(ps, 1))]) == "foo"
        @test String(ps.textbuf[JETLS.byte_range(@something JETLS.next_nontrivia(ps, 4))]) == "("
        @test String(ps.textbuf[JETLS.byte_range(@something JETLS.next_nontrivia(ps, 5))]) == "bar"
    end

    let code = "   "
        ps = parsedstream(code)
        @test isnothing(JETLS.next_nontrivia(ps, 1))
        @test isnothing(JETLS.next_nontrivia(ps, 1; pass_newlines=true))
    end

    # Test next_nontrivia_byte accessor function
    let code = "a b"
        ps = parsedstream(code)
        @test JETLS.next_nontrivia_byte(ps, 1) == 1
        @test JETLS.next_nontrivia_byte(ps, 2) == 3
        @test JETLS.next_nontrivia_byte(ps, 3) == 3
    end
end

@testset "noparen_macrocall" begin
    @test JETLS.noparen_macrocall(jlparse("@test true"; rule=:statement))
    @test JETLS.noparen_macrocall(jlparse("@interface AAA begin end"; rule=:statement))
    @test !JETLS.noparen_macrocall(jlparse("@test(true)"; rule=:statement))
    @test !JETLS.noparen_macrocall(jlparse("r\"xxx\""; rule=:statement))
end

get_target_node(::Type{JL.SyntaxTree}, code::AbstractString, pos::Int) = JETLS.select_target_node(jlparse(code), pos)
get_target_node(::Type{JS.SyntaxNode}, code::AbstractString, pos::Int) = JETLS.select_target_node(jsparse(code), pos)
function get_target_node(::Type{T}, code::AbstractString, matcher::Regex=r"│") where T
    clean_code, positions = JETLS.get_text_and_positions(code, matcher)
    @assert length(positions) == 1
    return get_target_node(T, clean_code, JETLS.xy_to_offset(Vector{UInt8}(clean_code), positions[1]))
end

@testset "`select_target_node` / `get_source_range`" begin
    @testset "with $T" for T in (JL.SyntaxTree, JS.SyntaxNode)
        let code = """
            test_│func(5)
            """
            node = get_target_node(T, code)
            @test (node !== nothing) && (JS.kind(node) === JS.K"Identifier")
            @test JS.sourcetext(node) == "test_func"
            let range = JETLS.get_source_range(node)
                @test range.start.line == 0 && range.start.character == 0
                @test range.var"end".line == 0 && range.var"end".character == sizeof("test_func")
            end
        end

        let code = """
            obj.│property = 42
            """
            node = get_target_node(T, code)
            @test node !== nothing
            @test JS.kind(node) === JS.K"."
            @test length(JS.children(node)) == 2
            @test JS.sourcetext(JS.children(node)[1]) == "obj"
            @test JS.sourcetext(JS.children(node)[2]) == "property"
            let range = JETLS.get_source_range(node)
                @test range.start.line == 0 && range.start.character == 0
                @test range.var"end".line == 0 && range.var"end".character == sizeof("obj.property")
            end
        end

        let code = """
            Core.Compiler.tme│et(x)
            """
            node = get_target_node(T, code)
            @test node !== nothing
            @test JS.kind(node) === JS.K"."
            let range = JETLS.get_source_range(node)
                @test range.start.line == 0 && range.start.character == 0
                @test range.var"end".line == 0 && range.var"end".character == sizeof("Core.Compiler.tmeet")
            end
        end

        let code = """
            Core.Compi│ler.tmeet(x)
            """
            node = get_target_node(T, code)
            @test node !== nothing
            @test JS.kind(node) === JS.K"."
            let range = JETLS.get_source_range(node)
                @test range.start.line == 0 && range.start.character == 0
                @test range.var"end".line == 0 && range.var"end".character == sizeof("Core.Compiler")
            end
        end

        let code = """
            Cor│e.Compiler.tmeet(x)
            """
            node = get_target_node(T, code)
            @test node !== nothing
            @test JS.kind(node) === JS.K"Identifier"
            let range = JETLS.get_source_range(node)
                @test range.start.line == 0 && range.start.character == 0
                @test range.var"end".line == 0 && range.var"end".character == sizeof("Core")
            end
        end

        let code = """
            @inline│ callsin(x) = sin(x)
            """
            node = get_target_node(T, code)
            @test node !== nothing
            @test JS.kind(node) === JS.K"MacroName"
            let range = JETLS.get_source_range(node)
                @test range.start.line == 0 && range.start.character == 0 # include at mark
                @test range.var"end".line == 0 && range.var"end".character == sizeof("@inline")
            end
        end

        let code = """
            Base.@inline│ callsin(x) = sin(x)
            """
            node = get_target_node(T, code)
            @test node !== nothing
            let range = JETLS.get_source_range(node)
                @test range.start.line == 0 && range.start.character == 0
                @test range.var"end".line == 0 && range.var"end".character == sizeof("Base.@inline")
            end
        end

        let code = """
            text│"sin"
            """
            node = get_target_node(T, code)
            @test node !== nothing
            let range = JETLS.get_source_range(node)
                @test range.start.line == 0 && range.start.character == 0
                @test range.var"end".line == 0 && range.var"end".character == sizeof("text")
            end
        end

        let code = """
            function test_func(x)
                return x │ + 1
            end
            """
            node = get_target_node(T, code)
            @test node === nothing
        end

        let code = """
            │
            """
            node = get_target_node(T, code)
            @test node === nothing
        end
    end
end

get_dotprefix_node(code::AbstractString, pos::Int) = JETLS.select_dotprefix_node(jlparse(code), pos)
function get_dotprefix_node(code::AbstractString, matcher::Regex=r"│")
    clean_code, positions = JETLS.get_text_and_positions(code, matcher)
    @assert length(positions) == 1
    return get_dotprefix_node(clean_code, JETLS.xy_to_offset(Vector{UInt8}(clean_code), positions[1]))
end
@testset "`select_dotprefix_node`" begin
    @test isnothing(get_dotprefix_node("isnothing│"))
    let node = get_dotprefix_node("Base.Sys.│")
        @test !isnothing(node)
        @test JS.sourcetext(node) == "Base.Sys"
    end
    let node = get_dotprefix_node("Base.Sys.CPU│")
        @test !isnothing(node)
        @test JS.sourcetext(node) == "Base.Sys"
    end
    let node = get_dotprefix_node("Base.Sy│s")
        @test !isnothing(node)
        @test JS.sourcetext(node) == "Base"
    end
    let node = get_dotprefix_node("""
        function foo(x)
            Core.│
        end
        """)
        @test !isnothing(node)
        @test JS.sourcetext(node) == "Core"
    end
    let node = get_dotprefix_node("""
        function foo(x = Base.│)
        end
        """)
        @test !isnothing(node)
        @test JS.sourcetext(node) == "Base"
    end
end

end # module test_ast
