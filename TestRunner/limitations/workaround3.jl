# Workarounds for Tests Within Function Bodies
# =============================================
# This file shows how to structure test code to work with TestRunner's
# pattern matching when you have tests that would normally be in functions.

using Test

# Workaround 1: Move tests directly into @testset blocks
@testset "arithmetic tests" begin
    @test 1 + 1 == 2   # This CAN be matched with :(@test 1 + 1 == 2)
    @test 2 * 2 == 4   # This CAN be matched with :(@test 2 * 2 == 4)
end

@testset "string tests" begin
    @test "hello" * " world" == "hello world"
    @test uppercase("julia") == "JULIA"
end

# Workaround 2: If you need helper functions, call them inside @testset blocks
function test_arithmetic()
    @test 1 + 1 == 2
    @test 2 * 2 == 4
end

function test_strings()
    @test "hello" * " world" == "hello world"
    @test uppercase("julia") == "JULIA"
end

@testset "function calls" begin
    test_arithmetic()  # Now these tests execute when this testset is selected
    test_strings()
end

# Now you can run:
# - runtest("workaround3.jl", ["arithmetic tests"]) to run just arithmetic tests
# - runtest("workaround3.jl", [:(@test 1 + 1 == 2)]) to run specific tests
# - runtest("workaround3.jl", ["function calls"]) to run tests via functions