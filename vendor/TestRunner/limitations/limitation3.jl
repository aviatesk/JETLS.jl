# Tests Within Function Bodies Limitation
# ========================================
# This example demonstrates that `@test` and `@testset` within function bodies
# cannot be selected: the tests in a function are all executed when the
# function call is executed, and none of them are executed otherwise.

using Test

function test_arithmetic()
    @testset "addition" begin
        @test 1 + 1 == 2
    end
    @testset "multiplication" begin
        @test 2 * 2 == 4
    end
end

@testset "arithmetic" test_arithmetic()

# The problem: Selecting "addition" or `:(@test 1 + 1 == 2)` executes no tests,
# since the call of `test_arithmetic()` is executed only when "arithmetic" is
# selected, which in turn executes both "addition" and "multiplication".
