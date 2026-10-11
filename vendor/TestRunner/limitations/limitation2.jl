# Conservative Dependency Execution Limitation
# =============================================
# This example demonstrates that setup code needed only by a specific
# `@testset` is executed even when another `@testset` is selected, since ALL
# code except unselected `@test`/`@testset` expressions is executed.

using Test

function expensive_setup(name)
    println("setting up ", name)
    return collect(1:3)
end

data1 = expensive_setup("data1")  # needed only by "test1"
@testset "test1" begin
    @test sum(data1) == 6
end

data2 = expensive_setup("data2")  # needed only by "test2"
@testset "test2" begin
    @test length(data2) == 3
end

# The problem: When selecting only "test1", the setup for "test2" is executed
# too, since TestRunner can't know that only "test2" needs `data2`.
