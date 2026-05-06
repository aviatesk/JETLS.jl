module Closure2Opaque

using ..JETLS: JL, JS, SyntaxTreeC

export rewrite_local_closures_to_opaque

"""
    rewrite_local_closures_to_opaque(
            ctx::JL.VariableAnalysisContext, ex::SyntaxTreeC
        ) -> SyntaxTreeC

Pre-lowering rewrite that turns single-method local closure definitions
(`K"function_decl"` paired with a sibling `K"method_defs"`) into the equivalent
`K"_opaque_closure"` form, so that `JL.convert_closures` routes them through its
native `OpaqueClosure` path instead of synthesizing a struct type.

This is intended for stateless static-analysis consumption: an `OpaqueClosure` is enough to
get precise body and call-site inference without `Core.eval`'ing the synthetic closure type
into inference context module (which the regular conversion would require).

# Limitations

- Multi-method bindings (a single name with multiple `K"method_defs"` anywhere in `ex`)
  can't be represented as a single OC, so they fall through to the regular synthetic-struct
  path. A whole-tree pre-pass (`collect_multi_method_bindings`) identifies these so the
  per-block rewrite can skip every method definition for such bindings.
- Bodies whose `K"method_defs"` shape doesn't match the expected
  `(block (block (= sig_ssa svec_call) (method ...) (removable ...)))`
  template (e.g. generated functions) are likewise left untouched.

# Usage

Designed to be called by `TypeAnnotation.infer_toplevel_tree` against a `K"toplevel"` /
`K"block"` `SyntaxTreeC` produced by `JL.resolve_scopes`, before `JL.convert_closures` runs.
The rewrite is non-destructive: nodes that don't match are returned unchanged, so the
pipeline downstream sees an equivalent tree with only the eligible closures swapped.
"""
function rewrite_local_closures_to_opaque(ctx::JL.VariableAnalysisContext, ex::SyntaxTreeC)
    multis = collect_multi_method_bindings(ex)
    return _rewrite_local_closures_to_opaque(ctx, ex, multis)
end

function _rewrite_local_closures_to_opaque(ctx::JL.VariableAnalysisContext, ex::SyntaxTreeC, multis::Set{Int})
    if JS.kind(ex) === JS.K"block"
        return rewrite_closure_block(ctx, ex, multis)
    end
    return JS.mapchildren(c::SyntaxTreeC -> _rewrite_local_closures_to_opaque(ctx, c, multis), ctx, ex)
end

function rewrite_closure_block(
        ctx::JL.VariableAnalysisContext, blk::SyntaxTreeC, multis::Set{Int}
    )
    children_old = JS.children(blk)
    n = length(children_old)
    new_children = JS.SyntaxList(JS.syntax_graph(ctx))
    consumed = falses(n)
    any_changed = false
    for i = 1:n
        consumed[i] && continue
        child = children_old[i]
        if JS.kind(child) === JS.K"function_decl" && is_local_closure_decl(ctx, child)
            func_name = child[1]
            md_idx = find_matching_method_defs(children_old, i, func_name.var_id, consumed)
            if md_idx !== nothing && !(func_name.var_id in multis)
                method_defs = children_old[md_idx]
                oc = try_build_oc_assignment(ctx, child, method_defs)
                if oc !== nothing
                    push!(new_children, _rewrite_local_closures_to_opaque(ctx, oc, multis))
                    consumed[md_idx] = true
                    any_changed = true
                    continue
                end
            end
        end
        push!(new_children, _rewrite_local_closures_to_opaque(ctx, child, multis))
    end
    any_changed || return JS.mapchildren(c::SyntaxTreeC -> _rewrite_local_closures_to_opaque(ctx, c, multis), ctx, blk)
    return JL.@ast ctx blk [JS.K"block" new_children...]
end

# Collect `var_id`s that have more than one `K"method_defs"` anywhere in `ex`.
# JL wraps each method definition in its own inner block, so `rewrite_closure_block`'s
# sibling-only view can't tell a single-method binding apart from one method of a
# multi-method binding. A whole-tree pre-pass disambiguates them. We track only the
# "seen at least once" / "seen at least twice" distinction (no need for full counts).
function collect_multi_method_bindings(ex::SyntaxTreeC)
    seen = Set{Int}()
    multis = Set{Int}()
    stack = SyntaxTreeC[ex]
    while !isempty(stack)
        node = pop!(stack)
        if JS.kind(node) === JS.K"method_defs" && JS.numchildren(node) >= 1 &&
                JS.kind(node[1]) === JS.K"BindingId"
            vid = node[1].var_id
            if vid in seen
                push!(multis, vid) # idempotent if already known multi
            else
                push!(seen, vid)
            end
        end
        if !JS.is_leaf(node)
            for c in JS.children(node)
                push!(stack, c)
            end
        end
    end
    return multis
end

function is_local_closure_decl(ctx::JL.VariableAnalysisContext, fd::SyntaxTreeC)
    JS.numchildren(fd) >= 1 || return false
    func_name = fd[1]
    return JS.kind(func_name) === JS.K"BindingId" &&
        haskey(ctx.closure_bindings, func_name.var_id)
end

function find_matching_method_defs(
        children_old, fd_idx::Int, target_var_id::Int, consumed::BitVector
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
    return JS.kind(c) === JS.K"method_defs" && JS.numchildren(c) >= 2 &&
        JS.kind(c[1]) === JS.K"BindingId" && c[1].var_id == target_var_id
end

# `method_defs[2]` is shaped like
#   (block (block (= sig_ssa (call core.svec inner_argtypes_svec sparams_svec functionloc))
#                 (method func_name sig_ssa lambda)
#                 (removable sig_ssa)))
# Returns `nothing` if the structure doesn't match (e.g. generated functions).
function try_build_oc_assignment(
        ctx::JL.VariableAnalysisContext, fd::SyntaxTreeC, method_defs::SyntaxTreeC
    )
    func_name = fd[1]
    method_node, sig_call = find_method_and_sig_call(method_defs[2], func_name.var_id)
    method_node === nothing && return nothing
    sig_call === nothing && return nothing
    JS.numchildren(sig_call) >= 4 || return nothing
    inner_argtypes = sig_call[2]
    functionloc = sig_call[4]
    JS.kind(inner_argtypes) === JS.K"call" || return nothing
    # `core.svec` callee + at least the function-type arg
    JS.numchildren(inner_argtypes) >= 2 || return nothing

    # The inner argtypes svec is `core.svec(function_type, user_arg_types...)`.
    # Skip the `core.svec` callee (idx 1) and the function-type marker (idx 2);
    # the rest are the user-visible argtypes.
    user_argtypes = JS.SyntaxList(JS.syntax_graph(ctx))
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

function find_method_and_sig_call(root::SyntaxTreeC, target_var_id::Int)
    method_node = sig_call = nothing
    stack = SyntaxTreeC[root]
    while !isempty(stack)
        method_node === nothing || sig_call === nothing || break
        node = pop!(stack)
        if JS.kind(node) === JS.K"method" && JS.numchildren(node) == 3 &&
                JS.kind(node[1]) === JS.K"BindingId" && node[1].var_id == target_var_id
            method_node = node
        elseif JS.kind(node) === JS.K"=" && JS.numchildren(node) == 2 &&
                JS.kind(node[1]) === JS.K"BindingId" &&
                JS.kind(node[2]) === JS.K"call" && is_core_svec_call(node[2])
            sig_call = node[2]
        end
        if !JS.is_leaf(node)
            for c in JS.children(node)
                push!(stack, c)
            end
        end
    end
    return (method_node, sig_call)
end

function is_core_svec_call(call_node::SyntaxTreeC)
    JS.numchildren(call_node) >= 1 || return false
    callee = call_node[1]
    return JS.kind(callee) === JS.K"core" && JS.hasattr(callee, :name_val) &&
        callee.name_val == "svec"
end

# Detect a vararg-typed entry in the user-argtypes svec. JL lowers both `(xs...)`
# and `(xs::T...)` to `(call core.apply_type core.Vararg <type-arg>)`.
function argtype_is_vararg(t::SyntaxTreeC)
    JS.kind(t) === JS.K"call" && JS.numchildren(t) >= 2 || return false
    callee = t[1]
    JS.kind(callee) === JS.K"core" && JS.hasattr(callee, :name_val) &&
        callee.name_val == "apply_type" || return false
    inner = t[2]
    return JS.kind(inner) === JS.K"core" && JS.hasattr(inner, :name_val) &&
        inner.name_val == "Vararg"
end

end # module Closure2Opaque
