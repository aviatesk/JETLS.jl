using Test

@testset "MarkdownSource" begin
    @testset "parse" include("test_parse.jl")
    @testset "upstream" include("test_upstream.jl")
end
