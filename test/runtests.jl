using Test
using HierarchicalTestSets

@testset HierarchicalTestSet "jetls app" verbose=true begin
    @testset "check" include("test_jetls_check.jl")
    @testset "schema" include("test_jetls_schema.jl")
    @testset "serve" include("test_jetls_serve.jl")
    @testset "test" include("test_jetls_test.jl")
end
