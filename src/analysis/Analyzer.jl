module Analyzer

export LSAnalyzer, inference_error_report_severity, inference_error_report_stack, reset_report_target_modules!
export BoundsErrorReport, FieldErrorReport, KeywordTypeErrorReport, MethodErrorReport,
    NoMethodMatchReport, NonBooleanCondErrorReport, TypeAssertErrorReport,
    TypeErrorReport, UndefKeywordErrorReport, UndefVarErrorReport,
    UnsupportedKeywordArgReport

using Core.IR
using JET.JETInterface
using JET: CC, JET

using ..JETLS: AnalysisEntry
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
    return ret
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

    invariable_analysis_hash::UInt

    """
        LSAnalyzer(state::AnalyzerState, analysis_token::AnalysisToken, report_target_modules::Set{Module})

    Internal constructor of `LSAnalyzer`.
    Used for both initial construction and creating a new [`LSAnalyzer`](@ref) from an existing one.
    """
    function LSAnalyzer(
            state::AnalyzerState, analysis_token::AnalysisToken,
            report_target_modules::Union{Nothing,Set{Module}},
            invariable_analysis_hash::UInt
        )
        method_table = CC.CachedMethodTable(CC.OverlayMethodTable(state.world, jetls_method_table))
        return new(state, analysis_token, method_table, report_target_modules, invariable_analysis_hash)
    end
end

const incremental_initial_hash = rand(UInt)
const global_mode_hash = rand(UInt)
const lagacy_mode_hash = rand(UInt)

"""
    LSAnalyzer(entry::AnalysisEntry, state::AnalyzerState; report_target_modules=missing)
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
        report_target_modules = missing
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
    invariable_analysis_hash = JET.compute_hash(entry, report_target_modules_hash)
    analysis_cache_key = JET.compute_hash(state.inf_params, invariable_analysis_hash)
    analysis_token = @lock LS_ANALYZER_CACHE_LOCK get!(AnalysisToken, LS_ANALYZER_CACHE, analysis_cache_key)
    return LSAnalyzer(state, analysis_token, report_target_modules, invariable_analysis_hash)
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
    return LSAnalyzer(state, analysis_token, report_target_modules, analyzer.invariable_analysis_hash)
end
JETInterface.AnalysisToken(analyzer::LSAnalyzer) = analyzer.analysis_token

const LS_ANALYZER_CACHE = Dict{UInt,AnalysisToken}()
const LS_ANALYZER_CACHE_LOCK = ReentrantLock()

# method overlay
# ==============

Base.Experimental.@MethodTable jetls_method_table

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

# Many builtin functions are used in `getproperty(::Any,::Symbol)` or `getindex(::Tuple,::Int)`, etc.,
# so analysis injection needs to be performed in the context of those methods (i.e. `Base`),
# but `report_target_modules` does not necessarily include `Base`.
# Therefore, we need to check the inference frame one level up, and if it is in `report_target_modules`,
# we also need to analyze it.
function should_analyze_for_builtins(analyzer::LSAnalyzer, sv::CC.InferenceState)
    report_target_modules = analyzer.report_target_modules
    isnothing(report_target_modules) && return 0
    CC.frame_module(sv) ∈ report_target_modules && return 0
    checkbounds(Bool, sv.callstack, sv.parentid) || return nothing
    parent = sv.callstack[sv.parentid]
    CC.frame_module(parent) ∈ report_target_modules && return 1
    return nothing
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

@static if VERSION ≥ v"1.12.2"
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
end # @static if VERSION ≥ v"1.12.2"

# Analysis injections
# ===================

function after_abstract_call_gf_by_type(
        analyzer::LSAnalyzer, ret::CC.Future, @nospecialize(func), arginfo::CC.ArgInfo,
        @nospecialize(atype), sv::CC.InferenceState, max_methods::Int
    )
    if !should_analyze(analyzer, sv)
        return nothing
    end
    atype′ = Ref{Any}(atype)
    function _after_abstract_call_gf_by_type(analyzer′::LSAnalyzer, sv′::CC.InferenceState)
        ret′ = ret[]
        report_method_error!(analyzer′, sv′, ret′, arginfo, atype′[])
        report_unsupported_kwarg_error!(analyzer′, sv′, func, ret′, arginfo, max_methods)
        report_undef_keyword!(analyzer′, sv′, func, ret′, arginfo, max_methods)
        report_keyword_typeerror!(analyzer′, sv′, func, ret′, arginfo, max_methods)
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
    after_abstract_call_gf_by_type(analyzer, ret, func, arginfo, atype, sv, max_methods)
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
    after_abstract_call_gf_by_type(analyzer, ret, func, arginfo, atype, sv, max_methods)
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
        offset = should_analyze_for_builtins(analyzer, sv)
        if offset !== nothing && offset ≤ allowed_offset
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
    offset = should_analyze_for_builtins(analyzer, sv)
    if offset !== nothing
        report_builtin_error!(analyzer, sv, f, argtypes, ret, offset)
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
    return print(io, lazy"FieldError: type $tname has no field `$(r.field)`, available fields: $flds")
end
inference_error_report_stack_impl(r::FieldErrorReport) = (length(r.vst)-r.vst_offset):-1:1
inference_error_report_severity_impl(::FieldErrorReport) = DiagnosticSeverity.Warning

@jetreport struct BoundsErrorReport <: JETLSErrorReport
    @nospecialize a
    i::Int
    vst_offset::Int
end
JETInterface.print_report_message(io::IO, r::BoundsErrorReport) =
    print(io, lazy"BoundsError: attempt to access $(r.a) at index [$(r.i)]")
inference_error_report_stack_impl(r::BoundsErrorReport) = (length(r.vst)-r.vst_offset):-1:1
inference_error_report_severity_impl(::BoundsErrorReport) = DiagnosticSeverity.Warning

# TypeAssertErrorReport
# ---------------------

@jetreport struct TypeAssertErrorReport <: TypeErrorReport
    @nospecialize expected
    @nospecialize actual
    vst_offset::Int
end
inference_error_report_stack_impl(r::TypeAssertErrorReport) = (length(r.vst)-r.vst_offset):-1:1
inference_error_report_severity_impl(::TypeAssertErrorReport) = DiagnosticSeverity.Warning

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
        analyzer::LSAnalyzer, sv::CC.InferenceState, @nospecialize(f), argtypes::Vector{Any},
        @nospecialize(ret), offset::Int
    )
    if ret === Union{}
        if f === getfield
            report_fieldaccess!(analyzer, sv, getfield, argtypes, offset)
        elseif f === setfield!
            report_fieldaccess!(analyzer, sv, setfield!, argtypes, offset)
        elseif f === fieldtype
            report_fieldaccess!(analyzer, sv, fieldtype, argtypes, offset)
        elseif f === Core.typeassert
            report_typeassert_error!(analyzer, sv, argtypes, offset)
        end
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
        add_new_report!(analyzer, sv.result, FieldErrorReport(sv, objtyp, namev, offset))
    elseif namev isa Int
        add_new_report!(analyzer, sv.result, BoundsErrorReport(sv, objtyp, namev, offset))
    else error("invalid field analysis") end
    return true
end

# NoMethodMatchReport
# -------------------

@jetreport struct NoMethodMatchReport <: MethodErrorReport
    @nospecialize t # ::Union{Type, Vector{Type}}
    union_split::Int
end
function JETInterface.print_report_message(io::IO, report::NoMethodMatchReport)
    print(io, "no matching method found ")
    if report.union_split == 0
        print_callsig(io, report.t)
    else
        ts = report.t::Vector{Any}
        nts = length(ts)
        for i = 1:nts
            print_callsig(io, ts[i])
            i == nts || print(io, ", ")
        end
        print(io, " (", nts, '/', report.union_split, " union split)")
    end
end
function print_callsig(io, @nospecialize(t))
    print(io, '`')
    Base.show_tuple_as_call(io, Symbol(""), t)
    print(io, '`')
end
inference_error_report_stack_impl(r::NoMethodMatchReport) = length(r.vst):-1:1
inference_error_report_severity_impl(::NoMethodMatchReport) = DiagnosticSeverity.Warning

function report_method_error!(
        analyzer::LSAnalyzer, sv::CC.InferenceState, call::CC.CallMeta,
        arginfo::CC.ArgInfo, @nospecialize(atype)
    )
    info = call.info
    if isa(info, CC.ConstCallInfo)
        info = info.call
    end
    if isa(info, CC.MethodMatchInfo)
        report_method_error!(analyzer, sv, info, atype)
    elseif isa(info, CC.UnionSplitInfo)
        report_method_error_for_union_split!(analyzer, sv, info, arginfo)
    end
end

function report_method_error!(
        analyzer::LSAnalyzer, sv::CC.InferenceState, info::CC.MethodMatchInfo,
        @nospecialize(atype)
    )
    if CC.isempty(info.results)
        report = NoMethodMatchReport(sv, atype, 0)
        add_new_report!(analyzer, sv.result, report)
    end
end

function report_method_error_for_union_split!(
        analyzer::LSAnalyzer, sv::CC.InferenceState, info::CC.UnionSplitInfo,
        arginfo::CC.ArgInfo
    )
    # check each match for union-split signature
    split_argtypes = empty_matches = nothing
    for (i, matchinfo) in enumerate(info.split)
        if CC.isempty(matchinfo.results)
            if isnothing(split_argtypes)
                split_argtypes = CC.switchtupleunion(CC.typeinf_lattice(analyzer), arginfo.argtypes)
            end
            argtypes′ = split_argtypes[i]::Vector{Any}
            if empty_matches === nothing
                empty_matches = (Any[], length(info.split))
            end
            sig_n = CC.argtypes_to_type(argtypes′)
            push!(empty_matches[1], sig_n)
        end
    end
    if empty_matches !== nothing
        add_new_report!(analyzer, sv.result, NoMethodMatchReport(sv, empty_matches...))
    end
end

# UnsupportedKeywordArgReport
# ---------------------------

# A call like `f(; unknownkw=...)` is lowered to `Core.kwcall((unknownkw=...,), f)`.
# This dispatches successfully to `f`'s generated keyword sorter, which then throws a
# `MethodError` via `Base.kwerr` for the surplus keyword. Since this is an explicit
# `throw` rather than a dispatch failure, `NoMethodMatchReport` does not fire; we detect
# the statically-determined surplus keyword here instead.
@jetreport struct UnsupportedKeywordArgReport <: MethodErrorReport
    @nospecialize ftype
    posargtypes::Vector{Any}
    @nospecialize kwt
    unsupported::Vector{Symbol}
end
function JETInterface.print_report_message(io::IO, r::UnsupportedKeywordArgReport)
    unsupported = r.unsupported
    print(io, "unsupported keyword argument")
    isone(length(unsupported)) || print(io, 's')
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
    # Keep a trailing `Vararg` intact (a splatted call like `f(xs...; kw=v)`) instead of
    # widening it into a bogus element; this also renders as `f(::T...)` in the report message.
    posargtypes = Any[let argtype = argtypes[i]
        CC.isvarargtype(argtype) ? argtype : CC.widenconst(argtype)
    end for i = 4:length(argtypes)]
    # Bound the lookup by inference's own `max_methods` (as `find_method_matches` does), so a
    # pathologically large match set (e.g. when `ftype` is abstract) bails cleanly rather than
    # enumerating every applicable method. `findall` returns `nothing` past the limit.
    # `argtypes_to_type` collapses dead paths (a `Union{}` argument) to `Bottom`, where a plain
    # `Tuple{...}` would error on a `Union{}` field.
    callsig = CC.argtypes_to_type(Any[ftype; posargtypes])
    callsig === Union{} && return false
    matches = @something CC.findall(callsig, CC.method_table(analyzer); limit=max_methods) return false
    isempty(matches) && return false
    supported = Set{Symbol}()
    for match in matches
        for name in Base.kwarg_decl(match.method)
            # a slurping `kwargs...` shows up as a name ending with `...` and accepts anything
            endswith(String(name), "...") && return false
            push!(supported, name)
        end
    end

    unsupported = Symbol[name for name in kwnames if name ∉ supported]
    isempty(unsupported) && return false

    report = UnsupportedKeywordArgReport(sv, ftype, posargtypes, kwt, unsupported)
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

# Calling a function without one of its required keyword arguments (a keyword without a
# default) raises `UndefKeywordError` at runtime. Detect this at the call site (not at the
# `throw` inside the synthesized keyword sorter) so the report stays independent of analysis
# order: the throw site only fires while the callee is freshly inferred, but its result —
# including whether the call diverges — is cached and reused, which would make the report
# appear or vanish depending on which signature got analyzed first.
@jetreport struct UndefKeywordErrorReport <: JETLSErrorReport
    var::Symbol
end
JETInterface.print_report_message(io::IO, r::UndefKeywordErrorReport) =
    print(io, "missing keyword argument `", r.var, '`')
inference_error_report_stack_impl(r::UndefKeywordErrorReport) = length(r.vst):-1:1
inference_error_report_severity_impl(::UndefKeywordErrorReport) = DiagnosticSeverity.Warning

function report_undef_keyword!(
        analyzer::LSAnalyzer, sv::CC.InferenceState, @nospecialize(func),
        call::CC.CallMeta, arginfo::CC.ArgInfo, max_methods::Int
    )
    # Decide *whether* to report from the return / exception types, which survive caching
    # (`call.exct` carries the missing keyword as `Const(UndefKeywordError(name))` only while
    # the callee is freshly inferred, and widens to the bare `UndefKeywordError` type once
    # cached). Recover the *name* from the callee's declared keywords so both presence and
    # message stay independent of analysis order.
    call.rt === Union{} || return false
    CC.widenconst(call.exct) <: UndefKeywordError || return false
    argtypes = arginfo.argtypes
    if func === Core.kwcall
        # `Core.kwcall(kwnt, f, posargs...)`
        length(argtypes) ≥ 3 || return false
        provided = @something kwcall_keyword_names(CC.widenconst(argtypes[2])) return false
        ftype = CC.widenconst(argtypes[3])
        posbase = 4
    else
        # direct call with no keywords (the function's zero-keyword convenience method)
        provided = ()
        ftype = CC.widenconst(argtypes[1])
        posbase = 2
    end
    # `arginfo.argtypes` may end in a `Vararg` (e.g. a splatted call like `f(xs...)`), and a
    # positional argument may even be `Union{}` on a dead path. `argtypes_to_type` keeps a
    # trailing vararg intact and collapses such dead paths to `Bottom`, where a plain
    # `Tuple{...}` would instead error on a vararg or `Union{}` field.
    callargtypes = Any[ftype]
    append!(callargtypes, @view argtypes[posbase:end])
    callsig = CC.argtypes_to_type(callargtypes)
    callsig === Union{} && return false
    matches = @something CC.findall(callsig, CC.method_table(analyzer); limit=max_methods) return false
    isempty(matches) && return false
    for match in matches
        for name in Base.kwarg_decl(match.method)
            endswith(String(name), "...") && continue # slurp absorbs any missing keyword
            name ∈ provided && continue
            # first declared keyword not supplied; the keyword sorter throws for the first
            # such *required* one, which this matches under the usual required-before-optional
            # declaration order
            add_new_report!(analyzer, sv.result, UndefKeywordErrorReport(sv, name))
            return true
        end
    end
    return false
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

# Recover the declared keyword types of `m` as `name => type` pairs (declaration order),
# skipping the slurp (`kws...`). The keyword sorter forwards the sorted keywords to the body
# function as leading positional arguments, so the body method's argument types are exactly the
# declared keyword types in `Base.kwarg_decl` order.
function keyword_arg_types(m::Method)
    decls = Base.kwarg_decl(m)
    isempty(decls) && return nothing
    bf = Base.bodyfunction(m)
    bf === nothing && return nothing
    bms = methods(bf)
    length(bms) == 1 || return nothing
    bsig = Base.unwrap_unionall((first(bms)).sig)
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
    posargtypes = Any[let argtype = argtypes[i]
        CC.isvarargtype(argtype) ? argtype : CC.widenconst(argtype)
    end for i = 4:length(argtypes)]
    callsig = CC.argtypes_to_type(Any[ftype; posargtypes])
    callsig === Union{} && return false
    matches = @something CC.findall(callsig, CC.method_table(analyzer); limit=max_methods) return false
    isempty(matches) && return false
    for match in matches
        kwtypes = @something keyword_arg_types(match.method) continue
        for (name, expected) in kwtypes
            idx = findfirst(==(name), names)
            idx === nothing && continue # this typed keyword was not provided
            got = fieldtype(kwt, idx)
            # report only a definite mismatch: no value of `got` can satisfy the keyword's
            # `isa expected` assertion (the `call.rt === Union{}` gate already ensures the call
            # always throws, so this picks the offending keyword)
            typeintersect(got, expected) === Union{} || continue
            add_new_report!(analyzer, sv.result, KeywordTypeErrorReport(sv, name, expected, got))
            return true
        end
    end
    return false
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
                if info === nothing
                    info = Any[], length(uts)
                end
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
        jetconfigs...
    )
    jetconfigs = JET.kwargs_dict(jetconfigs)
    jetconfigs[:aggressive_constant_propagation] = true
    # Enable the `assume_bindings_static` option to terminate analysis a bit earlier when
    # there are undefined bindings detected. Note that this option will cause inference
    # cache inconsistency until JuliaLang/julia#40399 is merged. But the analysis cache of
    # LSAnalyzer has the same problem already anyway, so enabling this option does not
    # make the situation worse.
    jetconfigs[:assume_bindings_static] = true
    state = AnalyzerState(world; jetconfigs...)
    return LSAnalyzer(entry, state; report_target_modules)
end

const LS_ANALYZER_CONFIGURATIONS = Set{Symbol}((:report_target_modules,))

let valid_keys = JET.GENERAL_CONFIGURATIONS ∪ LS_ANALYZER_CONFIGURATIONS
    @eval JETInterface.valid_configurations(::LSAnalyzer) = $valid_keys
end

end # module Analyzer
