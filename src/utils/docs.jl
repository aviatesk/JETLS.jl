# Sig-aware docstring lookup utilities shared between hover and the
# method-signature completion resolver. Both surfaces want the same
# narrowing semantics: at a call site, show only docs that match the
# dispatched method's signature, not every overload `Base.Docs.doc`
# falls back to when no `sig <: msig` match is found.

"""
    method_doc_sig(m::Method) -> Type | Nothing

Args-only Tuple-type signature for `m`, stripping the leading `typeof(f)`
(or `Type{T}` for type constructors) so the result matches the shape
`Base.Docs.MultiDoc` keys with — see `MultiDoc`'s docstring. Preserves
the method's `UnionAll` wrappers (parametric methods like `f(x::T) where
T <: Real` store their docs as `Tuple{T} where T <: Real`).
"""
function method_doc_sig(m::Method)
    vars = TypeVar[]
    body = m.sig
    while body isa UnionAll
        push!(vars, body.var)
        body = body.body
    end
    body isa DataType || return nothing
    body <: Tuple || return nothing
    length(body.parameters) >= 1 || return nothing
    tail = Tuple{body.parameters[2:end]...}
    while !isempty(vars)
        v = pop!(vars)
        tail = UnionAll(v, tail)
    end
    return tail
end

"""
    DocsBinding(parentmod::Module, identifier::Symbol, world::UInt) -> Base.Docs.Binding

Construct a `Base.Docs.Binding` for `parentmod.identifier`, working around
an upstream bug in `Base.Docs.Binding`'s alias resolution for renamed
imports — `using X: X as Y` makes the stock constructor produce a binding
to a non-existent `X.Y`, so doc lookup fails (see JuliaLang/julia#55119).

This wrapper bypasses that resolution when `identifier` resolves to a
renamed `Module` (`nameof(x) !== identifier`), keeping the binding tied
to `parentmod.identifier` so doc lookup can find the actual value's docs.
Function-rename (`using Base: cos as mycos`) hits the same upstream bug
but isn't handled here — hover routes those through
[`lookup_doc_for_value`](@ref) instead.
"""
function DocsBinding end
@eval function DocsBinding(parentmod::Module, identifier::Symbol, world::UInt)
    if Base.invoke_in_world(world, isdefinedglobal, parentmod, identifier)
        x = Base.invoke_in_world(world, getglobal, parentmod, identifier)
        if x isa Module && nameof(x) !== identifier
            # Bypass `Base.Docs.Binding`'s buggy alias resolution for
            # renamed-module imports — see docstring above.
            return $(Expr(:new, Base.Docs.Binding, :parentmod, :identifier))
        end
    end
    return Base.invoke_in_world(world, Base.Docs.Binding, parentmod, identifier)
end

"""
    narrow_doc_lookup(binding::Base.Docs.Binding, sig) -> Markdown.MD | Nothing

Narrowed sig-aware variant of `Base.Docs.doc(binding, sig)`.
The Base implementation falls back to *all* docs from *all* loaded modules
when no stored sig `msig` satisfies `sig <: msig`, which inflates the hover
with unrelated overloads (e.g. `Compiler.EscapeAnalysis.push!(::IntDisjointSet)`
showing up on a `push!(::Vector, x)` hover).

Walk every loaded module's `MultiDoc` for `binding` and partition the docs into
method-specific matches and interface declarations (`msig === Union{}`).

Match a stored sig `msig` against `sig` by non-empty type intersection.
Intersection captures both directions naturally:
- `msig` describes a more general case that covers `sig` (e.g. an
  `(::Any, ::Any)` doc covering an `(::Int, ::Int)` dispatch).
- `msig` describes a more specific case under `sig` (e.g. dispatch lands
  on `filter(f, a::AbstractArray)` whose own method carries no doc, but
  `Base`'s `filter(f, a)` text is attached to `Tuple{Any, Array{T,N}}` —
  intersection surfaces that doc as a useful proxy).

Intersection also tolerates the `Union{Tuple{N}, Tuple{T}, Tuple{…}} where
{T, N}` shape that the docsystem produces for stored sigs with type
variables — those scaffolding `Tuple{T}` / `Tuple{N}` parts break direct
`<:` checks in either direction.

Method-specific matches win when available; otherwise interface docs serve
as fallback. Returns `nothing` when neither category produces a match.
"""
function narrow_doc_lookup(binding::Base.Docs.Binding, @nospecialize(sig))
    matched = Base.Docs.DocStr[]
    interface = Base.Docs.DocStr[]
    for mod in Base.Docs.modules
        dict = @something Base.Docs.meta(mod; autoinit=false) continue
        haskey(dict, binding) || continue
        multidoc = dict[binding]::Base.Docs.MultiDoc
        for msig in multidoc.order
            if msig === Union{}
                push!(interface, multidoc.docs[msig])
            elseif typeintersect(sig, msig) !== Union{}
                push!(matched, multidoc.docs[msig])
            end
        end
    end
    results = isempty(matched) ? interface : matched
    isempty(results) && return nothing
    md = Base.Docs.catdoc(map(Base.Docs.parsedoc, results)...)
    md isa Markdown.MD || return nothing
    md.meta[:results] = results
    md.meta[:binding] = binding
    md.meta[:typesig] = sig
    return md
end

"""
    lookup_doc_for_binding(parentmod::Module, name::Symbol, sig, world::UInt) ->
        doc::Markdown.MD or nothing

Look up the docstring for `parentmod.name`, narrowed by `sig` when provided
(via [`narrow_doc_lookup`](@ref); no narrowing when `sig === nothing`).
Returns `nothing` on lookup failure rather than the "No documentation found"
placeholder `Markdown.MD` that `Base.Docs.doc` would otherwise return — that
placeholder is preserved by direct call sites that explicitly want the
user-visible "No documentation found" message.
"""
function lookup_doc_for_binding(
        parentmod::Module, name::Symbol, @nospecialize(sig), world::UInt
    )
    binding = DocsBinding(parentmod, name, world)
    if !Base.invoke_in_world(world, isdefinedglobal, binding.mod, binding.var)
        return nothing
    end
    try
        if sig === nothing
            return Base.invoke_in_world(world, Base.Docs.doc, binding)::Markdown.MD
        end
        return Base.invoke_in_world(world, narrow_doc_lookup, binding, sig)
    catch
        return nothing
    end
end
function lookup_doc_for_binding(binfo::JL.BindingInfo, @nospecialize(sig), world::UInt)
    mod = @something binfo.mod return nothing
    return lookup_doc_for_binding(mod, Symbol(binfo.name), sig, world)
end

"""
    lookup_doc_for_value(v, sig, world::UInt) -> Markdown.MD | Nothing

Look up sig-narrowed docs for a `Function` / `Module` / `Type` value `v`,
resolving its canonical `Base.Docs.Binding` via `aliasof` so cross-module
`using`-aliases land on the actual owner's `MultiDoc`. Returns the full
`Base.Docs.doc` result when `sig === nothing` (no narrowing requested).

Restricting to `Function`/`Module`/`Type` keeps literals, struct instances,
`nothing` / `missing` etc. from surfacing the "No documentation found"
placeholder that `Base.Docs.doc` produces for arbitrary values.
"""
function lookup_doc_for_value(@nospecialize(v), @nospecialize(sig), world::UInt)
    v isa Function || v isa Module || v isa Type || return nothing
    try
        if sig === nothing
            return Base.invoke_in_world(world, Base.Docs.doc, v)::Markdown.MD
        end
        binding = Base.invoke_in_world(world, Base.Docs.aliasof, v, typeof(v))
        binding isa Base.Docs.Binding || return nothing
        return Base.invoke_in_world(world, narrow_doc_lookup, binding, sig)
    catch
        return nothing
    end
end
