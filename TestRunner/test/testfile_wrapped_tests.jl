using Test

let x = 1
    y = x + 1
    @testset "let testset" begin
        @test y == 2
    end
    @test x == 1
    global let_done = y + 1
end

for i in 1:2
    @testset "for testset" begin
        @test i > 0
    end
    global for_done = i
end

if true
    @testset "if testset" begin
        @test true
    end
    global if_done = true
end

let a = [1, 2, 3]
    @test sum(a) == 6
    push!(a, 4)
    @test sum(a) == 10
    global mutated = copy(a)
end

let result = @testset "result testset" begin
        @test true
    end
    global result_count = result.n_passed
end

check(x) = @test x > 0

@test_throws ErrorException error("unmatched")
@test_nowarn identity("unmatched")

@testset "non-test code" begin
    @test let_done == 3
    @test for_done == 2
    @test if_done
    @test mutated == [1, 2, 3, 4]
    @test check isa Function
end
