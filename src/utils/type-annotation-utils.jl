"""
    format_opaque_closure_type(@nospecialize T) -> String

Format a `Core.OpaqueClosure{argt, rt}` type as `(args...) -> rt`.
Closures are rewritten to `Core.OpaqueClosure` by
[`Closure2Opaque.rewrite_local_closures_to_opaque`](@ref) so that [`TypeAnnotation`](@ref)
inference can reach the body precisely; that representation is purely an implementation
detail of the inference path — the user never wrote `OpaqueClosure` — so consumers that
want to surface the inferred closure type to the user should reformat it via this helper.
"""
function format_opaque_closure_type(@nospecialize T)
    argt, rt = @something unpack_opaque_closure_type(T) return string(T)::String
    arg_strs = String[string(p) for p in argt.parameters]
    return string("(", join(arg_strs, ", "), ") -> ", rt)
end

# Unpack `(argt::DataType, rt)` from a `Core.OpaqueClosure{argt, rt}` type.
# `Core.OpaqueClosure{...}` arrives here as a `UnionAll` whenever `rt` was left
# unconstrained (`Core.OpaqueClosure{Tuple{...}} where R` is the widened form
# `PartialOpaque` produces); unwrap and resolve the TypeVar to its upper bound
# so the caller works with a concrete `argt` / `rt` pair. Returns `nothing` if
# the shape doesn't match.
function unpack_opaque_closure_type(@nospecialize T)
    Tu = Base.unwrap_unionall(T)
    Tu isa DataType || return nothing
    length(Tu.parameters) ≥ 2 || return nothing
    argt = Tu.parameters[1]
    rt = Tu.parameters[2]
    rt isa TypeVar && (rt = rt.ub)
    argt isa DataType || return nothing
    argt <: Tuple || return nothing
    return Pair{DataType,Any}(argt, rt)
end

"""
    format_partial_opaque(po::Core.PartialOpaque) -> String

Like [`format_opaque_closure_type`](@ref), but pulls argument names from the
opaque closure's body method (via `po.parent::MethodInstance`) so the
displayed signature reads as `(x::Int, y::Int) -> Int` rather than the
type-only `(Int, Int) -> Int`. Argument-position `::Any` is dropped from the
output (`(x) -> Any`) since the bare name is already informative there;
return-position `Any` is preserved.
"""
function format_partial_opaque(po::Core.PartialOpaque)
    argt, rt = @something unpack_opaque_closure_type(po.typ) return string(po.typ)
    arg_types = Any[p for p in argt.parameters]
    nargs = length(arg_types)
    argnames = closure_argnames(po, nargs)
    arg_strs = if argnames === nothing
        String[string(t) for t in arg_types]
    else
        String[let t = arg_types[i], n = argnames[i]
            t === Any ? string(n) : string(n, "::", t)
        end for i in 1:nargs]
    end
    return string("(", join(arg_strs, ", "), ") -> ", rt)
end

# Try to recover the body method's argnames (excluding `#self#`) from a
# `Core.PartialOpaque`. `po.source` is the closure body's `Method` itself
# Returns `nothing` if `source` isn't a `Method` or its arg count doesn't
# line up with the closure's argtypes.
function closure_argnames(po::Core.PartialOpaque, nargs::Int)
    m = po.source
    m isa Method || return nothing
    names = try
        Base.method_argnames(m)
    catch
        return nothing
    end
    length(names) == nargs + 1 || return nothing
    return names[2:end]
end

"""
    resolve_global_const(context_module::Module, node::SyntaxTreeC, world::UInt) ->
        Core.Const | nothing

Best-effort static lookup of a `K"Identifier"` or `K"."` dotted-path node as a
`Core.Const` value by walking the dotted path against `context_module`. Used as a fallback
for features (signature help, call completion, definition, …) when the
[`TypeAnnotation`](@ref) pipeline can't supply a type — either because the
surrounding toplevel failed to lower (e.g. a method definition with unused
where-vars), or because the identifier doesn't survive lowering (most notably
macro names after macroexpansion).

Handles plain identifiers (`f`, `@m`), module-qualified macros (`Base.@show`)
and nested module paths (`Foo.Bar.f`). Returns `nothing` for anything more
complex (calls in node position, parametric type applications, …) — those
inputs need real inference, which the caller already attempted.

`world` pins the binding lookup so concurrent analysis updates can't make this
fallback observe a newer world than the rest of the request.
"""
function resolve_global_const(context_module::Module, node::SyntaxTreeC, world::UInt)
    if JS.kind(node) === JS.K"Identifier" && JS.hasattr(node, :name_val)
        sym = Symbol(node.name_val)
        Base.invoke_in_world(world, isdefinedglobal, context_module, sym) || return nothing
        return Core.Const(Base.invoke_in_world(world, getglobal, context_module, sym))
    elseif JS.kind(node) === JS.K"." && JS.numchildren(node) == 2
        prefix = node[1]
        suffix = node[2]
        # `Base.@show` parses with the macro identifier wrapped in `K"inert"`.
        if JS.kind(suffix) === JS.K"inert" && JS.numchildren(suffix) >= 1
            suffix = suffix[1]
        end
        prefix_const = resolve_global_const(context_module, prefix, world)
        prefix_const isa Core.Const || return nothing
        submod = prefix_const.val
        submod isa Module || return nothing
        return resolve_global_const(submod, suffix, world)
    end
    return nothing
end
