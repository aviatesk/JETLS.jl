using Test

@testset "JETLS" begin
    @testset "basic" include("basic.jl")
    @testset "utils" include("utils.jl")
    @testset "completions" include("completions.jl")
end
