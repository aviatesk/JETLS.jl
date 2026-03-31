# CFG-based def-use analysis for scope-resolved syntax tree `st3`.
#
# This file implements two complementary analyses using a shared event-based CFG:
#
# 1. **Undef analysis**: determines whether local variables may be used before
#    being assigned.  The result is a three-valued status:
#    - `false`: definitely defined at all uses
#    - `true`: definitely undefined at some use
#    - `nothing`: may or may not be defined (conservative)
#
# 2. **Dead store (unused assignment) analysis**: determines whether specific
#    assignments to local variables are never read.  This is the dual of undef:
#    - undef:      entry ──(no def)──▶ use?      → undef
#    - dead store: def_i ──(no other def)──▶ use? → unreachable ⟹ dead store
#
# The key technique is placing each assignment/use event in its own "event block"
# (not traditional basic blocks - each block contains at most one event).
# Event ordering is thus represented by CFG edges, allowing us to check
# reachability as a graph problem.

"""
    UndefInfo

Information about a local variable's definition/use sites and undef status.

Fields:
- `defs::Vector{JS.SyntaxTree}`: Definition sites (assignments, function declarations)
- `undef_uses::Vector{Pair{Bool,JS.SyntaxTree}}`: Use sites on undef paths.
  Each entry is `is_strict => use_tree`:
  - `true => tree`: Variable is definitely undefined at `tree`
  - `false => tree`: Variable may be undefined at `tree`
"""
struct UndefInfo
    defs::Vector{JS.SyntaxTree}
    undef_uses::Vector{Pair{Bool,JS.SyntaxTree}}
end

UndefInfo() = UndefInfo(JS.SyntaxTree[], Pair{Bool,JS.SyntaxTree}[])

"""
    DeadStoreInfo

Information about dead store assignments for a local variable.

Fields:
- `dead_defs::Vector{JS.SyntaxTree}`: Assignment sites whose values are
  never read on any CFG path (dead stores).
"""
struct DeadStoreInfo
    dead_defs::Vector{JS.SyntaxTree}
end

mutable struct EventBlock
    const id::Int
    const succs::Vector{Int}
    # Event in this block (at most one per block due to emit creating new blocks)
    # event_kind: :assign, :use, or :isdefined (hint for CFG analysis, not a real def)
    event::Union{Nothing, Tuple{Symbol,JL.IdTag,JS.SyntaxTree}}
end

EventBlock(id::Int) = EventBlock(id, Int[], nothing)

mutable struct EventLinearizer
    const blocks::Vector{EventBlock}
    current_block::Int
    const label_to_block::Dict{Int,Int}
    const pending_gotos::Vector{Tuple{Int,Int}}  # (from_block, label_id)
    next_label::Int
    # Maps symbolic label names (e.g. "loop-exit", "loop-cont") to CFG label IDs
    # for handling `K"symbolicblock"` / `K"break"` pairs from lowered loops.
    const break_targets::Dict{String,Int}
    # Correlated condition analysis.  Maps a set of condition BindingId
    # var_ids to the set of variables definitely assigned in the true
    # branch.  Scoped via save/restore; invalidated on reassignment.
    # E.g. `if x` records Set([x]) → {y}, `if x && z` records Set([x,z]) → {y}.
    const cond_implies_defined::Dict{Set{JL.IdTag},Set{JL.IdTag}}
    # Stack of BindingId var_id sets for conditions whose true branch we are
    # currently inside.  Used by `undef_emit_cond_implied_hints!` so that
    # nested `if a; if b; ...` lookups see the combined condition Set([a,b]).
    const active_cond_vars::Vector{Set{JL.IdTag}}
    function EventLinearizer()
        blocks = EventBlock[EventBlock(1)]
        new(blocks, 1, Dict{Int,Int}(), Tuple{Int,Int}[], 0, Dict{String,Int}(),
            Dict{Set{JL.IdTag},Set{JL.IdTag}}(), Set{JL.IdTag}[])
    end
end

function undef_new_block!(lin::EventLinearizer)
    id = length(lin.blocks) + 1
    push!(lin.blocks, EventBlock(id))
    return id
end

function undef_switch_to_block!(lin::EventLinearizer, id::Int)
    lin.current_block = id
end

function undef_add_edge!(lin::EventLinearizer, from::Int, to::Int)
    if !(to in lin.blocks[from].succs)
        push!(lin.blocks[from].succs, to)
    end
end

function undef_emit_event!(lin::EventLinearizer, event_kind::Symbol, var_id::JL.IdTag, st::JS.SyntaxTree)
    lin.blocks[lin.current_block].event = (event_kind, var_id, st)
    # Create a new block to ensure proper ordering.
    # This allows the path-based analysis to track intra-block event order:
    # `x = 1; println(x)` becomes BB1(assign) → BB2(use), so the analysis
    # correctly detects that all paths to use go through assignment.
    next_block = undef_new_block!(lin)
    undef_add_edge!(lin, lin.current_block, next_block)
    undef_switch_to_block!(lin, next_block)
end

function undef_make_label!(lin::EventLinearizer)
    return lin.next_label += 1
end

function undef_emit_label!(lin::EventLinearizer, label_id::Int)
    block_id = undef_new_block!(lin)
    lin.label_to_block[label_id] = block_id
    undef_add_edge!(lin, lin.current_block, block_id)
    undef_switch_to_block!(lin, block_id)
    return block_id
end

function undef_emit_goto!(lin::EventLinearizer, label_id::Int)
    push!(lin.pending_gotos, (lin.current_block, label_id))
    unreachable = undef_new_block!(lin)
    undef_switch_to_block!(lin, unreachable)
end

function undef_emit_gotoifnot!(lin::EventLinearizer, false_label::Int)
    true_block = undef_new_block!(lin)
    undef_add_edge!(lin, lin.current_block, true_block)
    push!(lin.pending_gotos, (lin.current_block, false_label))
    undef_switch_to_block!(lin, true_block)
end

function undef_finalize_cfg!(lin::EventLinearizer)
    for (from_block, label_id) in lin.pending_gotos
        if haskey(lin.label_to_block, label_id)
            to_block = lin.label_to_block[label_id]
            undef_add_edge!(lin, from_block, to_block)
        end
    end
end

# Save/restore for correlated condition implications.  Used to scope
# implications to the branch where they are recorded: implications
# created inside a conditional branch are discarded on exit, while
# invalidations (deletions due to condition-variable reassignment)
# are preserved across scopes.
function undef_save_cond_implied(lin::EventLinearizer)
    return copy(lin.cond_implies_defined)
end

function undef_restore_cond_implied!(
        lin::EventLinearizer, saved::Dict{Set{JL.IdTag},Set{JL.IdTag}};
        lift_with::Union{Nothing, Set{JL.IdTag}}=nothing
    )
    # Lift implications by combining with the outer condition.  Handles both
    # new keys (added during scope) and extended values (delta of existing keys).
    # E.g. if inside `if a`'s true branch we recorded Set([b]) → {y},
    # lift it to Set([a,b]) → {y} in the outer scope.
    lifted = Pair{Set{JL.IdTag}, Set{JL.IdTag}}[]
    if !isnothing(lift_with)
        for (key, implied) in lin.cond_implies_defined
            if !haskey(saved, key)
                push!(lifted, union(key, lift_with) => implied)
            else
                delta = setdiff(implied, saved[key])
                if !isempty(delta)
                    push!(lifted, union(key, lift_with) => delta)
                end
            end
        end
    end
    # Propagate invalidations: keys present in `saved` but deleted during
    # the scope must stay deleted after restore.
    for key in collect(keys(saved))
        haskey(lin.cond_implies_defined, key) || delete!(saved, key)
    end
    empty!(lin.cond_implies_defined)
    merge!(lin.cond_implies_defined, saved)
    for (lifted_key, implied) in lifted
        existing = get(lin.cond_implies_defined, lifted_key, nothing)
        lin.cond_implies_defined[lifted_key] =
            isnothing(existing) ? implied : union(existing, implied)
    end
end

# Walk the top-level operands of a condition expression, unwrapping
# EST `K"block"` wrappers and recursing through `&&` chains (all
# operands must be true in the true branch).
function for_each_cond_operand(callback, cond::JS.SyntaxTree)
    k = JS.kind(cond)
    if k == JS.K"block" && JS.numchildren(cond) == 1
        return for_each_cond_operand(callback, cond[1])
    elseif k == JS.K"&&"
        for child in JS.children(cond)
            for_each_cond_operand(callback, child)
        end
    else
        callback(cond)
    end
    return
end

# Emit `:isdefined` hints for `@isdefined(var)` in condition expressions.
function undef_emit_isdefined_hints!(
        lin::EventLinearizer, cond::JS.SyntaxTree, candidates::Set{JL.IdTag}
    )
    for_each_cond_operand(cond) do operand::JS.SyntaxTree
        JS.kind(operand) == JS.K"isdefined" || return
        JS.numchildren(operand) >= 1 || return
        arg = operand[1]
        if JS.kind(arg) == JS.K"BindingId"
            var_id = arg.var_id::JL.IdTag
            if var_id in candidates
                undef_emit_event!(lin, :isdefined, var_id, arg)
            end
        end
    end
end

# Collect all BindingId var_ids asserted true by a condition.
# Returns `true` if every operand is a BindingId (for recording),
# `false` otherwise (lookup still uses the collected ids).
function undef_cond_binding_ids!(result::Vector{JL.IdTag}, cond::JS.SyntaxTree)
    all_bindings = Ref(true)
    for_each_cond_operand(cond) do operand::JS.SyntaxTree
        if JS.kind(operand) == JS.K"BindingId"
            push!(result, operand.var_id::JL.IdTag)
        else
            all_bindings[] = false
        end
    end
    return all_bindings[]
end

# Extract the variable id from a direct definition node (`=` or `function_decl`).
# Returns `nothing` when the node is not a definition or the LHS is not a BindingId.
# This is the single source of truth for "what counts as a local variable definition"
# used by both event linearization and correlated condition recording.
function undef_direct_assign_var_id(node::JS.SyntaxTree)
    k = JS.kind(node)
    if (k == JS.K"=" || k == JS.K"function_decl") && JS.numchildren(node) >= 1
        lhs = node[1]
        if JS.kind(lhs) == JS.K"BindingId"
            return lhs.var_id::JL.IdTag
        end
    end
    return nothing
end

# Collect variables that are definitely assigned (direct top-level assignments)
# in a branch. Only considers assignments at the top level of `K"block"` nodes,
# not those nested inside conditionals/loops.
function undef_collect_branch_direct_assigns(
        branch::JS.SyntaxTree, candidates::Set{JL.IdTag}
    )
    result = Set{JL.IdTag}()
    undef_scan_direct_assigns!(result, branch, candidates)
    return result
end

function undef_scan_direct_assigns!(
        result::Set{JL.IdTag}, node::JS.SyntaxTree, candidates::Set{JL.IdTag}
    )
    var_id = undef_direct_assign_var_id(node)
    if !isnothing(var_id)
        if var_id in candidates
            push!(result, var_id)
        end
    elseif JS.kind(node) == JS.K"block"
        for child in JS.children(node)
            undef_scan_direct_assigns!(result, child, candidates)
        end
    end
    nothing
end

# Invalidate all condition implications that depend on a reassigned variable.
function undef_invalidate_cond_implies!(lin::EventLinearizer, var_id::JL.IdTag)
    isempty(lin.cond_implies_defined) && return
    for key in collect(keys(lin.cond_implies_defined))
        if var_id in key
            delete!(lin.cond_implies_defined, key)
        end
    end
end

# Emit `:isdefined` hints for variables implied by correlated conditions.
# Extracts all BindingId operands asserted true by the condition and checks
# if any recorded implication key is a subset.
function undef_emit_cond_implied_hints!(
        lin::EventLinearizer, cond::JS.SyntaxTree, candidates::Set{JL.IdTag}
    )
    isempty(lin.cond_implies_defined) && return
    cond_vars = JL.IdTag[]
    undef_cond_binding_ids!(cond_vars, cond)
    # Include enclosing conditions from the active stack so that
    # nested `if a; if b; ...` sees the combined Set([a,b]).
    for active_key in lin.active_cond_vars
        union!(cond_vars, active_key)
    end
    isempty(cond_vars) && return
    cond_key = Set{JL.IdTag}(cond_vars)
    for (key, implied) in lin.cond_implies_defined
        key ⊆ cond_key || continue
        for var_id in implied
            if var_id in candidates
                undef_emit_event!(lin, :isdefined, var_id, cond)
            end
        end
    end
end

# Record which variables are definitely assigned in the true branch of a condition.
# Both `if x` (key = Set([x])) and `if x && z` (key = Set([x,z])) are handled uniformly.
function undef_record_cond_implies!(
        lin::EventLinearizer, cond_key::Union{Nothing, Set{JL.IdTag}},
        direct_assigns::Set{JL.IdTag}
    )
    isnothing(cond_key) && return
    isempty(direct_assigns) && return
    existing = get(lin.cond_implies_defined, cond_key, nothing)
    lin.cond_implies_defined[cond_key] =
        isnothing(existing) ? direct_assigns : union(existing, direct_assigns)
end

function linearize_def_use_events!(
        lin::EventLinearizer, ctx3::JL.VariableAnalysisContext, ex3::JS.SyntaxTree,
        candidates::Set{JL.IdTag}, allow_throw_optimization::Bool
    )
    k = JS.kind(ex3)

    if k == JS.K"BindingId"
        var_id = ex3.var_id::JL.IdTag
        if var_id in candidates
            undef_emit_event!(lin, :use, var_id, ex3)
        end

    elseif k == JS.K"symbolicblock"
        label_node = ex3[1]
        label_name = label_node.name_val::String
        exit_label = undef_make_label!(lin)
        # Save and set the break target for this label (handles nesting)
        outer_target = get(lin.break_targets, label_name, nothing)
        lin.break_targets[label_name] = exit_label
        if JS.numchildren(ex3) >= 2
            linearize_def_use_events!(lin, ctx3, ex3[2], candidates, allow_throw_optimization)
        end
        if isnothing(outer_target)
            delete!(lin.break_targets, label_name)
        else
            lin.break_targets[label_name] = outer_target
        end
        undef_emit_label!(lin, exit_label)

    elseif k == JS.K"break"
        # Process value child if present (break label value)
        if JS.numchildren(ex3) >= 2
            linearize_def_use_events!(lin, ctx3, ex3[2], candidates, allow_throw_optimization)
        end
        # Emit goto to matching symbolicblock exit if label is known
        if JS.numchildren(ex3) >= 1 && JS.kind(ex3[1]) == JS.K"symboliclabel"
            label_name = ex3[1].name_val::String
            target_label = get(lin.break_targets, label_name, nothing)
            if !isnothing(target_label)
                undef_emit_goto!(lin, target_label)
                return
            end
        end
        unreachable = undef_new_block!(lin)
        undef_switch_to_block!(lin, unreachable)

    elseif JS.is_leaf(ex3) || JL.is_quoted(ex3)
        # Nothing to do

    elseif k == JS.K"="
        # Process RHS first
        linearize_def_use_events!(lin, ctx3, ex3[2], candidates, allow_throw_optimization)
        # Then record assignment
        lhs = ex3[1]
        if JS.kind(lhs) == JS.K"BindingId"
            var_id = lhs.var_id::JL.IdTag
            if var_id in candidates
                undef_emit_event!(lin, :assign, var_id, lhs)
            end
            undef_invalidate_cond_implies!(lin, var_id)
        end

    elseif k == JS.K"function_decl"
        # Process the RHS first (method_defs)
        for i in 2:JS.numchildren(ex3)
            linearize_def_use_events!(lin, ctx3, ex3[i], candidates, allow_throw_optimization)
        end
        # Then emit the assign event for the function name
        lhs = ex3[1]
        if JS.kind(lhs) == JS.K"BindingId"
            var_id = lhs.var_id::JL.IdTag
            if var_id in candidates
                undef_emit_event!(lin, :assign, var_id, lhs)
            end
            undef_invalidate_cond_implies!(lin, var_id)
        end

    elseif k == JS.K"isdefined"
        # @isdefined(var) checks if var is defined but doesn't actually use it
        # (won't cause UndefVarError), so don't emit use event for the BindingId inside

    elseif k == JS.K"lambda"
        # Handle captured variables from outer scope by recursing into lambda body
        # We don't know when/if the closure is called, so wrap in an uncertain branch
        nested_lb = ex3.lambda_bindings::JL.LambdaBindings
        has_outer_capture = any(is_capt && id in candidates for (id, is_capt) in nested_lb.locals_capt)
        if has_outer_capture && JS.numchildren(ex3) >= 3
            skip_label = undef_make_label!(lin)
            undef_emit_gotoifnot!(lin, skip_label)
            let saved = undef_save_cond_implied(lin)
                linearize_def_use_events!(lin, ctx3, ex3[3], candidates, allow_throw_optimization)
                undef_restore_cond_implied!(lin, saved)
            end
            undef_emit_label!(lin, skip_label)
        end

    elseif k == JS.K"local"
        # local declarations don't use or assign

    elseif k == JS.K"decl"
        # decl nodes: the BindingId is declaration, not use; only visit type expression
        if JS.numchildren(ex3) >= 2
            linearize_def_use_events!(lin, ctx3, ex3[2], candidates, allow_throw_optimization)
        end

    elseif k == JS.K"if" || k == JS.K"elseif"
        # if cond then_branch [else_branch]
        cond = ex3[1]
        linearize_def_use_events!(lin, ctx3, cond, candidates, allow_throw_optimization)

        end_label = undef_make_label!(lin)
        else_label = undef_make_label!(lin)

        undef_emit_gotoifnot!(lin, else_label)

        # Special case: if the condition contains @isdefined(var), the var is
        # definitely defined in the true branch. This handles both direct
        # `if @isdefined(var)` and `if ... && @isdefined(var)` patterns,
        # since `&&` short-circuits: all operands must be true in the true branch.
        undef_emit_isdefined_hints!(lin, cond, candidates)

        undef_emit_cond_implied_hints!(lin, cond, candidates)

        cond_vars = JL.IdTag[]
        all_bindings = undef_cond_binding_ids!(cond_vars, cond)
        cond_key = (all_bindings && !isempty(cond_vars)) ? Set{JL.IdTag}(cond_vars) : nothing

        isnothing(cond_key) || push!(lin.active_cond_vars, cond_key)
        let saved = undef_save_cond_implied(lin)
            linearize_def_use_events!(lin, ctx3, ex3[2], candidates, allow_throw_optimization)
            undef_restore_cond_implied!(lin, saved; lift_with=cond_key)
        end
        isnothing(cond_key) || pop!(lin.active_cond_vars)

        # Record implications AFTER restore so they live in the outer scope.
        undef_record_cond_implies!(lin, cond_key, undef_collect_branch_direct_assigns(ex3[2], candidates))

        undef_emit_goto!(lin, end_label)

        undef_emit_label!(lin, else_label)
        let saved = undef_save_cond_implied(lin)
            if JS.numchildren(ex3) >= 3
                linearize_def_use_events!(lin, ctx3, ex3[3], candidates, allow_throw_optimization)
            end
            undef_restore_cond_implied!(lin, saved)
        end

        undef_emit_label!(lin, end_label)

    elseif k == JS.K"_while"
        top_label = undef_make_label!(lin)
        end_label = undef_make_label!(lin)

        undef_emit_label!(lin, top_label)
        linearize_def_use_events!(lin, ctx3, ex3[1], candidates, allow_throw_optimization)
        undef_emit_gotoifnot!(lin, end_label)
        let saved = undef_save_cond_implied(lin)
            linearize_def_use_events!(lin, ctx3, ex3[2], candidates, allow_throw_optimization)
            undef_restore_cond_implied!(lin, saved)
        end
        undef_emit_goto!(lin, top_label)
        undef_emit_label!(lin, end_label)

    elseif k == JS.K"_do_while"
        top_label = undef_make_label!(lin)
        end_label = undef_make_label!(lin)

        undef_emit_label!(lin, top_label)
        let saved = undef_save_cond_implied(lin)
            linearize_def_use_events!(lin, ctx3, ex3[1], candidates, allow_throw_optimization)
            linearize_def_use_events!(lin, ctx3, ex3[2], candidates, allow_throw_optimization)
            undef_restore_cond_implied!(lin, saved)
        end
        undef_emit_gotoifnot!(lin, end_label)
        undef_emit_goto!(lin, top_label)
        undef_emit_label!(lin, end_label)

    elseif k == JS.K"trycatchelse"
        catch_label = undef_make_label!(lin)
        end_label = undef_make_label!(lin)

        # Try block can throw at any point
        undef_emit_gotoifnot!(lin, catch_label)
        let saved = undef_save_cond_implied(lin)
            linearize_def_use_events!(lin, ctx3, ex3[1], candidates, allow_throw_optimization)
            undef_restore_cond_implied!(lin, saved)
        end
        undef_emit_goto!(lin, end_label)

        undef_emit_label!(lin, catch_label)
        let saved = undef_save_cond_implied(lin)
            linearize_def_use_events!(lin, ctx3, ex3[2], candidates, allow_throw_optimization)
            if JS.numchildren(ex3) >= 3
                linearize_def_use_events!(lin, ctx3, ex3[3], candidates, allow_throw_optimization)
            end
            undef_restore_cond_implied!(lin, saved)
        end

        undef_emit_label!(lin, end_label)

    elseif k == JS.K"tryfinally"
        finally_label = undef_make_label!(lin)
        end_label = undef_make_label!(lin)

        undef_emit_gotoifnot!(lin, finally_label)
        let saved = undef_save_cond_implied(lin)
            linearize_def_use_events!(lin, ctx3, ex3[1], candidates, allow_throw_optimization)
            undef_restore_cond_implied!(lin, saved)
        end

        undef_emit_label!(lin, finally_label)
        linearize_def_use_events!(lin, ctx3, ex3[2], candidates, allow_throw_optimization)

        undef_emit_label!(lin, end_label)

    elseif k == JS.K"return"
        if JS.numchildren(ex3) >= 1
            linearize_def_use_events!(lin, ctx3, ex3[1], candidates, allow_throw_optimization)
        end
        unreachable = undef_new_block!(lin)
        undef_switch_to_block!(lin, unreachable)

    elseif allow_throw_optimization && k == JS.K"call"
        # Process all children (function and arguments)
        for child in JS.children(ex3)
            linearize_def_use_events!(lin, ctx3, child, candidates, allow_throw_optimization)
        end
        # Check if this is a call to global `throw` - treat as noreturn
        # Required to support the `@assert @isdefined(var) "compiler hint to tell the definedness of `var`"` pattern
        if JS.numchildren(ex3) >= 1
            callee = ex3[1]
            if JS.kind(callee) == JS.K"BindingId"
                binfo = JL.get_binding(ctx3, callee.var_id::JL.IdTag)
                if binfo.kind === :global && binfo.name == "throw"
                    unreachable = undef_new_block!(lin)
                    undef_switch_to_block!(lin, unreachable)
                end
            end
        end

    else
        # Default: process all children
        for child in JS.children(ex3)
            linearize_def_use_events!(lin, ctx3, child, candidates, allow_throw_optimization)
        end
    end
end

# Check if `start` can reach any block in `targets` WITHOUT going through any block in `avoid`
function undef_can_reach_avoiding(blocks::Vector{EventBlock}, start::Int, targets::Set{Int}, avoid::Set{Int})
    visited = Set{Int}()
    worklist = Int[start]
    while !isempty(worklist)
        block_id = pop!(worklist)
        block_id in visited && continue
        push!(visited, block_id)
        if block_id in targets
            return true
        end
        if block_id in avoid
            continue
        end
        for succ in blocks[block_id].succs
            if !(succ in visited)
                push!(worklist, succ)
            end
        end
    end
    return false
end

# Find all use blocks reachable from `start` avoiding `avoid`, sorted by block ID.
function undef_reachable_uses(
        blocks::Vector{EventBlock}, start::Int, targets::Set{Int}, avoid::Set{Int}
    )
    visited = Set{Int}()
    worklist = Int[start]
    reached = Int[]
    while !isempty(worklist)
        block_id = pop!(worklist)
        block_id in visited && continue
        push!(visited, block_id)
        if block_id in targets
            push!(reached, block_id)
        end
        if block_id in avoid
            continue
        end
        for succ in blocks[block_id].succs
            if !(succ in visited)
                push!(worklist, succ)
            end
        end
    end
    sort!(reached)
    return reached
end

# Check if a block is "must-execute" (all paths from entry pass through it)
# This is equivalent to: entry cannot reach exit without going through the block
function undef_is_must_execute(blocks::Vector{EventBlock}, block_id::Int)
    # Find exit blocks (blocks with no successors)
    exit_blocks = Set{Int}()
    for b in blocks
        if isempty(b.succs)
            push!(exit_blocks, b.id)
        end
    end

    # If no exit blocks, consider block as must-execute (edge case)
    isempty(exit_blocks) && return true

    # Check if entry (block 1) can reach any exit without going through block_id
    can_bypass = undef_can_reach_avoiding(blocks, 1, exit_blocks, Set{Int}([block_id]))

    # If entry cannot reach exit without going through this block, it's must-execute
    return !can_bypass
end

# Collect candidate variables captured by any nested closure.  The CFG
# places closure uses/assigns at the closure *definition* site (inside an
# uncertain branch), not at the call site.  This means a use inside a
# closure does not correctly block assignments that come after the closure
# definition, leading to false-positive dead store reports.  Variables
# identified here are excluded from dead store analysis.
function collect_closure_captured_vars(body::JS.SyntaxTree, candidates::Set{JL.IdTag})
    result = Set{JL.IdTag}()
    traverse(body) do st::JS.SyntaxTree
        JS.kind(st) == JS.K"lambda" || return nothing
        nested_lb = st.lambda_bindings::JL.LambdaBindings
        for (id, is_capt) in nested_lb.locals_capt
            if is_capt && id in candidates
                push!(result, id)
            end
        end
        return nothing
    end
    return result
end

"""
    analyze_def_use(ctx3, ex3; allow_throw_optimization) -> (undef_info, dead_store_info)

Combined CFG-aware analysis for local bindings in a single lambda.
Builds the event-based CFG once and runs both undef analysis and dead
store analysis on it.

Returns a tuple of:
- `undef_info::Dict{JL.BindingInfo, UndefInfo}`: undef status per variable
- `dead_store_info::Dict{JL.BindingInfo, DeadStoreInfo}`: dead stores per variable
"""
function analyze_def_use(
        ctx3::JL.VariableAnalysisContext, st3::JS.SyntaxTree;
        allow_throw_optimization::Bool=false
    )
    undef_result = Dict{JL.BindingInfo, UndefInfo}()
    dead_store_result = Dict{JL.BindingInfo, DeadStoreInfo}()

    JS.kind(st3) == JS.K"lambda" || return (undef_result, dead_store_result)

    lambda_bindings = st3.lambda_bindings::JL.LambdaBindings
    candidates = Set{JL.IdTag}()
    for (id, from_outer_lambda) in lambda_bindings.locals_capt
        from_outer_lambda && continue
        binfo = JL.get_binding(ctx3, id)
        if binfo.kind == :local
            push!(candidates, id)
        end
    end

    isempty(candidates) && return (undef_result, dead_store_result)

    # Variables captured by closures are excluded from dead store analysis
    closure_captured = if JS.numchildren(st3) >= 3
        collect_closure_captured_vars(st3[3], candidates)
    else
        Set{JL.IdTag}()
    end

    lin = EventLinearizer()
    if JS.numchildren(st3) >= 3
        linearize_def_use_events!(lin, ctx3, st3[3], candidates, allow_throw_optimization)
    end
    undef_finalize_cfg!(lin)

    for var_id in candidates
        binfo = JL.get_binding(ctx3, var_id)

        defs = JS.SyntaxTree[]
        assign_blocks = Set{Int}()       # for undef (includes :isdefined)
        real_assign_blocks = Set{Int}()  # for dead store (only :assign)
        use_blocks = Set{Int}()
        event_trees = Dict{Int,JS.SyntaxTree}()
        for block in lin.blocks
            (event_kind, id, st) = @something block.event continue
            id == var_id || continue
            event_trees[block.id] = st
            if event_kind === :assign
                push!(defs, st)
                push!(assign_blocks, block.id)
                push!(real_assign_blocks, block.id)
            elseif event_kind === :isdefined
                push!(assign_blocks, block.id)
            else # :use
                push!(use_blocks, block.id)
            end
        end

        # --- Undef analysis ---
        if isempty(use_blocks)
            undef_result[binfo] = UndefInfo(defs, Pair{Bool,JS.SyntaxTree}[])
        elseif isempty(assign_blocks)
            undef_uses = Pair{Bool,JS.SyntaxTree}[true => event_trees[ub] for ub in use_blocks]
            undef_result[binfo] = UndefInfo(defs, undef_uses)
        else
            reached = undef_reachable_uses(lin.blocks, 1, use_blocks, assign_blocks)
            if !isempty(reached)
                min_assign_block = minimum(assign_blocks)
                undef_uses = Pair{Bool,JS.SyntaxTree}[]
                for ub in reached
                    is_strict = ub < min_assign_block &&
                                undef_is_must_execute(lin.blocks, ub)
                    push!(undef_uses, is_strict => event_trees[ub])
                end
                undef_result[binfo] = UndefInfo(defs, undef_uses)
            else
                undef_result[binfo] = UndefInfo(defs, Pair{Bool,JS.SyntaxTree}[])
            end
        end

        # --- Dead store analysis ---
        if var_id in closure_captured || isempty(use_blocks) || isempty(real_assign_blocks)
            continue
        end
        dead_defs = JS.SyntaxTree[]
        for def_block_id in real_assign_blocks
            other_assigns = Set{Int}(ab for ab in real_assign_blocks if ab != def_block_id)
            can_reach_use = undef_can_reach_avoiding(lin.blocks, def_block_id, use_blocks, other_assigns)
            if !can_reach_use
                push!(dead_defs, event_trees[def_block_id])
            end
        end
        if !isempty(dead_defs)
            dead_store_result[binfo] = DeadStoreInfo(dead_defs)
        end
    end

    return (undef_result, dead_store_result)
end

"""
    analyze_def_use_all_lambdas(ctx3, st3; allow_throw_optimization)
        -> (undef_info, dead_store_info)

Analyze undef status and dead stores for all lambdas in the syntax tree.
Builds the CFG once per lambda and runs both analyses on it.
"""
function analyze_def_use_all_lambdas(
        ctx3::JL.VariableAnalysisContext, st3::JS.SyntaxTree;
        allow_throw_optimization::Bool = false
    )
    undef_result = Dict{JL.BindingInfo, UndefInfo}()
    dead_store_result = Dict{JL.BindingInfo, DeadStoreInfo}()
    traverse(st3) do st3′::JS.SyntaxTree
        if JS.kind(st3′) == JS.K"lambda"
            undef_info, dead_store_info = analyze_def_use(ctx3, st3′; allow_throw_optimization)
            merge!(undef_result, undef_info)
            merge!(dead_store_result, dead_store_info)
        end
        return nothing
    end
    return (undef_result, dead_store_result)
end
