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
# 3. **Unreachable-code analysis**: identifies `:block` children whose
#    recorded CFG block is unreachable from the lambda entry. The CFG
#    accurately models expression-nested control transfers, so e.g.
#    `return cnd ? @goto(fallback) : println("Return"); @label fallback; <code>`
#    correctly recognizes `<code>` as reachable via the goto edge.
#
# The key technique is placing each event in its own "event block" (not
# traditional basic blocks — each block contains at most one event).
# Event ordering is thus represented by CFG edges, allowing us to check
# reachability as a graph problem. Statements (direct children of `:block`)
# are additionally recorded with their entry/exit CFG blocks for analysis #3.
#
# Public API: `analyze_all_lambdas(ctx3, st3)` walks every `:lambda` in `st3` and returns
# the merged `(; undef_info, dead_store_info, unreachable_statements)` for all three analyses.
# The result types `UndefInfo` and `DeadStoreInfo` are also part of the public surface
# because they appear in the returned dicts.

# Per-block variable event recorded on `EventBlock.event`. `kind` is one of
# `:assign` / `:use` / `:isdefined` (the last is a hint for CFG analysis, not
# a real def). Using a named struct rather than a `Tuple` keeps the field
# layout stable for the compiler when stored as an `Union{Nothing, ...}`
# and avoids per-push tuple boxing in `Vector{...}` containers below.
struct BlockEvent
    kind::Symbol
    var_id::JL.IdTag
    st::SyntaxTree
end

# Per-variable, per-block event entry stored in `LambdaCFG.var_events`.
# Same `kind` semantics as `BlockEvent`; here `block_id` identifies the
# CFG block the event was emitted into.
struct VarEvent
    kind::Symbol
    block_id::Int
    st::SyntaxTree
end

# A `:block` child statement together with the CFG blocks execution
# enters and leaves it in. Stored on `EventLinearizer.statement_blocks`
# and consumed by `analyze_unreachable!`.
struct StatementRecord
    before_block::Int
    after_block::Int
    st::SyntaxTree
end

mutable struct EventBlock
    const id::Int
    const succs::Vector{Int}
    # Event in this block (at most one per block due to emit creating new blocks).
    event::Union{Nothing, BlockEvent}
end

EventBlock(id::Int) = EventBlock(id, Int[], nothing)

mutable struct EventLinearizer
    const blocks::Vector{EventBlock}
    current_block::Int
    const label_to_block::Dict{Int,Int}
    # `(from_block, label_id)` — resolved into edges by `cfg_finalize!`.
    const pending_gotos::Vector{Tuple{Int,Int}}
    next_label::Int
    # Maps symbolic label names (e.g. "loop-exit", "loop-cont") to CFG label IDs
    # for handling `:symbolicblock` / `:break` pairs from lowered loops.
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
    # For each direct child of each `:block` visited during
    # linearization, record `(before_block, after_block, statement)`:
    #   - before_block: `current_block` when we start processing the child
    #   - after_block:  `current_block` after the child has been processed
    # Used by `analyze_unreachable!`: a statement is unreachable iff BOTH blocks
    # are unreachable from block 1.
    #
    # Tracking after_block (not just before_block) matters for forms like
    # `:symboliclabel`, whose own block becomes reachable via a `:symbolicgoto` edge
    # resolved at finalization, even when the preceding fall-through (before_block) is
    # unreachable.
    const statement_blocks::Vector{StatementRecord}
    # Stack of the label IDs that a `return` in the try body of each enclosing `:tryfinally`
    # jumps to. Pushed before linearizing the try body and popped before the finally body
    # (so it is empty inside the finally body itself). Consulted by `:return` so that a
    # return inside `try` routes through the innermost enclosing finally — modeling the
    # runtime semantics of "finally runs before the return takes effect" — and an
    # assignment in the try body can correctly reach a use in the finally body.
    const active_finally_labels::Vector{Int}
    # Stack of label IDs of the exception handlers (catch or finally blocks) whose try body
    # is being linearized. Each is pushed only around its try body, so the innermost entry
    # is where an exception thrown at the current point is caught. Consulted by `:block`.
    const active_handler_labels::Vector{Int}
    function EventLinearizer()
        blocks = EventBlock[EventBlock(1)]
        new(blocks, 1, Dict{Int,Int}(), Tuple{Int,Int}[], 0,
            Dict{String,Int}(), Dict{String,Int}(),
            Dict{Set{JL.IdTag},Set{JL.IdTag}}(), Set{JL.IdTag}[],
            StatementRecord[], Int[], Int[])
    end
end

function cfg_new_block!(lin::EventLinearizer)
    id = length(lin.blocks) + 1
    push!(lin.blocks, EventBlock(id))
    return id
end

function cfg_switch_to_block!(lin::EventLinearizer, id::Int)
    lin.current_block = id
end

function cfg_add_edge!(lin::EventLinearizer, from::Int, to::Int)
    if !(to in lin.blocks[from].succs)
        push!(lin.blocks[from].succs, to)
    end
end

function cfg_emit_event!(lin::EventLinearizer, event_kind::Symbol, var_id::JL.IdTag, st::SyntaxTree)
    lin.blocks[lin.current_block].event = BlockEvent(event_kind, var_id, st)
    # Create a new block to ensure proper ordering.
    # This allows the path-based analysis to track intra-block event order:
    # `x = 1; println(x)` becomes BB1(assign) → BB2(use), so the analysis
    # correctly detects that all paths to use go through assignment.
    next_block = cfg_new_block!(lin)
    cfg_add_edge!(lin, lin.current_block, next_block)
    cfg_switch_to_block!(lin, next_block)
end

function cfg_make_label!(lin::EventLinearizer)
    return lin.next_label += 1
end

function cfg_emit_label!(lin::EventLinearizer, label_id::Int)
    block_id = cfg_new_block!(lin)
    lin.label_to_block[label_id] = block_id
    cfg_add_edge!(lin, lin.current_block, block_id)
    cfg_switch_to_block!(lin, block_id)
    return block_id
end

function cfg_emit_goto!(lin::EventLinearizer, label_id::Int)
    push!(lin.pending_gotos, (lin.current_block, label_id))
    unreachable = cfg_new_block!(lin)
    cfg_switch_to_block!(lin, unreachable)
end

function cfg_emit_gotoifnot!(lin::EventLinearizer, false_label::Int)
    true_block = cfg_new_block!(lin)
    cfg_add_edge!(lin, lin.current_block, true_block)
    push!(lin.pending_gotos, (lin.current_block, false_label))
    cfg_switch_to_block!(lin, true_block)
end

function cfg_finalize!(lin::EventLinearizer)
    for (from_block, label_id) in lin.pending_gotos
        if haskey(lin.label_to_block, label_id)
            to_block = lin.label_to_block[label_id]
            cfg_add_edge!(lin, from_block, to_block)
        end
    end
end

function cfg_get_or_create_goto_label!(lin::EventLinearizer, name::String)
    existing = get(lin.goto_targets, name, nothing)
    isnothing(existing) || return existing
    label_id = cfg_make_label!(lin)
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
# EST `:block` wrappers and descending through `&&` chains (all
# operands must be true in the true branch).
function for_each_cond_operand(@specialize(callback), cond::SyntaxTree)
    traverse(cond) do node::SyntaxTree
        k = JS.head(node)
        if k == :&& || (k == :block && JS.numchildren(node) == 1)
            return # descend into children
        end
        callback(node)
        return traversal_no_recurse
    end
end

function undef_is_not_call(ctx3::JL.VariableAnalysisContext, cond::SyntaxTree)
    JS.head(cond) == :call || return false
    JS.numchildren(cond) == 2 || return false
    func = cond[1]
    JS.head(func) == :bindingid || return false
    binfo = JL.get_binding(ctx3, var_id(func))
    return binfo.kind === :global && binfo.name == "!"
end

function undef_emit_isdefined_hint!(
        lin::EventLinearizer, arg::SyntaxTree, candidates::Set{JL.IdTag}
    )
    JS.head(arg) == :bindingid || return
    vid = var_id(arg)
    vid in candidates && cfg_emit_event!(lin, :isdefined, vid, arg)
end

# Emit `:isdefined` hints for condition branches where `@isdefined(var)` is true.
function undef_emit_isdefined_hints!(
        lin::EventLinearizer, ctx3::JL.VariableAnalysisContext,
        cond::SyntaxTree, candidates::Set{JL.IdTag}, branch_value::Bool
    )
    k = JS.head(cond)
    if k == :block && JS.numchildren(cond) == 1
        undef_emit_isdefined_hints!(lin, ctx3, cond[1], candidates, branch_value)
    elseif undef_is_not_call(ctx3, cond)
        undef_emit_isdefined_hints!(lin, ctx3, cond[2], candidates, !branch_value)
    elseif branch_value && k == :&&
        for child in JS.children(cond)
            undef_emit_isdefined_hints!(lin, ctx3, child, candidates, true)
        end
    elseif !branch_value && k == :||
        for child in JS.children(cond)
            undef_emit_isdefined_hints!(lin, ctx3, child, candidates, false)
        end
    elseif branch_value && k == :isdefined && JS.numchildren(cond) >= 1
        undef_emit_isdefined_hint!(lin, cond[1], candidates)
    end
end

# Collect all BindingId var_ids asserted true by a condition.
# Returns `true` if every operand is a BindingId (for recording),
# `false` otherwise (lookup still uses the collected ids).
function undef_cond_binding_ids!(result::Vector{JL.IdTag}, cond::SyntaxTree)
    all_bindings = Ref(true)
    for_each_cond_operand(cond) do operand::SyntaxTree
        if JS.head(operand) == :bindingid
            push!(result, var_id(operand))
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
function undef_direct_assign_var_id(node::SyntaxTree)
    k = JS.head(node)
    if (k == :(=) || k == :function_decl) && JS.numchildren(node) >= 1
        lhs = node[1]
        if JS.head(lhs) == :bindingid
            return var_id(lhs)
        end
    end
    return nothing
end

# Collect variables that are definitely assigned (direct top-level assignments)
# in a branch. Only considers assignments at the top level of `:block` nodes,
# not those nested inside conditionals/loops.
function undef_collect_branch_direct_assigns(
        branch::SyntaxTree, candidates::Set{JL.IdTag}
    )
    result = Set{JL.IdTag}()
    undef_scan_direct_assigns!(result, branch, candidates)
    return result
end

function undef_scan_direct_assigns!(
        result::Set{JL.IdTag}, node::SyntaxTree, candidates::Set{JL.IdTag}
    )
    var_id = undef_direct_assign_var_id(node)
    if !isnothing(var_id)
        if var_id in candidates
            push!(result, var_id)
        end
    elseif JS.head(node) == :block
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
        lin::EventLinearizer, cond::SyntaxTree, candidates::Set{JL.IdTag}
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
                cfg_emit_event!(lin, :isdefined, var_id, cond)
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
        lin::EventLinearizer, ctx3::JL.VariableAnalysisContext, ex3::SyntaxTree,
        candidates::Set{JL.IdTag}, allow_noreturn_optimization::Vector{Symbol}
    )
    k = JS.head(ex3)

    if k == :bindingid
        vid = var_id(ex3)
        if vid in candidates
            cfg_emit_event!(lin, :use, vid, ex3)
        end

    elseif k == :symbolicblock
        label_node = ex3[1]
        label_name = name_val(label_node)
        exit_label = cfg_make_label!(lin)
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
        cfg_emit_label!(lin, exit_label)

    elseif k == :break
        # Process value child if present (break label value)
        if JS.numchildren(ex3) >= 2
            linearize_cfg_events!(lin, ctx3, ex3[2], candidates, allow_noreturn_optimization)
        end
        # Emit goto to matching symbolicblock exit if label is known
        if JS.numchildren(ex3) >= 1 && JS.head(ex3[1]) == :symboliclabel
            label_name = name_val(ex3[1])
            target_label = get(lin.break_targets, label_name, nothing)
            if !isnothing(target_label)
                cfg_emit_goto!(lin, target_label)
                return
            end
        end
        unreachable = cfg_new_block!(lin)
        cfg_switch_to_block!(lin, unreachable)

    elseif k == :symboliclabel
        # `@label name` — register a CFG label at the current position so any
        # `:symbolicgoto` referencing this name (forward or backward) can
        # land here. At `st3` this node is a leaf; the name lives on `name_val`.
        label_id = cfg_get_or_create_goto_label!(lin, name_val(ex3))
        cfg_emit_label!(lin, label_id)

    elseif k == :symbolicgoto
        # `@goto name` — unconditional jump to the matching `:symboliclabel`.
        # Forward references work because `pending_gotos` is resolved later in
        # `cfg_finalize!`.
        label_id = cfg_get_or_create_goto_label!(lin, name_val(ex3))
        cfg_emit_goto!(lin, label_id)

    elseif JS.is_leaf(ex3) || JL.is_quoted(ex3)
        # Nothing to do

    elseif k == :(=)
        # Process RHS first
        linearize_cfg_events!(lin, ctx3, ex3[2], candidates, allow_noreturn_optimization)
        # Then record assignment
        lhs = ex3[1]
        if JS.head(lhs) == :bindingid
            vid = var_id(lhs)
            if vid in candidates
                cfg_emit_event!(lin, :assign, vid, lhs)
            end
            undef_invalidate_cond_implies!(lin, vid)
        end

    elseif k == :function_decl
        # Process the RHS first (method_defs)
        for i in 2:JS.numchildren(ex3)
            linearize_cfg_events!(lin, ctx3, ex3[i], candidates, allow_noreturn_optimization)
        end
        # Then emit the assign event for the function name
        lhs = ex3[1]
        if JS.head(lhs) == :bindingid
            vid = var_id(lhs)
            if vid in candidates
                cfg_emit_event!(lin, :assign, vid, lhs)
            end
            undef_invalidate_cond_implies!(lin, vid)
        end

    elseif k == :isdefined
        # @isdefined(var) checks if var is defined but doesn't actually use it
        # (won't cause UndefVarError), so don't emit use event for the BindingId inside

    elseif k == :lambda
        # Handle captured variables from outer scope by recursing into lambda body
        # We don't know when/if the closure is called, so wrap in an uncertain branch
        nested_lb = JL.lambda_bindings(ex3[1])
        has_outer_capture = any(is_capt && id in candidates for (id, is_capt) in nested_lb.locals_capt)
        if has_outer_capture && JS.numchildren(ex3) >= 4
            skip_label = cfg_make_label!(lin)
            cfg_emit_gotoifnot!(lin, skip_label)
            let saved = undef_save_cond_implied(lin)
                linearize_cfg_events!(lin, ctx3, ex3[4], candidates, allow_noreturn_optimization)
                undef_restore_cond_implied!(lin, saved)
            end
            cfg_emit_label!(lin, skip_label)
        end

    elseif k == :local
        # local declarations don't use or assign

    elseif k == :decl
        # decl nodes: the BindingId is declaration, not use; only visit type expression
        if JS.numchildren(ex3) >= 2
            linearize_cfg_events!(lin, ctx3, ex3[2], candidates, allow_noreturn_optimization)
        end

    elseif k == :if || k == :elseif
        # if cond then_branch [else_branch]
        cond = ex3[1]
        linearize_cfg_events!(lin, ctx3, cond, candidates, allow_noreturn_optimization)

        end_label = cfg_make_label!(lin)
        else_label = cfg_make_label!(lin)

        cfg_emit_gotoifnot!(lin, else_label)

        # Special case: if the condition implies @isdefined(var), the var is
        # definitely defined on that branch. This handles direct
        # `if @isdefined(var)`, `if ... && @isdefined(var)`, and negated
        # conditions like `if !(@isdefined(var)); ...; else ...`.
        undef_emit_isdefined_hints!(lin, ctx3, cond, candidates, true)

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

        cfg_emit_goto!(lin, end_label)

        cfg_emit_label!(lin, else_label)
        undef_emit_isdefined_hints!(lin, ctx3, cond, candidates, false)
        let saved = undef_save_cond_implied(lin)
            if JS.numchildren(ex3) >= 3
                linearize_cfg_events!(lin, ctx3, ex3[3], candidates, allow_noreturn_optimization)
            end
            undef_restore_cond_implied!(lin, saved)
        end

        cfg_emit_label!(lin, end_label)

    elseif k == :_while
        top_label = cfg_make_label!(lin)
        end_label = cfg_make_label!(lin)

        cfg_emit_label!(lin, top_label)
        cond = ex3[1]
        linearize_cfg_events!(lin, ctx3, cond, candidates, allow_noreturn_optimization)
        if !(JS.head(cond) === :value && cond.value === true)
            cfg_emit_gotoifnot!(lin, end_label)
        end
        let saved = undef_save_cond_implied(lin)
            linearize_cfg_events!(lin, ctx3, ex3[2], candidates, allow_noreturn_optimization)
            undef_restore_cond_implied!(lin, saved)
        end
        cfg_emit_goto!(lin, top_label)
        cfg_emit_label!(lin, end_label)

    elseif k == :_do_while
        top_label = cfg_make_label!(lin)
        end_label = cfg_make_label!(lin)

        cfg_emit_label!(lin, top_label)
        let saved = undef_save_cond_implied(lin)
            linearize_cfg_events!(lin, ctx3, ex3[1], candidates, allow_noreturn_optimization)
            linearize_cfg_events!(lin, ctx3, ex3[2], candidates, allow_noreturn_optimization)
            undef_restore_cond_implied!(lin, saved)
        end
        cfg_emit_gotoifnot!(lin, end_label)
        cfg_emit_goto!(lin, top_label)
        cfg_emit_label!(lin, end_label)

    elseif k == :trycatchelse
        catch_label = cfg_make_label!(lin)
        end_label = cfg_make_label!(lin)

        # Try block can throw at any point
        cfg_emit_gotoifnot!(lin, catch_label)
        push!(lin.active_handler_labels, catch_label)
        let saved = undef_save_cond_implied(lin)
            linearize_cfg_events!(lin, ctx3, ex3[1], candidates, allow_noreturn_optimization)
            undef_restore_cond_implied!(lin, saved)
        end
        pop!(lin.active_handler_labels)
        # The `else` block runs only when the try body completes normally, and exceptions
        # thrown from it are not caught by this `catch`.
        if JS.numchildren(ex3) >= 3
            let saved = undef_save_cond_implied(lin)
                linearize_cfg_events!(lin, ctx3, ex3[3], candidates, allow_noreturn_optimization)
                undef_restore_cond_implied!(lin, saved)
            end
        end
        cfg_emit_goto!(lin, end_label)

        cfg_emit_label!(lin, catch_label)
        let saved = undef_save_cond_implied(lin)
            linearize_cfg_events!(lin, ctx3, ex3[2], candidates, allow_noreturn_optimization)
            undef_restore_cond_implied!(lin, saved)
        end

        cfg_emit_label!(lin, end_label)

    elseif k == :tryfinally
        finally_label = cfg_make_label!(lin)
        return_label = cfg_make_label!(lin)
        end_label = cfg_make_label!(lin)

        cfg_emit_gotoifnot!(lin, finally_label)
        # `active_finally_labels` is consulted by `:return` (and only spans the try body
        # — `pop!` happens before linearizing the finally body so a `return` inside
        # `finally` is not redirected back to itself).
        push!(lin.active_finally_labels, return_label)
        push!(lin.active_handler_labels, finally_label)
        let saved = undef_save_cond_implied(lin)
            linearize_cfg_events!(lin, ctx3, ex3[1], candidates, allow_noreturn_optimization)
            undef_restore_cond_implied!(lin, saved)
        end
        pop!(lin.active_handler_labels)
        pop!(lin.active_finally_labels)

        # Like lowering, linearize the finally body twice, since only the normal completion
        # of the try body continues after the statement. The other copy is entered at
        # `finally_label` by exceptions and at `return_label` by routed `return`s. After it,
        # an exception is rethrown to the enclosing handler and a `return` continues through
        # the enclosing finally; either leaves the lambda when there is none.
        saved = undef_save_cond_implied(lin)
        linearize_cfg_events!(lin, ctx3, ex3[2], candidates, allow_noreturn_optimization)
        after_normal = undef_save_cond_implied(lin)
        cfg_emit_goto!(lin, end_label)

        copy!(lin.cond_implies_defined, saved)
        cfg_emit_label!(lin, finally_label)
        lin.label_to_block[return_label] = lin.current_block
        has_return = any(((_, label),) -> label == return_label, lin.pending_gotos)
        linearize_cfg_events!(lin, ctx3, ex3[2], candidates, allow_noreturn_optimization)
        if !isempty(lin.active_handler_labels)
            push!(lin.pending_gotos, (lin.current_block, last(lin.active_handler_labels)))
        end
        if has_return
            if isempty(lin.active_finally_labels)
                cfg_add_edge!(lin, lin.current_block, cfg_new_block!(lin))
            else
                push!(lin.pending_gotos, (lin.current_block, last(lin.active_finally_labels)))
            end
        end
        cfg_switch_to_block!(lin, cfg_new_block!(lin))
        copy!(lin.cond_implies_defined, after_normal)

        cfg_emit_label!(lin, end_label)

    elseif k == :return
        if JS.numchildren(ex3) >= 1
            linearize_cfg_events!(lin, ctx3, ex3[1], candidates, allow_noreturn_optimization)
        end
        if isempty(lin.active_finally_labels)
            # Same pattern as `cfg_emit_goto!`, no-target `:break`, noreturn-call branch:
            # phantom has no incoming edges, so post-return code is unreachable.
            unreachable = cfg_new_block!(lin)
            cfg_switch_to_block!(lin, unreachable)
        else
            # `return` inside `try` runs the enclosing `finally` first, so route the edge
            # through it — otherwise an assignment preceding the return looks dead.
            cfg_emit_goto!(lin, last(lin.active_finally_labels))
        end

    elseif k == :block
        # Record each direct child as a "statement" tagged with both the
        # block where execution would arrive at the child (before) and the
        # block execution leaves it in (after). Used by reachability-based
        # unreachable analysis: a statement is reachable iff EITHER block
        # is reachable from the entry. Tracking the after-block matters for
        # forms like `:symboliclabel` whose own block becomes reachable
        # only via a `:symbolicgoto` edge resolved at finalization, even
        # though fall-through from the previous statement is unreachable.
        for child in JS.children(ex3)
            before_block = lin.current_block
            linearize_cfg_events!(lin, ctx3, child, candidates, allow_noreturn_optimization)
            after_block = lin.current_block
            push!(lin.statement_blocks, StatementRecord(before_block, after_block, child))
            # Inside a `try` body, model "exception thrown between statements escapes
            # to the enclosing handler" by branching to the innermost active catch or
            # finally at every statement boundary. Combined with the entry-bypass
            # `gotoifnot` of `:trycatchelse` and `:tryfinally`, this covers exception
            # escape at every point in the try body.
            if !isempty(lin.active_handler_labels)
                cfg_emit_gotoifnot!(lin, last(lin.active_handler_labels))
            end
        end

    else # Default: process all children
        for child in JS.children(ex3)
            linearize_cfg_events!(lin, ctx3, child, candidates, allow_noreturn_optimization)
        end

        if !isempty(allow_noreturn_optimization) &&
                is_noreturn_call(ctx3, ex3, allow_noreturn_optimization)
            unreachable = cfg_new_block!(lin)
            cfg_switch_to_block!(lin, unreachable)
        end
    end
end

# Check if `start` can reach any block in `targets` WITHOUT going through any block in `avoid`.
# `visited` is a caller-provided scratch `BitSet` that is cleared on entry.
function cfg_can_reach_avoiding(
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
function cfg_reachable_targets(
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

# Group `block_ids` by their event tree, in order of first appearance. An event in a
# finally body has a block per copy of the body (see `:tryfinally`).
function group_blocks_by_tree(block_ids, event_trees::Dict{Int,SyntaxTree})
    groups = Pair{SyntaxTree,BitSet}[]
    group_index = Dict{SyntaxTree,Int}()
    for block_id in block_ids
        i = get!(group_index, event_trees[block_id], length(groups) + 1)
        i > length(groups) && push!(groups, event_trees[block_id] => BitSet())
        push!(groups[i].second, block_id)
    end
    return groups
end

# Collect candidate variables captured by any nested closure.  The CFG
# places closure uses/assigns at the closure *definition* site (inside an
# uncertain branch), not at the call site.  This means a use inside a
# closure does not correctly block assignments that come after the closure
# definition, leading to false-positive dead store reports.  Variables
# identified here are excluded from dead store analysis.
function collect_closure_captured_vars(body::SyntaxTree, candidates::Set{JL.IdTag})
    result = Set{JL.IdTag}()
    traverse(body) do st::SyntaxTree
        JS.head(st) == :lambda || return nothing
        nested_lb = JL.lambda_bindings(st[1])
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
- `var_events::Dict{JL.IdTag, Vector{VarEvent}}`: per-variable event list indexed by
  `var_id`, avoiding O(blocks × candidates) scans during analysis
- `exit_blocks::BitSet`: CFG blocks with no successors, used for
  strict-undef queries during undef analysis
- `reachable::BitSet`: CFG blocks reachable from the lambda entry
"""
struct LambdaCFG
    lin::EventLinearizer
    candidates::Set{JL.IdTag}
    closure_captured::Set{JL.IdTag}
    var_events::Dict{JL.IdTag, Vector{VarEvent}}
    exit_blocks::BitSet
    reachable::BitSet
end

# Construct the `LambdaCFG` for `lambda_st3`.
# The returned CFG is shared between `analyze_local_def_use!` and `analyze_unreachable!`.
function build_lambda_cfg(
        ctx3::JL.VariableAnalysisContext, lambda_st3::SyntaxTree;
        allow_noreturn_optimization::Vector{Symbol} = Symbol[]
    )
    JS.head(lambda_st3) in (:lambda, :toplevel_lambda) || return nothing

    lambda_bindings = JL.lambda_bindings(lambda_st3[1])
    candidates = Set{JL.IdTag}()
    for (id, from_outer_lambda) in lambda_bindings.locals_capt
        from_outer_lambda && continue
        binfo = JL.get_binding(ctx3, id)
        if binfo.kind == :local
            push!(candidates, id)
        end
    end

    closure_captured = if JS.numchildren(lambda_st3) >= 4
        collect_closure_captured_vars(lambda_st3[4], candidates)
    else
        Set{JL.IdTag}()
    end

    lin = EventLinearizer()
    if JS.numchildren(lambda_st3) >= 4
        linearize_cfg_events!(
            lin, ctx3, lambda_st3[4], candidates, allow_noreturn_optimization)
    end
    cfg_finalize!(lin)

    # Pre-build var_id → event list index to avoid O(blocks × candidates)
    # scanning in the per-variable loop of `analyze_local_def_use!`.
    var_events = Dict{JL.IdTag, Vector{VarEvent}}()
    for block in lin.blocks
        evt = block.event
        isnothing(evt) && continue
        evt.var_id in candidates || continue
        evts = get!(Vector{VarEvent}, var_events, evt.var_id)
        push!(evts, VarEvent(evt.kind, block.id, evt.st))
    end

    # Pre-compute exit blocks (no successors) for strict-undef checks.
    exit_blocks = BitSet()
    for b in lin.blocks
        isempty(b.succs) && push!(exit_blocks, b.id)
    end

    reachable = compute_reachable_blocks(lin.blocks)

    return LambdaCFG(lin, candidates, closure_captured, var_events, exit_blocks, reachable)
end

# Reachability-based unreachable-statement detection on a built CFG. Adds to
# `unreachable_statements` every recorded statement whose entry and exit CFG blocks are
# both unreachable from the lambda entry. A statement in a finally body has a record per
# copy of the body (see `:tryfinally`) and is added only when every copy is unreachable.
function analyze_unreachable!(
        unreachable_statements::Set{SyntaxTree}, cfg::LambdaCFG
    )
    is_reachable(rec::StatementRecord) =
        rec.before_block in cfg.reachable || rec.after_block in cfg.reachable
    all(is_reachable, cfg.lin.statement_blocks) && return unreachable_statements
    reachable_statements = Set{SyntaxTree}(
        rec.st for rec in cfg.lin.statement_blocks if is_reachable(rec))
    for rec in cfg.lin.statement_blocks
        rec.st in reachable_statements || push!(unreachable_statements, rec.st)
    end
    return unreachable_statements
end

"""
    UndefInfo

Information about a local variable's definition/use sites and undef status.

Fields:
- `defs::Vector{SyntaxTree}`: Definition sites (assignments, function declarations)
- `undef_uses::Vector{Pair{Bool,SyntaxTree}}`: Use sites on undef paths.
  Each entry is `is_strict => use_tree`:
  - `true => tree`: Variable is definitely undefined at `tree`
  - `false => tree`: Variable may be undefined at `tree`
"""
struct UndefInfo
    defs::Vector{SyntaxTree}
    undef_uses::Vector{Pair{Bool,SyntaxTree}}
end

UndefInfo() = UndefInfo(SyntaxTree[], Pair{Bool,SyntaxTree}[])

"""
    DeadStoreInfo

Information about dead store assignments for a local variable.

Fields:
- `dead_defs::Vector{SyntaxTree}`: Assignment sites whose values are
  never read on any CFG path (dead stores).
"""
struct DeadStoreInfo
    dead_defs::Vector{SyntaxTree}
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

        defs = SyntaxTree[]
        assign_blocks = BitSet()       # for undef (includes :isdefined)
        real_assign_blocks = BitSet()  # for dead store (only :assign)
        use_blocks = BitSet()
        event_trees = Dict{Int,SyntaxTree}()
        for evt in evts
            event_trees[evt.block_id] = evt.st
            if evt.kind === :assign
                push!(defs, evt.st)
                push!(assign_blocks, evt.block_id)
                push!(real_assign_blocks, evt.block_id)
            elseif evt.kind === :isdefined
                push!(assign_blocks, evt.block_id)
            else # :use
                push!(use_blocks, evt.block_id)
            end
        end
        length(defs) > 1 && unique!(defs) # copies in finally bodies

        # --- Undef analysis ---
        if isempty(use_blocks)
            undef_info[binfo] = UndefInfo(defs, Pair{Bool,SyntaxTree}[])
        elseif isempty(assign_blocks)
            undef_uses = Pair{Bool,SyntaxTree}[
                true => use_tree for use_tree in unique(event_trees[ub] for ub in use_blocks)]
            undef_info[binfo] = UndefInfo(defs, undef_uses)
        else
            reached = cfg_reachable_targets(cfg.lin.blocks, 1, use_blocks, assign_blocks, visited)
            if !isempty(reached)
                bypass_targets = union(assign_blocks, cfg.exit_blocks)
                undef_uses = Pair{Bool,SyntaxTree}[]
                for (use_tree, ubs) in group_blocks_by_tree(reached, event_trees)
                    # Strict if every execution reaches the use before any assignment, i.e.
                    # no assignment or exit is reachable from the entry without the use.
                    is_strict = !cfg_can_reach_avoiding(
                        cfg.lin.blocks, 1, bypass_targets, ubs, visited)
                    push!(undef_uses, is_strict => use_tree)
                end
                undef_info[binfo] = UndefInfo(defs, undef_uses)
            else
                undef_info[binfo] = UndefInfo(defs, Pair{Bool,SyntaxTree}[])
            end
        end

        # --- Dead store analysis ---
        if var_id in cfg.closure_captured ||
           isempty(use_blocks) || isempty(real_assign_blocks)
            continue
        end
        dead_defs = SyntaxTree[]
        other_assigns = BitSet()
        reachable_def_blocks = Iterators.filter(in(cfg.reachable), real_assign_blocks)
        for (def_tree, def_block_ids) in group_blocks_by_tree(reachable_def_blocks, event_trees)
            is_dead = true
            for def_block_id in def_block_ids
                empty!(other_assigns)
                for ab in real_assign_blocks
                    ab != def_block_id && push!(other_assigns, ab)
                end
                if cfg_can_reach_avoiding(
                        cfg.lin.blocks, def_block_id, use_blocks, other_assigns, visited)
                    is_dead = false
                    break
                end
            end
            is_dead && push!(dead_defs, def_tree)
        end
        if !isempty(dead_defs)
            dead_store_info[binfo] = DeadStoreInfo(dead_defs)
        end
    end

    return
end

# Build the CFG for one `:lambda` and run all CFG-based analyses
# (undef, dead store, unreachable) on it, adding results directly
# to the caller-provided containers.
function analyze_lambda!(
        undef_info::Dict{JL.BindingInfo, UndefInfo},
        dead_store_info::Dict{JL.BindingInfo, DeadStoreInfo},
        unreachable_statements::Set{SyntaxTree},
        ctx3::JL.VariableAnalysisContext, lambda_st3::SyntaxTree,
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
`:lambda` it encounters, builds a per-lambda event-based CFG and runs
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

- **Unreachable-code analysis** — collects `:block` children whose
  CFG block is not reachable from the lambda entry. Returned as
  `Set{SyntaxTree}`. Because the CFG accurately models
  expression-nested control transfers, patterns like
  `return cnd ? @goto(fallback) : println("Return"); @label fallback; <code>`
  correctly keep `<code>` reachable via the goto edge.

Results from every visited lambda are merged into a single set of
result containers that are threaded through the traversal, so no
per-lambda intermediate dicts/sets are allocated and merged.

# Arguments
- `ctx3::JL.VariableAnalysisContext`: the variable-analysis context
  produced by JuliaLowering's scope-resolution pass.
- `st3::SyntaxTree`: scope-resolved syntax tree to analyze. Top-
  level (non-lambda) constructs are skipped.
- `allow_noreturn_optimization::Vector{Symbol}`: globals (typically
  function names) whose calls should be treated as guaranteed
  terminators by `:call` lowering — used to model `error(...)`-style
  helpers as block terminators when the user opts in.

# Notes
Macro-expanded code is best fed in after `_remove_macrocalls` for old-style macros
(see `src/utils/ast.jl`); raw macro output can place statements like `return` into
expression positions that this analysis is not designed to handle correctly.
"""
function analyze_all_lambdas(
        ctx3::JL.VariableAnalysisContext, st3::SyntaxTree;
        allow_noreturn_optimization::Vector{Symbol} = Symbol[]
    )
    undef_info = Dict{JL.BindingInfo, UndefInfo}()
    dead_store_info = Dict{JL.BindingInfo, DeadStoreInfo}()
    unreachable_statements = Set{SyntaxTree}()
    traverse(st3) do st3′::SyntaxTree
        if JS.head(st3′) in (:lambda, :toplevel_lambda)
            analyze_lambda!(
                undef_info, dead_store_info, unreachable_statements,
                ctx3, st3′, allow_noreturn_optimization)
        end
        return nothing
    end
    return (; undef_info, dead_store_info, unreachable_statements)
end
