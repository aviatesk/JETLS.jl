module test_inlay_hint

using Test
using JETLS
using JETLS.LSP

include(normpath(pkgdir(JETLS), "test", "setup.jl"))
include(normpath(pkgdir(JETLS), "test", "jsjl-utils.jl"))

@testset "syntactic_inlay_hints!" begin
    @testset "module inlay hints" begin
        let code = """
            module TestModule
            x = 1
            end
            """
            fi = JETLS.FileInfo(1, code, @__FILE__)
            range = Range(; start = Position(; line = 0, character = 0),
                            var"end" = Position(; line = 3, character = 0))
            inlay_hints = JETLS.syntactic_inlay_hints(fi, range; min_lines=0)
            @test length(inlay_hints) == 1
            @test inlay_hints[1].position == Position(; line = 2, character = 3)
            @test inlay_hints[1].label == "module TestModule"
        end

        let code = """
            module TestModule
            x = 1
            y = 2
            end # module TestModule
            """
            fi = JETLS.FileInfo(1, code, @__FILE__)
            range = Range(; start = Position(; line = 0, character = 0),
                            var"end" = Position(; line = 4, character = 0))
            inlay_hints = JETLS.syntactic_inlay_hints(fi, range; min_lines=0)
            @test isempty(inlay_hints)
        end

        let code = """
            module TestModule
            x = 1
            end #= module TestModule =#
            """
            fi = JETLS.FileInfo(1, code, @__FILE__)
            range = Range(; start = Position(; line = 0, character = 0),
                            var"end" = Position(; line = 3, character = 0))
            inlay_hints = JETLS.syntactic_inlay_hints(fi, range; min_lines=0)
            @test isempty(inlay_hints)
        end

        @testset "one-liner modules" begin
            let code = """
                module TestModule end
                """
                fi = JETLS.FileInfo(1, code, @__FILE__)
                range = Range(; start = Position(; line = 0, character = 0),
                                var"end" = Position(; line = 1, character = 0))
                inlay_hints = JETLS.syntactic_inlay_hints(fi, range; min_lines=0)
                @test isempty(inlay_hints)
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
                fi = JETLS.FileInfo(1, code, @__FILE__)
                range = Range(; start = Position(; line = 0, character = 0),
                                var"end" = Position(; line = 5, character = 0))
                inlay_hints = JETLS.syntactic_inlay_hints(fi, range; min_lines=0)
                @test length(inlay_hints) == 2
                sort!(inlay_hints; by = hint -> hint.position.line)
                @test inlay_hints[1].position == Position(; line = 3, character = 3)
                @test inlay_hints[1].label == "module Inner"
                @test inlay_hints[2].position == Position(; line = 4, character = 3)
                @test inlay_hints[2].label == "module Outer"
            end
        end

        @testset "range filtering" begin
            let code = """
                module TestModule
                x = 1
                end
                """
                fi = JETLS.FileInfo(1, code, @__FILE__)
                range = Range(; start = Position(; line = 0, character = 0),
                                var"end" = Position(; line = 1, character = 0))
                inlay_hints = JETLS.syntactic_inlay_hints(fi, range; min_lines=0)
                @test isempty(inlay_hints)
            end
        end

        @testset "whitespace before comment" begin
            let code = """
                module TestModule
                x = 1
                end    # some comment
                """
                fi = JETLS.FileInfo(1, code, @__FILE__)
                range = Range(; start = Position(; line = 0, character = 0),
                                var"end" = Position(; line = 3, character = 0))
                inlay_hints = JETLS.syntactic_inlay_hints(fi, range; min_lines=0)
                @test length(inlay_hints) == 1
                @test inlay_hints[1].position == Position(; line = 2, character = 3)
                @test inlay_hints[1].label == "module TestModule"
            end
        end

        @testset "baremodule" begin
            let code = """
                baremodule TestModule
                x = 1
                end
                """
                fi = JETLS.FileInfo(1, code, @__FILE__)
                range = Range(; start = Position(; line = 0, character = 0),
                                var"end" = Position(; line = 3, character = 0))
                inlay_hints = JETLS.syntactic_inlay_hints(fi, range; min_lines=0)
                @test length(inlay_hints) == 1
                @test inlay_hints[1].label == "baremodule TestModule"
            end
        end
    end

    @testset "function inlay hints" begin
        let code = """
            function foo(x, y)
                x + y
            end
            """
            fi = JETLS.FileInfo(1, code, @__FILE__)
            range = Range(; start = Position(; line = 0, character = 0),
                            var"end" = Position(; line = 3, character = 0))
            inlay_hints = JETLS.syntactic_inlay_hints(fi, range; min_lines=0)
            @test length(inlay_hints) == 1
            @test inlay_hints[1].position == Position(; line = 2, character = 3)
            @test inlay_hints[1].label == "function foo"
        end

        @testset "short form function" begin
            let code = """
                foo(x) = begin
                    x + 1
                end
                """
                fi = JETLS.FileInfo(1, code, @__FILE__)
                range = Range(; start = Position(; line = 0, character = 0),
                                var"end" = Position(; line = 3, character = 0))
                inlay_hints = JETLS.syntactic_inlay_hints(fi, range; min_lines=0)
                @test length(inlay_hints) == 1
                @test inlay_hints[1].label == "foo(...) ="
            end
        end

        @testset "one-liner function" begin
            let code = """
                function foo(x) x + 1 end
                """
                fi = JETLS.FileInfo(1, code, @__FILE__)
                range = Range(; start = Position(; line = 0, character = 0),
                                var"end" = Position(; line = 1, character = 0))
                inlay_hints = JETLS.syntactic_inlay_hints(fi, range; min_lines=0)
                @test isempty(inlay_hints)
            end
        end

        @testset "existing comment" begin
            let code = """
                function foo(x)
                    x + 1
                end # function foo
                """
                fi = JETLS.FileInfo(1, code, @__FILE__)
                range = Range(; start = Position(; line = 0, character = 0),
                                var"end" = Position(; line = 3, character = 0))
                inlay_hints = JETLS.syntactic_inlay_hints(fi, range; min_lines=0)
                @test isempty(inlay_hints)
            end
        end
    end

    @testset "macro inlay hints" begin
        let code = """
            macro mymacro(x)
                esc(x)
            end
            """
            fi = JETLS.FileInfo(1, code, @__FILE__)
            range = Range(; start = Position(; line = 0, character = 0),
                            var"end" = Position(; line = 3, character = 0))
            inlay_hints = JETLS.syntactic_inlay_hints(fi, range; min_lines=0)
            @test length(inlay_hints) == 1
            @test inlay_hints[1].label == "macro @mymacro"
        end
    end

    @testset "struct inlay hints" begin
        let code = """
            struct Foo
                x::Int
                y::String
            end
            """
            fi = JETLS.FileInfo(1, code, @__FILE__)
            range = Range(; start = Position(; line = 0, character = 0),
                            var"end" = Position(; line = 4, character = 0))
            inlay_hints = JETLS.syntactic_inlay_hints(fi, range; min_lines=0)
            @test length(inlay_hints) == 1
            @test inlay_hints[1].label == "struct Foo"
        end

        @testset "mutable struct" begin
            let code = """
                mutable struct Bar
                    x::Int
                end
                """
                fi = JETLS.FileInfo(1, code, @__FILE__)
                range = Range(; start = Position(; line = 0, character = 0),
                                var"end" = Position(; line = 3, character = 0))
                inlay_hints = JETLS.syntactic_inlay_hints(fi, range; min_lines=0)
                @test length(inlay_hints) == 1
                @test inlay_hints[1].label == "mutable struct Bar"
            end
        end
    end

    @testset "control flow inlay hints" begin
        @testset "if block" begin
            let code = """
                if condition
                    x = 1
                end
                """
                fi = JETLS.FileInfo(1, code, @__FILE__)
                range = Range(; start = Position(; line = 0, character = 0),
                                var"end" = Position(; line = 3, character = 0))
                inlay_hints = JETLS.syntactic_inlay_hints(fi, range; min_lines=0)
                @test length(inlay_hints) == 1
                @test inlay_hints[1].label == "if condition"
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
                fi = JETLS.FileInfo(1, code, @__FILE__)
                range = Range(; start = Position(; line = 0, character = 0),
                                var"end" = Position(; line = 7, character = 0))
                inlay_hints = JETLS.syntactic_inlay_hints(fi, range; min_lines=0)
                @test length(inlay_hints) == 1
                @test inlay_hints[1].label == "if x > 0"
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
                fi = JETLS.FileInfo(1, code, @__FILE__)
                range = Range(; start = Position(; line = 0, character = 0),
                                var"end" = Position(; line = 5, character = 0))
                inlay_hints = JETLS.syntactic_inlay_hints(fi, range; min_lines=0)
                @test length(inlay_hints) == 1
                @test inlay_hints[1].label == "@static if Sys.iswindows()"
            end
        end

        @testset "let block" begin
            let code = """
                let x = 1,
                    y = 2
                    z = x + y
                end
                """
                fi = JETLS.FileInfo(1, code, @__FILE__)
                range = Range(; start = Position(; line = 0, character = 0),
                                var"end" = Position(; line = 4, character = 0))
                inlay_hints = JETLS.syntactic_inlay_hints(fi, range; min_lines=0)
                @test length(inlay_hints) == 1
                @test inlay_hints[1].label == "let x = 1,"
            end
        end

        @testset "for loop" begin
            let code = """
                for i in 1:10
                    println(i)
                end
                """
                fi = JETLS.FileInfo(1, code, @__FILE__)
                range = Range(; start = Position(; line = 0, character = 0),
                                var"end" = Position(; line = 3, character = 0))
                inlay_hints = JETLS.syntactic_inlay_hints(fi, range; min_lines=0)
                @test length(inlay_hints) == 1
                @test inlay_hints[1].label == "for i in 1:10"
            end
        end

        @testset "while loop" begin
            let code = """
                while x > 0
                    x -= 1
                end
                """
                fi = JETLS.FileInfo(1, code, @__FILE__)
                range = Range(; start = Position(; line = 0, character = 0),
                                var"end" = Position(; line = 3, character = 0))
                inlay_hints = JETLS.syntactic_inlay_hints(fi, range; min_lines=0)
                @test length(inlay_hints) == 1
                @test inlay_hints[1].label == "while x > 0"
            end
        end
    end

    @testset "@testset inlay hints" begin
        let code = """
            @testset "my tests" begin
                @test 1 == 1
            end
            """
            fi = JETLS.FileInfo(1, code, @__FILE__)
            range = Range(; start = Position(; line = 0, character = 0),
                            var"end" = Position(; line = 3, character = 0))
            inlay_hints = JETLS.syntactic_inlay_hints(fi, range; min_lines=0)
            @test length(inlay_hints) == 1
            @test inlay_hints[1].label == "@testset \"my tests\" begin"
        end

        @testset "nested @testset" begin
            let code = """
                @testset "outer" begin
                    @testset "inner" begin
                        @test true
                    end
                end
                """
                fi = JETLS.FileInfo(1, code, @__FILE__)
                range = Range(; start = Position(; line = 0, character = 0),
                                var"end" = Position(; line = 5, character = 0))
                inlay_hints = JETLS.syntactic_inlay_hints(fi, range; min_lines=0)
                @test length(inlay_hints) == 2
                sort!(inlay_hints; by = hint -> hint.position.line)
                @test inlay_hints[1].label == "@testset \"inner\" begin"
                @test inlay_hints[2].label == "@testset \"outer\" begin"
            end
        end
    end
end

function get_type_inlay_hints(code::AbstractString, mod::Module=Main)
    fi = JETLS.FileInfo(1, code, @__FILE__)
    st0_top = JETLS.build_syntax_tree(fi)
    hints = InlayHint[]
    range = Range(;
        start = Position(; line=0, character=0),
        var"end" = Position(; line=10000, character=0))
    JETLS.iterate_toplevel_tree(st0_top) do st0::JS.SyntaxTree
        fb = Int(JS.first_byte(st0))
        JETLS.has_type_inlay_hint_marker(fi.parsed_stream, fb) || return nothing
        result = @something JETLS.get_inferrable_tree(st0, mod) return nothing
        (; ctx3, st3) = result
        inferred_tree = @something JETLS.infer_toplevel_tree(ctx3, st3, mod) return nothing
        JETLS._collect_type_inlay_hints!(
            hints, st0, inferred_tree, fi, range,
            JETLS.LSPostProcessor())
    end
    return hints
end

@testset "type inlay hints" begin
    @testset "simple assignment" begin
        let code = "$(JETLS.TYPE_INLAY_HINT_MARKER)\nlet x = [1, 2, 3]\n    x\nend\n"
            hints = get_type_inlay_hints(code)
            type_labels = [h.label for h in hints]
            @test any(l -> occursin("Vector{Int64}", l), type_labels)
            @test all(h -> h.kind === InlayHintKind.Type, hints)
            @test all(h -> h.paddingLeft === false, hints)
        end
    end

    @testset "function call return type" begin
        let code = "$(JETLS.TYPE_INLAY_HINT_MARKER)\nlet v = [1.0, 2.0]\n    sum(v)\nend\n"
            hints = get_type_inlay_hints(code)
            fi = JETLS.FileInfo(1, code, @__FILE__)
            call_end = JETLS.offset_to_xy(fi, 1 + ncodeunits("$(JETLS.TYPE_INLAY_HINT_MARKER)\nlet v = [1.0, 2.0]\n    sum(v)"))
            @test any(h -> h.position == call_end &&h.label == "::Float64", hints)
        end
    end

    @testset "infix operator call" begin
        let code = "$(JETLS.TYPE_INLAY_HINT_MARKER)\nlet v = [1.0, 2.0]\n    v[1] + v[2]\nend\n"
            hints = get_type_inlay_hints(code)
            fi = JETLS.FileInfo(1, code, @__FILE__)
            prefix = "$(JETLS.TYPE_INLAY_HINT_MARKER)\nlet v = [1.0, 2.0]\n    "
            # `(` before infix expression `v[1] + v[2]`
            expr_start = JETLS.offset_to_xy(fi, ncodeunits(prefix) + 1)
            @test any(h -> h.position == expr_start && h.label == "(" || h.label == "((", hints)
            # `)::Float64` after the expression
            expr_end = JETLS.offset_to_xy(fi, 1 + ncodeunits(prefix * "v[1] + v[2]"))
            @test any(h -> h.position == expr_end && h.label == ")::Float64", hints)
        end
    end

    @testset "no marker" begin
        let code = "let x = [1]\n    x\nend\n"
            hints = get_type_inlay_hints(code)
            @test isempty(hints)
        end
    end

    @testset "global constant filtering" begin
        let code = "$(JETLS.TYPE_INLAY_HINT_MARKER)\nlet x = println\n    x\nend\n"
            hints = get_type_inlay_hints(code)
            type_labels = [h.label for h in hints]
            @test !any(l -> occursin("typeof(println)", l), type_labels)
        end
    end

    @testset "indexing wraps object with parens" begin
        let code = "$(JETLS.TYPE_INLAY_HINT_MARKER)\nlet x = [1,2,3]\n    x[1]\nend\n"
            hints = get_type_inlay_hints(code)
            fi = JETLS.FileInfo(1, code, @__FILE__)
            prefix = "$(JETLS.TYPE_INLAY_HINT_MARKER)\nlet x = [1,2,3]\n    "
            # `(` before `x` in `x[1]`
            x_start = JETLS.offset_to_xy(fi, ncodeunits(prefix) + 1)
            @test any(h -> h.position == x_start && h.label == "(", hints)
            # `::Vector{Int64})` after `x` in `x[1]`
            x_end = JETLS.offset_to_xy(fi, 1 + ncodeunits(prefix * "x"))
            @test any(h -> h.position == x_end && occursin("Vector{Int64})", h.label), hints)
        end
    end

    @testset "infix call paren position" begin
        let code = "$(JETLS.TYPE_INLAY_HINT_MARKER)\nlet v = [1.0]\n    v[1] < 0.0\nend\n"
            hints = get_type_inlay_hints(code)
            fi = JETLS.FileInfo(1, code, @__FILE__)
            prefix = "$(JETLS.TYPE_INLAY_HINT_MARKER)\nlet v = [1.0]\n    "
            # `(` should be placed at `v`, not at `<`
            v_pos = JETLS.offset_to_xy(fi, ncodeunits(prefix) + 1)
            @test any(h -> h.position == v_pos && occursin("(", h.label), hints)
            # `)::Bool` after the expression
            expr_end = JETLS.offset_to_xy(fi, 1 + ncodeunits(prefix * "v[1] < 0.0"))
            @test any(h -> h.position == expr_end && h.label == ")::Bool", hints)
        end
    end

    @testset "op= should not show operator type" begin
        let code = "$(JETLS.TYPE_INLAY_HINT_MARKER)\nlet inside = 0\n    inside += 1\n    inside\nend\n"
            hints = get_type_inlay_hints(code)
            type_labels = [h.label for h in hints]
            @test !any(l -> occursin("typeof(+)", l), type_labels)
        end
    end

    @testset "string macro type hint" begin
        let code = "$(JETLS.TYPE_INLAY_HINT_MARKER)\nlazy\"hello\"\n"
            hints = get_type_inlay_hints(code)
            @test any(h -> occursin("LazyString", h.label), hints)
            @test all(h -> h.kind === InlayHintKind.Type, hints)
        end
    end
end

end # module test_inlay_hint
