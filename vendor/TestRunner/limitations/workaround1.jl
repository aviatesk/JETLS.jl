# Workaround for Source Provenance Limitation
# ===========================================
# This file shows how to structure test code to avoid the issue where
# multiple tests on the same line all execute together.

using Test

# Workaround: Place each @test on a separate line
@testset "workaround1" begin
    workaround1() = nothing
    @test isnothing(workaround1())             # want to run only this
    @test isnothing(identity(workaround1()))   # now this test is skipped
end

# Now you can selectively run individual tests:
# - runtest("workaround1.jl", [:(@test isnothing(workaround1()))]) runs only the first test
# - runtest("workaround1.jl", [:(@test isnothing(identity(workaround1())))]) runs only the second test