using Test

@testset "Test failure" begin
    @test sin(0) == π
end

funccall(f, x) = f(x)
@testset "Exception inside of `@test` 1" begin
    @test sin(0) == 0
    @test sin(Inf) == π
end
@testset "Exception inside of `@test` 2" begin
    @test cos(0) == 1
    @test funccall(cos, Inf) == π
end

@testset "Exception outside of `@test`" begin
    v = sin(Inf)
    @test v == π
    @test @isdefined v # not executed
end

test_func(x) = @test sin(x) == 0
@testset "Exception outside of `@testset`" begin
    test_func(Inf)
end
