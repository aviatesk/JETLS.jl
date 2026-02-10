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

end # module test_inlay_hint
