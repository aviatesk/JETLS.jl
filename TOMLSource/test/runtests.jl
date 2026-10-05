using Test

@testset "TOMLSource" begin
    @testset "parse" include("test_parse.jl")
    @testset "editing" include("test_editing.jl")
    @testset "upstream" include("test_upstream.jl")
end
