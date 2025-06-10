module Resolver

export resolve_node

using ..JETLS: CC, JET, JS, JL, REPL
using ..JETLS.Analyzer

"""
    resolve_node(analyzer::LSAnalyzer, context_module::Module, s0::Union{JS.SyntaxNode,JL.SyntaxTree})
    resolve_node(analyzer::LSAnalyzer, context_module::Module, ex::Expr)

Resolves the type of `s0` in the `context_module` that has been analyzed by the `analyzer`.
When resolution is successful, it returns the type of the `node` in the extended lattice (e.g., `Int`, `Const`),
and when resolution fails, it returns `nothing`.
Note that `s0` is just a raw `SyntaxTree` or `SyntaxNode` that has not been lowered.

This utility has a critical flaw: it cannot correctly handle bindings that are shadowed in local scopes.
That is, `s0` is always resolved in the global scope of `context_module`.
Therefore, it may return incorrect results in cases like:
```julia
function foo(x)
    sin = cos
    y = sin(x) # resolve_node(analyzer, context_module, :(sin)) would return `Const(sin)` instead of `Const(cos)`
    return y
end
```

For this reason, significant changes are expected in the near future.
Specifically, `AnalysisContext` will store type inference results for each method analyzed by `LSAnalyzer`,
and `resolve_node` will be implemented as a query against these type inference results.
However, this implementation requires JL to be able to lower arbitrary user code,
which first requires integration of JL into Base.
"""
resolve_node(analyzer::LSAnalyzer, context_module::Module, s0::Union{JS.SyntaxNode,JL.SyntaxTree}) =
    resolve_node(analyzer, context_module, Expr(s0))
function resolve_node(analyzer::LSAnalyzer, context_module::Module, @nospecialize ex)
    # TODO use JL once it supports general macro expansion
    if Meta.isexpr(ex, :toplevel)
        return nothing
    elseif REPL.REPLCompletions.expr_has_error(ex)
        return nothing
    end
    lwr = try
        Meta.lower(context_module, ex)
    catch # macro expansion may fail, etc.
        return nothing
    end

    if lwr isa Symbol
        if !(@invokelatest isdefinedglobal(context_module, lwr))
            return nothing
        end
        res = @invokelatest getfield(context_module, lwr)
        if res isa JET.AbstractBindingState
            return isdefined(res, :typ) ? res.typ : nothing
        end
        return Core.Const(res)
    end
    Meta.isexpr(lwr, :thunk) || return nothing
    length(lwr.args) == 1 || return nothing
    src = only(lwr.args)
    src isa Core.CodeInfo || return nothing

    REPL.REPLCompletions.resolve_toplevel_symbols!(src, context_module)
    mi = @ccall jl_method_instance_for_thunk(src::Any, context_module::Any)::Ref{Core.MethodInstance}

    interp = JET.ToplevelAbstractAnalyzer(analyzer, falses(length(src.code)))
    result = CC.InferenceResult(mi)
    JET.init_result!(interp, result)
    frame = CC.InferenceState(result, src, #=cache=#:no, interp)
    CC.typeinf(interp, frame)

    result = frame.result.result
    result === Union{} && return nothing # for whatever reason, callers expect this as the Bottom and/or Top type instead
    return result
end

end # module Resolver
