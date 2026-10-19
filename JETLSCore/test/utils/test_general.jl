module test_general

using Test
using JETLSCore

@testset "Base rendering compatibility" begin
    @test JETLSCore.with_base_render_lock(+, 1, 2) == 3
    @test JETLSCore.with_base_render_lock(round, 1.234; digits=2) == 1.23
    @test JETLSCore.with_base_render_lock(JETLSCore.with_base_render_lock, identity, 42) == 42
    @test_throws ErrorException JETLSCore.with_base_render_lock(error, "rendering failed")
    @static if !(isdefined(Base, :get_stacktrace_color) && isdefined(Base, :STACKTRACE_COLORS_LOCK))
        @test !islocked(JETLSCore.BASE_RENDER_LOCK)
        @test JETLSCore.with_base_render_lock(islocked, JETLSCore.BASE_RENDER_LOCK)
    end
    let err = ErrorException("rendering failed"), bt = backtrace()
        @test sprint(JETLSCore.locked_showerror, err) == sprint(showerror, err)
        @test sprint(JETLSCore.locked_showerror, err, bt; context=:color=>false) ==
            sprint(showerror, err, bt; context=:color=>false)
        @test sprint(JETLSCore.locked_display_error, err, bt) ==
            sprint(Base.display_error, err, bt)
        @test sprint(JETLSCore.locked_show_backtrace, bt) == sprint(Base.show_backtrace, bt)
    end
end

@testset "format_duration" begin
    # Test milliseconds formatting (< 1 second)
    @test JETLSCore.format_duration(0.0) == "0.0ms"
    @test JETLSCore.format_duration(0.001) == "1.0ms"
    @test JETLSCore.format_duration(0.0005) == "0.5ms"
    @test JETLSCore.format_duration(0.1234) == "123.4ms"
    @test JETLSCore.format_duration(0.999) == "999.0ms"
    @test JETLSCore.format_duration(0.9999) == "999.9ms"

    # Test seconds formatting (1 second to < 60 seconds)
    @test JETLSCore.format_duration(1.0) == "1.0s"
    @test JETLSCore.format_duration(1.5) == "1.5s"
    @test JETLSCore.format_duration(10.0) == "10.0s"
    @test JETLSCore.format_duration(59.99) == "59.99s"
    @test JETLSCore.format_duration(30.123) == "30.12s"
    @test JETLSCore.format_duration(45.678) == "45.68s"

    # Test minutes formatting (>= 60 seconds)
    @test JETLSCore.format_duration(60.0) == "1m 0.0s"
    @test JETLSCore.format_duration(61.5) == "1m 1.5s"
    @test JETLSCore.format_duration(90.0) == "1m 30.0s"
    @test JETLSCore.format_duration(120.0) == "2m 0.0s"
    @test JETLSCore.format_duration(150.7) == "2m 30.7s"
    @test JETLSCore.format_duration(3661.2) == "61m 1.2s"

    # Test edge cases and rounding
    @test JETLSCore.format_duration(0.9995) == "999.5ms"  # Should round to 999.5ms, not 1000.0ms
    @test JETLSCore.format_duration(59.999) == "60.0s"    # Should round to 60.0s
    @test JETLSCore.format_duration(119.99) == "1m 60.0s" # 119.99s = 1m 59.99s, rounds to 60.0s
end

@testset "type string truncation" begin
    # `maxdepth=3, maxwidth=20` are the production defaults. Verify the two
    # passes cooperate: `maxdepth` clips deep nesting first, `maxwidth` then
    # handles wide-but-shallow types.

    @testset "maxdepth caps nesting" begin
        # `SyntaxTree{Dict{Symbol, Dict{Int64, Any}}}` — depth 3 inner contents.
        let s = "SyntaxTree{Dict{Symbol, Dict{Int64, Any}}}"
            @test JETLSCore.truncate_typstr(s, 3, typemax(Int)) ==
            "SyntaxTree{Dict{Symbol, Dict{…}}}"
            @test JETLSCore.truncate_typstr(s, 2, typemax(Int)) == "SyntaxTree{Dict{…}}"
            @test JETLSCore.truncate_typstr(s, 1, typemax(Int)) == "SyntaxTree{…}"
        end
    end

    @testset "maxwidth caps wide flat types" begin
        let s = "Tuple{Int64, Int64, Int64, Int64, Int64}"  # 40 chars, depth 1
            # Depth cap can't help — there's no nested level to cut. Width pass
            # collapses the outermost `{...}`.
            @test JETLSCore.truncate_typstr(s, typemax(Int), 20) == "Tuple{…}"
        end
        let s = "LongTypeNameForInlayHintTruncation"
            @test JETLSCore.truncate_typstr(s, typemax(Int), 20) == "LongTypeN…Truncation"
        end
    end

    @testset "passes compose" begin
        # Deep + wide: depth pass shrinks first, width pass either accepts
        # the shrunk result or further trims it.
        let s = "SyntaxTree{Dict{Symbol, Dict{Int64, Any}}}"
            @test JETLSCore.truncate_typstr(s, 3, 20) == "SyntaxTree{Dict{…}}"
        end
    end

    @testset "can be no-op" begin
        let s = "Tuple{Float64, Float64, Float64, Float64, Float64, Float64, Float64}"
            @test JETLSCore.truncate_typstr(s, typemax(Int), typemax(Int)) == s
        end
        let s = "Vector{Int64}"
            @test JETLSCore.truncate_typstr(s, 3, 20) == s
        end
    end

    @testset "short strings still respect maxdepth" begin
        @test JETLSCore.truncate_typstr("Vector{Int64}", 1, 20) == "Vector{…}"
        @test JETLSCore.truncate_typstr("A{B{C{D}}}", 3, 20) == "A{B{C{…}}}"
    end
end

@testset "is_abstract_fieldtype" begin
    @test !JETLSCore.is_abstract_fieldtype(Int)
    @test !JETLSCore.is_abstract_fieldtype(Vector{Int})
    @test JETLSCore.is_abstract_fieldtype(AbstractVector{Int})
    @test JETLSCore.is_abstract_fieldtype(Vector{Integer})
    @test JETLSCore.is_abstract_fieldtype(Vector{<:Integer})
    @test !JETLSCore.is_abstract_fieldtype(Vector{TypeVar(:T)}) # For cases like `struct A{T}; xs::Vector{T}; end`
end

func_with_keyword(x; kw = 1) = x + kw
capturing_closure(a) = x -> x + a
noncapturing_closure() = x -> x + 1

@testset "is_closure_type" begin
    @test JETLSCore.is_closure_type(typeof(capturing_closure(1)))
    @test JETLSCore.is_closure_type(typeof(capturing_closure(1)).name.wrapper)
    @test JETLSCore.is_closure_type(typeof(noncapturing_closure()))
    @test !JETLSCore.is_closure_type(typeof(sin))
    @test !JETLSCore.is_closure_type(typeof(func_with_keyword))
    # the keyword body of `func_with_keyword`
    let name = only(name for name in names(@__MODULE__; all = true)
                    if occursin(r"^#func_with_keyword#\d+$", String(name)))
        @test !JETLSCore.is_closure_type(typeof(getglobal(@__MODULE__, name)))
    end
    @test !JETLSCore.is_closure_type(Int)
end

maybenothing(x) = rand((x, nothing))
maybemissing(x) = rand((x, missing))
maybenothing(c::Bool, x) = c ? x : nothing
maybemissing(c::Bool, x) = c ? x : missing

@testset "@somereal" begin
    let cnt = Ref(0)
        nonreal(x) = (cnt[] += x; nothing)
        a = 3
        @test 3 == JETLSCore.@somereal a nonreal(1) nonreal(2)
        @test cnt[] == 0
        @test 3 == JETLSCore.@somereal a nonreal(1) nonreal(2) error("Unable to find default for `a`")
        @test cnt[] == 0
        @test 3 == JETLSCore.@somereal nonreal(1) nonreal(2) a
        @test cnt[] == 3
        @test 3 == JETLSCore.@somereal nonreal(1) nonreal(2) a error("Unable to find default for `a`")
        @test cnt[] == 6
        @test nothing == JETLSCore.@somereal nonreal(1) nonreal(2) Some(nothing)
        @test cnt[] == 9
    end
    let cnt = Ref(0)
        nonreal(x) = (cnt[] += x; nothing)
        a = missing
        @test_throws "Unable to find default for `a`" JETLSCore.@somereal a nonreal(1) nonreal(2) error("Unable to find default for `a`")
        @test cnt[] == 3
        @test_throws "No values present" JETLSCore.@somereal a nonreal(1) nonreal(2)
        @test cnt[] == 6
        @test_throws "Unable to find default for `a`" JETLSCore.@somereal nonreal(1) nonreal(2) a error("Unable to find default for `a`")
        @test cnt[] == 9
        @test_throws "No values present" JETLSCore.@somereal nonreal(1) nonreal(2) a
        @test cnt[] == 12
        @test nothing == JETLSCore.@somereal nonreal(1) nonreal(2) a Some(nothing)
        @test cnt[] == 15
    end
    let cnt = Ref(0)
        nonreal(x) = (cnt[] += x; nothing)
        a = Int[]
        @test [1,2] == JETLSCore.@somereal a [1,2] nonreal(1)
        @test cnt[] == 0
        @test [1,2] == JETLSCore.@somereal a nonreal(1) [1,2]
        @test cnt[] == 1
        @test_throws "No values present" JETLSCore.@somereal a nonreal(1)
        @test cnt[] == 2
        @test [] == JETLSCore.@somereal a nonreal(1) Some([])
        @test cnt[] == 3
    end

    @test Int == Base.infer_return_type((Int,)) do x
        JETLSCore.@somereal maybenothing(x)
    end
    @test Int == Base.infer_return_type((Int,Int,)) do x, y
        JETLSCore.@somereal maybenothing(x) maybenothing(y)
    end
    @test Union{Nothing,Int} == Base.infer_return_type((Int,)) do x
        JETLSCore.@somereal maybenothing(x) Some(nothing)
    end
    @test Base.infer_effects((Bool,Int,)) do c, x
        JETLSCore.@somereal maybenothing(c, x)
    end |> !Base.Compiler.is_nothrow
    @test Base.infer_effects((Bool,Int,)) do c, x
        JETLSCore.@somereal maybenothing(c, x) Some(nothing)
    end |> Base.Compiler.is_nothrow
    @test Int == Base.infer_return_type((Int,)) do x
        JETLSCore.@somereal maybemissing(x)
    end
    @test Int == Base.infer_return_type((Int,Int,)) do x, y
        JETLSCore.@somereal maybemissing(x) maybemissing(y)
    end
    @test Union{Missing,Int} == Base.infer_return_type((Int,)) do x
        JETLSCore.@somereal maybemissing(x) Some(missing)
    end
    @test Base.infer_effects((Bool,Int,)) do c, x
        JETLSCore.@somereal maybemissing(c, x)
    end |> !Base.Compiler.is_nothrow
    @test Base.infer_effects((Bool,Int,)) do c, x
        JETLSCore.@somereal maybemissing(c, x) Some(missing)
    end |> Base.Compiler.is_nothrow

    @test_throws "No values present" JETLSCore.@somereal
end

end # module test_general
