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

    hover = @something get_hover(state, fi, uri, pos) begin
        return send(server, HoverResponse(;
            id = msg.id, result = something(keyword_hover(state, fi, uri, pos), null)))
    end
    return send(server, HoverResponse(; id = msg.id, result = hover))
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
function get_hover(
        state::ServerState, fi::FileInfo, uri::URI, pos::Position;
        context_module::Union{Nothing,Module} = nothing
    )
    st0_top = build_syntax_tree(fi)
    offset = xy_to_offset(fi, pos)
    (; postprocessor, world) = ctx_info = get_context_info(state, uri, pos)
    # `context_module` kwarg overrides the analysis-derived module — exposed
    # for tests so they can seed the lookup with a pre-populated module
    # without running full-analysis on the test source.
    context_module = something(context_module, ctx_info.context_module)
    soft_scope = is_notebook_cell_uri(state, uri)
    binding_result = select_target_binding(st0_top, offset, context_module; soft_scope)
    if binding_result !== nothing
        (; ctx3, binding) = binding_result
        binfo = JL.get_binding(ctx3, binding)
        node = binding
        is_local = is_local_binding(binfo)
    else
        node = @something select_target_for_type_query(st0_top, offset) return nothing
        binfo = nothing
        is_local = false
    end

    # When `node` is the callee of an enclosing call (`func│(x)`, `Foo.bar│(x)`),
    # show the full call expression in the header and query its return type —
    # doc lookup keeps using `node` so the identifier-based resolution stays.
    callee_call = enclosing_call_for_matches(st0_top, node)
    display_node = (callee_call === nothing || callee_call === node) ? node : callee_call
    if display_node !== node
        header = JS.sourcetext(display_node)
    elseif binfo !== nothing
        header = "$(binding_kind_label(binfo.kind)) $(binfo.name)"
    else
        header = JS.sourcetext(node)
    end

    display_rng = JS.byte_range(display_node)
    ctx = build_inferred_context_for_range(st0_top, context_module, display_rng;
        world, caller="get_hover", cache=fi.inferred_context_cache)
    type_str = typ = display_typ = nothing
    if ctx !== nothing
        display_typ = get_type_for_range(ctx, display_rng)
        if display_typ !== nothing
            type_str = hover_type_string(display_typ, JS.sourcetext(display_node))
        end
        # Value-based doc lookup runs against the callee's type
        # (`sv.value` → `Core.Const(sin)`), not the call's return type.
        typ = display_node === node ? display_typ : get_type_for_range(ctx, JS.byte_range(node))
    end
    # Fallback when the TypeAnnotation pipeline can't supply a type
    if typ === nothing
        typ = resolve_global_const(context_module, node, world)
        if typ !== nothing && type_str === nothing && display_node === node
            type_str = hover_type_string(typ, JS.sourcetext(display_node))
        end
    end

    sig = ctx === nothing ? nothing : call_doc_sig(ctx, st0_top, node)

    docs = Markdown.MD[]
    # Cursor past the closing punctuation of a call-like surface (`f(x)│`,
    # `xs[i]│`, `[a, b]│`) — suppress the doc body and show only the
    # `expr :: T` header.
    is_call_like_position = JS.kind(node) in _CALL_LIKE_KINDS
    if !is_call_like_position
        if !is_local
            bdoc = binfo !== nothing ?
                lookup_doc_for_binding(binfo, sig, world) :
                lookup_doc_for_identifier(node, context_module, ctx, sig, world)
            bdoc === nothing || append!(docs, flatten_docs(bdoc))
        end
        vdoc = lookup_doc_for_inferred_value(typ, sig, world)
        if vdoc !== nothing
            for doc in flatten_docs(vdoc)
                doc in docs || push!(docs, doc)
            end
        end
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

    lattice_detail = type_str === nothing || display_typ === nothing ? nothing :
        hover_lattice_detail(display_typ)
    io = IOBuffer()
    if show_header
        println(io, "```julia")
        if type_str === nothing
            println(io, header)
        else
            print(io, header, " :: ", postprocessor(type_str))
            lattice_detail !== nothing && print(io, "  ", lattice_detail)
            println(io)
        end
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
    range, _ = unadjust_range(state, uri, jsobj_to_range(display_node, fi))
    return Hover(; contents, range)
end

# Unpack an aggregate `Markdown.MD` (what `Base.Docs.doc` returns when a
# binding has multiple stored docs — `.content` holds one `Markdown.MD` per
# doc) into a `Vector{Markdown.MD}`, so the hover renderer can insert a
# `\n---\n` separator between each. Single docs — whose `.content` holds
# leaf markdown elements (`Paragraph`, `CodeBlock`, …) rather than nested
# `Markdown.MD`s — pass through as a one-element list.
function flatten_docs(md::Markdown.MD)
    docs = Markdown.MD[]
    if all(@nospecialize(d)->d isa Markdown.MD, md.content)
        for doc in md.content
            push!(docs, doc::Markdown.MD)
        end
    else
        push!(docs, md)
    end
    return docs
end

binding_kind_label(kind::Symbol) =
    kind === :argument ? "(argument)" :
    kind === :static_parameter ? "(static parameter)" :
    kind === :local ? "(local)" : "(global)"

function hover_lattice_detail(@nospecialize(typ))
    # `hover_type_string` already formats `PartialOpaque` as a closure shape, hiding
    # the underlying `OpaqueClosure` internals. Do not re-append the raw lattice
    # element as a comment and expose the internal representation again.
    typ isa Core.PartialOpaque && return nothing
    typ === CC.widenconst(typ) && return nothing
    return format_lattice_element_comment(typ)
end

# Convert a lattice element from `get_type_for_range` into a string suitable for display
# in a hover. Returns `nothing` for implementation-detail lattice elements that the user
# shouldn't see: `Type{T}` (the value is itself a type), and function singletons whose
# name already appears in `source_text` as a whole word (e.g. hovering on `sin│` would
# otherwise show `sin :: typeof(sin)`, which is just noise). For function singletons whose
# name is not visible in the source — `s[2]│` resolving to `cos`, or `mycos│` aliased from
# `cos` — the singleton type is returned as `typeof(<name>)` so the hover header announces
# which value the expression resolves to without conflating value and type positions.
function hover_type_string(@nospecialize(typ), source_text::AbstractString)
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

# Compute the call-dispatch signature applicable at the cursor's `node`, or
# `nothing` when the cursor isn't at a call site, when no unique method
# matched, or when the signature can't be stripped cleanly. Used to narrow
# the hover docstring lookup from "all overloads merged" to
# "(generic + the specific method's docs)".
function call_doc_sig(ctx::InferredTreeContext, st0_top::SyntaxTreeC, node::SyntaxTreeC)
    call_node = @something enclosing_call_for_matches(st0_top, node) return nothing
    matches = @something get_matches_for_range(ctx, JS.byte_range(call_node)) return nothing
    # Require a single matched method — for ambiguous dispatch (union splits,
    # multiple matching overloads) fall back to the unnarrowed lookup so we
    # don't silently hide applicable docs.
    length(matches) == 1 || return nothing
    return method_doc_sig(only(matches).method)
end

# Resolve `node` to a `(parentmod, identifier)` pair and look up its binding-
# based docstring. For a dot expression whose left-hand side is a `Module`
# value, looks up the RHS as a member of that module. For a dot expression
# whose left-hand side is an instance, looks up the per-field docstring on
# the LHS's inferred type via [`lookup_field_doc`](@ref).
function lookup_doc_for_identifier(
        node::SyntaxTreeC, context_module::Module, ctx::Union{Nothing,InferredTreeContext},
        @nospecialize(sig), world::UInt
    )
    if JS.kind(node) === JS.K"." && JS.numchildren(node) ≥ 2
        prefix_node = node[1]
        identifier_node = node[2]
        # EST wraps the RHS of dot expressions in `K"inert"`
        if JS.kind(identifier_node) === JS.K"inert" && JS.numchildren(identifier_node) ≥ 1
            identifier_node = identifier_node[1]
        end
        JS.is_identifier(identifier_node) || return nothing
        field = Symbol(@something get_name_val(identifier_node) return nothing)
        mod = resolve_dot_prefix_module(prefix_node, context_module, ctx, world)
        if mod !== nothing
            return lookup_doc_for_binding(mod, field, sig, world)
        end
        # Instance field access: surface the per-field doc attached to the
        # LHS's inferred type, mirroring `REPL.fielddoc` but without REPL's
        # `T has fields …` fallback.
        ctx === nothing && return nothing
        prefix_typ = get_type_for_range(ctx, JS.byte_range(prefix_node))
        prefix_typ === nothing && return nothing
        return lookup_field_doc(prefix_typ, field, world)
    end
    JS.is_identifier(node) || return nothing
    name = @something get_name_val(node) return nothing
    return lookup_doc_for_binding(context_module, Symbol(name), sig, world)
end

# Resolve a dot expression's left-hand side to a `Module` value. Tries a direct
# `getglobal` for plain identifiers first — this covers macro-name dot prefixes
# like `Base.@inline` whose argument-position `Base` isn't typed by inference —
# and falls back to a `get_type_for_range` query against the surrounding ctx
# for nested chains (`Base.Compiler.…`). `ctx === nothing` (toplevel failed to
# lower) skips the inference fallback and only uses the direct lookup.
function resolve_dot_prefix_module(
        dotprefix::SyntaxTreeC, context_module::Module,
        ctx::Union{Nothing,InferredTreeContext}, world::UInt
    )
    if JS.is_identifier(dotprefix) && (nv = get_name_val(dotprefix)) !== nothing
        name = Symbol(nv)
        if Base.invoke_in_world(world, isdefinedglobal, context_module, name)
            v = Base.invoke_in_world(world, getglobal, context_module, name)
            v isa Module && return v
        end
    end
    ctx === nothing && return nothing
    typ = get_type_for_range(ctx, JS.byte_range(dotprefix))
    typ isa Core.Const || return nothing
    v = typ.val
    v isa Module || return nothing
    return v
end

# Unpack a lattice element to its underlying value and look up that value's
# narrowed docs. `typ.val` for `Core.Const`, `typ.instance` for a singleton
# `Type`. Restricted to `Function` / `Module` / `Type` values via
# [`lookup_value_doc`](@ref).
function lookup_doc_for_inferred_value(@nospecialize(typ), @nospecialize(sig), world::UInt)
    v = if typ isa Core.Const
        typ.val
    elseif Base.issingletontype(typ)
        typ.instance
    else
        return nothing
    end
    return lookup_doc_for_value(v, sig, world)
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
