using OrderedCollections, Test

@testset "LittleSet" begin

    @testset "Constructors" begin
        @test isa(LittleSet{Int}(keys(LittleDict{Int,Float64}(Vector{Int}(), Vector{Float64}()))), LittleSet{Int})
        @test isa(LittleSet{Int}(keys(LittleDict([(1,2.0)]))), LittleSet{Int})
        @test isa(LittleSet(), LittleSet{Any})
        @test isa(LittleSet([1,2,3]), LittleSet{Int})
        @test isa(LittleSet{Int}([3]), LittleSet{Int})
        data_in = (1, "banana", ())
        s = LittleSet(data_in)
        data_out = collect(s)
        @test isa(data_out, Array{Any,1})
        @test tuple(data_out...) === data_in
        @test tuple(data_in...) === tuple(s...)
        @test length(data_out) == length(data_in)
    end

    @testset "hash" begin
        s1 = LittleSet{String}(["bar", "foo"])
        s2 = LittleSet{String}(["foo", "bar"])
        s3 = LittleSet{String}(["baz"])
        @test hash(s1) != hash(s2)
        @test hash(s1) != hash(s3)
    end

    @testset "isequal" begin
        @test  isequal(LittleSet(), LittleSet())
        @test !isequal(LittleSet(), LittleSet([1]))
        @test  isequal(LittleSet{Any}(Any[1,2]), LittleSet{Int}([1,2]))
        @test !isequal(LittleSet{Any}(Any[1,2]), LittleSet{Int}([1,2,3]))

        @test  isequal(LittleSet{Int}(), LittleSet{AbstractString}())
        @test !isequal(LittleSet{Int}(), LittleSet{AbstractString}([""]))
        @test !isequal(LittleSet{AbstractString}(), LittleSet{Int}([0]))
        @test !isequal(LittleSet{Int}([1]), LittleSet{AbstractString}())
        @test  isequal(LittleSet{Any}([1,2,3]), LittleSet{Int}([1,2,3]))
        @test  isequal(LittleSet{Int}([1,2,3]), LittleSet{Any}([1,2,3]))
        @test !isequal(LittleSet{Any}([1,2,3]), LittleSet{Int}([1,2,3,4]))
        @test !isequal(LittleSet{Int}([1,2,3]), LittleSet{Any}([1,2,3,4]))
        @test !isequal(LittleSet{Any}([1,2,3,4]), LittleSet{Int}([1,2,3]))
        @test !isequal(LittleSet{Int}([1,2,3,4]), LittleSet{Any}([1,2,3]))
    end

    @testset "eltype, empty" begin
        s1 = empty(LittleSet([1,"hello"]))
        @test isequal(s1, LittleSet())
        @test eltype(s1) === Any
        s2 = empty(LittleSet{Float32}([2.0f0,3.0f0,4.0f0]))
        @test isequal(s2, LittleSet())
        @test eltype(s2) === Float32
    end

    @testset "Core Functionality" begin
        s = LittleSet(); push!(s,1); push!(s,2); push!(s,3)
        @test !isempty(s)
        @test in(1,s)
        @test in(2,s)
        @test length(s) == 3
        push!(s,1); push!(s,2); push!(s,3)
        @test length(s) == 3
        @test pop!(s,1) == 1
        @test !in(1,s)
        @test in(2,s)
        @test length(s) == 2
        @test_throws KeyError pop!(s,1)
        @test pop!(s,1,:foo) == :foo
        @test length(delete!(s,2)) == 1
        @test !in(1,s)
        @test !in(2,s)
        @test pop!(s) == 3
        @test length(s) == 0
        @test isempty(s)
    end

    @testset "copy" begin
        data_in = [1,2,9,8,4]
        s = LittleSet(data_in)
        c = copy(s)
        @test isequal(s,c)
        v = pop!(s)
        @test !in(v,s)
        @test  in(v,c)
        push!(s,100)
        push!(c,200)
        @test !in(100,c)
        @test !in(200,s)
    end

    @testset "sizehint!, empty" begin
        s = LittleSet([1])
        @test isequal(sizehint!(s, 10), LittleSet([1]))
        @test isequal(empty!(s), LittleSet())
        # TODO: rehash
    end

    @testset "iterate" begin
        for data_in in ((7,8,4,5),
                        ("hello", 23, 2.7, (), [], (1,8)))
            s = LittleSet(data_in)

            s_new = LittleSet()
            for el in s
                push!(s_new, el)
            end
            @test isequal(s, s_new)

            t = tuple(s...)

            @test t === data_in
            @test length(t) == length(s)
            for (e,f) in zip(t,s)
                @test e === f
            end
        end
    end

    @testset "union" begin
        @test isequal(union(LittleSet([1])),LittleSet([1]))

        s = ∪(LittleSet([1,2]), LittleSet([3,4]))
        @test isequal(s, LittleSet([1,2,3,4]))

        s = ∪(LittleSet((1, 2)), LittleSet((3,4)))
        @test isequal(s, LittleSet((1,2,3,4)))

        s1 = LittleSet{Int, Tuple{Vararg{Int}}}((1, 2))
        s2 = LittleSet{Int, Tuple{Vararg{Int}}}((3,4))
        s = @inferred(∪(s1, s2))
        @test isequal(s, LittleSet((1,2,3,4)))

        s = union(LittleSet([5,6,7,8]), LittleSet([7,8,9]))
        @test isequal(s, LittleSet([5,6,7,8,9]))
        s = LittleSet([1,3,5,7])
        union!(s,(2,3,4,5))
        # TODO: order is not the same, so isequal should return false...
        @test isequal(s, LittleSet([1,2,3,4,5,7]))
    end

    @testset "first" begin
        @test_throws ArgumentError first(LittleSet())
        @test first(LittleSet([2])) == 2

        s = LittleSet([1,2,3])
        @test length(first(s, 2)) == 2
        @test length(first(s, 10)) == 3

        s = LittleSet((1,2,3))
        @test length(first(s, 2)) == 2
        @test length(first(s, 10)) == 3

        s = LittleSet{Int, Tuple{Vararg{Int}}}((1,2,3))
        @test length(@inferred(first(s, 2))) == 2
    end

    @testset "last" begin
        s = LittleSet([1,2,3])
        @test length(last(s, 2)) == 2
        @test length(last(s, 10)) == 3

        s = LittleSet((1,2,3))
        @test length(last(s, 2)) == 2
        @test length(last(s, 10)) == 3

        s = LittleSet{Int, Tuple{Vararg{Int}}}((1,2,3))
        @test length(@inferred(last(s, 2))) == 2
    end

    @testset "intersect" begin
        @test isequal(intersect(LittleSet([1])),LittleSet([1]))
        s = ∩(LittleSet([1,2]), LittleSet([3,4]))
        @test isequal(s, LittleSet())
        s = intersect(LittleSet([5,6,7,8]), LittleSet([7,8,9]))
        @test isequal(s, LittleSet([7,8]))
        @test isequal(intersect(LittleSet([2,3,1]), LittleSet([4,2,3]), LittleSet([5,4,3,2])), LittleSet([2,3]))
    end

    @testset "setdiff" begin
        @test isequal(setdiff(LittleSet([1,2,3]), LittleSet()),        LittleSet([1,2,3]))
        @test isequal(setdiff(LittleSet([1,2,3]), LittleSet([1])),     LittleSet([2,3]))
        @test isequal(setdiff(LittleSet([1,2,3]), Set([1])),            LittleSet([2,3]))
        @test isequal(setdiff(LittleSet([1,2,3]), LittleSet([1,2])),   LittleSet([3]))
        @test isequal(setdiff(LittleSet([1,2,3]), Set([1,2])),          LittleSet([3]))
        @test isequal(setdiff(LittleSet([1,2,3]), LittleSet([1,2,3])), LittleSet())
        @test isequal(setdiff(LittleSet([1,2,3]), LittleSet([4])),     LittleSet([1,2,3]))
        @test isequal(setdiff(LittleSet([1,2,3]), LittleSet([4,1])),   LittleSet([2,3]))
        s = LittleSet([1,3,5,7])
        setdiff!(s,(3,5))
        @test isequal(s,LittleSet([1,7]))
        s = LittleSet([1,2,3,4])
        setdiff!(s, LittleSet([2,4,5,6]))
        @test isequal(s,LittleSet([1,3]))
    end

    @testset "ordering" begin
        @test LittleSet() < LittleSet([1])
        @test LittleSet([1]) < LittleSet([1,2])
        @test !(LittleSet([3]) < LittleSet([1,2]))
        @test !(LittleSet([3]) > LittleSet([1,2]))
        @test LittleSet([1,2,3]) > LittleSet([1,2])
        @test !(LittleSet([3]) <= LittleSet([1,2]))
        @test !(LittleSet([3]) >= LittleSet([1,2]))
        @test LittleSet([1]) <= LittleSet([1,2])
        @test LittleSet([1,2]) <= LittleSet([1,2])
        @test LittleSet([1,2]) >= LittleSet([1,2])
        @test LittleSet([1,2,3]) >= LittleSet([1,2])
        @test !(LittleSet([1,2,3]) >= LittleSet([1,2,4]))
        @test !(LittleSet([1,2,3]) <= LittleSet([1,2,4]))
    end

    @testset "issubset, symdiff" begin
        for (l,r) in ((LittleSet([1,2]),     LittleSet([3,4])),
                    (LittleSet([5,6,7,8]), LittleSet([7,8,9])),
                    (LittleSet([1,2]),     LittleSet([3,4])),
                    (LittleSet([5,6,7,8]), LittleSet([7,8,9])),
                    (LittleSet([1,2,3]),   LittleSet()),
                    (LittleSet([1,2,3]),   LittleSet([1])),
                    (LittleSet([1,2,3]),   LittleSet([1,2])),
                    (LittleSet([1,2,3]),   LittleSet([1,2,3])),
                    (LittleSet([1,2,3]),   LittleSet([4])),
                    (LittleSet([1,2,3]),   LittleSet([4,1])))
            @test issubset(intersect(l,r), l)
            @test issubset(intersect(l,r), r)
            @test issubset(l, union(l,r))
            @test issubset(r, union(l,r))
            @test isequal(union(intersect(l,r),symdiff(l,r)), union(l,r))
        end
        @test ⊆(LittleSet([1]), LittleSet([1,2]))

        @test ⊊(LittleSet([1]), LittleSet([1,2]))
        @test !⊊(LittleSet([1]), LittleSet([1]))
        @test ⊈(LittleSet([1]), LittleSet([2]))

        @test symdiff(LittleSet([1,2,3,4]), LittleSet([2,4,5,6])) == LittleSet([1,3,5,6])

        @test isequal(symdiff(LittleSet([1,2,3,4]), LittleSet([2,4,5,6])), LittleSet([1,3,5,6]))

    end

    @testset "filter" begin
        s = LittleSet([1,2,3,4])
        @test isequal(filter(isodd,s), LittleSet([1,3]))
        filter!(isodd, s)
        @test isequal(s, LittleSet([1,3]))
        s = LittleSet((1,2,3,4))
        @test isa(filter(isodd, s), OrderedCollections.FrozenLittleSet)
    end

    @testset "replace" begin
        s = LittleSet([1,2,3,4])
        @test isequal(replace(s, 1 => 0, 2 => 5), LittleSet([0, 5, 3, 4]))
        s = LittleSet{Int, Tuple{Vararg{Int}}}((1,2,3,4))
        @test isequal(replace(s, 1 => 0, 2 => 5), LittleSet((0, 5, 3, 4)))
    end

    @testset "empty set" begin
        d = LittleSet{Char}()
        @test length(d) == 0
        @test isempty(d)
        @test !('c' in d)
        push!(d, 'c')
        @test !isempty(d)
        empty!(d)
        @test isempty(d)
    end

    @testset "access, modification" begin
        d = LittleSet{Char}()

        for c in 'a':'z'
            push!(d, c)
        end

        for c in 'a':'z'
            @test c in d
        end

        @test collect(d) == collect('a':'z')
    end

    @testset "sort(!)" begin
        x = [-4, 1, -5, 10, 7]
        ox = LittleSet(x)
        @test !issorted(ox)
        sox = sort(ox)
        @test issorted(sox)
        sox = sort(ox; rev=true)
        @test !issorted(sox)
        @test issorted(sox; rev=true)
        ox = LittleSet(x)
        @test ox === sort!(ox)
        @test issorted(ox)
        ox = LittleSet(x)
        @test ox === sort!(ox; rev=true)
        @test !issorted(ox)
        @test issorted(ox; rev=true)
    end

end # @testset LittleSet
