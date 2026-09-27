# Tests Within Function Bodies Limitation
# ========================================
# This example demonstrates that individual `@test` cases within function
# bodies cannot be selectively executed using expression patterns.

using Test

# Limitation: Tests inside functions cannot be pattern-matched
function test_arithmetic()
    @test 1 + 1 == 2   # line 10: Can't match this with :(@test 1 + 1 == 2)
    @test 2 * 2 == 4   # line 11: Can't match this with :(@test 2 * 2 == 4)
end

function test_strings()
    @test "hello" * " world" == "hello world"  # line 15
    @test uppercase("julia") == "JULIA"        # line 16
end

# Trying to run with pattern :(@test 1 + 1 == 2) won't execute anything
# because the pattern matching doesn't look inside function bodies

# The problem: If we want to run only `@test 1 + 1 == 2`, it won't work
# because that test is inside a function definition, not at the top level
# or inside a @testset block.
