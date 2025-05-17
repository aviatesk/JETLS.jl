using Test

# test the basic server setup and lifecycle before running the tests
include("setup.jl")
@testset "basic lifecycle" begin
    @test withserver(Returns(true))
end

@testset "JETLS" begin
    @testset "utils" include("utils.jl")
    @testset "completions" include("completions.jl")
    @testset "full lifecycle" include("test_full_lifecycle.jl")
end
