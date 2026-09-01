module test_Analyzer

using Test
using JETLS

include(normpath(pkgdir(JETLS), "test", "interactive-utils.jl"))
include(normpath(pkgdir(JETLS), "test", "setup.jl"))

using JETLS.JET: CC, JET, get_reports
using JETLS.Analyzer

related_frame_indices(report) =
    map(frame -> frame.idx, inference_error_report_related_frames(report))
related_frame_kinds(report) =
    map(frame -> frame.kind, inference_error_report_related_frames(report))
function related_frame_signatures(report; actual2virtual=Main=>@__MODULE__)
    postprocessor = JET.PostProcessor(actual2virtual)
    map(inference_error_report_related_frames(report)) do frame
        postprocessor(sprint(JET.print_frame_sig, report.vst[frame.idx], JET.PrintConfig()))
    end
end

function primary_frame_signature(report; actual2virtual=Main=>@__MODULE__)
    postprocessor = JET.PostProcessor(actual2virtual)
    sprint(JET.print_frame_sig, report.vst[first(inference_error_report_stack(report))],
        JET.PrintConfig()) |> postprocessor
end

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

call_testtarget_func() = TestTargetModule.func()
read_testtarget_unexisting() = TestTargetModule.unexisting
function unpack_pair(pair::Pair{Any,Any})
    _, _, _ = pair
    return nothing
end

# Adapted from JuliaLang/julia#61048
throwconditional61048(c, x) = c ? throw(x isa Int) : throw(x isa Float64)
function issue61048(c::Bool, x)
    throwconditional61048(c, x)
end
@testset "aviatesk/JETLS#887" begin
    @test isempty(analyze_signature(issue61048))
end

# test basic analysis abilities of `LSAnalyzer`
function report_global_undef()
    return sin(undefvar)
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

struct Issue392
    property::Int
end
function issue392()
    x = Issue392(42)
    println(x.propert)
    return x
end

# aviatesk/JETLS.jl#469
struct TransparentGetproperty
    x::Int
end
function Base.getproperty(o::TransparentGetproperty, s::Symbol)
    if s === :alias
        return getfield(o, :x)
    else
        return getfield(o, s)
    end
end
transparent_getproperty_error(o::TransparentGetproperty) = o.missing

struct TypoGetproperty
    x::Int
end
Base.getproperty(o::TypoGetproperty, ::Symbol) = getfield(o, :typo)
typo_getproperty_error(o::TypoGetproperty) = o.missing

struct HelperGetproperty
    x::Int
end
Base.getproperty(o::HelperGetproperty, s::Symbol) = helper_getproperty(o, s)
helper_getproperty(o::HelperGetproperty, s::Symbol) = getfield(o, s)
helper_getproperty_error(o::HelperGetproperty) = o.missing

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

    let result = analyze_call(transparent_getproperty_error; report_target_modules=(@__MODULE__,))
        reports = get_reports(result)
        @test length(reports) == 1
        r = only(reports)
        @test r isa FieldErrorReport && r.field === :missing
        @test primary_frame_signature(r) == "transparent_getproperty_error(o::TransparentGetproperty)"
        @test lastindex(r.vst) ∈ related_frame_indices(r)
        @test RelatedOriginFrame ∈ related_frame_kinds(r)
    end

    let result = analyze_call(typo_getproperty_error; report_target_modules=(@__MODULE__,))
        reports = get_reports(result)
        @test length(reports) == 1
        r = only(reports)
        @test r isa FieldErrorReport && r.field === :typo
        @test primary_frame_signature(r) == "getproperty(o::TypoGetproperty, ::Symbol)"
        @test lastindex(r.vst) ∉ related_frame_indices(r)
    end

    let result = analyze_call(helper_getproperty_error; report_target_modules=(@__MODULE__,))
        reports = get_reports(result)
        @test length(reports) == 1
        r = only(reports)
        @test r isa FieldErrorReport && r.field === :missing
        @test_broken primary_frame_signature(r) == "helper_getproperty_error(o::HelperGetproperty)" &&
            lastindex(r.vst) ∈ related_frame_indices(r) &&
            RelatedOriginFrame ∈ related_frame_kinds(r)
    end

    let result = analyze_call((Some,)) do some
            fieldtype(some, :val)
        end
        reports = get_reports(result)
        @test length(reports) == 1
        r = only(reports)
        @test r isa FieldErrorReport && r.field === :val
    end

    # the report must not depend on inference cache state:
    # re-analyzing the same call with a warm cache must reproduce it
    let kernel = function (x)
            x.regex
        end
        for _ = 1:2
            result = analyze_call(kernel, (Union{Nothing,Regex},))
            reports = get_reports(result)
            @test length(reports) == 1
            r = only(reports)
            @test r isa FieldErrorReport && r.type === Nothing && r.field === :regex
        end
    end
    let result = analyze_call((Nothing,)) do x
            x.foo
        end
        reports = get_reports(result)
        @test length(reports) == 1
        r = only(reports)
        @test r isa FieldErrorReport && r.type === Nothing && r.field === :foo
    end
    let NT = Union{@NamedTuple{regex::Int},@NamedTuple{regex::String}}
        result = analyze_call((NT,)) do x
            x.regex
        end
        @test isempty(get_reports(result))
    end
    let result = analyze_call((Union{@NamedTuple{alias::Int},TransparentGetproperty},)) do x
            x.alias
        end
        @test isempty(get_reports(result))
    end
    # an erroring split whose receiver has other fields takes the same const-prop
    # path as before: exactly one report, no duplicates
    let result = analyze_call((Union{Some{Int},Regex},)) do x
            x.value
        end
        reports = get_reports(result)
        @test length(reports) == 1
        r = only(reports)
        @test r isa FieldErrorReport && r.type === Regex && r.field === :value
    end
    let result = analyze_call((Union{Nothing,Missing},)) do x
            x.foo
        end
        reports = get_reports(result)
        @test length(reports) == 2
        @test any(reports) do r
            r isa FieldErrorReport && r.type === Nothing && r.field === :foo
        end
        @test any(reports) do r
            r isa FieldErrorReport && r.type === Missing && r.field === :foo
        end
    end
    let result = analyze_call((Union{Nothing,Regex},)) do x
            isnothing(x) && return nothing
            return x.regex
        end
        @test isempty(get_reports(result))
    end
end

only_int(x::Int) = 2x
nested_only_int_inner(x) = only_int(x)
nested_only_int_outer(x) = nested_only_int_inner(x)
call_nested_only_int(x) = nested_only_int_outer(x)
ambiguous_func(x, y::Int) = x + y
ambiguous_func(x::Int, y) = x - y
union_ambiguous_func(x::Number, y::Int) = x + y
union_ambiguous_func(x::Int, y::Number) = x - y
world_age_func(x::Int) = x
struct MethodErrorCallable
    value::Int
end
(::MethodErrorCallable)(x::Int) = x
call_method_error_callable(f::MethodErrorCallable) = f("x")
function call_captured_method_error()
    captured = 1
    f = (x::Int) -> x + captured
    return f("x")
end
struct MethodErrorParametricCallable{T}
    value::T
end
(::MethodErrorParametricCallable)(x::Int) = x
call_method_error_parametric_callable(f::MethodErrorParametricCallable) = f("x")
abstract type AbstractMethodErrorCallable end
(::AbstractMethodErrorCallable)(x::Int) = x
call_abstract_method_error_callable(f::AbstractMethodErrorCallable) = f("x")
struct MethodErrorWorldAgeCallable
    value::Int
end
call_method_error_world_age_callable(f::MethodErrorWorldAgeCallable) = f("x")
struct MethodErrorConstructor{T} end
MethodErrorConstructor(x::Int) = MethodErrorConstructor{Int}()
call_method_error_constructor() = MethodErrorConstructor("x")
abstract type MethodErrorNoConstructor end
call_method_error_no_constructor() = MethodErrorNoConstructor(1)
struct MethodErrorNotCallable
    value::Int
end
call_method_error_not_callable(f::MethodErrorNotCallable) = f(1)
struct MethodErrorNotCallableSingleton end
call_method_error_not_callable_singleton() = MethodErrorNotCallableSingleton()(1)
struct MethodErrorVarargCallable
    value::Int
end
(::MethodErrorVarargCallable)(xs::Int...) = xs
call_method_error_vararg_callable(f::MethodErrorVarargCallable) = f("x", "y")
vararg_only_int(xs::Int...) = xs
call_vararg_splat_method_error(xs::Vector{String}) = vararg_only_int("x", xs...)
nokw_func(x::Int) = x
call_kwcall_method_error(x::Int) = nokw_func(x; kw=1)
call_kwcall_no_match_method_error(x::String) = nokw_func(x; kw=1)
kwambig_func(x, y::Int; a=1) = 1
kwambig_func(x::Int, y; b=1) = 2
kwambig_func(x::Int, y::Int) = 3
call_kwambig_method_error(x::Int, y::Int) = kwambig_func(x, y; z=1)
kwsplit_func(x::Int; a=1) = x
call_kwsplit_method_error(x::Union{Int,String}) = kwsplit_func(x; z=1)
nokw_union_func(x::Int) = x
nokw_union_func(x::String) = x
call_kwcall_union_explained(x::Union{Int,String}) = nokw_union_func(x; kw=1)
vararg_ambiguous_func(x, y::Int) = 1
vararg_ambiguous_func(x::Int, y) = 2
call_vararg_ambiguous(xs::Tuple{Vararg{Int}}) = vararg_ambiguous_func(xs...)
partial_ambiguous_func(x, y::Int, z::Int) = 1
partial_ambiguous_func(x::Int, y, z::Int) = 2
call_partial_ambiguous(z::Number) = partial_ambiguous_func(1, 1, z)
full_vararg_ambiguous_func(x, y::Int, zs::Int...) = 1
full_vararg_ambiguous_func(x::Int, y, zs::Int...) = 2
function call_full_vararg_ambiguous(xs::Tuple{Int,Int,Vararg{Int}})
    return full_vararg_ambiguous_func(xs...)
end
changing_vararg_ambiguous_func(x, y::Int, zs::Int...) = 1
changing_vararg_ambiguous_func(x::Int, y, zs::Int...) = 2
changing_vararg_ambiguous_func(x::Int, y::Number) = 3
function call_changing_vararg_ambiguous(xs::Tuple{Int,Int,Vararg{Int}})
    return changing_vararg_ambiguous_func(xs...)
end

multi_ambiguous_func(x::Number, y::Int) = x + y
multi_ambiguous_func(x::Int, y::Number) = x - y
multi_ambiguous_func(x::AbstractString, y::String) = x * y
multi_ambiguous_func(x::String, y::AbstractString) = y * x

kwfunc(; code::String="code", message::String="message", data=nothing) = (code, message, data)
kwdispatch(x::Int; a=1) = x
kwdispatch(x::String; b=1) = x
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
                sin('4')
            end
            reports = get_reports(result)
            @test length(reports) == 1
            r = only(reports)
            @test r isa NoMethodMatchReport && r.union_split == 0
            message = sprint(JET.print_report_message, r)
            @test startswith(message, "MethodError: no matching method found `sin(::Char)`")
            @test occursin("The function `sin` exists, but no method is defined", message)
            @test occursin("Closest candidates are:", message)
            @test occursin("\n- `sin(!Matched::", message)
            @test occursin("\n  @ Base", message)
            @test occursin("\n- ...", message)
        end

        let result = analyze_call(call_method_error_callable, (MethodErrorCallable,))
            reports = get_reports(result)
            @test length(reports) == 1
            r = only(reports)
            @test r isa NoMethodMatchReport && r.union_split == 0
            message = sprint(JET.print_report_message, r)
            @test startswith(message, "MethodError: no matching method found `(::")
            @test occursin("MethodErrorCallable)(::String)`", message)
            @test occursin("The object of type `", message)
            @test occursin("MethodErrorCallable` exists", message)
            @test occursin("Closest candidates are:", message)
            @test occursin("MethodErrorCallable)(x::$Int)`\n  @", message)
        end

        let result = analyze_call(call_captured_method_error, ())
            reports = get_reports(result)
            @test length(reports) == 1
            r = only(reports)
            @test r isa NoMethodMatchReport && r.union_split == 0
            message = sprint(JET.print_report_message, r)
            @test occursin("The object of type `", message)
            @test occursin("Closest candidates are:", message)
            @test occursin("(x::$Int)`\n  @", message)
        end

        let result = analyze_call(
                call_method_error_parametric_callable, (MethodErrorParametricCallable,))
            reports = get_reports(result)
            @test length(reports) == 1
            r = only(reports)
            @test r isa NoMethodMatchReport && r.union_split == 0
            message = sprint(JET.print_report_message, r)
            @test occursin("The object of type `", message)
            @test occursin("Closest candidates are:", message)
            @test occursin("MethodErrorParametricCallable)(x::$Int)`", message)
        end

        let result = analyze_call(
                call_abstract_method_error_callable, (AbstractMethodErrorCallable,))
            reports = get_reports(result)
            @test length(reports) == 1
            r = only(reports)
            @test r isa NoMethodMatchReport && r.union_split == 0
            message = sprint(JET.print_report_message, r)
            @test occursin("The object of type `", message)
            @test occursin("Closest candidates are:", message)
            @test occursin("AbstractMethodErrorCallable)(x::$Int)`", message)
        end

        let result = analyze_call(
                call_method_error_world_age_callable, (MethodErrorWorldAgeCallable,))
            reports = get_reports(result)
            @test length(reports) == 1
            r = only(reports)
            @test r isa NoMethodMatchReport && r.union_split == 0
            @eval (::MethodErrorWorldAgeCallable)(x::String) = x
            message = sprint(JET.print_report_message, r)
            @test occursin("Closest candidates are:", message)
            @test occursin("MethodErrorWorldAgeCallable)(x::String)`", message)
            @test occursin("method too new to be called from this world context", message)
        end

        let result = analyze_call(call_method_error_constructor, ())
            reports = get_reports(result)
            @test length(reports) == 1
            r = only(reports)
            @test r isa NoMethodMatchReport && r.union_split == 0
            message = sprint(JET.print_report_message, r)
            @test startswith(message, "MethodError: no matching method found `")
            @test occursin("MethodErrorConstructor(::String)`", message)
            @test occursin("The type `", message)
            @test occursin("MethodErrorConstructor` exists", message)
            @test occursin("Closest candidates are:", message)
            @test occursin("MethodErrorConstructor(!Matched::$Int)`", message)
        end

        # abstract type without any constructor
        let result = analyze_call(call_method_error_no_constructor, ())
            reports = get_reports(result)
            @test length(reports) == 1
            r = only(reports)
            @test r isa NoMethodMatchReport && r.union_split == 0
            @eval MethodErrorNoConstructor(x::Int) = x
            message = sprint(JET.print_report_message, r)
            @test occursin("No constructors have been defined for `", message)
            @test occursin("MethodErrorNoConstructor`.", message)
            @test !occursin("exists", message)
            @test !occursin("Closest candidates are:", message)
        end

        # object without any callable method
        let result = analyze_call(
                call_method_error_not_callable, (MethodErrorNotCallable,))
            reports = get_reports(result)
            @test length(reports) == 1
            r = only(reports)
            @test r isa NoMethodMatchReport && r.union_split == 0
            message = sprint(JET.print_report_message, r)
            @test occursin("MethodErrorNotCallable` are not callable.", message)
            @test !occursin("exists", message)
            @test !occursin("Closest candidates are:", message)
        end

        # singleton object without any callable method
        let result = analyze_call(call_method_error_not_callable_singleton, ())
            reports = get_reports(result)
            @test length(reports) == 1
            r = only(reports)
            @test r isa NoMethodMatchReport && r.union_split == 0
            @eval (::MethodErrorNotCallableSingleton)(x::Int) = x
            message = sprint(JET.print_report_message, r)
            @test occursin("MethodErrorNotCallableSingleton` are not callable.", message)
            @test !occursin("exists", message)
        end

        # vararg method of a callable object: candidate scoring must not crash
        let result = analyze_call(
                call_method_error_vararg_callable, (MethodErrorVarargCallable,))
            reports = get_reports(result)
            @test length(reports) == 1
            r = only(reports)
            @test r isa NoMethodMatchReport && r.union_split == 0
            message = sprint(JET.print_report_message, r)
            @test occursin("The object of type `", message)
            @test occursin("Closest candidates are:", message)
            @test occursin("(xs::$Int...)`", message)
            @test !endswith(message, '\n')
        end

        # splat call with `Vararg` argument types: hint must not crash `Base` printing
        let result = analyze_call(call_vararg_splat_method_error, (Vector{String},))
            reports = get_reports(result)
            @test length(reports) == 1
            r = only(reports)
            @test r isa NoMethodMatchReport && r.union_split == 0
            message = sprint(JET.print_report_message, r)
            @test startswith(message,
                "MethodError: no matching method found `vararg_only_int(::String")
            @test occursin("The function `vararg_only_int` exists", message)
            @test occursin("Closest candidates are:", message)
            @test !endswith(message, '\n')
        end

        # `Core.kwcall` signatures get no misleading candidate hints
        let result = analyze_call(call_kwcall_no_match_method_error, (String,))
            reports = get_reports(result)
            @test length(reports) == 1
            r = only(reports)
            @test r isa NoMethodMatchReport && r.union_split == 0
            message = sprint(JET.print_report_message, r)
            @test startswith(message, "MethodError: no matching method found `kwcall(")
            @test !occursin("exists", message)
            @test !occursin("Closest candidates are:", message)
        end

        # ambiguous `Core.kwcall` dispatch is reported alongside the keyword diagnostic
        let result = analyze_call(call_kwambig_method_error, (Int, Int))
            reports = get_reports(result)
            @test length(reports) == 2
            ambiguity = only(r for r in reports if r isa AmbiguousMethodReport)
            kwarg = only(r for r in reports if r isa UnsupportedKeywordArgReport)
            @test kwarg.unsupported == [:z]
            message = sprint(JET.print_report_message, ambiguity)
            @test startswith(message, "MethodError: `kwcall(")
            # Defining an internal `Core.kwcall` method is not a source-level fix.
            @test !occursin("Possible fix, define:", message)
            @test occursin("To resolve the ambiguity", message)
        end

        # keyword suppression is per-branch: a union-split branch without any positional
        # method keeps its no-match report
        let result = analyze_call(call_kwsplit_method_error, (Union{Int,String},))
            reports = get_reports(result)
            @test length(reports) == 2
            kwarg = only(r for r in reports if r isa UnsupportedKeywordArgReport)
            no_match = only(r for r in reports if r isa NoMethodMatchReport)
            @test kwarg.unsupported == [:z]
            @test no_match.union_split == 2 && length(no_match.t) == 1
            message = sprint(JET.print_report_message, no_match)
            @test startswith(message, "MethodError: no matching method found `kwcall(")
            @test occursin("::String", message)
        end

        # while branches explained by the keyword diagnostic are still suppressed
        let result = analyze_call(call_kwcall_union_explained, (Union{Int,String},))
            reports = get_reports(result)
            @test length(reports) == 1
            r = only(reports)
            @test r isa UnsupportedKeywordArgReport
            @test r.unsupported == [:kw]
        end

        # open-ended `Vararg` signatures are not classified by the ambiguity flag alone
        let result = analyze_call(call_vararg_ambiguous, (Tuple{Vararg{Int}},))
            r = only(get_reports(result))
            @test r isa NoMethodMatchReport && r.union_split == 0
            message = sprint(JET.print_report_message, r)
            @test startswith(message, "MethodError: no matching method found `vararg_ambiguous_func(")
            @test occursin("The function `vararg_ambiguous_func` exists", message)
        end

        # fixed-length abstract signatures can also mix ambiguity and no-match regions
        let result = analyze_call(call_partial_ambiguous, (Number,))
            @test only(get_reports(result)) isa NoMethodMatchReport
        end

        # every arity represented by this open-ended `Vararg` is ambiguous
        let result = analyze_call(
                call_full_vararg_ambiguous, (Tuple{Int,Int,Vararg{Int}},))
            reports = get_reports(result)
            @test length(reports) == 1
            r = only(reports)
            @test r isa AmbiguousMethodReport && r.union_split == 0
            @test length(r.methods) == 2
            message = sprint(JET.print_report_message, r)
            @test startswith(message, "MethodError: `full_vararg_ambiguous_func(")
            @test occursin("::Vararg{$Int})` is ambiguous.", message)
        end

        # the conflicting candidates may change between represented arities
        let result = analyze_call(
                call_changing_vararg_ambiguous, (Tuple{Int,Int,Vararg{Int}},))
            reports = get_reports(result)
            @test length(reports) == 1
            r = only(reports)
            @test r isa AmbiguousMethodReport && length(r.methods) == 3
            message = sprint(JET.print_report_message, r)
            @test !occursin("Possible fix, define:", message)
            @test occursin("To resolve the ambiguity", message)
        end

        # ambiguous method error
        let result = analyze_call() do
                ambiguous_func(1, 2)
            end
            reports = get_reports(result)
            @test length(reports) == 1
            r = only(reports)
            @test r isa AmbiguousMethodReport && r.union_split == 0
            @test length(r.methods) == 2
            message = sprint(JET.print_report_message, r)
            @test startswith(message, "MethodError: `ambiguous_func(::$Int, ::$Int)` is ambiguous.")
            @test occursin("\n\nCandidates:\n", message)
            @test occursin("\n- `ambiguous_func(x::$Int, y)`\n  @", message)
            @test occursin("\n- `ambiguous_func(x, y::$Int)`\n  @", message)
            @test occursin("\n\nPossible fix, define: `ambiguous_func(::$Int, ::$Int)`", message)
        end

        # union split case: ambiguity and no-match branches
        let result = analyze_call((Union{Int,String},)) do x
                union_ambiguous_func(x, 1)
            end
            reports = get_reports(result)
            @test length(reports) == 2
            no_match = only(r for r in reports if r isa NoMethodMatchReport)
            ambiguity = only(r for r in reports if r isa AmbiguousMethodReport)
            @test no_match.union_split == ambiguity.union_split == 2
            @test length(no_match.t) == 1
            @test length(ambiguity.t::Vector{Any}) == 1
            @test length(only(ambiguity.methods::Vector{Vector{Method}})) == 2
            no_match_message = sprint(JET.print_report_message, no_match)
            ambiguity_message = sprint(JET.print_report_message, ambiguity)
            @test startswith(no_match_message, "MethodError: no matching method found `union_ambiguous_func(::String, ::$Int)`")
            @test occursin(" (1/2 union split)\n\nThe function `union_ambiguous_func` exists", no_match_message)
            @test occursin("Closest candidates are:", no_match_message)
            @test startswith(ambiguity_message, "MethodError: `union_ambiguous_func(::$Int, ::$Int)` is ambiguous. ")
            @test occursin("(1/2 union split)\n\nCandidates:\n- `", ambiguity_message)
            @test !endswith(ambiguity_message, '\n')
        end

        # union split case: multiple ambiguous branches are aggregated into one report
        let result = analyze_call((Union{Int,String}, Union{Int,String})) do x, y
                multi_ambiguous_func(x, y)
            end
            reports = get_reports(result)
            @test length(reports) == 2
            no_match = only(r for r in reports if r isa NoMethodMatchReport)
            ambiguity = only(r for r in reports if r isa AmbiguousMethodReport)
            @test no_match.union_split == ambiguity.union_split == 4
            @test length(no_match.t) == 2
            ts = ambiguity.t::Vector{Any}
            methodss = ambiguity.methods::Vector{Vector{Method}}
            @test length(ts) == 2 && length(methodss) == 2
            @test all(methods -> length(methods) == 2, methodss)
            message = sprint(JET.print_report_message, ambiguity)
            @test startswith(message, "MethodError: `multi_ambiguous_func(::")
            @test occursin("` are ambiguous. (2/4 union split)", message)
            @test occursin("For `multi_ambiguous_func(::$Int, ::$Int)`:", message)
            @test occursin("For `multi_ambiguous_func(::String, ::String)`:", message)
            @test length(findall("Candidates:", message)) == 2
            @test occursin("Possible fix, define: `multi_ambiguous_func(::$Int, ::$Int)`", message)
            @test occursin("Possible fix, define: `multi_ambiguous_func(::String, ::String)`", message)
        end

        # union split case: only one branch fails
        let result = analyze_call((Union{Int,String},)) do x
                only_int(x)
            end
            reports = get_reports(result)
            @test length(reports) == 1
            r = only(reports)
            @test r isa NoMethodMatchReport && r.union_split == 2 && length(r.t) == 1
            message = sprint(JET.print_report_message, r)
            @test startswith(message, "MethodError: no matching method found `only_int(::String)`")
            @test occursin(" (1/2 union split)\n\nThe function `only_int` exists", message)
            @test occursin("Closest candidates are:", message)
            @test occursin("\n- `only_int(!Matched::$Int)`", message)
        end

        let result = analyze_call(call_nested_only_int, (String,); report_target_modules=(@__MODULE__,))
            reports = get_reports(result)
            @test length(reports) == 1
            r = only(reports)
            @test r isa NoMethodMatchReport && r.union_split == 0
            @test related_frame_kinds(r) == [
                RelatedViaFrame,
                RelatedEntryFrame,
            ]
            @test related_frame_signatures(r) == [
                "nested_only_int_outer(x::String)",
                "call_nested_only_int(x::String)",
            ]
        end

        # union split case: all branches fail
        let result = analyze_call((Union{String,Symbol},)) do x
                only_int(x)
            end
            reports = get_reports(result)
            @test length(reports) == 1
            r = only(reports)
            @test r isa NoMethodMatchReport && r.union_split == 2 && length(r.t) == 2
            message = sprint(JET.print_report_message, r)
            @test occursin("For `only_int(::String)`:", message)
            @test occursin("For `only_int(::Symbol)`:", message)
            @test length(findall("Closest candidates are:", message)) == 2
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

        # a callee without any keyword-accepting method: the keyword diagnostic
        # supersedes the no-match report on the raw `Core.kwcall` signature
        let result = analyze_call(call_kwcall_method_error, (Int,))
            reports = get_reports(result)
            @test length(reports) == 1
            r = only(reports)
            @test r isa UnsupportedKeywordArgReport
            @test r.ftype === typeof(nokw_func)
            @test r.unsupported == [:kw]
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

        # every positional branch rejects the keyword combination, but for different names
        let result = analyze_call((Union{Int,String},)) do x
                kwdispatch(x; a=1, b=1)
            end
            r = only(get_reports(result))
            @test r isa UnsupportedKeywordArgReport
            @test r.combination && r.unsupported == [:a, :b]
            message = sprint(JET.print_report_message, r)
            @test startswith(message, "unsupported combination of keyword arguments `a`, `b` in `kwdispatch(")
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
            _, _ = tpl2
        end
        @test isempty(get_reports(result))
    end
    let result = analyze_call((Pair{Any,Any},)) do pair
            _, _ = pair
        end
        @test isempty(get_reports(result))
    end
    let result = analyze_call((Tuple{Any,Any},)) do tpl2
            _, _, _ = tpl2
        end
        reports = get_reports(result)
        @test length(reports) == 1
        r = only(reports)
        @test r isa BoundsErrorReport && r.a === Tuple{Any,Any} && r.i === 3
    end
    let result = analyze_call((Pair{Any,Any},)) do pair
            _, _, _ = pair
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
kwtyped_dispatch(x::Int; kw::Int=1) = x
kwtyped_dispatch(x::String; kw::String="s") = x
kwtypedfwd(; kws...) = kwtyped(1; kws...)   # forwards slurped keywords
kwtypedbad(; _kws...) = kwtyped(1; kw=2.0)   # slurps but hardcodes a mismatching call
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

        # expectations from different positional branches are combined deterministically
        let result = analyze_call((Union{Int,String},)) do x
                kwtyped_dispatch(x; kw=1.0)
            end
            r = only(get_reports(result))
            @test r isa KeywordTypeErrorReport
            @test r.var === :kw && r.expected === Union{Int,String} && r.got === Float64
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
            @test sprint(JETLS.JET.print_report_message, r) == "TypeError: in `typeassert`, expected `$Int`, got a value of type `Float64`"
        end

        let result = analyze_call() do
                (Int)::String
            end
            reports = get_reports(result)
            @test length(reports) == 1
            r = only(reports)
            @test r isa TypeAssertErrorReport
            @test r.expected === String && r.actual === Type{Int}
            @test sprint(JETLS.JET.print_report_message, r) == "TypeError: in `typeassert`, expected `String`, got Type{$Int}"
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
    let result = analyze_call(call_testtarget_func;
            report_target_modules=(@__MODULE__,TestTargetModule,))
        reports = get_reports(result)
        @test length(reports) == 1
        r = only(reports)
        @test r isa UndefVarErrorReport && r.var == GlobalRef(TestTargetModule, :undefvar)
        @test primary_frame_signature(r) == "func()"
    end
    let result = analyze_call(read_testtarget_unexisting; report_target_modules=(@__MODULE__,))
        reports = get_reports(result)
        @test length(reports) == 1
        r = only(reports)
        @test r isa UndefVarErrorReport && r.var == GlobalRef(TestTargetModule, :unexisting)
        @test primary_frame_signature(r) == "read_testtarget_unexisting()"
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
        @test r isa FieldErrorReport && r.field === :propert
        @test primary_frame_signature(r) == "issue392()"
    end
    let result = analyze_call(issue392; report_target_modules=(ExternalModule,))
        @test isempty(get_reports(result))
    end

    # BoundsErrorReport
    let result = analyze_call(unpack_pair; report_target_modules=(@__MODULE__,))
        reports = get_reports(result)
        @test length(reports) == 1
        r = only(reports)
        @test r isa BoundsErrorReport && r.a === Pair{Any,Any} && r.i === 3
        @test primary_frame_signature(r) == "unpack_pair(pair::Pair{Any, Any})"
    end
    let result = analyze_call((Pair{Any,Any},); report_target_modules=(ExternalModule,)) do pair
            _, _, _ = pair
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

module NativeBoundaryModule
    # these error on the callee frame, and are surfaced at their in-scope call site
    typeassert_error(x::Int) = x::String
    getfield_error(x::Pair{Int,Int}) = getfield(x, :nonexistent)
    # `precompile` puts these specializations into the native inference cache, which is
    # what makes the regression test below exercise the boundary's cache-hit path
    precompile(typeassert_error, (Int,))
    precompile(getfield_error, (Pair{Int,Int},))
end

call_boundary_typeassert(x::Int) = NativeBoundaryModule.typeassert_error(x)
call_boundary_getfield(pair::Pair{Int,Int}) = NativeBoundaryModule.getfield_error(pair)

@testset HierarchicalTestSet "reuse_native_inference" begin
    @testset "analysis cache separation" begin
        # reports are cached within `CodeInstance`s and the boundary suppresses those of
        # out-of-target callees, so the two settings must never share analysis results
        enabled = JETLS.LSAnalyzer(;
            report_target_modules=(@__MODULE__,), reuse_native_inference=true)
        disabled = JETLS.LSAnalyzer(;
            report_target_modules=(@__MODULE__,), reuse_native_inference=false)
        @test JET.AnalysisToken(enabled) !== JET.AnalysisToken(disabled)
    end

    @testset "out-of-target callee errors are still reported" begin
        # Serving an out-of-target callee from the native inference cache would silence
        # reports created on that callee frame, so definitely erroring callees
        # (`rt === Union{}`) must keep taking the analyzer path.
        for reuse_native_inference in (false, true)
            let result = analyze_call(call_boundary_typeassert, (Int,);
                    report_target_modules=(@__MODULE__,), reuse_native_inference)
                r = only(get_reports(result))
                @test r isa TypeAssertErrorReport
                @test r.expected === String && r.actual === Int
            end
            let result = analyze_call(call_boundary_getfield, (Pair{Int,Int},);
                    report_target_modules=(@__MODULE__,), reuse_native_inference)
                r = only(get_reports(result))
                @test r isa FieldErrorReport && r.field === :nonexistent
            end
        end
    end
end

end # module test_LSAnalyzer
