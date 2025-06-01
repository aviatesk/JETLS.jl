using Test

# test the basic server setup and lifecycle before running the tests
include("setup.jl")
@testset "basic lifecycle" begin
    @test withserver(Returns(true))
end

@testset "JETLS" begin
    @testset "utils" include("test_utils.jl")
    @testset "registration" include("test_registration.jl")
    @testset "completions" include("test_completions.jl")
    @testset "analysis" include("test_analysis.jl")
    @testset "diagnostics" include("test_diagnostics.jl")
    @testset "full lifecycle" include("test_full_lifecycle.jl")
end
