module Analyzer

export LSAnalyzer, inference_error_report_stack, initialize_cache!

using Core.IR
using JET.JETInterface
using JET: JET, CC

using ..JETLS: AnalysisEntry

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
  * [ ] Reports undefined local variables
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

# TODO Better to factor out and share it with `JET.JETAnalyzer`
function CC.abstract_eval_globalref(analyzer::LSAnalyzer,
    g::GlobalRef, saw_latestworld::Bool, sv::CC.InferenceState)
    if saw_latestworld
        return CC.RTEffects(Any, Any, CC.generic_getglobal_effects)
    end
    analyzed_modules = analyzed_modules!(analyzer)
    (valid_worlds, ret) = CC.scan_leaf_partitions(analyzer, g, sv.world) do analyzer::LSAnalyzer, binding::Core.Binding, partition::Core.BindingPartition
        if isempty(analyzed_modules) || CC.frame_module(sv) ∈ analyzed_modules
            if partition.min_world ≤ sv.world.this ≤ partition.max_world # XXX This should probably be fixed on the Julia side
                report_undef_global_var!(analyzer, sv, binding, partition)
            end
        end
        CC.abstract_eval_partition_load(analyzer, binding, partition)
    end
    CC.update_valid_age!(sv, valid_worlds)
    return ret
end

# analysis
# ========

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
    # JETAnalyzer has the same problem already anyway, so enabling this option does not
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
