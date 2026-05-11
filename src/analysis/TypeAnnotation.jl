"""
    TypeAnnotation

Type-annotation pipeline for the LSP feature path: parse → lower → infer → query.
Produces a `SyntaxTreeC` whose nodes carry `:type` attributes computed by a custom
`CC.AbstractInterpreter`, plus a query handle ([`InferredTreeContext`](@ref)) for
byte-range type lookups.

# Exported API

LSP feature code should normally only need these:

- [`infer_type_at_range`](@ref) — single-shot "type at this byte range",
  for features that issue one query per cursor position (go to type
  definition, single hover-type, …).
- [`build_inferred_context_at`](@ref) — build an [`InferredTreeContext`](@ref) once for a
  toplevel and reuse it across multiple queries on the same context
  (signature help and call completion query the function head plus each argument).
- [`get_type_for_range`](@ref) — the byte-range → type query; call against a
  context returned by `build_inferred_context_at`.
- [`get_matches_for_range`](@ref) — the byte-range → `Vector{Core.MethodMatch}`
  query. Returns the methods CC's dispatch picked at a call site, for features
  that want narrower jumps than `methods(callee)` (go-to-method-definition).
- [`InferredTreeContext`](@ref) — the query handle exported so feature
  code can spell its type in signatures (e.g. `Union{Nothing,InferredTreeContext}`).

The full pipeline below is documented because the prerequisites and
limitations propagate to the exported API — every type the exported entries
surface (whether through `infer_type_at_range` or through `get_type_for_range`
on a context built by `build_inferred_context_at`) is subject to the
constraints in "Prerequisite" and "Limitations".

# Pipeline

The four public pieces interlock in a fixed order — each step's output feeds the
next:

1. **Lower for scope resolution**:
   [`get_inferrable_tree(st0::SyntaxTreeC, context_module::Module) -> (; ctx3::JL.VariableAnalysisContext, st3::SyntaxTreeC) | nothing`](@ref get_inferrable_tree)
   walks a top-level `st0` through JuliaLowering's early scope passes against
   `context_module`, returning an `(ctx3, st3)` pair. Surface `K"error"` nodes are stripped
   first so incomplete user input still produces a usable lowered tree.

2. **Infer & annotate**:
   [`infer_toplevel_tree(ctx3::JL.VariableAnalysisContext, st3::SyntaxTreeC, context_module::Module; world::UInt = Base.get_world_counter()) -> inferred_tree::SyntaxTreeC`](@ref infer_toplevel_tree)
   takes `(ctx3, st3)` through the remaining JuliaLowering passes (`convert_closures` →
   `linearize_ir`), runs CC inference under the internal `ASTTypeAnnotator`, and
   writes the inferred type of each lowered statement back into the tree as a
   `:type` attribute. The result is a `inferred_tree::SyntaxTreeC` whose nodes — both at
   toplevel and inside method bodies — carry per-statement types.

3. **Build query indexes**:
   [`InferredTreeContext(inferred_tree::SyntaxTreeC, st3::SyntaxTreeC) -> ctx::InferredTreeContext`](@ref InferredTreeContext)
   wraps the annotated tree with \$O(N)\$-built indexes (`by_byte_range`, `surface_kind_index`,
   return-tail maps, OC body scope, …) so downstream queries are \$O(1)\$ per call.
   Build once per inferred tree, reuse across many queries.

4. **Query**:
   [`get_type_for_range(ctx::InferredTreeContext, rng::UnitRange{<:Integer}) -> typ`](@ref get_type_for_range)
   is the main entry point: given a surface byte range, it picks a lookup strategy based on
   the lowered surface kind (`K"call"`, `K"macrocall"`, `K"function"`, branching forms, …)
   and returns the inferred lattice element.

For LSP feature code, [`build_inferred_context_at`](@ref) collapses steps 1–3 into a single
call (locate the toplevel containing a byte range, run the pipeline,
return a ready-to-query [`InferredTreeContext`](@ref)).
[`infer_type_at_range`](@ref) further folds in step 4 for the common single-query case.

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

- **Parametric methods.** `TypeVar`s constructed via `Core.TypeVar(:T, ub)` in the
  argtypes svec are flattened to their upper bound (`val.ub`) so the slot has a
  usable `Type`. Furthermore, the thunk's `MethodInstance` is a thunk MI (`def isa Module`);
  CC's `sptypes_from_meth_instance` forces `EMPTY_SPTYPES` for toplevel MIs, so an
  `Expr(:static_parameter, i)` reference inside the body cannot retrieve `T` and infers as `Any`.
"""
module TypeAnnotation

using Core.IR
using JET: CC
using ..JETLS: JETLS_DEBUG_LOWERING, JL, JS, SyntaxTreeC, TraversalReturn,
    iterate_toplevel_tree, jl_lower_for_scope_resolution, rewrite_local_closures_to_opaque,
    traversal_terminator, traverse

export InferredTreeContext, build_inferred_context_at, get_matches_for_range,
    get_type_for_range, infer_type_at_range

# ASTTypeAnnotator
# ================

struct ASTTypeAnnotatorToken end

struct ASTTypeAnnotator <: CC.AbstractInterpreter
    toptree::SyntaxTreeC
    topmi::MethodInstance
    world::UInt
    inf_params::CC.InferenceParams
    opt_params::CC.OptimizationParams
    inf_cache::Vector{CC.InferenceResult}
    # OC `Method` → its body's `K"code_info"` SyntaxTree subtree. Populated by
    # `register_oc_body_trees!` after a thunk's `resolve_definition_effects_in_ir`
    # has replaced `:opaque_closure_method` Exprs with concrete `Method` objects;
    # `finishinfer!` then annotates OC body frames CC has infered.
    oc_body_trees::IdDict{Method,SyntaxTreeC}
    # OC `Method`s that are pending body annotation — populated by the
    # `abstract_eval_new_opaque_closure` override before the eager body
    # inference runs, consumed by `finishinfer!` (annotate then delete). Ensures
    # the body's citree is annotated from the eager `most_general_argtypes`
    # specialization (signature view), not from per-call-site specializations
    # — same model as top-level method bodies.
    oc_methods_to_annotate::Set{Method}
    function ASTTypeAnnotator(
            toptree::SyntaxTreeC,
            topmi::MethodInstance;
            world::UInt = Base.get_world_counter(),
            inf_params::CC.InferenceParams = CC.InferenceParams(;
                aggressive_constant_propagation = true
            ),
            opt_params::CC.OptimizationParams = CC.OptimizationParams(),
            inf_cache::Vector{CC.InferenceResult} = CC.InferenceResult[],
            oc_body_trees::IdDict{Method,SyntaxTreeC} = IdDict{Method,SyntaxTreeC}(),
            oc_methods_to_annotate::Set{Method} = Set{Method}()
        )
        return new(toptree, topmi, world, inf_params, opt_params, inf_cache,
            oc_body_trees, oc_methods_to_annotate)
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
function CC.abstract_eval_new_opaque_closure(
        interp::ASTTypeAnnotator, e::Expr, sstate::CC.StatementState, sv::CC.InferenceState
    )
    future = @invoke CC.abstract_eval_new_opaque_closure(
        interp::CC.AbstractInterpreter, e::Expr, sstate::CC.StatementState, sv::CC.InferenceState)
    rt_exct_effects = future[]
    po = rt_exct_effects.rt
    po isa CC.PartialOpaque || return future
    CC.call_result_unused(sv, sv.currpc) && return future
    # Mark this OC's `Method` so the eager body inference's `finishinfer!`
    # annotates the citree (signature view, like top-level methods). The marker
    # is consumed (deleted) atomically in `finishinfer!` itself; per-call-site
    # specializations of the same Method find the marker missing and skip.
    # We can't delete in this override's wrapper `Future` continuation because
    # that continuation can run synchronously (when the inner `abstract_call_opaque_closure`
    # returns an immediate `Future` due to in-progress / cache-hit body inference) —
    # before the body's `finishinfer!` has actually run.
    push!(interp.oc_methods_to_annotate, po.source)
    # Re-run the eager body inference the default just did; CC's specialization
    # cache absorbs the duplication and this avoids re-implementing the
    # function's `:opaque_closure`-Expr argument-collection plumbing.
    argtypes = CC.most_general_argtypes(po)
    pushfirst!(argtypes, po.env)
    arginfo, stmtinfo = CC.ArgInfo(nothing, argtypes), CC.StmtInfo(true, false)
    callinfo = CC.abstract_call_opaque_closure(
        interp, po, arginfo, stmtinfo, sv, #=check=#false)::CC.Future
    return CC.Future{CC.RTEffects}(callinfo, interp, sv) do callinfo, _, _
        refined_rt = refine_partial_opaque_rt(po, callinfo.rt)
        return CC.RTEffects(refined_rt, rt_exct_effects.exct, rt_exct_effects.effects, rt_exct_effects.refinements)
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
    _collect_call_matches!(matches, info)
    return isempty(matches) ? nothing : matches
end

function _collect_call_matches!(matches::Vector{Core.MethodMatch}, @nospecialize info)
    if info isa CC.MethodMatchInfo
        for m in info.results.matches
            push!(matches, m)
        end
    elseif info isa CC.UnionSplitInfo
        for sub in info.split
            _collect_call_matches!(matches, sub)
        end
    elseif info isa CC.ConstCallInfo
        # `ConstCallInfo` wraps the underlying dispatch info with a
        # const-prop'd result; the same matching methods live one level down.
        _collect_call_matches!(matches, info.call)
    end
    return matches
end

function annotate_types!(citree::SyntaxTreeC, frame::CC.InferenceState)
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
        JS.setattr!(stmttree, :type, stmttype)
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
                if lhs isa SlotNumber
                    JS.setattr!(treeref[1], :type, stmttype)
                end
                stmt = stmt.args[2]
                stmt isa Expr || continue
                treeref = treeref[2]
                JS.setattr!(treeref, :type, stmttype)
            end
            is_call = stmt.head === :call
            if is_call
                matches = extract_call_matches(frame.stmt_info[i])
                matches === nothing || JS.setattr!(treeref, :matches, matches)
            end
            for j = 1:length(stmt.args)
                arg = stmt.args[j]
                if arg isa SlotNumber
                    argtyp = slot_type_at(arg, i, frame)
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
        annotate_types!(interp.toptree[1], frame)
    else
        def = frame.linfo.def
        # Annotate only when this is the eager body inference's `finishinfer!`
        # (marker pushed by `abstract_eval_new_opaque_closure`); per-call-site
        # specializations of the same Method find the marker missing and skip.
        # The marker is consumed here (delete atomically with the annotation)
        # so it doesn't leak into subsequent inferences in the same interp.
        if def isa Method && def in interp.oc_methods_to_annotate
            delete!(interp.oc_methods_to_annotate, def)
            oc_citree = get(interp.oc_body_trees, def, nothing)
            # `oc_citree[1]` is the body block, matching `annotate_types!`'s contract.
            oc_citree === nothing || annotate_types!(oc_citree[1], frame)
        end
    end
    return ret
end

# Walk `(citree, src)` and register `is_for_opaque_closure` `Method` objects
# (the result of `resolve_definition_effects_in_ir` replacing
# `:opaque_closure_method` Exprs in `src.code`) against the matching
# `K"code_info"` subtree of the corresponding `K"opaque_closure_method"` syntax
# node. Method-keyed (not CodeInfo-keyed) because `jl_method_set_source`
# compresses the body — `frame.src` is a freshly decompressed copy and won't
# `===` the original body `CodeInfo`.
#
# Recurses through each newly-registered OC's body via `Base.uncompressed_ir`
# to register nested closures up-front. Unlike regular closures (which
# `JL.convert_closures` hoists to top-level `:method` 3-arg statements),
# `:opaque_closure_method` stays at the construction site, so an inner OC's
# Method lives inside its outer OC's body — not in the thunk's top-level
# `src.code`. Without the recursion, when CC dispatches the inner OC and
# `finishinfer!` runs for it, the lookup against `oc_body_trees` misses.
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
            context_module::Module;
            world::UInt = Base.get_world_counter()
        ) -> inferred::SyntaxTreeC

[`TypeAnnotation`](@ref) pipeline step 2: take `(ctx3, st3)` (typically from
[`get_inferrable_tree`](@ref)) through the remaining JuliaLowering passes, run CC
inference under the internal `ASTTypeAnnotator`, and return a `SyntaxTreeC`
annotated with a `:type` attribute on each lowered statement. The walk recurses
into `:method` 3-arg statements: each method body is inferred as its own
anonymous thunk against argtypes statically evaluated from the sig svec.

`world` (default: the current world) selects the inference world used
throughout. The returned tree contains both top-level statements and method
bodies, all annotated, so downstream lookups via [`get_type_for_range`](@ref)
work for either without descending into bodies separately.

See the [`TypeAnnotation`](@ref) module docstring for the rest of the pipeline,
the full-analysis prerequisite, and the current limitations.
"""
infer_toplevel_tree(args...; kwargs...) =
    (@something _infer_toplevel_tree(args...; kwargs...) return nothing).toptree

function _infer_toplevel_tree(
        ctx3::JL.VariableAnalysisContext, inferrable_tree3::SyntaxTreeC, context_module::Module;
        world::UInt = Base.get_world_counter()
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
        @error "infer_toplevel_tree: Lowering failed" e
        return nothing
    end |> prepare_type_attr
    lwr = JL.to_lowered_expr(inferrable_tree)

    Meta.isexpr(lwr, :thunk) || error("infer_toplevel_tree: Unexpected lowering result")
    src = lwr.args[1]::CodeInfo

    interp = infer_thunk!(inferrable_tree, src, context_module, nothing, world)
    infer_method_defs!(inferrable_tree, src, context_module, world)
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
function infer_thunk!(tree::SyntaxTreeC, src::CodeInfo, context_module::Module,
                      argtypes::Union{Nothing,Vector{Any}}, world::UInt)
    strip_latestworld!(src)
    mi = construct_toplevel_mi(src, context_module)
    interp = ASTTypeAnnotator(tree, mi; world)
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
        inferred::SyntaxTreeC, src::CodeInfo, context_module::Module, world::UInt
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
        infer_thunk!(body_tree, body_codeinfo, context_module, argtypes, world)
    end
    return
end

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
    argtypes = Vector{Any}(undef, nargs)
    for i = 1:nargs
        argtypes[i] = i <= length(inner_args) ?
            eval_to_type(inner_args[i], src, context_module, world) : Any
    end
    return argtypes
end

function resolve_ssa_stmt(@nospecialize(expr), src::CodeInfo)
    while expr isa SSAValue
        expr = src.code[expr.id]
    end
    return expr
end

function svec_call_args(@nospecialize(expr))
    expr isa Expr || return nothing
    expr.head === :call || return nothing
    length(expr.args) >= 1 || return nothing
    callee = expr.args[1]
    callee isa GlobalRef || return nothing
    (callee.mod === Core && callee.name === :svec) || return nothing
    return @view expr.args[2:end]
end

function eval_to_type(
        @nospecialize(expr), src::CodeInfo, context_module::Module, world::UInt
    )
    val = eval_to_value(expr, src, context_module, world)
    val isa TypeVar && return val.ub
    return val isa Type ? val : Any
end

# Returns `nothing` when any leaf reference fails to resolve (e.g. undefined
# synthetic name); callers must treat that as "could not statically evaluate".
function eval_to_value(
        @nospecialize(expr), src::CodeInfo, context_module::Module, world::UInt
    )
    if expr isa SSAValue
        return eval_to_value(resolve_ssa_stmt(expr, src), src, context_module, world)
    elseif expr isa GlobalRef
        return resolve_globalref(expr, world)
    elseif expr isa Expr && expr.head === :call
        f = @something eval_to_value(expr.args[1], src, context_module, world) return nothing
        cargs = Any[]
        for i = 2:length(expr.args)
            v = @something eval_to_value(expr.args[i], src, context_module, world) return nothing
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

function resolve_globalref(g::GlobalRef, world::UInt)
    if Base.invoke_in_world(world, isdefinedglobal, g.mod, g.name)::Bool
        return Base.invoke_in_world(world, getglobal, g.mod, g.name)
    end
    return nothing
end

# Queries
# =======

"""
    InferredTreeContext(
            inferred_tree::SyntaxTreeC, st3::SyntaxTreeC
        ) -> ctx::InferredTreeContext

[`TypeAnnotation`](@ref) pipeline step 3: wrap an annotated `inferred_tree` (from
[`infer_toplevel_tree`](@ref)) plus the post-scope-resolution `st3` (from
[`get_inferrable_tree`](@ref)) with prebuilt indexes, yielding a query handle
that [`get_type_for_range`](@ref) and friends can answer in \$O(1)\$ per call (or
\$O(log N)\$ for the branching case).

`st3` (rather than the surface tree) is needed to identify byte ranges of
*user-written* `return` values, which `type_for_branching` filters out so they
don't pollute the value type of an enclosing branching expression. Using `st3`
lets the analysis see through desugared `&&` / `||` / `?:` / chained
comparisons (now `K"if"`) and through expanded macros — without it, those
constructs would leak.

Build once per `inferred_tree` and reuse across queries — the single \$O(N)\$
index build is amortized. Consumers should normally call [`get_type_for_range`](@ref) and
treat this type as opaque; the fields are implementation detail and may be reorganized
as new queries demand different indexes.

See the [`TypeAnnotation`](@ref) module docstring for the full pipeline.
"""
struct InferredTreeContext
    inferred_tree::SyntaxTreeC
    # `byte_range => kind` for the surface node each lowered node was lowered
    # from (first element of `JS.flattened_provenance`). First-write-wins,
    # mirroring a `traverse`-then-pick-first lookup.
    surface_kind_index::Dict{UnitRange{Int}, JS.Kind}
    # Every lowered node keyed by its own `byte_range`, in preorder. The
    # preorder property is load-bearing for the "last `K"call"` wins"
    # semantics in `type_for_call`.
    by_byte_range::Dict{UnitRange{Int}, Vector{SyntaxTreeC}}
    # Typed `K"call"` nodes whose first provenance is a `K"macrocall"`, keyed
    # by the **macrocall's** `byte_range` (not the lowered call's own range —
    # string macros lower to a `K"call"` with a smaller span than the
    # macrocall, so we key by the surface span the user wrote).
    macrocall_typed_calls::Dict{UnitRange{Int}, Vector{SyntaxTreeC}}
    # Every `K"return"` node, in two parallel `Vector`s sorted by
    # `JS.first_byte` (so `searchsortedfirst` is valid on `return_first_bytes`).
    return_first_bytes::Vector{Int}
    return_nodes::Vector{SyntaxTreeC}
    # Maps each tail-position byte range `R` of a user-written `return X`
    # to the *innermost* user return value byte range that produced it
    # (i.e. `byte_range(X)` for the closest enclosing user `return`).
    # Computed by walking `st3` for `K"return"` nodes and descending into
    # tail-recursing forms (`K"if"` branches, `K"block"` last child, …).
    # `type_for_branching(rng)` filters a contained `K"return"` at `R`
    # when `rng` *strictly* contains the recorded URV — meaning the user
    # `return` is fully inside the queried expression, so its exit shouldn't
    # pollute the queried value. When `rng ⊆ URV` (the queried expression
    # is the user return value itself, or a sub-expression of it), the
    # `K"return"` is part of the queried branching's value and isn't
    # filtered.
    user_return_value_ranges::Dict{UnitRange{Int}, UnitRange{Int}}
    # For each lowered node inside the body of some OC, the byte range of that OC's
    # `K"opaque_closure_method"`. Used by `tmerge_at_range` to filter OC construction
    # scaffolding sharing a byte range with the user's yield expression: a node is kept
    # only when the OC whose body it's in has the queried byte range — so inner-OC noise
    # inside an outer OC body (e.g. multi-`for` comprehension, closure-of-closure) is
    # filtered when querying at the inner OC's range.
    oc_body_scope::Dict{Int,UnitRange{Int}}
end

function InferredTreeContext(inferred_tree::SyntaxTreeC, st3::SyntaxTreeC)
    surface_kind_index = Dict{UnitRange{Int}, JS.Kind}()
    by_byte_range = Dict{UnitRange{Int}, Vector{SyntaxTreeC}}()
    macrocall_typed_calls = Dict{UnitRange{Int}, Vector{SyntaxTreeC}}()
    return_first_bytes = Int[]
    return_nodes = SyntaxTreeC[]

    traverse(inferred_tree) do st::SyntaxTreeC
        rng = JS.byte_range(st)
        push!(get!(Vector{SyntaxTreeC}, by_byte_range, rng), st)

        provs = JS.flattened_provenance(st)
        if !isempty(provs)
            fprov = first(provs)
            fprov_rng = JS.byte_range(fprov)
            # Register *every* provenance entry, not just `first(provs)`. For
            # macro-wrapped surface forms — `@inline f(x) = body` whose chain is
            # `[macrocall, function]` — this makes the inner funcdef's span queryable
            # in addition to the macrocall's outer span.
            for prov in provs
                prov_rng = JS.byte_range(prov)
                haskey(surface_kind_index, prov_rng) ||
                    (surface_kind_index[prov_rng] = JS.kind(prov))
            end

            if JS.kind(st) === JS.K"call" && hasproperty(st, :type) &&
                    length(provs) >= 2 && JS.kind(fprov) === JS.K"macrocall"
                push!(get!(Vector{SyntaxTreeC}, macrocall_typed_calls, fprov_rng), st)
            end
        end

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

    user_return_value_ranges = Dict{UnitRange{Int}, UnitRange{Int}}()
    collect_user_return_value_ranges!(user_return_value_ranges, st3)

    oc_body_scope = Dict{Int,UnitRange{Int}}()
    populate_oc_body_scope!(oc_body_scope, inferred_tree, nothing)

    return InferredTreeContext(
        inferred_tree, surface_kind_index, by_byte_range,
        macrocall_typed_calls, return_first_bytes, return_nodes,
        user_return_value_ranges, oc_body_scope)
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

# Walk `st`, find every `K"return"` node, and record the byte ranges of all
# tail-position values of its return value into `D`, mapped to the innermost
# enclosing user return's value byte range. Operates on `st3`
# (post-desugaring, post-macro-expansion), so `&&` / `||` / `?:` / chained
# comparisons all show up as `K"if"` and macros are already expanded.
function collect_user_return_value_ranges!(
        D::Dict{UnitRange{Int}, UnitRange{Int}}, st::SyntaxTreeC
    )
    if JS.kind(st) === JS.K"return" && JS.numchildren(st) >= 1
        urv = JS.byte_range(st[1])
        record_user_return_tails!(D, st[1], urv)
    end
    for i = 1:JS.numchildren(st)
        collect_user_return_value_ranges!(D, st[i])
    end
end

# Recursively descend `value` (the RHS of a user `return`), and for every
# tail-position leaf record `byte_range(leaf) => urv`. When a nested
# `K"return"` is encountered, its own value becomes the innermost `urv` for
# its sub-walk so the entries point at the closest enclosing user return —
# `type_for_branching`'s strict-contains check then correctly distinguishes
# "queried expression is inside the user return" from "queried expression
# strictly contains the user return".
function record_user_return_tails!(D::Dict{UnitRange{Int}, UnitRange{Int}},
                                   value::SyntaxTreeC, urv::UnitRange{<:Integer})
    k = JS.kind(value)
    if k === JS.K"if" || k === JS.K"elseif"
        # `K"if"` shape: cond, then, optional else.
        n = JS.numchildren(value)
        n >= 2 && record_user_return_tails!(D, value[2], urv)
        if n >= 3
            record_user_return_tails!(D, value[3], urv)
        else
            # No-else branch: lowering synthesizes `K"return"(nothing)` with
            # srcref = the `K"if"` itself, so its byte range is `value`'s.
            record_tail!(D, JS.byte_range(value), urv)
        end
    elseif k === JS.K"block" || k === JS.K"scope_block"
        n = JS.numchildren(value)
        if n >= 1
            record_user_return_tails!(D, value[n], urv)
        else
            record_tail!(D, JS.byte_range(value), urv)
        end
    elseif k === JS.K"return"
        # Nested `return` inside the value subtree: switch to its own URV so
        # this nested return's tail SSAs trace back to *it* (innermost),
        # not the wrapping return.
        if JS.numchildren(value) >= 1
            inner_urv = JS.byte_range(value[1])
            record_user_return_tails!(D, value[1], inner_urv)
        else
            record_tail!(D, JS.byte_range(value), urv)
        end
    else
        # Leaf or non-tail-recursing form (call, identifier, literal,
        # `K"trycatchelse"` / `K"tryfinally"` — the last two are unhandled
        # for now and may leak; covered by `@test_broken` in the test file).
        record_tail!(D, JS.byte_range(value), urv)
    end
end

# Keep the smaller (more strictly-contained) URV when a tail range is
# encountered via multiple traversal paths. Smaller URV = more innermost
# user return = the right URV to compare the queried `rng` against.
function record_tail!(D::Dict{UnitRange{Int}, UnitRange{Int}},
                      R::UnitRange{<:Integer}, urv::UnitRange{<:Integer})
    cur = get(D, R, nothing)
    if cur === nothing || length(urv) < length(cur)
        D[R] = urv
    end
end

"""
    build_inferred_context_at(
            st0_top::SyntaxTreeC, context_module::Module, rng::UnitRange{<:Integer};
            world::UInt = Base.get_world_counter(),
            caller::AbstractString = "build_inferred_context_at"
        ) -> ctx::InferredTreeContext | nothing

Compose [`TypeAnnotation`](@ref) pipeline steps 1–3 into a single call: locate the
top-level subtree of `st0_top` that contains `rng`, run [`get_inferrable_tree`](@ref)
and [`infer_toplevel_tree`](@ref) on it, and wrap the result in an
[`InferredTreeContext`](@ref). Returns `nothing` when no top-level subtree contains `rng`,
or when lowering / inference fails.

The standard entry point for LSP features that need to issue **multiple**
[`get_type_for_range`](@ref) queries against the same toplevel — e.g. signature
help looks up the function's type and then each argument's type. For a single
range lookup, [`infer_type_at_range`](@ref) is the convenience shortcut that
also folds in step 4.
"""
function build_inferred_context_at(
        st0_top::SyntaxTreeC, context_module::Module, rng::UnitRange{<:Integer};
        world::UInt = Base.get_world_counter(),
        caller::AbstractString = "build_inferred_context_at"
    )
    return iterate_toplevel_tree(st0_top) do st0::SyntaxTreeC
        rng ⊆ JS.byte_range(st0) || return nothing
        result = @something get_inferrable_tree(
            st0, context_module; world, caller) return traversal_terminator
        (; ctx3, st3) = result
        inferred = @something infer_toplevel_tree(
            ctx3, st3, context_module; world) return traversal_terminator
        return TraversalReturn(InferredTreeContext(inferred, st3); terminate=true)
    end
end

"""
    infer_type_at_range(
            st0_top::SyntaxTreeC, context_module::Module, rng::UnitRange{<:Integer};
            world::UInt = Base.get_world_counter()
        ) -> typ | nothing

Compose all four [`TypeAnnotation`](@ref) pipeline steps into a single call: run inference
on the top-level subtree containing `rng` and return the inferred type at `rng`.
Returns `nothing` if lowering / inference fails, or no `:type` annotation exists at `rng`.

The shared cursor-to-type bridge for LSP features that need only one query
(go to type definition, single-shot hover-type, …).
For features that need multiple queries against the same toplevel, build the context once with
[`build_inferred_context_at`](@ref) and reuse it across [`get_type_for_range`](@ref) calls.
"""
function infer_type_at_range(
        st0_top::SyntaxTreeC, context_module::Module, rng::UnitRange{<:Integer};
        world::UInt = Base.get_world_counter(),
    )
    ctx = @something build_inferred_context_at(
        st0_top, context_module, rng; world, caller="infer_type_at_range") return nothing
    return get_type_for_range(ctx, rng)
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
| `K"call"` / `K"dotcall"` / `K"tuple"`                  | `type_for_call`              |
| `K"macrocall"`                                         | `type_for_macroexpansion`    |
| `K"typed_comprehension"`                               | `type_for_array_construct`   |
| `K"function"` / `K"macro"`                             | `type_for_funcdef`           |
| `K"comparison"` / `K"&&"` / `K"||"` / `K"if"` / `K"?"` | `type_for_branching`         |
| `K"for"` / `K"while"`                                  | always `Core.Const(nothing)` |
| everything else                                        | `tmerge_at_range`            |
"""
function get_type_for_range(ctx::InferredTreeContext, rng::UnitRange{<:Integer})
    surface_kind = surface_kind_at_range(ctx, rng)
    if surface_kind === JS.K"macrocall"
        return type_for_macroexpansion(ctx, rng)
    elseif surface_kind in JS.KSet"call dotcall tuple"
        return type_for_call(ctx, rng)
    elseif surface_kind === JS.K"typed_comprehension"
        return type_for_typed_comprehension(ctx, rng)
    elseif surface_kind in JS.KSet"for while"
        return Core.Const(nothing)
    elseif surface_kind in JS.KSet"function macro"
        return type_for_funcdef(ctx, rng)
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
# the original `K"macrocall"` source span. `macrocall_typed_calls` indexes only
# those whose first provenance is the macrocall (skipping nodes the expansion
# imported from elsewhere); among them, the last typed non-Const call carries
# the value type. `Const` entries are skipped because they're usually metadata
# the expansion baked in (line numbers, `Module`, …), not the user value.
function type_for_macroexpansion(ctx::InferredTreeContext, rng::UnitRange{<:Integer})
    typ = nothing
    for st5 in get(ctx.macrocall_typed_calls, rng, ())
        ntyp = st5.type
        ntyp isa Core.Const && continue
        typ = ntyp
    end
    return typ
end

# Last-K"call"-wins selector used by `K"call"` / `K"dotcall"` / `K"tuple"`
# surface kinds. The "last in preorder" K"call" is the outermost lowered
# call, i.e. the one that produces the user-visible value:
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
        hasproperty(st, :type) || continue
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
        hasproperty(st, :type) || continue
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
# A `K"return"` that spans exactly `rng` (synthesized when the branching
# expression is itself the function body) lives in both `by_byte_range[rng]`
# and the K"return" containment scan, so the explicit `continue` below skips
# it in the second scan to avoid double-counting.
#
# *User-written* `K"return"` exits the function and must not contribute to
# the enclosing expression's value (e.g. `out = if cond; return X; end` —
# the if's value is `Nothing`, not `Union{Nothing, typeof(X)}`). They're
# filtered via `ctx.user_return_value_ranges`, which records the byte
# ranges of every tail-position value reachable from a user `return`'s
# right-hand side.
function type_for_branching(ctx::InferredTreeContext, rng::UnitRange{<:Integer})
    typ = nothing
    # (1) equality match — any lowered kind, including merge-slot `K"="`.
    for st in get(ctx.by_byte_range, rng, ())
        hasproperty(st, :type) || continue
        ntyp = st.type
        typ = typ === nothing ? ntyp : CC.tmerge(ntyp, typ)
    end
    # (2) containment match — `K"return"` strictly inside `rng`, excluding
    #     user-written returns.
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
        # Skip user-return tails when their URV is strictly contained in
        # `rng` — i.e. the user `return` is fully inside `rng`, so its
        # exit doesn't contribute to `rng`'s value. When `rng ⊆ URV`
        # (queried expression IS inside the return value), the K"return"
        # is a branch tail of `rng` itself and stays.
        let urv = get(ctx.user_return_value_ranges, first_byte:last_byte, nothing)
            urv !== nothing && strictly_contains(rng, urv) && continue
        end
        hasproperty(st, :type) || continue
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
                if JS.kind(stmt) === JS.K"return" && hasproperty(stmt, :type)
                    ntyp = stmt.type
                    typ = typ === nothing ? ntyp : CC.tmerge(ntyp, typ)
                end
            end
        end
    end
    return typ
end

function tmerge_at_range(ctx::InferredTreeContext, rng::UnitRange{<:Integer})
    nodes = get(ctx.by_byte_range, rng, ())
    # When `OpaqueClosure` construction occurs at `rng` (most often a comprehension/
    # `map`/`filter` auto-generated lambda whose source bytes coincide with the user's
    # yield expression), the construction scaffolding — OC method object, argt/rt_lb svec,
    # OC binding — would otherwise `tmerge` into the user-visible value and surface as
    # `Union{T, Method, OpaqueClosure, Type}`. Keep only nodes attributed to the body of
    # the OC at `rng`; outside that scope is scaffolding.
    is_oc_site = any(s -> JS.kind(s) === JS.K"new_opaque_closure", nodes)
    typ = nothing
    for st in nodes
        hasproperty(st, :type) || continue
        if is_oc_site && get(ctx.oc_body_scope, st._id, nothing) !== rng
            continue
        end
        # Skip `core.Typeof(funcname)` calls that lowering inserts when building
        # a method's argtypes svec — those calls share the function name's byte
        # range and would `tmerge` `Const(Type{T})` into the value's `Const(T)`,
        # surfacing `Union{T, Type{T}}` to consumers querying the def-site name.
        is_method_def_typeof_scaffolding(st) && continue
        ntyp = st.type
        typ = typ === nothing ? ntyp : CC.tmerge(ntyp, typ)
    end
    return typ
end

function is_method_def_typeof_scaffolding(st::SyntaxTreeC)
    JS.kind(st) === JS.K"call" || return false
    JS.numchildren(st) ≥ 1 || return false
    callee = st[1]
    JS.kind(callee) === JS.K"core" || return false
    JS.hasattr(callee, :name_val) || return false
    return callee.name_val == "Typeof"
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
call-shaped surface kinds: kwcall sites lower the kwargs `NamedTuple` constructor and
`Core.tuple` builder as separate `K"call"`s sharing the user call's byte range,
but the user's call is emitted last in preorder, so this returns matches for
the user-visible dispatch rather than for the scaffolding.

Pair with [`build_inferred_context_at`](@ref) for the context.
"""
function get_matches_for_range(ctx::InferredTreeContext, rng::UnitRange{<:Integer})
    matches = nothing
    for st in get(ctx.by_byte_range, rng, ())
        JS.kind(st) === JS.K"call" || continue
        hasproperty(st, :matches) || continue
        matches = st.matches::Vector{Core.MethodMatch}
    end
    return matches
end

end # module TypeAnnotation
