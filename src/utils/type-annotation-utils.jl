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
