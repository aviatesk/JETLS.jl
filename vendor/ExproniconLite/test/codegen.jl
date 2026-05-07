
    using Test
    using ExproniconLite
    #= none:4 =# @testset "x function" begin
            #= none:5 =# @test_expr xtuple(1, :x) == :((1, x))
            #= none:6 =# @test_expr xnamedtuple(; x = 2, y = 3) == :((x = 2, y = 3))
            #= none:7 =# @test_expr xcall(Base, :sin, 1; x = 2) == :(($Base).sin(1; x = 2))
            #= none:8 =# @test_expr xpush(:coll, :x) == :(($Base).push!(coll, x))
            #= none:9 =# @test_expr xfirst(:coll) == :(($Base).first(coll))
            #= none:10 =# @test_expr xlast(:coll) == :(($Base).last(coll))
            #= none:11 =# @test_expr xprint(:coll) == :(($Base).print(coll))
            #= none:12 =# @test_expr xprintln(:coll) == :(($Base).println(coll))
            #= none:13 =# @test_expr xmap(:f, :coll) == :(($Base).map(f, coll))
            #= none:14 =# @test_expr xmapreduce(:f, :op, :coll) == :(($Base).mapreduce(f, op, coll))
            #= none:15 =# @test_expr xiterate(:it) == :(($Base).iterate(it))
            #= none:16 =# @test_expr xiterate(:it, :st) == :(($Base).iterate(it, st))
            #= none:17 =# @test_expr xgetindex(:locs, 1) == :(($Base).getindex(locs, 1))
        end
