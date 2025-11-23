
    using Test
    using ExproniconLite
    #= none:4 =# @test_throws ArgumentError jlfn = JLFunction(; name = :aaa, args = [:a, JLKwField(name = :b, default = 1)])
    #= none:9 =# @test_throws ArgumentError jlfn = JLFunction(; name = ":aaa", args = [:a, JLKwField(name = :b, default = 1)])
    #= none:14 =# @test_throws ArgumentError jlfn = JLFunction(; head = :aaa, name = ":aaa", args = [:a, JLKwField(name = :b, default = 1)])
    #= none:20 =# @test_throws ArgumentError jlfn = JLFunction(; head = :aaa, name = ":aaa", args = [:a], kwargs = [JLKwField(name = :b, default = 1)])
    #= none:27 =# @test_throws ArgumentError jlfn = JLFunction(; head = :aaa, name = ":aaa", args = [:a], whereparams = [JLKwField(name = :b, default = 1)])
