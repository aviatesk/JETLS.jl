module test_ast

using Test
using JETLS
using JETLS: JL, JS

include(normpath(pkgdir(JETLS), "test", "jsjl_utils.jl"))

@testset "`byte_ancestors`" begin
    # Test with a simple function
    let code = """
        function foo(x)
            return x│ + 1
        end
        """
        clean_code, positions = JETLS.get_text_and_positions(code)
        return_pos = JETLS.xy_to_offset(clean_code, positions[1])

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
        clean_code, positions = JETLS.get_text_and_positions(code)
        @assert length(positions) == 2
        hello_start = JETLS.xy_to_offset(clean_code, positions[1])
        hello_end = JETLS.xy_to_offset(clean_code, positions[2]) - 1

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
        clean_code, positions = JETLS.get_text_and_positions(code)
        x_pos = JETLS.xy_to_offset(clean_code, positions[1])

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
        clean_code, positions = JETLS.get_text_and_positions(code)
        @test length(positions) == 1
        c_pos = JETLS.xy_to_offset(clean_code, positions[1])

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
        clean_code, positions = JETLS.get_text_and_positions(code)
        @test length(positions) == 1
        γ_pos = JETLS.xy_to_offset(clean_code, positions[1])
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
        clean_code, positions = JETLS.get_text_and_positions(code)
        @test length(positions) == 2

        pos1 = JETLS.xy_to_offset(clean_code, positions[1])
        @test pos1 == sizeof("αβγ = ")+1

        pos2 = JETLS.xy_to_offset(clean_code, positions[2])
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
        @test String(ps.textbuf[JS.byte_range(@something(JETLS.token_at_offset(ps, 1)))]) == "alpha"
        @test String(ps.textbuf[JS.byte_range(@something(JETLS.token_at_offset(ps, 3)))]) == "alpha"
        @test String(ps.textbuf[JS.byte_range(@something(JETLS.token_at_offset(ps, 5)))]) == "alpha"
        @test String(ps.textbuf[JS.byte_range(@something(JETLS.token_at_offset(ps, 6)))]) == " "
        @test String(ps.textbuf[JS.byte_range(@something(JETLS.token_at_offset(ps, 8)))]) == "beta"
        @test isnothing(JETLS.token_at_offset(ps, 100))
    end
    let code = "foo(bar)"
        ps = parsedstream(code)
        @test String(ps.textbuf[JS.byte_range(@something(JETLS.token_at_offset(ps, 2)))]) == "foo"
        @test String(ps.textbuf[JS.byte_range(@something(JETLS.token_at_offset(ps, 4)))]) == "("
        @test String(ps.textbuf[JS.byte_range(@something(JETLS.token_at_offset(ps, 6)))]) == "bar"
    end

    # Test token_before_offset
    let code = "a + b"
        ps = parsedstream(code)
        @test String(ps.textbuf[JS.byte_range(@something(JETLS.token_before_offset(ps, 2)))]) == "a"
        @test String(ps.textbuf[JS.byte_range(@something(JETLS.token_before_offset(ps, 3)))]) == " "
        @test String(ps.textbuf[JS.byte_range(@something(JETLS.token_before_offset(ps, 4)))]) == "+"
        @test isnothing(JETLS.token_before_offset(ps, 1))
    end

    # Test with multi-byte characters
    let code = "α + β"
        ps = parsedstream(code)
        @test String(ps.textbuf[JS.byte_range(@something(JETLS.token_at_offset(ps, 1)))]) == "α"
        @test String(ps.textbuf[JS.byte_range(@something(JETLS.token_at_offset(ps, sizeof("α"))))]) == "α"
        @test String(ps.textbuf[JS.byte_range(@something(JETLS.token_at_offset(ps, sizeof("α")+1)))]) == " "
        @test String(ps.textbuf[JS.byte_range(@something(JETLS.token_before_offset(ps, sizeof("α")+1)))]) == "α"
    end
end

@testset "TokenCursor" begin
    let tc = JETLS.TokenCursor(parsedstream(""))
        @test isempty(tc) == iszero(length(tc))
    end
    let code = "abc def"
        ps = parsedstream(code)
        toks = collect(JETLS.TokenCursor(ps))
        @test length(toks) == 3
        @test String(ps.textbuf[JS.byte_range(toks[1])]) == "abc"
        @test String(ps.textbuf[JS.byte_range(toks[2])]) == " "
        @test String(ps.textbuf[JS.byte_range(toks[3])]) == "def"
    end
end

@testset "prev_nontrivia" begin
    # Test that prev_nontrivia correctly finds the previous non-trivia token
    # at or before a given byte position.

    # Test basic functionality
    let code = "x   y"
        ps = parsedstream(code)
        @test String(ps.textbuf[JS.byte_range(@something JETLS.prev_nontrivia(ps, 1))]) == "x"
        @test String(ps.textbuf[JS.byte_range(@something JETLS.prev_nontrivia(ps, 3))]) == "x"
        @test String(ps.textbuf[JS.byte_range(@something JETLS.prev_nontrivia(ps, 5))]) == "y"
        @test isnothing(JETLS.prev_nontrivia(ps, 0))
        @test isnothing(JETLS.prev_nontrivia(ps, sizeof(code)+1))
        @test isnothing(JETLS.prev_nontrivia(ps, 100))
    end

    # Test with newlines
    let code = "x\n  y"
        ps = parsedstream(code)
        @test JETLS.JS.kind(JETLS.this(@something JETLS.prev_nontrivia(ps, 2))) == JETLS.JS.K"NewlineWs"
        @test String(ps.textbuf[JS.byte_range(@something JETLS.prev_nontrivia(ps, 2; pass_newlines=true))]) == "x"
        @test String(ps.textbuf[JS.byte_range(@something JETLS.prev_nontrivia(ps, sizeof(code)))]) == "y"
        @test isnothing(JETLS.prev_nontrivia(ps, sizeof(code)+1))  # beyond input
    end

    # Test with comments
    let code = "x # comment\ny"
        ps = parsedstream(code)
        @test String(ps.textbuf[JS.byte_range(@something JETLS.prev_nontrivia(ps, 5))]) == "x"  # from within comment
        @test JETLS.JS.kind(JETLS.this(@something JETLS.prev_nontrivia(ps, sizeof(code)-1))) == JETLS.JS.K"NewlineWs"  # at newline
        @test String(ps.textbuf[JS.byte_range(@something JETLS.prev_nontrivia(ps, sizeof(code)-1; pass_newlines=true))]) == "x"
        @test String(ps.textbuf[JS.byte_range(@something JETLS.prev_nontrivia(ps, sizeof(code)))]) == "y"
    end

    # Test with block comments
    let code = "x #= block\ncomment =# y"
        ps = parsedstream(code)
        @test String(ps.textbuf[JS.byte_range(@something JETLS.prev_nontrivia(ps, 15))]) == "x"  # from within block comment
        @test String(ps.textbuf[JS.byte_range(@something JETLS.prev_nontrivia(ps, sizeof(code)))]) == "y"
        @test isnothing(JETLS.prev_nontrivia(ps, sizeof(code)+1))  # beyond input
    end

    # Test at various positions in non-trivia tokens
    let code = "foo(bar)"
        ps = parsedstream(code)
        @test String(ps.textbuf[JS.byte_range(@something JETLS.prev_nontrivia(ps, 1))]) == "foo"  # at start
        @test String(ps.textbuf[JS.byte_range(@something JETLS.prev_nontrivia(ps, 2))]) == "foo"  # in middle
        @test String(ps.textbuf[JS.byte_range(@something JETLS.prev_nontrivia(ps, 3))]) == "foo"  # at end
        @test String(ps.textbuf[JS.byte_range(@something JETLS.prev_nontrivia(ps, 4))]) == "("
        @test String(ps.textbuf[JS.byte_range(@something JETLS.prev_nontrivia(ps, 5))]) == "bar"
        @test String(ps.textbuf[JS.byte_range(@something JETLS.prev_nontrivia(ps, 7))]) == "bar"
        @test String(ps.textbuf[JS.byte_range(@something JETLS.prev_nontrivia(ps, 8))]) == ")"
    end

    # Test edge cases
    let code = "   "  # Only spaces
        ps = parsedstream(code)
        @test isnothing(JETLS.prev_nontrivia(ps, sizeof(code)))
        @test isnothing(JETLS.prev_nontrivia(ps, sizeof(code); pass_newlines=true))
    end

    # Test prev_nontrivia_byte accessor function
    let code = "a b"
        ps = parsedstream(code)
        @test JETLS.prev_nontrivia_byte(ps, 1) == 1
        @test JETLS.prev_nontrivia_byte(ps, 2) == 1  # from space
        @test JETLS.prev_nontrivia_byte(ps, 3) == 3
        @test isnothing(JETLS.prev_nontrivia_byte(ps, 0))
    end

    # Test with comments and newlines for prev_nontrivia_byte
    let code = "x  # comment\ny"
        ps = parsedstream(code)
        @test JETLS.prev_nontrivia_byte(ps, sizeof(code)) == sizeof(code)  # at 'y'
        @test JETLS.prev_nontrivia_byte(ps, sizeof(code)-1) == sizeof(code)-1  # at newline
        @test JETLS.prev_nontrivia_byte(ps, sizeof(code)-1; pass_newlines=true) == 1  # skip newline to 'x'
        @test JETLS.prev_nontrivia_byte(ps, sizeof(code)-2) == 1   # from end of comment
        @test JETLS.prev_nontrivia_byte(ps, 5) == 1   # from within comment
    end

    # Test with strict=true option
    let code = "x\n# comment\ny"
        ps = parsedstream(code)
        # At 'y'
        @test JETLS.prev_nontrivia_byte(ps, sizeof(code)) == sizeof(code)
        @test JETLS.prev_nontrivia_byte(ps, sizeof(code); strict=true) == sizeof(code)-1

        # At the second newline
        @test JETLS.prev_nontrivia_byte(ps, sizeof(code)-1) == sizeof(code)-1
        @test JETLS.prev_nontrivia_byte(ps, sizeof(code)-1; strict=true) == 2
        @test JETLS.prev_nontrivia_byte(ps, sizeof(code)-1; pass_newlines=true, strict=true) == 1

        # At 'x'
        @test JETLS.prev_nontrivia_byte(ps, 1) == 1
        @test isnothing(JETLS.prev_nontrivia_byte(ps, 1; strict=true))
    end
end

@testset "next_nontrivia" begin
    # Test that next_nontrivia correctly finds the next non-trivia token
    # at or after a given byte position.

    # Test basic functionality - when starting on a non-trivia token
    let code = "x   y"
        ps = parsedstream(code)
        @test String(ps.textbuf[JS.byte_range(@something JETLS.next_nontrivia(ps, 1))]) == "x"
        @test String(ps.textbuf[JS.byte_range(@something JETLS.next_nontrivia(ps, 2))]) == "y"
        @test String(ps.textbuf[JS.byte_range(@something JETLS.next_nontrivia(ps, sizeof(code)))]) == "y"
        @test isnothing(JETLS.next_nontrivia(ps, sizeof(code)+1))
    end

    # Test with pass_newlines=true
    let code = "x\n  y"
        ps = parsedstream(code)
        @test JETLS.JS.kind(JETLS.this(@something JETLS.next_nontrivia(ps, 2))) == JETLS.JS.K"NewlineWs"
        @test String(ps.textbuf[JS.byte_range(@something JETLS.next_nontrivia(ps, 2; pass_newlines=true))]) == "y"
    end

    # Test with comments (comments are considered trivia)
    let code = "x # comment\ny"
        ps = parsedstream(code)
        @test JETLS.JS.kind(JETLS.this(@something JETLS.next_nontrivia(ps, sizeof("x #")))) == JETLS.JS.K"NewlineWs"
        @test String(ps.textbuf[JS.byte_range(@something JETLS.next_nontrivia(ps, sizeof("x #"); pass_newlines=true))]) == "y"

        code = "x \n#= multi-line\ncomment =#\ny"
        ps = parsedstream(code)
        @test JETLS.JS.kind(JETLS.this(@something JETLS.next_nontrivia(ps, sizeof("x \n#")))) == JETLS.JS.K"NewlineWs"
        @test String(ps.textbuf[JS.byte_range(@something JETLS.next_nontrivia(ps, sizeof("x \n#"); pass_newlines=true))]) == "y"
    end

    let code = "foo(bar)"
        ps = parsedstream(code)
        @test String(ps.textbuf[JS.byte_range(@something JETLS.next_nontrivia(ps, 1))]) == "foo"
        @test String(ps.textbuf[JS.byte_range(@something JETLS.next_nontrivia(ps, 4))]) == "("
        @test String(ps.textbuf[JS.byte_range(@something JETLS.next_nontrivia(ps, 5))]) == "bar"
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

    # Test with strict=true option
    let code_til_first_newline = "x # comment\n"
        code_til_second_newline = code_til_first_newline * "y #= block =#\n"
        code = code_til_second_newline * "z" # "x # comment\ny #= block =#\nz"

        ps = parsedstream(code)
        # At 'x'
        @test JETLS.next_nontrivia_byte(ps, 1) == 1
        @test JETLS.next_nontrivia_byte(ps, 1; strict=true) == sizeof(code_til_first_newline)

        # At space after 'x'
        @test JETLS.next_nontrivia_byte(ps, 2) == sizeof(code_til_first_newline)
        @test JETLS.next_nontrivia_byte(ps, 2; strict=true) == sizeof(code_til_first_newline)

        # At the first newline
        @test JETLS.next_nontrivia_byte(ps, sizeof(code_til_first_newline)) == sizeof(code_til_first_newline)
        @test JETLS.next_nontrivia_byte(ps, sizeof(code_til_first_newline); strict=true) == sizeof(code_til_first_newline)+1

        # At `y`
        @test JETLS.next_nontrivia_byte(ps, sizeof(code_til_first_newline)+1) == sizeof(code_til_first_newline)+1
        @test JETLS.next_nontrivia_byte(ps, sizeof(code_til_first_newline)+1; strict=true) == sizeof(code_til_second_newline)
        @test JETLS.next_nontrivia_byte(ps, sizeof(code_til_first_newline)+1; pass_newlines=true, strict=true) == sizeof(code_til_second_newline)+1 # z

        # At the second newline position
        @test JETLS.next_nontrivia_byte(ps, sizeof(code_til_second_newline)) == sizeof(code_til_second_newline)
        @test JETLS.next_nontrivia_byte(ps, sizeof(code_til_second_newline); strict=true) == sizeof(code_til_second_newline)+1 # z

        # At 'z'
        @test JETLS.next_nontrivia_byte(ps, sizeof(code)) == sizeof(code)
        @test isnothing(JETLS.next_nontrivia_byte(ps, sizeof(code); strict=true))
    end
end

@testset "noparen_macrocall" begin
    @test JETLS.noparen_macrocall(jlparse("@test true"; rule=:statement))
    @test JETLS.noparen_macrocall(jlparse("@interface AAA begin end"; rule=:statement))
    @test !JETLS.noparen_macrocall(jlparse("@test(true)"; rule=:statement))
    @test !JETLS.noparen_macrocall(jlparse("r\"xxx\""; rule=:statement))
end

select_target_node(::Type{JL.SyntaxTree}, code::AbstractString, pos::Int) = JETLS.select_target_node(jlparse(code), pos)
select_target_node(::Type{JS.SyntaxNode}, code::AbstractString, pos::Int) = JETLS.select_target_node(jsparse(code), pos)
function get_target_node(::Type{T}, code::AbstractString; kwargs...) where T
    clean_code, positions = JETLS.get_text_and_positions(code; kwargs...)
    @assert length(positions) == 1
    fi = JETLS.FileInfo(1, parsedstream(clean_code))
    target_node = select_target_node(T, clean_code, JETLS.xy_to_offset(clean_code, positions[1]))
    return fi, target_node
end

@testset "`select_target_node` / `jsobj_to_range`" begin
    @testset "with $T" for T in (JL.SyntaxTree, JS.SyntaxNode)
        let code = """
            test_│func(5)
            """
            fi, node = get_target_node(T, code)
            @test (node !== nothing) && (JS.kind(node) === JS.K"Identifier")
            @test JS.sourcetext(node) == "test_func"
            let range = JETLS.jsobj_to_range(node, fi)
                @test range.start.line == 0 && range.start.character == 0
                @test range.var"end".line == 0 && range.var"end".character == sizeof("test_func")
            end
        end

        let code = """
            obj.│property = 42
            """
            fi, node = get_target_node(T, code)
            @test node !== nothing
            @test JS.kind(node) === JS.K"."
            @test length(JS.children(node)) == 2
            @test JS.sourcetext(JS.children(node)[1]) == "obj"
            @test JS.sourcetext(JS.children(node)[2]) == "property"
            let range = JETLS.jsobj_to_range(node, fi)
                @test range.start.line == 0 && range.start.character == 0
                @test range.var"end".line == 0 && range.var"end".character == sizeof("obj.property")
            end
        end

        let code = """
            Core.Compiler.tme│et(x)
            """
            fi, node = get_target_node(T, code)
            @test node !== nothing
            @test JS.kind(node) === JS.K"."
            let range = JETLS.jsobj_to_range(node, fi)
                @test range.start.line == 0 && range.start.character == 0
                @test range.var"end".line == 0 && range.var"end".character == sizeof("Core.Compiler.tmeet")
            end
        end

        let code = """
            Core.Compi│ler.tmeet(x)
            """
            fi, node = get_target_node(T, code)
            @test node !== nothing
            @test JS.kind(node) === JS.K"."
            let range = JETLS.jsobj_to_range(node, fi)
                @test range.start.line == 0 && range.start.character == 0
                @test range.var"end".line == 0 && range.var"end".character == sizeof("Core.Compiler")
            end
        end

        let code = """
            Cor│e.Compiler.tmeet(x)
            """
            fi, node = get_target_node(T, code)
            @test node !== nothing
            @test JS.kind(node) === JS.K"Identifier"
            let range = JETLS.jsobj_to_range(node, fi)
                @test range.start.line == 0 && range.start.character == 0
                @test range.var"end".line == 0 && range.var"end".character == sizeof("Core")
            end
        end

        let code = """
            @inline│ callsin(x) = sin(x)
            """
            fi, node = get_target_node(T, code)
            @test node !== nothing
            @test JS.kind(node) === JS.K"MacroName"
            let range = JETLS.jsobj_to_range(node, fi)
                @test range.start.line == 0 && range.start.character == 1 # not include the @-mark
                @test range.var"end".line == 0 && range.var"end".character == sizeof("@inline")
            end
        end

        let code = """
            Base.@inline│ callsin(x) = sin(x)
            """
            fi, node = get_target_node(T, code)
            @test node !== nothing
            let range = JETLS.jsobj_to_range(node, fi)
                @test range.start.line == 0 && range.start.character == 0
                @test range.var"end".line == 0 && range.var"end".character == sizeof("Base.@inline")
            end
        end

        let code = """
            text│"sin"
            """
            fi, node = get_target_node(T, code)
            @test node !== nothing
            let range = JETLS.jsobj_to_range(node, fi)
                @test range.start.line == 0 && range.start.character == 0
                @test range.var"end".line == 0 && range.var"end".character == sizeof("text")
            end
        end

        let code = """
            function test_func(x)
                return x │ + 1
            end
            """
            _, node = get_target_node(T, code)
            @test node === nothing
        end

        let code = """
            │
            """
            _, node = get_target_node(T, code)
            @test node === nothing
        end
    end
end

get_dotprefix_node(code::AbstractString, pos::Int) = JETLS.select_dotprefix_node(jlparse(code), pos)
function get_dotprefix_node(code::AbstractString; kwargs...)
    clean_code, positions = JETLS.get_text_and_positions(code; kwargs...)
    @assert length(positions) == 1
    return get_dotprefix_node(clean_code, JETLS.xy_to_offset(clean_code, positions[1]))
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
