module Analyzer

export LSAnalyzer
export inference_error_report_related_frames, inference_error_report_related_stack,
    inference_error_report_severity, inference_error_report_stack,
    reset_report_target_modules!
export AmbiguousMethodReport, BoundsErrorReport, FieldErrorReport, KeywordTypeErrorReport,
    MethodErrorReport, NoMethodMatchReport, NonBooleanCondErrorReport, TypeAssertErrorReport,
    TypeErrorReport, UndefKeywordErrorReport, UndefVarErrorReport,
    UnsupportedKeywordArgReport
export RelatedEntryFrame, RelatedFrame, RelatedFrameKind, RelatedOriginFrame, RelatedViaFrame

using Core.IR
using Compiler: Compiler as CC
using JET.JETInterface
using JET: JET

using ..JETLS: AnalysisEntry, JETLS_DEV_MODE
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
        method_table = CC.CachedMethodTable(CC.OverlayMethodTable(state.world, jetls_method_table))
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
const LS_ANALYZER_CACHE_LOCK = ReentrantLock()

# method overlay
# ==============

Base.Experimental.@MethodTable jetls_method_table

# `include` is concretely handled by `ConcreteInterpreter`; analyzing Base's file-loading
# machinery only adds noise. Keep its unmodeled return value abstract.
Base.Experimental.@overlay jetls_method_table Base.include(::Module, ::AbstractString) = Base.inferencebarrier(nothing)
Base.Experimental.@overlay jetls_method_table Base.include(::Function, ::Module, ::AbstractString) = Base.inferencebarrier(nothing)

@static if VERSION < v"1.14.0-DEV.2024"
# Backport JuliaLang/julia#61526
Base.Experimental.@overlay jetls_method_table Base.in(x, itr::Tuple) = _in_tuple(x, itr)
function _in_tuple(x, @nospecialize(itr::Tuple), result = false)
    @inline
    isempty(itr) && return result
    v = (itr[1] == x)
    if v === true
        return true
    end
    return _in_tuple(x, Base.tail(itr), result | v)
end
end

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

# Analysis injections
# ===================

function after_abstract_call_gf_by_type(
        analyzer::LSAnalyzer, ret::CC.Future, @nospecialize(func), arginfo::CC.ArgInfo,
        sv::CC.InferenceState, max_methods::Int
    )
    if !should_analyze(analyzer, sv)
        return nothing
    end
    func_ref = Ref{Any}(func)
    function _after_abstract_call_gf_by_type(analyzer′::LSAnalyzer, sv′::CC.InferenceState)
        ret′ = ret[]
        func′ = func_ref[]
        kwarg_reported = report_unsupported_kwarg_error!(analyzer′, sv′, func′, ret′, arginfo, max_methods)
        report_method_error!(analyzer′, sv′, ret′, arginfo, kwarg_reported, max_methods)
        report_keyword_typeerror!(analyzer′, sv′, func′, ret′, arginfo, max_methods)
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
    # TODO use `abstract_eval_isdefinedglobal` for respecting world age
    world = CC.get_inference_world(analyzer)
    if Base.invoke_in_world(world, isdefinedglobal, gr.mod, gr.name)
        # HACK/FIXME Concretize `AbstractBindingState`
        x = Base.invoke_in_world(world, getglobal, gr.mod, gr.name)
        x isa JET.AbstractBindingState || return false
        binding_state = x
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
        pc_assign = CC.find_dominating_assignment(slot.id, pc, sv)
        pc_assign === nothing && return nothing
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
    candidates = sprint(Base.show_method_candidates, exception; context=io)
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

# Returns `nothing` when the applicable methods cannot be enumerated (too broad a
# callable type or too many matches), and an empty vector when `ftype` has no methods
# at all, i.e. its instances are not callable.
function find_callable_candidate_methods(@nospecialize(ftype))
    ftype′ = Base.unwrap_unionall(ftype)
    ftype′ isa DataType || return nothing
    ftype′ === Any && return nothing
    ftype′ === Function && return nothing
    callsig = Tuple{ftype,Vararg{Any}}
    matches = Base._methods_by_ftype(callsig, nothing, 100, Base.get_world_counter())
    matches isa Vector || return nothing
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
        methods = find_ambiguous_methods(atype, CC.method_table(analyzer))
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
            methods = find_ambiguous_methods(sig_n, CC.method_table(analyzer))
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
        match = match::Core.MethodMatch
        coverage = Union{coverage,match.spec_types}
        match.method ∈ methods || push!(methods, match.method)
    end
    # The ambiguity flag may describe only part of an abstract query signature.
    # Require the applicable match regions to cover the complete query signature.
    t <: coverage || return nothing
    return methods
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
    matches = CC.findall(callsig, CC.method_table(analyzer); limit=max_methods)
    matches === nothing && return nothing
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
    bf = Base.bodyfunction(m)
    bf === nothing && return nothing
    bms = Base._methods(bf, Tuple{Vararg{Any}}, -1, world)
    bms isa Vector || return nothing
    length(bms) == 1 || return nothing
    bsig = Base.unwrap_unionall((first(bms)::Core.MethodMatch).method.sig)
    bsig isa DataType || return nothing
    params = bsig.parameters
    length(params) ≥ 1 + length(decls) || return nothing
    kwtypes = Pair{Symbol,Any}[]
    for i = 1:length(decls)
        name = decls[i]
        endswith(String(name), "...") && continue # slurp accepts any keyword
        ty = params[1+i]
        ty isa Type || continue
        push!(kwtypes, name => ty)
    end
    return kwtypes
end

function report_keyword_typeerror!(
        analyzer::LSAnalyzer, sv::CC.InferenceState, @nospecialize(func),
        call::CC.CallMeta, arginfo::CC.ArgInfo, max_methods::Int
    )
    func === Core.kwcall || return false
    call.rt === Union{} || return false
    CC.widenconst(call.exct) <: TypeError || return false
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
