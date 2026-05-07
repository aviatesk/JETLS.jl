
    using Test
    using ExproniconLite
    #= none:4 =# @test is_tuple(:((a, b, c)))
    #= none:5 =# @test is_splat(:(f(x)...))
