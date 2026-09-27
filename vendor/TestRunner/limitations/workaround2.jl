# Workaround for Conservative Dependency Execution
# ================================================
# This file shows how to structure test code to avoid unintended test
# execution from top-level function calls.

using Test

function limitation2()
    @test String(nameof(Test)) == "Test"
end

# Workaround: Don't call test functions at the top level
# Instead, only call them inside @testset blocks

@testset "workaround2" begin
    limitation2()  # Function is only called when this testset is selected
end

# Alternative workaround: Define test logic directly in @testset
@testset "alternative workaround" begin
    @test String(nameof(Test)) == "Test"
end

# Now tests only run when explicitly selected:
# - runtest("workaround2.jl", ["workaround2"]) runs the test once
# - runtest("workaround2.jl", ["alternative workaround"]) runs only that test