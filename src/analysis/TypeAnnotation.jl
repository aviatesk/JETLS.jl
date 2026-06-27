"""
    TypeAnnotation

Type-annotation pipeline for the LSP feature path: parse → lower → infer → query.
Produces a `SyntaxTreeC` whose nodes carry `:type` attributes computed by a custom
`CC.AbstractInterpreter`, plus a query handle ([`InferredTreeContext`](@ref)) for
byte-range type lookups.

# Exported API

LSP feature code should normally only need these:

- [`build_inferred_context_for_range`](@ref) locates the top-level tree containing a
  byte range and returns an [`InferredTreeContext`](@ref). Use
  [`build_inferred_context_for_tree`](@ref) when the caller already has the lowerable
  top-level tree. Pass `cache` when the caller can reuse inferred contexts for the
  same document version.
- [`get_type_for_range`](@ref) queries the inferred type at a surface byte range
  from an [`InferredTreeContext`](@ref).
- [`get_matches_for_range`](@ref) queries the `Vector{Core.MethodMatch}` that
  CC's dispatch picked at a call site, for features that want narrower jumps
  than `methods(callee)` (go-to-method-definition).
- [`InferredTreeContext`](@ref) is exported so feature code can spell its type
  in signatures (e.g. `Union{Nothing,InferredTreeContext}`).

The lower-level pipeline is documented because its prerequisites and
limitations determine what the exported API can return. In particular, every
type surfaced through [`get_type_for_range`](@ref) is subject to the constraints
in "Prerequisite" and "Limitations".

# Pipeline

The pipeline has four steps. Each step's output feeds the next:

1. **Lower for scope resolution**:
   [`get_inferrable_tree(st0::SyntaxTreeC, context_module::Module) -> (; ctx3::JL.VariableAnalysisContext, st3::SyntaxTreeC) | nothing`](@ref get_inferrable_tree)
   walks a top-level `st0` through JuliaLowering's early scope passes against
   `context_module`, returning an `(ctx3, st3)` pair. Surface `K"error"` nodes are stripped
   first so incomplete user input still produces a usable lowered tree.

2. **Infer & annotate**:
   [`infer_toplevel_tree(ctx3::JL.VariableAnalysisContext, st3::SyntaxTreeC, st0::SyntaxTreeC, context_module::Module; world::UInt = Base.get_world_counter()) -> inferred_tree::SyntaxTreeC`](@ref infer_toplevel_tree)
   takes `(ctx3, st3)` through the remaining JuliaLowering passes (`convert_closures` →
   `linearize_ir`), runs CC inference under the internal `ASTTypeAnnotator`, and
   writes the inferred type of each lowered statement back into the tree as a
   `:type` attribute. The result is a `inferred_tree::SyntaxTreeC` whose nodes — both at
   toplevel and inside method bodies — carry per-statement types.

3. **Build query indexes**:
   [`build_inferred_context_for_range`](@ref) wraps the annotated tree with
   \$O(N)\$-built indexes (`by_byte_range`, `surface_kind_index`, OC body scope,
   …) so downstream queries are \$O(1)\$ per call. Build once per inferred tree,
   reuse across many queries.

4. **Query**:
   [`get_type_for_range(ctx::InferredTreeContext, rng::UnitRange{<:Integer}) -> typ`](@ref get_type_for_range)
   is the main entry point: given a surface byte range, it picks a lookup strategy based on
   the lowered surface kind (`K"call"`, `K"macrocall"`, `K"function"`, branching forms, …)
   and returns the inferred lattice element.

For LSP feature code, [`build_inferred_context_for_range`](@ref) and
[`build_inferred_context_for_tree`](@ref) collapse steps 1–3 into a single call
(locate or accept the toplevel, run the pipeline, return a ready-to-query
[`InferredTreeContext`](@ref), optionally through a per-document-version cache).

# Prerequisite: full-analysis must have run first

`context_module` must already be populated by the time we reach this pipeline.
Full analysis runs JET's concrete interpretation against the user's source
through Julia's *own* lowering pipeline, materializing the user's bindings
(functions, types, constants) into the appropriate module. By the time a hover /
completion / inlay-hint reaches this pipeline, the caller has chosen
`context_module` based on those full-analysis results, and we run a lightweight
and stateless pass on top.

The dependency is concrete, not advisory: the per-method-body argtypes
resolution in step 2 works by `getfield`-ing user names out of `context_module`
(e.g. evaluating `Core.Typeof(Main.f)`, `Core.apply_type(Main.Vector, Main.Int)`).
Without those bindings present, every user-defined name falls through to `Any` and
method bodies are inferred against `Any` argtypes.

# Anonymous-thunk inference unit

The basic inference unit is a thunk: a `Core.CodeInfo` paired with a
`SyntaxTreeC` whose first statement is the block of statements to annotate, plus
a list of slot argtypes. The toplevel itself is one such thunk (`nargs=0`);
method definitions are handled the same way — *not* via `Method` / `MethodInstance`
dispatch, but by treating each method's body `CodeInfo` as another anonymous thunk
whose argtypes are statically evaluated from its sig svec against `context_module`.
No `Method` lookup, no dispatch, no `Base._which`.

!!! note "Why we don't let `CC.typeinf` recurse into `:method` itself"
    The straightforward alternative would be to let inference of the toplevel
    thunk recurse into `:method` 3-arg statements via the usual dispatch path.
    That path doesn't reach `function f(...; kw...) end`: JuliaLowering
    introduces synthetic kwbody bindings (e.g. `var"#kw_body#f#0"`) whose names
    don't match the bindings full analysis materialized in `context_module` via
    Julia's own lowering. Going through dispatch would either fail or hit stale
    entries. Static svec evaluation avoids both; the synthetic-name slot simply
    degrades to `Any` (see Limitations).

# Closure argument-type refinement

Untyped closure parameters (`do x`, `x -> ...`) have no declared types to feed the
body's signature-view inference, so a single pass would annotate such bodies against
`Tuple{Any,…}`. Instead, [`infer_toplevel_tree`](@ref) runs up to
`MAX_OC_REFINEMENT_PASSES` inference passes: each pass records OC argtypes observed
at calls and iterator adaptor construction sites (`record_oc_argtype_observation!`,
keyed by body byte range), and the next pass substitutes the per-slot join into the
declared-`Any` slots of the OC's argt (`refine_partial_opaque_argt`) before the eager
body inference runs. Body
annotations therefore stay a deterministic signature view — the signature itself is just
inferred from observed call sites, the same annotation model as Kotlin/Swift-style
lambda parameter inference. Refinement fills only the unannotated blanks, per slot:
non-`Any` user annotations are authoritative and never refined (such slots behave
exactly like top-level typed method parameters), while an explicit `::Any` annotation
is indistinguishable from an unannotated parameter after lowering and is refined the
same way. Closures never called within the analyzed tree keep their `Any` view.

# Limitations

The static-svec approach inherits a few precision losses around lowering's
synthetic binding constructs. None of these break correctness; they only degrade
types to `Any`.

- **Closures**: Single-method local closures are rewritten to `K"_opaque_closure"`
  by [`Closure2Opaque.rewrite_local_closures_to_opaque`](@ref) before
  `JL.convert_closures`, so CC's native `OpaqueClosure` path handles them
  precisely (body, captures, and call sites all infer). Multi-method local
  closures (same name with multiple method definitions) aren't representable as
  a single OC, so the rewrite skips them and JL's synthetic struct path takes
  over. JL's standard runtime materializes the synthetic struct type before
  dispatch, but `infer_toplevel_tree` deliberately avoids `Core.eval` to keep
  analysis side-effect-free, so the synthetic type never appears in
  `context_module` and call sites collapse to `Any`.

- **Synthetic kwbody self.** Same shape as the closure self issue: in the
  kwbody method, slot 1 resolves to `Any` because the synthetic name isn't
  defined in `context_module`. User-named slots (`init`, `xs`, …) still resolve
  correctly via the svec, so the body code itself is inferred precisely.

- **Parametric methods.** Signature types statically evaluated from the argtypes
  svec are normalized to contain no free `TypeVar`s: a bare `T` collapses to its
  upper bound, while nested uses such as `Vector{T}` are existentially closed.
  Furthermore, the thunk's `MethodInstance` is a thunk MI (`def isa Module`);
  CC's `sptypes_from_meth_instance` forces `EMPTY_SPTYPES` for toplevel MIs, so an
  `Expr(:static_parameter, i)` reference inside the body cannot retrieve `T` and
  infers as `Any`.
"""
module TypeAnnotation

using Core.IR
using JET: CC, JET
using ..JETLS: InferredContextCache, InferredContextCacheData, SyntaxTreeC, TraversalReturn
using ..JETLS: JETLS_DEBUG_LOWERING, JETLS_DEV_MODE, JL, JS
using ..JETLS: get_name_val, iterate_toplevel_tree, jl_lower_for_scope_resolution, load,
    rewrite_local_closures_to_opaque, store!, traverse
import ..JETLS: InferredTreeContext

export InferredTreeContext,
    build_inferred_context_for_range, build_inferred_context_for_tree,
    get_matches_for_range, get_type_for_range, is_type_annotation_skipped_toplevel

# ASTTypeAnnotator
# ================

struct ASTTypeAnnotatorToken end

# Keyed per OC body byte range plus the OC's parameter names — both stable across
# re-lowering passes, unlike `Method` identity. The byte range alone is ambiguous:
# nested generator lambdas (`[x + y for x in xs for y in ys]`) all collapse their body
# provenance onto the same user expression, and a range-only key would cross-apply one
# lambda's observations to another. One entry per OC parameter slot; used both for
# call-site argtype observations and for the refinements derived from them.
const OCArgtypeKey = Tuple{UnitRange{Int},Tuple{Vararg{Symbol}}}
const OCArgtypeTable = Dict{OCArgtypeKey,Vector{Any}}

struct SyntheticFilter
    bindings::JL.Bindings
    destructure_ranges::Vector{UnitRange{Int}}
    user_assignment_ranges::Set{UnitRange{Int}}
end

function SyntheticFilter(st0::SyntaxTreeC, bindings::JL.Bindings)
    destructure_ranges, user_assignment_ranges = collect_assignment_ranges(st0)
    return SyntheticFilter(bindings, destructure_ranges, user_assignment_ranges)
end

mutable struct OCBodyAnnotationState
    last_frame::Union{Nothing,CC.InferenceState}
end
OCBodyAnnotationState() = OCBodyAnnotationState(nothing)

struct ASTTypeAnnotator <: CC.AbstractInterpreter
    world::UInt
    inf_params::CC.InferenceParams
    opt_params::CC.OptimizationParams
    inf_cache::Vector{CC.InferenceResult}

    toptree::SyntaxTreeC
    topmi::MethodInstance
    # Consumer-side classifier for "user-written vs lowering-introduced" used by
    # `annotate_types!`. See `is_internal_binding_leaf` and `is_synthetic_destructure_stmt`.
    filter::SyntheticFilter
    # OC `Method` → body's `K"code_info"` subtree; built by `register_oc_body_trees!`.
    oc_body_trees::IdDict{Method,SyntaxTreeC}
    # Pending eager OC body annotations. `abstract_eval_new_opaque_closure` opens an
    # entry, `finishinfer!` records the last body frame seen for that fresh OC method,
    # and the eager call's `Future` continuation consumes the entry.
    oc_body_annotation_states::IdDict{Method,OCBodyAnnotationState}
    # Per OC body byte range, the per-slot join of argtypes observed for slots the
    # user left untyped (`Union{}` = unobserved). Shared across all thunk interps of
    # one inference pass; see `record_oc_argtype_observation!`.
    oc_argtype_observations::OCArgtypeTable
    # Refinements derived from the previous pass's observations, applied by
    # `refine_partial_opaque_argt`; `nothing` during the first pass.
    oc_argtype_refinements::Union{Nothing,OCArgtypeTable}
    # `Method` → refinement-key memo for `refinable_oc_shape`. The key derivation
    # (`Base.method_argnames` + tuple construction) allocates, and the observation hook
    # runs on every `PartialOpaque` call-site evaluation; the key is immutable per
    # `Method` and `Method`s are fresh per pass, so per-interp memoization is exact.
    # `nothing` marks Methods without a registered body tree.
    oc_key_memo::IdDict{Method,Union{Nothing,OCArgtypeKey}}
    function ASTTypeAnnotator(
            world::UInt,
            toptree::SyntaxTreeC,
            topmi::MethodInstance,
            filter::SyntheticFilter;
            inf_params::CC.InferenceParams = CC.InferenceParams(;
                aggressive_constant_propagation = true
            ),
            opt_params::CC.OptimizationParams = CC.OptimizationParams(),
            inf_cache::Vector{CC.InferenceResult} = CC.InferenceResult[],
            oc_body_trees::IdDict{Method,SyntaxTreeC} = IdDict{Method,SyntaxTreeC}(),
            oc_body_annotation_states::IdDict{Method,OCBodyAnnotationState} = IdDict{Method,OCBodyAnnotationState}(),
            oc_argtype_observations::OCArgtypeTable = OCArgtypeTable(),
            oc_argtype_refinements::Union{Nothing,OCArgtypeTable} = nothing,
            oc_key_memo::IdDict{Method,Union{Nothing,OCArgtypeKey}} = IdDict{Method,Union{Nothing,OCArgtypeKey}}()
        )
        return new(world, inf_params, opt_params, inf_cache, toptree, topmi,
            filter, oc_body_trees, oc_body_annotation_states,
            oc_argtype_observations, oc_argtype_refinements, oc_key_memo)
    end
end
CC.InferenceParams(interp::ASTTypeAnnotator) = interp.inf_params
CC.OptimizationParams(interp::ASTTypeAnnotator) = interp.opt_params
CC.get_inference_world(interp::ASTTypeAnnotator) = interp.world
CC.get_inference_cache(interp::ASTTypeAnnotator) = interp.inf_cache
CC.cache_owner(::ASTTypeAnnotator) = ASTTypeAnnotatorToken()

CC.typeinf_lattice(::ASTTypeAnnotator) =
    CC.InferenceLattice(CC.MustAliasesLattice(CC.BaseInferenceLattice.instance))
CC.ipo_lattice(::ASTTypeAnnotator) =
    CC.InferenceLattice(CC.InterMustAliasesLattice(CC.IPOResultLattice.instance))

# ASTTypeAnnotator is only used for type analysis, so it should disable optimization entirely
CC.may_optimize(::ASTTypeAnnotator) = false

# ASTTypeAnnotator doesn't need any sources to be cached, so discard them aggressively
CC.transform_result_for_cache(::ASTTypeAnnotator, ::CC.InferenceResult, ::Core.SimpleVector) = nothing

# `bail_out_toplevel_call(interp, sv::InferenceState) = sv.restrict_abstract_call_sites` is
# `true` for thunk MIs (`def isa Module`), and `abstract_call_gf_by_type` then refuses to
# infer any matching method whose `spec_types` isn't a `isdispatchtuple` — i.e. methods with
# free type vars like `(::Type{NamedTuple{names}})(::Tuple)`, whose result type would
# normally be `NamedTuple{names, Tuple{…}}`. Since we always run inference on top-level
# thunks built from user-source method bodies, that bail-out throws away precise types
# we'd otherwise have. Override to never bail.
CC.bail_out_toplevel_call(::ASTTypeAnnotator, ::CC.InferenceState) = false

# Keep precise unused call results for frames that `finishinfer!` annotates.
function CC.widen_call_result(
        interp::ASTTypeAnnotator, si::CC.StmtInfo, state::CC.CallInferenceState,
        sv::CC.InferenceState
    )
    interp.topmi === sv.linfo && return false
    def = sv.linfo.def
    def isa Method && haskey(interp.oc_body_annotation_states, def) && return false
    return @invoke CC.widen_call_result(
        interp::CC.AbstractInterpreter, si::CC.StmtInfo, state::CC.CallInferenceState,
        sv::CC.InferenceState)
end

function CC.concrete_eval_eligible(
        interp::ASTTypeAnnotator, @nospecialize(f), result::CC.MethodCallResult,
        arginfo::CC.ArgInfo, sv::CC.InferenceState
    )
    ret = @invoke CC.concrete_eval_eligible(
        interp::CC.AbstractInterpreter, f::Any, result::CC.MethodCallResult,
        arginfo::CC.ArgInfo, sv::CC.InferenceState)
    if ret === :semi_concrete_eval
        # while the base eligibility check probably won't permit semi-concrete evaluation
        # for `ASTTypeAnnotator` (given it completely turns off optimization),
        # this ensures we don't inadvertently enter irinterp
        ret = :none
    end
    return ret
end

function CC.abstract_eval_partition_load(
        interp::ASTTypeAnnotator, binding::Core.Binding, partition::Core.BindingPartition
    )
    res = @invoke CC.abstract_eval_partition_load(
        interp::CC.AbstractInterpreter, binding::Core.Binding, partition::Core.BindingPartition)
    return concretize_abstract_binding_state_load(interp, res)
end

# Script-mode full analysis may hand us a context module populated by JET's virtualprocess,
# where inferred const globals are materialized as `AbstractBindingState`.
function concretize_abstract_binding_state_load(interp::ASTTypeAnnotator, res::CC.RTEffects)
    ⊑ = CC.partialorder(CC.typeinf_lattice(interp))
    if res.rt !== Union{} && res.rt ⊑ JET.AbstractBindingState
        rt = res.rt
        if rt isa Core.Const && (binding_state = rt.val) isa JET.AbstractBindingState
            if isdefined(binding_state, :typ)
                (; exct, effects) = res
                if binding_state.maybeundef
                    ⊔ = CC.join(CC.typeinf_lattice(interp))
                    exct = exct ⊔ UndefVarError
                    effects = CC.Effects(effects; nothrow = exct === Union{})
                end
                return CC.RTEffects(binding_state.typ, exct, effects)
            end
        end
        return CC.RTEffects(Any, res.exct, res.effects)
    end
    return res
end

# Refine `PartialOpaque.typ`'s rt parameter using the OC body's eager inference
# result, so the OC's static type carries the precise rt when it crosses
# `widenconst` boundaries (most notably `Base.@default_eltype`'s
# `Tuple{typeof(itr)}` widening in the `map(closure, vec)` chain). Without this,
# the OC type stays `OpaqueClosure{argt, T} where T<:rt_ub` and downstream
# `abstract_call_unknown` OC fallbacks see only `T<:Any`.
#
# This refinement is IPO-unsound in general — See JuliaLang/julia#61718 for the upstream
# rejection. We accept the unsoundness here because `ASTTypeAnnotator` results never feed
# optimization, caching, or runtime — they only drive tooling. The closure→OC rewrite already
# accepts a class of incompleteness, so this unsoundness is also judged to be acceptable.
# In most cases, it could become a problem when user code explicitly defines method
# definitions for the `OpaqueClosure` type, and such cases are currently not very common.
# The `PartialOpaque` construction replicates the default method instead of `@invoke`ing it:
# the default eagerly infers the body against the *unrefined* signature before
# `refine_partial_opaque_argt` could apply, and call-site observations recorded inside
# that signature-view-with-`Any` frame would poison the per-slot joins
# (`tmerge(Any, T) === Any`), blocking refinement convergence for nested closures.
# Replicating lets the single eager body inference run against the refined signature.
function CC.abstract_eval_new_opaque_closure(
        interp::ASTTypeAnnotator, e::Expr, sstate::CC.StatementState, sv::CC.InferenceState
    )
    ea = e.args
    if length(ea) < 5
        return @invoke CC.abstract_eval_new_opaque_closure(
            interp::CC.AbstractInterpreter, e::Expr, sstate::CC.StatementState,
            sv::CC.InferenceState)
    end
    argtypes = CC.collect_argtypes(interp, ea, sstate, sv)
    if argtypes === nothing
        return CC.Future(CC.RTEffects(Union{}, Any, CC.EFFECTS_THROWS))
    end
    rt = CC.opaque_closure_tfunc(CC.typeinf_lattice(interp),
        argtypes[1], argtypes[2], argtypes[3], argtypes[5], argtypes[6:end],
        CC.frame_instance(sv))
    if ea[4] !== true && rt isa CC.PartialOpaque
        rt = CC.widenconst(rt) # propagation of `PartialOpaque` disabled
    end
    effects = CC.Effects() # match the default method's `TODO` placeholder
    if !(rt isa CC.PartialOpaque) || CC.call_result_unused(sv, sv.currpc)
        return CC.Future(CC.RTEffects(rt, Any, effects))
    end
    po = refine_partial_opaque_argt(interp, rt)
    oc_argtypes = CC.most_general_argtypes(po)
    pushfirst!(oc_argtypes, po.env)
    interp.oc_body_annotation_states[po.source] = OCBodyAnnotationState()
    arginfo, stmtinfo = CC.ArgInfo(nothing, oc_argtypes), CC.StmtInfo(true, false)
    @static if hasmethod(CC.abstract_call_opaque_closure,
        Tuple{CC.AbstractInterpreter, CC.PartialOpaque, CC.ArgInfo,
              CC.StmtInfo, Union{Vector{CC.VarState}, Nothing}, CC.AbsIntState,
              Bool})
        callinfo = CC.abstract_call_opaque_closure(
            interp, po, arginfo, stmtinfo, nothing, sv, #=check=#false)::CC.Future
    else
        callinfo = CC.abstract_call_opaque_closure(
            interp, po, arginfo, stmtinfo, sv, #=check=#false)::CC.Future
    end
    return CC.Future{CC.RTEffects}(callinfo, interp, sv) do callinfo, _, sv
        consume_oc_body_annotation_state!(interp, po.source)
        sv.stmt_info[sv.currpc] = CC.OpaqueClosureCreateInfo(callinfo)
        refined_rt = refine_partial_opaque_rt(po, callinfo.rt)
        return CC.RTEffects(refined_rt, Any, effects)
    end
end

function refine_partial_opaque_rt(po::CC.PartialOpaque, @nospecialize inferred_rt)
    typ = po.typ
    isa(typ, UnionAll) || return po
    refined = CC.widenconst(inferred_rt)
    (refined === Any || refined === Union{}) && return po
    tv = typ.var
    tv.lb <: refined <: tv.ub || return po
    refined_typ = try
        typ{refined}
    catch
        return po
    end
    return CC.PartialOpaque(refined_typ, po.env, po.parent, po.source)
end

# Shared precondition matcher for the two sides of closure argtype refinement —
# `record_oc_argtype_observation!` (observation) and `refine_partial_opaque_argt`
# (application): resolve a `PartialOpaque` to its refinement key (the OC body's byte
# range — stable across re-lowering passes, unlike `Method` identity) and its declared
# argt parameter list. Returns `nothing` when any precondition fails:
# - `source` must be a `Method` registered in `interp.oc_body_trees`, i.e. an OC this
#   pipeline created; OCs constructed inside foreign code under inference don't necessarily
#   correspond to any tree we annotate.
# - `typ` must be one of the two shapes our pipeline produces: the single-UnionAll-over-rt
#   shape from `opaque_closure_tfunc` (rt still a free var), or the concrete `DataType`
#   left after `refine_partial_opaque_rt` bakes the rt in — the latter is what call sites
#   see whenever the eager body inference produced a concrete rt, so the observation side
#   must accept it or such closures are never observed.
#   Anything more complex (e.g. hand-written OCs with free argt vars, where `typ.body`
#   is still a `UnionAll`) bails: `refine_partial_opaque_argt`'s reconstruction is only
#   correct for the simple shapes, and recording what the application side can't consume
#   would only waste passes.
# - argt must be a plain `Vararg`-free `Tuple`, so slots map 1:1 onto call-site argtypes.
function refinable_oc_shape(interp::ASTTypeAnnotator, po::CC.PartialOpaque)
    m = po.source
    m isa Method || return nothing
    key = @something get!(interp.oc_key_memo, m) do
        body_tree = get(interp.oc_body_trees, m, nothing)
        body_tree === nothing && return nothing
        argnames = (Base.method_argnames(m)[2:end]...,) # drop the implicit env slot
        return (JS.byte_range(body_tree), argnames)
    end return nothing
    # The typ-dependent checks can't be memoized per `Method`: the same `Method` flows
    # in both unrefined and refined `PartialOpaque`s, whose `typ`s differ.
    typ = po.typ
    oc = typ isa UnionAll ? typ.body : typ
    oc isa DataType || return nothing
    argt = oc.parameters[1]
    argt isa DataType || return nothing
    argt <: Tuple || return nothing
    params = argt.parameters
    any(CC.isvarargtype, params) && return nothing
    return (; key, params)
end

# Refinement-eligibility policy for a single parameter slot: only slots the user left
# unannotated participate, so non-`Any` annotations stay authoritative (an explicit
# `::Any` is indistinguishable from an unannotated parameter after lowering and is
# treated the same way).
#
# The application side always sees a freshly lowered argt, where unannotated slots are
# still literally `Any` — the 1-arg form suffices. The observation side sees the
# *post-refinement* `PartialOpaque`, where a previously refined slot is no longer
# `Any`; the 3-arg form extends the test with the pass's applied refinement entry so
# refined slots keep being re-observed and the refinement set stays stable across
# passes (see `merge_refinements`).
is_unannotated_slot(@nospecialize declared) = declared === Any
is_unannotated_slot(@nospecialize(declared), refined::Union{Nothing,Vector{Any}}, i::Int) =
    is_unannotated_slot(declared) || (refined !== nothing && is_refined_slot(refined[i]))

# `Union{}` marks an unobserved slot; an `Any` join carries no refinement.
is_refined_slot(@nospecialize t) = !(t === Union{} || t === Any)

# Substitute call-site-observed types (joined by the previous inference pass; see
# `record_oc_argtype_observation!`) into the declared-`Any` slots of `PartialOpaque.typ`'s
# argt parameter. The body's eager signature-view inference and `refine_partial_opaque_rt`
# then both run against the refined signature, so the body annotation and the OC's rt
# parameter become as precise as the observed call sites allow. The body annotation thus
# remains a deterministic signature view — the signature itself is just inferred from
# call sites, the same annotation model as Kotlin/Swift-style lambda parameter inference.
function refine_partial_opaque_argt(interp::ASTTypeAnnotator, po::CC.PartialOpaque)
    refinements = @something interp.oc_argtype_refinements return po
    # Application only ever sees the freshly constructed `PartialOpaque` (rt refinement
    # happens later, in `abstract_eval_new_opaque_closure`'s continuation), so the typ
    # is the UnionAll-over-rt shape; the guard documents the reconstruction's precondition
    # rather than a reachable case.
    typ = po.typ
    typ isa UnionAll || return po
    (; key, params) = @something refinable_oc_shape(interp, po) return po
    refined_slots = @something get(refinements, key, nothing) return po
    length(params) == length(refined_slots) || return po
    newparams = Any[params[i] for i = 1:length(params)]
    changed = false
    for i = 1:length(params)
        is_unannotated_slot(params[i]) || continue
        is_refined_slot(refined_slots[i]) || continue
        newparams[i] = refined_slots[i]
        changed = true
    end
    changed || return po
    refined_typ = try
        Base.rewrap_unionall(Core.OpaqueClosure{Tuple{newparams...}, typ.var}, typ)
    catch
        return po
    end
    return CC.PartialOpaque(refined_typ, po.env, po.parent, po.source)
end

# Record the argtypes each OC body is actually called with, keyed by the body's byte
# range — stable across re-lowering passes, unlike `Method` identity. The eager
# signature-view inference from `abstract_eval_new_opaque_closure` passes `check=false`
# and must not be recorded: it would join `most_general_argtypes` (the declared `Any`s)
# into every observation and erase the refinement.
@static if hasmethod(CC.abstract_call_opaque_closure,
    Tuple{CC.AbstractInterpreter, CC.PartialOpaque, CC.ArgInfo,
          CC.StmtInfo, Union{Vector{CC.VarState}, Nothing}, CC.AbsIntState,
          Bool})
function CC.abstract_call_opaque_closure(
        interp::ASTTypeAnnotator, closure::CC.PartialOpaque, arginfo::CC.ArgInfo,
        si::CC.StmtInfo, vtypes::Union{Vector{CC.VarState},Nothing}, sv::CC.AbsIntState,
        check::Bool
    )
    check && record_oc_argtype_observation!(interp, closure, arginfo)
    return @invoke CC.abstract_call_opaque_closure(
        interp::CC.AbstractInterpreter, closure::CC.PartialOpaque, arginfo::CC.ArgInfo,
        si::CC.StmtInfo, vtypes::Union{Vector{CC.VarState},Nothing}, sv::CC.AbsIntState,
        check::Bool)
end
else
function CC.abstract_call_opaque_closure(
        interp::ASTTypeAnnotator, closure::CC.PartialOpaque, arginfo::CC.ArgInfo,
        si::CC.StmtInfo, sv::CC.AbsIntState, check::Bool
    )
    check && record_oc_argtype_observation!(interp, closure, arginfo)
    return @invoke CC.abstract_call_opaque_closure(
        interp::CC.AbstractInterpreter, closure::CC.PartialOpaque, arginfo::CC.ArgInfo,
        si::CC.StmtInfo, sv::CC.AbsIntState, check::Bool)
end
end

# `Generator(f, iter)` and `Filter(f, iter)` invoke `f` as iteration advances. In
# nested iterator pipelines, that invocation is mediated by iterator machinery, so
# the `PartialOpaque` call hook may not observe it. Treat construction as observing
# `f` at the iterator element type.
@static if hasmethod(CC.abstract_call_gf_by_type,
        Tuple{CC.AbstractInterpreter, Any, CC.ArgInfo, CC.StmtInfo, Any,
              Union{Vector{CC.VarState}, Nothing}, CC.AbsIntState, Int})
function CC.abstract_call_gf_by_type(
        interp::ASTTypeAnnotator, @nospecialize(func), arginfo::CC.ArgInfo,
        si::CC.StmtInfo, @nospecialize(atype), vtypes::Union{Vector{CC.VarState},Nothing},
        sv::CC.AbsIntState, max_methods::Int
    )
    if func === Base.Generator || func === Base.Iterators.Filter
        record_iterator_argtype_observation!(interp, arginfo)
    end
    return @invoke CC.abstract_call_gf_by_type(
        interp::CC.AbstractInterpreter, func::Any, arginfo::CC.ArgInfo,
        si::CC.StmtInfo, atype::Any, vtypes::Union{Vector{CC.VarState},Nothing},
        sv::CC.AbsIntState, max_methods::Int)
end
else
function CC.abstract_call_gf_by_type(
        interp::ASTTypeAnnotator, @nospecialize(func), arginfo::CC.ArgInfo,
        si::CC.StmtInfo, @nospecialize(atype), sv::CC.AbsIntState, max_methods::Int
    )
    if func === Base.Generator || func === Base.Iterators.Filter
        record_iterator_argtype_observation!(interp, arginfo)
    end
    return @invoke CC.abstract_call_gf_by_type(
        interp::CC.AbstractInterpreter, func::Any, arginfo::CC.ArgInfo,
        si::CC.StmtInfo, atype::Any, sv::CC.AbsIntState, max_methods::Int)
end
end

function record_iterator_argtype_observation!(
        interp::ASTTypeAnnotator, arginfo::CC.ArgInfo
    )
    argtypes = arginfo.argtypes
    length(argtypes) == 3 || return nothing
    closure = CC.widenslotwrapper(argtypes[2])
    closure isa CC.PartialOpaque || return nothing
    iter_eltype = @something iterator_upper_bound_type(interp, argtypes[3]) return nothing
    is_refined_slot(iter_eltype) || return nothing
    return record_oc_argtype_observation!(
        interp, closure, CC.ArgInfo(nothing, Any[closure.env, iter_eltype]))
end

function iterator_upper_bound_type(interp::ASTTypeAnnotator, @nospecialize(iter_arg))
    iter_type = CC.widenconst(CC.widenslotwrapper(iter_arg))
    iter_type isa Type || return nothing
    iter_type === Any && return nothing
    rt = try
        Base._return_type(Base._iterator_upper_bound, Tuple{iter_type}, interp.world)
    catch
        return nothing
    end
    return rt isa Type ? rt : nothing
end

# Join observed argtypes into `interp.oc_argtype_observations`, per slot — see
# `refinable_oc_shape` / `is_unannotated_slot` for the matching preconditions and the
# slot-eligibility policy.
function record_oc_argtype_observation!(
        interp::ASTTypeAnnotator, closure::CC.PartialOpaque, arginfo::CC.ArgInfo
    )
    (; key, params) = @something refinable_oc_shape(interp, closure) return nothing
    n = length(params)
    argtypes = arginfo.argtypes
    # `argtypes[1]` is the env (substituted by `abstract_call_unknown`); the rest must
    # map 1:1 onto the OC's params — splat calls with unknown arity don't.
    length(argtypes) == n + 1 || return nothing
    any(CC.isvarargtype, argtypes) && return nothing
    oc_argtype_refinements = interp.oc_argtype_refinements
    refined = oc_argtype_refinements === nothing ? nothing :
        get(oc_argtype_refinements, key, nothing)
    refined !== nothing && length(refined) != n && (refined = nothing)
    obs = get!(() -> Any[Union{} for _ = 1:n], interp.oc_argtype_observations, key)
    length(obs) == n || return nothing # byte-range collision between different-arity OCs
    𝕃 = CC.typeinf_lattice(interp)
    for i = 1:n
        is_unannotated_slot(params[i], refined, i) || continue
        t = CC.widenconst(argtypes[i+1])
        t === Union{} && continue
        obs[i] = obs[i] === Union{} ? t : CC.tmerge(𝕃, obs[i], t)
    end
    return nothing
end

# Slot type at a specific use site. `argextype(SlotNumber)` returns the joined
# post-inference `slottypes[id]`, which loses every per-use narrowing — so we instead
# reconstruct the slot's type at `idx`:
# - If the same basic block has a slot assignment that dominates `idx`,
#   use the assigned RHS's type (`ssavaluetypes[pc_assign]`).
# - Otherwise fall back to the bb's entry varstate
#   (`bb_vartables[bb][id]`), which CC's dataflow has already populated
#   with cross-bb branch narrowing.
function slot_type_at(slot::SlotNumber, idx::Int, frame::CC.InferenceState)
    pc_assign = CC.find_dominating_assignment(slot.id, idx, frame)
    pc_assign === nothing || return frame.ssavaluetypes[pc_assign]
    bb = CC.block_for_inst(frame.cfg, idx)
    entry = @something frame.bb_vartables[bb] return frame.src.slottypes[slot.id]
    return entry[slot.id].typ
end

# Extract the matched methods for a call site from CC's per-stmt `CallInfo`.
# Returns `nothing` for `CallInfo` shapes that don't expose a method-match
# list (`InvokeCallInfo`, `OpaqueClosureCallInfo`, `ApplyCallInfo`, …): those
# call shapes don't have a "set of dispatched methods" definition that maps
# cleanly onto go-to-definition / sighelp queries.
function extract_call_matches(@nospecialize info)
    matches = Core.MethodMatch[]
    collect_call_matches!(matches, info)
    return isempty(matches) ? nothing : matches
end

function collect_call_matches!(matches::Vector{Core.MethodMatch}, @nospecialize info)
    if info isa CC.MethodMatchInfo
        for m in info.results
            push!(matches, m)
        end
    elseif info isa CC.UnionSplitInfo
        for sub in info.split
            collect_call_matches!(matches, sub)
        end
    elseif info isa CC.ConstCallInfo
        # `ConstCallInfo` wraps the underlying dispatch info with a
        # const-prop'd result; the same matching methods live one level down.
        collect_call_matches!(matches, info.call)
    end
    return matches
end

# Walk to the *deepest* K"BindingId" in the source chain — argmap-renamed
# user arguments have an intermediate `is_internal=true` local that would
# misreport `true` if we stopped at the first hop.
function is_internal_binding_leaf(filter::SyntheticFilter, leaf::SyntaxTreeC)
    graph = JS.syntax_graph(leaf)
    src = get(leaf, :source, nothing)
    src isa JS.NodeId || return false
    cur = SyntaxTreeC(graph, src)
    JS.kind(cur) === JS.K"BindingId" || return false
    last_binding = cur
    while true
        nxt = get(last_binding, :source, nothing)
        nxt isa JS.NodeId || break
        st = SyntaxTreeC(graph, nxt)
        JS.kind(st) === JS.K"BindingId" || break
        last_binding = st
    end
    return JL.get_binding(filter.bindings, last_binding).is_internal
end

# Classify every surface `K"="`:
# - K"tuple" LHS → destructure trigger (catches `(a, b) = rhs`,
#   `(; a, b) = rhs`, and the K"=" iter-spec of `for (a, b) in iter`)
# - any other LHS → user-written simple assignment, recorded so it isn't
#   misfiltered when it appears inside a destructure RHS.
function collect_assignment_ranges(st0::SyntaxTreeC)
    destructure = UnitRange{Int}[]
    user_simple = Set{UnitRange{Int}}()
    traverse(st0) do st::SyntaxTreeC
        JS.kind(st) === JS.K"=" || return nothing
        rng = JS.byte_range(st)
        if JS.numchildren(st) >= 1 && JS.kind(st[1]) === JS.K"tuple"
            push!(destructure, rng)
        else
            push!(user_simple, rng)
        end
        return nothing
    end
    return destructure, user_simple
end

# Skip lowered `K"="`s that match a user-written simple `K"="` exactly —
# `(a, b) = (x = 10; (x, x+1))` puts the inner `x = 10` inside the
# destructure's byte range, where containment alone would misflag it.
function is_synthetic_destructure_stmt(filter::SyntheticFilter, stmttree::SyntaxTreeC)
    JS.kind(stmttree) === JS.K"=" || return false
    rng = JS.byte_range(stmttree)
    rng in filter.user_assignment_ranges && return false
    for r in filter.destructure_ranges
        first(rng) >= first(r) && last(rng) <= last(r) && return true
    end
    return false
end

# JL inserts synthetic nodes (`Base.X` / `Core.X` call-head refs for
# array literals / kwarg / parametric-ctor scaffolding, lowering-introduced
# literals in destructure / generator scaffolding, …) with no natural
# user-source position; JL attaches their `treeref` to the parent surface
# form so they share the surrounding stmt's full byte range. Flagging by
# that range equality skips annotating scaffolding leaves at ranges meant
# for user-facing queries.
is_synthetic_arg_leaf(stmttree::SyntaxTreeC, leaf::SyntaxTreeC) =
    JS.byte_range(leaf) == JS.byte_range(stmttree)

function annotate_types!(
        citree::SyntaxTreeC, frame::CC.InferenceState, filter::SyntheticFilter
    )
    if length(frame.src.code) != JS.numchildren(citree)
        return @warn "ASTTypeAnnotator: Can't annotate types for " frame.linfo
    end
    for i = 1:length(frame.src.code)
        stmt = frame.src.code[i]
        stmttype = frame.src.ssavaluetypes[i]
        stmttree = citree[i]
        if JS.kind(stmttree) in JS.KSet"newvar goto gotoifnot"
            # The `ssavaluetype` corresponding to these nodes is always `Any`, and since
            # the provenance information for these nodes is very broad, it's more convenient
            # for the implementation of `get_type_for_range` to leave them untyped
            continue
        end
        # Synthetic destructure K"="s share the user's RHS byte range, so
        # annotating them (or their inner K"call" / args, below) would shadow
        # source-range queries.
        is_synthesized_stmt = is_synthetic_destructure_stmt(filter, stmttree)
        is_synthesized_stmt || JS.setattr!(stmttree, :type, stmttype)
        if stmt isa Expr
            stmt.head === :meta && continue
            # TODO: properly annotate static-parameter references once CC supports
            # `sparam_vals` for thunk MIs (currently degrades to `Any`; see the
            # `# Limitations` section of `infer_toplevel_tree`'s docstring).
            stmt.head === :static_parameter && continue
            treeref = stmttree
            if JS.numchildren(treeref) ≠ length(stmt.args)
                @warn "ASTTypeAnnotator: Unexpected syntax tree statement conversion" treeref
                continue
            end
            if stmt.head === :(=)
                lhs = stmt.args[1]
                if lhs isa SlotNumber && !is_internal_binding_leaf(filter, treeref[1])
                    # Skip annotating slot LHS when the binding itself is
                    # lowering-introduced (e.g. tuple destructure's
                    # `iterstate` / `rhs_tmp`) — those slot leaves share the
                    # user's RHS source position and would pollute queries.
                    JS.setattr!(treeref[1], :type, stmttype)
                end
                stmt = stmt.args[2]
                stmt isa Expr || continue
                treeref = treeref[2]
                is_synthesized_stmt || JS.setattr!(treeref, :type, stmttype)
            end
            is_call = stmt.head === :call
            if is_call && !is_synthesized_stmt
                matches = extract_call_matches(frame.stmt_info[i])
                matches === nothing || JS.setattr!(treeref, :matches, matches)
            end
            for j = 1:length(stmt.args)
                arg = stmt.args[j]
                if arg isa SlotNumber && !is_internal_binding_leaf(filter, treeref[j])
                    argtyp = slot_type_at(arg, i, frame)
                    JS.setattr!(treeref[j], :type, argtyp)
                elseif (!is_synthesized_stmt && is_call && !(arg isa SSAValue) &&
                        !is_synthetic_arg_leaf(treeref, treeref[j]))
                    # `is_synthetic_arg_leaf` filters lowering-inserted leaves
                    # (synthetic call heads like `Base.vect` for `[1,2,3]` /
                    # `Core.apply_type` / `Core.kwcall` for kwarg calls, and
                    # lowering-introduced literals in comprehension scaffolding).
                    # Their `argextype` otherwise leaks through `tmerge_at_range`-dispatched
                    # queries (`K"vect"`, `K"typed_vcat"`, …) as a union with the real type.
                    # SSAValue args are skipped separately since the producing stmt already
                    # annotates the value.
                    argtyp = CC.argextype(arg, frame.src, frame.sptypes)
                    JS.setattr!(treeref[j], :type, argtyp)
                end
            end
        elseif stmt isa ReturnNode
            val = stmt.val
            if val isa SlotNumber
                rettyp = slot_type_at(val, i, frame)
            else
                rettyp = CC.argextype(val, frame.src, frame.sptypes)
            end
            JS.setattr!(stmttree, :type, rettyp)
        end
    end
end

function CC.finishinfer!(frame::CC.InferenceState, interp::ASTTypeAnnotator, cycleid::Int)
    ret = @invoke CC.finishinfer!(frame::CC.InferenceState, interp::CC.AbstractInterpreter, cycleid::Int)
    if frame.linfo === interp.topmi
        annotate_types!(interp.toptree[1], frame, interp.filter)
    else
        def = frame.linfo.def
        if def isa Method
            record_oc_body_annotation_candidate!(interp, def, frame)
        end
    end
    return ret
end

# The pending `def` entry marks the dynamic extent of the eager `check=false`
# OC body inference. Since OC methods are freshly materialized by each re-lowering
# pass, both the regular body frame and, when const-prop' applies, its narrower
# companion frame finish before the eager call's `Future` continuation. Keeping the
# last frame therefore selects the const-prop' body view when it exists.
function record_oc_body_annotation_candidate!(
        interp::ASTTypeAnnotator, def::Method, frame::CC.InferenceState
    )
    state = get(interp.oc_body_annotation_states, def, nothing)
    state === nothing && return nothing
    state.last_frame = frame
    return nothing
end

function consume_oc_body_annotation_state!(interp::ASTTypeAnnotator, def::Method)
    state = get(interp.oc_body_annotation_states, def, nothing)
    state === nothing && return false
    delete!(interp.oc_body_annotation_states, def)
    frame = @something state.last_frame return false
    oc_citree = get(interp.oc_body_trees, def, nothing)
    # `oc_citree[1]` is the body block, matching `annotate_types!`'s contract.
    oc_citree === nothing || annotate_types!(oc_citree[1], frame, interp.filter)
    return true
end

# Register `is_for_opaque_closure` `Method`s (replacements from
# `resolve_definition_effects_in_ir`) against their `K"code_info"` syntax
# subtree. Keyed by `Method` (not `CodeInfo`) because `jl_method_set_source`
# compresses the body — `frame.src` is a freshly decompressed copy and won't
# `===` the registered CodeInfo.
#
# Recurses via `Base.uncompressed_ir` so nested OCs are registered up-front:
# `:opaque_closure_method` stays at the construction site (unlike
# `JL.convert_closures`-hoisted regular closures), so an inner OC's Method
# lives inside its outer OC's body, not in the thunk's top-level `src.code`.
function register_oc_body_trees!(
        oc_body_trees::IdDict{Method,SyntaxTreeC}, citree::SyntaxTreeC, src::CodeInfo
    )
    block_citree = JS.kind(citree) === JS.K"code_info" ? citree[1] : citree
    JS.numchildren(block_citree) == length(src.code) || return oc_body_trees
    for i = 1:length(src.code)
        stmt = src.code[i]
        node = block_citree[i]
        stmt isa Method || continue
        ocmeth = stmt
        if ocmeth isa Method && ocmeth.is_for_opaque_closure
            JS.kind(node) === JS.K"opaque_closure_method" || continue
            body_citree = @something find_code_info_child(node) continue
            haskey(oc_body_trees, ocmeth) && continue # avoid re-recursing on cycles
            oc_body_trees[ocmeth] = body_citree
            inner_src = Base.uncompressed_ir(ocmeth)
            inner_src isa CodeInfo &&
                register_oc_body_trees!(oc_body_trees, body_citree, inner_src)
        end
    end
    return oc_body_trees
end

function find_code_info_child(node::SyntaxTreeC)
    for i = 1:JS.numchildren(node)
        c = node[i]
        JS.kind(c) === JS.K"code_info" && return c
    end
    return nothing
end

# Type annotation driver
# ======================

"""
    is_type_annotation_skipped_toplevel(st0::SyntaxTreeC)

Return whether type-annotation features should skip a lowerable top-level form.
Declaration-only forms have no useful inferred value annotations.
"""
is_type_annotation_skipped_toplevel(st0::SyntaxTreeC) =
    JS.kind(st0) in JS.KSet"using import export public abstract primitive"

"""
    get_inferrable_tree(
            st0::SyntaxTreeC, context_module::Module;
            world::UInt = Base.get_world_counter(),
            caller::AbstractString = "get_inferrable_tree"
        ) -> (; ctx3::JL.VariableAnalysisContext, st3::SyntaxTreeC) | nothing

[`TypeAnnotation`](@ref) pipeline step 1: lower `st0` for scope resolution against `mod`,
returning the `(ctx3, st3)` pair that [`infer_toplevel_tree`](@ref) consumes.
Returns `nothing` if lowering throws (typically a parse error or an unready macro context);
errors are routed through `JETLS_DEBUG_LOWERING` rather than propagated.

`K"error"` nodes are stripped from `st0` before lowering so incomplete source
still produces a usable tree — JuliaSyntax keeps parsing past errors and
JuliaLowering happily lowers what's left. For example, in
`function f(x::T); x.; end` the body's `x` reference still resolves to `T` after
`K"error"` removal.

See the [`TypeAnnotation`](@ref) module docstring for the full pipeline.
"""
function get_inferrable_tree(
        st0::SyntaxTreeC, context_module::Module;
        world::UInt = Base.get_world_counter(),
        caller::AbstractString = "get_inferrable_tree"
    )
    (; ctx3, st3) = try
        jl_lower_for_scope_resolution(context_module, st0; world, trim_error_nodes=true, recover_from_macro_errors=false)
    catch err
        JETLS_DEBUG_LOWERING && @warn "Error in lowering ($caller)" err
        JETLS_DEBUG_LOWERING && Base.show_backtrace(stderr, catch_backtrace())
        return nothing
    end
    return (; ctx3, st3)
end

"""
    infer_toplevel_tree(
            ctx3::JL.VariableAnalysisContext, st3::SyntaxTreeC,
            st0::SyntaxTreeC, context_module::Module;
            world::UInt = Base.get_world_counter()
        ) -> inferred::SyntaxTreeC

[`TypeAnnotation`](@ref) pipeline step 2: take `(ctx3, st3)` (typically from
[`get_inferrable_tree`](@ref)) through the remaining JuliaLowering passes, run CC
inference under the internal `ASTTypeAnnotator`, and return a `SyntaxTreeC`
annotated with a `:type` attribute on each lowered statement. The walk recurses
into `:method` 3-arg statements: each method body is inferred as its own
anonymous thunk against argtypes statically evaluated from the sig svec.

`st0` (raw parse) is used to collect surface destructure byte ranges; `st3`
is post-desugaring and no longer carries those triggers.

`world` (default: the current world) selects the inference world used
throughout. The returned tree contains both top-level statements and method
bodies, all annotated, so downstream lookups via [`get_type_for_range`](@ref)
work for either without descending into bodies separately.

See the [`TypeAnnotation`](@ref) module docstring for the rest of the pipeline,
the full-analysis prerequisite, and the current limitations.
"""
infer_toplevel_tree(args...; kwargs...) =
    (@something _infer_toplevel_tree(args...; kwargs...) return nothing).toptree

# Pass cap for the closure argtype refinement loop in `_infer_toplevel_tree`: pass 1
# collects observations; pass 2 applies them. A 3rd pass is only reached when pass 2's
# refined inference observes new refinements itself (e.g. an inner closure whose call
# sites live inside an outer refined closure body).
const MAX_OC_REFINEMENT_PASSES = 3

function _infer_toplevel_tree(
        ctx3::JL.VariableAnalysisContext, inferrable_tree3::SyntaxTreeC,
        st0::SyntaxTreeC, context_module::Module;
        world::UInt = Base.get_world_counter()
    )
    filter = SyntheticFilter(st0, ctx3.bindings)
    inf_cache = CC.InferenceResult[]
    interp = refinements = nothing
    for _ = 1:MAX_OC_REFINEMENT_PASSES
        observations = OCArgtypeTable()
        interp = @something infer_lowered_tree(
            ctx3, inferrable_tree3, context_module, world, filter,
            observations, refinements, inf_cache) return interp
        nextrefinements = @something merge_refinements(
            refinements, viable_oc_argtype_refinements(observations)) break
        isequal(nextrefinements, refinements) && break
        refinements = nextrefinements
    end
    return interp
end

# Join, per slot, the previous pass's refinements with the new pass's observations,
# so the refinement sequence `_infer_toplevel_tree` iterates is monotone (bounded
# ascent via `tmerge`, saturating at `Any` where the slot drops out via
# `is_refined_slot`). Monotonicity guarantees convergence to a fixpoint, and the
# `isequal` break detects it.
#
# Why merge rather than just take the new pass's observations: that would only
# converge if observations were stable across passes, and stability is an assumption
# about CC's heuristics we'd rather not depend on. Concretely, a refined OC could in
# principle stop being observed in a later pass (if its improved type made a guarding
# branch or dispatch resolve away the call site it was observed at), and a plain
# replace would then oscillate the refinement in and out. In practice this is hard to
# even provoke — refining an OC's argt/rt doesn't change that it flows as a
# `PartialOpaque` and re-enters its body at each call site, so observations stay
# stable, and neither the test suite nor deliberately constructed cases exercise the
# difference. So `merge` is a cheap, monotone safety net over a non-monotone
# observation pattern we couldn't realize, not a routinely-needed step.
function merge_refinements(prev::Union{Nothing,OCArgtypeTable}, next::Union{Nothing,OCArgtypeTable})
    prev === nothing && return next
    next === nothing && return prev
    merged = copy(prev)
    for (key, slots) in next
        prevslots = get(merged, key, nothing)
        if prevslots === nothing || length(prevslots) != length(slots)
            merged[key] = slots
            continue
        end
        mergedslots = Vector{Any}(undef, length(slots))
        for i = 1:length(slots)
            p, t = prevslots[i], slots[i]
            mergedslots[i] = p === Union{} ? t : t === Union{} ? p : CC.tmerge(p, t)
        end
        merged[key] = mergedslots
    end
    return merged
end

# Keep only observations that would actually refine a slot: a slot joined to `Any` (or
# never observed) carries no information, and an all-unrefinable entry would only
# trigger useless extra passes.
function viable_oc_argtype_refinements(observations::OCArgtypeTable)
    refinements = nothing
    for (key, slots) in observations
        any(is_refined_slot, slots) || continue
        refinements = @something refinements OCArgtypeTable()
        refinements[key] = slots
    end
    return refinements
end

# Each pass re-lowers from `(ctx3, st3)` rather than reusing the previous pass's lowered
# code. Re-lowering materializes fresh OC `Method`s, so sharing `inf_cache` across
# passes won't make OC body inference hit stale entries and skip `finishinfer!`.
# Non-OC callees can still reuse pass-local inference results. Refinements are keyed
# by body byte range, which is stable across re-lowering.
function infer_lowered_tree(
        ctx3::JL.VariableAnalysisContext, inferrable_tree3::SyntaxTreeC,
        context_module::Module, world::UInt, filter::SyntheticFilter,
        observations::OCArgtypeTable, refinements::Union{Nothing,OCArgtypeTable},
        inf_cache::Vector{CC.InferenceResult}
    )
    inferrable_tree = try
        # Route single-method local closures through `OpaqueClosure` instead of
        # the synthetic-struct path. CC's native OC handling then resolves the
        # closure body and call sites precisely (the synthetic-struct route
        # collapses both to `Any` because the synthetic type isn't materialized
        # in `context_module`).
        st3_oc = rewrite_local_closures_to_opaque(ctx3, inferrable_tree3)
        ctx4, st4 = JL.convert_closures(ctx3, st3_oc)
        _, st5 = JL.linearize_ir(ctx4, st4)
        st5
    catch e
        JETLS_DEV_MODE && @error "infer_toplevel_tree: Lowering failed" e
        JETLS_DEV_MODE && Base.showerror(stderr, e, catch_backtrace())
        return nothing
    end |> prepare_type_attr
    lwr = JL.to_lowered_expr(inferrable_tree)

    Meta.isexpr(lwr, :thunk) || error("infer_toplevel_tree: Unexpected lowering result")
    src = lwr.args[1]::CodeInfo

    interp = infer_thunk!(inferrable_tree, src, context_module, nothing, world, filter,
        observations, refinements, inf_cache)
    infer_method_defs!(inferrable_tree, src, context_module, world, filter,
        observations, refinements, inf_cache)
    return interp
end

prepare_type_attr(st::SyntaxTreeC) = let g = JL.syntax_graph(st)
    attrs = Dict(pairs(g.attributes))
    attrs[:type] = Dict{Int, Any}()
    attrs[:matches] = Dict{Int, Vector{Core.MethodMatch}}()
    return SyntaxTreeC(JL.SyntaxGraph(g.edge_ranges, g.edges, attrs), st._id)
end

# `argtypes === nothing` keeps the `InferenceResult`'s default argtypes (intended
# for nargs=0 thunks); a `Vector{Any}` overrides them with one entry per slot.
function infer_thunk!(
        tree::SyntaxTreeC, src::CodeInfo, context_module::Module,
        argtypes::Union{Nothing,Vector{Any}}, world::UInt, filter::SyntheticFilter,
        observations::OCArgtypeTable, refinements::Union{Nothing,OCArgtypeTable},
        inf_cache::Vector{CC.InferenceResult}
    )
    strip_latestworld!(src)
    mi = construct_toplevel_mi(src, context_module)
    interp = ASTTypeAnnotator(world, tree, mi, filter;
        oc_argtype_observations=observations, oc_argtype_refinements=refinements, inf_cache)
    register_oc_body_trees!(interp.oc_body_trees, tree, src)
    result = CC.InferenceResult(mi)
    if argtypes !== nothing
        # Thunk MIs have no `specTypes`-derived argtypes, so populate them
        # explicitly to match the thunk's slot count.
        empty!(result.argtypes)
        append!(result.argtypes, argtypes)
    end
    frame = CC.InferenceState(result, src, #=cache=#:no, interp)
    CC.typeinf(interp, frame)
    return interp
end

# `Expr(:latestworld)` syncs the current task's `world_age` to the global world counter.
# JuliaLowering emits it after any binding-mutating op in the same thunk — `const`,
# `import`/`using`, method add, or the `Core.declare_global` that toplevel bare assignment
# expands to — so subsequent stmts can see those changes at runtime. CC mirrors this by
# flipping `currsaw_latestworld`, which makes `abstract_eval_globalref` widen every global
# (e.g. `Main.sin`) to `Any` — a guard against mid-inference binding mutation.
#
# In our snapshot-typing pass that guard has no subject: full-analysis has already
# materialized any binding changes the thunk produces into `context_module` at our fixed
# `interp.world`, so the snapshot CC reads is already the post-mutation state, and we
# never execute or cache the inferred result. Stripping the directive is therefore not
# just safe but a precision win — it lets `Const` propagation survive across what would
# otherwise be a forced widening point.
function strip_latestworld!(src::CodeInfo)
    for i in eachindex(src.code)
        s = src.code[i]
        if s isa Expr && s.head === :latestworld
            src.code[i] = nothing
        end
    end
    return src
end

function construct_toplevel_mi(src::CodeInfo, context_module::Module)
    resolve_toplevel_symbols!(src, context_module)
    return @ccall jl_method_instance_for_thunk(src::Any, context_module::Any)::Ref{MethodInstance}
end

# Perform some post-hoc mutation on lowered code, as expected by some abstract interpretation
# routines, especially for `:foreigncall` and `:cglobal`.
function resolve_toplevel_symbols!(src::CodeInfo, context_module::Module)
    @ccall jl_resolve_definition_effects_in_ir(
        #=jl_array_t *stmts=# src.code::Any,
        #=jl_module_t *m=# context_module::Any,
        #=jl_svec_t *sparam_vals=# Core.svec()::Any,
        #=jl_value_t *binding_edge=# C_NULL::Ptr{Cvoid},
        #=int binding_effects=# 0::Int)::Cvoid
    return src
end

function infer_method_defs!(
        inferred::SyntaxTreeC, src::CodeInfo, context_module::Module, world::UInt, filter::SyntheticFilter,
        observations::OCArgtypeTable, refinements::Union{Nothing,OCArgtypeTable},
        inf_cache::Vector{CC.InferenceResult}
    )
    block = inferred[1]
    nstmts = JS.numchildren(block)
    nstmts == length(src.code) || return
    for i = 1:nstmts
        node = block[i]
        JS.kind(node) === JS.K"method" || continue
        JS.numchildren(node) == 3 || continue
        body_tree = node[3]
        JS.kind(body_tree) === JS.K"code_info" || continue
        # Dispatcher methods synthesized for default args / kwargs have a body that just
        # calls the user method with the defaults filled in, but the user method might not
        # be bound in `context_module` here, so the call would infer as `Any` anyway.
        # Skip them to save inference time and to keep the resulting tree free of
        # meaningless `:type` annotations.
        JS.byte_range(body_tree) == JS.byte_range(node) && continue
        stmt = src.code[i]
        stmt isa Expr || continue
        stmt.head === :method || continue
        length(stmt.args) == 3 || continue
        sig_ref = stmt.args[2]
        body_codeinfo = stmt.args[3]
        body_codeinfo isa CodeInfo || continue

        nargs = Int(body_codeinfo.nargs)
        argtypes = something(
            resolve_method_argtypes(sig_ref, src, nargs, context_module, world),
            Any[Any for _ in 1:nargs])
        infer_thunk!(body_tree, body_codeinfo, context_module, argtypes, world, filter,
            observations, refinements, inf_cache)
    end
    return
end

# Preserve identity of `TypeVar`s shared between argtypes and sparams in lowered
# signatures. Re-evaluating `Core.TypeVar(:T, ...)` would create distinct objects
# that can't be closed by the sparams `UnionAll`s.
struct MethodSigEvalCache
    ssa_values::Dict{Int,Any}
    slot_assignment_values::Dict{Tuple{Int,Int},Any}
end
MethodSigEvalCache() = MethodSigEvalCache(Dict{Int,Any}(), Dict{Tuple{Int,Int},Any}())

# `sig_ref` (= `stmt.args[2]` of a `:method` 3-arg Expr) points to an outer
# `Core.svec(argtypes_svec, sparams_svec, source_loc)`; the first element is the
# argtypes svec we evaluate. Slots whose source expression can't be resolved (e.g.
# references to synthetic kwbody self bindings) fall back to `Any`.
function resolve_method_argtypes(
        @nospecialize(sig_ref), src::CodeInfo, nargs::Int,
        context_module::Module, world::UInt
    )
    outer = resolve_ssa_stmt(sig_ref, src)
    args = @something svec_call_args(outer) return nothing
    length(args) >= 1 || return nothing
    inner = resolve_ssa_stmt(args[1], src)
    inner_args = @something svec_call_args(inner) return nothing
    cache = MethodSigEvalCache()
    sparams = resolve_method_sparams(args, src, context_module, world, cache)
    argtypes = Vector{Any}(undef, nargs)
    for i = 1:nargs
        argtypes[i] = if i <= length(inner_args)
            eval_method_sig_type(inner_args[i], src, context_module, world, cache, sparams)
        else
            Any
        end
    end
    return argtypes
end

function resolve_method_sparams(
        outer_args, src::CodeInfo, context_module::Module, world::UInt,
        cache::MethodSigEvalCache
    )
    sparams = TypeVar[]
    length(outer_args) >= 2 || return sparams
    sparams_expr = resolve_ssa_stmt(outer_args[2], src)
    sparam_args = @something svec_call_args(sparams_expr) return sparams
    for arg in sparam_args
        val = eval_method_sig_value(arg, src, context_module, world, cache)
        val isa TypeVar && push!(sparams, val)
    end
    return sparams
end

function resolve_ssa_stmt(@nospecialize(expr), src::CodeInfo)
    while expr isa SSAValue
        expr = src.code[expr.id]
    end
    return expr
end

function svec_call_args(@nospecialize(expr))
    Meta.isexpr(expr, :call) || return nothing
    length(expr.args) >= 1 || return nothing
    callee = expr.args[1]
    callee isa GlobalRef || return nothing
    (callee.mod === Core && callee.name === :svec) || return nothing
    return @view expr.args[2:end]
end

function eval_method_sig_type(
        @nospecialize(expr), src::CodeInfo, context_module::Module, world::UInt,
        cache::MethodSigEvalCache, sparams::Vector{TypeVar}
    )
    val = eval_method_sig_value(expr, src, context_module, world, cache)
    val isa Type || val isa TypeVar || return Any
    return close_method_sig_typevars(val, sparams)
end

function close_method_sig_typevars(@nospecialize(typ), sparams::Vector{TypeVar})
    Base.has_free_typevars(typ) || return typ
    # Use the shortest `where`-order sparam prefix that closes `typ`. Later
    # sparams can't appear in earlier bounds, while earlier unused binders
    # collapse, matching `code_typed`'s unspecialized slot view.
    for n = 1:length(sparams)
        closed = @something close_method_sig_typevars(typ, sparams, n) return Any
        Base.has_free_typevars(closed) || return closed
    end
    return Any
end

function close_method_sig_typevars(@nospecialize(typ), sparams::Vector{TypeVar}, n::Int)
    closed = typ
    for i = n:-1:1
        closed = try
            UnionAll(sparams[i], closed)
        catch
            return nothing
        end
    end
    return closed
end

# Returns `nothing` when any leaf reference fails to resolve (e.g. undefined
# synthetic name); callers must treat that as "could not statically evaluate".
function eval_method_sig_value(
        @nospecialize(expr), src::CodeInfo, context_module::Module, world::UInt,
        cache::MethodSigEvalCache, stmt_limit::Int = length(src.code) + 1
    )
    if expr isa SSAValue
        1 <= expr.id <= length(src.code) || return nothing
        haskey(cache.ssa_values, expr.id) && return cache.ssa_values[expr.id]
        val = eval_method_sig_value(
            src.code[expr.id], src, context_module, world, cache, expr.id)
        cache.ssa_values[expr.id] = val
        return val
    elseif expr isa SlotNumber
        return eval_method_sig_slot_value(expr, src, context_module, world, cache, stmt_limit)
    elseif expr isa GlobalRef
        return resolve_globalref(expr, world)
    elseif Meta.isexpr(expr, :call)
        f = @something eval_method_sig_value(
            expr.args[1], src, context_module, world, cache, stmt_limit) return nothing
        cargs = Any[]
        for i = 2:length(expr.args)
            v = @something eval_method_sig_value(
                expr.args[i], src, context_module, world, cache, stmt_limit) return nothing
            push!(cargs, v)
        end
        try
            return Base.invoke_in_world(world, f, cargs...)
        catch
            return nothing
        end
    elseif expr isa QuoteNode
        return expr.value
    end
    # Self-evaluating literal (Number, String, Symbol, Bool, ...).
    return expr
end

function eval_method_sig_slot_value(
        slot::SlotNumber, src::CodeInfo, context_module::Module, world::UInt,
        cache::MethodSigEvalCache, stmt_limit::Int
    )
    slot_id = slot.id
    found = nothing
    for i = 1:min(stmt_limit - 1, length(src.code))
        stmt = src.code[i]
        if Meta.isexpr(stmt, :(=)) && length(stmt.args) == 2 && stmt.args[1] === slot
            found === nothing || return nothing
            found = Pair{Int,Any}(i, stmt.args[2])
        end
    end
    i, rhs = @something found return nothing
    key = (slot_id, i)
    haskey(cache.slot_assignment_values, key) && return cache.slot_assignment_values[key]
    val = eval_method_sig_value(rhs, src, context_module, world, cache, i)
    cache.slot_assignment_values[key] = val
    return val
end

function resolve_globalref(g::GlobalRef, world::UInt)
    if Base.invoke_in_world(world, isdefinedglobal, g.mod, g.name)::Bool
        val = Base.invoke_in_world(world, getglobal, g.mod, g.name)
        if val isa JET.AbstractBindingState
            val = abstract_binding_state_const_value(val)
        end
        return val
    end
    return nothing
end

# Static signature evaluation reads globals from the same virtualprocess-backed context
# module, but can only reuse binding states that carry an actual const value.
function abstract_binding_state_const_value(val::JET.AbstractBindingState)
    isdefined(val, :typ) || return nothing
    typ = val.typ
    typ isa Core.Const || return nothing
    return typ.val
end

# Queries
# =======

"""
    InferredTreeContext(
            inferred_tree::SyntaxTreeC, ctx3::JL.VariableAnalysisContext,
            st3::SyntaxTreeC, surface_kind_index::Dict{UnitRange{Int},JS.Kind},
            macrocall_types::Dict{UnitRange{Int},Vector{Any}}
        ) -> ctx::InferredTreeContext

[`TypeAnnotation`](@ref) pipeline step 3: wrap an annotated `inferred_tree` (from
[`infer_toplevel_tree`](@ref)) plus the post-scope-resolution `ctx3` / `st3` (from
[`get_inferrable_tree`](@ref)) and provenance indexes built before pruning,
yielding a query handle that [`get_type_for_range`](@ref) and friends can answer
in \$O(1)\$ per call (or \$O(log N)\$ for the branching case).

`ctx3` supplies closure argument binding ranges for parameter-position queries.
`st3` (rather than the surface tree) is needed to identify byte ranges of
*user-written* `K"return"` surface forms, which `type_for_branching` looks up
to filter user returns out of the value type of an enclosing branching
expression. Using `st3` lets the analysis see through desugared `&&` / `||` /
`?:` / chained comparisons (now `K"if"`) and through expanded macros —
without it, those constructs would leak.

Build once per `inferred_tree` and reuse across queries — the single \$O(N)\$
index build is amortized. Consumers should normally call [`get_type_for_range`](@ref) and
treat this type as opaque; the fields are implementation detail and may be reorganized
as new queries demand different indexes.

See the [`TypeAnnotation`](@ref) module docstring for the full pipeline.
"""
function InferredTreeContext(
        inferred_tree::SyntaxTreeC, ctx3::JL.VariableAnalysisContext, st3::SyntaxTreeC,
        surface_kind_index::Dict{UnitRange{Int},JS.Kind},
        macrocall_types::Dict{UnitRange{Int},Vector{Any}}
    )
    by_byte_range = Dict{UnitRange{Int}, Vector{SyntaxTreeC}}()
    return_first_bytes = Int[]
    return_nodes = SyntaxTreeC[]

    # These indexes retain tree nodes, so they must be built from the pruned tree;
    # otherwise the context would keep the unpruned graph alive.
    traverse(inferred_tree) do st::SyntaxTreeC
        rng = JS.byte_range(st)
        push!(get!(Vector{SyntaxTreeC}, by_byte_range, rng), st)
        if JS.kind(st) === JS.K"return"
            push!(return_first_bytes, JS.first_byte(st))
            push!(return_nodes, st)
        end
        return nothing
    end

    # Sort returns by `first_byte` so `searchsortedfirst` is valid. The traverse
    # order is roughly source order, but enforce explicitly to be safe.
    perm = sortperm(return_first_bytes)
    permute!(return_first_bytes, perm)
    permute!(return_nodes, perm)

    user_return_form_ranges = collect_user_return_form_ranges(st3)

    oc_body_scope = Dict{Int,UnitRange{Int}}()
    populate_oc_body_scope!(oc_body_scope, inferred_tree, nothing)
    oc_argument_binding_types = collect_oc_argument_binding_types(ctx3, inferred_tree)

    return InferredTreeContext(
        inferred_tree, surface_kind_index, by_byte_range,
        macrocall_types, return_first_bytes, return_nodes,
        user_return_form_ranges, oc_body_scope, oc_argument_binding_types)
end

# The surface kinds `get_type_for_range` selects a lookup strategy for. When several
# surface forms share one byte range, these take precedence in `surface_kind_index`
# over generic wrappers: a lambda body `K"block"` (or a short-form funcdef body)
# collapses onto the very expression it wraps, and letting the wrapper claim the range
# would drop the query into `tmerge_at_range`, merging loop/closure scaffolding types
# into the user-visible result.
const DISPATCH_SURFACE_KINDS = JS.KSet"macrocall call dotcall tuple ' do typed_comprehension for while function macro = comparison && || if ?"

function collect_provenance_indexes(inferred_tree::SyntaxTreeC)
    surface_kind_index = Dict{UnitRange{Int},JS.Kind}()
    macrocall_types = Dict{UnitRange{Int},Vector{Any}}()
    traverse(inferred_tree) do st::SyntaxTreeC
        provs = JS.flattened_provenance(st)
        if !isempty(provs)
            # Register *every* provenance entry, not just `first(provs)`. For
            # macro-wrapped surface forms — `@inline f(x) = body` whose chain is
            # `[macrocall, function]` — this makes the inner funcdef's span queryable
            # in addition to the macrocall's outer span. Within one range, dispatch
            # kinds win over generic wrappers; otherwise first-wins.
            for prov in provs
                prov_rng = JS.byte_range(prov)
                pk = JS.kind(prov)
                existing = get(surface_kind_index, prov_rng, nothing)
                if (existing === nothing ||
                    (!(existing in DISPATCH_SURFACE_KINDS) && pk in DISPATCH_SURFACE_KINDS))
                    surface_kind_index[prov_rng] = pk
                end
            end
        end
        if JS.kind(st) === JS.K"call" && JS.hasattr(st, :type) &&
                length(provs) >= 2 && JS.kind(first(provs)) === JS.K"macrocall"
            push!(get!(Vector{Any}, macrocall_types, JS.byte_range(first(provs))), st.type)
        end
        return nothing
    end
    return surface_kind_index, macrocall_types
end

# `K"code_info"` only marks an OC body when it's the body slot of a
# `K"opaque_closure_method"` — the top-level thunk is also wrapped in `K"code_info"` and
# would otherwise mark the entire tree. Each `K"opaque_closure_method"` opens its own
# scope; entering its `K"code_info"` child overrides the inherited scope so an inner OC's
# body is attributed to the inner method, not the outer.
function populate_oc_body_scope!(
        scope::Dict{Int,UnitRange{Int}},
        node::SyntaxTreeC,
        current::Union{Nothing,UnitRange{Int}},
    )
    current === nothing || (scope[node._id] = current)
    JS.is_leaf(node) && return
    if JS.kind(node) === JS.K"opaque_closure_method"
        method_range = JS.byte_range(node)
        for c in JS.children(node)
            child_scope = JS.kind(c) === JS.K"code_info" ? method_range : current
            populate_oc_body_scope!(scope, c, child_scope)
        end
    else
        for c in JS.children(node)
            populate_oc_body_scope!(scope, c, current)
        end
    end
    return
end

function collect_oc_argument_binding_types(
        ctx3::JL.VariableAnalysisContext, inferred_tree::SyntaxTreeC
    )
    oc_argtypes = collect_oc_argtypes_by_binding(inferred_tree)
    binding_types = Dict{UnitRange{Int},Any}()
    isempty(oc_argtypes) && return binding_types
    lambda_ranges = collect_lambda_ranges(ctx3)
    for binfo in ctx3.bindings.info
        binfo.kind === :argument || continue
        binfo.is_internal && continue
        lambda_range = get(lambda_ranges, binfo.lambda_id, nothing)
        lambda_range === nothing && continue
        name = binfo.name
        name isa AbstractString || continue
        typ = get(oc_argtypes, (lambda_range, Symbol(name)), nothing)
        typ === nothing && continue
        binding = SyntaxTreeC(ctx3.graph, binfo.node_id)
        JS.kind(binding) === JS.K"BindingId" || continue
        binding_types[JS.byte_range(binding)] = typ
    end
    return binding_types
end

function collect_lambda_ranges(ctx3::JL.VariableAnalysisContext)
    ranges = Dict{Int,UnitRange{Int}}()
    for scope in ctx3.scopes
        node = SyntaxTreeC(ctx3.graph, scope.node_id)
        JS.kind(node) === JS.K"lambda" || continue
        ranges[scope.lambda_id] = JS.byte_range(node)
    end
    return ranges
end

function collect_oc_argtypes_by_binding(inferred_tree::SyntaxTreeC)
    body_ranges_by_surface = collect_oc_body_ranges_by_surface(inferred_tree)
    oc_argtypes = Dict{Tuple{UnitRange{Int},Symbol},Any}()
    traverse(inferred_tree) do st::SyntaxTreeC
        JS.kind(st) === JS.K"new_opaque_closure" || return nothing
        JS.hasattr(st, :type) || return nothing
        entry = @something oc_argtypes_for_node(st.type, JS.byte_range(st)) return nothing
        body_ranges = get(Vector{UnitRange{Int}}, body_ranges_by_surface, entry.range)
        for i = 1:length(entry.argnames)
            typ = entry.argtypes[i]
            is_refined_slot(typ) || continue
            name = entry.argnames[i]
            oc_argtypes[(entry.range, name)] = typ
            for body_range in body_ranges
                oc_argtypes[(body_range, name)] = typ
            end
        end
        return nothing
    end
    return oc_argtypes
end

function collect_oc_body_ranges_by_surface(inferred_tree::SyntaxTreeC)
    body_ranges_by_surface = Dict{UnitRange{Int},Vector{UnitRange{Int}}}()
    traverse(inferred_tree) do st::SyntaxTreeC
        JS.kind(st) === JS.K"opaque_closure_method" || return nothing
        surface_range = JS.byte_range(st)
        for child in JS.children(st)
            JS.kind(child) === JS.K"code_info" || continue
            body_ranges = get!(Vector{UnitRange{Int}}, body_ranges_by_surface, surface_range)
            push!(body_ranges, JS.byte_range(child))
        end
        return nothing
    end
    return body_ranges_by_surface
end

function oc_argtypes_for_node(@nospecialize(typ), rng::UnitRange{Int})
    typ isa CC.PartialOpaque || return nothing
    source = typ.source
    source isa Method || return nothing
    argnames = (Base.method_argnames(source)[2:end]...,)
    argtypes = @something opaque_closure_argtypes(typ) return nothing
    length(argnames) == length(argtypes) || return nothing
    return (; range = rng, argnames, argtypes)
end

# `st3` (not `st0`) so `K"return"`s introduced by macro expansion are picked up.
function collect_user_return_form_ranges(st3::SyntaxTreeC)
    ranges = UnitRange{Int}[]
    traverse(st3) do st::SyntaxTreeC
        JS.kind(st) === JS.K"return" && push!(ranges, JS.byte_range(st))
        return nothing
    end
    return ranges
end

# Outermost (rather than innermost) so nested `return begin; return X; end`
# yields the outer form — the form-range the strict-contains filter needs.
function find_outermost_user_return_form(
        user_return_form_ranges::Vector{UnitRange{Int}}, r_range::UnitRange{<:Integer}
    )
    outermost = nothing
    for f_range in user_return_form_ranges
        r_range ⊆ f_range || continue
        if outermost === nothing || first(f_range) < first(outermost)
            outermost = f_range
        end
    end
    return outermost
end

"""
    build_inferred_context_for_tree(
            st0::SyntaxTreeC, context_module::Module;
            world::UInt = Base.get_world_counter(),
            caller::AbstractString = "build_inferred_context_for_tree",
            cache::Union{Nothing,InferredContextCache} = nothing
        ) -> ctx::InferredTreeContext | nothing

Compose [`TypeAnnotation`](@ref) pipeline steps 1–3 into a single call for an
already-selected lowerable top-level tree: run [`get_inferrable_tree`](@ref) and
[`infer_toplevel_tree`](@ref), and wrap the result in an [`InferredTreeContext`](@ref).
Returns `nothing` when the top-level form is skipped by type-annotation features,
or when lowering / inference fails.

When `cache` is provided, inferred contexts are reused by `(context_module, world,
top-level range)`, allowing repeated requests for the same synced document version to skip
lowering and inference.

Cache misses build outside the cache lock. Racing requests may duplicate inference for the
same key, but unrelated cache hits/misses are not blocked.
"""
function build_inferred_context_for_tree(
        st0::SyntaxTreeC, context_module::Module;
        world::UInt = Base.get_world_counter(),
        caller::AbstractString = "build_inferred_context_for_tree",
        cache::Union{Nothing,InferredContextCache} = nothing
    )
    is_type_annotation_skipped_toplevel(st0) && return nothing
    top_rng = JS.byte_range(st0)
    if cache === nothing
        return build_inferred_context(st0, context_module; world, caller)
    end
    key = (context_module, world, top_rng)
    entries = load(cache)
    haskey(entries, key) && return entries[key]
    # Build outside the cache lock: racing requests may duplicate inference
    # for the same key, but they don't block unrelated cache hits/misses.
    new_ctx = build_inferred_context(st0, context_module; world, caller)
    return store!(cache) do entries
        if haskey(entries, key)
            return entries, entries[key]
        end
        return InferredContextCacheData(entries, key => new_ctx), new_ctx
    end
end

"""
    build_inferred_context_for_range(
            st0_top::SyntaxTreeC, context_module::Module, rng::UnitRange{<:Integer};
            world::UInt = Base.get_world_counter(),
            caller::AbstractString = "build_inferred_context_for_range",
            cache::Union{Nothing,InferredContextCache} = nothing
        ) -> ctx::InferredTreeContext | nothing

Compose [`TypeAnnotation`](@ref) pipeline steps 1–3 into a single call: locate the
top-level subtree of `st0_top` that contains `rng`, run [`get_inferrable_tree`](@ref)
and [`infer_toplevel_tree`](@ref) on it, and wrap the result in an
[`InferredTreeContext`](@ref).
Returns `nothing` when no top-level subtree contains `rng`, the top-level form is skipped
by type-annotation features, or lowering / inference fails.

This is the standard entry point for LSP features that need TypeAnnotation queries.
Callers can then issue one or more [`get_type_for_range`](@ref) /
[`get_matches_for_range`](@ref) queries against the returned context.
When `cache` is provided, inferred contexts are reused by `(context_module, world,
top-level range)`, allowing repeated requests for the same synced document version to skip
lowering and inference.

Cache misses build outside the cache lock. Racing requests may duplicate inference for the
same key, but unrelated cache hits/misses are not blocked.
"""
function build_inferred_context_for_range(
        st0_top::SyntaxTreeC, context_module::Module, rng::UnitRange{<:Integer};
        world::UInt = Base.get_world_counter(),
        caller::AbstractString = "build_inferred_context_for_range",
        cache::Union{Nothing,InferredContextCache} = nothing
    )
    return iterate_toplevel_tree(st0_top) do st0::SyntaxTreeC
        rng ⊆ JS.byte_range(st0) || return nothing
        ctx = build_inferred_context_for_tree(st0, context_module; world, caller, cache)
        return TraversalReturn(ctx; terminate=true)
    end
end

function build_inferred_context(
        st0::SyntaxTreeC, context_module::Module;
        world::UInt = Base.get_world_counter(),
        caller::AbstractString = "build_inferred_context"
    )
    (; ctx3, st3) = @something get_inferrable_tree(st0, context_module; world, caller) return nothing
    inferred = @something infer_toplevel_tree(ctx3, st3, st0, context_module; world) return nothing
    # `JS.prune` minimizes provenance, so collect query-dispatch indexes first.
    surface_kind_index, macrocall_types = collect_provenance_indexes(inferred)
    return InferredTreeContext(JS.prune(inferred), ctx3, st3, surface_kind_index, macrocall_types)
end

"""
    get_type_for_range(ctx::InferredTreeContext, rng::UnitRange{<:Integer})

[`TypeAnnotation`](@ref) pipeline step 4: look up the inferred type at surface byte range `rng`.
Returns `nothing` if no lowered node corresponding to `rng` carries a `:type` attribute.

Build the [`InferredTreeContext`](@ref) once per inferred tree and reuse it across queries
— see the [`TypeAnnotation`](@ref) module docstring for the full pipeline.

# Dispatch

Lowering routinely places multiple SSA-position nodes at the same surface byte range, so
a naive `tmerge` of all matches would pull in synthetic helper types that the user never
wrote. The dispatch picks a per-kind strategy that filters or summarizes the lowered
nodes appropriately; see the source of each helper for the rationale behind its choice:

| surface kind                                           | strategy                     |
|:-------------------------------------------------------|:-----------------------------|
| `K"call"` / `K"dotcall"` / `K"tuple"` / `K"'"` / `K"do"` | `type_for_call`              |
| `K"macrocall"`                                         | `type_for_macroexpansion`    |
| `K"typed_comprehension"`                               | `type_for_array_construct`   |
| `K"function"` / `K"macro"`                             | `type_for_funcdef`           |
| `K"comparison"` / `K"&&"` / `K"||"` / `K"if"` / `K"?"` | `type_for_branching`         |
| `K"for"` / `K"while"`                                  | always `Core.Const(nothing)` |
| everything else                                        | `tmerge_at_range`            |
"""
function get_type_for_range(ctx::InferredTreeContext, rng::UnitRange{<:Integer})
    binding_typ = get(ctx.oc_argument_binding_types, rng, nothing)
    binding_typ === nothing || return binding_typ
    if is_oc_construction_site(ctx, rng)
        typ = type_for_oc_body_return_at_range(ctx, rng)
        typ === nothing || return typ
    end
    surface_kind = surface_kind_at_range(ctx, rng)
    if surface_kind === JS.K"macrocall"
        return type_for_macroexpansion(ctx, rng)
    elseif surface_kind in JS.KSet"call dotcall tuple ' do"
        return type_for_call(ctx, rng)
    elseif surface_kind === JS.K"typed_comprehension"
        return type_for_typed_comprehension(ctx, rng)
    elseif surface_kind in JS.KSet"for while"
        return Core.Const(nothing)
    elseif surface_kind in JS.KSet"function macro"
        return type_for_funcdef(ctx, rng)
    elseif surface_kind === JS.K"="
        # Pruned `st0` can collapse short-form function-definition provenance from
        # `K"function"` to the surface `K"="`. The inferred tree still carries the
        # method-like lowered node, so use that as the authoritative signal.
        typ = type_for_funcdef(ctx, rng)
        typ === nothing || return typ
    elseif surface_kind in JS.KSet"comparison && || if ?"
        # Ternary `b ? x : 0` is `K"if"` in the surface tree but `K"?"` in the
        # inferred tree's provenance (JuliaLowering retains the parser kind).
        return type_for_branching(ctx, rng)
    end
    return tmerge_at_range(ctx, rng)
end

surface_kind_at_range(ctx::InferredTreeContext, rng::UnitRange{<:Integer}) =
    get(ctx.surface_kind_index, rng, nothing)

# A macrocall expansion produces many `K"call"`s whose byte ranges fall under
# the original `K"macrocall"` source span. `macrocall_types` indexes only calls
# whose first provenance is the macrocall (skipping nodes the expansion imported
# from elsewhere); among them, the last non-Const type carries the value type.
# `Const` entries are skipped because they're usually metadata the expansion
# baked in (line numbers, `Module`, ...), not the user value.
function type_for_macroexpansion(ctx::InferredTreeContext, rng::UnitRange{<:Integer})
    typ = nothing
    for ntyp in get(ctx.macrocall_types, rng, ())
        ntyp isa Core.Const && continue
        typ = ntyp
    end
    return typ
end

# Last-K"call"-wins selector used by call-like surface kinds. The "last in
# preorder" K"call" is the outermost lowered call, i.e. the one that produces
# the user-visible value:
# - kwcall `f(; kw=v)`: `Core.tuple` (kw names) and `NamedTuple{…}` (kwargs
#   bundling) appear before `Core.kwcall(…)` in `src.code`, so the user call
#   wins.
# - NamedTuple literal `(; a=1, b=2)`: lowered as four calls — names tuple,
#   `NamedTuple{…}` type apply, values tuple, final constructor — and the
#   constructor (which produces the NamedTuple value) is emitted last.
# - Positional `f(args)` and `(1, 2, 3)`: a single K"call" at the range,
#   so "last" is just that single entry.
function type_for_call(ctx::InferredTreeContext, rng::UnitRange{<:Integer})
    typ = nothing
    for st in get(ctx.by_byte_range, rng, ())
        JS.kind(st) === JS.K"call" || continue
        JS.hasattr(st, :type) || continue
        typ = st.type
    end
    return typ
end

# `T[expr for v in iter]` lowers to an inlined "allocate-then-fill" loop:
# `Array{T,N}(undef, …)` for the result, then iterator/state/comparison
# scaffolding calls (`LinearIndices`, `Base.iterate`, `=== nothing` checks,
# …) — all sharing the user's byte range, so `tmerge_at_range`'s
# tmerge-everything strategy widens to `Any` here.
#
# `T[…]` literal syntax is hardcoded by Julia's parser/lowering to allocate
# `Array{T,N}`, so the user-visible value is always (a subtype of) `Array`.
# Pick the lowered `K"call"` matching that: ordering-independent (doesn't
# rely on the allocation being lowered first) and tight (`LinearIndices` is
# `<: AbstractArray` but not `<: Array`, so it's filtered).
#
# `wt !== Union{}` excludes the loop body's speculative-unreachable path
# (`Union{}` is `<: Array` since Bottom is a subtype of every type).
function type_for_typed_comprehension(ctx::InferredTreeContext, rng::UnitRange{<:Integer})
    for st in get(ctx.by_byte_range, rng, ())
        JS.kind(st) === JS.K"call" || continue
        JS.hasattr(st, :type) || continue
        wt = CC.widenconst(st.type)
        wt !== Union{} && wt <: Array && return st.type
    end
    return nothing
end

# `K"comparison"` / `K"&&"` / `K"||"` / `K"if"` (ternary or block-form) all
# lower to branching code where each branch produces a candidate value. The
# lowered branches show up as either:
# - merge-slot assignments (`K"="` whose byte range equals the surface `rng`)
#   when the surface is in `K"="` RHS or any non-tail position; or
# - synthetic tail returns (`K"return"` whose byte range is contained in
#   `rng`) when the surface is in tail position of a function body.
# The expression's value type is the `tmerge` over all such branch values.
#
# User-written `K"return"`s strictly inside `rng` exit the function and must
# not contribute (e.g. `out = if cond; return X; end` — the if's value is
# `Nothing`, not `Union{Nothing, typeof(X)}`). They're filtered via
# `ctx.user_return_form_ranges` containment.
function type_for_branching(ctx::InferredTreeContext, rng::UnitRange{<:Integer})
    typ = nothing
    # (1) equality match — any lowered kind, including merge-slot `K"="`.
    for st in get(ctx.by_byte_range, rng, ())
        JS.hasattr(st, :type) || continue
        ntyp = st.type
        typ = typ === nothing ? ntyp : CC.tmerge(ntyp, typ)
    end
    # (2) containment match — `K"return"` strictly inside `rng`, excluding
    #     user-written returns whose exit doesn't contribute to `rng`'s value.
    rng_start = rng.start
    rng_stop = rng.stop
    lo = searchsortedfirst(ctx.return_first_bytes, rng_start)
    for i in lo:length(ctx.return_first_bytes)
        first_byte = ctx.return_first_bytes[i]
        first_byte > rng_stop && break
        st = ctx.return_nodes[i]
        last_byte = JS.last_byte(st)
        last_byte > rng_stop && continue
        first_byte == rng_start && last_byte == rng_stop && continue # already counted
        form_rng = find_outermost_user_return_form(
            ctx.user_return_form_ranges, first_byte:last_byte)
        form_rng !== nothing && strictly_contains(rng, form_rng) && continue
        JS.hasattr(st, :type) || continue
        ntyp = st.type
        typ = typ === nothing ? ntyp : CC.tmerge(ntyp, typ)
    end
    return typ
end

# `outer` strictly contains `inner` (proper superset): same start/stop
# constraints as `⊆` but at least one bound is strict.
function strictly_contains(outer::UnitRange{<:Integer}, inner::UnitRange{<:Integer})
    return outer.start <= inner.start && inner.stop <= outer.stop &&
           (outer.start < inner.start || inner.stop < outer.stop)
end

# For `function f(…) … end` / `macro m(…) … end`, the user-visible "value" is
# the function's return type. The matching `K"method"` (or
# `K"opaque_closure_method"` for single-method local closures rewritten by
# `rewrite_local_closures_to_opaque`) wraps a `K"code_info"` body whose
# `K"return"` stmts carry the inferred return types; `tmerge` over them
# yields the function's value type.
function type_for_funcdef(ctx::InferredTreeContext, rng::UnitRange{<:Integer})
    typ = nothing
    for st in get(ctx.by_byte_range, rng, ())
        JS.kind(st) in JS.KSet"method opaque_closure_method" || continue
        for i = 1:JS.numchildren(st)
            child = st[i]
            JS.kind(child) === JS.K"code_info" || continue
            JS.numchildren(child) >= 1 || continue
            block = child[1]
            for j = 1:JS.numchildren(block)
                stmt = block[j]
                if JS.kind(stmt) === JS.K"return" && JS.hasattr(stmt, :type)
                    ntyp = stmt.type
                    typ = typ === nothing ? ntyp : CC.tmerge(ntyp, typ)
                end
            end
        end
    end
    return typ
end

is_oc_construction_site(ctx::InferredTreeContext, rng::UnitRange{<:Integer}) =
    any(s -> JS.kind(s) === JS.K"new_opaque_closure", get(ctx.by_byte_range, rng, ()))

function type_for_oc_body_return_at_range(
        ctx::InferredTreeContext, rng::UnitRange{<:Integer}
    )
    typ = nothing
    lo = searchsortedfirst(ctx.return_first_bytes, first(rng))
    for i in lo:length(ctx.return_first_bytes)
        first_byte = ctx.return_first_bytes[i]
        first_byte > last(rng) && break
        st = ctx.return_nodes[i]
        JS.last_byte(st) <= last(rng) || continue
        get(ctx.oc_body_scope, st._id, nothing) === rng || continue
        JS.hasattr(st, :type) || continue
        ntyp = st.type
        typ = typ === nothing ? ntyp : CC.tmerge(ntyp, typ)
    end
    return typ
end

function tmerge_at_range(ctx::InferredTreeContext, rng::UnitRange{<:Integer})
    nodes = get(ctx.by_byte_range, rng, ())
    # When `OpaqueClosure` construction occurs at `rng` (most often a comprehension/
    # `map`/`filter` auto-generated lambda whose source bytes coincide with the user's
    # yield expression), the construction scaffolding — OC method object, argt/rt_lb svec,
    # OC binding — would otherwise `tmerge` into the user-visible value and surface as
    # `Union{T, Method, OpaqueClosure, Type}`. Prefer the OC body's return type when
    # available; it summarizes the user-visible value without mixing in synthetic typed-
    # iterator conversion checks. Otherwise keep only nodes attributed to the body of the
    # OC at `rng`; outside that scope is scaffolding.
    is_oc_site = is_oc_construction_site(ctx, rng)
    # Property destructuring in parameter position (`do (; a, b)`) emits a
    # `getproperty(obj, :a)` whose field-name `K"Symbol"` leaf lands on the binding's
    # byte range, polluting it to `Union{T, Symbol}`. (Assignment-position `(; a, b) =`
    # is already handled by `is_synthetic_destructure_stmt` at annotation time.)
    # Skip the symbol when a binding slot shares the range.
    has_binding_slot = any(s -> JS.kind(s) === JS.K"slot", nodes)
    typ = nothing
    for st in nodes
        # `K"core"` leaves are lowering-introduced `Core.X` references (e.g. the
        # `Core.Any` argtype entry of a closure's argt svec, whose provenance sits on
        # the parameter's surface position); users can't write them, so their types
        # (`Const(Any)` etc.) must not leak into surface queries.
        JS.kind(st) === JS.K"core" && continue
        has_binding_slot && JS.kind(st) === JS.K"Symbol" && continue
        JS.hasattr(st, :type) || continue
        if is_oc_site && get(ctx.oc_body_scope, st._id, nothing) !== rng
            continue
        end
        # Synthetic `Core.Typeof(funcname)` overlaps the function name's byte
        # range; `tmerge`ing `Const(Type{T})` into `Const(T)` would surface
        # `Union{T, Type{T}}` for def-site name queries.
        is_synthetic_typeof_scaffolding(st) && continue
        ntyp = st.type
        typ = typ === nothing ? ntyp : CC.tmerge(ntyp, typ)
    end
    return typ
end

# `K"core"` callee can't appear in user source — user-written
# `Core.Typeof(x)` lowers to `K"globalref"` — so a K"core" "Typeof"
# call reliably marks JL's argtype-svec scaffolding.
function is_synthetic_typeof_scaffolding(st::SyntaxTreeC)
    JS.kind(st) === JS.K"call" || return false
    JS.numchildren(st) >= 1 || return false
    c1 = st[1]
    JS.kind(c1) === JS.K"core" || return false
    return get_name_val(c1) == "Typeof"
end

"""
    get_matches_for_range(
            ctx::InferredTreeContext, rng::UnitRange{<:Integer}
        ) -> Vector{Core.MethodMatch} | nothing

Look up the `Core.MethodMatch`es CC's dispatch produced for the call site at
surface byte range `rng`. Returns `nothing` if no lowered `K"call"` node at
`rng` carries a `:matches` attribute — the surface isn't a call site, the
lookup hit a non-method-dispatch `CallInfo` (`InvokeCallInfo`, `OpaqueClosureCallInfo`,
`ApplyCallInfo`, …), or inference couldn't see the callee at all.

Mirrors [`get_type_for_range`](@ref)'s "last `K"call"` wins" semantics for
call-shaped surface kinds: only the last `K"call"` at `rng` (the user-visible call —
kwcall scaffolding `K"call"`s share the byte range and precede it in preorder) is
consulted, so when its callee is unresolved this returns `nothing` rather than
leaking the scaffolding's matches.

Pair with [`build_inferred_context_for_range`](@ref) for the context.
"""
function get_matches_for_range(ctx::InferredTreeContext, rng::UnitRange{<:Integer})
    last_call = nothing
    for st in get(ctx.by_byte_range, rng, ())
        JS.kind(st) === JS.K"call" || continue
        last_call = st
    end
    last_call === nothing && return nothing
    JS.hasattr(last_call, :matches) || return nothing
    return last_call.matches::Vector{Core.MethodMatch}
end

function opaque_closure_argtypes(@nospecialize(typ))
    oc = Base.unwrap_unionall(CC.widenconst(typ))
    oc isa DataType || return nothing
    oc.name === Base.typename(Core.OpaqueClosure) || return nothing
    argt = oc.parameters[1]
    argt isa DataType || return nothing
    argt <: Tuple || return nothing
    params = argt.parameters
    any(CC.isvarargtype, params) && return nothing
    return Any[params...]
end

end # module TypeAnnotation
