
    using Test
    using ExproniconLite
    jl = #= none:4 =# @expr(JLFunction, #= none:4 =# Base.@generated(foo() = begin
                        1
                    end))
    #= none:5 =# @test jl.generated === true
    #= none:6 =# @test_expr codegen_ast(jl) == :(#= none:6 =# Base.@generated(foo() = begin
                          1
                      end))
