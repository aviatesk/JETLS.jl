using Test

include("_testfile_include_selection1.jl")

@testset "after bare include" begin
    @test value1() == 1
end

@testset "include in testset" include("_testfile_include_selection2.jl")

@testset "outer" begin
    include("_testfile_include_selection2.jl")
    @testset "sibling" begin
        include("_testfile_include_selection1.jl")
    end
    @testset "inner" begin
        @test value2() == 2
    end
end

@testset "dependency" begin
    value = include("_testfile_include_selection2.jl")
    @testset "uses value" begin
        @test value == 2
    end
end
