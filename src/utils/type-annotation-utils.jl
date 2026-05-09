"""
    infer_type_at_range(st0_top::SyntaxTreeC, mod::Module, rng::UnitRange{<:Integer})

Run inference on the top-level subtree that contains `rng` and look up its
inferred type via the [`TypeAnnotation`](@ref) pipeline.
Returns `nothing` if lowering or inference fails, or no `:type` annotation
exists at `rng`.

The shared cursor-to-type bridge for LSP features (go to type definition,
hover-type, …) — pair with [`select_target_for_type_query`](@ref) to obtain
the right `rng` for a given cursor position.
"""
function infer_type_at_range(
        st0_top::SyntaxTreeC, mod::Module, rng::UnitRange{<:Integer}
    )
    return iterate_toplevel_tree(st0_top) do st0::SyntaxTreeC
        rng ⊆ JS.byte_range(st0) || return nothing
        result = @something(
            get_inferrable_tree(st0, mod; caller="infer_type_at_range"),
            return traversal_terminator)
        (; ctx3, st3) = result
        inferred = @something infer_toplevel_tree(ctx3, st3, mod) return traversal_terminator
        ctx = InferredTreeContext(inferred, st3)
        return TraversalReturn(get_type_for_range(ctx, rng); terminate=true)
    end
end

"""
    value_based_doc(@nospecialize typ) -> Union{Markdown.MD, Nothing}

Look up a docstring from the *value* a lattice element resolves to. Fires when:
- `typ isa Core.Const` (the value is `typ.val`), or
- `typ` is a singleton `Type` (the value is `typ.instance`).

Then only retrieves the docstring when the resolved value is a `Function`,
`Module`, or `Type` — these are the kinds of values for which
`Base.Docs.doc(v)` returns a meaningful, value-specific docstring rather
than falling back to type-level documentation. Returns `nothing` for
literals, struct instances, `nothing`/`missing`, etc., to avoid surfacing
the noisy `"No documentation found.\\n# Int64\\n…"` fallback that
`Base.Docs.doc` produces for non-documented values.
"""
function value_based_doc(@nospecialize typ)
    v = if typ isa Core.Const
        typ.val
    elseif Base.issingletontype(typ)
        typ.instance
    else
        return nothing
    end
    v isa Function || v isa Module || v isa Type || return nothing
    return try
        @invokelatest(Base.Docs.doc(v))::Markdown.MD
    catch
        return nothing
    end
end

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
    argt, rt = @something unpack_opaque_closure_type(T) return string(T)
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
