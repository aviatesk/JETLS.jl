module test_Analyzer

using Test
include("interactive-utils.jl")
using JETLS.JET: get_reports
using JETLS.Analyzer

baremodule ExternalModule end

baremodule TestTargetModule
    function func()
        undefvar
    end
end

# test basic analysis abilities of `LSAnalyzer`
function report_global_undef()
    return sin(undefvar)
end
@noinline callfunc(f) = f()

struct Issue392
    property::Int
end
function issue392()
    x = Issue392(42)
    println(x.propert)
    return x
end

@testset "LSAnalyzer" begin
    # global undef variables
    let result = analyze_call() do
            sin(undefvar)
        end
        reports = get_reports(result)
        @test length(reports) == 1
        r = only(reports)
        @test r isa UndefVarErrorReport && r.var == GlobalRef(@__MODULE__, :undefvar)
    end
    let result = @analyze_call report_global_undef()
        reports = get_reports(result)
        @test length(reports) == 1
        r = only(reports)
        @test r isa UndefVarErrorReport && r.var == GlobalRef(@__MODULE__, :undefvar)
    end

    # getglobal(::Module, ::Symbol)
    let result = analyze_call() do
            TestTargetModule.unexisting
        end
        reports = get_reports(result)
        @test length(reports) == 1
        r = only(reports)
        @test r isa UndefVarErrorReport && r.var == GlobalRef(TestTargetModule, :unexisting)
    end

    # local undef variables
    let result = analyze_call() do
            local x
            sin(x)
        end
        reports = get_reports(result)
        @test length(reports) == 1
        r = only(reports)
        @test r isa UndefVarErrorReport && r.var === :x && !r.maybeundef
    end
    let result = analyze_call((Bool,Float64)) do c, x
            if c
                y = x
            end
            return sin(y)
        end
        reports = get_reports(result)
        @test length(reports) == 1
        r = only(reports)
        @test r isa UndefVarErrorReport && r.var === :y && r.maybeundef
    end
    let result = analyze_call((Any,)) do x
            local y = x
            callfunc() do
                identity(y)
            end
        end
        @test isempty(get_reports(result))
    end
end

@testset "FieldError analysis" begin
    let result = analyze_call((Some{Int},)) do some
            some.value
        end
        @test isempty(get_reports(result))
    end
    let result = analyze_call((Some{Int},)) do some
            some.val
        end
        reports = get_reports(result)
        @test length(reports) == 1
        r = only(reports)
        @test r isa FieldErrorReport && r.type === Some{Int} && r.field === :val
    end
    let result = analyze_call((Some,)) do some
            some.val
        end
        reports = get_reports(result)
        @test length(reports) == 1
        r = only(reports)
        @test r isa FieldErrorReport && r.field === :val
    end

    let result = analyze_call(issue392)
        reports = get_reports(result)
        @test length(reports) == 1
        r = only(reports)
        @test r isa FieldErrorReport && r.field === :propert
    end

    let result = analyze_call((Some,)) do some
            fieldtype(some, :val)
        end
        reports = get_reports(result)
        @test length(reports) == 1
        r = only(reports)
        @test r isa FieldErrorReport && r.field === :val
    end
end

@testset "BoundsError analysis" begin
    # `getindex(::Tuple, ::Int)`
    let result = analyze_call((Tuple{Int},)) do tpl1
            tpl1[1]
        end
        @test isempty(get_reports(result))
    end
    let result = analyze_call((Tuple{Int},)) do tpl1
            tpl1[0]
        end
        reports = get_reports(result)
        @test length(reports) == 1
        r = only(reports)
        @test r isa BoundsErrorReport && r.a === Tuple{Int} && r.i === 0
    end
    let result = analyze_call((Tuple{Any},)) do tpl1
            tpl1[2]
        end
        reports = get_reports(result)
        @test length(reports) == 1
        r = only(reports)
        @test r isa BoundsErrorReport && r.a === Tuple{Any} && r.i === 2
    end

    # `getindex(::NamedTuple, ::Int)`
    let result = analyze_call((Int,)) do x
            (;x)[1]
        end
        @test isempty(get_reports(result))
    end
    let result = analyze_call((Int,Int)) do x, y
            (;x,y)[2]
        end
        @test isempty(get_reports(result))
    end
    let result = analyze_call((Int,)) do x
            (;x)[2]
        end
        reports = get_reports(result)
        @test length(reports) == 1
        r = only(reports)
        @test r isa BoundsErrorReport && r.a === @NamedTuple{x::Int} && r.i === 2
    end

    # `getindex(::Pair, ::Int)`
    let result = analyze_call((Int,Int)) do x, y
            (x=>y)[1]
        end
        @test isempty(get_reports(result))
    end
    let result = analyze_call((Int,Int)) do x, y
            (x=>y)[0]
        end
        reports = get_reports(result)
        @test length(reports) == 1
        r = only(reports)
        @test r isa BoundsErrorReport && r.a === Pair{Int,Int} && r.i === 0
    end

    # `Base.indexed_iterate`
    let result = analyze_call((Tuple{Any,Any},)) do tpl2
            a, b = tpl2
        end
        @test isempty(get_reports(result))
    end
    let result = analyze_call((Pair{Any,Any},)) do pair
            a, b = pair
        end
        @test isempty(get_reports(result))
    end
    let result = analyze_call((Tuple{Any,Any},)) do tpl2
            a, b, c = tpl2
        end
        reports = get_reports(result)
        @test length(reports) == 1
        r = only(reports)
        @test r isa BoundsErrorReport && r.a === Tuple{Any,Any} && r.i === 3
    end
    let result = analyze_call((Pair{Any,Any},)) do pair
            a, b, c = pair
        end
        reports = get_reports(result)
        @test length(reports) == 1
        r = only(reports)
        @test r isa BoundsErrorReport && r.a === Pair{Any,Any} && r.i === 3
    end

    # `fieldtype`
    let result = analyze_call((Int,Int)) do x, y
            fieldtype((;x,y), 3)
        end
        reports = get_reports(result)
        @test length(reports) == 1
        r = only(reports)
        @test r isa BoundsErrorReport && r.a === @NamedTuple{x::Int,y::Int} && r.i === 3
    end
end

@testset "report_target_modules" begin
    let result = analyze_call(; report_target_modules=()) do
            TestTargetModule.func()
        end
        @test isempty(get_reports(result))
    end

    # UndefVarErrorReport
    let result = analyze_call(; report_target_modules=(@__MODULE__,TestTargetModule,)) do
            TestTargetModule.func()
        end
        reports = get_reports(result)
        @test length(reports) == 1
        r = only(reports)
        @test r isa UndefVarErrorReport && r.var == GlobalRef(TestTargetModule, :undefvar) && r.vst_offset == 0
    end
    let result = analyze_call(; report_target_modules=(@__MODULE__,)) do
            TestTargetModule.unexisting
        end
        reports = get_reports(result)
        @test length(reports) == 1
        r = only(reports)
        @test r isa UndefVarErrorReport && r.var == GlobalRef(TestTargetModule, :unexisting) && r.vst_offset == 1
    end
    let result = analyze_call(; report_target_modules=(ExternalModule,)) do
            TestTargetModule.func()
        end
        @test isempty(get_reports(result))
    end

    # For `GlobalRef`s used directly at the source level (i.e. global binding access that is not `getglobal`),
    # only analyze those from modules directly specified in `report_target_modules`
    let result = analyze_call(; report_target_modules=(@__MODULE__,)) do
            TestTargetModule.func()
        end
        @test isempty(get_reports(result))
    end

    # FieldErrorReport
    let result = analyze_call(issue392; report_target_modules=(@__MODULE__,))
        reports = get_reports(result)
        @test length(reports) == 1
        r = only(reports)
        @test r isa FieldErrorReport && r.field === :propert && r.vst_offset == 1
    end
    let result = analyze_call(issue392; report_target_modules=(ExternalModule,))
        @test isempty(get_reports(result))
    end

    # BoundsErrorReport
    let result = analyze_call((Pair{Any,Any},); report_target_modules=(@__MODULE__,)) do pair
            a, b, c = pair
        end
        reports = get_reports(result)
        @test length(reports) == 1
        r = only(reports)
        @test r isa BoundsErrorReport && r.a === Pair{Any,Any} && r.i === 3 && r.vst_offset == 1
    end
    let result = analyze_call((Pair{Any,Any},); report_target_modules=(ExternalModule,)) do pair
            a, b, c = pair
        end
        @test isempty(get_reports(result))
    end
end

end # module test_LSAnalyzer
