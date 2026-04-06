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

function _infer_method(interp::ASTTypeAnnotator, e::Expr, sstate::CC.StatementState, sv::CC.InferenceState)
    ea = e.args
    na = length(ea)
    na == 3 || return nothing
    src = ea[3]
    src isa Core.CodeInfo || return 2

    treesttmt = interp.toptree[1][sv.currpc]
    JS.numchildren(treesttmt) == na || return 3
    innertree = treesttmt[3]
    JS.kind(innertree) === JS.K"code_info" || return 4

    argtypes = CC.collect_argtypes(interp, ea, sstate, sv)
    argtypes !== nothing || return 5
    msig = argtypes[2]
    msig isa Core.Const || return 6
    msigval = msig.val
    msigval isa Core.SimpleVector || return 7
    length(msigval) ≥ 2 || return 8
    atypes, tvars = msigval
    atypes isa Core.SimpleVector || return 9
    tvars isa Core.SimpleVector || return 10
    tt = form_method_signature(atypes, tvars)
    match = Base._which(tt; world = CC.get_inference_world(interp), raise = false)
    isnothing(match) && return 11
    newmi = CC.specialize_method(match)

    interp = ASTTypeAnnotator(innertree, newmi, interp.limit_aggressive_inference)
    result = CC.InferenceResult(newmi)
    frame = CC.InferenceState(result, src, #=cache=#:no, interp)
    CC.typeinf(interp, frame)
    return nothing
end

# Infer the inner method body with its method signatures
function infer_method(interp::ASTTypeAnnotator, e::Expr, sstate::CC.StatementState, sv::CC.InferenceState)
    ret = @something _infer_method(interp, e, sstate, sv) return nothing
    JETLS_DEV_MODE && @info "Inner method inference failed" reason = ret
    return nothing
end

function form_method_signature(atypes::Core.SimpleVector, sparams::Core.SimpleVector)
    atype = Tuple{atypes...}
    for i = length(sparams):-1:1
        atype = UnionAll(sparams[i]::TypeVar, atype)
    end
    return atype
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

@inline function CC.abstract_eval_basic_statement(
        interp::ASTTypeAnnotator, @nospecialize(stmt), sstate::CC.StatementState,
        frame::CC.InferenceState, result::Union{Nothing, CC.Future{CC.RTEffects}}
    )
    if stmt isa Expr && stmt.head === :method && length(stmt.args) ≥ 3 && interp.topmi === frame.linfo
        infer_method(interp, stmt, sstate, frame)
    end
    # Ignore :latestworld effect completely
    ret = @invoke CC.abstract_eval_basic_statement(
        interp::CC.AbstractInterpreter, stmt::Any, sstate::CC.StatementState,
        frame::CC.InferenceState, result::Union{Nothing, CC.Future{CC.RTEffects}}
    )
    if ret isa CC.AbstractEvalBasicStatementResult
        ret = CC.AbstractEvalBasicStatementResult(
            ret.rt, ret.exct, ret.effects, ret.changes, ret.refinements,
            #=currsaw_latestworld=#false
        )
    end
    return ret
end

function annotate_types!(citree::JL.SyntaxTree, frame::CC.InferenceState)
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
