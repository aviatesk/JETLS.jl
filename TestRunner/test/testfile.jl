using Test

function test_func(x)
    return sin(x)
end

@testset "simple" begin
    @test test_func(0) ≈ 0
    @test test_func(π/2) ≈ 1
    @test_broken test_func(2π) ≈ 0
end

function standalone_test_func(x)
    return sin(x)
end

# standalone test case
@test standalone_test_func(π) ≈ 0

include("_testfile_included.jl")
# `include` would be executed automatically
@test included_test_func(π) ≈ 0

# Test that top-level code is executed unconditionally
const test_array = []
push!(test_array, 42)
global_var = length(test_array)

@testset "dependency execution" begin
    @test global_var == 1
    @test test_array[1] == 42
end

@testset "complex" begin
    localfuncvar = test_func
    localfunc(x) = test_func(x)

    @test localfuncvar(3π/2) ≈ -1
    @test localfunc(3π/2) ≈ -1
    @test_broken test_func(2π) ≈ 0

    @testset "nested1" begin
        nestedfunc1(x) = localfunc(x)
        @test localfuncvar(3π/2) ≈ -1
        @test nestedfunc1(3π/2) ≈ -1
        @test nestedfunc1(2π) ≈ 0 broken=true
    end

    @testset "nested2" begin
        nestedfunc2(x) = localfunc(x)
        @test localfunc(3π/2) ≈ -1
        @test nestedfunc2(3π/2) ≈ -1
    end
end

@testset "nested first" begin
    @testset "nested first1" begin
        @test test_func(0) ≈ 0
    end
    @testset "nested first2" begin
        @test test_func(π/2) ≈ 1
    end
end
