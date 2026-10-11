# Conservative Dependency Execution Limitation
# =============================================
# This example demonstrates that due to conservative dependency execution,
# ALL top-level code except `@test`/`@testset` expressions is executed, including
# the `limitation2()` call no matter if it's explicitly selected.

using Test

function limitation2()
    @test String(nameof(Test)) == "Test"
end

limitation2()  # This executes during dependency execution

@testset "selected test" limitation2()  # This also executes when selected

# The problem: The test inside limitation2() executes twice - once from the
# top-level call (during conservative dependency execution) and once from
# the @testset when it's selected.
