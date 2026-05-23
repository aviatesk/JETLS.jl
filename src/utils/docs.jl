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

Construct a `Base.Docs.Binding` for `parentmod.identifier`, working around an upstream bug
in `Base.Docs.Binding`'s alias resolution for renamed imports — `using X: y as z` /
`import X: y as z` make the stock constructor produce a binding to a non-existent `X.z`,
so doc lookup fails (see JuliaLang/julia#61869).

When `identifier`'s binding partition is an explicit by-name import — the only kinds
(`PARTITION_KIND_EXPLICIT` / `PARTITION_KIND_IMPORTED`) where `as`-rename is syntactically
possible — resolve to the canonical `(mod, name)` via the partition's restriction and feed
that to the stock `Base.Docs.Binding`. Other kinds fall through to the stock constructor
unchanged.
"""
function DocsBinding(parentmod::Module, identifier::Symbol, world::UInt)
    if Base.invoke_in_world(world, isdefinedglobal, parentmod, identifier)
        bpart = Base.lookup_binding_partition(world, GlobalRef(parentmod, identifier))
        if Base.is_some_explicit_imported(Base.binding_kind(bpart))
            imported = Base.partition_restriction(bpart)::Core.Binding
            return Base.invoke_in_world(
                world, Base.Docs.Binding, imported.globalref.mod, imported.globalref.name)
        end
    end
    return Base.invoke_in_world(world, Base.Docs.Binding, parentmod, identifier)
end

"""
    lookup_doc_stripped(object, world::UInt) -> Markdown.MD

`Base.Docs.doc(object)` with the leading "No documentation found for ..."
placeholder paragraph stripped, so hover/completion surfaces don't show that
noise text for undocumented bindings while still keeping the auto-generated
method/type summary that follows it.
"""
function lookup_doc_stripped(@nospecialize(object), world::UInt)
    md = Base.invoke_in_world(world, Base.Docs.doc, object)::Markdown.MD
    # Tied to Base's exact placeholder phrasing (`Base.Docs.summarize` /
    # `bindingsummary`) — if upstream ever changes that wording, this filter
    # silently stops working.
    filtered = filter(md.content) do @nospecialize(m)
        m isa Markdown.Paragraph || return true
        content = m.content
        (content isa Vector{Any} && !isempty(content)) || return true
        content1 = content[1]
        content1 isa String || return true
        return !startswith(content1, "No documentation found for")
    end
    return Markdown.MD(filtered, md.meta)
end

"""
    narrow_doc_lookup(binding::Base.Docs.Binding, sig, world::UInt) -> Markdown.MD | Nothing

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
function narrow_doc_lookup(binding::Base.Docs.Binding, @nospecialize(sig), world::UInt)
    matched = Base.Docs.DocStr[]
    interface = Base.Docs.DocStr[]
    for mod in Base.Docs.modules
        dict = @something Base.invoke_in_world(world, Base.Docs.meta, mod;
            autoinit=false)::Union{Nothing,IdDict{Any,Any}} continue
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
    md = Base.invoke_in_world(world, Base.Docs.catdoc, map(Base.Docs.parsedoc, results)...)
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
Returns `nothing` when the binding is undefined or when lookup throws.

When the binding exists but has no docstring, [`lookup_doc_stripped`](@ref) strips
the "No documentation found for ..." placeholder paragraph so the
auto-generated method/type summary still surfaces without the placeholder
noise.
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
            return lookup_doc_stripped(binding, world)
        end
        return narrow_doc_lookup(binding, sig, world)
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
`using`-aliases land on the actual owner's `MultiDoc`. When `sig === nothing`,
returns the [`lookup_doc_stripped`](@ref) result as a fallback.

The `Function`/`Module`/`Type` restriction skips lookup entirely for
literals, struct instances, `nothing` / `missing` etc. — values whose
`Base.Docs.doc` output is *only* the placeholder with no useful summary
to keep. For documentable values that nonetheless carry no docstring,
[`lookup_doc_stripped`](@ref) handles the placeholder removal.
"""
function lookup_doc_for_value(@nospecialize(v), @nospecialize(sig), world::UInt)
    v isa Function || v isa Module || v isa Type || return nothing
    try
        if sig === nothing
            return lookup_doc_stripped(v, world)
        end
        binding = Base.invoke_in_world(world, Base.Docs.aliasof, v, typeof(v))
        binding isa Base.Docs.Binding || return nothing
        return narrow_doc_lookup(binding, sig, world)
    catch
        return nothing
    end
end
