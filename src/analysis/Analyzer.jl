module Analyzer

export LSAnalyzer, inference_error_report_stack, inference_error_report_severity, initialize_cache!

using Core.IR
using JET.JETInterface
using JET: JET, CC

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
inference_error_report_severity_impl(@nospecialize report::JET.InferenceErrorReport) =
    DiagnosticSeverity.Warning
inference_error_report_severity(@nospecialize report::JET.InferenceErrorReport) =
    inference_error_report_severity_impl(report)::DiagnosticSeverity.Ty

"""
    InterpretationStateCache

Internal state that allows `LSAnalyzer` to access the state of `LSInterpreter`.
Initialized when `LSInterpreter` receives a new `JET.InterpretationState`,
and lazily computes cache information when utility functions are used.
"""
mutable struct InterpretationStateCache
    info::Union{Dict{String,JET.AnalyzedFileInfo}, Set{Module}}
    InterpretationStateCache() = new()
end

const empty_analyzed_modules = Set{Module}()

function _analyzed_modules!(cache::InterpretationStateCache)
    isdefined(cache, :info) || return empty_analyzed_modules
    info = cache.info
    if info isa Set{Module}
        return info
    end
    newinfo = Set{Module}()
    for (_, analyzed_file_info) in info
        for module_range_info in analyzed_file_info.module_range_infos
            push!(newinfo, last(module_range_info))
        end
    end
    return cache.info = newinfo
end

"""
    LSAnalyzer <: AbstractAnalyzer

This is a code analyzer specially designed for the language server.
It is implemented using the `JET.AbstractAnalyzer` framework,
extending the base abstract interpretation performed by the Julia compiler
to detect errors during analysis, along with analyzing types and effects.

Currently, it analyzes the following errors:
- `UndefVarErrorReport`: Reports undefined variables:
  * [x] Reports undefined global variables
  * [x] Reports undefined local variables
  * [ ] Reports undefined static parameters
"""
struct LSAnalyzer <: ToplevelAbstractAnalyzer
    state::AnalyzerState
    analysis_token::AnalysisToken
    cache::InterpretationStateCache
    method_table::CC.CachedMethodTable{CC.InternalMethodTable}
    function LSAnalyzer(state::AnalyzerState, analysis_token::AnalysisToken, cache::InterpretationStateCache)
        method_table = CC.CachedMethodTable(CC.InternalMethodTable(state.world))
        return new(state, analysis_token, cache, method_table)
    end
end
function LSAnalyzer(entry::AnalysisEntry, state::AnalyzerState)
    analysis_cache_key = JET.compute_hash(entry, state.inf_params)
    analysis_token = get!(AnalysisToken, LS_ANALYZER_CACHE, analysis_cache_key)
    cache = InterpretationStateCache()
    return LSAnalyzer(state, analysis_token, cache)
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

JETInterface.AnalyzerState(analyzer::LSAnalyzer) = analyzer.state
function JETInterface.AbstractAnalyzer(analyzer::LSAnalyzer, state::AnalyzerState)
    # XXX `analyzer.analysis_token` doesn't respect changes in `state.inf_params`
    return LSAnalyzer(state, analyzer.analysis_token, analyzer.cache)
end
JETInterface.AnalysisToken(analyzer::LSAnalyzer) = analyzer.analysis_token

const LS_ANALYZER_CACHE = Dict{UInt, AnalysisToken}()

# internal API
# ============

function initialize_cache!(analyzer::LSAnalyzer, analyzed_files::Dict{String,JET.AnalyzedFileInfo})
    analyzer.cache.info = analyzed_files
    nothing
end

# utilities
# =========

analyzed_modules!(analyzer::LSAnalyzer) = _analyzed_modules!(analyzer.cache)

function should_analyze(analyzer::LSAnalyzer, sv::CC.InferenceState)
    analyzed_modules = analyzed_modules!(analyzer)
    return isempty(analyzed_modules) || CC.frame_module(sv) ∈ analyzed_modules
end

# analysis injections
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

function CC.abstract_call_gf_by_type(analyzer::LSAnalyzer,
    @nospecialize(func), arginfo::CC.ArgInfo, si::CC.StmtInfo, @nospecialize(atype), sv::CC.InferenceState,
    max_methods::Int)
    ret = @invoke CC.abstract_call_gf_by_type(analyzer::ToplevelAbstractAnalyzer,
        func::Any, arginfo::CC.ArgInfo, si::CC.StmtInfo, atype::Any, sv::CC.InferenceState, max_methods::Int)
    if !should_analyze(analyzer, sv)
        return ret
    end
    atype′ = Ref{Any}(atype)
    function after_abstract_call_gf_by_type(analyzer′::LSAnalyzer, sv′::CC.InferenceState)
        ret′ = ret[]
        report_method_error!(analyzer′, sv′, ret′, arginfo, atype′[])
        return true
    end
    if isready(ret)
        after_abstract_call_gf_by_type(analyzer, sv)
    else
        push!(sv.tasks, after_abstract_call_gf_by_type)
    end
    return ret
end

# TODO Better to factor out and share it with `JET.JETAnalyzer`
function CC.abstract_eval_globalref(analyzer::LSAnalyzer,
    g::GlobalRef, saw_latestworld::Bool, sv::CC.InferenceState)
    if saw_latestworld
        return CC.RTEffects(Any, Any, CC.generic_getglobal_effects)
    end
    (valid_worlds, ret) = CC.scan_leaf_partitions(analyzer, g, sv.world) do analyzer::LSAnalyzer, binding::Core.Binding, partition::Core.BindingPartition
        if should_analyze(analyzer, sv)
            if partition.min_world ≤ sv.world.this ≤ partition.max_world # XXX This should probably be fixed on the Julia side
                report_undef_global_var!(analyzer, sv, binding, partition)
            end
        end
        CC.abstract_eval_partition_load(analyzer, binding, partition)
    end
    CC.update_valid_age!(sv, valid_worlds)
    return ret
end

# inject report pass for undefined local variables
function CC.abstract_eval_special_value(analyzer::LSAnalyzer, @nospecialize(e), sstate::CC.StatementState, sv::CC.InferenceState)
    if should_analyze(analyzer, sv)
        if e isa SlotNumber
            vtypes = sstate.vtypes
            if vtypes !== nothing
                report_undefined_local_vars!(analyzer, sv, e, vtypes)
            end
        end
    end
    return @invoke CC.abstract_eval_special_value(analyzer::ToplevelAbstractAnalyzer, e::Any, sstate::CC.StatementState, sv::CC.InferenceState)
end

# analysis
# ========

# MethodErrorReport
# -----------------

@jetreport struct MethodErrorReport <: InferenceErrorReport
    @nospecialize t # ::Union{Type, Vector{Type}}
    union_split::Int
end
function JETInterface.print_report_message(io::IO, report::MethodErrorReport)
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
inference_error_report_stack_impl(r::MethodErrorReport) = length(r.vst):-1:1
inference_error_report_severity_impl(r::MethodErrorReport) = DiagnosticSeverity.Warning

function report_method_error!(analyzer::LSAnalyzer,
    sv::CC.InferenceState, call::CC.CallMeta, arginfo::CC.ArgInfo, @nospecialize(atype))
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

function report_method_error!(analyzer::LSAnalyzer, sv::CC.InferenceState, info::CC.MethodMatchInfo, @nospecialize(atype))
    if CC.isempty(info.results)
        report = MethodErrorReport(sv, atype, 0)
        add_new_report!(analyzer, sv.result, report)
        return true
    end
    return false
end

function report_method_error_for_union_split!(analyzer::LSAnalyzer, sv::CC.InferenceState, info::CC.UnionSplitInfo, arginfo::CC.ArgInfo)
    # check each match for union-split signature
    split_argtypes = empty_matches = nothing
    reported = false
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
        add_new_report!(analyzer, sv.result, MethodErrorReport(sv, empty_matches...))
        reported |= true
    end
    return reported
end

# UndefVarErrorReport
# -------------------

@jetreport struct UndefVarErrorReport <: InferenceErrorReport
    var::Union{GlobalRef,TypeVar,Symbol}
    maybeundef::Bool
end
function JETInterface.print_report_message(io::IO, r::UndefVarErrorReport)
    var = r.var
    if isa(var, TypeVar) # TODO show "maybe undefined" case nicely?
        print(io, "`", var.name, "` not defined in static parameter matching")
    else
        if isa(var, GlobalRef)
            print(io, "`", var.mod, '.', var.name, "`")
        else
            print(io, "local variable `", var, "`")
        end
        if r.maybeundef
            print(io, " may be undefined")
        else
            print(io, " is not defined")
        end
    end
end
inference_error_report_stack_impl(r::UndefVarErrorReport) = length(r.vst):-1:1
inference_error_report_severity_impl(r::UndefVarErrorReport) =
    r.maybeundef ? DiagnosticSeverity.Information : DiagnosticSeverity.Warning

function report_undef_global_var!(analyzer::LSAnalyzer,
    sv::CC.InferenceState, binding::Core.Binding, partition::Core.BindingPartition)
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
    add_new_report!(analyzer, sv.result, UndefVarErrorReport(sv, gr, maybeundef))
    return true
end

function report_undefined_local_vars!(analyzer::LSAnalyzer, sv::CC.InferenceState, var::SlotNumber, vtypes::CC.VarTable)
    if JET.isconcretized(analyzer, sv)
        return false # no need to be analyzed
    end
    vtype = vtypes[JET.slot_id(var)]
    vtype.undef || return false
    if !JET.is_constant_propagated(sv)
        if isempty(sv.ssavalue_uses[sv.currpc])
            # This case is when an undefined local variable is just declared,
            # but such cases can become reachable when constant propagation
            # for capturing closures doesn't occur.
            # In the future, improvements to the compiler should make such cases
            # unreachable in the first place, but for now we completely ignore
            # such cases to suppress false positives.
            return false
        end
    end
    name = JET.get_slotname(sv, var)
    if name === Symbol("")
        # Such unnamed local variables are mainly introduced by `try/catch/finally` clauses.
        # Due to insufficient liveness analysis of the current compiler for such code,
        # the isdefined-ness of such variables may not be properly determined.
        # For the time being, until the compiler implementation is improved,
        # we ignore this case to suppress false positives.
        return false
    end
    maybeundef = vtype.typ !== Union{}
    add_new_report!(analyzer, sv.result, UndefVarErrorReport(sv, name, maybeundef))
    return true
end

# Constructor
# ===========

# the entry constructor
function LSAnalyzer(entry::AnalysisEntry,
                    world::UInt = Base.get_world_counter();
                    jetconfigs...)
    jetconfigs = JET.kwargs_dict(jetconfigs)
    jetconfigs[:aggressive_constant_propagation] = true
    # Enable the `assume_bindings_static` option to terminate analysis a bit earlier when
    # there are undefined bindings detected. Note that this option will cause inference
    # cache inconsistency until JuliaLang/julia#40399 is merged. But the analysis cache of
    # LSAnalyzer has the same problem already anyway, so enabling this option does not
    # make the situation worse.
    jetconfigs[:assume_bindings_static] = true
    state = AnalyzerState(world; jetconfigs...)
    return LSAnalyzer(entry, state)
end

const LS_ANALYZER_CONFIGURATIONS = Set{Symbol}(())

let valid_keys = JET.GENERAL_CONFIGURATIONS ∪ LS_ANALYZER_CONFIGURATIONS
    @eval JETInterface.valid_configurations(::LSAnalyzer) = $valid_keys
end

end # module Analyzer
