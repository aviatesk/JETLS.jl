module test_ast

using Test
using JETLS
using JETLS: JL, JS

include(normpath(pkgdir(JETLS), "test", "jsjl-utils.jl"))

@testset "`byte_ancestors`" begin
    # Test with a simple function
    let code = """
        function foo(x)
            return x│ + 1
        end
        """
        clean_code, positions = JETLS.get_text_and_positions(code)
        return_pos = JETLS.xy_to_offset(clean_code, positions[1], @__FILE__)

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
        hello_start = JETLS.xy_to_offset(clean_code, positions[1], @__FILE__)
        hello_end = JETLS.xy_to_offset(clean_code, positions[2], @__FILE__) - 1

        let st = jlparse(clean_code),
            ancestors = JETLS.byte_ancestors(st, hello_start:hello_end)
            @test any(node -> JS.kind(node) === JS.K"String" && JS.sourcetext(node) == "hello", ancestors)
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
        x_pos = JETLS.xy_to_offset(clean_code, positions[1], @__FILE__)

        st = jlparse(clean_code)

        # Test at position beyond code length should return empty
        @test isempty(JETLS.byte_ancestors(st, 1000))

        # Test at exact boundaries
        let ancestors = JETLS.byte_ancestors(st, x_pos)
            @test any(node -> JS.kind(node) === JS.K"Identifier" && JS.sourcetext(node) == "x", ancestors)
        end
    end

    let code = """
        a = b + │c
        """
        clean_code, positions = JETLS.get_text_and_positions(code)
        @test length(positions) == 1
        c_pos = JETLS.xy_to_offset(clean_code, positions[1], @__FILE__)

        let st = jlparse(clean_code),
            ancestors = JETLS.byte_ancestors(st, c_pos)
            @test any(node -> JS.kind(node) === JS.K"Identifier" && JS.sourcetext(node) == "c", ancestors)
        end
    end

    # Test with multi-byte characters
    let code = "α = β + │γ"
        clean_code, positions = JETLS.get_text_and_positions(code)
        @test length(positions) == 1
        γ_pos = JETLS.xy_to_offset(clean_code, positions[1], @__FILE__)
        @test γ_pos == sizeof("α = β + ")+1

        let st = jlparse(clean_code),
            ancestors = JETLS.byte_ancestors(st, γ_pos)
            @test any(node -> JS.kind(node) === JS.K"Identifier" && JS.sourcetext(node) == "γ", ancestors)
        end
    end

    # Test with multiple multi-byte characters and positions
    let code = """
        αβγ = │δεζ + ηθι│
        """
        clean_code, positions = JETLS.get_text_and_positions(code)
        @test length(positions) == 2

        pos1 = JETLS.xy_to_offset(clean_code, positions[1], @__FILE__)
        @test pos1 == sizeof("αβγ = ")+1

        pos2 = JETLS.xy_to_offset(clean_code, positions[2], @__FILE__)
        @test pos2 == sizeof("αβγ = δεζ + ηθι")+1

        st = jlparse(clean_code)
        ancestors1 = JETLS.byte_ancestors(st, pos1)
        @test any(node -> JS.kind(node) === JS.K"Identifier" && JS.sourcetext(node) == "δεζ", ancestors1)
        ancestors2 = JETLS.byte_ancestors(st, pos2-1)
        @test any(node -> JS.kind(node) === JS.K"Identifier" && JS.sourcetext(node) == "ηθι", ancestors2)
    end
end

@testset "lowerable_toplevel_at" begin
    # Return the top-level subtree whose byte range contains the cursor.
    let code = """
        function foo(│x│)
            return │x│ + 1
        end
        """
        clean_code, positions = JETLS.get_text_and_positions(code)
        st = jlparse(clean_code)
        for pos in positions
            offset = JETLS.xy_to_offset(clean_code, pos, @__FILE__)
            local_tree = JETLS.lowerable_toplevel_at(st, offset)
            @test !isnothing(local_tree)
            @test JS.kind(local_tree) === JS.K"function"
        end
    end

    # Cursor inside a module but not any contained statement: no top-level subtree to lower.
    let code = """
        module M
        │
        end
        """
        clean_code, positions = JETLS.get_text_and_positions(code)
        offset = JETLS.xy_to_offset(clean_code, only(positions), @__FILE__)
        st = jlparse(clean_code)
        @test isnothing(JETLS.lowerable_toplevel_at(st, offset))
    end

    # Offset past the end of the source.
    let code = "x = 1\n"
        st = jlparse(code)
        @test isnothing(JETLS.lowerable_toplevel_at(st, 1000))
    end

    # Fallback: when the cursor is just past the last token on a line (e.g. `export foo│\n`),
    # the raw offset lands on whitespace owned only by `toplevel`.
    # `lowerable_toplevel_at` should retry with `offset - 1` and return the enclosing statement.
    let code = """
        export foo
        foo(1)
        """
        clean_code = code
        st = jlparse(clean_code)
        # Offset at the newline after `foo` (i.e. one past the identifier's last byte).
        offset = sizeof("export foo") + 1
        local_tree = JETLS.lowerable_toplevel_at(st, offset)
        @test !isnothing(local_tree)
        @test JS.kind(local_tree) === JS.K"export"
    end

    # Same fallback for trailing identifier in a statement-ending position.
    let code = "x = 1\ny\n"
        st = jlparse(code)
        offset = sizeof("x = 1\ny") + 1  # just past `y`, on the newline
        local_tree = JETLS.lowerable_toplevel_at(st, offset)
        @test !isnothing(local_tree)
        @test JS.kind(local_tree) === JS.K"Identifier"
        @test JS.sourcetext(local_tree) == "y"
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

        @test startswith(sprint(show, toks[1]), "TokenCursor at position 1 Identifier")
        @test startswith(sprint(show, toks[2]), "TokenCursor at position 2 Whitespace")
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
        @test JS.kind(@something JETLS.prev_nontrivia(ps, 2)) == JS.K"NewlineWs"
        @test String(ps.textbuf[JS.byte_range(@something JETLS.prev_nontrivia(ps, 2; pass_newlines=true))]) == "x"
        @test String(ps.textbuf[JS.byte_range(@something JETLS.prev_nontrivia(ps, sizeof(code)))]) == "y"
        @test isnothing(JETLS.prev_nontrivia(ps, sizeof(code)+1))  # beyond input
    end

    # Test with comments
    let code = "x # comment\ny"
        ps = parsedstream(code)
        @test String(ps.textbuf[JS.byte_range(@something JETLS.prev_nontrivia(ps, 5))]) == "x"  # from within comment
        @test JS.kind(@something JETLS.prev_nontrivia(ps, sizeof(code)-1)) == JS.K"NewlineWs"  # at newline
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
        @test JS.kind(@something JETLS.next_nontrivia(ps, 2)) == JS.K"NewlineWs"
        @test String(ps.textbuf[JS.byte_range(@something JETLS.next_nontrivia(ps, 2; pass_newlines=true))]) == "y"
    end

    # Test with comments (comments are considered trivia)
    let code = "x # comment\ny"
        ps = parsedstream(code)
        @test JS.kind(@something JETLS.next_nontrivia(ps, sizeof("x #"))) == JS.K"NewlineWs"
        @test String(ps.textbuf[JS.byte_range(@something JETLS.next_nontrivia(ps, sizeof("x #"); pass_newlines=true))]) == "y"

        code = "x \n#= multi-line\ncomment =#\ny"
        ps = parsedstream(code)
        @test JS.kind(@something JETLS.next_nontrivia(ps, sizeof("x \n#"))) == JS.K"NewlineWs"
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

@testset "get_line_indent" begin
    let code = "export a, b"
        fi = JETLS.FileInfo(#=version=#0, code, @__FILE__)
        @test JETLS.get_line_indent(fi, 0) == ""
    end
    let code = "    export a, b"
        fi = JETLS.FileInfo(#=version=#0, code, @__FILE__)
        @test JETLS.get_line_indent(fi, 0) == "    "
    end
    let code = "begin\n    export a, b\nend"
        fi = JETLS.FileInfo(#=version=#0, code, @__FILE__)
        @test JETLS.get_line_indent(fi, 0) == ""
    end
    let code = "begin\n    export a, b\nend"
        fi = JETLS.FileInfo(#=version=#0, code, @__FILE__)
        @test JETLS.get_line_indent(fi, 1) == "    "
    end
    let code = "\t\texport a, b"
        fi = JETLS.FileInfo(#=version=#0, code, @__FILE__)
        @test JETLS.get_line_indent(fi, 0) == "\t\t"
    end
    let code = "begin export a, b end"
        fi = JETLS.FileInfo(#=version=#0, code, @__FILE__)
        @test JETLS.get_line_indent(fi, 0) == ""
    end
end

@testset "noparen_macrocall" begin
    @test JETLS.noparen_macrocall(jlparse("@test true"; rule=:statement))
    @test JETLS.noparen_macrocall(jlparse("@interface AAA begin end"; rule=:statement))
    @test !JETLS.noparen_macrocall(jlparse("@test(true)"; rule=:statement))
    @test !JETLS.noparen_macrocall(jlparse("r\"xxx\""; rule=:statement))
    @test !JETLS.noparen_macrocall(jlparse("cmdmac`xxx`"; rule=:statement))
end

select_target_identifier(code::AbstractString, pos::Int) = JETLS.select_target_identifier(jlparse(code), pos)
function get_target_identifier(code::AbstractString; kwargs...)
    clean_code, positions = JETLS.get_text_and_positions(code; kwargs...)
    @assert length(positions) == 1
    fi = JETLS.FileInfo(1, clean_code, @__FILE__)
    target_node = select_target_identifier(clean_code, JETLS.xy_to_offset(fi, positions[1]))
    return fi, target_node
end

@testset "`select_target_identifier` / `jsobj_to_range`" begin
    let code = """
        test_│func(5)
        """
        fi, node = get_target_identifier(code)
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
        fi, node = get_target_identifier(code)
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
        fi, node = get_target_identifier(code)
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
        fi, node = get_target_identifier(code)
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
        fi, node = get_target_identifier(code)
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
        fi, node = get_target_identifier(code)
        @test node !== nothing
        @test JS.kind(node) === JS.K"Identifier"
        let range = JETLS.jsobj_to_range(node, fi)
            @test range.start.line == 0 && range.start.character == 0 # include @-mark
            @test range.var"end".line == 0 && range.var"end".character == sizeof("@inline")
        end
    end

    let code = """
        Base.@inline│ callsin(x) = sin(x)
        """
        fi, node = get_target_identifier(code)
        @test node !== nothing
        let range = JETLS.jsobj_to_range(node, fi)
            @test range.start.line == 0 && range.start.character == 0 # include `Base.`
            @test range.var"end".line == 0 && range.var"end".character == sizeof("Base.@inline")
        end
    end

    let code = """
        text│"sin"
        """
        fi, node = get_target_identifier(code)
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
        _, node = get_target_identifier(code)
        @test node === nothing
    end

    let code = """
        │
        """
        _, node = get_target_identifier(code)
        @test node === nothing
    end
end

select_target_string(code::AbstractString, pos::Int) = JETLS.select_target_string(jlparse(code), pos)
function get_target_string(code::AbstractString; kwargs...)
    clean_code, positions = JETLS.get_text_and_positions(code; kwargs...)
    @assert length(positions) == 1
    return select_target_string(clean_code, JETLS.xy_to_offset(clean_code, positions[1], @__FILE__))
end
@testset "`select_target_string`" begin
    let node = get_target_string("include(\"fo│o.jl\")")
        @test node !== nothing
        @test JS.kind(node) === JS.K"String"
        @test JS.hasattr(node, :value)
        @test node.value == "foo.jl"
    end
    let node = get_target_string("x = \"hello│ world\"")
        @test node !== nothing
        @test node.value == "hello world"
    end
    @test isnothing(get_target_string("x = 42│"))
    @test isnothing(get_target_string("foo│()"))
end

select_enclosing_call(code::AbstractString, pos::Int) = JETLS.select_enclosing_call(jlparse(code), pos)
function get_enclosing_call(code::AbstractString; kwargs...)
    clean_code, positions = JETLS.get_text_and_positions(code; kwargs...)
    @assert length(positions) == 1
    fi = JETLS.FileInfo(1, clean_code, @__FILE__)
    return select_enclosing_call(clean_code, JETLS.xy_to_offset(fi, positions[1]))
end
@testset "`select_enclosing_call`" begin
    # cursor right after `)` resolves via the `offset - 1` retry
    let node = get_enclosing_call("foo(1, 2)│")
        @test node !== nothing
        @test JS.kind(node) === JS.K"call"
        @test JS.sourcetext(node) == "foo(1, 2)"
    end
    # cursor inside the call's argument list
    let node = get_enclosing_call("foo(1, │2)")
        @test node !== nothing
        @test JS.kind(node) === JS.K"call"
        @test JS.sourcetext(node) == "foo(1, 2)"
    end
    # innermost call wins when cursor sits inside both
    let node = get_enclosing_call("outer(inner(│x))")
        @test node !== nothing
        @test JS.kind(node) === JS.K"call"
        @test JS.sourcetext(node) == "inner(x)"
    end
    # right after the inner `)` the more specific (inner) call wins over the
    # outer call that also spans the cursor — symmetric with `func(args)│`
    let node = get_enclosing_call("outer(inner(x)│)")
        @test node !== nothing
        @test JS.kind(node) === JS.K"call"
        @test JS.sourcetext(node) == "inner(x)"
    end
    # method call (dot-call expression)
    let node = get_enclosing_call("obj.method(x)│")
        @test node !== nothing
        @test JS.kind(node) === JS.K"call"
        @test JS.sourcetext(node) == "obj.method(x)"
    end
    # `K"ref"` (indexing) is treated as call-like since it lowers to `getindex`
    let node = get_enclosing_call("xs[2]│")
        @test node !== nothing
        @test JS.kind(node) === JS.K"ref"
        @test JS.sourcetext(node) == "xs[2]"
    end
    # `K"tuple"` is treated as call-like
    let node = get_enclosing_call("(1, 2)│")
        @test node !== nothing
        @test JS.kind(node) === JS.K"tuple"
        @test JS.sourcetext(node) == "(1, 2)"
    end
    # array literals and comprehensions are call-like since they lower to
    # `Base.vect` / `Base.vcat` / `Base.hcat` / `Base.collect`.
    let node = get_enclosing_call("[1, 2, 3]│")
        @test node !== nothing
        @test JS.kind(node) === JS.K"vect"
        @test JS.sourcetext(node) == "[1, 2, 3]"
    end
    let node = get_enclosing_call("[1; 2]│")
        @test node !== nothing
        @test JS.kind(node) === JS.K"vcat"
        @test JS.sourcetext(node) == "[1; 2]"
    end
    let node = get_enclosing_call("[1 2]│")
        @test node !== nothing
        @test JS.kind(node) === JS.K"hcat"
        @test JS.sourcetext(node) == "[1 2]"
    end
    let node = get_enclosing_call("[i for i in 1:3]│")
        @test node !== nothing
        @test JS.kind(node) === JS.K"comprehension"
        @test JS.sourcetext(node) == "[i for i in 1:3]"
    end
    let node = get_enclosing_call("Int[1; 2]│")
        @test node !== nothing
        @test JS.kind(node) === JS.K"typed_vcat"
        @test JS.sourcetext(node) == "Int[1; 2]"
    end
    let node = get_enclosing_call("Int[1 2]│")
        @test node !== nothing
        @test JS.kind(node) === JS.K"typed_hcat"
        @test JS.sourcetext(node) == "Int[1 2]"
    end
    let node = get_enclosing_call("Int[i for i in 1:3]│")
        @test node !== nothing
        @test JS.kind(node) === JS.K"typed_comprehension"
        @test JS.sourcetext(node) == "Int[i for i in 1:3]"
    end
    # cursor not inside any call-like expression
    @test isnothing(get_enclosing_call("x = 42│"))
    @test isnothing(get_enclosing_call("│"))
end

select_target_for_type_query(code::AbstractString, pos::Int) =
    JETLS.select_target_for_type_query(jlparse(code), pos)
function get_target_for_type_query(code::AbstractString; kwargs...)
    clean_code, positions = JETLS.get_text_and_positions(code; kwargs...)
    @assert length(positions) == 1
    fi = JETLS.FileInfo(1, clean_code, @__FILE__)
    return select_target_for_type_query(clean_code, JETLS.xy_to_offset(fi, positions[1]))
end
@testset "`select_target_for_type_query`" begin
    # identifier path mirrors `select_target_identifier`
    let node = get_target_for_type_query("f│oo(x)")
        @test node !== nothing
        @test JS.kind(node) === JS.K"Identifier"
        @test JS.sourcetext(node) == "foo"
    end
    # dot-chain path: walk up through `K"."` like `select_target_identifier`
    let node = get_target_for_type_query("Base.Pa│ir(1, 2)")
        @test node !== nothing
        @test JS.kind(node) === JS.K"."
        @test JS.sourcetext(node) == "Base.Pair"
    end
    # call fallback when there is no identifier at the cursor
    let node = get_target_for_type_query("foo(1, 2)│")
        @test node !== nothing
        @test JS.kind(node) === JS.K"call"
        @test JS.sourcetext(node) == "foo(1, 2)"
    end
    let node = get_target_for_type_query("Base.Pair(1, 2)│")
        @test node !== nothing
        @test JS.kind(node) === JS.K"call"
        @test JS.sourcetext(node) == "Base.Pair(1, 2)"
    end
    # array literal / comprehension forms fall through to
    # `select_enclosing_call` and resolve as `Vector`/`Matrix`/… surfaces.
    let node = get_target_for_type_query("[1, 2, 3]│")
        @test node !== nothing
        @test JS.kind(node) === JS.K"vect"
    end
    let node = get_target_for_type_query("Int[i for i in 1:3]│")
        @test node !== nothing
        @test JS.kind(node) === JS.K"typed_comprehension"
    end
    # neither identifier nor enclosing call
    @test isnothing(get_target_for_type_query("x = 42│"))
    @test isnothing(get_target_for_type_query("│"))
end

get_dotprefix_identifier(code::AbstractString, pos::Int) = JETLS.select_dotprefix_identifier(jlparse(code), pos)
function get_dotprefix_identifier(code::AbstractString; kwargs...)
    clean_code, positions = JETLS.get_text_and_positions(code; kwargs...)
    @assert length(positions) == 1
    return get_dotprefix_identifier(clean_code, JETLS.xy_to_offset(clean_code, positions[1], @__FILE__))
end
@testset "`select_dotprefix_identifier`" begin
    @test isnothing(get_dotprefix_identifier("isnothing│"))
    let node = get_dotprefix_identifier("Base.Sys.│")
        @test !isnothing(node)
        @test JS.sourcetext(node) == "Base.Sys"
    end
    let node = get_dotprefix_identifier("Base.Sys.CPU│")
        @test !isnothing(node)
        @test JS.sourcetext(node) == "Base.Sys"
    end
    let node = get_dotprefix_identifier("Base.Sy│s")
        @test !isnothing(node)
        @test JS.sourcetext(node) == "Base"
    end
    let node = get_dotprefix_identifier("""
        function foo(x)
            Core.│
        end
        """)
        @test !isnothing(node)
        @test JS.sourcetext(node) == "Core"
    end
    let node = get_dotprefix_identifier("""
        function foo(x = Base.│)
        end
        """)
        @test !isnothing(node)
        @test JS.sourcetext(node) == "Base"
    end
end

@testset "`try_extract_field_line`" begin
    let fieldline = JETLS.try_extract_field_line(jsparse("""
            struct A
                xs::Vector{Int}
            end
        """), :A, :xs)
        @test !isnothing(fieldline)
        @test JS.sourcetext(fieldline) == "xs::Vector{Int}"
    end
    let fieldline = JETLS.try_extract_field_line(jsparse("""
            struct A{T}
                xs::Vector{T}
            end
        """), :A, :xs)
        @test !isnothing(fieldline)
        @test JS.sourcetext(fieldline) == "xs::Vector{T}"
    end
    let fieldline = JETLS.try_extract_field_line(jsparse("""
            struct A <: AbstractVector{Int}
                xs::Vector{Int}
            end
        """), :A, :xs)
        @test !isnothing(fieldline)
        @test JS.sourcetext(fieldline) == "xs::Vector{Int}"
    end
    let fieldline = JETLS.try_extract_field_line(jsparse("""
            struct A{T} <: AbstractVector{T}
                xs::Vector{T}
            end
        """), :A, :xs)
        @test !isnothing(fieldline)
        @test JS.sourcetext(fieldline) == "xs::Vector{T}"
    end
    let fieldline = JETLS.try_extract_field_line(jsparse("""
            mutable struct A
                x::Int
            end
        """), :A, :x)
        @test !isnothing(fieldline)
        @test JS.sourcetext(fieldline) == "x::Int"
    end
    let fieldline = JETLS.try_extract_field_line(jsparse("""
            mutable struct A
                const x::Int
            end
        """), :A, :x)
        @test !isnothing(fieldline)
        @test JS.sourcetext(fieldline) == "const x::Int"
    end
    let fieldline = JETLS.try_extract_field_line(jsparse("""
            struct A
                xs
            end
        """), :A, :xs)
        @test !isnothing(fieldline)
        @test JS.sourcetext(fieldline) == "xs"
    end
    let fieldline = JETLS.try_extract_field_line(jsparse("""
            begin
                struct A
                    xs
                end
            end
        """), :A, :xs)
        @test !isnothing(fieldline)
        @test JS.sourcetext(fieldline) == "xs"
    end
end

@testset "iterate_toplevel_tree" begin
    let cnt = Ref(0), func1 = Ref(false), struct1 = Ref(false)
        JETLS.iterate_toplevel_tree(jlparse("""
            module Module1
            func1(x) = x
            struct Struct1 end
            end
            """)) do st0
            cnt[] += 1
            s = JS.sourcetext(st0)
            if s == "func1(x) = x"
                func1[] = true
            elseif s == "struct Struct1 end"
                struct1[] = true
            end
        end
        @test cnt[] == 2
        @test func1[] && struct1[]
    end

    # Doc-wrapped forms should yield the docstring and the documented expression
    # as separate lowerable trees, with interpolated identifiers inside the
    # docstring reachable for downstream analyses (e.g. `analyze_unused_imports!`).
    let cnt = Ref(0), func1 = Ref(false), struct1 = Ref(false),
        outer_doc = Ref{Union{Nothing,JS.SyntaxTree}}(nothing),
        inner_doc = Ref{Union{Nothing,JS.SyntaxTree}}(nothing)
        JETLS.iterate_toplevel_tree(jlparse("""
            \"\"\"
            Docstring for `module Module1`
            \"\"\"
            module Module1
            \"\"\"
            \$(SIGNATURES)
            \"\"\"
            func1(x) = x
            struct Struct1 end
            end
            """)) do st0
            cnt[] += 1
            k = JS.kind(st0)
            if k === JS.K"string"
                inner_doc[] = st0
            elseif k === JS.K"String"
                outer_doc[] = st0
            else
                s = JS.sourcetext(st0)
                if s == "func1(x) = x"
                    func1[] = true
                elseif s == "struct Struct1 end"
                    struct1[] = true
                end
            end
        end
        @test cnt[] == 4
        @test func1[] && struct1[]
        @test outer_doc[] !== nothing
        doc = inner_doc[]
        @test doc !== nothing
        @test any(JS.children(doc)) do c
            JS.kind(c) === JS.K"Identifier" &&
                JS.hasattr(c, :name_val) && c.name_val == "SIGNATURES"
        end
    end
end

# Find the first descendant (or `st` itself) whose kind matches `k`.
function find_first_kind(st::JS.SyntaxTree, k::JS.Kind)
    JS.kind(st) === k && return st
    JS.is_leaf(st) && return nothing
    for c in JS.children(st)
        r = find_first_kind(c, k)
        r === nothing || return r
    end
    return nothing
end

@testset "`trim_error_nodes`" begin
    # The repaired tree must be acceptable to scope-resolution lowering;
    # otherwise the repair didn't achieve its purpose.
    lowers_ok(st) = try
        JETLS.jl_lower_for_scope_resolution(@__MODULE__, st;
            trim_error_nodes=false, recover_from_macro_errors=false)
        return true
    catch
        return false
    end

    # `K"."`: `(. lhs (inert (error)))` collapses to `lhs` so the surrounding
    # tree stays usable for downstream lowering / type queries.
    let st = jlparse("function f(binfo); g(binfo.); end")
        trimmed = JETLS.trim_error_nodes(st)
        @test find_first_kind(trimmed, JS.K"error") === nothing
        @test find_first_kind(trimmed, JS.K".") === nothing
        call = find_first_kind(trimmed, JS.K"call")
        @test call !== nothing
        # `g(binfo)` after repair → `(call g binfo)`.
        @test JS.numchildren(call) == 2
        @test JS.kind(call[2]) === JS.K"Identifier"
        @test call[2].name_val == "binfo"
        @test lowers_ok(trimmed)
    end

    # `K"&&"` / `K"||"`: 1-child residue collapses to the surviving operand.
    let st = jlparse("function f(a); g(a && ); end")
        trimmed = JETLS.trim_error_nodes(st)
        @test find_first_kind(trimmed, JS.K"&&") === nothing
        @test lowers_ok(trimmed)
    end
    let st = jlparse("function f(a); g(a || ); end")
        trimmed = JETLS.trim_error_nodes(st)
        @test find_first_kind(trimmed, JS.K"||") === nothing
        @test lowers_ok(trimmed)
    end

    # `K"::"`: the infix form `value::│` collapses to `value`; the anonymous
    # prefix form `f(::T)` is preserved. Disambiguation uses the parser's
    # infix/prefix flag, which `JS.mknode` carries through the trim.
    let st = jlparse("function f(); g(binfo::); end")
        trimmed = JETLS.trim_error_nodes(st)
        @test find_first_kind(trimmed, JS.K"::") === nothing
        @test lowers_ok(trimmed)
    end
    let st = jlparse("f(::Int) = 1")
        trimmed = JETLS.trim_error_nodes(st)
        ascription = find_first_kind(trimmed, JS.K"::")
        @test ascription !== nothing
        @test JS.is_prefix_op_call(ascription)
        @test JS.numchildren(ascription) == 1
        @test JS.kind(ascription[1]) === JS.K"Identifier"
        @test ascription[1].name_val == "Int"
        @test lowers_ok(trimmed)
    end

    # No-op on well-formed input: every legitimate shape passes through unchanged.
    let st = jlparse("function f(a::Int, b); a.x + (a && b) || a; end")
        @test JETLS.trim_error_nodes(st) === st
    end
end

end # module test_ast
