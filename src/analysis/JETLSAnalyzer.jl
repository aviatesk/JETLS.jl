using Core.IR
using JET.JETInterface
using JET: JET, CC

"""
    JETLSAnalyzer <: AbstractAnalyzer

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
struct JETLSAnalyzer <: AbstractAnalyzer
    state::AnalyzerState
    analysis_token::AnalysisToken
    method_table::CC.CachedMethodTable{CC.InternalMethodTable}
    function JETLSAnalyzer(state::AnalyzerState, analysis_token::AnalysisToken)
        method_table = CC.CachedMethodTable(CC.InternalMethodTable(state.world))
        return new(state, analysis_token, method_table)
    end
    function JETLSAnalyzer(state::AnalyzerState)
        cache_key = JET.compute_hash(state.inf_params)
        analysis_token = get!(AnalysisToken, LS_ANALYZER_CACHE, cache_key)
        return JETLSAnalyzer(state, analysis_token)
    end
end

# AbstractInterpreter API
# =======================

# JETLSAnalyzer does not need any sources, so discard them always
CC.maybe_compress_codeinfo(::JETLSAnalyzer, ::MethodInstance, ::CodeInfo) = nothing
CC.may_optimize(::JETLSAnalyzer) = false
CC.method_table(analyzer::JETLSAnalyzer) = analyzer.method_table
CC.typeinf_lattice(::JETLSAnalyzer) =
    CC.InferenceLattice(CC.MustAliasesLattice(CC.BaseInferenceLattice.instance))
CC.ipo_lattice(::JETLSAnalyzer) =
    CC.InferenceLattice(CC.InterMustAliasesLattice(CC.IPOResultLattice.instance))

# AbstractAnalyzer API
# ====================

JETInterface.AnalyzerState(analyzer::JETLSAnalyzer) = analyzer.state
function JETInterface.AbstractAnalyzer(analyzer::JETLSAnalyzer, state::AnalyzerState)
    return JETLSAnalyzer(state, )
end
JETInterface.AnalysisToken(analyzer::JETLSAnalyzer) = analyzer.analysis_token

const LS_ANALYZER_CACHE = IdDict{UInt, AnalysisToken}()

# analysis injections
# ===================

"""
    bail_out_call(analyzer::JETLSAnalyzer, ...)

This overload makes call inference performed by `JETLSAnalyzer` not bail out even when
inferred return type grows up to `Any` to collect as much error reports as possible.
That potentially slows down inference performance, but it would stay to be practical
given that the number of matching methods are limited beforehand.
"""
CC.bail_out_call(::JETLSAnalyzer, ::CC.InferenceLoopState, ::CC.InferenceState) = false

"""
    bail_out_toplevel_call(analyzer::JETLSAnalyzer, ...)

This overload allows `JETLSAnalyzer` to keep inference going on
non-concrete call sites in a toplevel frame created by `JET.virtual_process`.
"""
CC.bail_out_toplevel_call(::JETLSAnalyzer, ::CC.InferenceState) = false

# TODO Better to factor out and share it with `JET.JETAnalyzer`
function CC.abstract_eval_globalref(analyzer::JETLSAnalyzer,
    g::GlobalRef, saw_latestworld::Bool, sv::CC.InferenceState)
    if saw_latestworld
        return CC.RTEffects(Any, Any, CC.generic_getglobal_effects)
    end
    (valid_worlds, ret) = CC.scan_leaf_partitions(analyzer, g, sv.world) do analyzer::AbstractAnalyzer, binding::Core.Binding, partition::Core.BindingPartition
        if partition.min_world ≤ sv.world.this ≤ partition.max_world # XXX This should probably be fixed on the Julia side
            report_undef_global_var!(analyzer, sv, binding, partition)
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
function report_undef_global_var!(analyzer::JETLSAnalyzer,
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
function JETLSAnalyzer(world::UInt = Base.get_world_counter();
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
    return JETLSAnalyzer(state)
end

const LS_ANALYZER_CONFIGURATIONS = Set{Symbol}(())

let valid_keys = JET.GENERAL_CONFIGURATIONS ∪ LS_ANALYZER_CONFIGURATIONS
    @eval JETInterface.valid_configurations(::JETLSAnalyzer) = $valid_keys
end
