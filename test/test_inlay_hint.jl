module test_inlay_hint

using Test
using JETLS
using JETLS.LSP

include(normpath(pkgdir(JETLS), "test", "setup.jl"))
include(normpath(pkgdir(JETLS), "test", "jsjl-utils.jl"))

# Inserts each `hint.label` at its `position` in `code` and returns the
# resulting text, mirroring how an editor renders the hint (honouring
# `paddingLeft` / `paddingRight`). ASCII-only — LSP `Position.character` is
# treated as a byte index into the line. Hints on the same position are
# inserted in their original (traversal) order.
function apply_inlay_hints(code::AbstractString, hints::Vector{InlayHint})
    by_line = Dict{Int,Vector{InlayHint}}()
    for h in hints
        push!(get!(() -> InlayHint[], by_line, h.position.line), h)
    end
    out = IOBuffer()
    lines = split(code, '\n'; keepempty=true)
    for (i, line) in enumerate(lines)
        s = String(line)
        line_hints = sort(get(by_line, i-1, InlayHint[]); by = h -> h.position.character)
        cursor = 0
        for h in line_hints
            c = h.position.character
            print(out, s[cursor+1:c])
            something(h.paddingLeft, false) && print(out, ' ')
            print(out, h.label)
            something(h.paddingRight, false) && print(out, ' ')
            cursor = c
        end
        print(out, s[cursor+1:end])
        i < length(lines) && print(out, '\n')
    end
    return String(take!(out))
end

function get_syntactic_inlay_hints(
        code::AbstractString;
        range::Union{Range,Nothing} = nothing,
        min_lines::Int = 0,
    )
    fi = JETLS.FileInfo(1, code, @__FILE__)
    if range === nothing
        n_lines = count(==('\n'), code)
        range = Range(;
            start = Position(; line = 0, character = 0),
            var"end" = Position(; line = n_lines, character = 0))
    end
    return JETLS.syntactic_inlay_hints(fi, range; min_lines)
end

@testset "block end hints" begin
    @testset "modules" begin
        let code = """
            module TestModule
            x = 1
            end
            """
            expected = """
            module TestModule
            x = 1
            end #= module TestModule =#
            """
            @test apply_inlay_hints(code, get_syntactic_inlay_hints(code)) == expected
        end

        # `end # module TestModule` already names the block, so the hint is
        # suppressed (source round-trips unchanged).
        let code = """
            module TestModule
            x = 1
            y = 2
            end # module TestModule
            """
            @test apply_inlay_hints(code, get_syntactic_inlay_hints(code)) == code
        end

        # `#= module TestModule =#` block-comment form is also recognized.
        let code = """
            module TestModule
            x = 1
            end #= module TestModule =#
            """
            @test apply_inlay_hints(code, get_syntactic_inlay_hints(code)) == code
        end

        @testset "one-liner modules" begin
            let code = """
                module TestModule end
                """
                @test apply_inlay_hints(code, get_syntactic_inlay_hints(code)) == code
            end
        end

        @testset "nested modules" begin
            let code = """
                module Outer
                module Inner
                x = 1
                end
                end
                """
                expected = """
                module Outer
                module Inner
                x = 1
                end #= module Inner =#
                end #= module Outer =#
                """
                @test apply_inlay_hints(code, get_syntactic_inlay_hints(code)) == expected
            end
        end

        # Range that does not include the block's `end` line should suppress
        # the hint entirely.
        @testset "range filtering" begin
            let code = """
                module TestModule
                x = 1
                end
                """
                range = Range(;
                    start = Position(; line = 0, character = 0),
                    var"end" = Position(; line = 1, character = 0))
                @test apply_inlay_hints(code, get_syntactic_inlay_hints(code; range)) == code
            end
        end

        # `end    # some comment` doesn't match the `# module name` shape, so
        # the hint still emits.
        @testset "whitespace before comment" begin
            let code = """
                module TestModule
                x = 1
                end    # some comment
                """
                expected = """
                module TestModule
                x = 1
                end #= module TestModule =#    # some comment
                """
                @test apply_inlay_hints(code, get_syntactic_inlay_hints(code)) == expected
            end
        end

        @testset "baremodule" begin
            let code = """
                baremodule TestModule
                x = 1
                end
                """
                expected = """
                baremodule TestModule
                x = 1
                end #= baremodule TestModule =#
                """
                @test apply_inlay_hints(code, get_syntactic_inlay_hints(code)) == expected
            end
        end
    end

    @testset "functions" begin
        let code = """
            function foo(x, y)
                x + y
            end
            """
            expected = """
            function foo(x, y)
                x + y
            end #= function foo =#
            """
            @test apply_inlay_hints(code, get_syntactic_inlay_hints(code)) == expected
        end

        @testset "short form function" begin
            let code = """
                foo(x) = begin
                    x + 1
                end
                """
                expected = """
                foo(x) = begin
                    x + 1
                end #= foo(...) = =#
                """
                @test apply_inlay_hints(code, get_syntactic_inlay_hints(code)) == expected
            end
        end

        @testset "one-liner function" begin
            let code = """
                function foo(x) x + 1 end
                """
                @test apply_inlay_hints(code, get_syntactic_inlay_hints(code)) == code
            end
        end

        @testset "existing comment" begin
            let code = """
                function foo(x)
                    x + 1
                end # function foo
                """
                @test apply_inlay_hints(code, get_syntactic_inlay_hints(code)) == code
            end
        end
    end

    @testset "macros" begin
        let code = """
            macro mymacro(x)
                esc(x)
            end
            """
            expected = """
            macro mymacro(x)
                esc(x)
            end #= macro @mymacro =#
            """
            @test apply_inlay_hints(code, get_syntactic_inlay_hints(code)) == expected
        end
    end

    @testset "structs" begin
        let code = """
            struct Foo
                x::Int
                y::String
            end
            """
            expected = """
            struct Foo
                x::Int
                y::String
            end #= struct Foo =#
            """
            @test apply_inlay_hints(code, get_syntactic_inlay_hints(code)) == expected
        end

        @testset "mutable struct" begin
            let code = """
                mutable struct Bar
                    x::Int
                end
                """
                expected = """
                mutable struct Bar
                    x::Int
                end #= mutable struct Bar =#
                """
                @test apply_inlay_hints(code, get_syntactic_inlay_hints(code)) == expected
            end
        end
    end

    @testset "control flow" begin
        @testset "if block" begin
            let code = """
                if condition
                    x = 1
                end
                """
                expected = """
                if condition
                    x = 1
                end #= if condition =#
                """
                @test apply_inlay_hints(code, get_syntactic_inlay_hints(code)) == expected
            end

            let code = """
                if x > 0
                    y = 1
                elseif x < 0
                    y = -1
                else
                    y = 0
                end
                """
                expected = """
                if x > 0
                    y = 1
                elseif x < 0
                    y = -1
                else
                    y = 0
                end #= if x > 0 =#
                """
                @test apply_inlay_hints(code, get_syntactic_inlay_hints(code)) == expected
            end
        end

        @testset "@static if block" begin
            let code = """
                @static if Sys.iswindows()
                    const PATH_SEP = '\\\\'
                else
                    const PATH_SEP = '/'
                end
                """
                expected = """
                @static if Sys.iswindows()
                    const PATH_SEP = '\\\\'
                else
                    const PATH_SEP = '/'
                end #= @static if Sys.iswindows() =#
                """
                @test apply_inlay_hints(code, get_syntactic_inlay_hints(code)) == expected
            end
        end

        @testset "let block" begin
            let code = """
                let x = 1,
                    y = 2
                    z = x + y
                end
                """
                expected = """
                let x = 1,
                    y = 2
                    z = x + y
                end #= let x = 1, =#
                """
                @test apply_inlay_hints(code, get_syntactic_inlay_hints(code)) == expected
            end
        end

        @testset "for loop" begin
            let code = """
                for i in 1:10
                    println(i)
                end
                """
                expected = """
                for i in 1:10
                    println(i)
                end #= for i in 1:10 =#
                """
                @test apply_inlay_hints(code, get_syntactic_inlay_hints(code)) == expected
            end
        end

        @testset "while loop" begin
            let code = """
                while x > 0
                    x -= 1
                end
                """
                expected = """
                while x > 0
                    x -= 1
                end #= while x > 0 =#
                """
                @test apply_inlay_hints(code, get_syntactic_inlay_hints(code)) == expected
            end
        end
    end

    @testset "@testset blocks" begin
        let code = """
            @testset "my tests" begin
                @test 1 == 1
            end
            """
            expected = """
            @testset "my tests" begin
                @test 1 == 1
            end #= @testset "my tests" begin =#
            """
            @test apply_inlay_hints(code, get_syntactic_inlay_hints(code)) == expected
        end

        @testset "nested @testset" begin
            let code = """
                @testset "outer" begin
                    @testset "inner" begin
                        @test true
                    end
                end
                """
                expected = """
                @testset "outer" begin
                    @testset "inner" begin
                        @test true
                    end #= @testset "inner" begin =#
                end #= @testset "outer" begin =#
                """
                @test apply_inlay_hints(code, get_syntactic_inlay_hints(code)) == expected
            end
        end
    end
end

end # module test_inlay_hint
