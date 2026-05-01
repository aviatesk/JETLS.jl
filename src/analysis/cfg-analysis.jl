# CFG-based analyses for scope-resolved syntax tree `st3`.
#
# This file implements three complementary analyses using a shared event-based CFG:
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
# 3. **Unreachable-code analysis**: identifies `K"block"` children whose
#    recorded CFG block is unreachable from the lambda entry. The CFG
#    accurately models expression-nested control transfers, so e.g.
#    `return f(@goto label); @label label; <code>` correctly recognizes
#    `<code>` as reachable via the goto edge.
#
# The key technique is placing each event in its own "event block" (not
# traditional basic blocks — each block contains at most one event).
# Event ordering is thus represented by CFG edges, allowing us to check
# reachability as a graph problem. Statements (direct children of `K"block"`)
# are additionally recorded with their entry/exit CFG blocks for analysis #3.
#
# Public API: `analyze_all_lambdas(ctx3, st3)` walks every `K"lambda"` in `st3` and returns
# the merged `(; undef_info, dead_store_info, unreachable_statements)` for all three analyses.
# The result types `UndefInfo` and `DeadStoreInfo` are also part of the public surface
# because they appear in the returned dicts.

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
    # Maps `@label name` / `@goto name` label names to CFG label IDs. Unlike
    # `break_targets`, these are not nested — `@label`/`@goto` reference each
    # other across the whole lambda body, and forward references are resolved
    # at finalization via `pending_gotos`.
    const goto_targets::Dict{String,Int}
    # Correlated condition analysis.  Maps a set of condition BindingId
    # var_ids to the set of variables definitely assigned in the true
    # branch.  Scoped via save/restore; invalidated on reassignment.
    # E.g. `if x` records Set([x]) → {y}, `if x && z` records Set([x,z]) → {y}.
    const cond_implies_defined::Dict{Set{JL.IdTag},Set{JL.IdTag}}
    # Stack of BindingId var_id sets for conditions whose true branch we are
    # currently inside.  Used by `undef_emit_cond_implied_hints!` so that
    # nested `if a; if b; ...` lookups see the combined condition Set([a,b]).
    const active_cond_vars::Vector{Set{JL.IdTag}}
    # For each direct child of each `K"block"` visited during
    # linearization, record `(before_block, after_block, statement)`:
    #   - before_block: `current_block` when we start processing the child
    #   - after_block:  `current_block` after the child has been processed
    # Used by `analyze_unreachable!`: a statement is unreachable iff BOTH blocks
    # are unreachable from block 1.
    #
    # Tracking after_block (not just before_block) matters for forms like
    # `K"symboliclabel"`, whose own block becomes reachable via a `K"symbolicgoto"` edge
    # resolved at finalization, even when the preceding fall-through (before_block) is
    # unreachable.
    const statement_blocks::Vector{Tuple{Int,Int,JS.SyntaxTree}}
    # Tracks whether the most recently processed construct emitted a control-flow terminator
    # (`return`, `break`, `goto`, ...) without a matching label, leaving `current_block`
    # known to be unreachable from the entry. Used by `K"tryfinally"` to decide whether to
    # wire its `end_label` (post-try) up to the finally body: when the try body is known
    # to terminate, post-try is unreachable and we must not connect the finally-end to it
    # (otherwise `analyze_unreachable_code!` would consider post-try reachable through the
    # finally's gotoifnot bypass).
    current_known_unreachable::Bool
    function EventLinearizer()
        blocks = EventBlock[EventBlock(1)]
        new(blocks, 1, Dict{Int,Int}(), Tuple{Int,Int}[], 0,
            Dict{String,Int}(), Dict{String,Int}(),
            Dict{Set{JL.IdTag},Set{JL.IdTag}}(), Set{JL.IdTag}[],
            Tuple{Int,Int,JS.SyntaxTree}[], false)
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
    # A label can have additional incoming edges (from gotos resolved at
    # finalization), so we conservatively assume the new current block is
    # reachable.
    lin.current_known_unreachable = false
    return block_id
end

function undef_emit_goto!(lin::EventLinearizer, label_id::Int)
    push!(lin.pending_gotos, (lin.current_block, label_id))
    unreachable = undef_new_block!(lin)
    undef_switch_to_block!(lin, unreachable)
    lin.current_known_unreachable = true
end

function undef_emit_gotoifnot!(lin::EventLinearizer, false_label::Int)
    true_block = undef_new_block!(lin)
    undef_add_edge!(lin, lin.current_block, true_block)
    push!(lin.pending_gotos, (lin.current_block, false_label))
    undef_switch_to_block!(lin, true_block)
end

function cfg_finalize!(lin::EventLinearizer)
    for (from_block, label_id) in lin.pending_gotos
        if haskey(lin.label_to_block, label_id)
            to_block = lin.label_to_block[label_id]
            undef_add_edge!(lin, from_block, to_block)
        end
    end
end

function _undef_get_or_create_goto_label!(lin::EventLinearizer, name::String)
    existing = get(lin.goto_targets, name, nothing)
    isnothing(existing) || return existing
    label_id = undef_make_label!(lin)
    lin.goto_targets[name] = label_id
    return label_id
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

function linearize_cfg_events!(
        lin::EventLinearizer, ctx3::JL.VariableAnalysisContext, ex3::JS.SyntaxTree,
        candidates::Set{JL.IdTag}, allow_noreturn_optimization::Vector{Symbol}
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
            linearize_cfg_events!(lin, ctx3, ex3[2], candidates, allow_noreturn_optimization)
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
            linearize_cfg_events!(lin, ctx3, ex3[2], candidates, allow_noreturn_optimization)
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
        lin.current_known_unreachable = true

    elseif k == JS.K"symboliclabel"
        # `@label name` — register a CFG label at the current position so any
        # `K"symbolicgoto"` referencing this name (forward or backward) can
        # land here. At `st3` this node is a leaf; the name lives on `name_val`.
        label_id = _undef_get_or_create_goto_label!(lin, ex3.name_val::String)
        undef_emit_label!(lin, label_id)

    elseif k == JS.K"symbolicgoto" || k == JS.K"oldsymbolicgoto"
        # `@goto name` — unconditional jump to the matching `K"symboliclabel"`.
        # Forward references work because `pending_gotos` is resolved later in
        # `cfg_finalize!`.
        label_id = _undef_get_or_create_goto_label!(lin, ex3.name_val::String)
        undef_emit_goto!(lin, label_id)

    elseif JS.is_leaf(ex3) || JL.is_quoted(ex3)
        # Nothing to do

    elseif k == JS.K"="
        # Process RHS first
        linearize_cfg_events!(lin, ctx3, ex3[2], candidates, allow_noreturn_optimization)
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
            linearize_cfg_events!(lin, ctx3, ex3[i], candidates, allow_noreturn_optimization)
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
                linearize_cfg_events!(lin, ctx3, ex3[3], candidates, allow_noreturn_optimization)
                undef_restore_cond_implied!(lin, saved)
            end
            undef_emit_label!(lin, skip_label)
        end

    elseif k == JS.K"local"
        # local declarations don't use or assign

    elseif k == JS.K"decl"
        # decl nodes: the BindingId is declaration, not use; only visit type expression
        if JS.numchildren(ex3) >= 2
            linearize_cfg_events!(lin, ctx3, ex3[2], candidates, allow_noreturn_optimization)
        end

    elseif k == JS.K"if" || k == JS.K"elseif"
        # if cond then_branch [else_branch]
        cond = ex3[1]
        linearize_cfg_events!(lin, ctx3, cond, candidates, allow_noreturn_optimization)

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
            linearize_cfg_events!(lin, ctx3, ex3[2], candidates, allow_noreturn_optimization)
            undef_restore_cond_implied!(lin, saved; lift_with=cond_key)
        end
        isnothing(cond_key) || pop!(lin.active_cond_vars)

        # Record implications AFTER restore so they live in the outer scope.
        undef_record_cond_implies!(lin, cond_key, undef_collect_branch_direct_assigns(ex3[2], candidates))

        undef_emit_goto!(lin, end_label)

        undef_emit_label!(lin, else_label)
        let saved = undef_save_cond_implied(lin)
            if JS.numchildren(ex3) >= 3
                linearize_cfg_events!(lin, ctx3, ex3[3], candidates, allow_noreturn_optimization)
            end
            undef_restore_cond_implied!(lin, saved)
        end

        undef_emit_label!(lin, end_label)

    elseif k == JS.K"_while"
        top_label = undef_make_label!(lin)
        end_label = undef_make_label!(lin)

        undef_emit_label!(lin, top_label)
        linearize_cfg_events!(lin, ctx3, ex3[1], candidates, allow_noreturn_optimization)
        undef_emit_gotoifnot!(lin, end_label)
        let saved = undef_save_cond_implied(lin)
            linearize_cfg_events!(lin, ctx3, ex3[2], candidates, allow_noreturn_optimization)
            undef_restore_cond_implied!(lin, saved)
        end
        undef_emit_goto!(lin, top_label)
        undef_emit_label!(lin, end_label)

    elseif k == JS.K"_do_while"
        top_label = undef_make_label!(lin)
        end_label = undef_make_label!(lin)

        undef_emit_label!(lin, top_label)
        let saved = undef_save_cond_implied(lin)
            linearize_cfg_events!(lin, ctx3, ex3[1], candidates, allow_noreturn_optimization)
            linearize_cfg_events!(lin, ctx3, ex3[2], candidates, allow_noreturn_optimization)
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
            linearize_cfg_events!(lin, ctx3, ex3[1], candidates, allow_noreturn_optimization)
            undef_restore_cond_implied!(lin, saved)
        end
        undef_emit_goto!(lin, end_label)

        undef_emit_label!(lin, catch_label)
        let saved = undef_save_cond_implied(lin)
            linearize_cfg_events!(lin, ctx3, ex3[2], candidates, allow_noreturn_optimization)
            if JS.numchildren(ex3) >= 3
                linearize_cfg_events!(lin, ctx3, ex3[3], candidates, allow_noreturn_optimization)
            end
            undef_restore_cond_implied!(lin, saved)
        end

        undef_emit_label!(lin, end_label)

    elseif k == JS.K"tryfinally"
        finally_label = undef_make_label!(lin)
        end_label = undef_make_label!(lin)

        undef_emit_gotoifnot!(lin, finally_label)
        let saved = undef_save_cond_implied(lin)
            linearize_cfg_events!(lin, ctx3, ex3[1], candidates, allow_noreturn_optimization)
            undef_restore_cond_implied!(lin, saved)
        end

        # If the try body terminated, post-try is unreachable; the finally
        # body still runs (modeled via the gotoifnot bypass) but its
        # completion does not flow into post-try.
        try_body_terminated = lin.current_known_unreachable

        undef_emit_label!(lin, finally_label)
        linearize_cfg_events!(lin, ctx3, ex3[2], candidates, allow_noreturn_optimization)

        if try_body_terminated
            end_block = undef_new_block!(lin)
            lin.label_to_block[end_label] = end_block
            undef_switch_to_block!(lin, end_block)
            lin.current_known_unreachable = true
        else
            undef_emit_label!(lin, end_label)
        end

    elseif k == JS.K"return"
        if JS.numchildren(ex3) >= 1
            linearize_cfg_events!(lin, ctx3, ex3[1], candidates, allow_noreturn_optimization)
        end
        # Switch to a fresh "phantom" block — no edge from the
        # return-emitting block — so the linearizer keeps a valid
        # `current_block` for whatever syntactically follows the return.
        # The phantom has no incoming edges, so subsequent events recorded
        # against it are correctly treated as unreachable. Same pattern:
        # `undef_emit_goto!`, no-target `K"break"`, noreturn-call branch.
        unreachable = undef_new_block!(lin)
        undef_switch_to_block!(lin, unreachable)
        lin.current_known_unreachable = true

    elseif k == JS.K"block"
        # Record each direct child as a "statement" tagged with both the
        # block where execution would arrive at the child (before) and the
        # block execution leaves it in (after). Used by reachability-based
        # unreachable analysis: a statement is reachable iff EITHER block
        # is reachable from the entry. Tracking the after-block matters for
        # forms like `K"symboliclabel"` whose own block becomes reachable
        # only via a `K"symbolicgoto"` edge resolved at finalization, even
        # though fall-through from the previous statement is unreachable.
        for child in JS.children(ex3)
            before_block = lin.current_block
            linearize_cfg_events!(lin, ctx3, child, candidates, allow_noreturn_optimization)
            after_block = lin.current_block
            push!(lin.statement_blocks, (before_block, after_block, child))
        end

    else # Default: process all children
        for child in JS.children(ex3)
            linearize_cfg_events!(lin, ctx3, child, candidates, allow_noreturn_optimization)
        end

        if !isempty(allow_noreturn_optimization) &&
                is_noreturn_call(ctx3, ex3, allow_noreturn_optimization)
            unreachable = undef_new_block!(lin)
            undef_switch_to_block!(lin, unreachable)
            lin.current_known_unreachable = true
        end
    end
end

# Check if `start` can reach any block in `targets` WITHOUT going through any block in `avoid`.
# `visited` is a caller-provided scratch `BitSet` that is cleared on entry.
function undef_can_reach_avoiding(
        blocks::Vector{EventBlock}, start::Int, targets::BitSet, avoid::BitSet,
        visited::BitSet
    )
    empty!(visited)
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
# `visited` is a caller-provided scratch `BitSet` that is cleared on entry.
function undef_reachable_uses(
        blocks::Vector{EventBlock}, start::Int, targets::BitSet, avoid::BitSet,
        visited::BitSet
    )
    empty!(visited)
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

# Check if a block is "must-execute" (all paths from entry pass through it).
# This is equivalent to: entry cannot reach exit without going through the block.
# When `exit_blocks` / `visited` are supplied by the caller they are reused
# across repeated calls for the same CFG, avoiding redundant allocation.
function undef_is_must_execute(
        blocks::Vector{EventBlock}, block_id::Int, exit_blocks::BitSet, visited::BitSet
    )
    isempty(exit_blocks) && return true
    avoid = BitSet([block_id])
    can_bypass = undef_can_reach_avoiding(blocks, 1, exit_blocks, avoid, visited)
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
    compute_reachable_blocks(blocks::Vector{EventBlock}) -> BitSet

Return the set of block ids reachable from block 1 (the lambda entry) by
following `succs` edges. Used by reachability-based unreachable-code
detection.
"""
function compute_reachable_blocks(blocks::Vector{EventBlock})
    reachable = BitSet()
    isempty(blocks) && return reachable
    push!(reachable, 1)
    queue = Int[1]
    while !isempty(queue)
        b = popfirst!(queue)
        for s in blocks[b].succs
            if !(s in reachable)
                push!(reachable, s)
                push!(queue, s)
            end
        end
    end
    return reachable
end

"""
    LambdaCFG

Per-lambda event-based CFG together with the indices the analyses in this file consume.
Build once via `build_lambda_cfg` and pass the result to `analyze_local_def_use!` and
`analyze_unreachable`.

Fields:
- `lin::EventLinearizer`: the constructed CFG
- `candidates::Set{JL.IdTag}`: local binding ids tracked for def-use
- `closure_captured::Set{JL.IdTag}`: subset of `candidates` captured by
  closures; excluded from dead-store analysis
- `var_events::Dict{JL.IdTag, Vector{Tuple{Symbol,Int,JS.SyntaxTree}}}`:
  per-variable event list indexed by `var_id`, avoiding
  O(blocks × candidates) scans during analysis
- `exit_blocks::BitSet`: CFG blocks with no successors, used for
  must-execute queries during undef analysis
"""
struct LambdaCFG
    lin::EventLinearizer
    candidates::Set{JL.IdTag}
    closure_captured::Set{JL.IdTag}
    var_events::Dict{JL.IdTag, Vector{Tuple{Symbol,Int,JS.SyntaxTree}}}
    exit_blocks::BitSet
end

# Construct the `LambdaCFG` for `lambda_st3`.
# The returned CFG is shared between `analyze_local_def_use!` and `analyze_unreachable!`.
function build_lambda_cfg(
        ctx3::JL.VariableAnalysisContext, lambda_st3::JS.SyntaxTree;
        allow_noreturn_optimization::Vector{Symbol} = Symbol[]
    )
    JS.kind(lambda_st3) == JS.K"lambda" || return nothing

    lambda_bindings = lambda_st3.lambda_bindings::JL.LambdaBindings
    candidates = Set{JL.IdTag}()
    for (id, from_outer_lambda) in lambda_bindings.locals_capt
        from_outer_lambda && continue
        binfo = JL.get_binding(ctx3, id)
        if binfo.kind == :local
            push!(candidates, id)
        end
    end

    closure_captured = if JS.numchildren(lambda_st3) >= 3
        collect_closure_captured_vars(lambda_st3[3], candidates)
    else
        Set{JL.IdTag}()
    end

    lin = EventLinearizer()
    if JS.numchildren(lambda_st3) >= 3
        linearize_cfg_events!(
            lin, ctx3, lambda_st3[3], candidates, allow_noreturn_optimization)
    end
    cfg_finalize!(lin)

    # Pre-build var_id → event list index to avoid O(blocks × candidates)
    # scanning in the per-variable loop of `analyze_local_def_use!`.
    var_events = Dict{JL.IdTag, Vector{Tuple{Symbol,Int,JS.SyntaxTree}}}()
    for block in lin.blocks
        evt = block.event
        isnothing(evt) && continue
        (event_kind, id, st) = evt
        id in candidates || continue
        evts = get!(Vector{Tuple{Symbol,Int,JS.SyntaxTree}}, var_events, id)
        push!(evts, (event_kind, block.id, st))
    end

    # Pre-compute exit blocks (no successors) for must-execute checks.
    exit_blocks = BitSet()
    for b in lin.blocks
        isempty(b.succs) && push!(exit_blocks, b.id)
    end

    return LambdaCFG(lin, candidates, closure_captured, var_events, exit_blocks)
end

# Reachability-based unreachable-statement detection on a built CFG. Adds to
# `unreachable_statements` every recorded statement whose entry and exit CFG blocks are
# both unreachable from the lambda entry.
function analyze_unreachable!(
        unreachable_statements::Set{JS.SyntaxTree}, cfg::LambdaCFG
    )
    reachable = compute_reachable_blocks(cfg.lin.blocks)
    for (before_block, after_block, stmt) in cfg.lin.statement_blocks
        (before_block in reachable || after_block in reachable) && continue
        push!(unreachable_statements, stmt)
    end
    return unreachable_statements
end

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

# Run undef-analysis and dead-store analysis for every local binding tracked by
# `cfg.candidates`, sharing the precomputed event index and exit-block set on `cfg`.
function analyze_local_def_use!(
        undef_info::Dict{JL.BindingInfo, UndefInfo},
        dead_store_info::Dict{JL.BindingInfo, DeadStoreInfo},
        ctx3::JL.VariableAnalysisContext, cfg::LambdaCFG
    )
    isempty(cfg.candidates) && return

    visited = BitSet()
    for var_id in cfg.candidates
        binfo = JL.get_binding(ctx3, var_id)

        evts = get(cfg.var_events, var_id, nothing)
        if isnothing(evts)
            undef_info[binfo] = UndefInfo()
            continue
        end

        defs = JS.SyntaxTree[]
        assign_blocks = BitSet()       # for undef (includes :isdefined)
        real_assign_blocks = BitSet()  # for dead store (only :assign)
        use_blocks = BitSet()
        event_trees = Dict{Int,JS.SyntaxTree}()
        for (event_kind, block_id, st) in evts
            event_trees[block_id] = st
            if event_kind === :assign
                push!(defs, st)
                push!(assign_blocks, block_id)
                push!(real_assign_blocks, block_id)
            elseif event_kind === :isdefined
                push!(assign_blocks, block_id)
            else # :use
                push!(use_blocks, block_id)
            end
        end

        # --- Undef analysis ---
        if isempty(use_blocks)
            undef_info[binfo] = UndefInfo(defs, Pair{Bool,JS.SyntaxTree}[])
        elseif isempty(assign_blocks)
            undef_uses = Pair{Bool,JS.SyntaxTree}[true => event_trees[ub] for ub in use_blocks]
            undef_info[binfo] = UndefInfo(defs, undef_uses)
        else
            reached = undef_reachable_uses(cfg.lin.blocks, 1, use_blocks, assign_blocks, visited)
            if !isempty(reached)
                min_assign_block = minimum(assign_blocks)
                undef_uses = Pair{Bool,JS.SyntaxTree}[]
                for ub in reached
                    is_strict = ub < min_assign_block &&
                                undef_is_must_execute(cfg.lin.blocks, ub, cfg.exit_blocks, visited)
                    push!(undef_uses, is_strict => event_trees[ub])
                end
                undef_info[binfo] = UndefInfo(defs, undef_uses)
            else
                undef_info[binfo] = UndefInfo(defs, Pair{Bool,JS.SyntaxTree}[])
            end
        end

        # --- Dead store analysis ---
        if var_id in cfg.closure_captured ||
           isempty(use_blocks) || isempty(real_assign_blocks)
            continue
        end
        dead_defs = JS.SyntaxTree[]
        other_assigns = BitSet()
        for def_block_id in real_assign_blocks
            empty!(other_assigns)
            for ab in real_assign_blocks
                ab != def_block_id && push!(other_assigns, ab)
            end
            can_reach_use = undef_can_reach_avoiding(
                cfg.lin.blocks, def_block_id, use_blocks, other_assigns, visited)
            if !can_reach_use
                push!(dead_defs, event_trees[def_block_id])
            end
        end
        if !isempty(dead_defs)
            dead_store_info[binfo] = DeadStoreInfo(dead_defs)
        end
    end

    return
end

# Build the CFG for one `K"lambda"` and run all CFG-based analyses
# (undef, dead store, unreachable) on it, adding results directly
# to the caller-provided containers.
function analyze_lambda!(
        undef_info::Dict{JL.BindingInfo, UndefInfo},
        dead_store_info::Dict{JL.BindingInfo, DeadStoreInfo},
        unreachable_statements::Set{JS.SyntaxTree},
        ctx3::JL.VariableAnalysisContext, lambda_st3::JS.SyntaxTree,
        allow_noreturn_optimization::Vector{Symbol}
    )
    cfg = @something build_lambda_cfg(ctx3, lambda_st3; allow_noreturn_optimization) return
    analyze_local_def_use!(undef_info, dead_store_info, ctx3, cfg)
    analyze_unreachable!(unreachable_statements, cfg)
    return
end

"""
    analyze_all_lambdas(ctx3, st3; allow_noreturn_optimization=Symbol[])
        -> (; undef_info, dead_store_info, unreachable_statements)

Public entry point of `cfg-analysis.jl`. Walks `st3` and, for every
`K"lambda"` it encounters, builds a per-lambda event-based CFG and runs
all three CFG-aware analyses on it:

- **Undef analysis** — for each tracked local binding, report uses on
  CFG paths that do not pass through any of its defining sites.
  Encoded as `Dict{JL.BindingInfo, UndefInfo}`; each `UndefInfo` lists
  the binding's `defs` and any `undef_uses` (`is_strict => use_tree`,
  where `is_strict == true` means UndefVarError is guaranteed on the
  path that reaches `use_tree`).

- **Dead store (unused assignment) analysis** — for each tracked local
  binding, report assignments whose value cannot reach any use without
  being overwritten by another assignment. Encoded as
  `Dict{JL.BindingInfo, DeadStoreInfo}` listing the dead `defs`.

- **Unreachable-code analysis** — collects `K"block"` children whose
  CFG block is not reachable from the lambda entry. Returned as
  `Set{JS.SyntaxTree}`. Because the CFG accurately models
  expression-nested control transfers, patterns like
  `return f(@goto label); @label label; <code>` correctly keep
  `<code>` reachable via the goto edge.

Results from every visited lambda are merged into a single set of
result containers that are threaded through the traversal, so no
per-lambda intermediate dicts/sets are allocated and merged.

# Arguments
- `ctx3::JL.VariableAnalysisContext`: the variable-analysis context
  produced by JuliaLowering's scope-resolution pass.
- `st3::JS.SyntaxTree`: scope-resolved syntax tree to analyze. Top-
  level (non-lambda) constructs are skipped.
- `allow_noreturn_optimization::Vector{Symbol}`: globals (typically
  function names) whose calls should be treated as guaranteed
  terminators by `K"call"` lowering — used to model `error(...)`-style
  helpers as block terminators when the user opts in.

# Notes
Macro-expanded code is best fed in after `_remove_macrocalls` for old-style macros
(see `src/utils/ast.jl`); raw macro output can place statements like `return` into
expression positions that this analysis is not designed to handle correctly.
"""
function analyze_all_lambdas(
        ctx3::JL.VariableAnalysisContext, st3::JS.SyntaxTree;
        allow_noreturn_optimization::Vector{Symbol} = Symbol[]
    )
    undef_info = Dict{JL.BindingInfo, UndefInfo}()
    dead_store_info = Dict{JL.BindingInfo, DeadStoreInfo}()
    unreachable_statements = Set{JS.SyntaxTree}()
    traverse(st3) do st3′::JS.SyntaxTree
        if JS.kind(st3′) == JS.K"lambda"
            analyze_lambda!(
                undef_info, dead_store_info, unreachable_statements,
                ctx3, st3′, allow_noreturn_optimization)
        end
        return nothing
    end
    return (; undef_info, dead_store_info, unreachable_statements)
end
