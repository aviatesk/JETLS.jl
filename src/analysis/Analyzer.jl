module Analyzer

export LSAnalyzer, inference_error_report_severity, inference_error_report_stack, reset_report_target_modules!
export BoundsErrorReport, FieldErrorReport, UndefVarErrorReport

using Core.IR
using JET.JETInterface
using JET: CC, JET

using ..JETLS: AnalysisEntry, JETLS
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
to detect [`LSErrorReport`](@ref)s, along with analyzing types and effects.
"""
struct LSAnalyzer <: ToplevelAbstractAnalyzer
    state::AnalyzerState
    analysis_token::AnalysisToken
    method_table::CC.CachedMethodTable{CC.InternalMethodTable}

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
        method_table = CC.CachedMethodTable(CC.InternalMethodTable(state.world))
        return new(state, analysis_token, method_table, report_target_modules, invariable_analysis_hash)
    end
end

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
    # The case `report_target_modules === missing` is a special case.
    # In this case, `report_target_modules` is tracked incrementally using `reset_report_target_modules!`,
    # but this is only used by the legacy analysis mode, and in that mode,
    # analysis is performed by creating anonymous modules that essentially represent the same module,
    # so there is no need to separate the cache by the identity of those anonymous modules
    report_target_modules_hash = objectid(report_target_modules)
    invariable_analysis_hash = JET.compute_hash(entry, report_target_modules_hash)
    analysis_cache_key = JET.compute_hash(state.inf_params, invariable_analysis_hash)
    analysis_token = @lock LS_ANALYZER_CACHE_LOCK get!(AnalysisToken, LS_ANALYZER_CACHE, analysis_cache_key)
    if report_target_modules === missing
        report_target_modules = Set{Module}()
    elseif report_target_modules !== nothing
        report_target_modules = Set{Module}(report_target_modules)
    end
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
function JETInterface.AbstractAnalyzer(
        analyzer::LSAnalyzer, state::AnalyzerState;
        resolver_mode::Bool = false
    )
    if resolver_mode
        # Use special analysis cache for resolver purposes
        analysis_cache_key = JET.compute_hash(state, analyzer.invariable_analysis_hash, resolver_hash)
        # Force target modules to be empty and shutdown the report system
        @assert isempty(empty_target_modules)
        report_target_modules = empty_target_modules
    else
        analysis_cache_key = JET.compute_hash(state.inf_params, analyzer.invariable_analysis_hash)
        report_target_modules = analyzer.report_target_modules
    end
    analysis_token = @lock LS_ANALYZER_CACHE_LOCK get!(AnalysisToken, LS_ANALYZER_CACHE, analysis_cache_key)
    return LSAnalyzer(state, analysis_token, report_target_modules, analyzer.invariable_analysis_hash)
end
JETInterface.AnalysisToken(analyzer::LSAnalyzer) = analyzer.analysis_token

const LS_ANALYZER_CACHE = Dict{UInt,AnalysisToken}()
const LS_ANALYZER_CACHE_LOCK = ReentrantLock()

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
        # but this will lead to lots of false positive `MethodErrorReport`s for inference
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

# analysis
# ========

"""
    LSErrorReport <: InferenceErrorReport

Abstract type for error reports analyzed by [`LSAnalyzer`](@ref).

Subtypes:
- `UndefVarErrorReport`: Undefined variables (global, static parameters[^unimplemented])
- `FieldErrorReport`: Access to non-existent struct fields
- `BoundsErrorReport`: Out-of-bounds field access by index
- `MethodErrorReport`: Method dispatch errors[^unimplemented]

[^unimplemented]: Currently unimplemented.
"""
abstract type LSErrorReport <: InferenceErrorReport end

# UndefVarErrorReport
# -------------------

@jetreport struct UndefVarErrorReport <: LSErrorReport
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
    if @invokelatest isdefinedglobal(gr.mod, gr.name)
        # HACK/FIXME Concretize `AbstractBindingState`
        x = @invokelatest getglobal(gr.mod, gr.name)
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

@jetreport struct FieldErrorReport <: LSErrorReport
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

@jetreport struct BoundsErrorReport <: LSErrorReport
    @nospecialize a
    i::Int
    vst_offset::Int
end
JETInterface.print_report_message(io::IO, r::BoundsErrorReport) =
    print(io, lazy"BoundsError: attempt to access $(r.a) at index [$(r.i)]")
inference_error_report_stack_impl(r::BoundsErrorReport) = (length(r.vst)-r.vst_offset):-1:1
inference_error_report_severity_impl(::BoundsErrorReport) = DiagnosticSeverity.Warning

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
        end
    end
end

const MODULE_SETFIELD_MSG = "cannot assign variables in other modules"
type_error_msg(f, expected, actual) = (@nospecialize;
    lazy"TypeError: in $f, expected $expected, got a value of type $actual")

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
            s00 = s = s.parameters[1]
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
