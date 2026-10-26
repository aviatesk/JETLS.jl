using Test
using HierarchicalTestSets

@testset HierarchicalTestSet "MarkdownSource" verbose=true progress=true begin
    @testset "parse" include("test_parse.jl")
    @testset "upstream" include("test_upstream.jl")
end
