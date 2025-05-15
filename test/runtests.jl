using Test

# test the basic server setup and lifecycle before running the tests
include("withserver.j")
@testset "basic" withserver(Returns(nothing))

@testset "JETLS" begin
    @testset "utils" include("utils.jl")
    @testset "completions" include("completions.jl")
    @testset "completions2" include("completions2.jl")
end
