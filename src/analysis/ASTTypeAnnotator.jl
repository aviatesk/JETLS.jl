using Core.IR

struct ASTTypeAnnotatorToken end

struct ASTTypeAnnotator <: CC.AbstractInterpreter
    toptree::JL.SyntaxTree
    topmi::Core.MethodInstance
    limit_aggressive_inference::Bool
    world::UInt
    inf_params::CC.InferenceParams
    opt_params::CC.OptimizationParams
    inf_cache::Vector{CC.InferenceResult}
    function ASTTypeAnnotator(
            toptree::JL.SyntaxTree,
            topmi::Core.MethodInstance,
            limit_aggressive_inference::Bool = false;
            world::UInt = Base.get_world_counter(),
            inf_params::CC.InferenceParams = CC.InferenceParams(;
                aggressive_constant_propagation = true
            ),
            opt_params::CC.OptimizationParams = CC.OptimizationParams(),
            inf_cache::Vector{CC.InferenceResult} = CC.InferenceResult[]
        )
        return new(toptree, topmi, limit_aggressive_inference, world, inf_params, opt_params, inf_cache)
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

# ASTTypeAnnotator analyzes a top-level frame, so better to not bail out from it
CC.bail_out_toplevel_call(::ASTTypeAnnotator, ::CC.InferenceLoopState, ::CC.InferenceState) = false

# `ASTTypeAnnotator` aggressively resolves global bindings to enable reasonable completions
# for lines like `Mod.a.|` (where `|` is the cursor position).
# Aggressive binding resolution poses challenges for the inference cache validation
# (until https://github.com/JuliaLang/julia/issues/40399 is implemented).
# To avoid the cache validation issues, `ASTTypeAnnotator` only allows aggressive binding
# resolution for top-level frame representing REPL input code and for child uncached frames
# that are constant propagated from the top-level frame ("repl-frame"s). This works, even if
# those global bindings are not constant and may be mutated in the future, since:
# a.) "repl-frame"s are never cached, and
# b.) mutable values are never observed by any cached frames.
#
# `ASTTypeAnnotator` also aggressively concrete evaluate `:inconsistent` calls within
# "repl-frame" to provide reasonable completions for lines like `Ref(Some(42))[].|`.
# Aggressive concrete evaluation allows us to get accurate type information about complex
# expressions that otherwise can not be constant folded, in a safe way, i.e. it still
# doesn't evaluate effectful expressions like `pop!(xs)`.
# Similarly to the aggressive binding resolution, aggressive concrete evaluation doesn't
# present any cache validation issues because "repl-frame" is never cached.
#
# `ASTTypeAnnotator` is specifically used by `repl_eval_ex`, where all top-level frames are
# `repl_frame` always. However, this assumption wouldn't stand if `ASTTypeAnnotator` were to
# be employed, for instance, by `typeinf_ext_toplevel`.
is_top_frame(sv::CC.InferenceState) = sv.linfo.def isa Module && sv.cache_mode === CC.CACHE_MODE_NULL

function is_call_stack_uncached(sv::CC.InferenceState)
    CC.is_cached(sv) && return false
    parent = CC.frame_parent(sv)
    parent === nothing && return true
    return is_call_stack_uncached(parent::CC.InferenceState)
end

# aggressive global binding resolution within `repl_frame`
function CC.abstract_eval_globalref(
        interp::ASTTypeAnnotator, g::GlobalRef, bailed::Bool, sv::CC.InferenceState
    )
    # Ignore saw_latestworld
    if (interp.limit_aggressive_inference ? is_top_frame(sv) : is_call_stack_uncached(sv))
        partition = CC.abstract_eval_binding_partition!(interp, g, sv)
        if CC.is_defined_const_binding(CC.binding_kind(partition))
            return CC.RTEffects(Core.Const(CC.partition_restriction(partition)), Union{}, CC.EFFECTS_TOTAL)
        else
            b = convert(Core.Binding, g)
            if CC.binding_kind(partition) == CC.PARTITION_KIND_GLOBAL && isdefined(b, :value)
                return CC.RTEffects(Core.Const(b.value), Union{}, CC.EFFECTS_TOTAL)
            end
        end
        return CC.RTEffects(Union{}, UndefVarError, CC.EFFECTS_THROWS)
    end
    return @invoke CC.abstract_eval_globalref(
        interp::CC.AbstractInterpreter, g::GlobalRef, bailed::Bool, sv::CC.InferenceState
    )
end

# aggressive concrete evaluation for `:inconsistent` frames within `repl_frame`
function CC.concrete_eval_eligible(
        interp::ASTTypeAnnotator, @nospecialize(f), result::CC.MethodCallResult,
        arginfo::CC.ArgInfo, sv::CC.InferenceState
    )
    # if (interp.limit_aggressive_inference ? is_top_frame(sv) : is_call_stack_uncached(sv))
    #     neweffects = CC.Effects(result.effects; consistent=CC.ALWAYS_TRUE)
    #     result = CC.MethodCallResult(result.rt, result.exct, neweffects, result.edge,
    #                                  result.edgecycle, result.edgelimited, result.volatile_inf_result)
    # end
    ret = @invoke CC.concrete_eval_eligible(
        interp::CC.AbstractInterpreter, f::Any, result::CC.MethodCallResult,
        arginfo::CC.ArgInfo, sv::CC.InferenceState
    )
    if ret === :semi_concrete_eval
        # while the base eligibility check probably won't permit semi-concrete evaluation
        # for `ASTTypeAnnotator` (given it completely turns off optimization),
        # this ensures we don't inadvertently enter irinterp
        ret = :none
    end
    return ret
end

# allow constant propagation for mutable constants
function CC.const_prop_argument_heuristic(interp::ASTTypeAnnotator, arginfo::CC.ArgInfo, sv::CC.InferenceState)
    if !interp.limit_aggressive_inference
        any(@nospecialize(a) -> isa(a, Core.Const), arginfo.argtypes) && return true # even if mutable
    end
    return @invoke CC.const_prop_argument_heuristic(interp::CC.AbstractInterpreter, arginfo::CC.ArgInfo, sv::CC.InferenceState)
end

function _infer_method_body!(
        innertree::JL.SyntaxTree, mi::Core.MethodInstance, src::Core.CodeInfo,
        limit_aggressive_inference::Bool, argtypes::Union{Nothing, Vector{Any}} = nothing
    )
    innerinterp = ASTTypeAnnotator(innertree, mi, limit_aggressive_inference)
    result = if isnothing(argtypes)
        CC.InferenceResult(mi)
    else
        CC.InferenceResult(mi, argtypes, nothing)
    end
    frame = CC.InferenceState(result, src, #=cache=#:no, innerinterp)
    CC.typeinf(innerinterp, frame)
    return nothing
end

function resolve_method_signature_arg(sv::CC.InferenceState, x::Core.SSAValue)
    ret = resolve_method_signature_arg(sv, sv.src.code[x.id])
    ret !== nothing && return ret
    ssa_type = sv.src.ssavaluetypes[x.id]
    ssa_type isa Core.Const && return ssa_type.val
    ssa_type isa CC.PartialTypeVar && return ssa_type.tv
    return nothing
end
resolve_method_signature_arg(sv::CC.InferenceState, x::Core.Const) =
    resolve_method_signature_arg(sv, x.val)
resolve_method_signature_arg(::CC.InferenceState, x::QuoteNode) = x.value
function resolve_method_signature_arg(::CC.InferenceState, x::GlobalRef)
    isdefined(x.mod, x.name) && return getfield(x.mod, x.name)
    return nothing
end
function resolve_method_signature_arg(sv::CC.InferenceState, x::Expr)
    x.head === :call || return nothing
    callee = x.args[1]
    callee isa GlobalRef || return nothing
    callee.mod === Core || return nothing
    if callee.name === :svec
        args = Any[]
        for i in 2:length(x.args)
            arg = resolve_method_signature_arg(sv, x.args[i])
            arg === nothing && return nothing
            push!(args, arg)
        end
        return Core.svec(args...)
    elseif callee.name === :Typeof && length(x.args) == 2
        arg = resolve_method_signature_arg(sv, x.args[2])
        return arg === Any ? Any : typeof(arg)
    elseif callee.name === :apply_type && length(x.args) >= 2
        head = resolve_method_signature_arg(sv, x.args[2])
        head isa Type || head === Union || return nothing
        params = Any[]
        for i in 3:length(x.args)
            p = resolve_method_signature_arg(sv, x.args[i])
            p === nothing && return nothing
            push!(params, p)
        end
        return try
            Core.apply_type(head, params...)
        catch
            nothing
        end
    end
    return nothing
end
resolve_method_signature_arg(::CC.InferenceState, x::TypeVar) = x
function resolve_method_signature_arg(sv::CC.InferenceState, x::Core.SlotNumber)
    slot_type = CC.argextype(x, sv.src, sv.sptypes)
    slot_type isa Core.Const && return slot_type.val
    slot_type isa CC.PartialTypeVar && return slot_type.tv
    for i in 1:length(sv.src.code)
        stmt = sv.src.code[i]
        if stmt isa Expr && stmt.head === :(=) && stmt.args[1] == x
            ssa_type = sv.src.ssavaluetypes[i]
            ssa_type isa Core.Const && return ssa_type.val
            ssa_type isa CC.PartialTypeVar && return ssa_type.tv
        end
    end
    return nothing
end
resolve_method_signature_arg(::CC.InferenceState, ::Any) = nothing

function annotate_method_definition!(
        interp::ASTTypeAnnotator, stmt::Expr, stmt_tree::JS.SyntaxTree, sv::CC.InferenceState
    )
    length(stmt.args) == 3 || return nothing
    src = stmt.args[3]
    src isa Core.CodeInfo || return nothing
    JS.numchildren(stmt_tree) == 3 || return nothing
    inner_tree = stmt_tree[3]
    JS.kind(inner_tree) === JS.K"code_info" || return nothing

    msig = resolve_method_signature_arg(sv, stmt.args[2])
    msig isa Core.SimpleVector || return nothing
    length(msig) ≥ 2 || return nothing

    atypes = msig[1]
    atypes isa Core.SimpleVector || return nothing
    msig[2] isa Core.SimpleVector || return nothing

    argtypes = Vector{Any}(undef, length(atypes))
    for i in 1:length(atypes)
        atype = atypes[i]
        if atype isa Type
            argtypes[i] = atype
        elseif atype isa TypeVar
            argtypes[i] = atype.ub
        else
            return nothing
        end
    end

    method_instance = @ccall jl_method_instance_for_thunk(
        src::Any, sv.mod::Any
    )::Ref{Core.MethodInstance}
    _infer_method_body!(inner_tree, method_instance, src, interp.limit_aggressive_inference, argtypes)
    return nothing
end


function CC.builtin_tfunction(interp::ASTTypeAnnotator, @nospecialize(f::Core.Builtin), argtypes::Vector{Any}, sv::CC.InferenceState)
    if f === Core.svec
        argvals = Any[]
        for i = 1:length(argtypes)
            argtype = argtypes[i]
            if argtype isa Core.Const
                push!(argvals, argtype.val)
            elseif argtype isa CC.PartialTypeVar && argtype.lb_certain && argtype.ub_certain
                push!(argvals, argtype.tv)
            else
                argvals = nothing
                break
            end
        end
        if !isnothing(argvals)
            return Core.Const(Core.svec(argvals...))
        end
    end
    return @invoke CC.builtin_tfunction(interp::CC.AbstractInterpreter, f::Core.Builtin, argtypes::Vector{Any}, sv::CC.InferenceState)
end

function is_core_toplevel_declaration_call(stmt::Expr)
    stmt.head === :call || return false
    isempty(stmt.args) && return false
    callee = stmt.args[1]
    return callee isa GlobalRef &&
           callee.mod === Core &&
           (callee.name === :declare_global || callee.name === :declare_const)
end
is_core_toplevel_declaration_call(::Any) = false

@inline function CC.abstract_eval_basic_statement(
        interp::ASTTypeAnnotator, @nospecialize(stmt), sstate::CC.StatementState,
        frame::CC.InferenceState, result::Union{Nothing, CC.Future{CC.RTEffects}}
    )
    # Ignore :latestworld effect completely
    ret = @invoke CC.abstract_eval_basic_statement(
        interp::CC.AbstractInterpreter, stmt::Any, sstate::CC.StatementState,
        frame::CC.InferenceState, result::Union{Nothing, CC.Future{CC.RTEffects}}
    )
    if ret isa CC.AbstractEvalBasicStatementResult
        rt = ret.rt
        # JuliaLowering emits `Core.declare_global` / `Core.declare_const` as
        # bookkeeping statements. On Julia 1.12, the base evaluator returns
        # `Union{}` for these declaration ops in this path, and
        # `ASTTypeAnnotator` would otherwise copy that into statement
        # annotations. Normalize them to `Nothing` instead.
        if rt === Union{} && is_core_toplevel_declaration_call(stmt)
            rt = Nothing
        end
        ret = CC.AbstractEvalBasicStatementResult(
            rt, ret.exct, ret.effects, ret.changes, ret.refinements,
            #=currsaw_latestworld=#false
        )
    end
    return ret
end

function annotate_types!(citree::JL.SyntaxTree, frame::CC.InferenceState)
    ncode = length(frame.src.code)
    ntree = JS.numchildren(citree)
    nstmts = min(ncode, ntree)
    for i = 1:nstmts
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
            treeref = stmttree
            if stmt.head === :(=)
                lhs = stmt.args[1]
                if lhs isa Core.SlotNumber
                    JS.setattr!(treeref[1], :type, stmttype)
                end
                stmt = stmt.args[2]
                stmt isa Expr || continue
                treeref = treeref[2]
            end
            for i = 1:length(stmt.args)
                arg = stmt.args[i]
                if arg isa Core.SlotNumber
                    argtyp = CC.argextype(arg, frame.src, frame.sptypes)
                    JS.setattr!(treeref[i], :type, argtyp)
                end
            end
            if stmt.head === :call
                JS.setattr!(treeref, :type, stmttype)
            end
        elseif stmt isa ReturnNode
            rettyp = CC.argextype(stmt.val, frame.src, frame.sptypes)
            JS.setattr!(stmttree, :type, rettyp)
        end
    end
end

function CC.finishinfer!(frame::CC.InferenceState, interp::ASTTypeAnnotator, cycleid::Int)
    ret = @invoke CC.finishinfer!(frame::CC.InferenceState, interp::CC.AbstractInterpreter, cycleid::Int)
    if frame.linfo === interp.topmi
        annotate_types!(interp.toptree[1], frame)
        nstmts = min(length(frame.src.code), JS.numchildren(interp.toptree[1]))
        for i = 1:nstmts
            stmt = frame.src.code[i]
            stmt isa Core.Const && stmt.val isa Expr && (stmt = stmt.val)
            stmt isa Expr || continue
            stmt.head === :method || continue
            annotate_method_definition!(interp, stmt, interp.toptree[1][i], frame)
        end
    end
    return ret
end

# Perform some post-hoc mutation on lowered code, as expected by some abstract interpretation
# routines, especially for `:foreigncall` and `:cglobal`.
function resolve_toplevel_symbols!(src::Core.CodeInfo, context_module::Module)
    @ccall jl_resolve_definition_effects_in_ir(
        #=jl_array_t *stmts=# src.code::Any,
        #=jl_module_t *m=# context_module::Any,
        #=jl_svec_t *sparam_vals=# Core.svec()::Any,
        #=jl_value_t *binding_edge=# C_NULL::Ptr{Cvoid},
        #=int binding_effects=# 0::Int)::Cvoid
    return src
end

function construct_toplevel_mi(src::Core.CodeInfo, context_module::Module)
    resolve_toplevel_symbols!(src, context_module)
    return @ccall jl_method_instance_for_thunk(src::Any, context_module::Any)::Ref{Core.MethodInstance}
end

prepare_type_attr(st::JL.SyntaxTree) = let g = JL.syntax_graph(st)
    attrs = Dict(pairs(g.attributes))
    attrs[:type] = Dict{Int, Any}()
    return JL.SyntaxTree(JL.SyntaxGraph(g.edge_ranges, g.edges, attrs), st._id)
end

function _infer_toplevel_tree(
        ctx3, st3::JS.SyntaxTree, context_module::Module;
        limit_aggressive_inference::Bool = false
    )
    lwrst = try
        ctx4, st4 = JL.convert_closures(ctx3, st3)
        _, st5 = JL.linearize_ir(ctx4, st4)
        st5
    catch e
        @error "Lowering failed" e
        return nothing
    end |> prepare_type_attr
    lwr = JL.to_lowered_expr(lwrst)

    Meta.isexpr(lwr, :thunk) || error("Unexpected lowering result")
    src = lwr.args[1]::Core.CodeInfo

    mi = construct_toplevel_mi(src, context_module)

    interp = ASTTypeAnnotator(lwrst, mi, limit_aggressive_inference)
    result = CC.InferenceResult(mi)
    frame = CC.InferenceState(result, src, #=cache=#:no, interp)

    CC.typeinf(interp, frame) # TODO Use the fixed world here

    return interp, frame
end
infer_toplevel_tree(args...) = first(@something _infer_toplevel_tree(args...) return nothing).toptree
