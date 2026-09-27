using Test

# This file contains a syntax error
@testset "syntax error test" begin
    @test 1 + 1 == 2
    @test 2 * 2 == 4  # Missing closing bracket on next line
    @test [3 * 3 == 9  # Unclosed bracket - syntax error
end