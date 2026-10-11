# Workarounds for Tests Within Function Bodies
# =============================================
# This file shows how to structure test code to work with TestRunner's
# selection when you have tests that would normally be in functions.

using Test

# Workaround 1: Write the testsets directly instead of in a function
@testset "arithmetic" begin
    @testset "addition" begin
        @test 1 + 1 == 2
    end
    @testset "multiplication" begin
        @test 2 * 2 == 4
    end
end

# Workaround 2: If the tests need to be in a function, call it within a
# `@testset` rather than at the top level, so that they can be selected
# together through that `@testset`
function test_strings()
    @testset "concatenation" begin
        @test "hello" * " world" == "hello world"
    end
    @testset "uppercase" begin
        @test uppercase("julia") == "JULIA"
    end
end

@testset "strings" test_strings()

# Now you can run:
# - runtest("workaround3.jl", ["addition"]) to run just the addition tests
# - runtest("workaround3.jl", [:(@test 1 + 1 == 2)]) to run a specific test
# - runtest("workaround3.jl", ["strings"]) to run the tests in `test_strings()`
