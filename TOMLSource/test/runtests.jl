using Test
using HierarchicalTestSets

@testset HierarchicalTestSet "TOMLSource" begin
    @testset "parse" include("test_parse.jl")
    @testset "editing" include("test_editing.jl")
    @testset "upstream" include("test_upstream.jl")
end
