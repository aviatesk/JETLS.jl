# CFG-based undef analysis for scope-resolved syntax tree `st3`.
#
# This analysis determines whether local variables may be used before being
# assigned, using CFG path analysis. The result is a three-valued status:
# - `false`: Variable is definitely defined at all uses (all CFG paths to uses go through assignments)
# - `true`: Variable is definitely undefined at some use (use precedes assignment in straight-line code)
# - `nothing`: Variable may or may not be defined (conservative - undef CFG path exists but use may not execute)
#
# The key technique is placing each assignment/use event in its own "event block"
# (not traditional basic blocks - each block contains at most one event).
# Event ordering is thus represented by CFG edges, allowing us to check:
# "Can entry reach a use without going through any assignment?" as a graph reachability problem.

"""
    UndefInfo

Information about a local variable's definition/use sites and undef status.

Fields:
- `defs::Vector{JS.SyntaxTree}`: Definition sites (assignments, function declarations)
- `uses::Vector{JS.SyntaxTree}`: Use sites (reads of the variable)
- `undef::Union{Nothing,Bool}`: Undef status
  - `false`: Variable is definitely defined at all uses
  - `true`: Variable is definitely undefined at some use
  - `nothing`: Variable may or may not be defined (conservative)
"""
struct UndefInfo
    defs::Vector{JS.SyntaxTree}
    uses::Vector{JS.SyntaxTree}
    undef::Union{Nothing,Bool}
end

UndefInfo(; undef::Union{Nothing,Bool}=nothing) = UndefInfo(JS.SyntaxTree[], JS.SyntaxTree[], undef)

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
    function EventLinearizer()
        blocks = EventBlock[EventBlock(1)]
        new(blocks, 1, Dict{Int,Int}(), Tuple{Int,Int}[], 0)
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

function linearize_for_undef!(
        lin::EventLinearizer, ctx3::JL.VariableAnalysisContext, ex::JS.SyntaxTree,
        candidates::Set{JL.IdTag}, allow_throw_optimization::Bool
    )
    k = JS.kind(ex)

    if k == JS.K"BindingId"
        var_id = ex.var_id
        if var_id in candidates
            undef_emit_event!(lin, :use, var_id, ex)
        end

    elseif JS.is_leaf(ex) || JL.is_quoted(ex)
        # Nothing to do

    elseif k == JS.K"="
        # Process RHS first
        linearize_for_undef!(lin, ctx3, ex[2], candidates, allow_throw_optimization)
        # Then record assignment
        lhs = ex[1]
        if JS.kind(lhs) == JS.K"BindingId"
            var_id = lhs.var_id
            if var_id in candidates
                undef_emit_event!(lin, :assign, var_id, lhs)
            end
        end

    elseif k == JS.K"function_decl"
        # Process the RHS first (method_defs)
        for i in 2:JS.numchildren(ex)
            linearize_for_undef!(lin, ctx3, ex[i], candidates, allow_throw_optimization)
        end
        # Then emit the assign event for the function name
        lhs = ex[1]
        if JS.kind(lhs) == JS.K"BindingId"
            var_id = lhs.var_id
            if var_id in candidates
                undef_emit_event!(lin, :assign, var_id, lhs)
            end
        end

    elseif k == JS.K"isdefined"
        # @isdefined(var) checks if var is defined but doesn't actually use it
        # (won't cause UndefVarError), so don't emit use event for the BindingId inside

    elseif k == JS.K"lambda"
        # Handle captured variables from outer scope by recursing into lambda body
        # We don't know when/if the closure is called, so wrap in an uncertain branch
        nested_lb = ex.lambda_bindings
        has_outer_capture = any(is_capt && id in candidates for (id, is_capt) in nested_lb.locals_capt)
        if has_outer_capture && JS.numchildren(ex) >= 3
            skip_label = undef_make_label!(lin)
            undef_emit_gotoifnot!(lin, skip_label)
            linearize_for_undef!(lin, ctx3, ex[3], candidates, allow_throw_optimization)
            undef_emit_label!(lin, skip_label)
        end

    elseif k == JS.K"local"
        # local declarations don't use or assign

    elseif k == JS.K"decl"
        # decl nodes: the BindingId is declaration, not use; only visit type expression
        if JS.numchildren(ex) >= 2
            linearize_for_undef!(lin, ctx3, ex[2], candidates, allow_throw_optimization)
        end

    elseif k == JS.K"if" || k == JS.K"elseif"
        # if cond then_branch [else_branch]
        cond = ex[1]
        linearize_for_undef!(lin, ctx3, cond, candidates, allow_throw_optimization)

        end_label = undef_make_label!(lin)
        else_label = undef_make_label!(lin)

        undef_emit_gotoifnot!(lin, else_label)

        # Special case: if @isdefined(var), the var is definitely defined in the true branch
        if JS.kind(cond) == JS.K"isdefined" && JS.numchildren(cond) >= 1
            isdefined_arg = cond[1]
            if JS.kind(isdefined_arg) == JS.K"BindingId"
                var_id = isdefined_arg.var_id
                if var_id in candidates
                    # Emit :isdefined hint - affects CFG analysis but not a real def
                    undef_emit_event!(lin, :isdefined, var_id, isdefined_arg)
                end
            end
        end

        linearize_for_undef!(lin, ctx3, ex[2], candidates, allow_throw_optimization)
        undef_emit_goto!(lin, end_label)

        undef_emit_label!(lin, else_label)
        if JS.numchildren(ex) >= 3
            linearize_for_undef!(lin, ctx3, ex[3], candidates, allow_throw_optimization)
        end

        undef_emit_label!(lin, end_label)

    elseif k == JS.K"_while"
        top_label = undef_make_label!(lin)
        end_label = undef_make_label!(lin)

        undef_emit_label!(lin, top_label)
        linearize_for_undef!(lin, ctx3, ex[1], candidates, allow_throw_optimization)
        undef_emit_gotoifnot!(lin, end_label)
        linearize_for_undef!(lin, ctx3, ex[2], candidates, allow_throw_optimization)
        undef_emit_goto!(lin, top_label)
        undef_emit_label!(lin, end_label)

    elseif k == JS.K"_do_while"
        top_label = undef_make_label!(lin)
        end_label = undef_make_label!(lin)

        undef_emit_label!(lin, top_label)
        linearize_for_undef!(lin, ctx3, ex[1], candidates, allow_throw_optimization)
        linearize_for_undef!(lin, ctx3, ex[2], candidates, allow_throw_optimization)
        undef_emit_gotoifnot!(lin, end_label)
        undef_emit_goto!(lin, top_label)
        undef_emit_label!(lin, end_label)

    elseif k == JS.K"trycatchelse"
        catch_label = undef_make_label!(lin)
        end_label = undef_make_label!(lin)

        # Try block can throw at any point
        undef_emit_gotoifnot!(lin, catch_label)
        linearize_for_undef!(lin, ctx3, ex[1], candidates, allow_throw_optimization)
        undef_emit_goto!(lin, end_label)

        undef_emit_label!(lin, catch_label)
        linearize_for_undef!(lin, ctx3, ex[2], candidates, allow_throw_optimization)
        if JS.numchildren(ex) >= 3
            linearize_for_undef!(lin, ctx3, ex[3], candidates, allow_throw_optimization)
        end

        undef_emit_label!(lin, end_label)

    elseif k == JS.K"tryfinally"
        finally_label = undef_make_label!(lin)
        end_label = undef_make_label!(lin)

        undef_emit_gotoifnot!(lin, finally_label)
        linearize_for_undef!(lin, ctx3, ex[1], candidates, allow_throw_optimization)

        undef_emit_label!(lin, finally_label)
        linearize_for_undef!(lin, ctx3, ex[2], candidates, allow_throw_optimization)

        undef_emit_label!(lin, end_label)

    elseif k == JS.K"return"
        if JS.numchildren(ex) >= 1
            linearize_for_undef!(lin, ctx3, ex[1], candidates, allow_throw_optimization)
        end
        unreachable = undef_new_block!(lin)
        undef_switch_to_block!(lin, unreachable)

    elseif k == JS.K"break"
        unreachable = undef_new_block!(lin)
        undef_switch_to_block!(lin, unreachable)

    elseif allow_throw_optimization && k == JS.K"call"
        # Process all children (function and arguments)
        for child in JS.children(ex)
            linearize_for_undef!(lin, ctx3, child, candidates, allow_throw_optimization)
        end
        # Check if this is a call to global `throw` - treat as noreturn
        # Required to support the `@assert @isdefined(var) "compiler hint to tell the definedness of `var`"` pattern
        if JS.numchildren(ex) >= 1
            callee = ex[1]
            if JS.kind(callee) == JS.K"BindingId"
                binfo = JL.get_binding(ctx3, callee.var_id)
                if binfo.kind === :global && binfo.name == "throw"
                    unreachable = undef_new_block!(lin)
                    undef_switch_to_block!(lin, unreachable)
                end
            end
        end

    else
        # Default: process all children
        for child in JS.children(ex)
            linearize_for_undef!(lin, ctx3, child, candidates, allow_throw_optimization)
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

"""
    analyze_undef(ctx3::JL.VariableAnalysisContext, ex::JS.SyntaxTree;
                  allow_throw_optimization::Bool=false) -> Dict{JL.BindingInfo, UndefInfo}

CFG-aware undef analysis local bindings.

For each local variable in the lambda `ex`, determines:
- Definition and use sites (as `SyntaxTree` nodes)
- Undef status:
  - `false`: Variable is definitely defined at all uses
  - `true`: Variable is definitely undefined at some use
  - `nothing`: Variable may or may not be defined (conservative)

Each assign/use event is placed in its own event block, so event ordering
is represented by CFG edges. This enables checking reachability to determine
if a use can be reached from entry without going through any assignment.

When `allow_throw_optimization=true`, calls to global `throw` are treated as
noreturn (like `return`), allowing patterns like `@assert @isdefined(y)` to work
as definedness hints.

Returns a dictionary mapping `BindingInfo` to `UndefInfo` for all
analyzed local variables.
"""
function analyze_undef(ctx3::JL.VariableAnalysisContext, ex::JS.SyntaxTree;
                       allow_throw_optimization::Bool=false)
    result = Dict{JL.BindingInfo, UndefInfo}()

    JS.kind(ex) == JS.K"lambda" || return result

    # Collect candidate variables: all local variables in this lambda
    lambda_bindings = ex.lambda_bindings
    candidates = Set{JL.IdTag}()
    for (id, from_outer_lambda) in lambda_bindings.locals_capt
        from_outer_lambda && continue
        binfo = JL.get_binding(ctx3, id)
        if binfo.kind == :local
            push!(candidates, id)
        end
    end

    isempty(candidates) && return result

    lin = EventLinearizer()
    if JS.numchildren(ex) >= 3
        body = ex[3]
        linearize_for_undef!(lin, ctx3, body, candidates, allow_throw_optimization)
    end
    undef_finalize_cfg!(lin)

    # For each candidate, collect defs/uses and check if all uses are dominated by assignments
    for var_id in candidates
        binfo = JL.get_binding(ctx3, var_id)

        # Collect all defs and uses for this variable
        defs = JS.SyntaxTree[]
        uses = JS.SyntaxTree[]
        assign_blocks = Set{Int}()
        use_blocks = Set{Int}()
        for block in lin.blocks
            (event_kind, id, st) = @something block.event continue
            id == var_id || continue
            if event_kind === :assign
                push!(defs, st)
                push!(assign_blocks, block.id)
            elseif event_kind === :isdefined
                # :isdefined hints affect CFG analysis but shouldn't appear in defs list
                push!(assign_blocks, block.id)
            else # :use
                push!(uses, st)
                push!(use_blocks, block.id)
            end
        end

        # No uses means "definitely defined at all uses" (vacuously true)
        if isempty(use_blocks)
            result[binfo] = UndefInfo(defs, uses, false)
            continue
        end

        # No assignments means all uses are before any definition
        if isempty(assign_blocks)
            result[binfo] = UndefInfo(defs, uses, true)
            continue
        end

        # Check if entry can reach any use while avoiding all assignment blocks
        # If yes, there's a CFG path where the variable is used without being assigned
        has_undef_path = undef_can_reach_avoiding(lin.blocks, 1, use_blocks, assign_blocks)

        if has_undef_path
            # CFG path exists. Check if the use is "must-execute" (on all paths).
            # If use is must-execute and precedes all assignments, it's definitely undef.
            # Otherwise, we can't prove it's definitely executed (e.g., correlated branches).

            # Find the earliest must-execute use block
            min_must_execute_use_id = typemax(Int)
            for ub in use_blocks
                if undef_is_must_execute(lin.blocks, ub)
                    min_must_execute_use_id = min(min_must_execute_use_id, ub)
                end
            end

            if min_must_execute_use_id != typemax(Int)
                # Check if all assignments come after the must-execute use
                all_assigns_after = true
                for assign in assign_blocks
                    if assign < min_must_execute_use_id
                        all_assigns_after = false
                        break
                    end
                end
                if all_assigns_after
                    # Use is must-execute and all assignments come after → definitely undef
                    result[binfo] = UndefInfo(defs, uses, true)
                else
                    # Some assignment might come before the use on some paths
                    result[binfo] = UndefInfo(defs, uses, nothing)
                end
            else
                # Use is not must-execute (conditional), can't prove definitely undef
                result[binfo] = UndefInfo(defs, uses, nothing)
            end
        else
            # All CFG paths to any use go through an assignment
            result[binfo] = UndefInfo(defs, uses, false)
        end
    end

    return result
end

"""
    analyze_undef_all_lambdas(
        ctx3::JL.VariableAnalysisContext, st3::JS.SyntaxTree;
        allow_throw_optimization::Bool = false
        ) -> Dict{JL.BindingInfo, UndefInfo}

Analyze undef status for all lambdas in the syntax tree.

This traverses the syntax tree and calls `analyze_undef` on each lambda,
merging the results into a single dictionary. Each lambda must be analyzed
separately because `analyze_undef` only analyzes that lambda's own local
variables (not captured from outer scope). The recursion into nested lambdas
within `linearize_for_undef!` handles uses/assigns of captured variables,
but doesn't analyze the nested lambda's own locals.

When `allow_throw_optimization=true`, calls to global `throw` are treated as
noreturn. The caller should verify that `throw === Core.throw` in the current
module context before enabling this optimization.
"""
function analyze_undef_all_lambdas(
        ctx3::JL.VariableAnalysisContext, st3::JS.SyntaxTree;
        allow_throw_optimization::Bool = false
    )
    result = Dict{JL.BindingInfo, UndefInfo}()
    traverse(st3) do st3′::JS.SyntaxTree
        if JS.kind(st3′) == JS.K"lambda"
            merge!(result, analyze_undef(ctx3, st3′; allow_throw_optimization))
        end
        return nothing
    end
    return result
end
