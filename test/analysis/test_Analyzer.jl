module test_Analyzer

using Test
using JETLS

include(normpath(pkgdir(JETLS), "test", "interactive-utils.jl"))
include(normpath(pkgdir(JETLS), "test", "setup.jl"))

using JETLS.JET: CC, get_reports
using JETLS.Analyzer

function analyze_signature(f; report_target_modules = nothing)
    analyzer = JETLS.LSAnalyzer(; report_target_modules)
    analyzer = JET.AbstractAnalyzer(analyzer,
        JET.AnalyzerState(JET.AnalyzerState(analyzer), #=refresh_local_cache=#true))
    m = only(methods(f))
    world = CC.get_inference_world(analyzer)
    match = JETLS.signature_analysis_match(analyzer, m.sig, world)
    match === nothing && error("No method match for signature analysis")
    analyzer, result = JET.analyze_method_signature!(analyzer,
        match.method, match.spec_types, match.sparams)
    return get_reports(analyzer, result)
end

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

@testset "UndefVarErrorReport" begin
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

only_int(x::Int) = 2x

kwfunc(; code::String="code", message::String="message", data=nothing) = (code, message, data)
kwslurp(; a=1, kwargs...) = (a, kwargs)
kwpos(x::Int; y=1) = (x, y)
kwvaropt(pos...; y=1) = (pos, y) # optional keyword + positional vararg
struct KwCallable end
(::KwCallable)(x::Int; y=1) = (x, y)

@testset HierarchicalTestSet "MethodErrorReport" begin
    @testset "NoMethodMatchReport" begin
        # no report when method exists
        let result = analyze_call((Int,)) do x
                sin(x)
            end
            @test isempty(get_reports(result))
        end

        # basic method error
        let result = analyze_call() do
                sin(1, 2)
            end
            reports = get_reports(result)
            @test length(reports) == 1
            r = only(reports)
            @test r isa NoMethodMatchReport && r.union_split == 0
        end

        # union split case: only one branch fails
        let result = analyze_call((Union{Int,String},)) do x
                only_int(x)
            end
            reports = get_reports(result)
            @test length(reports) == 1
            r = only(reports)
            @test r isa NoMethodMatchReport && r.union_split == 2 && length(r.t) == 1
        end

        # union split case: all branches fail
        let result = analyze_call((Union{String,Symbol},)) do x
                only_int(x)
            end
            reports = get_reports(result)
            @test length(reports) == 1
            r = only(reports)
            @test r isa NoMethodMatchReport && r.union_split == 2 && length(r.t) == 2
        end
    end

    @testset "UnsupportedKeywordArgReport" begin
        # a single unsupported keyword argument
        let result = analyze_call() do
                kwfunc(; result="result")
            end
            reports = get_reports(result)
            @test length(reports) == 1
            r = only(reports)
            @test r isa UnsupportedKeywordArgReport
            @test r.ftype === typeof(kwfunc)
            @test r.unsupported == [:result]
        end

        # only the unsupported keywords are reported, supported ones are ignored
        let result = analyze_call() do
                kwfunc(; code="c", result="result", other=1)
            end
            reports = get_reports(result)
            @test length(reports) == 1
            r = only(reports)
            @test r isa UnsupportedKeywordArgReport && r.unsupported == [:result, :other]
        end

        # no report when all keywords are supported
        let result = analyze_call() do
                kwfunc(; code="c", data=42)
            end
            @test isempty(get_reports(result))
        end

        # no report when the method slurps `kwargs...` (accepts any keyword)
        let result = analyze_call() do
                kwslurp(; whatever=1)
            end
            @test isempty(get_reports(result))
        end

        # unsupported keyword combined with positional arguments
        let result = analyze_call((Int,)) do x
                kwpos(x; z=2)
            end
            reports = get_reports(result)
            @test length(reports) == 1
            r = only(reports)
            @test r isa UnsupportedKeywordArgReport && r.unsupported == [:z]
        end

        # supported keyword with positional arguments: no report
        let result = analyze_call((Int,)) do x
                kwpos(x; y=2)
            end
            @test isempty(get_reports(result))
        end

        # a non-constant callable object (resolved via its type, not a singleton instance)
        let result = analyze_call((KwCallable, Int)) do c, x
                c(x; z=2)
            end
            reports = get_reports(result)
            @test length(reports) == 1
            r = only(reports)
            @test r isa UnsupportedKeywordArgReport
            @test r.ftype === KwCallable && r.unsupported == [:z]
        end

        # splatted positional arguments leave a trailing `Vararg` in the call's argtypes, which
        # must be kept intact rather than widened into a bogus signature element
        let result = analyze_call((Tuple{Vararg{Int}},)) do args
                kwvaropt(args...; z=2)
            end
            reports = get_reports(result)
            @test length(reports) == 1
            r = only(reports)
            @test r isa UnsupportedKeywordArgReport
            @test r.ftype === typeof(kwvaropt) && r.unsupported == [:z]
            @test r.posargtypes == Any[Vararg{Int}]
        end
    end
end

kwreq(; x) = x            # required keyword x
kwreq2(; x, y=2) = (x, y) # required x, optional y
kwopt(; x=1) = x          # optional keyword x
kwfwd(; kws...) = kwreq(; kws...) # forwards slurped keywords to a required-keyword function
kwreqpos(pos; x) = (pos, x)
kwfwdpos(; kws...) = kwreqpos(42; kws...)
kwvarpos(pos...; x) = (pos, x) # required keyword + positional vararg
kwcaller() = kwreq()      # never supplies the required keyword
module UndefKeywordExternalModule
    libkwreq(; x) = x
end

@testset "UndefKeywordErrorReport" begin
    # required keyword missing on a direct call (no keyword sorter)
    let result = analyze_call() do
            kwreq()
        end
        reports = get_reports(result)
        @test length(reports) == 1
        r = only(reports)
        @test r isa UndefKeywordErrorReport && r.var === :x
    end

    # required keyword missing while another keyword is provided (via keyword sorter)
    let result = analyze_call() do
            kwreq2(; y=3)
        end
        reports = get_reports(result)
        @test length(reports) == 1
        r = only(reports)
        @test r isa UndefKeywordErrorReport && r.var === :x
    end

    # no report when the required keyword is provided
    let result = analyze_call() do
            kwreq(; x=1)
        end
        @test isempty(get_reports(result))
    end

    # no report for an optional keyword
    let result = analyze_call() do
            kwopt()
        end
        @test isempty(get_reports(result))
    end

    # no false positive when keywords are splatted dynamically: `nt` may supply `x`, so the
    # call does not definitely throw
    let result = analyze_call((NamedTuple,)) do nt
            kwreq(; nt...)
        end
        @test isempty(get_reports(result))
    end

    # splatted positional arguments leave a trailing `Vararg` in the call's argtypes, which
    # must be kept intact rather than widened into a bogus signature element
    let result = analyze_call((Tuple{Vararg{Int}},)) do args
            kwvarpos(args...)
        end
        reports = get_reports(result)
        @test length(reports) == 1
        r = only(reports)
        @test r isa UndefKeywordErrorReport && r.var === :x
    end

    # signature analysis uses an abstract keyword sorter for keyword-forwarding wrappers,
    # so a required keyword may be supplied by the wrapper's own caller
    let reports = analyze_signature(kwfwd)
        @test isempty(reports)
    end
    let reports = analyze_signature(kwfwdpos)
        @test isempty(reports)
    end
    # ... but a concrete zero-keyword call to the forwarder still reports the real error
    let result = analyze_call(kwfwd, ())
        reports = get_reports(result)
        @test length(reports) == 1
        r = only(reports)
        @test r isa UndefKeywordErrorReport && r.var === :x
    end
    let result = analyze_call(kwfwdpos, ())
        reports = get_reports(result)
        @test length(reports) == 1
        r = only(reports)
        @test r isa UndefKeywordErrorReport && r.var === :x
    end
    # ... and a non-forwarding function that never supplies the keyword is still reported
    let reports = analyze_signature(kwcaller)
        @test length(reports) == 1
        r = only(reports)
        @test r isa UndefKeywordErrorReport && r.var === :x
    end

    # Two call sites of the same missing-keyword callee within one frame are reported
    # independently. The report originates on the callee's keyword sorter, inferred once
    # and shared by both sites, but `ls_aggregation_policy` also keys on the attribution
    # (call-site) frame, so the two sites are not collapsed into a single report.
    let result = analyze_call((Bool,)) do c
            if c
                kwreq()
            else
                kwreq()
            end
        end
        reports = get_reports(result)
        @test length(reports) == 2
        @test all(r -> r isa UndefKeywordErrorReport && r.var === :x, reports)
    end

    # the throw happens in the callee's module, but gating is on the caller: a call from a
    # target module is reported even when the function is defined elsewhere
    let result = analyze_call(; report_target_modules=(@__MODULE__,)) do
            UndefKeywordExternalModule.libkwreq()
        end
        reports = get_reports(result)
        @test length(reports) == 1
        @test only(reports) isa UndefKeywordErrorReport
    end
    # ... but not reported when the caller's module is outside the target set
    let result = analyze_call(; report_target_modules=(UndefKeywordExternalModule,)) do
            UndefKeywordExternalModule.libkwreq()
        end
        @test isempty(get_reports(result))
    end
end

@testset "BoundsErrorReport" begin
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

kwtyped(a::Int; kw::Int=42) = a * kw       # typed keyword with a default, plus a positional
kwtyped2(; x::Int, y::String="s") = (x, y) # required typed x, optional typed y
kwtypedfwd(; kws...) = kwtyped(1; kws...)   # forwards slurped keywords
kwtypedbad(; kws...) = kwtyped(1; kw=2.0)   # slurps but hardcodes a mismatching call
module KeywordTypeExternalModule
    libkwtyped(; kw::Int=1) = kw
end

@testset HierarchicalTestSet "TypeErrorReport" begin
    @testset "KeywordTypeErrorReport" begin
        # keyword value whose type does not match the declared keyword type
        let result = analyze_call() do
                kwtyped(2; kw=42.0)
            end
            reports = get_reports(result)
            @test length(reports) == 1
            r = only(reports)
            @test r isa KeywordTypeErrorReport
            @test r.var === :kw && r.expected === Int && r.got === Float64
        end

        # mismatch on a required typed keyword (routed through the keyword sorter)
        let result = analyze_call() do
                kwtyped2(; x=1.0)
            end
            reports = get_reports(result)
            @test length(reports) == 1
            r = only(reports)
            @test r isa KeywordTypeErrorReport && r.var === :x && r.expected === Int
        end

        # no report when the keyword value type matches
        let result = analyze_call() do
                kwtyped(2; kw=42)
            end
            @test isempty(get_reports(result))
        end

        # no report when the keyword is omitted (the default is used)
        let result = analyze_call() do
                kwtyped(2)
            end
            @test isempty(get_reports(result))
        end

        # no false positive when the value type only sometimes mismatches: the call does not
        # definitely throw, so it is not flagged
        let result = analyze_call((Union{Int,Float64},)) do x
                kwtyped(1; kw=x)
            end
            @test !any(r -> r isa KeywordTypeErrorReport, get_reports(result))
        end

        # no false positive for a keyword-forwarding wrapper analyzed at its zero-keyword
        # signature: a forwarded call carries no statically-known mismatching value
        let result = analyze_call(kwtypedfwd)
            @test isempty(get_reports(result))
        end
        # ... but a hardcoded mismatching call inside a slurping function is still reported
        # (unlike missing keywords, slurping does not mask a value-type mismatch)
        let result = analyze_call(kwtypedbad)
            reports = get_reports(result)
            @test length(reports) == 1
            @test only(reports) isa KeywordTypeErrorReport
        end

        # each reached call site is reported independently (call-site, not throw-site, detection):
        # both branches pass the same mismatching keyword, so throw-site detection — firing once on
        # the shared sorter's fresh inference — would report only one of them
        let result = analyze_call((Bool,)) do c
                if c
                    kwtyped(1; kw=2.0)
                else
                    kwtyped(1; kw=2.0)
                end
            end
            reports = filter(r -> r isa KeywordTypeErrorReport, get_reports(result))
            @test length(reports) == 2
        end

        # a definite type error on a conditional branch is still reported even when the frame
        # returns normally on another path: unlike a missing keyword, a value-type mismatch is
        # never spuriously synthesized on a non-taken branch, so it is not suppressed
        let result = analyze_call((Bool,)) do c
                c ? kwtyped(1; kw=2.0) : 0
            end
            reports = filter(r -> r isa KeywordTypeErrorReport, get_reports(result))
            @test length(reports) == 1
            @test only(reports).var === :kw
        end

        # the throw happens in the callee's module, but gating is on the caller: a call from a
        # target module is reported even when the function is defined elsewhere
        let result = analyze_call(; report_target_modules=(@__MODULE__,)) do
                KeywordTypeExternalModule.libkwtyped(; kw=2.0)
            end
            reports = get_reports(result)
            @test length(reports) == 1
            @test only(reports) isa KeywordTypeErrorReport
        end
        # ... but not reported when the caller's module is outside the target set
        let result = analyze_call(; report_target_modules=(KeywordTypeExternalModule,)) do
                KeywordTypeExternalModule.libkwtyped(; kw=2.0)
            end
            @test isempty(get_reports(result))
        end
    end

    @testset "TypeAssertErrorReport" begin
        let result = analyze_call((Int,)) do x
                x::Int
            end
            @test isempty(get_reports(result))
        end
        let result = analyze_call((Any,)) do x
                x::Int
            end
            @test isempty(get_reports(result))
        end

        let result = analyze_call() do
                let x = rand()
                    o = x::Int
                    o
                end
            end
            reports = get_reports(result)
            @test length(reports) == 1
            r = only(reports)
            @test r isa TypeAssertErrorReport
            @test r.expected === Int && r.actual === Float64
            @test sprint(JETLS.JET.print_report_message, r) == "TypeError: in `typeassert`, expected `Int64`, got a value of type `Float64`"
        end

        let result = analyze_call() do
                (Int)::String
            end
            reports = get_reports(result)
            @test length(reports) == 1
            r = only(reports)
            @test r isa TypeAssertErrorReport
            @test r.expected === String && r.actual === Type{Int}
            @test sprint(JETLS.JET.print_report_message, r) == "TypeError: in `typeassert`, expected `String`, got Type{Int64}"
        end

        let result = analyze_call((Union{Int,Float64},)) do x
                x::Int
            end
            @test isempty(get_reports(result))
        end
    end

    @testset "NonBooleanCondErrorReport" begin
        # no report for boolean condition
        let result = analyze_call((Bool,)) do x
                x ? 1 : 2
            end
            @test isempty(get_reports(result))
        end
        let result = analyze_call((Bool,)) do x
                if x; 1; else; 2; end
            end
            @test isempty(get_reports(result))
        end
        let result = analyze_call((Bool,)) do x
                x && return 1
            end
            @test isempty(get_reports(result))
        end

        # basic non-boolean condition
        let result = analyze_call((Int,)) do x
                x ? 1 : 2
            end
            reports = get_reports(result)
            @test length(reports) == 1
            r = only(reports)
            @test r isa NonBooleanCondErrorReport && r.union_split == 0
        end
        let result = analyze_call((Int,)) do x
                if x; 1; else; 2; end
            end
            reports = get_reports(result)
            @test length(reports) == 1
            r = only(reports)
            @test r isa NonBooleanCondErrorReport && r.union_split == 0
        end
        let result = analyze_call((Int,)) do x
                x && return 1
            end
            reports = get_reports(result)
            @test length(reports) == 1
            r = only(reports)
            @test r isa NonBooleanCondErrorReport && r.union_split == 0
        end

        # union split case: only one branch is non-boolean
        let result = analyze_call((Union{Bool,Int},)) do x
                x ?  1 : 2
            end
            reports = get_reports(result)
            @test length(reports) == 1
            r = only(reports)
            @test r isa NonBooleanCondErrorReport && r.union_split == 2 && length(r.t) == 1
        end

        # JuliaLang/julia#61526
        let result = analyze_call((Vector{String},String,)) do xs, x
                x in tuple(xs) ? 0 : 1
            end
            reports = get_reports(result)
            @test isempty(reports)
        end
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

    # NoMethodMatchReport
    let result = analyze_call(; report_target_modules=(@__MODULE__,)) do
            sin(1, 2)
        end
        reports = get_reports(result)
        @test length(reports) == 1
        r = only(reports)
        @test r isa NoMethodMatchReport
    end
    let result = analyze_call(; report_target_modules=(ExternalModule,)) do
            sin(1, 2)
        end
        @test isempty(get_reports(result))
    end
end

end # module test_LSAnalyzer
