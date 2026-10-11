# Source Provenance Limitation
# ============================
# This example demonstrates that multiple tests on the same line don't have
# distinct source location information in lowered code, causing all tests
# on the line to execute when trying to select just one.

using Test

@testset "limitation1" begin
    limitation1() = nothing
    @test isnothing(limitation1()) #=want to run only this=#; @test isnothing(identity(limitation1())) #=but this runs too=#
end

# The problem: When trying to match just the first @test, both tests execute
# because they share the same line number in the lowered code representation.
