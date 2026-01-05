module test_general

using Test
using JETLS

@testset "format_duration" begin
    # Test milliseconds formatting (< 1 second)
    @test JETLS.format_duration(0.0) == "0.0ms"
    @test JETLS.format_duration(0.001) == "1.0ms"
    @test JETLS.format_duration(0.0005) == "0.5ms"
    @test JETLS.format_duration(0.1234) == "123.4ms"
    @test JETLS.format_duration(0.999) == "999.0ms"
    @test JETLS.format_duration(0.9999) == "999.9ms"

    # Test seconds formatting (1 second to < 60 seconds)
    @test JETLS.format_duration(1.0) == "1.0s"
    @test JETLS.format_duration(1.5) == "1.5s"
    @test JETLS.format_duration(10.0) == "10.0s"
    @test JETLS.format_duration(59.99) == "59.99s"
    @test JETLS.format_duration(30.123) == "30.12s"
    @test JETLS.format_duration(45.678) == "45.68s"

    # Test minutes formatting (>= 60 seconds)
    @test JETLS.format_duration(60.0) == "1m 0.0s"
    @test JETLS.format_duration(61.5) == "1m 1.5s"
    @test JETLS.format_duration(90.0) == "1m 30.0s"
    @test JETLS.format_duration(120.0) == "2m 0.0s"
    @test JETLS.format_duration(150.7) == "2m 30.7s"
    @test JETLS.format_duration(3661.2) == "61m 1.2s"

    # Test edge cases and rounding
    @test JETLS.format_duration(0.9995) == "999.5ms"  # Should round to 999.5ms, not 1000.0ms
    @test JETLS.format_duration(59.999) == "60.0s"    # Should round to 60.0s
    @test JETLS.format_duration(119.99) == "1m 60.0s" # 119.99s = 1m 59.99s, rounds to 60.0s
end

@testset "is_abstract_fieldtype" begin
    @test !JETLS.is_abstract_fieldtype(Int)
    @test !JETLS.is_abstract_fieldtype(Vector{Int})
    @test JETLS.is_abstract_fieldtype(AbstractVector{Int})
    @test JETLS.is_abstract_fieldtype(Vector{Integer})
    @test JETLS.is_abstract_fieldtype(Vector{<:Integer})
    @test !JETLS.is_abstract_fieldtype(Vector{TypeVar(:T)}) # For cases like `struct A{T}; xs::Vector{T}; end`
end

maybenothing(x) = rand((x, nothing))
maybemissing(x) = rand((x, missing))

@testset "@somereal" begin
    @test_throws "No values present" JETLS.@somereal
    let cnt = 0
        nonreal(x) = (cnt += x; nothing)
        a = 3
        @test 3 == JETLS.@somereal a nonreal(1) nonreal(2)
        @test cnt == 0
        @test 3 == JETLS.@somereal a nonreal(1) nonreal(2) error("Unable to find default for `a`")
        @test cnt == 0
        @test 3 == JETLS.@somereal nonreal(1) nonreal(2) a
        @test cnt == 3
        @test 3 == JETLS.@somereal nonreal(1) nonreal(2) a error("Unable to find default for `a`")
        @test cnt == 6
    end
    let cnt = 0
        nonreal(x) = (cnt += x; nothing)
        a = missing
        @test_throws "Unable to find default for `a`" JETLS.@somereal a nonreal(1) nonreal(2) error("Unable to find default for `a`")
        @test cnt == 3
        @test_throws "No values present" JETLS.@somereal a nonreal(1) nonreal(2)
        @test cnt == 6
        @test_throws "Unable to find default for `a`" JETLS.@somereal nonreal(1) nonreal(2) a error("Unable to find default for `a`")
        @test cnt == 9
        @test_throws "No values present" JETLS.@somereal nonreal(1) nonreal(2) a
        @test cnt == 12
    end
    let cnt = 0
        nonreal(x) = (cnt += x; nothing)
        a = Int[]
        @test [1,2] == JETLS.@somereal a [1,2] nonreal(1)
        @test cnt == 0
        @test [1,2] == JETLS.@somereal a nonreal(1) [1,2]
        @test cnt == 1
        @test_throws "No values present" JETLS.@somereal a nonreal(1)
        @test cnt == 2
    end

    @test Int == Base.infer_return_type((Int,)) do x
        JETLS.@somereal maybenothing(x)
    end
    @test Int == Base.infer_return_type((Int,Int,)) do x, y
        JETLS.@somereal maybenothing(x) maybenothing(y)
    end
    @test Int == Base.infer_return_type((Int,)) do x
        JETLS.@somereal maybemissing(x)
    end
    @test Int == Base.infer_return_type((Int,Int,)) do x, y
        JETLS.@somereal maybemissing(x) maybemissing(y)
    end
end

end # module test_general
