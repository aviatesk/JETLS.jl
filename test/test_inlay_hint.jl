module test_inlay_hint

using Test
using JETLS
using JETLS.LSP

include(normpath(pkgdir(JETLS), "test", "setup.jl"))
include(normpath(pkgdir(JETLS), "test", "jsjl_utils.jl"))

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
            inlay_hints = JETLS.syntactic_inlay_hints(fi, range)
            @test length(inlay_hints) == 1
            @test inlay_hints[1].position == Position(; line = 2, character = 3)
            @test inlay_hints[1].label == " #= module TestModule =#"
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
            inlay_hints = JETLS.syntactic_inlay_hints(fi, range)
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
            inlay_hints = JETLS.syntactic_inlay_hints(fi, range)
            @test isempty(inlay_hints)
        end

        @testset "one-liner modules" begin
            let code = """
                module TestModule end
                """
                fi = JETLS.FileInfo(1, code, @__FILE__)
                range = Range(; start = Position(; line = 0, character = 0),
                                var"end" = Position(; line = 1, character = 0))
                inlay_hints = JETLS.syntactic_inlay_hints(fi, range)
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
                inlay_hints = JETLS.syntactic_inlay_hints(fi, range)
                @test length(inlay_hints) == 2
                # The order depends on the tree traversal, so we sort by line number
                sort!(inlay_hints, by = hint -> hint.position.line)
                @test inlay_hints[1].position == Position(; line = 3, character = 3)
                @test inlay_hints[1].label == " #= module Inner =#"
                @test inlay_hints[2].position == Position(; line = 4, character = 3)
                @test inlay_hints[2].label == " #= module Outer =#"
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
                inlay_hints = JETLS.syntactic_inlay_hints(fi, range)
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
                inlay_hints = JETLS.syntactic_inlay_hints(fi, range)
                @test length(inlay_hints) == 1
                @test inlay_hints[1].position == Position(; line = 2, character = 3)
                @test inlay_hints[1].label == " #= module TestModule =#"
            end
        end
    end
end

end # module test_inlay_hint
