# Workaround for Conservative Dependency Execution
# ================================================
# This file shows how to structure test code so that setup code needed only
# by a specific `@testset` isn't executed when another `@testset` is selected.

using Test

function expensive_setup(name)
    println("setting up ", name)
    return collect(1:3)
end

# Workaround: Move the setup code into the `@testset` that needs it
@testset "test1" begin
    data1 = expensive_setup("data1")
    @test sum(data1) == 6
end

@testset "test2" begin
    data2 = expensive_setup("data2")  # skipped when only "test1" is selected
    @test length(data2) == 3
end

# Now the setup code is executed only when its `@testset` is selected:
# - runtest("workaround2.jl", ["test1"]) sets up only `data1`
# - runtest("workaround2.jl", ["test2"]) sets up only `data2`
