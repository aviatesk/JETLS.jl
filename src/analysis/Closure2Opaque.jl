module Closure2Opaque

using ..JETLS: JL, JS, SyntaxTreeC, get_name_val, var_id

export rewrite_local_closures_to_opaque

"""
    rewrite_local_closures_to_opaque(
            ctx::JL.VariableAnalysisContext, st3::SyntaxTreeC
        ) -> SyntaxTreeC

Pre-lowering rewrite that turns single-method local closure definitions
(`K"function_decl"` paired with a sibling `K"method_defs"`) into the equivalent
`K"_opaque_closure"` form, so that `JL.convert_closures` routes them through its
native `OpaqueClosure` path instead of synthesizing a struct type.

This is intended for stateless static-analysis consumption: an `OpaqueClosure` is enough to
get precise body and call-site inference without `Core.eval`'ing the synthetic closure type
into inference context module (which the regular conversion would require).

# Limitations

- Local closures with multiple `K"method"` nodes for one `ClosureKey` can't be
  represented as a single OC, so they fall through to the regular synthetic-struct
  path. A whole-tree pre-pass (`collect_multi_method_bindings`) counts methods per
  key so the per-block rewrite can skip every definition of that closure.
- Bodies whose `K"method_defs"` shape doesn't contain exactly one method, or whose
  method declares its own static parameters (e.g. generated or generic local methods),
  are likewise left untouched.

# Usage

Designed to be called by `TypeAnnotation.infer_toplevel_tree` against the `K"lambda"`
root produced by `JL.resolve_scopes` (its `lambda_bindings` seeds the enclosing-lambda
tracking), before `JL.convert_closures` runs.
The rewrite is non-destructive: nodes that don't match are returned unchanged, so the
pipeline downstream sees an equivalent tree with only the eligible closures swapped.
"""
function rewrite_local_closures_to_opaque(ctx::JL.VariableAnalysisContext, st3::SyntaxTreeC)
    lambda_scope_id = JL.lambda_bindings(st3[1]).scope_id
    multis = collect_multi_method_bindings(ctx, st3, lambda_scope_id)
    return _rewrite_local_closures_to_opaque(ctx, st3, multis, lambda_scope_id)
end

function _rewrite_local_closures_to_opaque(
        ctx::JL.VariableAnalysisContext, st3::SyntaxTreeC,
        multis::Set{JL.ClosureKey}, lambda_scope_id::Int
    )
    k = JS.kind(st3)
    if k === JS.K"block"
        return rewrite_closure_block(ctx, st3, multis, lambda_scope_id)
    elseif k === JS.K"lambda"
        lambda_scope_id = JL.lambda_bindings(st3[1]).scope_id
    end
    let lambda_scope_id=lambda_scope_id
        return JS.mapchildren(st3) do c::SyntaxTreeC
            _rewrite_local_closures_to_opaque(ctx, c, multis, lambda_scope_id)
        end
    end
end

function rewrite_closure_block(
        ctx::JL.VariableAnalysisContext, blk3::SyntaxTreeC,
        multis::Set{JL.ClosureKey}, lambda_scope_id::Int
    )
    children_old = JS.children(blk3)
    n = length(children_old)
    new_children = JS.SyntaxList()
    consumed = falses(n)
    for i = 1:n
        consumed[i] && continue
        child = children_old[i]
        func_key = JS.kind(child) === JS.K"function_decl" ?
            local_closure_key(ctx, child, lambda_scope_id) : nothing
        if func_key !== nothing
            md_idx = find_matching_method_defs(
                children_old, i, func_key.binding, consumed)
            if md_idx !== nothing && func_key ∉ multis
                method_defs = children_old[md_idx]
                oc = try_build_oc_assignment(ctx, child, method_defs)
                if oc !== nothing
                    push!(new_children,
                        _rewrite_local_closures_to_opaque(ctx, oc, multis, lambda_scope_id))
                    consumed[md_idx] = true
                    continue
                end
            end
        end
        push!(new_children,
            _rewrite_local_closures_to_opaque(ctx, child, multis, lambda_scope_id))
    end
    return JL.@ast ctx blk3 [JS.K"block" new_children...]
end

# Collect closure keys that resolve to more than one method, plus any helper
# closures reachable from multi-method *closure* wrappers.
#
# Multi-method detection counts `K"method"` nodes per `ClosureKey` across the
# whole tree. JL has two ways to express multi-method bindings — multiple sibling
# `K"method_defs"` (e.g. kwarg wrappers, `f(::T1)` + `f(::T2)`) or a single
# `K"method_defs"` packing multiple methods (e.g. default-positional-arg) — and
# both reduce to the same `K"method"` count once flattened. The enclosing lambda
# in `ClosureKey` prevents definitions of the same binding in nested lambdas from
# bleeding into each other's counts.
#
# The reachability propagation handles kwarg closures: JL splits `f = (x; kw=1) -> ...`
# into a multi-method wrapper `f` (positional dispatch + kwsorter) plus a single-method
# inner body helper that the wrapper's methods call. Rewriting the helper alone to an
# OC breaks the wrapper's later synthetic-struct lowering (the wrapper's `function_type`
# reference can no longer find the helper). Tagging any closure binding called from a
# multi-method wrapper's bodies forces the helper through the same path as its wrapper.
#
# Propagation seeds are restricted to closure bindings: a multi-method *global* (e.g. a
# top-level function with default positional args or kwargs) never goes through
# synthetic-struct closure conversion, so single-method closures inside its bodies are
# still safely rewritable to OCs and must not be tagged.
function collect_multi_method_bindings(
        ctx::JL.VariableAnalysisContext, st3::SyntaxTreeC, root_scope_id::Int
    )
    method_defs_by_key = Dict{JL.ClosureKey,Vector{SyntaxTreeC}}()
    methods_per_key = Dict{JL.ClosureKey,Int}()
    multis = Set{JL.ClosureKey}()
    stack = Tuple{SyntaxTreeC,Int}[(st3, root_scope_id)]
    while !isempty(stack)
        node, lambda_scope_id = pop!(stack)
        k = JS.kind(node)
        if k === JS.K"lambda"
            lambda_scope_id = JL.lambda_bindings(node[1]).scope_id
        elseif ((k === JS.K"method" || k === JS.K"method_defs") &&
                JS.numchildren(node) >= 1 && JS.kind(node[1]) === JS.K"BindingId")
            key = JL.ClosureKey(var_id(node[1]), lambda_scope_id)
            if k === JS.K"method"
                n = (methods_per_key[key] = get(methods_per_key, key, 0) + 1)
                n == 2 && push!(multis, key)
            else
                push!(get!(() -> SyntaxTreeC[], method_defs_by_key, key), node)
            end
        end
        if !JS.is_leaf(node)
            for c in JS.children(node)
                push!(stack, (c, lambda_scope_id))
            end
        end
    end
    worklist = JL.ClosureKey[key for key in multis if haskey(ctx.closure_bindings, key)]
    candidate_bids = Set{Int}(key.binding for key in keys(method_defs_by_key))
    while !isempty(worklist)
        key = pop!(worklist)
        for md in method_defs_by_key[key]
            collect_referenced_closures!(
                ctx, md, key.lam, multis, worklist, method_defs_by_key, candidate_bids)
        end
    end
    return multis
end

function collect_referenced_closures!(
        ctx::JL.VariableAnalysisContext, root::SyntaxTreeC, lambda_scope_id::Int,
        multis::Set{JL.ClosureKey}, worklist::Vector{JL.ClosureKey},
        method_defs_by_key::Dict{JL.ClosureKey,Vector{SyntaxTreeC}},
        candidate_bids::Set{Int}
    )
    stack = Tuple{SyntaxTreeC,Int}[(c, lambda_scope_id) for c in JS.children(root)]
    while !isempty(stack)
        node, lambda_scope_id = pop!(stack)
        k = JS.kind(node)
        if k === JS.K"function_decl" || k === JS.K"method_defs"
            # Nested definitions need no descent: their sibling `[local]`/`[removable]`
            # BindingId occurrences tag them, and tagged ones are walked via the worklist.
            continue
        elseif k === JS.K"lambda"
            lambda_scope_id = JL.lambda_bindings(node[1]).scope_id
        elseif k === JS.K"BindingId" && var_id(node) in candidate_bids
            key = find_enclosing_closure_key(ctx, var_id(node), lambda_scope_id)
            if key !== nothing && key ∉ multis && haskey(method_defs_by_key, key)
                push!(multis, key)
                push!(worklist, key)
            end
        end
        if !JS.is_leaf(node)
            for c in JS.children(node)
                push!(stack, (c, lambda_scope_id))
            end
        end
    end
    return nothing
end

function find_enclosing_closure_key(
        ctx::JL.VariableAnalysisContext, binding_id::Int, lambda_scope_id::Int
    )
    while true
        key = JL.ClosureKey(binding_id, lambda_scope_id)
        haskey(ctx.closure_bindings, key) && return key
        parent = @something JL.parent(ctx, ctx.scopes[lambda_scope_id]) return nothing
        lambda_scope_id = JL.enclosing_lambda(ctx, parent).id
    end
end

# Returns the `ClosureKey` for a `function_decl` of a local closure, `nothing` otherwise.
function local_closure_key(
        ctx::JL.VariableAnalysisContext, fd::SyntaxTreeC, lambda_scope_id::Int
    )
    JS.numchildren(fd) >= 1 || return nothing
    func_name = fd[1]
    JS.kind(func_name) === JS.K"BindingId" || return nothing
    key = JL.ClosureKey(var_id(func_name), lambda_scope_id)
    return haskey(ctx.closure_bindings, key) ? key : nothing
end

function find_matching_method_defs(
        children_old::JL.SyntaxList, fd_idx::Int, target_var_id::Int, consumed::BitVector
    )
    # Search both directions; method_defs may appear before or after function_decl.
    for j = fd_idx+1:length(children_old)
        consumed[j] && continue
        if is_method_defs_for(children_old[j], target_var_id)
            return j
        end
    end
    for j = 1:fd_idx-1
        consumed[j] && continue
        if is_method_defs_for(children_old[j], target_var_id)
            return j
        end
    end
    return nothing
end

function is_method_defs_for(c::SyntaxTreeC, target_var_id::Int)
    return JS.kind(c) === JS.K"method_defs" && JS.numchildren(c) == 3 &&
        JS.kind(c[1]) === JS.K"BindingId" && var_id(c[1]) == target_var_id
end

# `method_defs` is shaped like
#   (method_defs func_name (block typevar_setup...)
#     (block (block (method func_name inner_argtypes_svec lambda))))
# Returns `nothing` for non-single-method scaffolding and methods with their own
# static parameters.
function try_build_oc_assignment(
        ctx::JL.VariableAnalysisContext, fd::SyntaxTreeC, method_defs::SyntaxTreeC
    )
    func_name = fd[1]
    typevars = method_defs[2]
    JS.kind(typevars) === JS.K"block" || return nothing
    JS.numchildren(typevars) == 0 || return nothing

    method_node = @something find_single_method_node(
        method_defs[3], var_id(func_name)) return nothing
    inner_argtypes = method_node[2]
    JS.kind(inner_argtypes) === JS.K"call" || return nothing
    # `core.svec` callee + at least the function-type arg
    JS.numchildren(inner_argtypes) >= 2 || return nothing
    callee = inner_argtypes[1]
    JS.kind(callee) === JS.K"core" && get_name_val(callee) == "svec" || return nothing
    functionloc = JL.@ast ctx method_node (::JS.K"SourceLocation")

    # The inner argtypes svec is `core.svec(function_type, user_arg_types...)`.
    # Skip the `core.svec` callee (idx 1) and the function-type marker (idx 2);
    # the rest are the user-visible argtypes.
    user_argtypes = JS.SyntaxList()
    for i = 3:JS.numchildren(inner_argtypes)
        push!(user_argtypes, inner_argtypes[i])
    end
    nargs = length(user_argtypes)
    isva = nargs > 0 && argtype_is_vararg(user_argtypes[end])

    lambda = method_node[3]
    JS.kind(lambda) === JS.K"lambda" || return nothing

    argt = JL.@ast ctx method_defs [JS.K"call"
        "apply_type"::JS.K"core"
        "Tuple"::JS.K"core"
        user_argtypes...
    ]
    rt_lb = JL.@ast ctx method_defs [JS.K"call" "apply_type"::JS.K"core" "Union"::JS.K"core"]
    rt_ub = JL.@ast ctx method_defs "Any"::JS.K"core"

    # `K"_opaque_closure"` children:
    # `(binding, argt, rt_lb, rt_ub, allow_partial, nargs, isva, functionloc, lambda)`.
    # `allow_partial = true` matches what `Base.Experimental.@opaque` emits — it tells
    # `abstract_eval_new_opaque_closure` to keep the `PartialOpaque` lattice element rather
    # than widening it to `OpaqueClosure{argt, T} where T`.
    # PartialOpaque carries the body's `Method` and env, and our entire OC routing depends
    # on call sites being able to reach the body source through it.
    oc = JL.@ast ctx method_defs [JS.K"_opaque_closure"
        func_name
        argt
        rt_lb
        rt_ub
        true::JS.K"Bool" # allow_partial
        nargs::JS.K"Integer"
        isva::JS.K"Bool"
        functionloc
        lambda
    ]
    return JL.@ast ctx method_defs [JS.K"=" func_name oc]
end

function find_single_method_node(root::SyntaxTreeC, target_var_id::Int)
    node = root
    while JS.kind(node) === JS.K"block" && JS.numchildren(node) == 1
        node = node[1]
    end
    if (JS.kind(node) === JS.K"method" && JS.numchildren(node) == 3 &&
        JS.kind(node[1]) === JS.K"BindingId" && var_id(node[1]) == target_var_id)
        return node
    end
    return nothing
end

# Detect a vararg-typed entry in the user-argtypes svec. JL lowers both `(xs...)`
# and `(xs::T...)` to `(call core.apply_type core.Vararg <type-arg>)`.
function argtype_is_vararg(t::SyntaxTreeC)
    JS.kind(t) === JS.K"call" && JS.numchildren(t) >= 2 || return false
    callee = t[1]
    JS.kind(callee) === JS.K"core" && get_name_val(callee) == "apply_type" || return false
    inner = t[2]
    return JS.kind(inner) === JS.K"core" && get_name_val(inner) == "Vararg"
end

end # module Closure2Opaque
