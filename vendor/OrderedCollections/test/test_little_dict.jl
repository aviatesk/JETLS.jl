using OrderedCollections, Test
using OrderedCollections: FrozenLittleDict, UnfrozenLittleDict

@testset "LittleDict" begin
    @testset "Type Aliases" begin
        FF1 = LittleDict{Int,Int, NTuple{10, Int}, NTuple{10, Int}}
        @test FF1 <: FrozenLittleDict{<:Any, <:Any}
        @test FF1 <: FrozenLittleDict
        @test FF1 <: FrozenLittleDict{Int, Int}
        @test !(FF1 <: UnfrozenLittleDict{<:Any, <:Any})
        @test !(FF1 <: UnfrozenLittleDict)
        @test !(FF1 <: UnfrozenLittleDict{Int, Int})


        UU1 = LittleDict{Int,Int,Vector{Int},Vector{Int}}
        @test !(UU1 <: FrozenLittleDict{<:Any, <:Any})
        @test !(UU1 <: FrozenLittleDict)
        @test !(UU1 <: FrozenLittleDict{Int, Int})
        @test (UU1 <: UnfrozenLittleDict{<:Any, <:Any})
        @test (UU1 <: UnfrozenLittleDict)
        @test (UU1 <: UnfrozenLittleDict{Int, Int})


        FU1 = LittleDict{Int,Int,NTuple{10, Int},Vector{Int}}
        @test !(FU1 <: FrozenLittleDict{<:Any, <:Any})
        @test !(FU1 <: FrozenLittleDict)
        @test !(FU1 <: FrozenLittleDict{Int, Int})
        @test !(FU1 <: UnfrozenLittleDict{<:Any, <:Any})
        @test !(FU1 <: UnfrozenLittleDict)
        @test !(FU1 <: UnfrozenLittleDict{Int, Int})

        UF1 = LittleDict{Int,Int,Vector{Int},NTuple{10,Int}}
        @test !(UF1 <: FrozenLittleDict{<:Any, <:Any})
        @test !(UF1 <: FrozenLittleDict)
        @test !(UF1 <: FrozenLittleDict{Int, Int})
        @test !(UF1 <: UnfrozenLittleDict{<:Any, <:Any})
        @test !(UF1 <: UnfrozenLittleDict)
        @test !(UF1 <: UnfrozenLittleDict{Int, Int})
    end

    @testset "Constructors" begin
        @test isa(@inferred(LittleDict{Any, Any, <:Tuple, <:Tuple}()), LittleDict{Any, Any, Tuple{}, Tuple{}})
        @test isa(@inferred(LittleDict()), LittleDict{Any,Any})
        @test isa(@inferred(LittleDict([(1,2.0)])), LittleDict{Int,Float64})

        @test isa(@inferred(LittleDict([("a",1),("b",2)])), LittleDict{String,Int})
        @test isa(@inferred(LittleDict(Pair(1, 1.0))), LittleDict{Int,Float64})
        @test isa(@inferred(LittleDict(Pair(1, 1.0), Pair(2, 2.0))),
        LittleDict{Int,Float64})

        @test isa(@inferred(LittleDict{Int,Float64}(2=>2.0, 3=>3.0)),
            LittleDict{Int,Float64})
        @test isa(@inferred(LittleDict{Int,Float64}(Pair(1, 1), Pair(2, 2))), LittleDict{Int,Float64})
        @test isa(@inferred(LittleDict(Pair(1, 1.0), Pair(2, 2.0), Pair(3, 3.0))), LittleDict{Int,Float64})
        @test LittleDict(()) == LittleDict{Any,Any}()

        @test isa(@inferred(LittleDict([Pair(1, 1.0), Pair(2, 2.0)])), LittleDict{Int,Float64})
        @test_throws ArgumentError LittleDict([1,2,3,4])

        iter = Iterators.filter(x->x.first>1, [Pair(1, 1.0), Pair(2, 2.0), Pair(3, 3.0)])
        @test @inferred(LittleDict(iter)) == LittleDict{Int,Float64}(2=>2.0, 3=>3.0)

        iter = Iterators.drop(1:10, 1)
        @test_throws ArgumentError LittleDict(iter)

        k_iter = Iterators.filter(x->x>1, [1,2,3,4])
        v_iter = Iterators.filter(x->x>1, [1.0,2.0,3.0,4.0])
        @test @inferred(LittleDict(k_iter, v_iter)) isa
            LittleDict{Int,Float64, Vector{Int}, Vector{Float64}}

        @test @inferred(LittleDict{Int, Char}(rand(1:100,20), rand('a':'z', 20))) isa
            LittleDict{Int,Char,Vector{Int},Vector{Char}}

        # Different number of keys and values
        @test_throws ArgumentError LittleDict{Int, Char, Vector{Int}, Vector{Char}}([1,2,3], ['a','b'])
    end


    @testset "empty dictionary" begin
        d = LittleDict{Char, Int}()
        @test length(d) == 0
        @test isempty(d)
        @test_throws KeyError d['c'] == 1
        d['c'] = 1
        @test !isempty(d)
        @test_throws KeyError d[0.01]
        @test isempty(empty(d))
        empty!(d)
        @test isempty(d)
        @test delete!(d, "foo") == empty(d)  # Make sure this does't throw an error

        # access, modification
        for c in 'a':'z'
            d[c] = c - 'a' + 1
        end

        @test (d['a'] += 1) == 2
        @test 'a' in keys(d)
        @test haskey(d, 'a')
        @test get(d, 'B', 0) == 0
        @test getkey(d, 'b', nothing) == 'b'
        @test getkey(d, 'B', nothing) == nothing
        @test !('B' in keys(d))
        @test !haskey(d, 'B')
        @test pop!(d, 'a') == 2
        @test pop!(d) == 26  # z was added last

        @test collect(keys(d)) == collect('b':'y')
        @test collect(values(d)) == collect(2:25)
        @test collect(d) == [Pair(a,i) for (a,i) in zip('b':'y', 2:25)]
    end

    @testset "convert" begin
        d = LittleDict{Int,Float32}(i=>Float32(i) for i = 1:10)
        @test convert(LittleDict{Int,Float32}, d) === d
        dc = convert(LittleDict{Int,Float64}, d)
        @test dc !== d
        @test keytype(dc) == Int
        @test valtype(dc) == Float64
        @test keys(dc) == keys(d)
        @test collect(values(dc)) == collect(values(d))

        d = Dict(i=>Float32(i) for i = 1:10)
        @test convert(LittleDict{Int,Float32}, d) isa LittleDict{Int,Float32}
        @test convert(LittleDict{Int,Float32,Vector{Int},Vector{Float32}}, d) isa LittleDict{Int,Float32,Vector{Int},Vector{Float32}}
    end

    @testset "Issue #60" begin
        od60 = LittleDict{Int,Int}()
        od60[1] = 2

        ranges = [2:5, 6:9, 10:13]
        for range in ranges
            for i = range
                od60[i] = i+1
            end
            for i = range
                delete!( od60, i )
            end
        end
        od60[14]=15

        @test od60[14] == 15
    end


    ##############################
    # Copied and modified from Base/test/dict.jl

    # LittleDict

    @testset "LittleDict{Int,Int}" begin
        h = LittleDict{Int,Int}()
        for i=1:100
            h[i] = i+1
        end

        @test collect(h) == [Pair(x,y) for (x,y) in zip(1:100, 2:101)]

        for i=1:2:100
            delete!(h, i)
        end
        for i=1:2:100
            h[i] = i+1
        end

        for i=1:100
            @test h[i]==i+1
        end

        for i=1:100
            delete!(h, i)
        end
        @test isempty(h)

        h[77] = 100
        @test h[77]==100
        @test length(h) == 1

        for i=1:100
            h[i] = i+1
        end
        @test length(h) == 100

        for i=1:2:50
            delete!(h, i)
        end
        @test length(h) == 75

        for i=51:100
            h[i] = i+1
        end
        @test length(h) == 75

        for i=2:2:100
            @test h[i]==i+1
        end
        for i=75:100
            @test h[i]==i+1
        end
    end

    @testset "LittleDict{Any,Any}" begin
        h = LittleDict{Any,Any}([("a", 3)])
        @test h["a"] == 3
        h["a","b"] = 4
        @test h["a","b"] == h[("a","b")] == 4
        h["a","b","c"] = 4
        @test h["a","b","c"] == h[("a","b","c")] == 4
    end

    @testset "KeyError" begin
        z = LittleDict()
        get_KeyError = false
        try
            z["a"]
        catch _e123_
            get_KeyError = isa(_e123_, KeyError)
        end
        @test get_KeyError
    end

    @testset "filter" begin
        _d = LittleDict([("a", 0)])
        v = [k for k in filter(x->length(x)==1, collect(keys(_d)))]
        @test isa(v, Vector{String})
    end

    @testset "from tuple/vector/pairs/tuple of pair 1" begin
        d = LittleDict(((1, 2), (3, 4)))
        d2 = LittleDict([(1, 2), (3, 4)])
        d3 = LittleDict(1 => 2, 3 => 4)
        d4 = LittleDict((1 => 2, 3 => 4))

        @test d[1] === 2
        @test d[3] === 4

        @test d == d2 == d3 == d4
        @test isa(d, LittleDict{Int,Int})
        @test isa(d2, LittleDict{Int,Int})
        @test isa(d3, LittleDict{Int,Int})
        @test isa(d4, LittleDict{Int,Int})
    end

    @testset "from tuple/vector/pairs/tuple of pair 2" begin
        d = LittleDict(((1, 2), (3, "b")))
        d2 = LittleDict([(1, 2), (3, "b")])
        d3 = LittleDict(1 => 2, 3 => "b")
        d4 = LittleDict((1 => 2, 3 => "b"))

        @test d2[1] === 2
        @test d2[3] == "b"

        @test d == d2 == d3 == d4
        @test isa(d, LittleDict{Int,Any})
        @test isa(d2, LittleDict{Int,Any})
        @test isa(d3, LittleDict{Int,Any})
        @test isa(d4, LittleDict{Int,Any})
    end

    @testset "from tuple/vector/pairs/tuple of pair 3" begin
        d = LittleDict(((1, 2), ("a", 4)))
        d2 = LittleDict([(1, 2), ("a", 4)])
        d3 = LittleDict(1 => 2, "a" => 4)
        d4 = LittleDict((1 => 2, "a" => 4))

        @test d2[1] === 2
        @test d2["a"] === 4

        ## TODO: tuple of tuples doesn't work for mixed tuple types
        # @test d == d2 == d3 == d4
        @test d2 == d3 == d4
        # @test isa(d, LittleDict{Any,Int})
        @test isa(d2, LittleDict{Any,Int})
        @test isa(d3, LittleDict{Any,Int})
        @test isa(d4, LittleDict{Any,Int})
    end

    @testset "from tuple/vector/pairs/tuple of pair 4" begin
        d = LittleDict(((1, 2), ("a", "b")))
        d2 = LittleDict([(1, 2), ("a", "b")])
        d3 = LittleDict(1 => 2, "a" => "b")
        d4 = LittleDict((1 => 2, "a" => "b"))

        @test d[1] === 2
        @test d["a"] == "b"

        @test d == d2 == d3 == d4
        @test isa(d, LittleDict{Any,Any})
        @test isa(d2, LittleDict{Any,Any})
        @test isa(d3, LittleDict{Any,Any})
        @test isa(d4, LittleDict{Any,Any})
    end

    @testset "first" begin
        @test_throws ArgumentError first(LittleDict())
        @test first(LittleDict([(:f, 2)])) == Pair(:f,2)
    end


    @testset "iterate" begin
        d = LittleDict("a" => [1, 2])
        val1, state1 = iterate(d)
        @test val1 == ("a" => [1, 2])
        @test iterate(d, state1) === nothing
    end


    @testset "Failing to add a value but being able to add a key (cf: Issue #1821)" begin
        d = LittleDict{String, Vector{Int}}()
        d["a"] = [1, 2]
        @test_throws MethodError d["b"] = 1
        @test isa(repr(d), AbstractString)  # check that printable without error
    end

    @testset "Issue #2344" begin
        bestkey(d, key) = key
        bestkey(d::AbstractDict{K,V}, key) where {K<:AbstractString,V} = string(key)
        bar(x) = bestkey(x, :y)
        @test bar(LittleDict([(:x, [1,2,5])])) == :y
        @test bar(LittleDict([("x", [1,2,5])])) == "y"
    end

    @testset "isequal" begin
        @test  isequal(LittleDict(), LittleDict())
        @test  isequal(LittleDict([(1, 1)]), LittleDict([(1, 1)]))
        @test !isequal(LittleDict([(1, 1)]), LittleDict())
        @test !isequal(LittleDict([(1, 1)]), LittleDict([(1, 2)]))
        @test !isequal(LittleDict([(1, 1)]), LittleDict([(2, 1)]))

        @test isequal(LittleDict(), sizehint!(LittleDict(),96))

        # Here is what currently happens when dictionaries of different types
        # are compared. This is not necessarily desirable. These tests are
        # descriptive rather than proscriptive.
        @test !isequal(LittleDict([(1, 2)]), LittleDict([("dog", "bone")]))
        @test isequal(LittleDict{Int,Int}(), LittleDict{AbstractString,AbstractString}())
    end


    @testset "data_in" begin
        # Generate some data to populate dicts to be compared
        data_in = [ (rand(1:1000), randstring(2)) for _ in 1:1001 ]

        # Populate the first dict
        d1 = LittleDict{Int, String}()
        for (k,v) in data_in
            d1[k] = v
        end
        data_in = collect(d1)
        # shuffle the data
        for i in 1:length(data_in)
            j = rand(1:length(data_in))
            data_in[i], data_in[j] = data_in[j], data_in[i]
        end
        # Inserting data in different (shuffled) order should result in
        # equivalent dict.
        d2 = LittleDict{Int, AbstractString}()
        for (k,v) in data_in
            d2[k] = v
        end

        @test  isequal(d1, d2)
        d3 = copy(d2)
        d4 = copy(d2)
        # Removing an item gives different dict
        delete!(d1, data_in[rand(1:length(data_in))][1])
        @test !isequal(d1, d2)
        # Changing a value gives different dict
        d3[data_in[rand(1:length(data_in))][1]] = randstring(3)
        !isequal(d1, d3)
        # Adding a pair gives different dict
        d4[1001] = randstring(3)
        @test !isequal(d1, d4)
    end

    @testset "get!" begin
        # get! (get with default values assigned to the given location)
        f(x) = x^2
        d = LittleDict(8 => 19)

        @test get!(d, 8, 5) == 19
        @test get!(d, 19, 2) == 2

        @test get!(d, 42) do  # key not found, d is updated with f(2)
            f(2)
        end == 4

        @test get!(d, 42) do  # key found, d is not updated
            f(200)
        end == 4

        @test get(d, 13) do   # key not found, d is not updated
            f(4)
        end == 16

        @test get(d, 42) do   # key found, d is not updated
            error("this code is not reached")
        end == 4

        @test d == LittleDict(8=>19, 19=>2, 42=>4)
    end

    @testset "Issue #5886" begin
        d5886 = LittleDict()
        for k5886 in 1:11
            d5886[k5886] = 1
        end
        for k5886 in keys(d5886)
            # undefined ref if not fixed
            d5886[k5886] += 1
        end
    end

    @testset "isordered (Issue #216)1" begin
        @test OrderedCollections.isordered(LittleDict{Int, String})
        @test !OrderedCollections.isordered(Dict{Int, String})
    end

    @testset "Test merging" begin
        a = LittleDict("foo"  => 0.0, "bar" => 42.0)
        b = LittleDict("フー" => 17, "バー" => 4711)
        result = merge(a, b)
        @test isa(result, LittleDict{String,Float64})

        expected = LittleDict("foo"  => 0.0, "bar" => 42.0, "フー" => 17, "バー" => 4711)
        @test result == expected

        c = LittleDict("a" => 1, "b" => 2, "c" => 3)
        result = merge(a, b, c)
        @test isa(result, LittleDict{String,Float64})

        expected = LittleDict(
            "foo" => 0.0, "bar" => 42.0,
            "フー" => 17, "バー" => 4711,
            "a" => 1, "b" => 2, "c" => 3,
        )
        @test result == expected

        c = LittleDict("a" => 1, "b" => 2, "foo" => 3)
        result = merge(a, b, c)
        @test isa(result, LittleDict{String,Float64})

        expected = LittleDict(
            "foo" => 3, "bar" => 42.0,
            "フー" => 17, "バー" => 4711,
            "a" => 1, "b" => 2,
        )
        @test result == expected
    end

    @testset "Issue #9295" begin
        d = LittleDict()
        @test push!(d, 'a'=> 1) === d
        @test d['a'] == 1
        @test push!(d, 'b' => 2, 'c' => 3) === d
        @test d['b'] == 2
        @test d['c'] == 3
        @test push!(d, 'd' => 4, 'e' => 5, 'f' => 6) === d
        @test d['d'] == 4
        @test d['e'] == 5
        @test d['f'] == 6
        @test length(d) == 6
    end

    @testset "Serialization" begin
        s = IOBuffer()
        od = LittleDict{Char,Int64}()
        for c in 'a':'e'
            od[c] = c-'a'+1
        end
        serialize(s, od)
        seek(s, 0)
        dd = deserialize(s)
        @test isa(dd, OrderedCollections.LittleDict{Char,Int64})
        @test dd == od
        close(s)
    end

    @testset "Issue #148" begin
        d148 = LittleDict(
                    :gps => [],
                    :direction => 1:8,
                    :weather => 1:10
            )

        d148_2 = LittleDict(
            :time => 1:10,
            :features => LittleDict(
                :gps => 1:5,
                :direction => 1:8,
                :weather => 1:10
            )
        )
    end

    @testset "Issue #400" begin
        @test filter(p->first(p) > 1, LittleDict(1=>2, 3=>4)) isa LittleDict
    end

    @testset "Sorting" begin
        ks = [4, 8, 1, 7, 9, 3, 10, 2, 6, 5]
        d = LittleDict(i=>Char(123-i) for i in ks)

        sd = sort(d)
        @test collect(keys(d)) == ks    # verify d is not changed by sort()
        @test collect(keys(sd)) == 1:10
        @test collect(values(sd)) == collect('z':-1:'q')
        @test sort(sd) == sd

        sdv = sort(d; byvalue=true)
        @test collect(keys(d)) == ks    # verify d is not changed by sort()
        @test collect(keys(sdv)) == 10:-1:1
        @test collect(values(sdv)) == collect('q':'z')

        sort!(d)
        @test collect(keys(d)) == 1:10
        @test collect(values(d)) == collect('z':-1:'q')
        @test sort(d) == d == sd

        sort!(d; byvalue=true)
        @test collect(keys(d)) == 10:-1:1
        @test collect(values(d)) == collect('q':'z')
        @test sort(d) == d == sd
    end

    @testset "Test that LittleDict merge with combiner returns type LittleDict" begin
        @test merge(+, LittleDict(:a=>1, :b=>2), LittleDict(:b=>7, :c=>4)) == LittleDict(:a=>1, :b=>9, :c=>4)
        @test merge(+, LittleDict(:a=>1, :b=>2), Dict(:b=>7, :c=>4)) isa LittleDict
    end

    @testset "Test that LittleDict mergewith returns type LittleDict" begin
        @test mergewith(+, LittleDict(:a=>1, :b=>2), LittleDict(:b=>7, :c=>4)) == LittleDict(:a=>1, :b=>9, :c=>4)
        @test mergewith(+, LittleDict(:a=>1, :b=>2), Dict(:b=>7, :c=>4)) isa LittleDict
    end

    @testset "issue #27" begin
        d = LittleDict{Symbol, Int}(:x=>1)
        d1 = LittleDict(:x=>1)
        d_wide = LittleDict{Symbol, Number}(:x=>1)
        @test d == d1 == d_wide
        @test d isa LittleDict{Symbol, Int}
        @test d1 isa LittleDict{Symbol, Int}
        @test d_wide isa LittleDict{Symbol, Number}

        @test_throws MethodError LittleDict{Char,Char}(:x => 1)
    end
end # @testset LittleDict


@testset "Frozen LittleDict" begin

    @testset "types" begin
        base_dict = LittleDict((10,20,30),("a", "b", "c"))
        @test base_dict isa LittleDict{Int, String, <:Tuple, <:Tuple}

        nonfrozen = LittleDict(10=>"a", 20=>"b", 30=>"c")
        @test nonfrozen isa LittleDict{Int, String, <:Vector, <:Vector}

        @test base_dict == nonfrozen

        frozen = freeze(nonfrozen)
        @test frozen isa LittleDict{Int, String, <:Tuple, <:Tuple}
        @test frozen == base_dict
        @test frozen === base_dict
    end

    @testset "get" begin
        fd = LittleDict((10,20,30),("a", "b", "c"))
        @test fd[10] == "a"
        @test fd[20] == "b"
        @test fd[30] == "c"
        @test_throws KeyError fd[-1]
    end

    @testset "set" begin
        fd = LittleDict((10,20,30),("a", "b", "c"))
        @test_throws MethodError fd[10] = "ab"
        @test_throws MethodError fd[20] = "bb"
        @test_throws MethodError fd[30] = "cc"
        @test_throws MethodError fd[-1] = "dd"
    end

    @testset "map!(f, values(LittleDict))" begin
        testdict = LittleDict(:a=>1, :b=>2)
        map!(v->v-1, values(testdict))
        @test testdict[:a] == 0
        @test testdict[:b] == 1
    end

    @testset "lazy reverse iteration" begin
        ks = collect('a':'z')
        vs = collect(0:25)
        ld = LittleDict(ks, vs)
        pass = true
        for (n,(k,v)) in enumerate(Iterators.reverse(ld))
            pass &= reverse(ks)[n] == k
            pass &= reverse(vs)[n] == v
        end
        @test pass
    end

end
