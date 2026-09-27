using Test

# Line 3
@test 1 + 1 == 2

# Line 6
@test 2 * 2 == 4

@testset "math tests" begin
    nothing # FIXME and remove me
    # Line 10
    @test 3 + 3 == 6
    # Line 12
    @test 4 * 4 == 16
end

# Line 16
@test 5 - 3 == 2
