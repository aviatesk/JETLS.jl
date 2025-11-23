
    using ExproniconLite
    using Documenter
    using Test
    using Aqua
    Aqua.test_all(ExproniconLite)
    #= none:7 =# @test_expr quote
                x + 1
                $nothing
            end == quote
                x + 1
                $nothing
            end
    #= none:15 =# @testset "@test_expr" begin
            #= none:16 =# @test_expr quote
                        x + 1
                        $nothing
                    end == quote
                        x + 1
                        $nothing
                    end
        end
    #= none:25 =# @testset "printings" begin
            include("print/inline.jl")
            include("print/multi.jl")
            include("print/old.jl")
            #= none:30 =# @static if VERSION > v"1.8-"
                    include("print/lts.jl")
                end
        end
    #= none:35 =# @testset "types" begin
            include("types.jl")
        end
    #= none:39 =# @testset "analysis" begin
            include("analysis.jl")
        end
    #= none:43 =# @testset "transform" begin
            include("transform.jl")
        end
    #= none:47 =# @testset "match" begin
            nothing
        end
    #= none:51 =# @testset "codegen" begin
            include("codegen.jl")
        end
    #= none:55 =# @testset "adt" begin
            nothing
        end
    DocMeta.setdocmeta!(ExproniconLite, :DocTestSetup, :(using ExproniconLite); recursive = true)
    doctest(ExproniconLite)
