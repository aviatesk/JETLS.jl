using Test

struct MyStruct
    value::Int
end

function process(s::MyStruct)
    return s.value * 2
end

@testset "basic tests" begin
    @test 1 + 1 == 2
    @test 2 * 2 == 4
    @test_broken 1 + 1 == 3  # This is expected to fail
end

@testset "struct tests" begin
    s = MyStruct(5)
    @test process(s) == 10
    @test s.value == 5
end

# Standalone test
@test process(MyStruct(3)) == 6

# Nested testsets
# ===============
# TestRunner can handle nested @testset and execute specific @test cases within @testset

@testset "nested tests" begin
    outer_func() = "outer"
    @test outer_func() == "outer"

    @testset "inner tests 1" begin
        inner_func1() = "inner1"
        @test inner_func1() == "inner1"
        @test length(inner_func1()) == 6
    end

    @testset "inner tests 2" begin
        inner_func2() = "inner2"
        @test inner_func2() == "inner2"
        @test startswith(inner_func2(), "inner")
    end
end

# Line number patterns
# ====================
# Run tests by directly specifying line numbers

@testset "calculator tests" begin
    add(a, b) = a + b
    mul(a, b) = a * b

    @test add(2, 3) == 5    # line 55
    @test mul(3, 4) == 12   # line 56
    @test add(10, 20) == 30 # line 57
end

# More standalone tests
@test 100 - 50 == 50  # line 61
@test sqrt(16) == 4   # line 62

# Error cases
# ===========

@testset "Test failure" begin
    @test sin(0) == π
end

@testset "Exception inside of `@test`" begin
    @test sin(Inf) == π
    @test sin(0) == 0
    @test cos(Inf) == π
end

@testset "Exception outside of `@test`" begin
    v = sin(Inf)
    @test v == π
    @test @isdefined v # not executed
end
