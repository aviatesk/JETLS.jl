module test_FixedSizeFIFOQueue

using Test
using JETLS: FixedSizeFIFOQueue, capacity, isfull

struct TestType
    x::Int
end

mutable struct MutableTestType
    x::Int
    data::Vector{Int}
end

@testset "FixedSizeFIFOQueue basic operations" begin
    let q = FixedSizeFIFOQueue{Int}(3)
        @test isempty(q)
        @test !isfull(q)
        @test length(q) == 0
        @test capacity(q) == 3

        push!(q, 1)
        @test !isempty(q)
        @test length(q) == 1
        @test 1 in q
        @test !(2 in q)

        push!(q, 2)
        push!(q, 3)
        @test isfull(q)
        @test length(q) == 3
        @test 1 in q && 2 in q && 3 in q
    end

    let q = FixedSizeFIFOQueue{Int}(3)
        push!(q, 1)
        push!(q, 2)
        push!(q, 3)
        push!(q, 4)  # Should overwrite 1
        @test isfull(q)
        @test length(q) == 3
        @test !(1 in q)
        @test 2 in q && 3 in q && 4 in q

        push!(q, 5)  # Should overwrite 2
        @test !(2 in q)
        @test 3 in q && 4 in q && 5 in q
    end
end

@testset "FixedSizeFIFOQueue type flexibility" begin
    let q = FixedSizeFIFOQueue(2)
        push!(q, "hello")
        push!(q, 42)
        @test "hello" in q
        @test 42 in q

        push!(q, :symbol)
        @test !("hello" in q)
        @test 42 in q
        @test :symbol in q
    end

    let q = FixedSizeFIFOQueue{TestType}(2)
        t1 = TestType(1)
        t2 = TestType(2)
        t3 = TestType(3)

        push!(q, t1)
        push!(q, t2)
        @test t1 in q
        @test t2 in q

        push!(q, t3)
        @test !(t1 in q)
        @test t2 in q
        @test t3 in q
    end
end

@testset "FixedSizeFIFOQueue edge cases" begin
    let q = FixedSizeFIFOQueue{String}(1)
        push!(q, "a")
        @test "a" in q
        push!(q, "b")
        @test !("a" in q)
        @test "b" in q
    end

    @test_throws ArgumentError FixedSizeFIFOQueue{Int}(0)
    @test_throws ArgumentError FixedSizeFIFOQueue{Int}(-1)
end

@testset "FixedSizeFIFOQueue collect and display" begin
    let q = FixedSizeFIFOQueue{Int}(3)
        push!(q, 1)
        push!(q, 2)
        push!(q, 3)

        items = collect(q)
        @test items == [1, 2, 3]

        push!(q, 4)  # Overwrites 1
        items = collect(q)
        @test items == [2, 3, 4]

        str = string(q)
        @test occursin("FixedSizeFIFOQueue{Int", str)
        @test occursin("capacity=3", str)
        @test occursin("[2, 3, 4]", str)
    end
end

@testset "FixedSizeFIFOQueue large capacity" begin
    let q = FixedSizeFIFOQueue{Union{Int,String}}(1000)
        for i in 1:500
            push!(q, i)
        end
        for i in 501:1000
            push!(q, "id-$i")
        end

        @test isfull(q)
        @test 1 in q
        @test 500 in q
        @test "id-501" in q
        @test "id-1000" in q

        push!(q, "extra-1")
        @test !(1 in q)  # First element should be evicted
        @test 2 in q      # Second element should still be there
        @test "extra-1" in q

        for i in 1:100
            push!(q, "new-$i")
        end

        @test !(2 in q)
        @test !(100 in q)
        @test "new-100" in q
    end
end

@testset "FixedSizeFIFOQueue garbage collection" begin
    let q = FixedSizeFIFOQueue{MutableTestType}(2)
        obj1 = MutableTestType(1, [1,2,3])
        obj2 = MutableTestType(2, [4,5,6])
        obj3 = MutableTestType(3, [7,8,9])

        push!(q, obj1)
        push!(q, obj2)
        push!(q, obj3)

        @test obj2 in q
        @test obj3 in q
        @test !(obj1 in q.data)
        @test !(obj1 in q.items)
    end
end

end # module test_FixedSizeFIFOQueue
