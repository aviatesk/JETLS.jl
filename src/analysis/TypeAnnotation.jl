module TypeAnnotation

using Core.IR
using JET: CC
using ..JETLS: JETLS_DEBUG_LOWERING, JETLS_DEV_MODE, JL, JS, SyntaxTreeC,
    jl_lower_for_scope_resolution, traverse

export InferredTreeContext, get_inferrable_tree, get_type_for_range, infer_toplevel_tree

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
    function ASTTypeAnnotator(
            toptree::SyntaxTreeC,
            topmi::MethodInstance;
            world::UInt = Base.get_world_counter(),
            inf_params::CC.InferenceParams = CC.InferenceParams(;
                aggressive_constant_propagation = true
            ),
            opt_params::CC.OptimizationParams = CC.OptimizationParams(),
            inf_cache::Vector{CC.InferenceResult} = CC.InferenceResult[]
        )
        return new(toptree, topmi, world, inf_params, opt_params, inf_cache)
    end
end
CC.InferenceParams(interp::ASTTypeAnnotator) = interp.inf_params
CC.OptimizationParams(interp::ASTTypeAnnotator) = interp.opt_params
CC.get_inference_world(interp::ASTTypeAnnotator) = interp.world
CC.get_inference_cache(interp::ASTTypeAnnotator) = interp.inf_cache
CC.cache_owner(::ASTTypeAnnotator) = ASTTypeAnnotatorToken()

# ASTTypeAnnotator is only used for type analysis, so it should disable optimization entirely
CC.may_optimize(::ASTTypeAnnotator) = false

# ASTTypeAnnotator doesn't need any sources to be cached, so discard them aggressively
CC.transform_result_for_cache(::ASTTypeAnnotator, ::CC.InferenceResult, ::Core.SimpleVector) = nothing

# `bail_out_toplevel_call(interp, sv::InferenceState) = sv.restrict_abstract_call_sites`
# is `true` for thunk MIs (`def isa Module`), and `abstract_call_gf_by_type` then
# refuses to infer any matching method whose `spec_types` isn't a `isdispatchtuple`
# — i.e. methods with free type vars like `(::Type{NamedTuple{names}})(::Tuple)`,
# whose result type would normally be `NamedTuple{names, Tuple{…}}`. Since we
# always run inference on chunk thunks built from user-source method bodies, that
# bail-out throws away precise types we'd otherwise have. Override to never bail.
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
    end
    return ret
end

# Type annotation driver
# ======================

"""
    get_inferrable_tree(
            st0::SyntaxTreeC, mod::Module; caller::AbstractString = "get_inferrable_tree"
        ) -> (; ctx3, st3) | nothing

Lower `st0` for scope resolution against `mod` and return the `(ctx3, st3)` pair that
[`infer_toplevel_tree`](@ref) consumes. Wraps `jl_lower_for_scope_resolution` with
error handling: returns `nothing` if lowering throws (typically because the user's
source contains parse errors or the macro context isn't yet ready).

`K"error"` nodes are stripped from `st0` before lowering.
JuliaSyntax doesn't bail on incomplete source — it builds a partial tree with `K"error"`
siblings around the well-formed parts — and JuliaLowering happily lowers what remains, so
the LSP gets meaningful types for the parts the user has finished typing (e.g. for
`function f(x::T); x.; end` the body's `x` reference still resolves to `T`).
"""
function get_inferrable_tree(
        st0::SyntaxTreeC, mod::Module;
        caller::AbstractString = "get_inferrable_tree"
    )
    (; ctx3, st3) = try
        jl_lower_for_scope_resolution(mod, st0; trim_error_nodes=true, recover_from_macro_errors=false)
    catch err
        JETLS_DEBUG_LOWERING && @warn "Error in lowering ($caller)" err
        JETLS_DEBUG_LOWERING && Base.show_backtrace(stderr, catch_backtrace())
        return nothing
    end
    return (; ctx3, st3)
end

"""
    infer_toplevel_tree(
            ctx3::JL.VariableAnalysisContext, st3::SyntaxTreeC, context_module::Module;
            world::UInt = Base.get_world_counter()
        ) -> inferred::SyntaxTreeC

Run type inference on a lowered toplevel expression and return the lowered syntax tree
(`inferred`) annotated with a `:type` attribute on each lowered statement.

`ctx3` and `st3` come from `JL.jl_lower_for_scope_resolution`, which runs JuliaLowering's
early scope-resolution passes — typically obtained via [`get_inferrable_tree`](@ref).
This function takes them through the remaining JuliaLowering passes, runs inference on
the result, and writes the inferred types back into the graph.

`world` (default: the current world) selects the inference world used throughout.

# Reading types from the result

Use [`get_type_for_range`](@ref) to look up the inferred type at a surface byte range.
Both top-level expressions and method bodies are annotated in the same returned tree,
so the same query handles either — no need to descend into method bodies separately.
For traversal-based use, types live on each annotated node as a `:type` attribute.

# Prerequisite: full-analysis must have run first

This LSP-feature path is intentionally separate from full-analysis, but it depends on
full-analysis having already populated `context_module`. Full analysis runs JET's concrete
interpretation against the user's source — which goes through Julia's own lowering
pipeline, *not* JuliaLowering — and materializes the user's bindings (functions, types,
constants, etc.) into the appropriate module. By the time an inlay-hint / hover /
completion request reaches this function, the caller has already chosen `context_module`
based on full-analysis results, and we run a lightweight pass on top: parse →
JuliaLowering → inference, just to produce the per-statement type annotations the LSP
feature needs.

The dependency is concrete, not advisory: the per-method-body argtypes resolution in the
"Design" section below works by `getfield`-ing user names out of `context_module` (see
step 2: evaluating `Core.Typeof(Main.f)`, `Core.apply_type(Main.Vector, Main.Int)`, …).
If full-analysis hasn't materialized those bindings, every user-defined name falls
through to `Any` and method bodies are inferred against `Any` argtypes. Argument type
instantiation simply isn't possible without the bindings being present.

# Design: every chunk is an "anonymous toplevel chunk"

The basic inference unit is a chunk: a `Core.CodeInfo` paired with a `SyntaxTreeC` whose
`[1]` is the block of statements to annotate, plus a list of slot argtypes. The toplevel
itself is such a chunk (nargs=0).

Method definitions are handled the same way — *not* by going through `Method` /
`MethodInstance` dispatch, but by treating each method's body `CodeInfo` as another
anonymous chunk:

1. We walk `inferred[1]` for `:method` 3-arg statements.
2. For each, we statically evaluate the argtypes svec referenced from `args[2]` against
   `context_module` (`eval_to_value` follows the SSA chain in `src.code`, resolving
   `Core.apply_type`, `Core.Typeof`, `GlobalRef`, etc.).
3. The resolved argtypes are fed to `infer_chunk!` together with the body `CodeInfo` and
   the corresponding `K"code_info"` subtree of `inferred`.

No `Method` lookup, no dispatch, no `Base._which` — body inference needs only what's
already in `inferred` and `src.code`, plus the caller's `context_module` for resolving
`GlobalRef`s in type expressions.

!!! note "Why we don't let `CC.typeinf` recurse into `:method` itself"
    The straightforward alternative would be to let inference of the toplevel chunk
    recurse into `:method` 3-arg statements via the usual dispatch path. That path
    doesn't reach `function f(...; kw...) end`: JuliaLowering introduces synthetic
    kwbody bindings (e.g. `var"#kw_body#f#0"`) whose names don't match the bindings
    full analysis materialized in `context_module` via Julia's own lowering. Going
    through dispatch would either fail or hit stale entries. Static svec evaluation
    avoids both; the synthetic-name slot simply degrades to `Any` (see Limitations).

# Limitations

The static-svec approach inherits a few precision losses around lowering's synthetic
binding constructs. None of these break correctness; they only degrade types to `Any`.

- **Closures.** `JL.convert_closures` hoists every closure to a toplevel `:method` 3-arg,
  so closure body inference itself works normally — local variables, parameter types, and
  the closure's return type are all annotated. But the closure is callable through a
  synthetic type (`var"#closure#N"`) that isn't `getfield`-resolvable in `context_module`.
  So:
  - The closure's self slot resolves to `Any`, which means **captured variables**
    (accessed via the self field) infer as `Any`.
  - From the **enclosing function's body**, calling the closure dispatches on this
    synthetic type, so the call site infers as `Any` and `Any`-typedness propagates
    outward (e.g. an accumulator that sums a closure's results becomes `Any`).

- **Parametric methods.** TypeVars constructed via `Core.TypeVar(:T, ub)` in the argtypes
  svec are flattened to their upper bound (`val.ub`) so the slot has a usable `Type`.
  Furthermore, the chunk's `MethodInstance` is a thunk MI (`def isa Module`); CC's
  `sptypes_from_meth_instance` forces `EMPTY_SPTYPES` for toplevel MIs, so an
  `Expr(:static_parameter, i)` reference inside the body cannot retrieve `T` and infers
  as `Any`.

- **Synthetic kwbody self.** Same shape as the closure self issue: in the kwbody method,
  slot 1 resolves to `Any` because the synthetic name isn't defined in `context_module`.
  User-named slots (`init`, `xs`, etc.) still resolve correctly via the svec, so the body
  code itself is inferred precisely.
"""
infer_toplevel_tree(args...; kwargs...) =
    (@something _infer_toplevel_tree(args...; kwargs...) return nothing).toptree

function _infer_toplevel_tree(
        ctx3::JL.VariableAnalysisContext, st3::SyntaxTreeC, context_module::Module;
        world::UInt = Base.get_world_counter()
    )
    inferred = try
        ctx4, st4 = JL.convert_closures(ctx3, st3)
        _, st5 = JL.linearize_ir(ctx4, st4)
        st5
    catch e
        @error "infer_toplevel_tree: Lowering failed" e
        return nothing
    end |> prepare_type_attr
    lwr = JL.to_lowered_expr(inferred)

    Meta.isexpr(lwr, :thunk) || error("infer_toplevel_tree: Unexpected lowering result")
    src = lwr.args[1]::CodeInfo

    interp = @something infer_chunk!(inferred, src, context_module, nothing, world) return nothing
    infer_method_defs!(inferred, src, context_module, world)
    return interp
end

prepare_type_attr(st::SyntaxTreeC) = let g = JL.syntax_graph(st)
    attrs = Dict(pairs(g.attributes))
    attrs[:type] = Dict{Int, Any}()
    return SyntaxTreeC(JL.SyntaxGraph(g.edge_ranges, g.edges, attrs), st._id)
end

# `argtypes === nothing` keeps the `InferenceResult`'s default argtypes (intended
# for nargs=0 thunks); a `Vector{Any}` overrides them with one entry per slot.
function infer_chunk!(
        tree::SyntaxTreeC, src::CodeInfo, context_module::Module,
        argtypes::Union{Nothing, Vector{Any}}, world::UInt
    )
    strip_latestworld!(src)
    mi = construct_toplevel_mi(src, context_module)
    interp = ASTTypeAnnotator(tree, mi; world)
    result = CC.InferenceResult(mi)
    if argtypes !== nothing
        # Thunk MIs have no `specTypes`-derived argtypes, so populate them
        # explicitly to match the chunk's slot count.
        empty!(result.argtypes)
        append!(result.argtypes, argtypes)
    end
    frame = try
        CC.InferenceState(result, src, #=cache=#:no, interp)
    catch err
        JETLS_DEV_MODE && @warn "infer_chunk!: InferenceState failed" err
        return nothing
    end
    CC.typeinf(interp, frame)
    return interp
end

# `Expr(:latestworld)` syncs the current task's `world_age` to the global world counter.
# JuliaLowering emits it after any binding-mutating op in the same chunk — `const`,
# `import`/`using`, method add, or the `Core.declare_global` that toplevel bare assignment
# expands to — so subsequent stmts can see those changes at runtime. CC mirrors this by
# flipping `currsaw_latestworld`, which makes `abstract_eval_globalref` widen every global
# (e.g. `Main.sin`) to `Any` — a guard against mid-inference binding mutation.
#
# In our snapshot-typing pass that guard has no subject: full-analysis has already
# materialized any binding changes the chunk produces into `context_module` at our fixed
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
        infer_chunk!(body_tree, body_codeinfo, context_module, argtypes, world)
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
    InferredTreeContext(inferred_tree::SyntaxTreeC) -> ctx::InferredTreeContext

Public type-query handle for a lowered, inferred syntax tree. Bundles
`inferred_tree` (the result of [`infer_toplevel_tree`](@ref)) with a set of
prebuilt indexes so that [`get_type_for_range`](@ref) (and friends) can answer
each query in O(1) — or O(log N) for the branching case — without re-walking
the tree per call.

# Lifecycle

The context is intended to be **built once per inferred tree** and reused
across many queries. Constructing it does a single `O(N)` traversal that
populates all indexes simultaneously. Typical usage:

- in `JETLS` itself: cache an `InferredTreeContext` alongside (or in place
  of) the inferred tree on the server's per-file state, rebuilding only when
  the tree is rebuilt;
- in tests / one-off callers: pass `inferred_tree` directly to the two-arg
  convenience overload `get_type_for_range(inferred_tree, rng)`, which builds
  a fresh context per call.

Consumers should normally just call [`get_type_for_range`](@ref) and treat
this type as opaque; the fields are implementation detail and may be
reorganized as new queries demand different indexes.
"""
struct InferredTreeContext
    inferred_tree::SyntaxTreeC
    # `byte_range => kind` for the surface node each lowered node was lowered
    # from (first element of `JS.flattened_provenance`). First-write-wins,
    # mirroring a `traverse`-then-pick-first lookup.
    surface_kind_index::Dict{UnitRange{UInt32}, JS.Kind}
    # Every lowered node keyed by its own `byte_range`, in preorder. The
    # preorder property is load-bearing for the "last `K"call"` wins"
    # semantics in `type_for_call`.
    by_byte_range::Dict{UnitRange{UInt32}, Vector{SyntaxTreeC}}
    # Typed `K"call"` nodes whose first provenance is a `K"macrocall"`, keyed
    # by the **macrocall's** `byte_range` (not the lowered call's own range —
    # string macros lower to a `K"call"` with a smaller span than the
    # macrocall, so we key by the surface span the user wrote).
    macrocall_typed_calls::Dict{UnitRange{UInt32}, Vector{SyntaxTreeC}}
    # Every `K"return"` node, in two parallel `Vector`s sorted by
    # `JS.first_byte` (so `searchsortedfirst` is valid on `return_first_bytes`).
    return_first_bytes::Vector{UInt32}
    return_nodes::Vector{SyntaxTreeC}
end

function InferredTreeContext(inferred_tree::SyntaxTreeC)
    surface_kind_index = Dict{UnitRange{UInt32}, JS.Kind}()
    by_byte_range = Dict{UnitRange{UInt32}, Vector{SyntaxTreeC}}()
    macrocall_typed_calls = Dict{UnitRange{UInt32}, Vector{SyntaxTreeC}}()
    return_first_bytes = UInt32[]
    return_nodes = SyntaxTreeC[]

    traverse(inferred_tree) do st::SyntaxTreeC
        rng = JS.byte_range(st)
        push!(get!(Vector{SyntaxTreeC}, by_byte_range, rng), st)

        provs = JS.flattened_provenance(st)
        if !isempty(provs)
            fprov = first(provs)
            fprov_rng = JS.byte_range(fprov)
            haskey(surface_kind_index, fprov_rng) ||
                (surface_kind_index[fprov_rng] = JS.kind(fprov))

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

    return InferredTreeContext(
        inferred_tree, surface_kind_index, by_byte_range,
        macrocall_typed_calls, return_first_bytes, return_nodes)
end

"""
    get_type_for_range(ctx::InferredTreeContext, rng::UnitRange{<:Integer})
    get_type_for_range(inferred_tree::SyntaxTreeC, rng::UnitRange{<:Integer})

Look up the inferred type at surface byte range `rng`.
Returns `nothing` if no lowered node corresponding to `rng` carries a `:type` attribute.

The first form is the production entry point: pass an [`InferredTreeContext`](@ref) so the
per-tree O(N) index build is amortized across all queries against the same inferred tree.
The second form is a convenience that constructs a fresh context per call — meant for tests
and one-off use, **not** for batch queries against a single tree (you'd rebuild the indexes
for every `rng`).

# Dispatch

Lowering routinely places multiple SSA-position nodes at the same surface byte
range, so a naive `tmerge` of all matches would pull in synthetic helper types
that the user never wrote. The dispatch picks a strategy based on the surface
node's kind (recovered from `ctx.surface_kind_index`):

- `K"call"` / `K"dotcall"` — returns the **last** `K"call"` lowered node at
  `rng`. For `f(; kw=v)` kwcalls, the kwargs `NamedTuple` constructor and
  `Core.tuple` builder sit at the same byte range as separate `K"call"`s, but
  the user's call is emitted last, so this picks the user-visible result
  without `Type{NamedTuple{…}}` or `Tuple{…}` chaff.
- `K"macrocall"` — returns the **last** `K"call"` whose first provenance is
  the macrocall at `rng`. That tail call carries the value type of the macro
  expansion, while every internal helper inside the expansion shares the
  macrocall's byte range but is not what the user means by the macrocall's
  value.
- `K"for"` / `K"while"` — always `Core.Const(nothing)`. Loop expressions
  evaluate to `nothing`; this avoids `tmerge`-ing the iteration machinery
  (`iterate` results, `=== nothing` checks, body return) that all share the
  loop's byte range.
- `K"function"` / `K"macro"` — returns the method body's `tmerge`d
  return-statement type (i.e. the value-type of `function f(…) … end`),
  looked up against the matching `K"method"` lowered node.
- `K"comparison"` / `K"&&"` / `K"||"` / `K"if"` — branching expressions whose
  value is the `tmerge` of each branch's value. Lowering emits a separate
  branch as either a contained `K"return"` (tail position) or a merge-slot
  `K"="` whose byte range matches `rng` (`r = a && b` etc.); both shapes get
  merged.
- otherwise — falls back to `tmerge` of every node at `rng`. Sufficient when
  there is only a single typed node, or when merging is genuinely the right
  answer (e.g. branches of a conditional).
"""
function get_type_for_range(ctx::InferredTreeContext, rng::UnitRange{<:Integer})
    surface_kind = surface_kind_at_range(ctx, rng)
    if surface_kind === JS.K"macrocall"
        return type_for_macroexpansion(ctx, rng)
    elseif surface_kind in JS.KSet"call dotcall"
        return type_for_call(ctx, rng)
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

get_type_for_range(inferred_tree::SyntaxTreeC, rng::UnitRange{<:Integer}) =
    get_type_for_range(InferredTreeContext(inferred_tree), rng)

surface_kind_at_range(ctx::InferredTreeContext, rng::UnitRange{<:Integer}) =
    get(ctx.surface_kind_index, rng, nothing)

function type_for_call(ctx::InferredTreeContext, rng::UnitRange{<:Integer})
    typ = nothing
    for st in get(ctx.by_byte_range, rng, ())
        JS.kind(st) === JS.K"call" || continue
        hasproperty(st, :type) || continue
        typ = st.type
    end
    return typ
end

function type_for_macroexpansion(ctx::InferredTreeContext, rng::UnitRange{<:Integer})
    typ = nothing
    for st5 in get(ctx.macrocall_typed_calls, rng, ())
        ntyp = st5.type
        ntyp isa Core.Const && continue
        typ = ntyp
    end
    return typ
end

# `K"comparison"` / `K"&&"` / `K"||"` / `K"if"` (ternary or block-form) all
# lower to branching code where each branch produces a candidate value. The
# lowered branches show up as either:
# - merge-slot assignments (`K"="` whose byte range equals the surface `rng`)
#   when the surface is in `K"="` RHS or any non-tail position; or
# - tail returns (`K"return"` whose byte range is contained in `rng`) when
#   the surface is in tail position of a function body.
# The expression's value type is the `tmerge` over all such branch values.
#
# A `K"return"` that spans exactly `rng` (synthesized when the branching
# expression is itself the function body) lives in both `by_byte_range[rng]`
# and the K"return" containment scan, so the explicit `continue` below skips
# it in the second scan to avoid double-counting.
function type_for_branching(ctx::InferredTreeContext, rng::UnitRange{<:Integer})
    typ = nothing
    # (1) equality match — any lowered kind, including merge-slot `K"="`.
    for st in get(ctx.by_byte_range, rng, ())
        hasproperty(st, :type) || continue
        ntyp = st.type
        typ = typ === nothing ? ntyp : CC.tmerge(ntyp, typ)
    end
    # (2) containment match — tail-position `K"return"` strictly inside `rng`.
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
        hasproperty(st, :type) || continue
        ntyp = st.type
        typ = typ === nothing ? ntyp : CC.tmerge(ntyp, typ)
    end
    return typ
end

function type_for_funcdef(ctx::InferredTreeContext, rng::UnitRange{<:Integer})
    typ = nothing
    for st in get(ctx.by_byte_range, rng, ())
        JS.kind(st) === JS.K"method" || continue
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
    typ = nothing
    for st in get(ctx.by_byte_range, rng, ())
        hasproperty(st, :type) || continue
        ntyp = st.type
        typ = typ === nothing ? ntyp : CC.tmerge(ntyp, typ)
    end
    return typ
end

end # module TypeAnnotation
