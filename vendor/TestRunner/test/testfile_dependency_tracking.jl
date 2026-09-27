using Test

@testset "dependency tracking 1" begin
    xs1 = []
    push!(xs1, 1)
    @test length(xs1) == 1
end

@testset "dependency tracking 2" begin
    xs2 = []
    push!(xs2, 1)
    @test length(xs2) == 1
    push!(xs2, 2)
    @test length(xs2) == 2
end
