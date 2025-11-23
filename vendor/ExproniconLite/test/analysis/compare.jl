
    using Test
    using ExproniconLite: compare_expr
    lhs = :(function (x,; y)
          end)
    rhs = Expr(:function, Expr(:tuple, Expr(:parameters, :y), :x))
    #= none:6 =# @test compare_expr(lhs, rhs)
    lhs = :(function (x,; y)
          end)
    rhs = Expr(:function, Expr(:tuple, Expr(:parameters, :y), :x), nothing)
    #= none:10 =# @test compare_expr(lhs, rhs)
