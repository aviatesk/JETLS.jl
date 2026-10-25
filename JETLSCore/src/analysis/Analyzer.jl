module Analyzer

export LSAnalyzer
export declared_argtypes, inference_error_report_related_frames,
    inference_error_report_related_stack, inference_error_report_severity,
    inference_error_report_stack, is_parametric_closure_type,
    reset_report_target_modules!
export AmbiguousMethodReport, BoundsErrorReport, DeprecatedCallReport, FailingTestReport,
    FieldErrorReport, InvokeTypeErrorReport, KeywordTypeErrorReport, MethodErrorReport,
    NoMethodMatchReport, NonBooleanCondErrorReport, TypeAssertErrorReport, TypeErrorReport,
    UndefKeywordErrorReport, UndefVarErrorReport, UnsupportedKeywordArgReport
export RelatedEntryFrame, RelatedFrame, RelatedFrameKind, RelatedOriginFrame, RelatedViaFrame

using Core.IR
using Compiler: Compiler as CC
using JET.JETInterface
using JET: JET

using ..JETLSCore: AnalysisEntry, JETLS_DEV_MODE, deprecated_function_message,
    deprecated_method_message, global_const_value, with_base_render_lock
using ..LSP

# JETLS internal interface
# ========================

function inference_error_report_stack_impl end
function inference_error_report_stack(@nospecialize report::JET.InferenceErrorReport)
    ret = inference_error_report_stack_impl(report)
    if ret isa UnitRange{Int}
        ret = convert(StepRange{Int,Int}, ret)
    else
        ret isa StepRange{Int,Int} ||
            error("Invalid implementation of `inference_error_report_stack_impl`")
    end
    @static JETLS_DEV_MODE && assert_valid_report_stack(report, ret, "display")
    return ret
end
function assert_valid_report_stack(
        @nospecialize(report::JET.InferenceErrorReport), stack, kind::String
    )
    valid = all(idx -> 1 ≤ idx ≤ lastindex(report.vst), stack)
    report_type = typeof(report)
    n = length(report.vst)
    @assert valid lazy"invalid $kind stack for $report_type: stack=$stack, vst length=$n"
end

@enum RelatedFrameKind begin
    RelatedOriginFrame
    RelatedViaFrame
    RelatedEntryFrame
end

struct RelatedFrame
    idx::Int
    kind::RelatedFrameKind
end

function inference_error_report_related_frames(@nospecialize report::JET.InferenceErrorReport)
    stk = inference_error_report_stack(report)
    isempty(stk) && return RelatedFrame[]
    primary = first(stk)
    entry = last(stk)
    origin_stack = inference_error_report_origin_stack(report)
    display_tail = Iterators.drop(stk, 1)
    @static if JETLS_DEV_MODE
        @assert isempty(intersect(origin_stack, display_tail)) lazy"related stack overlap found for $(report)"
    end
    related = RelatedFrame[]
    for idx in origin_stack
        idx == primary && continue
        push!(related, RelatedFrame(idx, RelatedOriginFrame))
    end
    for idx in display_tail
        idx == primary && continue
        kind = idx == entry ? RelatedEntryFrame : RelatedViaFrame
        push!(related, RelatedFrame(idx, kind))
    end
    @static JETLS_DEV_MODE &&
        assert_valid_report_stack(report, map(frame -> frame.idx, related), "related")
    return related
end
function inference_error_report_origin_stack(@nospecialize report::JET.InferenceErrorReport)
    offset = scope_offset(report)
    offset > 0 || return 0:-1:1
    n = length(report.vst)
    first_origin = n - offset + 1
    1 ≤ first_origin ≤ n || return 0:-1:1
    return n:-1:first_origin
end
inference_error_report_severity_impl(@nospecialize _report::JET.InferenceErrorReport) =
    DiagnosticSeverity.Warning
inference_error_report_severity(@nospecialize report::JET.InferenceErrorReport) =
    inference_error_report_severity_impl(report)::DiagnosticSeverity.Ty

"""
    LSAnalyzer <: AbstractAnalyzer

A code analyzer specially designed for the language server.
It is implemented using the `JET.AbstractAnalyzer` framework,
extending the base abstract interpretation performed by the Julia compiler
to detect [`JETLSErrorReport`](@ref)s, along with analyzing types and effects.
"""
struct LSAnalyzer <: ToplevelAbstractAnalyzer
    state::AnalyzerState
    analysis_token::AnalysisToken
    method_table::CC.CachedMethodTable{CC.OverlayMethodTable}

    """
        `LSAnalyzer.report_target_modules::::Union{Nothing,Set{Module}}`

    Configures from which modules reports should be analyzed
    - `report_target_modules === nothing`: Do not filter by module (used by tests)
    - `report_target_modules::Set{Module}`: Only modules included in `report_target_modules`
      will be subject to report analysis
    """
    report_target_modules::Union{Nothing,Set{Module}}

    """
        `LSAnalyzer.reuse_native_inference::Bool`

    When enabled, calls to methods defined outside `report_target_modules` reuse results
    from Julia's native inference cache instead of being analyzed recursively.
    See [`is_native_boundary`](@ref).
    """
    reuse_native_inference::Bool

    invariable_analysis_hash::UInt

    """
        LSAnalyzer(state::AnalyzerState, analysis_token::AnalysisToken, report_target_modules::Set{Module})

    Internal constructor of `LSAnalyzer`.
    Used for both initial construction and creating a new [`LSAnalyzer`](@ref) from an existing one.
    """
    function LSAnalyzer(
            state::AnalyzerState, analysis_token::AnalysisToken,
            report_target_modules::Union{Nothing,Set{Module}}, reuse_native_inference::Bool,
            invariable_analysis_hash::UInt
        )
        method_table = CC.CachedMethodTable(CC.OverlayMethodTable(state.world, JET.JET_METHOD_TABLE))
        return new(state, analysis_token, method_table, report_target_modules,
            reuse_native_inference, invariable_analysis_hash)
    end
end

const incremental_initial_hash = rand(UInt)
const global_mode_hash = rand(UInt)
const lagacy_mode_hash = rand(UInt)

"""
    LSAnalyzer(entry::AnalysisEntry, state::AnalyzerState;
               report_target_modules=missing, reuse_native_inference=false)
        -> analyzer::LSAnalyzer

Internal utility constructor for [`analyzer::LSAnalyzer`](@ref), which initializes
`analyzer.report_target_modules` and `analyzer.analysis_token`.
All new analysis entries should construct `LSAnalyzer` through this method.

`report_target_modules` controls which modules are analyzed:
- `missing`: Use the module list incrementally updated by [`reset_report_target_modules!`](@ref)
- `nothing`: Do not filter by module (used by tests)
- Otherwise: Create `Set{Module}` from an iterator of modules (used by tests).
  Note that test code may also be updated by `reset_report_target_modules!`.
"""
function LSAnalyzer(
        @nospecialize(entry::AnalysisEntry), state::AnalyzerState;
        report_target_modules = missing,
        reuse_native_inference::Bool = false
    )
    # N.B. Separate the cache by the identity of `report_target_modules`.
    if report_target_modules === missing
        report_target_modules = Set{Module}()
        # The case `report_target_modules === missing` is a special case.
        # In this case, `report_target_modules` is tracked incrementally using `reset_report_target_modules!`,
        # but this is only used by the legacy analysis mode, and in that mode,
        # analysis is performed by creating anonymous modules that essentially represent the same module,
        # so there is no need to separate the cache by the identity of those anonymous modules
        report_target_modules_hash = lagacy_mode_hash
    elseif report_target_modules === nothing
        report_target_modules_hash = global_mode_hash
    else
        report_target_modules = Set{Module}(report_target_modules)
        report_target_modules_hash = incremental_initial_hash
        for mod in sort(collect(report_target_modules); by=objectid)
            report_target_modules_hash = hash(mod, report_target_modules_hash)
        end
    end
    # N.B. `reuse_native_inference` participates in the cache key: reports are cached within
    # `CodeInstance`s, and the boundary suppresses those of out-of-target callees, so
    # results must never be shared across the two settings.
    invariable_analysis_hash =
        JET.compute_hash(entry, report_target_modules_hash, reuse_native_inference)
    analysis_cache_key = JET.compute_hash(state.inf_params, invariable_analysis_hash)
    analysis_token = @lock LS_ANALYZER_CACHE_LOCK get!(AnalysisToken, LS_ANALYZER_CACHE, analysis_cache_key)
    return LSAnalyzer(state, analysis_token, report_target_modules, reuse_native_inference,
        invariable_analysis_hash)
end

# AbstractInterpreter API
# =======================

# LSAnalyzer does not need any sources, so discard them always
CC.maybe_compress_codeinfo(::LSAnalyzer, ::MethodInstance, ::CodeInfo) = nothing
CC.may_optimize(::LSAnalyzer) = false
CC.method_table(analyzer::LSAnalyzer) = analyzer.method_table
CC.typeinf_lattice(::LSAnalyzer) =
    CC.InferenceLattice(CC.MustAliasesLattice(CC.BaseInferenceLattice.instance))
CC.ipo_lattice(::LSAnalyzer) =
    CC.InferenceLattice(CC.InterMustAliasesLattice(CC.IPOResultLattice.instance))

let base_ntuple_int_method = which(Base.ntuple, Tuple{Any,Int})
    ntuple_with_unknown_length(f::F, n::Int) where F = Base._ntuple(f, n)
    ntuple_with_unknown_length_source = only(code_lowered(ntuple_with_unknown_length, Tuple{Any,Int}))

    global function CC.InferenceState(
            result::CC.InferenceResult, src::CodeInfo, cache_mode::UInt8,
            analyzer::LSAnalyzer
        )
        # Base's small-n unrolling produces false positives for unknown n (aviatesk/JET.jl#678).
        # Preserve the original body for constant n and the MI so constprop replaces
        # reports from generic inference.
        if result.linfo.def === base_ntuple_int_method && !(result.argtypes[3] isa Const)
            inlining = src.inlining
            src = copy(ntuple_with_unknown_length_source)
            src.parent = result.linfo
            src.inlining = inlining
            CC.maybe_validate_code(result.linfo, src, "lowered")
        end
        return @invoke CC.InferenceState(
            result::CC.InferenceResult, src::CodeInfo, cache_mode::UInt8,
            analyzer::CC.AbstractInterpreter)
    end
end

# AbstractAnalyzer API
# ====================

const empty_target_modules = Set{Module}()
const resolver_hash = rand(UInt)

JETInterface.AnalyzerState(analyzer::LSAnalyzer) = analyzer.state
function JETInterface.AbstractAnalyzer(analyzer::LSAnalyzer, state::AnalyzerState)
    analysis_cache_key = JET.compute_hash(state.inf_params, analyzer.invariable_analysis_hash)
    report_target_modules = analyzer.report_target_modules
    analysis_token = @lock LS_ANALYZER_CACHE_LOCK get!(AnalysisToken, LS_ANALYZER_CACHE, analysis_cache_key)
    return LSAnalyzer(state, analysis_token, report_target_modules,
        analyzer.reuse_native_inference, analyzer.invariable_analysis_hash)
end
JETInterface.AnalysisToken(analyzer::LSAnalyzer) = analyzer.analysis_token

JET.@withmixedhash struct JETLSReportAggregationKey
    T::DataType
    sig::JET.Signature
    primary_frame::JET.VirtualFrameNoLinfo
    origin_frame::JET.VirtualFrameNoLinfo
end
JETInterface.aggregation_policy(::LSAnalyzer) = function (report::JET.InferenceErrorReport)
    @nospecialize report
    stk = inference_error_report_stack(report)
    attribution_idx = isempty(stk) ? lastindex(report.vst) : first(stk)
    return JETLSReportAggregationKey(
        typeof(Base.inferencebarrier(report)),
        report.sig,
        JET.VirtualFrameNoLinfo(report.vst[attribution_idx]),
        JET.VirtualFrameNoLinfo(last(report.vst)))
end

const LS_ANALYZER_CACHE = Dict{UInt,AnalysisToken}()
# `AbstractAnalyzer(::LSAnalyzer, ::AnalyzerState)` takes this lock during inference, while
# Compiler engine reservations owned by the current OS thread may be held. Waiting on a
# `ReentrantLock` may yield and resume the task on another thread, so use a non-yielding
# `SpinLock` instead. Critical sections must stay short and free of yield points, and must
# not re-acquire the lock since `SpinLock` is not reentrant.
const LS_ANALYZER_CACHE_LOCK = Threads.SpinLock()

# internal API
# ============

function reset_report_target_modules!(analyzer::LSAnalyzer, analyzed_files::Dict{String,JET.AnalyzedFileInfo})
    report_target_modules = analyzer.report_target_modules
    isnothing(report_target_modules) && return nothing
    empty!(report_target_modules)
    for (_, analyzed_file_info) in analyzed_files
        for module_range_info in analyzed_file_info.module_range_infos
            push!(report_target_modules, last(module_range_info))
        end
    end
    nothing
end

# utilities
# =========

# Lowering parameterizes a closure type by the types of its captured variables, while the
# types of named functions are never parametric.
function is_parametric_closure_type(@nospecialize typ)
    typ = Base.unwrap_unionall(typ)
    return typ isa DataType && typ <: Function && Base.isgensym(nameof(typ)) &&
        typ.name.wrapper isa UnionAll
end

# The declared types of the arguments of a method with the signature `sig`, as argument types
# to call the method with, or `nothing` if some argument has no declared type, where an
# explicit `::Any` is indistinguishable from no declaration.
function declared_argtypes(@nospecialize sig)
    sig′ = Base.unwrap_unionall(sig)
    sig′ isa DataType || return nothing
    argtypes = Any[]
    for i = 2:length(sig′.parameters)
        param = sig′.parameters[i]
        isva = Base.isvarargtype(param)
        argtype = isva ? Base.unwrapva(param) : param
        while argtype isa TypeVar
            argtype = argtype.ub
        end
        argtype === Any && return nothing
        argtype = Base.rewrap_unionall(argtype, sig)
        CC.has_free_typevars(argtype) && return nothing
        push!(argtypes, isva ? Vararg{argtype} : argtype)
    end
    return argtypes
end

function should_analyze(analyzer::LSAnalyzer, sv::CC.InferenceState)
    report_target_modules = analyzer.report_target_modules
    return isnothing(report_target_modules) || CC.frame_module(sv) ∈ report_target_modules
end

# `vst` offset for a report created unconditionally on the erroring frame `sv`: `0` when `sv`
# is in scope (caller-independent, decided here), else `1` — `sv` is an out-of-scope helper
# (e.g. `getproperty`/`getindex` in `Base`), so the in-scope decision is deferred to
# `collect_callee_reports!` rather than baked into `sv`'s shared cache.
function report_offset(analyzer::LSAnalyzer, sv::CC.InferenceState)
    report_target_modules = analyzer.report_target_modules
    isnothing(report_target_modules) && return 0
    CC.frame_module(sv) ∈ report_target_modules && return 0
    return 1
end

# Inference overloads
# ===================

"""
    bail_out_call(analyzer::LSAnalyzer, ...)

This overload makes call inference performed by `LSAnalyzer` not bail out even when
inferred return type grows up to `Any` to collect as much error reports as possible.
That potentially slows down inference performance, but it would stay to be practical
given that the number of matching methods are limited beforehand.
"""
CC.bail_out_call(::LSAnalyzer, ::CC.InferenceLoopState, ::CC.InferenceState) = false

"""
    bail_out_toplevel_call(analyzer::LSAnalyzer, ...)

This overload allows `LSAnalyzer` to keep inference going on
non-concrete call sites in a toplevel frame created by `JET.virtual_process`.
"""
CC.bail_out_toplevel_call(::LSAnalyzer, ::CC.InferenceState) = false

"""
    bail_out_const_call(analyzer::LSAnalyzer, ...)

The native compiler bails out of constant propagation when the generic inference result is
already proven to be `Bottom` (i.e. the call always throws), since const-prop' cannot
improve the return type any further. For error analysis however, const-prop'ing such a call
is exactly what analyzes the callee frame with the constant arguments and lets it create
precise error reports (e.g. `FieldError` for an `x.field` access with the concrete field
name, including each split of a union-split `getproperty` call), which then surface at the
in-scope call site via `collect_callee_reports!`. This overload keeps const-prop' going in
that case.
This is currently scoped to `getproperty` methods: only the field-error diagnostics benefit
from analyzing always-throwing callees currently, while relaxing the bail-out for every
always-throwing call (`error` etc.) costs roughly +10% of full-analysis time for no
additional reports.
"""
function CC.bail_out_const_call(
        analyzer::LSAnalyzer, result::CC.MethodCallResult, si::CC.StmtInfo,
        match::CC.MethodMatch, sv::CC.InferenceState
    )
    ret = @invoke CC.bail_out_const_call(
        analyzer::ToplevelAbstractAnalyzer, result::CC.MethodCallResult, si::CC.StmtInfo,
        match::CC.MethodMatch, sv::CC.InferenceState)
    if ret && match.method.name === :getproperty && result.rt === Union{}
        return false
    end
    return ret
end

function CC.concrete_eval_eligible(
        analyzer::LSAnalyzer, @nospecialize(f), result::CC.MethodCallResult,
        arginfo::CC.ArgInfo, sv::CC.InferenceState
    )
    res = @invoke CC.concrete_eval_eligible(
        analyzer::ToplevelAbstractAnalyzer, f::Any, result::CC.MethodCallResult,
        arginfo::CC.ArgInfo, sv::CC.InferenceState)
    # Ensure that semi-concrete interpretation is definitely disabled to prevent it from occurring
    return res === :concrete_eval ? res : :none
end
# This overload disables concrete evaluation ad-hoc when concrete evaluation returns `Bottom`
# (i.e., when an error occurs during concrete evaluation) and falls back to constant propagation
# to enable error reporting
function CC.concrete_eval_call(
        analyzer::LSAnalyzer, @nospecialize(f), result::CC.MethodCallResult, arginfo::CC.ArgInfo,
        sv::CC.InferenceState, invokecall::Union{CC.InvokeCall,Nothing}
    )
    res = @invoke CC.concrete_eval_call(
        analyzer::ToplevelAbstractAnalyzer, f::Any, result::CC.MethodCallResult, arginfo::CC.ArgInfo,
        sv::CC.InferenceState, invokecall::Union{CC.InvokeCall,Nothing})
    return res.rt === Union{} ? nothing : res
end

# Native-interpreter boundary (experimental)
# ==========================================

"""
    is_native_boundary(analyzer::LSAnalyzer, method::Method) -> Bool

Whether inference of a call to `method` may be served from Julia's native inference cache
instead of being analyzed, i.e. whether `analyzer.reuse_native_inference` is enabled and
`method` sits outside `analyzer.report_target_modules`. Reports are never collected beyond
that boundary, so it only applies to methods whose reports would be filtered out by
`report_target_modules` anyway.
"""
function is_native_boundary(analyzer::LSAnalyzer, method::Method)
    analyzer.reuse_native_inference || return false
    report_target_modules = analyzer.report_target_modules
    isnothing(report_target_modules) && return false
    return method.module ∉ report_target_modules
end

function CC.typeinf_edge(analyzer::LSAnalyzer,
        method::Method, @nospecialize(atype), sparams::Core.SimpleVector,
        caller::CC.InferenceState, edgecycle::Bool, edgelimited::Bool
    )
    if is_native_boundary(analyzer, method)
        world = CC.get_inference_world(analyzer)
        mi = CC.specialize_method(method, atype, sparams)
        ci = CC.get(CC.WorldView(CC.InternalCodeCache(nothing), world), mi, nothing)
        if ci isa Core.CodeInstance
            rt = CC.cached_return_type(ci)
            # `rt === Union{}` means this callee definitely errors. Let the analyzer infer
            # it so that reports created on the callee frame (builtin errors, which surface
            # at their in-scope call site via `collect_callee_reports!`) are not silenced.
            if rt !== Union{}
                effects = CC.decode_effects(ci.ipo_purity_bits)
                return CC.Future(CC.MethodCallResult(
                    rt, ci.exctype, effects, ci, edgecycle, edgelimited))
            end
        end
    end
    return @invoke CC.typeinf_edge(analyzer::ToplevelAbstractAnalyzer,
        method::Method, atype::Any, sparams::Core.SimpleVector,
        caller::CC.InferenceState, edgecycle::Bool, edgelimited::Bool)
end

# JuliaLang/julia#62359 replaced `codeinst_as_edge` with local inference proofs (v1.14)
@static if isdefined(CC, :codeinst_as_edge)

CC.codeinst_as_edge(
    analyzer::LSAnalyzer, sv::CC.InferenceState, @nospecialize(existing_edge)
) = codeinst_as_shared_edge(analyzer, sv, existing_edge)

# Constant propagation allocates a dummy edge `CodeInstance` whenever the edges of the
# constant-propagated inference differ from those of `existing_edge`, and registers its
# backedges, which keep it alive as long as its callees are. Since the analyses re-infer the
# same code over and over, this piles up equivalent dummy edges, so share one per
# `MethodInstance`, owner and set of edges instead, under the same conditions for reuse as
# `existing_edge`.
const DUMMY_EDGES = IdDict{MethodInstance,Vector{Core.CodeInstance}}()
# `codeinst_as_edge` runs during inference too, so use a `SpinLock` for the same reason as
# `LS_ANALYZER_CACHE_LOCK`.
const DUMMY_EDGES_LOCK = Threads.SpinLock()

function codeinst_as_shared_edge(
        interp::CC.AbstractInterpreter, sv::CC.InferenceState, @nospecialize(existing_edge)
    )
    mi = sv.linfo
    min_world, max_world = first(sv.world.valid_worlds), last(sv.world.valid_worlds)
    if max_world >= CC.get_world_counter()
        max_world = typemax(UInt)
    end
    edges = Core.svec(sv.edges...)
    if (existing_edge isa Core.CodeInstance && existing_edge.min_world >= min_world &&
        existing_edge.max_world <= max_world && existing_edge.edges == edges)
        return existing_edge
    end
    owner = CC.cache_owner(interp)
    if max_world != typemax(UInt)
        return Core.CodeInstance(mi, owner, Any, Any, nothing, nothing, zero(Int32),
            min_world, max_world, zero(UInt32), nothing, nothing, edges)
    end
    return @lock DUMMY_EDGES_LOCK begin
        dummies = get!(Vector{Core.CodeInstance}, DUMMY_EDGES, mi)
        filter!(dummy::Core.CodeInstance -> dummy.max_world == typemax(UInt), dummies)
        idx = findfirst(dummies) do dummy::Core.CodeInstance
            dummy.owner === owner && dummy.min_world >= min_world && dummy.edges == edges
        end
        if idx === nothing
            ci = Core.CodeInstance(mi, owner, Any, Any, nothing, nothing, zero(Int32),
                min_world, max_world, zero(UInt32), nothing, nothing, edges)
            CC.store_backedges(ci, edges)
            push!(dummies, ci)
            ci
        else
            dummies[idx]
        end
    end
end

end # @static if isdefined(CC, :codeinst_as_edge)

# Analysis injections
# ===================

function after_abstract_call_gf_by_type(
        analyzer::LSAnalyzer, ret::CC.Future, @nospecialize(func), arginfo::CC.ArgInfo,
        sv::CC.InferenceState, max_methods::Int
    )
    if !should_analyze(analyzer, sv)
        return nothing
    end
    if func === JET.check_test_value
        report_failing_test!(analyzer, sv, arginfo.argtypes)
    elseif func === JET.check_test_exception
        report_failing_test_exception!(analyzer, sv, arginfo.argtypes)
    end
    func_ref = Ref{Any}(func)
    function _after_abstract_call_gf_by_type(analyzer′::LSAnalyzer, sv′::CC.InferenceState)
        ret′ = ret[]
        func′ = func_ref[]
        kwarg_reported = report_unsupported_kwarg_error!(analyzer′, sv′, func′, ret′, arginfo, max_methods)
        report_method_error!(analyzer′, sv′, ret′, arginfo, kwarg_reported, max_methods)
        report_keyword_typeerror!(analyzer′, sv′, func′, ret′, arginfo, max_methods)
        report_deprecated_call!(analyzer′, sv′, func′, ret′, arginfo)
        return true
    end
    if isready(ret)
        _after_abstract_call_gf_by_type(analyzer, sv)
    else
        push!(sv.tasks, _after_abstract_call_gf_by_type)
    end
    return nothing
end

@static if hasmethod(CC.abstract_call_gf_by_type,
        Tuple{CC.AbstractInterpreter, Any, CC.ArgInfo, CC.StmtInfo, Any,
              Union{Vector{CC.VarState}, Nothing}, CC.AbsIntState, Int})
function CC.abstract_call_gf_by_type(
        analyzer::LSAnalyzer, @nospecialize(func), arginfo::CC.ArgInfo,
        si::CC.StmtInfo, @nospecialize(atype), vtypes::Union{Vector{CC.VarState},Nothing},
        sv::CC.InferenceState, max_methods::Int
    )
    ret = @invoke CC.abstract_call_gf_by_type(
        analyzer::ToplevelAbstractAnalyzer, func::Any, arginfo::CC.ArgInfo,
        si::CC.StmtInfo, atype::Any, vtypes::Union{Vector{CC.VarState},Nothing},
        sv::CC.InferenceState, max_methods::Int)
    after_abstract_call_gf_by_type(analyzer, ret, func, arginfo, sv, max_methods)
    return ret
end
else
function CC.abstract_call_gf_by_type(
        analyzer::LSAnalyzer, @nospecialize(func), arginfo::CC.ArgInfo,
        si::CC.StmtInfo, @nospecialize(atype), sv::CC.InferenceState, max_methods::Int
    )
    ret = @invoke CC.abstract_call_gf_by_type(
        analyzer::ToplevelAbstractAnalyzer, func::Any, arginfo::CC.ArgInfo,
        si::CC.StmtInfo, atype::Any, sv::CC.InferenceState, max_methods::Int)
    after_abstract_call_gf_by_type(analyzer, ret, func, arginfo, sv, max_methods)
    return ret
end
end

function after_abstract_invoke(
        analyzer::LSAnalyzer, ret::CC.Future{CC.CallMeta}, arginfo::CC.ArgInfo,
        sv::CC.InferenceState
    )
    should_analyze(analyzer, sv) || return ret
    function _after_abstract_invoke(
            call::CC.CallMeta, analyzer′::LSAnalyzer, sv′::CC.InferenceState
        )
        sig = report_invoke_method_error!(analyzer′, sv′, call, arginfo)
        report_invoke_type_error!(analyzer′, sv′, call, arginfo)
        argtypes = arginfo.argtypes
        func = length(argtypes) ≥ 2 ? CC.singleton_type(argtypes[2]) : nothing
        report_deprecated_call!(analyzer′, sv′, func, call, arginfo)
        sig === nothing && return call
        return CC.CallMeta(call.rt, call.exct, call.effects, InvokeMethodErrorInfo(sig),
            call.refinements)
    end
    return CC.Future{CC.CallMeta}(_after_abstract_invoke, ret, analyzer, sv)
end

@static if hasmethod(CC.abstract_invoke,
        Tuple{CC.AbstractInterpreter, CC.ArgInfo, CC.StmtInfo,
              Union{Vector{CC.VarState}, Nothing}, CC.AbsIntState})
function CC.abstract_invoke(
        analyzer::LSAnalyzer, arginfo::CC.ArgInfo, si::CC.StmtInfo,
        vtypes::Union{Vector{CC.VarState},Nothing}, sv::CC.InferenceState
    )
    ret = @invoke CC.abstract_invoke(
        analyzer::ToplevelAbstractAnalyzer, arginfo::CC.ArgInfo, si::CC.StmtInfo,
        vtypes::Union{Vector{CC.VarState},Nothing}, sv::CC.AbsIntState)
    return after_abstract_invoke(analyzer, ret, arginfo, sv)
end
else
function CC.abstract_invoke(
        analyzer::LSAnalyzer, arginfo::CC.ArgInfo, si::CC.StmtInfo, sv::CC.InferenceState
    )
    ret = @invoke CC.abstract_invoke(
        analyzer::ToplevelAbstractAnalyzer, arginfo::CC.ArgInfo, si::CC.StmtInfo,
        sv::CC.AbsIntState)
    return after_abstract_invoke(analyzer, ret, arginfo, sv)
end
end

"""
    CC.abstract_eval_new(analyzer::LSAnalyzer, e::Expr, sstate, sv) -> RTEffects

Infers the methods of a closure whose argument types are all declared where the closure is
constructed, if its type is parameterized by the types of its captured variables.

Signature analysis infers the undeclared argument types of a closure method, and the
variables the closure captures, as `Any`, which hides errors and also reports errors for
types that they never have. So it skips the methods of closures with undeclared argument
types and of closures with captured variables (see `JETLSCore.should_analyze_signature`):
- A closure method with undeclared argument types is analyzed only where the analyzed code
  calls it, e.g. a `do` block passed to `mktemp`, and is not analyzed if the analyzed code
  never calls it.
- A closure method whose argument types are all declared, including one without arguments,
  is analyzed here instead, even if the analyzed code never calls it, e.g. a closure
  returned to the caller. Here, the closure type carries the inferred types of the captured
  variables, e.g. `var"#1#2"{Base.Process}`, as `TypeAnnotation` infers a closure rewritten
  to an opaque closure where it is constructed. The reports from the closure method
  propagate to the construction site.

An explicit `::Any` is indistinguishable from no declaration (see
[`declared_argtypes`](@ref)). A closure wrapped in a `Task`, e.g. the body of `@async`,
is also analyzed where the `Task` is constructed (see `JET.analyze_task_parallel_code!`).
"""
function CC.abstract_eval_new(
        analyzer::LSAnalyzer, e::Expr, sstate::CC.StatementState, sv::CC.AbsIntState
    )
    ret = @invoke CC.abstract_eval_new(analyzer::ToplevelAbstractAnalyzer, e::Expr,
        sstate::CC.StatementState, sv::CC.AbsIntState)
    if sv isa CC.InferenceState && should_analyze(analyzer, sv)
        infer_constructed_closure!(analyzer, ret.rt, sstate, sv)
    end
    return ret
end

function infer_constructed_closure!(
        analyzer::LSAnalyzer, @nospecialize(rt), sstate::CC.StatementState,
        sv::CC.InferenceState
    )
    closuretype = CC.widenconst(rt)
    is_parametric_closure_type(closuretype) || return nothing
    matches = @something CC.findall(Tuple{closuretype,Vararg{Any}}, CC.method_table(analyzer)) return nothing
    si = CC.StmtInfo(#=used=#true, sstate.saw_latestworld)
    for match in matches
        argtypes = @something declared_argtypes(match.method.sig) continue
        # Call the closure value rather than its type, so that constant propagation can use
        # the constant values of the captured variables.
        arginfo = CC.ArgInfo(nothing, Any[rt, argtypes...])
        call = CC.abstract_call(analyzer, arginfo, si, sv)
        CC.Future{Any}(call, analyzer, sv) do call, _, sv
            # The construction's statement info is not a call, so retain these edges separately.
            CC.add_edges!(sv.edges, call.info)
            return nothing
        end
    end
    return nothing
end

"""
    CC.widen_call_result(analyzer::LSAnalyzer, si, state, sv) -> Bool

Widens a call result that may be `missing` to `Any` when the `missing` comes from the
loose argument types of signature analysis rather than from the analyzed code itself.

With `x::Any`, `x == :sym` also matches `==(::Missing, ::Any)` and is inferred as
`Union{Bool,Missing}`, so branching on it would be reported as a non-boolean condition
even though `x` is rarely `missing` in practice. Results are widened when the call signature
does not involve `Missing` and either:
- a method specialized on `Missing` matched only because an argument is `Any`
  (see [`is_speculative_missing_match`](@ref)), e.g. `x == :sym` or `max(x, :sym)`, or
- the result may be both `Bool` and `missing` and comes from a method of Base, whose
  three-valued logic returns `missing` when an operation on loosely typed values is inferred
  as `Any`, e.g. `==` for `Vector{Any}` or `Vector{Number}` arguments. Methods whose results
  are served from the native inference cache (see [`is_native_boundary`](@ref)) are treated
  likewise, since the three-valued logic of Base inside them is not widened. Such results
  are kept when the declared field types of the arguments involve `Missing`
  (see [`fields_mention_missing`](@ref)), e.g. `r.flag` for `flag::Union{Missing,Bool}`.

A speculative match also refines its argument slots, e.g. `x & 0x0f` refines `x::Any` to
`Union{Missing,Integer}`. Refinements that include `Missing` are dropped whenever such a
match exists, even if the result itself is not widened or is unused, so that `x` is not
reported as possibly `missing` afterwards.

Other `missing` results, e.g. of a parser returning `missing` for invalid input, are kept
even for loosely typed arguments.

Whether a result is widened must not depend on how precisely it is inferred, since a widened
result of constant propagation is discarded in favor of the result inferred without the
constants when the latter is not widened. Hence results that also include other types, e.g.
`Union{Bool,Int,Missing}`, are widened as well.
"""
function CC.widen_call_result(
        analyzer::LSAnalyzer, si::CC.StmtInfo, state::CC.CallInferenceState,
        sv::CC.AbsIntState
    )
    matches = state.matches
    mentions = call_signature_mentions_missing(matches)
    speculative = !mentions && has_speculative_missing_match(matches)
    if speculative
        # `widen_call_result` is called after the slot refinements are computed and before
        # they are stored in the resulting `CallMeta`. Drop them before the default check
        # below, which returns early for unused call results.
        drop_missing_slot_refinements!(state)
    end
    @invoke(CC.widen_call_result(analyzer::ToplevelAbstractAnalyzer, si::CC.StmtInfo,
        state::CC.CallInferenceState, sv::CC.AbsIntState)) && return true
    mentions && return false
    has_missing_member(state.rettype) || return false
    speculative && return true
    return Bool <: CC.widenconst(state.rettype) &&
        has_base_or_native_method_match(analyzer, matches) &&
        !call_signature_fields_mention_missing(matches)
end

call_signature_mentions_missing(matches::CC.MethodMatches) =
    mentions_missing(matches.info.atype)
call_signature_mentions_missing(matches::CC.UnionSplitMethodMatches) =
    any(info::CC.MethodMatchInfo -> mentions_missing(info.atype), matches.info.split)

# bounds the recursion into deeply nested type parameters
const MAX_TYPE_PARAMETER_DEPTH = 8

# Whether `Missing` appears in `t`, including union components, type parameters and the
# upper bounds of type variables, e.g. `AbstractVector{<:Union{Missing,Int}}`.
function mentions_missing(@nospecialize(t), depth::Int = 0)
    depth > MAX_TYPE_PARAMETER_DEPTH && return false
    t === Missing && return true
    if t isa Union
        return mentions_missing(t.a, depth) || mentions_missing(t.b, depth)
    elseif t isa UnionAll
        return mentions_missing(Base.unwrap_unionall(t), depth)
    elseif t isa TypeVar
        return mentions_missing(t.ub, depth)
    elseif t isa Core.TypeofVararg
        return isdefined(t, :T) && mentions_missing(t.T, depth + 1)
    elseif t isa DataType
        params = t.parameters
        for i = 1:length(params)
            # skip repeated parameters, e.g. of `NTuple{128,T}`, which would otherwise make
            # the traversal exponential in the depth
            i > 1 && params[i] === params[i-1] && continue
            mentions_missing(params[i], depth + 1) && return true
        end
    end
    return false
end

has_speculative_missing_match(matches::CC.MethodMatches) =
    has_speculative_missing_match(matches.info)
has_speculative_missing_match(matches::CC.UnionSplitMethodMatches) =
    any(has_speculative_missing_match, matches.info.split)
has_speculative_missing_match(info::CC.MethodMatchInfo) =
    any(match::Core.MethodMatch -> is_speculative_missing_match(info.atype, match), info.results)

"""
    is_speculative_missing_match(atype, match::Core.MethodMatch) -> Bool

Returns whether the method of `match` is declared with `::Missing` at a position where the
call signature `atype` has `Any`, i.e. whether it matched only because the argument type is
unknown, like `==(::Missing, ::Any)` for `x == :sym` with `x::Any`.
"""
function is_speculative_missing_match(@nospecialize(atype), match::Core.MethodMatch)
    sig = Base.unwrap_unionall(atype)
    msig = Base.unwrap_unionall(match.method.sig)
    (sig isa DataType && msig isa DataType) || return false
    argtypes, params = sig.parameters, msig.parameters
    for i = 1:min(length(argtypes), length(params))
        argtype, param = argtypes[i], params[i]
        (argtype isa Core.TypeofVararg || param isa Core.TypeofVararg) && return false
        argtype === Any && param === Missing && return true
    end
    return false
end

function drop_missing_slot_refinements!(state::CC.CallInferenceState)
    refinements = state.slotrefinements
    refinements === nothing && return nothing
    for i = eachindex(refinements)
        refinement = refinements[i]
        if refinement !== nothing && has_missing_member(refinement)
            refinements[i] = nothing
        end
    end
    return nothing
end

function has_missing_member(@nospecialize t)
    t = CC.widenconst(t)
    return t isa Union && any(@nospecialize(u)->u===Missing, Base.uniontypes(t))
end

has_base_or_native_method_match(analyzer::LSAnalyzer, matches::CC.MethodMatches) =
    has_base_or_native_method_match(analyzer, matches.info)
has_base_or_native_method_match(analyzer::LSAnalyzer, matches::CC.UnionSplitMethodMatches) =
    any(info -> has_base_or_native_method_match(analyzer, info), matches.info.split)
has_base_or_native_method_match(analyzer::LSAnalyzer, info::CC.MethodMatchInfo) =
    any(info.results) do match
        method = match.method
        return Base.moduleroot(method.module) === Base ||
            is_native_boundary(analyzer, method)
    end

call_signature_fields_mention_missing(matches::CC.MethodMatches) =
    fields_mention_missing(matches.info.atype)
call_signature_fields_mention_missing(matches::CC.UnionSplitMethodMatches) =
    any(info::CC.MethodMatchInfo -> fields_mention_missing(info.atype), matches.info.split)

"""
    fields_mention_missing(t) -> Bool

Returns whether `Missing` appears in the declared field types of `t` or of its type
parameters, e.g. `Vector{Row}` for `struct Row; flag::Union{Missing,Bool}; end`, which
covers fields read by Base functions, e.g. `getproperty`, or by callbacks passed to them,
e.g. `all(r -> r.flag, rows)`, including those captured by closures.
Fields of fields are not checked, since large objects often involve `Missing` somewhere deep.
"""
function fields_mention_missing(@nospecialize(t), depth::Int = 0)
    depth > MAX_TYPE_PARAMETER_DEPTH && return false
    if t isa Union
        return fields_mention_missing(t.a, depth) || fields_mention_missing(t.b, depth)
    elseif t isa UnionAll
        return fields_mention_missing(Base.unwrap_unionall(t), depth)
    elseif t isa TypeVar
        return fields_mention_missing(t.ub, depth)
    elseif t isa Core.TypeofVararg
        return isdefined(t, :T) && fields_mention_missing(t.T, depth + 1)
    elseif t isa DataType
        # the fields of `Tuple` and `NamedTuple` are their type parameters
        if isstructtype(t) && !(t <: Union{Tuple,NamedTuple})
            for ft in Base.datatype_fieldtypes(t)
                ft <: Type && continue # a field holding a type is never `missing`
                mentions_missing(ft) && return true
            end
        end
        params = t.parameters
        for i = 1:length(params)
            i > 1 && params[i] === params[i-1] && continue # see `mentions_missing`
            fields_mention_missing(params[i], depth + 1) && return true
        end
    end
    return false
end

# TODO Better to factor out and share it with `JET.JETAnalyzer`
function CC.abstract_eval_globalref(
        analyzer::LSAnalyzer, g::GlobalRef, saw_latestworld::Bool, sv::CC.InferenceState;
        allowed_offset::Int = 1
    )
    if saw_latestworld
        return CC.RTEffects(Any, Any, CC.generic_getglobal_effects)
    end
    (valid_worlds, ret) = CC.scan_leaf_partitions(analyzer, g, sv.world) do analyzer::LSAnalyzer, binding::Core.Binding, partition::Core.BindingPartition
        offset = report_offset(analyzer, sv)
        if offset ≤ allowed_offset
            if partition.min_world ≤ sv.world.this ≤ partition.max_world # XXX This should probably be fixed on the Julia side
                report_undef_global_var!(analyzer, sv, binding, partition, offset)
            end
        end
        CC.abstract_eval_partition_load(analyzer, binding, partition)
    end
    CC.update_valid_age!(sv, valid_worlds)
    return ret
end

function CC.builtin_tfunction(analyzer::LSAnalyzer,
    @nospecialize(f), argtypes::Vector{Any}, sv::CC.InferenceState) # `AbstractAnalyzer` isn't overloaded on `return_type`
    ret = @invoke CC.builtin_tfunction(analyzer::ToplevelAbstractAnalyzer,
        f::Any, argtypes::Vector{Any}, sv::CC.InferenceState)
    if f === fieldtype
        # the valid widest possible return type of `fieldtype_tfunc` is `Union{Type,TypeVar}`
        # because fields of unwrapped `DataType`s can legally be `TypeVar`s,
        # but this will lead to lots of false positive `NoMethodMatchReport`s for inference
        # with accessing to abstract fields since most methods don't expect `TypeVar`
        # (e.g. `@report_call readuntil(stdin, 'c')`)
        # JET.jl further widens this case to `Any` and give up further analysis rather than
        # trying hard to do sound and noisy analysis
        # xref: https://github.com/JuliaLang/julia/pull/38148
        if ret === Union{Type, TypeVar}
            ret = Any
        end
    end
    if ret === Union{}
        # Gate on `ret === Union{}` first so valid builtins (the common case) skip all report
        # work. Report unconditionally on the erroring frame `sv`; for an out-of-scope `sv`
        # (offset 1) the `report_target_modules` check is deferred to `collect_callee_reports!`
        # as the report propagates to its in-scope call site, so it is not baked into the cache.
        offset = report_offset(analyzer, sv)
        report_builtin_error!(analyzer, sv, f, argtypes, offset)
    end
    return ret
end

function CC.abstract_eval_special_value(analyzer::LSAnalyzer, @nospecialize(e), sstate::CC.StatementState, sv::CC.InferenceState)
    # GlobalRefs directly embedded in source code are analyzed with allowed_offset=0
    if e isa GlobalRef
        return CC.abstract_eval_globalref(analyzer, e, sstate.saw_latestworld, sv; allowed_offset=0)
    end
    return @invoke CC.abstract_eval_special_value(analyzer::ToplevelAbstractAnalyzer, e::Any, sstate::CC.StatementState, sv::CC.InferenceState)
end

function CC.abstract_eval_value(analyzer::LSAnalyzer, @nospecialize(e), sstate::CC.StatementState, sv::CC.InferenceState)
    ret = @invoke CC.abstract_eval_value(analyzer::ToplevelAbstractAnalyzer, e::Any, sstate::CC.StatementState, sv::CC.InferenceState)
    if should_analyze(analyzer, sv)
        stmt = JET.get_stmt((sv, JET.get_currpc(sv)))
        if isa(stmt, GotoIfNot)
            t = CC.widenconst(ret)
            if t !== Union{}
                report_non_boolean_cond!(analyzer, sv, t)
            end
        end
    end
    return ret
end

function CC.finish!(analyzer::LSAnalyzer, caller::CC.InferenceState, validation_world::UInt, time_before::UInt64)
    # An `UndefKeywordError` thrown on a path that does not make the enclosing frame diverge
    # was not actually taken (e.g. `f(; nt...)` lowers to a branch calling `f()` only when
    # `nt` is empty), so drop such reports and keep only definitely-missing keyword calls.
    # `finish!` runs after `finishinfer!`, and (for cycles) after every cycle member's
    # `finishinfer!`, so `caller.bestguess` is the converged return type here. Unwrap
    # `LimitedAccuracy` so a recursion-limited but diverging frame still keeps the report.
    # `KeywordTypeErrorReport` is not filtered here: it has no empty-`nt` branch to fire
    # on spuriously, so a type mismatch on a conditional path is a real error.
    if CC.ignorelimited(caller.bestguess) !== Union{}
        filter!(JET.get_reports(analyzer, caller.result)) do @nospecialize(report)
            return !(report isa UndefKeywordErrorReport)
        end
    end
    return @invoke CC.finish!(analyzer::ToplevelAbstractAnalyzer, caller::CC.InferenceState,
        validation_world::UInt, time_before::UInt64)
end

# Detect `UndefKeywordError` at the `throw` inside the synthesized keyword sorter and store
# the report unconditionally on that (caller-independent) frame; see `report_undef_keyword!`.
function CC.abstract_throw(
        analyzer::LSAnalyzer, argtypes::Vector{Any}, sv::CC.InferenceState
    )
    report_undef_keyword!(analyzer, sv, argtypes)
    return @invoke CC.abstract_throw(
        analyzer::ToplevelAbstractAnalyzer, argtypes::Vector{Any}, sv::CC.InferenceState)
end

# Apply the `report_target_modules` filter as reports propagate into the caller `sv`, not at
# creation — so it is never written to the callee cache. A report with positive
# `scope_offset` is dropped here when `sv` (its call site) is out of scope;
# offset `0` means the decision was already made at creation, so it is kept.
function JET.collect_callee_reports!(analyzer::LSAnalyzer, sv::CC.InferenceState)
    reports = JET.get_report_stash(analyzer)
    if !isempty(reports)
        if JET.isconcretized(analyzer, sv)
            # Concrete execution owns diagnostics for this call, but the callee cache
            # must retain its reports for non-concretized callers.
            empty!(reports)
            return nothing
        end
        vf = JET.get_virtual_frame(sv)
        for report in reports
            offset = scope_offset(report)
            if offset > 0 && length(report.vst) == offset && !should_analyze(analyzer, sv)
                continue # at the (out-of-scope) call-site frame: drop instead of propagating
            end
            pushfirst!(report.vst, vf)
            add_new_report!(analyzer, sv.result, report)
        end
        empty!(reports)
    end
    return nothing
end

# `vst_offset` of a report subject to the propagation-time `report_target_modules` filter, or
# `-1` for reports not created unconditionally (whose in-scope decision is made at creation).
# Methods for the concrete report types are defined after those structs below.
scope_offset(@nospecialize report::JET.InferenceErrorReport) = scope_offset_impl(report)::Int
scope_offset_impl(@nospecialize _report::JET.InferenceErrorReport) = -1

# analysis
# ========

"""
    JETLSErrorReport <: InferenceErrorReport

Abstract type for error reports analyzed by [`LSAnalyzer`](@ref).

Subtypes:
- `UndefVarErrorReport`: Undefined global bindings (corresponding to `UndefVarError`)
- `FieldErrorReport`: Access to non-existent struct fields (corresponding to `FieldError`)
- `BoundsErrorReport`: Out-of-bounds field access by index (corresponding to `BoundsError`)
- `MethodErrorReport`: Errors that raise `MethodError` at runtime
  * `NoMethodMatchReport`: No matching method for a call (a dispatch failure)
  * `AmbiguousMethodReport`: Multiple applicable methods without a unique match
  * `UnsupportedKeywordArgReport`: Keyword arguments the method does not accept
    (raised via `Base.kwerr`)
- `UndefKeywordErrorReport`: Missing required keyword arguments
  (corresponding to `UndefKeywordError`)
- `TypeErrorReport`: Errors that raise `TypeError` at runtime
  * `TypeAssertErrorReport`: Statically failing type assertions
  * `NonBooleanCondErrorReport`: Non-boolean value in a boolean context
  * `KeywordTypeErrorReport`: Keyword argument value type mismatch
  * `InvokeTypeErrorReport`: Invalid signature or argument types for `invoke`
- `FailingTestReport`: Top-level `@test`s that always fail
- `DeprecatedCallReport`: Calls to methods deprecated with `@deprecate`
"""
abstract type JETLSErrorReport <: InferenceErrorReport end
abstract type MethodErrorReport <: JETLSErrorReport end
abstract type TypeErrorReport <: JETLSErrorReport end

# UndefVarErrorReport
# -------------------

@jetreport struct UndefVarErrorReport <: JETLSErrorReport
    var::Union{GlobalRef,TypeVar}
    maybeundef::Bool
    vst_offset::Int
end
function JETInterface.print_report_message(io::IO, r::UndefVarErrorReport)
    var = r.var
    if isa(var, TypeVar) # TODO show "maybe undefined" case nicely?
        print(io, "`", var.name, "` not defined in static parameter matching")
    else
        print(io, "`", var.mod, '.', var.name, "`")
        if r.maybeundef
            print(io, " may be undefined")
        else
            print(io, " is not defined")
        end
    end
end
inference_error_report_stack_impl(r::UndefVarErrorReport) = (length(r.vst)-r.vst_offset):-1:1
inference_error_report_severity_impl(r::UndefVarErrorReport) =
    r.maybeundef ? DiagnosticSeverity.Information : DiagnosticSeverity.Warning
scope_offset_impl(r::UndefVarErrorReport) = r.vst_offset

function report_undef_global_var!(
        analyzer::LSAnalyzer, sv::CC.InferenceState, binding::Core.Binding, partition::Core.BindingPartition,
        offset::Int
    )
    gr = binding.globalref
    # Read constants from `partition` itself: JET defines constants in a world newer than
    # `sv.world`, and `getglobal` warns about such backdated constants.
    if CC.is_defined_const_binding(CC.binding_kind(partition))
        # HACK/FIXME Concretize `AbstractBindingState`
        x = CC.partition_restriction(partition)
        x isa JET.AbstractBindingState || return false
        binding_state = x
    elseif Base.invoke_in_world(sv.world.this, isdefinedglobal, gr.mod, gr.name)
        return false
    else
        binding_states = JET.get_binding_states(analyzer)
        binding_state = get(binding_states, partition, nothing)
    end
    maybeundef = false
    if binding_state !== nothing
        binding_state.maybeundef || return false
        maybeundef = true
    end
    add_new_report!(analyzer, sv.result, UndefVarErrorReport(sv, gr, maybeundef, offset))
    return true
end

@jetreport struct FieldErrorReport <: JETLSErrorReport
    @nospecialize type
    field::Symbol
    vst_offset::Int
end
function JETInterface.print_report_message(io::IO, r::FieldErrorReport)
    typ = r.type::Union{UnionAll,DataType}
    flds = join(map(n->"`$n`", fieldnames(typ)), ", ")
    if typ <: Tuple
        typ = Tuple # reproduce base error message
    end
    @static if VERSION ≥ v"1.12.0-beta4.14"
        # JuliaLang/julia#58507
        typ = Base.unwrap_unionall(typ)::DataType
        tname = string(typ.name.wrapper)
    else
        tname = nameof(typ)
    end
    return print(io, lazy"FieldError: type `$tname` has no field `$(r.field)`, available fields: $flds")
end
inference_error_report_stack_impl(r::FieldErrorReport) = (length(r.vst)-r.vst_offset):-1:1
inference_error_report_severity_impl(::FieldErrorReport) = DiagnosticSeverity.Warning
scope_offset_impl(r::FieldErrorReport) = r.vst_offset

@jetreport struct BoundsErrorReport <: JETLSErrorReport
    @nospecialize a
    i::Int
    vst_offset::Int
end
JETInterface.print_report_message(io::IO, r::BoundsErrorReport) =
    print(io, lazy"BoundsError: attempt to access $(r.a) at index [$(r.i)]")
inference_error_report_stack_impl(r::BoundsErrorReport) = (length(r.vst)-r.vst_offset):-1:1
inference_error_report_severity_impl(::BoundsErrorReport) = DiagnosticSeverity.Warning
scope_offset_impl(r::BoundsErrorReport) = r.vst_offset

# TypeAssertErrorReport
# ---------------------

@jetreport struct TypeAssertErrorReport <: TypeErrorReport
    @nospecialize expected
    @nospecialize actual
    vst_offset::Int
end
inference_error_report_stack_impl(r::TypeAssertErrorReport) = (length(r.vst)-r.vst_offset):-1:1
inference_error_report_severity_impl(::TypeAssertErrorReport) = DiagnosticSeverity.Warning
scope_offset_impl(r::TypeAssertErrorReport) = r.vst_offset

function JETInterface.print_report_message(io::IO, r::TypeAssertErrorReport)
    (; expected, actual) = r
    print(io, "TypeError: in `typeassert`, expected `", expected, "`, got ")
    if CC.isType(actual)
        print(io, actual)
    else
        print(io, "a value of type `", actual, '`')
    end
end

function print_type_error_got(io::IO, @nospecialize(actual))
    if CC.isType(actual)
        print(io, actual)
    else
        print(io, "a value of type `", actual, '`')
    end
end

function report_typeassert_error!(
        analyzer::LSAnalyzer, sv::CC.InferenceState, argtypes::Vector{Any}, offset::Int
    )
    length(argtypes) == 2 || return false
    valtyp, asserttyp = argtypes

    expected = CC.instanceof_tfunc(asserttyp, true)[1]
    if expected === Union{}
        actual = CC.widenconst(asserttyp)
        actual === Union{} && return false
        add_new_report!(analyzer, sv.result, TypeAssertErrorReport(sv, Type, actual, offset))
        return true
    end

    actual = CC.widenconst(valtyp)
    actual === Union{} && return false
    CC.hasintersect(actual, expected) && return false
    add_new_report!(analyzer, sv.result, TypeAssertErrorReport(sv, expected, actual, offset))
    return true
end

function report_builtin_error!(
        analyzer::LSAnalyzer, sv::CC.InferenceState, @nospecialize(f),
        argtypes::Vector{Any}, offset::Int
    )
    if f === getfield
        report_fieldaccess!(analyzer, sv, getfield, argtypes, offset)
    elseif f === setfield!
        report_fieldaccess!(analyzer, sv, setfield!, argtypes, offset)
    elseif f === fieldtype
        report_fieldaccess!(analyzer, sv, fieldtype, argtypes, offset)
    elseif f === typeassert
        report_typeassert_error!(analyzer, sv, argtypes, offset)
    end
end

# const MODULE_SETFIELD_MSG = "cannot assign variables in other modules"
# type_error_msg(f, expected, actual) = (@nospecialize;
#     lazy"TypeError: in $f, expected $expected, got a value of type $actual")

function report_fieldaccess!(
        analyzer::LSAnalyzer, sv::CC.InferenceState, @nospecialize(f), argtypes::Vector{Any},
        offset::Int
    )
    2 ≤ length(argtypes) ≤ 3 || return false

    issetfield! = f === setfield!
    obj, name = argtypes[1], argtypes[2]
    s00 = CC.widenconst(obj)

    if issetfield!
        if !CC._mutability_errorcheck(s00)
            # msg = lazy"setfield!: immutable struct of type $s00 cannot be changed"
            # report = BuiltinErrorReport(sv, setfield!, msg, offset)
            # add_new_report!(analyzer, sv.result, report)
            return true
        end
    end

    isa(name, Const) || return false
    s = Base.unwrap_unionall(s00)
    if CC.isType(s)
        if f === fieldtype
            # XXX this is a hack to share more code between `getfield`/`setfield!`/`fieldtype`
            s = s.parameters[1]
        elseif CC.isconstType(s)
            s = (s00::DataType).parameters[1]
        else
            return false
        end
    end
    isa(s, DataType) || return false
    isabstracttype(s) && return false
    if s <: Module
        if issetfield!
            # report = BuiltinErrorReport(sv, setfield!, MODULE_SETFIELD_MSG)
            # add_new_report!(analyzer, sv.result, report, offset)
            return true
        end
        nametyp = CC.widenconst(name)
        if !CC.hasintersect(nametyp, Symbol)
            # msg = type_error_msg(getglobal, Symbol, nametyp)
            # report = BuiltinErrorReport(sv, getglobal, msg)
            # add_new_report!(analyzer, sv.result, report, offset)
            return true
        end
    end
    fidx = CC._getfield_fieldindex(s, name)
    if fidx !== nothing
        nf = length(Base.datatype_fieldtypes(s))
        1 ≤ fidx ≤ nf && return false
    end

    namev = (name::Const).val
    objtyp = s
    if namev isa Symbol
        if f === getfield
            offset = direct_transparent_getproperty_offset(sv, offset)
        end
        add_new_report!(analyzer, sv.result, FieldErrorReport(sv, objtyp, namev, offset))
    elseif namev isa Int
        add_new_report!(analyzer, sv.result, BoundsErrorReport(sv, objtyp, namev, offset))
    else error("invalid field analysis") end
    return true
end

# TODO Replace this hack with a general report provenance attribution system

function direct_transparent_getproperty_offset(sv::CC.InferenceState, offset::Int)
    is_direct_transparent_getproperty_getfield(sv) || return offset
    return max(offset, 1)
end

function is_direct_transparent_getproperty_getfield(sv::CC.InferenceState)
    def = sv.linfo.def
    def isa Method || return false
    def.name === :getproperty || return false
    length(sv.slottypes) ≥ 3 || return false
    pc = JET.get_currpc(sv)
    stmt = sv.src.code[pc]
    Meta.isexpr(stmt, :call) || return false
    length(stmt.args) == 3 || return false
    seen_slots = BitSet()
    receiver = @something transparent_getproperty_slot_id!(seen_slots, stmt.args[2], sv, pc) return false
    receiver == 2 || return false
    field = @something transparent_getproperty_slot_id!(seen_slots, stmt.args[3], sv, pc) return false
    field == 3 || return false
    return true
end

function transparent_getproperty_slot_id!(
        seen_slots::BitSet, @nospecialize(x), sv::CC.InferenceState, pc::Int
    )
    while true
        slot = CC.ssa_def_slot(x, sv)
        slot isa SlotNumber || return nothing
        slot.id ≤ 3 && return slot.id
        slot.id ∈ seen_slots && return nothing
        push!(seen_slots, slot.id)
        pc_assign = @something CC.find_dominating_assignment(slot.id, pc, sv) return nothing
        stmt = sv.src.code[pc_assign]
        if Meta.isexpr(stmt, :(=)) && length(stmt.args) == 2
            lhs, rhs = stmt.args
            if lhs isa SlotNumber && lhs.id == slot.id
                x = rhs
                pc = pc_assign
                continue
            end
        end
        return nothing
    end
end

# NoMethodMatchReport
# -------------------

@jetreport struct NoMethodMatchReport <: MethodErrorReport
    @nospecialize t # ::Union{Type, Vector{Type}}
    union_split::Int
    world::UInt
end
JETInterface.print_report_message(io::IO, report::NoMethodMatchReport) =
    print_no_method_match_report(io, report)
inference_error_report_stack_impl(r::NoMethodMatchReport) = length(r.vst):-1:1
inference_error_report_severity_impl(::NoMethodMatchReport) = DiagnosticSeverity.Warning

function print_no_method_match_report(io::IO, report::NoMethodMatchReport)
    print(io, "MethodError: no matching method found ")
    if report.union_split == 0
        t = report.t
        print_callsig(io, t)
        print_no_method_hint(io, t, report.world)
    else
        ts = report.t::Vector{Any}
        nts = length(ts)
        for i = 1:nts
            print_callsig(io, ts[i])
            i == nts || print(io, ", ")
        end
        print(io, " (", nts, '/', report.union_split, " union split)")
        for t in ts
            print_no_method_hint(io, t, report.world; labeled = nts > 1)
        end
    end
end

function print_callsig(io, @nospecialize(t))
    print(io, '`')
    Base.show_tuple_as_call(io, Symbol(""), t)
    print(io, '`')
end

# The hint printers feed arbitrary inference signatures into `Base` printing internals
# that were designed for runtime values, so guard against unexpected inputs here to
# avoid breaking the whole diagnostics generation.
function print_no_method_hint(
        io::IO, @nospecialize(t), world::UInt; labeled::Bool = false
    )
    hint = try
        sprint(print_no_method_hint_impl, t, world, labeled; context=io)
    catch
        JETLS_DEV_MODE && rethrow()
        return
    end
    print(io, hint)
end

function print_no_method_hint_impl(
        io::IO, @nospecialize(t), world::UInt, labeled::Bool
    )
    t′ = Base.unwrap_unionall(t)
    t′ isa DataType && t′ <: Tuple || return
    params = t′.parameters
    isempty(params) && return
    Base.isvarargtype(params[1]) && return
    ftype = Base.rewrap_unionall(params[1], t)
    f = CC.singleton_type(ftype)
    if f === nothing
        ftype′ = Base.unwrap_unionall(ftype)
        if ftype′ isa DataType && CC.isType(ftype)
            typ = ftype′.parameters[1]
            typ isa Type && (f = typ)
        end
    end
    argparams = params[2:end]
    # `Base.show_method_candidates` and `method_candidate_score` cannot handle `Vararg`
    # in the argument types, so use the fixed-length prefix of the signature
    if !isempty(argparams) && Base.isvarargtype(argparams[end])
        argparams = argparams[1:end-1]
    end
    arg_types = Base.rewrap_unionall(Tuple{argparams...}, t)
    f isa Core.Builtin && return
    # keyword no-match calls surface as `Core.kwcall` signatures, for which candidates
    # from `kwcall`'s own method table would be meaningless
    f === Core.kwcall && return
    if labeled
        print(io, "\n\nFor ")
        print_callsig(io, t)
        print(io, ':')
    end
    if f isa Function
        print(io, "\n\nThe function `", f,
            "` exists, but no method is defined for this combination of argument types.")
    elseif f isa Type
        if f isa DataType && isabstracttype(f) && !has_methods_at_world(f, world)
            print(io, "\n\nNo constructors have been defined for `", f, "`.")
            return
        end
        print(io, "\n\nThe type `", f,
            "` exists, but no method is defined for this combination of argument types ",
            "when trying to construct it.")
    elseif f === nothing
        candidates = find_callable_candidate_methods(ftype)
        if candidates !== nothing && isempty(candidates)
            print(io, "\n\nObjects of type `", ftype, "` are not callable.")
            return
        end
        print(io, "\n\nThe object of type `", ftype,
            "` exists, but no method is defined for this combination of argument types ",
            "when trying to treat it as a callable object.")
        if candidates !== nothing
            print_callable_method_candidates(io, candidates, arg_types, world)
        end
        return
    else
        if !has_methods_at_world(f, world)
            print(io, "\n\nObjects of type `", typeof(f), "` are not callable.")
            return
        end
        print(io, "\n\nThe object of type `", typeof(f),
            "` exists, but no method is defined for this combination of argument types ",
            "when trying to treat it as a callable object.")
    end
    exception = MethodError(f, arg_types, world)
    candidates = with_base_render_lock(sprint, Base.show_method_candidates, exception;
            context=io)
    print_bulleted_method_candidates(io, candidates)
    return nothing
end

function has_methods_at_world(@nospecialize(f), world::UInt)
    matches = Base._methods(f, Tuple{Vararg{Any}}, -1, world)::Vector
    return !isempty(matches)
end

function print_callable_method_candidates(
        io::IO, methods::Vector{Method}, @nospecialize(arg_types), world::UInt
    )
    arg_types′ = Base.unwrap_unionall(arg_types)
    arg_types′ isa DataType && arg_types′ <: Tuple || return nothing
    params = Any[Base.rewrap_unionall(param, arg_types) for param in arg_types′.parameters]
    scores = Int[method_candidate_score(method, params) for method in methods]
    order = sortperm(scores)
    print(io, "\n\nClosest candidates are:")
    ncandidates = min(3, length(order))
    for i = 1:ncandidates
        print(io, '\n')
        print_method_candidate(io, methods[order[i]]; world)
    end
    length(order) > ncandidates && print(io, "\n- ...")
    return nothing
end

# Ranking the closest candidates needs all of them, which is expensive and pointless for
# broad callable types like `Type` with thousands of methods, while callable objects usually
# have only a few. With this limit, the lookup bails out as soon as it is exceeded, and
# ranking up to this many candidates takes under a millisecond, once per report message.
const CALLABLE_CANDIDATE_MAX_METHODS = 100

# Returns `nothing` when the applicable methods cannot be enumerated (too broad a
# callable type or too many matches), and an empty vector when `ftype` has no methods
# at all, i.e. its instances are not callable.
function find_callable_candidate_methods(@nospecialize(ftype))
    ftype′ = Base.unwrap_unionall(ftype)
    ftype′ isa DataType || return nothing
    ftype′ === Any && return nothing
    ftype′ === Function && return nothing
    callsig = Tuple{ftype,Vararg{Any}}
    matches = @something Base._methods_by_ftype(callsig, nothing,
        CALLABLE_CANDIDATE_MAX_METHODS, Base.get_world_counter()) return nothing
    methods = Method[]
    for match in matches
        match = match::Core.MethodMatch
        match.method ∈ methods || push!(methods, match.method)
    end
    return methods
end

function method_candidate_score(method::Method, arg_types::Vector{Any})
    sig = Base.unwrap_unionall(method.sig)::DataType
    sigtypes = sig.parameters[2:end]
    input_types = copy(arg_types)
    right_matches = 0
    for i = 1:min(length(input_types), length(sigtypes))
        j = Base.isvarargtype(sigtypes[i]) ? length(input_types) : i
        method_prefix = Base.rewrap_unionall(Tuple{sigtypes[1:i]...}, method.sig)
        input_prefix = Base.rewrap_unionall(Tuple{input_types[1:j]...}, method.sig)
        if typeintersect(method_prefix, input_prefix) === Union{}
            input_types[i] = sigtypes[i]
        else
            right_matches += j == i
        end
    end
    if length(input_types) > length(sigtypes) &&
       !isempty(sigtypes) && Base.isvarargtype(sigtypes[end])
        vararg_type = Base.rewrap_unionall(Base.unwrapva(Base.unwrap_unionall(sigtypes[end])), method.sig)
        # iterate the original `arg_types` here: `input_types` may contain `Vararg`
        # entries written from `sigtypes` above, which `<:` cannot handle
        for input_type in arg_types[length(sigtypes):end]
            input_type <: vararg_type && (right_matches += 1)
        end
    end
    return -(right_matches * 2 + (length(arg_types) < 2 ? 1 : 0))
end

function print_bulleted_method_candidates(io::IO, candidates::String)
    lines = split(rstrip(candidates, '\n'), '\n'; keepempty=true)
    for (i, line) in enumerate(lines)
        if startswith(line, "   @")
            print(io, "  ", line[4:end])
        elseif startswith(line, "  ...")
            print(io, "- ...")
        elseif startswith(line, "  ") && !startswith(line, "   ")
            print(io, "- `", line[3:end], '`')
        else
            print(io, line)
        end
        i == length(lines) || print(io, '\n')
    end
    return nothing
end

# AmbiguousMethodReport
# ---------------------

@jetreport struct AmbiguousMethodReport <: MethodErrorReport
    @nospecialize t # ::Union{Type, Vector{Type}}
    union_split::Int
    methods::Union{Vector{Method},Vector{Vector{Method}}} # parallel to `t`
end
JETInterface.print_report_message(io::IO, report::AmbiguousMethodReport) =
    print_ambiguous_method_report(io, report)
inference_error_report_stack_impl(r::AmbiguousMethodReport) = length(r.vst):-1:1
inference_error_report_severity_impl(::AmbiguousMethodReport) = DiagnosticSeverity.Warning

function print_ambiguous_method_report(io::IO, report::AmbiguousMethodReport)
    print(io, "MethodError: ")
    if report.union_split == 0
        print_callsig(io, report.t)
        print(io, " is ambiguous.")
        print_ambiguity_candidates(io, report.methods::Vector{Method}, report.t)
    else
        ts = report.t::Vector{Any}
        nts = length(ts)
        for i = 1:nts
            print_callsig(io, ts[i])
            i == nts || print(io, ", ")
        end
        print(io, nts == 1 ? " is" : " are", " ambiguous.")
        print(io, " (", nts, '/', report.union_split, " union split)")
        methodss = report.methods::Vector{Vector{Method}}
        for i = 1:nts
            if nts > 1
                print(io, "\n\nFor ")
                print_callsig(io, ts[i])
                print(io, ':')
            end
            print_ambiguity_candidates(io, methodss[i], ts[i])
        end
    end
    return nothing
end

function print_ambiguity_candidates(
        io::IO, methods::Vector{Method}, @nospecialize(t)
    )
    print(io, "\n\nCandidates:")
    for method in methods
        print(io, '\n')
        print_method_candidate(io, method)
    end
    t′ = Base.unwrap_unionall(t)
    is_kwcall = t′ isa DataType && !isempty(t′.parameters) &&
        t′.parameters[1] === typeof(Core.kwcall)
    sigfix = mapfoldl(m -> m.sig, typeintersect, methods; init=Any)
    if Base.unwrap_unionall(sigfix) isa DataType && sigfix <: Tuple
        if !is_kwcall && t <: sigfix && all(m -> Base.morespecific(sigfix, m.sig), methods)
            print(io, "\n\nPossible fix, define: ")
            print_callsig(io, sigfix)
        else
            print(io, "\n\nTo resolve the ambiguity, try making one of the methods more ",
                "specific, or adding a new method more specific than any of the existing ",
                "applicable methods.")
        end
    end
    return nothing
end

function print_method_candidate(
        io::IO, method::Method; world::Union{Nothing,UInt} = nothing
    )
    description = sprint(method; context=io) do candidate_io, method
        Base.show_method(candidate_io, method; digit_align_width=0)
    end
    parts = split(description, '\n'; limit=2, keepempty=true)
    print(io, "- `", parts[1], '`')
    if world !== nothing && world < reinterpret(UInt, method.primary_world)
        print(io, " (method too new to be called from this world context.)")
    end
    if length(parts) == 2
        print(io, "\n  ", lstrip(parts[2]))
    end
    return nothing
end

function report_method_error!(
        analyzer::LSAnalyzer, sv::CC.InferenceState, call::CC.CallMeta, arginfo::CC.ArgInfo,
        kwarg_reported::Bool, max_methods::Int
    )
    info = call.info
    if isa(info, CC.ConstCallInfo)
        info = info.call
    end
    if isa(info, CC.MethodMatchInfo)
        report_method_error!(analyzer, sv, info, kwarg_reported)
    elseif isa(info, CC.UnionSplitInfo)
        report_method_error_for_union_split!(analyzer, sv, info, arginfo, kwarg_reported,
            max_methods)
    end
end

function report_method_error!(
        analyzer::LSAnalyzer, sv::CC.InferenceState, info::CC.MethodMatchInfo,
        kwarg_reported::Bool
    )
    if CC.isempty(info.results)
        world = CC.get_inference_world(analyzer)
        atype = info.atype
        mt = CC.method_table(analyzer)
        methods = find_ambiguous_methods(atype, mt)
        if methods !== nothing
            report = AmbiguousMethodReport(sv, atype, 0, methods)
        elseif kwarg_reported
            # the unsupported keyword diagnostic already covers this call site:
            # `report_unsupported_kwarg_error!` requires the positional signature to have
            # matching methods, so the raw `Core.kwcall` no-match report is redundant.
            # For a statically-unknown-length `Vararg` signature the matches may cover
            # only some arities, but the uncovered arities are below the reporting bar
            # anyway: their keyword-free analog is not reported either
            return
        else
            report = NoMethodMatchReport(sv, atype, 0, world)
        end
        add_new_report!(analyzer, sv.result, report)
    end
end

function report_method_error_for_union_split!(
        analyzer::LSAnalyzer, sv::CC.InferenceState, info::CC.UnionSplitInfo,
        arginfo::CC.ArgInfo, kwarg_reported::Bool, max_methods::Int
    )
    world = CC.get_inference_world(analyzer)
    union_split = length(info.split)
    split_argtypes = empty_matches = ambiguous_matches = nothing
    for (i, matchinfo) in enumerate(info.split)
        if CC.isempty(matchinfo.results)
            sig_n = matchinfo.atype
            mt = CC.method_table(analyzer)
            methods = find_ambiguous_methods(sig_n, mt)
            if methods === nothing
                # suppress the raw `Core.kwcall` no-match only for branches whose
                # positional signature has matching methods, i.e. whose failure the
                # unsupported keyword diagnostic covers (for the `Vararg` arity caveat,
                # see the corresponding comment in `report_method_error!`); branches
                # without any positional method are independent errors and must be kept
                if kwarg_reported
                    split_argtypes = @something split_argtypes CC.switchtupleunion(
                        CC.typeinf_lattice(analyzer), arginfo.argtypes)
                    argtypes′ = split_argtypes[i]::Vector{Any}
                    if length(argtypes′) ≥ 3 && find_call_method_matches(
                            analyzer, CC.widenconst(argtypes′[3]), argtypes′, 4, max_methods
                        ) !== nothing
                        continue
                    end
                end
                empty_matches = @something empty_matches (Any[], union_split)
                push!(empty_matches[1], sig_n)
            else
                ambiguous_matches = @something ambiguous_matches (Any[], Vector{Method}[])
                push!(ambiguous_matches[1], sig_n)
                push!(ambiguous_matches[2], methods)
            end
        end
    end
    if empty_matches !== nothing
        report = NoMethodMatchReport(sv, empty_matches..., world)
        add_new_report!(analyzer, sv.result, report)
    end
    if ambiguous_matches !== nothing
        report = AmbiguousMethodReport(sv, ambiguous_matches[1], union_split, ambiguous_matches[2])
        add_new_report!(analyzer, sv.result, report)
    end
end

function find_ambiguous_methods(
        @nospecialize(t), method_table::CC.MethodTableView
    )
    matches = @something CC.findall(t, method_table; include_ambiguous=true) return nothing
    matches.ambig || return nothing
    coverage = Union{}
    methods = Method[]
    for match in matches
        coverage = Union{coverage,match.spec_types}
        match.method ∈ methods || push!(methods, match.method)
    end
    # The ambiguity flag may describe only part of an abstract query signature.
    # Require the applicable match regions to cover the complete query signature.
    t <: coverage || return nothing
    return methods
end

# `abstract_invoke` gives up without any call info when no method is found for the
# signature requested by `invoke`, so look up the method again here to report it.
# Returns the signature if reported.
function report_invoke_method_error!(
        analyzer::LSAnalyzer, sv::CC.InferenceState, call::CC.CallMeta, arginfo::CC.ArgInfo
    )
    call.info isa CC.NoCallInfo || return nothing
    sig = @something invoke_signature(arginfo.argtypes) return nothing
    mt = CC.method_table(analyzer)
    match, valid_worlds = CC.findsup(sig, mt)
    match === nothing || return nothing
    @static if hasmethod(CC.update_valid_age!, Tuple{CC.AbsIntState,Any,CC.WorldRange})
        CC.update_valid_age!(sv, CC.get_inference_world(analyzer), valid_worlds)
    else
        CC.update_valid_age!(sv, valid_worlds)
    end
    methods = find_ambiguous_methods(sig, mt)
    if methods !== nothing
        report = AmbiguousMethodReport(sv, sig, 0, methods)
    else
        report = NoMethodMatchReport(sv, sig, 0, CC.get_inference_world(analyzer))
    end
    add_new_report!(analyzer, sv.result, report)
    return sig
end

# Replaces the call info of an `invoke` call reported by `report_invoke_method_error!`.
# The failed lookup leaves no edge, so this adds a method table backedge for the signature
# to invalidate the cached report once a method is defined for it.
struct InvokeMethodErrorInfo <: CC.CallInfo
    sig::Type
    InvokeMethodErrorInfo(@nospecialize sig::Type) = new(sig)
end
CC.add_edges_impl(edges::Vector{Any}, info::InvokeMethodErrorInfo) =
    push!(edges, info.sig, Core.methodtable)

# Returns `nothing` unless the signature is known statically and `invoke` gets to look it
# up, i.e. it does not throw a `TypeError` for the arguments first
function invoke_signature(argtypes::Vector{Any})
    ft = CC.widenconst(CC.argtype_by_index(argtypes, 2))
    ft isa DataType && CC.isdispatchelem(ft) || return nothing
    types, isexact, _, _ = CC.instanceof_tfunc(CC.argtype_by_index(argtypes, 3), false)
    isexact || return nothing
    unwrapped = Base.unwrap_unionall(types)
    unwrapped isa DataType && unwrapped.name === Tuple.name || return nothing
    argtype = CC.argtypes_to_type(CC.argtype_tail(argtypes, 4))
    typeintersect(types, argtype) === Union{} && return nothing
    return Base.rewrap_unionall(Tuple{ft, unwrapped.parameters...}, types)
end

# UnsupportedKeywordArgReport
# ---------------------------

# A call like `f(; unknownkw=...)` is lowered to `Core.kwcall((unknownkw=...,), f)`.
# This dispatches successfully to `f`'s generated keyword sorter, which then throws a
# `MethodError` via `Base.kwerr` for the surplus keyword. Since this is an explicit
# `throw` rather than a dispatch failure, `NoMethodMatchReport` does not fire; we detect
# the statically-determined surplus keyword here instead.
# When `f` has no keyword-accepting method at all, the `Core.kwcall` dispatch itself
# fails instead; this report then supersedes the raw no-match report
# (see `after_abstract_call_gf_by_type`).
@jetreport struct UnsupportedKeywordArgReport <: MethodErrorReport
    @nospecialize ftype
    posargtypes::Vector{Any}
    @nospecialize kwt
    unsupported::Vector{Symbol}
    combination::Bool
end
function JETInterface.print_report_message(io::IO, r::UnsupportedKeywordArgReport)
    unsupported = r.unsupported
    if r.combination
        print(io, "unsupported combination of keyword arguments")
    else
        print(io, "unsupported keyword argument")
        isone(length(unsupported)) || print(io, 's')
    end
    print(io, ' ')
    for (i, name) in enumerate(unsupported)
        i == 1 || print(io, ", ")
        print(io, '`', name, '`')
    end
    kwt = Base.unwrap_unionall(r.kwt)::DataType
    keys = kwt.parameters[1]::Tuple{Vararg{Symbol}}
    kwargs = Pair{Symbol,Any}[Pair{Symbol,Any}(keys[i], fieldtype(kwt, i)) for i in eachindex(keys)]
    print(io, " in `")
    Base.show_signature_function(io, r.ftype)
    Base.show_tuple_as_call(io, Symbol(""), Tuple{r.posargtypes...}; hasfirst=false, kwargs)
    print(io, '`')
end
inference_error_report_stack_impl(r::UnsupportedKeywordArgReport) = length(r.vst):-1:1
inference_error_report_severity_impl(::UnsupportedKeywordArgReport) = DiagnosticSeverity.Warning

# `arginfo.argtypes` may end in a `Vararg` (e.g. a splatted call like `f(xs...)`), and a
# positional argument may even be `Union{}` on a dead path. `argtypes_to_type` keeps a
# trailing vararg intact and collapses such dead paths to `Bottom`, where a plain
# `Tuple{...}` would instead error on a vararg or `Union{}` field.
function find_call_method_matches(
        analyzer::LSAnalyzer, @nospecialize(ftype), argtypes::Vector{Any},
        posbase::Int, max_methods::Int
    )
    posargtypes = Any[let argtype = argtypes[i]
        CC.isvarargtype(argtype) ? argtype : CC.widenconst(argtype)
    end for i = posbase:length(argtypes)]
    # Bound the lookup by inference's own `max_methods` (as `find_method_matches` does), so
    # a pathologically large match set (e.g. when `ftype` is abstract) bails cleanly rather
    # than enumerating every applicable method. `findall` returns `nothing` past the limit.
    callsig = CC.argtypes_to_type(Any[ftype; posargtypes])
    callsig === Union{} && return nothing
    mt = CC.method_table(analyzer)
    matches = @something CC.findall(callsig, mt; limit=max_methods) return nothing
    isempty(matches) && return nothing
    return posargtypes, matches
end

function report_unsupported_kwarg_error!(
        analyzer::LSAnalyzer, sv::CC.InferenceState, @nospecialize(func),
        call::CC.CallMeta, arginfo::CC.ArgInfo, max_methods::Int
    )
    func === Core.kwcall || return false
    # only report when inference agrees that the call always throws
    call.rt === Union{} || return false
    argtypes = arginfo.argtypes
    # `Core.kwcall(kwnt, f, posargs...)`: Any[typeof(kwcall), kwnt, f, posargs...]
    length(argtypes) ≥ 3 || return false

    kwt = CC.widenconst(argtypes[2])
    kwnames = @something kwcall_keyword_names(kwt) return false
    isempty(kwnames) && return false

    ftype = CC.widenconst(argtypes[3])
    posargtypes, matches = @something find_call_method_matches(
        analyzer, ftype, argtypes, 4, max_methods) return false
    world = CC.get_inference_world(analyzer)
    always_unsupported = trues(length(kwnames))
    ever_unsupported = falses(length(kwnames))
    for match in matches
        decls = kwarg_decl(match.method, world)
        # a slurping `kwargs...` shows up as a name ending with `...` and accepts anything
        any(name -> endswith(String(name), "..."), decls) && return false
        rejects_call = false
        for i in eachindex(kwnames)
            unsupported = kwnames[i] ∉ decls
            always_unsupported[i] &= unsupported
            ever_unsupported[i] |= unsupported
            rejects_call |= unsupported
        end
        rejects_call || return false
    end

    combination = !any(always_unsupported)
    unsupported_flags = combination ? ever_unsupported : always_unsupported
    unsupported = Symbol[kwnames[i] for i in eachindex(kwnames) if unsupported_flags[i]]
    report = UnsupportedKeywordArgReport(sv, ftype, posargtypes, kwt, unsupported, combination)
    add_new_report!(analyzer, sv.result, report)
    return true
end

function kwcall_keyword_names(@nospecialize kwt)
    kwt = Base.unwrap_unionall(kwt)
    isa(kwt, DataType) || return nothing
    kwt <: NamedTuple || return nothing
    isempty(kwt.parameters) && return nothing
    names = kwt.parameters[1]
    isa(names, Tuple{Vararg{Symbol}}) || return nothing
    return names
end

# UndefKeywordErrorReport
# -----------------------

# A missing required keyword throws `UndefKeywordError` in the synthesized keyword sorter;
# detect it there (`CC.abstract_throw`) and store the report unconditionally on the sorter
# frame. That is caller-independent, so it caches cleanly and replays (re-rooted) to every
# call site — offset 1 points one frame up, at the call site. `report_target_modules`
# filtering is deferred to propagation.
@jetreport struct UndefKeywordErrorReport <: JETLSErrorReport
    var::Symbol
end
JETInterface.print_report_message(io::IO, r::UndefKeywordErrorReport) =
    print(io, "missing keyword argument `", r.var, '`')
inference_error_report_stack_impl(r::UndefKeywordErrorReport) = (length(r.vst)-1):-1:1
inference_error_report_severity_impl(::UndefKeywordErrorReport) = DiagnosticSeverity.Warning
scope_offset_impl(::UndefKeywordErrorReport) = 1

function report_undef_keyword!(analyzer::LSAnalyzer, sv::CC.InferenceState, argtypes::Vector{Any})
    length(argtypes) ≥ 2 || return false
    a = argtypes[2]
    a isa Const || return false
    err = a.val
    err isa UndefKeywordError || return false
    # The report points at the user's call site, one frame up from the synthesized sorter.
    add_new_report!(analyzer, sv.result, UndefKeywordErrorReport(sv, err.var))
    return true
end

# KeywordTypeErrorReport
# ----------------------

# Passing a keyword argument whose value type does not match the keyword's declared type
# (`func(2; kw=42.0)` for `func(a; kw::Int=42)`) raises a `TypeError` at runtime: the keyword
# sorter asserts each typed keyword and throws `TypeError(Symbol("keyword argument"), :kw, Int,
# got)`. As with `UndefKeywordErrorReport`, detect this at the call site rather than at that
# `throw`, so the report does not depend on which call site first inferred the sorter. The
# offending keyword, its declared type, and the provided type are recovered from the call's
# keyword `NamedTuple` and the callee's declared keyword types (caller-independent and
# cache-stable), since `call.exct` widens to the bare `TypeError` type once cached.
@jetreport struct KeywordTypeErrorReport <: TypeErrorReport
    var::Symbol
    @nospecialize expected
    @nospecialize got
end
function JETInterface.print_report_message(io::IO, r::KeywordTypeErrorReport)
    print(io, "TypeError: in keyword argument `", r.var, "`, expected `", r.expected, "`, got ")
    print_type_error_got(io, r.got)
end
inference_error_report_stack_impl(r::KeywordTypeErrorReport) = length(r.vst):-1:1
inference_error_report_severity_impl(::KeywordTypeErrorReport) = DiagnosticSeverity.Warning

function kwarg_decl(m::Method, world::UInt)
    @static if :world in Base.kwarg_decl(only(methods(Base.kwarg_decl, (Method,))))
        return Base.kwarg_decl(m; world)
    else
        return Base.kwarg_decl(m)
    end
end

function keyword_arg_types(m::Method, world::UInt)
    decls = kwarg_decl(m, world)
    isempty(decls) && return nothing
    bf = @something (@static if :world in Base.kwarg_decl(only(methods(Base.bodyfunction)))
        Base.bodyfunction(m; world)
    else
        Base.invoke_in_world(world, Base.bodyfunction, m)
    end) return nothing
    bms = Base._methods(bf, Tuple{Vararg{Any}}, -1, world)
    bms isa Vector || return nothing
    length(bms) == 1 || return nothing
    bsig = Base.unwrap_unionall((only(bms)::Core.MethodMatch).method.sig)
    bsig isa DataType || return nothing
    params = bsig.parameters
    length(params) ≥ 1 + length(decls) || return nothing
    kwtypes = Pair{Symbol,Any}[]
    for i = 1:length(decls)
        name = decls[i]
        endswith(String(name), "...") && continue # slurp accepts any keyword
        ty = params[1+i]
        ty isa Type || continue
        push!(kwtypes, Pair{Symbol,Any}(name, ty))
    end
    return kwtypes
end

function report_keyword_typeerror!(
        analyzer::LSAnalyzer, sv::CC.InferenceState, @nospecialize(func),
        call::CC.CallMeta, arginfo::CC.ArgInfo, max_methods::Int
    )
    func === Core.kwcall || return false
    call.rt === Union{} || return false
    Union{} !== CC.widenconst(call.exct) <: TypeError || return false
    argtypes = arginfo.argtypes
    # `Core.kwcall(kwnt, f, posargs...)`
    length(argtypes) ≥ 3 || return false
    kwt = CC.widenconst(argtypes[2])
    names = @something kwcall_keyword_names(kwt) return false
    isempty(names) && return false
    ftype = CC.widenconst(argtypes[3])
    _, matches = @something find_call_method_matches(
        analyzer, ftype, argtypes, 4, max_methods) return false
    world = CC.get_inference_world(analyzer)
    mismatches = Dict{Symbol,Any}[]
    for match in matches
        kwtypes = @something keyword_arg_types(match.method, world) return false
        mismatch = Dict{Symbol,Any}()
        for (name, expected) in kwtypes
            idx = @something findfirst(==(name), names) continue # this typed keyword was not provided
            got = fieldtype(kwt, idx)
            # report only a definite mismatch: no value of `got` can satisfy the keyword's
            # `isa expected` assertion
            typeintersect(got, expected) === Union{} || continue
            mismatch[name] = expected
        end
        isempty(mismatch) && return false
        push!(mismatches, mismatch)
    end

    common_names = Set{Symbol}(keys(first(mismatches)))
    for mismatch in @view mismatches[2:end]
        intersect!(common_names, keys(mismatch))
        isempty(common_names) && return false
    end
    idx = @something findfirst(∈(common_names), names) return false
    name = names[idx]
    expected = Union{}
    for mismatch in mismatches
        expected = Union{expected,mismatch[name]}
    end
    got = fieldtype(kwt, idx)
    add_new_report!(analyzer, sv.result, KeywordTypeErrorReport(sv, name, expected, got))
    return true
end

# InvokeTypeErrorReport
# ---------------------

@jetreport struct InvokeTypeErrorReport <: TypeErrorReport
    @nospecialize expected
    @nospecialize got
    argument_mismatch::Bool
end
function JETInterface.print_report_message(io::IO, r::InvokeTypeErrorReport)
    print(io, "TypeError: in `invoke`")
    r.argument_mismatch && print(io, ": argument type error")
    print(io, ", expected `", r.expected, "`, got ")
    print_type_error_got(io, r.got)
end
inference_error_report_stack_impl(r::InvokeTypeErrorReport) = length(r.vst):-1:1
inference_error_report_severity_impl(::InvokeTypeErrorReport) = DiagnosticSeverity.Warning

# `abstract_invoke` gives up without any call info when `invoke` throws a `TypeError` before
# looking up the method, so check the signature and the arguments again here to report it
function report_invoke_type_error!(
        analyzer::LSAnalyzer, sv::CC.InferenceState, call::CC.CallMeta, arginfo::CC.ArgInfo
    )
    call.rt === Union{} && call.info isa CC.NoCallInfo || return false
    argtypes = arginfo.argtypes
    length(argtypes) ≥ 3 && !CC.isvarargtype(argtypes[3]) || return false
    sigtype = argtypes[3]
    got = CC.widenconst(sigtype)
    # `invoke` also accepts a `Method` or a `CodeInstance` in place of the signature
    CC.hasintersect(got, Union{Method,Core.CodeInstance}) && return false
    types, isexact, _, _ = CC.instanceof_tfunc(sigtype, false)
    isexact || return false
    unwrapped = Base.unwrap_unionall(types)
    if !(unwrapped isa DataType && unwrapped.name === Tuple.name)
        report = InvokeTypeErrorReport(sv, Type{T} where T<:Tuple, got, false)
    else
        argtype = CC.argtypes_to_type(CC.argtype_tail(argtypes, 4))
        CC.hasintersect(types, argtype) && return false
        report = InvokeTypeErrorReport(sv, types, argtype, true)
    end
    add_new_report!(analyzer, sv.result, report)
    return true
end

# NonBooleanCondErrorReport
# -------------------------

@jetreport struct NonBooleanCondErrorReport <: TypeErrorReport
    @nospecialize t # ::Union{Type, Vector{Type}}
    union_split::Int
    uncovered::Bool
end
inference_error_report_stack_impl(r::NonBooleanCondErrorReport) = length(r.vst):-1:1
inference_error_report_severity_impl(::NonBooleanCondErrorReport) = DiagnosticSeverity.Warning
function JETInterface.print_report_message(io::IO, report::NonBooleanCondErrorReport)
    (; t, union_split, uncovered) = report
    if union_split == 0
        print(io, "non-boolean `", t, "`")
        if uncovered
            print(io, " may be used in boolean context")
        else
            print(io, " found in boolean context")
        end
    else
        ts = t::Vector{Any}
        nts = length(ts)
        print(io, "non-boolean ")
        for i = 1:nts
            print(io, '`', ts[i], '`')
            i == nts || print(io, ", ")
        end
        if uncovered
            print(io, " may be used in boolean context")
        else
            print(io, " found in boolean context")
        end
        print(io, " (", nts, '/', union_split, " union split)")
    end
end

function report_non_boolean_cond!(analyzer::LSAnalyzer, sv::CC.InferenceState, @nospecialize(t))
    check_uncovered = false
    ⊑ = CC.partialorder(CC.typeinf_lattice(analyzer))
    if isa(t, Union)
        info = nothing
        uts = Base.uniontypes(t)
        for ut in uts
            if !(check_uncovered ? ut ⊑ Bool : CC.hasintersect(ut, Bool))
                info = @something info Any[], length(uts)
                push!(info[1], ut)
            end
        end
        if info !== nothing
            add_new_report!(analyzer, sv.result, NonBooleanCondErrorReport(sv, info..., #=uncovered=#check_uncovered))
        end
    else
        if !(check_uncovered ? t ⊑ Bool : CC.hasintersect(t, Bool))
            add_new_report!(analyzer, sv.result, NonBooleanCondErrorReport(sv, t, 0, #=uncovered=#check_uncovered))
        end
    end
end

# FailingTestReport
# -----------------

# Top-level analysis replaces `@test ex` with code that passes the value of `ex` to
# `JET.check_test_value`, so a call to it whose argument is inferred to be `false` or of a
# non-boolean type is a test that always fails. Likewise, it replaces
# `@test_throws extype ex` with code that passes the exception caught from `ex` to
# `JET.check_test_exception`, so a call to it whose argument is inferred to be only of
# exception types that do not match `extype` is a test that always fails.
@jetreport struct FailingTestReport <: JETLSErrorReport
    @nospecialize t # `Bool` for an expression that always evaluates to `false`
    @nospecialize expected # the expected exception of `@test_throws`, `nothing` for `@test`
end
inference_error_report_stack_impl(r::FailingTestReport) = length(r.vst):-1:1
inference_error_report_severity_impl(::FailingTestReport) = DiagnosticSeverity.Warning
function JETInterface.print_report_message(io::IO, (; t, expected)::FailingTestReport)
    print(io, "this test always fails since its expression ")
    if expected !== nothing
        print(io, "throws `", t, "`, not `", expected, "`")
    elseif t === Bool
        print(io, "evaluates to `false`")
    else
        print(io, "evaluates to non-boolean `", t, "`")
    end
end

function report_failing_test!(analyzer::LSAnalyzer, sv::CC.InferenceState, argtypes::Vector{Any})
    # A test in a function body is inferred for each specialization, e.g. for each member of
    # a union split at the call site, where a failure for some argument types does not mean
    # that the test always fails. So report only the tests in top-level code.
    sv.linfo.def isa Module || return false
    length(argtypes) == 2 || return false
    value = CC.widenconditional(argtypes[2])
    if value isa Const && value.val === false
        add_new_report!(analyzer, sv.result, FailingTestReport(sv, Bool, nothing))
        return true
    end
    t = CC.widenconst(value)
    t === Union{} && return false
    CC.hasintersect(t, Bool) && return false
    add_new_report!(analyzer, sv.result, FailingTestReport(sv, t, nothing))
    return true
end

function report_failing_test_exception!(
        analyzer::LSAnalyzer, sv::CC.InferenceState, argtypes::Vector{Any}
    )
    sv.linfo.def isa Module || return false # see `report_failing_test!`
    length(argtypes) ≥ 3 || return false
    expected = JET.matching_test_exception_type(argtypes[3])
    expected === nothing && return false
    # The caught exception is inferred from the exceptions that the test expression may
    # throw. An expression inferred not to throw is not reported for now, as inference may
    # miss the exceptions thrown by it.
    exct = CC.typesubtract(CC.widenconst(argtypes[2]), JET.NoTestException,
        CC.InferenceParams(analyzer).max_union_splitting)
    (exct === Union{} || CC.hasintersect(exct, expected)) && return false
    add_new_report!(analyzer, sv.result,
        FailingTestReport(sv, exct, (argtypes[3]::Const).val))
    return true
end

# DeprecatedCallReport
# --------------------

# Unlike `lowering/deprecated-*`, the diagnostic of this report is not tagged with
# `DiagnosticTag.Deprecated`, since inference diagnostics span the whole line of the call,
# which clients would render struck through.
@jetreport struct DeprecatedCallReport <: JETLSErrorReport
    message::String
end
inference_error_report_stack_impl(r::DeprecatedCallReport) = length(r.vst):-1:1
inference_error_report_severity_impl(::DeprecatedCallReport) = DiagnosticSeverity.Information
JETInterface.print_report_message(io::IO, r::DeprecatedCallReport) = print(io, r.message)

function report_deprecated_call!(
        analyzer::LSAnalyzer, sv::CC.InferenceState, @nospecialize(func), call::CC.CallMeta,
        arginfo::CC.ArgInfo
    )
    info = call.info
    if isa(info, CC.ConstCallInfo)
        info = info.call
    end
    world = CC.get_inference_world(analyzer)
    messages = String[]
    if isa(info, CC.MethodMatchInfo)
        deprecated_call_messages!(messages, info, world) || return false
    elseif isa(info, CC.UnionSplitInfo)
        # The call reaches the deprecated methods whenever its arguments have the types of the
        # splits that match only those methods
        for matchinfo in info.split
            deprecated_call_messages!(messages, matchinfo, world)
        end
    elseif isa(info, CC.InvokeCallInfo)
        push!(messages, @something deprecated_method_message(info.match.method, world) return false)
    else
        return false
    end
    isempty(messages) && return false
    # e.g. the methods that `@deprecate` defines for default arguments call the deprecated
    # method, and the calls in them are not the uses of deprecated methods
    def = sv.linfo.def
    def isa Method && deprecated_method_message(def, world) !== nothing && return false
    # `lowering/deprecated-function` reports the uses of a function whose methods are all
    # deprecated, but only where the function is written as a global name, not e.g. where a
    # function returned by another call is called
    if func === Core.kwcall && length(arginfo.argtypes) ≥ 3
        func = CC.singleton_type(arginfo.argtypes[3])
    end
    if (func isa Function && deprecated_function_message(func, world) !== nothing &&
        writes_global_name(sv, func, world))
        return false
    end
    add_new_report!(analyzer, sv.result, DeprecatedCallReport(sv, join(messages, '\n')))
    return true
end

# Whether the current statement of `sv` writes `func` as a global name, e.g. `f` or `Mod.f`,
# whose uses `lowering/deprecated-function` reports, as the function to call or as an
# argument of e.g. `Core.kwcall`
function writes_global_name(sv::CC.InferenceState, @nospecialize(func), world::UInt)
    stmt = sv.src.code[sv.currpc]
    Meta.isexpr(stmt, :(=)) && (stmt = stmt.args[2])
    Meta.isexpr(stmt, :call) || return false
    return any(stmt.args) do @nospecialize arg
        lowered_value(sv, arg, world) === func && is_global_name(sv, arg, world)
    end
end

# Whether `x` in the code of `sv` is a global name, e.g. `f` or `Mod.f`, which is lowered to
# `getproperty(Mod, :f)`
function is_global_name(sv::CC.InferenceState, @nospecialize(x), world::UInt)
    x isa GlobalRef && return true
    x isa Core.SSAValue || return false
    stmt = sv.src.code[x.id]
    stmt isa GlobalRef && return true
    Meta.isexpr(stmt, :call) && length(stmt.args) == 3 || return false
    f, mod, name = stmt.args
    f isa GlobalRef && f.name === :getproperty && name isa QuoteNode || return false
    return lowered_value(sv, mod, world) isa Module && is_global_name(sv, mod, world)
end

function lowered_value(sv::CC.InferenceState, @nospecialize(x), world::UInt)
    if x isa Core.SSAValue
        t = sv.ssavaluetypes[x.id]
        return t isa Core.Const ? t.val : nothing
    elseif x isa GlobalRef
        return global_const_value(convert(Core.Binding, x), world)
    end
    return nothing
end

# Only the calls whose matching methods are all deprecated are reported, since whether a call
# reaches a deprecated method otherwise depends on the runtime types of its arguments
function deprecated_call_messages!(
        messages::Vector{String}, info::CC.MethodMatchInfo, world::UInt
    )
    n = length(messages)
    for match in info.results
        message = deprecated_method_message(match.method, world)
        if message === nothing
            resize!(messages, n)
            return false
        end
        message in messages || push!(messages, message)
    end
    return true
end

# Constructor
# ===========

# the entry constructor
function LSAnalyzer(
        @nospecialize(entry::AnalysisEntry), world::UInt = Base.get_world_counter();
        report_target_modules = missing,
        reuse_native_inference::Bool = false,
        jetconfigs...
    )
    inf_params = CC.InferenceParams(;
        aggressive_constant_propagation = true,
        # Enable the `assume_bindings_static` option to terminate analysis a bit earlier when
        # there are undefined bindings detected. Note that this option will cause inference
        # cache inconsistency until JuliaLang/julia#40399 is merged. But the analysis cache of
        # LSAnalyzer has the same problem already anyway, so enabling this option does not
        # make the situation worse.
        assume_bindings_static = true)
    state = AnalyzerState(world; inf_params, jetconfigs...)
    return LSAnalyzer(entry, state; report_target_modules, reuse_native_inference)
end

const LS_ANALYZER_CONFIGURATIONS =
    Set{Symbol}((:report_target_modules, :reuse_native_inference))

let valid_keys = JET.GENERAL_CONFIGURATIONS ∪ LS_ANALYZER_CONFIGURATIONS
    @eval JETInterface.valid_configurations(::LSAnalyzer) = $valid_keys
end

end # module Analyzer
