const HOVER_REGISTRATION_ID = "jetls-hover"
const HOVER_REGISTRATION_METHOD = "textDocument/hover"

function hover_options()
    return HoverOptions()
end

function hover_registration()
    return Registration(;
        id = HOVER_REGISTRATION_ID,
        method = HOVER_REGISTRATION_METHOD,
        registerOptions = HoverRegistrationOptions(;
            documentSelector = DEFAULT_DOCUMENT_SELECTOR,
        )
    )
end

# For dynamic registrations during development
# unregister(currently_running, Unregistration(;
#     id = HOVER_REGISTRATION_ID,
#     method = HOVER_REGISTRATION_METHOD))
# register(currently_running, hover_registration())

function handle_HoverRequest(
        server::Server, msg::HoverRequest, cancel_flag::CancelFlag
    )
    state = server.state
    uri = msg.params.textDocument.uri
    pos = adjust_position(state, uri, msg.params.position)

    result = get_file_info(state, uri, cancel_flag)
    if isnothing(result)
        return send(server, HoverResponse(; id = msg.id, result = null))
    elseif result isa ResponseError
        return send(server, HoverResponse(; id = msg.id, result = nothing, error = result))
    end
    fi = result

    st0_top = build_syntax_tree(fi)
    offset = xy_to_offset(fi, pos)
    (; mod, postprocessor) = get_context_info(state, uri, pos)
    soft_scope = is_notebook_cell_uri(state, uri)

    expr_hover = expression_hover(state, fi, uri, st0_top, offset, mod, postprocessor; soft_scope)
    expr_hover === nothing || return send(server, HoverResponse(;
        id = msg.id, result = expr_hover))

    return send(server, HoverResponse(;
        id = msg.id, result = something(keyword_hover(state, fi, uri, pos), null)))
end

# Unified hover entry. Whether the cursor is on a local binding, a global
# identifier, or a complex expression (dot-chain, call result, struct field)
# is handled in a single flow:
#
# - A type query at the cursor's byte range produces an `expr :: T` header
#   (skipped when `T` is an implementation-detail type — see
#   [`hover_type_string`](@ref)).
# - A value-based docstring lookup ([`value_based_doc`](@ref)) fires whenever
#   inference resolves the expression to a documented `Function` / `Module` /
#   `Type` (covers globals, cross-file aliases, struct-field access via
#   inference, etc.).
# - For non-local bindings and complex expressions, a binding-based docstring
#   lookup is added as well (preserves docstrings attached to value bindings
#   like `"""docs""" const x = 42`). Duplicates against the value-based doc
#   are removed via Markdown equality.
#
# Local bindings show a kind tag (`(argument)` / `(local)` / `(static
# parameter)`) so the binding's role in scope is visible even when the type
# alone wouldn't carry that information.
function expression_hover(
        state::ServerState, fi::FileInfo, uri::URI, st0_top::SyntaxTreeC, offset::Int,
        mod::Module, postprocessor::LSPostProcessor;
        soft_scope::Bool = false
    )
    binding_result = select_target_binding(st0_top, offset, mod; soft_scope)
    if binding_result !== nothing
        (; ctx3, binding) = binding_result
        binfo = JL.get_binding(ctx3, binding)
        node = binding
        is_local = is_local_binding(binfo)
        header = "$(binding_kind_label(binfo.kind)) $(binfo.name)"
    else
        node = @something select_target_for_type_query(st0_top, offset) return nothing
        binfo = nothing
        is_local = false
        header = JS.sourcetext(node)
    end

    typ = infer_type_at_range(st0_top, mod, JS.byte_range(node))
    type_str = hover_type_string(typ, JS.sourcetext(node))

    docs = Markdown.MD[]
    if !is_local
        bdoc = binfo !== nothing ?
            doc_for_binding(mod, Symbol(binfo.name)) : lookup_binding_doc(node, st0_top, mod)
        bdoc === nothing || push!(docs, bdoc)
    end
    vdoc = value_based_doc(typ)
    if vdoc !== nothing && !any(==(vdoc), docs)
        push!(docs, vdoc)
    end

    # The header line (`<expr> [:: T]` in a code block) is shown whenever the
    # cursor is on a binding — even without a type the kind tag / name is
    # informative — or whenever the inferred type itself is displayable. For a
    # bare complex expression with no displayable type, we omit the header
    # since the expression's source text is already visible in the editor.
    show_header = binding_result !== nothing || type_str !== nothing
    if !show_header && isempty(docs)
        return nothing
    end

    io = IOBuffer()
    if show_header
        println(io, "```julia")
        type_str === nothing ? println(io, header) : println(io, header, " :: ", type_str)
        println(io, "```")
    end
    if !isempty(docs)
        show_header && println(io, "\n---\n")
        for (i, doc) in enumerate(docs)
            i == 1 || println(io, "\n---\n")
            print(io, postprocessor(doc))
        end
    end
    contents = MarkupContent(; kind = MarkupKind.Markdown, value = String(take!(io)))
    range, _ = unadjust_range(state, uri, jsobj_to_range(node, fi))
    return Hover(; contents, range)
end

binding_kind_label(kind::Symbol) =
    kind === :argument ? "(argument)" :
    kind === :static_parameter ? "(static parameter)" :
    kind === :local ? "(local)" : "(global)"

# Convert a lattice element returned by `infer_type_at_range` into a string
# suitable for display in a hover. Returns `nothing` for "implementation
# detail" lattice elements that the user shouldn't see — `Type{T}` (the value
# is itself a type), and function singletons whose name already appears in
# `source_text` as a whole word (e.g. hovering on `sin│` would otherwise show
# `sin :: typeof(sin)`, which is just noise). For function singletons whose
# name is *not* visible in the source — `s[2]│` resolving to `cos`, or
# `mycos│` aliased from `cos` — the singleton type is returned as
# `typeof(<name>)` so the hover header announces which value the expression
# resolves to without conflating value and type positions.
function hover_type_string(@nospecialize(typ), source_text::AbstractString)
    typ === nothing && return nothing
    typ isa Core.PartialOpaque && return format_partial_opaque(typ)
    widened = CC.widenconst(typ)
    widened === Union{} && return nothing
    widened <: Core.OpaqueClosure && return format_opaque_closure_type(widened)
    if widened <: Function && CC.issingletontype(widened)
        # `\b` fails on names ending in `!` like `push!` since `!(` is
        # non-word/non-word with no transition; spell out identifier
        # boundaries and use `\Q\E` so operator names like `+` are literal.
        name = String(nameof(widened.instance)::Symbol)
        if occursin(Regex("(?<!\\w)\\Q" * name * "\\E(?![\\w!])"), source_text)
            return nothing
        end
        return string(widened)
    end
    CC.isType(widened) && return nothing
    return string(widened)::String
end

# Look up the docstring for `parentmod.name`. Returns `nothing` on lookup
# failure (rather than the "No documentation found" placeholder Markdown.MD
# `Base.Docs.doc` would otherwise return — that placeholder is preserved by
# direct call sites that explicitly want the user-visible "No documentation
# found" message).
function doc_for_binding(parentmod::Module, name::Symbol)
    return try
        @invokelatest(Base.Docs.doc(DocsBinding(parentmod, name)))::Markdown.MD
    catch
        return nothing
    end
end

# Resolve `node` to a `(parentmod, identifier)` pair and look up its binding-
# based docstring. Returns `nothing` if the node isn't a plain identifier or a
# dot expression whose left-hand side resolves to a `Module` value.
function lookup_binding_doc(node::SyntaxTreeC, st0_top::SyntaxTreeC, mod::Module)
    parentmod = mod
    identifier_node = node
    if JS.kind(node) === JS.K"." && JS.numchildren(node) ≥ 2
        parentmod = @something resolve_dot_prefix_module(node[1], st0_top, mod) return nothing
        identifier_node = node[2]
        # EST wraps the RHS of dot expressions in `K"inert"`
        if JS.kind(identifier_node) === JS.K"inert" && JS.numchildren(identifier_node) ≥ 1
            identifier_node = identifier_node[1]
        end
    end
    JS.is_identifier(identifier_node) || return nothing
    return doc_for_binding(parentmod, Symbol(identifier_node.name_val)::Symbol)
end

# Resolve a dot expression's left-hand side to a `Module` value. Tries a direct
# `getglobal` for plain identifiers first — this covers macro-name dot prefixes
# like `Base.@inline` whose argument-position `Base` isn't typed by inference —
# and falls back to `infer_type_at_range` for nested chains (`Base.Compiler.…`).
function resolve_dot_prefix_module(dotprefix::SyntaxTreeC, st0_top::SyntaxTreeC, mod::Module)
    if JS.is_identifier(dotprefix)
        name = Symbol(dotprefix.name_val)::Symbol
        if @invokelatest(isdefinedglobal(mod, name))
            v = @invokelatest(getglobal(mod, name))
            v isa Module && return v
        end
    end
    typ = infer_type_at_range(st0_top, mod, JS.byte_range(dotprefix))
    typ isa Core.Const || return nothing
    v = typ.val
    v isa Module || return nothing
    return v
end

@eval function DocsBinding(parentmod::Module, identifier::Symbol)
    if invokelatest(isdefinedglobal, parentmod, identifier)
        x = invokelatest(getglobal, parentmod, identifier)
        if x isa Module && nameof(x) !== identifier
            # HACK: skip the binding resolution logic performed by the `Base.Docs.Binding` constructor
            # for modules that are given different names within this context
            return $(Expr(:new, Base.Docs.Binding, :parentmod, :identifier))
        end
    end
    return Base.Docs.Binding(parentmod, identifier)
end

# Returns a `Hover` for a keyword token at `pos`, or `nothing` if the cursor
# isn't on a recognized keyword. Used as the fallback when no identifier
# resolves at the cursor.
function keyword_hover(state::ServerState, fi::FileInfo, uri::URI, pos::Position)
    tok = @something token_at_offset(fi, pos) return nothing
    byterng = JS.byte_range(tok)
    tokstr = String(fi.parsed_stream.textbuf[byterng])
    haskey(KEYWORD_DOCS, tokstr) || return nothing
    contents = KEYWORD_DOCS[tokstr]
    range = Range(;
        start = offset_to_xy(fi, first(byterng)),
        var"end" = offset_to_xy(fi, last(byterng)+1))
    range, _ = unadjust_range(state, uri, range)
    return Hover(; contents, range)
end
