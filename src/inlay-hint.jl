const INLAY_HINT_REGISTRATION_ID = "jetls-inlay-hint"
const INLAY_HINT_REGISTRATION_METHOD = "textDocument/inlayHint"

function inlay_hint_options()
    return InlayHintOptions(;
        resolveProvider = false)
end

function inlay_hint_registration(static::Bool)
    return Registration(;
        id = INLAY_HINT_REGISTRATION_ID,
        method = INLAY_HINT_REGISTRATION_METHOD,
        registerOptions = InlayHintRegistrationOptions(;
            documentSelector = DEFAULT_DOCUMENT_SELECTOR,
            resolveProvider = false,
            id = static ? INLAY_HINT_REGISTRATION_ID : nothing))
end

# For dynamic registrations during development
# unregister(currently_running, Unregistration(;
#     id = INLAY_HINT_REGISTRATION_ID,
#     method = INLAY_HINT_REGISTRATION_METHOD))
# register(currently_running, inlay_hint_registration(#=static=#true))

function handle_InlayHintRequest(
        server::Server, msg::InlayHintRequest, cancel_flag::CancelFlag)
    state = server.state
    uri = msg.params.textDocument.uri
    range = Range(;
        start = adjust_position(state, uri, msg.params.range.start),
        var"end" = adjust_position(state, uri, msg.params.range.var"end"))

    result = get_file_info(state, uri, cancel_flag)
    if isnothing(result)
        return send(server, InlayHintResponse(; id = msg.id, result = null))
    elseif result isa ResponseError
        return send(server, InlayHintResponse(; id = msg.id, result = nothing, error = result))
    end
    fi = result

    inlay_hints = InlayHint[]
    if get_config(server, :inlay_hint, :block_end, :enabled)
        min_lines = get_config(server, :inlay_hint, :block_end, :min_lines)
        symbols = get_document_symbols!(state, uri, fi)
        syntactic_inlay_hints!(inlay_hints, symbols, fi, range; min_lines)
    end

    if get_config(server, :inlay_hint, :types, :enabled)
        st0_top = build_syntax_tree(fi)
        type_inlay_hints!(inlay_hints, state, fi, st0_top, uri, range)
    end

    return send(server, InlayHintResponse(;
        id = msg.id,
        result = @somereal localize_inlay_hints(state, uri, inlay_hints) null))
end

const INLAY_HINT_MIN_LINES = 25

function syntactic_inlay_hints!(
        inlay_hints::Vector{InlayHint}, symbols::Vector{DocumentSymbol}, fi::FileInfo, range::Range;
        min_lines::Int = INLAY_HINT_MIN_LINES
    )
    for sym in symbols
        add_block_end_inlay_hint!(inlay_hints, sym, fi, range; min_lines)
        if sym.children !== nothing
            syntactic_inlay_hints!(inlay_hints, sym.children, fi, range; min_lines)
        end
    end
    return inlay_hints
end

function add_block_end_inlay_hint!(
        inlay_hints::Vector{InlayHint}, sym::DocumentSymbol, fi::FileInfo, range::Range;
        min_lines::Int = INLAY_HINT_MIN_LINES
    )
    keyword, label = @something get_block_keyword_label(sym) return
    endpos = sym.range.var"end"
    endpos ∉ range && return # this inlay hint isn't visible
    block_lines = endpos.line - sym.range.start.line
    if block_lines == 0
        return # don't add inlay hint when block is defined as one liner
    elseif block_lines < min_lines
        return # block is too short to need an inlay hint
    end
    # If there's already a comment like `end # keyword name`, don't display the inlay hint
    name = sym.name
    bstart = xy_to_offset(fi, endpos) + 1
    nexttc = next_nontrivia(fi.parsed_stream, bstart)
    if !isnothing(nexttc)
        commentrange = bstart:JS.first_byte(nexttc)-1
        commentstr = String(fi.parsed_stream.textbuf[commentrange])
        if (occursin(name, commentstr) ||
            (keyword !== nothing && startswith(lstrip(commentstr), "# $keyword")) ||
            (keyword !== nothing && startswith(lstrip(commentstr), "#= $keyword")))
            return
        end
    end
    displayLabel = "#= " * label * " =#"
    newText = " " * displayLabel
    offset = encoded_length(newText, fi.encoding)
    textEdits = TextEdit[TextEdit(;
        range = Range(;
            start = Position(endpos; character = endpos.character+1),
            var"end" = Position(endpos; character = endpos.character+1+offset)),
        newText)]
    push!(inlay_hints, InlayHint(;
        position = endpos,
        textEdits,
        label = displayLabel,
        paddingLeft = true))
    nothing
end

function get_block_keyword_label(sym::DocumentSymbol)
    detail = @something sym.detail return nothing
    if sym.kind === SymbolKind.Module
        startswith(detail, "baremodule ") && return "baremodule", "baremodule " * sym.name
        startswith(detail, "module ") && return "module", "module " * sym.name
    elseif sym.kind === SymbolKind.Function
        startswith(detail, "function ") && return "function", "function " * sym.name
        startswith(detail, "macro ") && return "macro", "macro " * sym.name
        endswith(detail, " =") && return nothing, sym.name * "(...) =" # short form
    elseif sym.kind === SymbolKind.Struct
        startswith(detail, "mutable struct ") && return "mutable struct", "mutable struct " * sym.name
        startswith(detail, "struct ") && return "struct", "struct " * sym.name
    elseif sym.kind === SymbolKind.Namespace
        startswith(detail, "if") && return "if", String(first(split(detail, '\n')))
        startswith(detail, "@static if") && return "@static if", String(first(split(detail, '\n')))
        startswith(detail, "let") && return "let", String(first(split(detail, '\n')))
        startswith(detail, "for") && return "for", String(first(split(detail, '\n')))
        startswith(detail, "while") && return "while", String(first(split(detail, '\n')))
    elseif sym.kind === SymbolKind.Event # `@testset`
        startswith(detail, "@testset") && return "@testset", detail
    end
    return nothing
end

function syntactic_inlay_hints(fi::FileInfo, range::Range; kwargs...)
    st0 = build_syntax_tree(fi)
    symbols = extract_document_symbols(st0, fi)
    inlay_hints = InlayHint[]
    syntactic_inlay_hints!(inlay_hints, symbols, fi, range; kwargs...)
    return inlay_hints
end

function type_inlay_hints!(
        inlay_hints::Vector{InlayHint}, state::ServerState, fi::FileInfo,
        st0_top::SyntaxTreeC, uri::URI, range::Range
    )
    nontrivia_index = build_nontrivia_byte_index(fi.parsed_stream)
    iterate_toplevel_tree(st0_top) do st0::SyntaxTreeC
        # Skip toplevel def whose source is fully outside of the requested visible viewport.
        startpos = offset_to_xy(fi, JS.first_byte(st0))
        endpos = offset_to_xy(fi, JS.last_byte(st0) + 1)
        overlap(Range(; start=startpos, var"end"=endpos), range) || return nothing
        (; mod, postprocessor) = get_context_info(state, uri, startpos)
        (; ctx3, st3) = @something get_inferrable_tree(st0, mod) return nothing
        inferred_tree = @something infer_toplevel_tree(ctx3, st3, mod) return nothing
        collect_type_inlay_hints!(
            inlay_hints, st0, st3, inferred_tree, fi, range, postprocessor, nontrivia_index)
    end
    return inlay_hints
end

# Sorted Vector of `first_byte` of every non-trivia token (newlines also treated as
# trivia, matching `next_nontrivia_byte(...; pass_newlines=true)` semantics). One
# linear scan amortizes what was O(N) per `first_token_byte` call into a single
# O(N) prepass plus O(log N) binary search per query.
function build_nontrivia_byte_index(ps::JS.ParseStream)
    indices = Int[]
    for tc in TokenCursor(ps)
        is_trivia(tc, #=pass_newlines=#true) && continue
        push!(indices, JS.first_byte(tc))
    end
    return indices
end

# Two-pass design:
#
# Most "should this node get a hint?" decisions are determined by the node's
# *role inside its parent* — the callee child of `K"call"`, the LHS of `K"="`,
# the type RHS of `K"::"`, etc. JuliaSyntax's `SyntaxTree` traversal hands the
# callback one node at a time without an upward parent pointer, so a leaf-only
# visit can't ask "what role does my parent assign me?".
#
# We therefore split the work in two:
#
# 1. **Preorder classify pass** — visit each node, and when a parent kind
#    assigns a role to a child range (callee, paren-wrap base, sig/type
#    declaration, …), record the child's byte range into the appropriate set.
# 2. **Postorder emission pass** — visit each node in postorder and decide
#    whether to emit a hint, consulting the precomputed sets to suppress or
#    wrap as needed.
function collect_type_inlay_hints!(
        inlay_hints::Vector{InlayHint}, st0::SyntaxTreeC, st3::SyntaxTreeC,
        inferred_tree::SyntaxTreeC, fi::FileInfo, range::Range,
        postprocessor::LSPostProcessor,
        nontrivia_index::Vector{Int} = build_nontrivia_byte_index(fi.parsed_stream);
        # Inline hints have no horizontal room for a fully-spelled
        # `SyntaxTree{Dict{Symbol, Dict{Int64, Any}}}`; the defaults clip both
        # nesting and width so the rendered hint stays a glanceable cue. Tests
        # pass `typemax(Int)` for both to assert on the unclipped type strings.
        maxdepth::Int = 3,
        maxwidth::Int = 20,
    )
    # Sets accumulated:
    # - `callee_ranges`: byte ranges that should *not* receive a hint of their
    #   own — callees (`f` in `f(...)`, `<` operators in chained comparisons),
    #   plain `=` LHS Identifiers, dotted-access RHS, for-loop iteration
    #   variables (we emit those via the dedicated postorder branch), …
    # - `paren_wrap_ranges`: expressions that appear as the LHS of `.field`
    #   or `[…]` access; the hint needs an extra `(…)::T)` wrap so the
    #   trailing access still binds outside the assertion.
    # - `sig_ranges`: user-written signature / type expressions
    #   (`function f(x::T)::U`, `struct Foo{T} <: AbstractVector{T}`, the
    #   RHS of `::`, …). The postorder pass skips any node whose byte
    #   range falls inside one — the user already wrote the type.
    callee_ranges = Set{UnitRange{Int}}()
    paren_wrap_ranges = Set{UnitRange{Int}}()
    sig_ranges = Set{UnitRange{Int}}()
    traverse(st0) do node::SyntaxTreeC
        JS.kind(node) === JS.K"Value" && return nothing
        if JS.kind(node) === JS.K"." && JS.numchildren(node) >= 2
            push!(paren_wrap_ranges, JS.byte_range(node[1]))
            push!(callee_ranges, JS.byte_range(node[2]))
        end
        if JS.kind(node) === JS.K"ref" && JS.numchildren(node) >= 1
            push!(paren_wrap_ranges, JS.byte_range(node[1]))
        end
        if JS.kind(node) in JS.KSet"call dotcall" && JS.numchildren(node) >= 1
            push!(callee_ranges, JS.byte_range(node[1]))
            # Infix `^`: `::` is tighter than `^` (so `x::T^2` parses correctly
            # as `(x::T)^2`), but the rendered text looks visually ambiguous —
            # a reader can mis-group as `x::(T^2)`. Wrap the LHS operand to
            # make the grouping explicit: `(x::T)^2`.
            if JS.is_infix_op_call(node) && JS.numchildren(node) >= 3
                callee_rng = JS.byte_range(node[1])
                if length(callee_rng) == 1 &&
                        fi.parsed_stream.textbuf[first(callee_rng)] == UInt8('^')
                    push!(paren_wrap_ranges, JS.byte_range(node[2]))
                end
            end
        end
        if JS.kind(node) in JS.KSet"function macro"
            sig_rng = funcdef_sig_range(node)
            sig_rng !== nothing && push!(sig_ranges, sig_rng)
        end
        if JS.kind(node) === JS.K"->" && JS.numchildren(node) >= 1
            # Lambda parameter list (`do y::T` / `(y::T) -> …`) is a signature —
            # same treatment as funcdef sig: suppress the user-typed annotations
            # from emitting redundant `::Any` hints.
            params = node[1]
            if JS.kind(params) === JS.K"tuple"
                push!(sig_ranges, JS.byte_range(params))
            end
        end
        if JS.kind(node) === JS.K"comparison"
            # `K"comparison"` lays out children as `[lhs, op, mid, op, rhs, …]`
            # — each operator (even index, 1-based) is a `K"Identifier"` that
            # the lowering pipeline reuses as a callee, so its byte range
            # picks up `Union{typeof(<), Bool, …}` annotations that the user
            # didn't write. Suppress them like other callees.
            for i = 2:2:JS.numchildren(node)
                push!(callee_ranges, JS.byte_range(node[i]))
            end
        end
        if JS.kind(node) === JS.K"=" && JS.numchildren(node) >= 1
            lhs = node[1]
            if JS.kind(lhs) === JS.K"Identifier"
                push!(callee_ranges, JS.byte_range(lhs))
            else
                # Short-form function definition `f(args) = body` (possibly
                # `where`-wrapped or `::T`-annotated). `funcdef_sig_range`
                # peels both wrappers and returns the entire sig's range.
                sig_rng = funcdef_sig_range(node)
                sig_rng !== nothing && push!(sig_ranges, sig_rng)
            end
        end
        if JS.kind(node) === JS.K"unknown_head" && JS.numchildren(node) >= 1
            # Compound assignment (`op=`) lowering introduces operator
            # references that pollute the LHS byte range.
            push!(callee_ranges, JS.byte_range(node[1]))
        end
        # Postfix `'` (adjoint): the operand's hint at end-of-operand would
        # land between the operand and `'`, producing syntactically ambiguous
        # rendering like `M::T'::T_outer` (which parses as `M::(T')`).
        # Suppress the operand's hint so the K"'" emits cleanly as `M'::T`.
        if JS.kind(node) === JS.K"'" && JS.numchildren(node) >= 1
            push!(callee_ranges, JS.byte_range(node[1]))
        end
        # `for var = iter` — register the iteration variable(s) so the regular
        # postorder visit doesn't emit a hint on them; we emit a single hint
        # via `emit_for_loop_var_hints!` in the postorder pass below. Unlike
        # bare destructuring `(a, b) = expr`, the for-loop variants
        # `(a, b) = iter` / `(; v) = iter` always go through this path.
        if JS.kind(node) === JS.K"for" && JS.numchildren(node) >= 1
            spec = node[1]
            if JS.kind(spec) === JS.K"=" && JS.numchildren(spec) >= 1
                register_for_loop_vars!(callee_ranges, spec[1])
            end
        end
        if JS.kind(node) === JS.K"::" && JS.numchildren(node) >= 1
            push!(callee_ranges, JS.byte_range(node[1]))
            # The RHS is a user-written type expression — suppress annotations
            # on any identifier nested inside (e.g. `Int` in `x::Int`,
            # `Vector{Int}` in `x::Vector{Int}`).
            if JS.numchildren(node) >= 2
                push!(sig_ranges, JS.byte_range(node[2]))
            end
        end
        # Type declarations: register the user-written name expression
        # (e.g. `Foo`, `Bar{T} <: AbstractVector{T}`) as a sig range so
        # identifiers inside don't get `::Any` hints.
        if JS.kind(node) === JS.K"struct" && JS.numchildren(node) >= 2
            push!(sig_ranges, JS.byte_range(node[2])) # node[1] is mutable flag
        end
        if JS.kind(node) in JS.KSet"abstract primitive" && JS.numchildren(node) >= 1
            push!(sig_ranges, JS.byte_range(node[1]))
        end
    end

    # Branches in order:
    #   1. Funcdef shape → emit return-type hint on the signature `K"call"`.
    #   2. Kinds that would clobber user-written text or duplicate a hint
    #      already emitted elsewhere — skip.
    #   3. `K"for"` → emit hints on the iteration variable(s).
    #   4. Non-anchor kinds (loop machinery, blocks, control-flow) — skip.
    #   5. Nodes whose range lies inside a `sig_ranges` entry — skip.
    #   6. Viewport check — skip if the anchor lies outside the requested
    #      range (LSP re-requests per viewport).
    #   7. Look up the type for the node's byte range and emit, deciding the
    #      `(…)::T` wrap shape from `paren_wrap_ranges` and the node's kind
    #      (infix call, no-paren macrocall, branching expression, open
    #      tuple, …). Decoratively parenthesized sources reuse their own
    #      parens instead of layering ours.
    ctx = InferredTreeContext(inferred_tree, st3)
    traverse(st0, #=postorder=#true) do node::SyntaxTreeC
        k = JS.kind(node)
        k === JS.K"Value" && return nothing

        byterng = JS.byte_range(node)

        # Funcdef return type emits on the signature `K"call"` — covers
        # `function f(...) end` / `macro m(...) end` and short-form
        # `f(args) = body` (possibly `where`-wrapped). `funcdef_call_node`
        # returns the signature `K"call"` for any of these, or `nothing` if
        # the LHS isn't a call (e.g. regular assignment, or funcdef with a
        # manual `::T` return type that we shouldn't override).
        if k in JS.KSet"function macro =" && (call_node = funcdef_call_node(node)) !== nothing
            endpos = offset_to_xy(fi, JS.last_byte(call_node) + 1)
            endpos ∈ range || return nothing
            ret_typ = @something get_type_for_range(ctx, byterng) return nothing
            emit_type_hint!(
                inlay_hints, call_node, ret_typ, fi, nontrivia_index, endpos, postprocessor,
                maxdepth, maxwidth)
            return nothing
        end

        # Kinds whose annotation would override or duplicate user-written text.
        # `K"function"` / `K"macro"` reach here only with a manual `::T` return
        # type (no `call_node`); annotating would clobber it. `K"="` is the
        # regular-assignment fall-through from the funcdef branch above — its
        # byte range coincides with the RHS, which already emits its own hint.
        # `K"do"` / `K"->"` share their byte range with the underlying
        # `K"call"` (or its tail), so emitting here would duplicate the call's
        # hint. `K"::"` / `K"struct"` / `K"abstract"` / `K"primitive"` carry
        # user-written types directly.
        k in JS.KSet"function macro = do -> :: struct abstract primitive" && return nothing
        # `for var = iter` — emit hints on the loop variable(s). The K"=" pass
        # above adds the LHS to `callee_ranges` (so the regular Identifier visit
        # below skips it), but unlike a plain binding, the iteration variable's
        # inferred type is informative. Handle three LHS shapes:
        #   `for i = iter`           — K"Identifier"
        #   `for (i, x) = iter`      — K"tuple" of K"Identifier"
        #   `for (; value) = iter`   — K"tuple" of K"parameters" of K"Identifier"
        if k === JS.K"for" && JS.numchildren(node) >= 1
            spec = node[1]
            if JS.kind(spec) === JS.K"=" && JS.numchildren(spec) >= 1
                emit_for_loop_var_hints!(
                    inlay_hints, spec[1], ctx, fi, range, nontrivia_index, postprocessor,
                    maxdepth, maxwidth)
            end
        end
        # Kinds that simply aren't useful hint anchors: loop machinery, syntactic body
        # blocks, control-flow statements, and the `K"unknown_head"` placeholder that
        # compound assignment (`a += 1`) lowers through.
        k in JS.KSet"unknown_head for while in iteration block return break continue" && return nothing

        in_sig_range(byterng, sig_ranges) && return nothing

        # Load-bearing: `emit_type_hint!` has no late visibility filter, so this
        # bail is what keeps hints whose anchor is outside the client's viewport
        # (LSP re-requests per viewport change) from being emitted.
        endpos = offset_to_xy(fi, JS.last_byte(node) + 1)
        endpos ∈ range || return nothing

        # Locate the type to display.
        if k in JS.KSet"call dotcall"
            JS.numchildren(node) >= 1 || return nothing
        end
        # Nodes labeled by their container — callee Identifiers (`f` in
        # `f(...)`), LHS of `=`, dotted-access RHS, postfix `'` operand, … —
        # have their byte range registered in `callee_ranges` so they don't
        # pick up a redundant hint here. `K"macrocall"` is an anchor in its
        # own right and bypasses this filter.
        k !== JS.K"macrocall" && byterng in callee_ranges && return nothing
        typ = get_type_for_range(ctx, byterng)
        typ === nothing && return nothing
        should_annotate_type(typ) || return nothing

        # Paren options:
        # - infix/postfix `K"call"` / `K"dotcall"`, no-paren `K"macrocall"`,
        #   `K"&&"`/`K"||"`/`K"comparison"`, ternary `K"if"`, and open
        #   `K"tuple"` (`x, y` without surrounding parens) need wrapping the
        #   value with `(…)::T` so `::T` doesn't bind to the rightmost
        #   operand. Block-form `K"if"`/`K"let"` (with explicit `end`) don't
        #   need wrap — the `end` keyword is a syntactic boundary, so
        #   `let; …; end::T` parses as `(let; …; end)::T`.
        # - `is_dp` (the byte range is a dotted-access LHS) needs an extra
        #   close paren after the type so the trailing `.field` still binds.
        #   `K"macrocall"` isn't typically used as a dotted LHS, so the
        #   original code didn't apply `is_dp` to it either.
        is_dp = byterng in paren_wrap_ranges
        is_infix_call = k in JS.KSet"call dotcall" &&
            (JS.is_infix_op_call(node) || JS.is_postfix_op_call(node) ||
             JS.is_prefix_op_call(node))
        is_noparen_macro = k === JS.K"macrocall" && noparen_macrocall(node)
        is_logical_or_chained = k in JS.KSet"&& || comparison" ||
            (k === JS.K"if" && is_ternary(node))
        needs_wrap = is_infix_call || is_noparen_macro || is_logical_or_chained || is_open_tuple(node)
        # If the source already has decorative parens around `node`, reuse them
        # instead of layering our own — `((expr)::T)` collapses to `(expr)::T`,
        # and `((y::T)).foo` collapses to `(y::T).foo`. The combined case
        # `(x + y).foo` (`needs_wrap` *and* `is_dp`) still needs an outer
        # `(...)::T` so `.foo` binds outside the assertion, but the source's
        # parens take care of the inner wrap.
        # For prefix unary `-x` / `!x` / `~x`, anchor the open paren at the
        # *argument*'s start so the operator stays outside the wrap:
        # `-(x::T)::T` reads more naturally than `(-x::T)::T`.
        is_prefix_unary = k in JS.KSet"call dotcall" && JS.is_prefix_op_call(node) &&
            JS.numchildren(node) >= 2
        paren_start_node = is_prefix_unary ? node[2] : node
        if (needs_wrap || is_dp) && is_decoratively_parenthesized(node, fi)
            past = needs_wrap ? offset_to_xy(fi, byte_past_close_paren(node, fi)) : endpos
            emit_type_hint!(
                inlay_hints, node, typ, fi, nontrivia_index, past, postprocessor,
                maxdepth, maxwidth;
                open_paren = needs_wrap && is_dp,
                close_paren_before_type = false,
                close_paren_after_type = k !== JS.K"macrocall" && needs_wrap && is_dp,
                paren_start_node)
        else
            emit_type_hint!(
                inlay_hints, node, typ, fi, nontrivia_index, endpos, postprocessor,
                maxdepth, maxwidth;
                open_paren = needs_wrap || is_dp,
                close_paren_before_type = needs_wrap,
                close_paren_after_type = k !== JS.K"macrocall" && is_dp,
                paren_start_node)
        end
        return nothing
    end
    return inlay_hints
end

function funcdef_call_node(funcdef::SyntaxTreeC)
    JS.numchildren(funcdef) >= 1 || return nothing
    sig = funcdef[1]
    while JS.kind(sig) === JS.K"where"
        JS.numchildren(sig) >= 1 || return nothing
        sig = sig[1]
    end
    JS.kind(sig) === JS.K"::" && return nothing # manual return type annotation exists
    JS.kind(sig) === JS.K"call" || return nothing
    return sig
end

# Byte range of the entire user-written signature (`f(args)`, optionally wrapped by
# `where {…}` and/or `::T`), or `nothing` if `funcdef` isn't a function-like definition.
# Used to populate `sig_ranges` so where-clause bounds (e.g. `T <: Number`) don't pick up
# `::TypeVar` hints. Unlike `funcdef_call_node`, this does *not* bail on a `::T` return
# annotation — we still want to treat the surrounding signature as a sig range.
function funcdef_sig_range(funcdef::SyntaxTreeC)
    JS.numchildren(funcdef) >= 1 || return nothing
    sig = funcdef[1]
    JS.kind(unwrap_funcdef_sig(sig)) === JS.K"call" || return nothing
    return JS.byte_range(sig)
end

should_annotate_type(@nospecialize(typ)) = !(typ isa Core.Const)

# Recursively register every Identifier byte range inside a for-loop's
# iteration LHS, so the regular postorder visit skips them — they're
# emitted as a single hint by `emit_for_loop_var_hints!`.
function register_for_loop_vars!(callee_ranges::Set{UnitRange{Int}}, lhs::SyntaxTreeC)
    k = JS.kind(lhs)
    if k === JS.K"Identifier"
        push!(callee_ranges, JS.byte_range(lhs))
    elseif k in JS.KSet"tuple parameters"
        for child in JS.children(lhs)
            register_for_loop_vars!(callee_ranges, child)
        end
    end
    return nothing
end

# Recursively walk a for-loop iteration LHS and emit a type hint on each
# declared variable. Handles `K"Identifier"` (single var), `K"tuple"` of
# identifiers (tuple destructuring), and the `K"parameters"` child of a
# tuple (named-tuple destructuring `(; a, b)`).
function emit_for_loop_var_hints!(
        inlay_hints::Vector{InlayHint}, lhs::SyntaxTreeC,
        ctx::InferredTreeContext, fi::FileInfo, range::Range,
        nontrivia_index::Vector{Int}, postprocessor::LSPostProcessor,
        maxdepth::Int, maxwidth::Int,
    )
    k = JS.kind(lhs)
    if k === JS.K"Identifier"
        emit_loop_var_hint!(
            inlay_hints, lhs, ctx, fi, range, nontrivia_index, postprocessor,
            maxdepth, maxwidth)
    elseif k in JS.KSet"tuple parameters"
        for child in JS.children(lhs)
            emit_for_loop_var_hints!(
                inlay_hints, child, ctx, fi, range, nontrivia_index, postprocessor,
                maxdepth, maxwidth)
        end
    end
    return nothing
end

function emit_loop_var_hint!(
        inlay_hints::Vector{InlayHint}, lvar::SyntaxTreeC,
        ctx::InferredTreeContext, fi::FileInfo, range::Range,
        nontrivia_index::Vector{Int}, postprocessor::LSPostProcessor,
        maxdepth::Int, maxwidth::Int,
    )
    ltyp = @something get_type_for_range(ctx, JS.byte_range(lvar)) return nothing
    should_annotate_type(ltyp) || return nothing
    endpos = offset_to_xy(fi, JS.last_byte(lvar) + 1)
    endpos ∈ range || return nothing
    emit_type_hint!(
        inlay_hints, lvar, ltyp, fi, nontrivia_index, endpos, postprocessor,
        maxdepth, maxwidth)
    return nothing
end

# EST conversion rewrites ternary green-tree `K"?"` to `K"if"`, fusing it with
# block-form `if`. The original kind is preserved on the provenance chain
# (`prov(node)` returns the green-tree node this EST node was built from).
is_ternary(node::SyntaxTreeC) =
    JS.kind(node) === JS.K"if" && JS.kind(JS.prov(node)) === JS.K"?"

# `(x, y)::T` parses cleanly because the `)` is a syntactic boundary, but
# `x, y::T` parses as `x, (y::T)`. The parser sets `PARENS_FLAG` on
# `K"tuple"` exactly when it's surrounded by `(` `)` (independent of any
# nested tuple's parens), so checking the flag is the precise discriminator.
is_open_tuple(node::SyntaxTreeC) =
    JS.kind(node) === JS.K"tuple" && !JS.has_flags(node.syntax_flags, JS.PARENS_FLAG)

# `K"parens"` is dropped during EST construction (its byte range is absorbed
# into the inner expression's), so we recover it from the `ParseStream` by
# looking at the tokens flanking the node. The `(` preceding the node is
# decorative — i.e. just `(expr)` — when it is itself preceded by a token
# that *isn't* a function-call / indexed-call / chained-call anchor (an
# identifier, `]`, or `)`).
function is_decoratively_parenthesized(node::SyntaxTreeC, fi::FileInfo)
    ps = fi.parsed_stream
    fb = JS.first_byte(node)
    open_tc = @something prev_nontrivia(ps, fb - 1; pass_newlines=true) return false
    JS.kind(open_tc) === JS.K"(" || return false
    lb = JS.last_byte(node)
    close_tc = @something next_nontrivia(ps, lb + 1; pass_newlines=true) return false
    JS.kind(close_tc) === JS.K")" || return false
    open_pos = JS.first_byte(open_tc)
    open_pos < 2 && return true # `(` at start of file
    # `pass_newlines=false`: a newline between the previous statement and our
    # `(` means we're at a fresh statement boundary, so any `)` from the
    # previous line doesn't make us a chained call.
    prev = @something prev_nontrivia(ps, open_pos - 1; pass_newlines=false) return true
    pk = JS.kind(prev)
    return !(pk === JS.K"Identifier" || pk === JS.K"]" || pk === JS.K")")
end

# Byte position one past the source `)` that follows `node`. Caller must have
# already verified parenthesization via `is_decoratively_parenthesized`.
function byte_past_close_paren(node::SyntaxTreeC, fi::FileInfo)
    lb = JS.last_byte(node)
    close_tc = next_nontrivia(fi.parsed_stream, lb + 1; pass_newlines=true)
    return JS.last_byte(close_tc) + 1
end

# `sig_ranges` holds the byte range of each user-written declaration signature
# — `function f(...)` / `macro m(...)` calls, lambda parameter tuples, and the
# name expressions of `struct` / `abstract` / `primitive` declarations.
# Anything inside such a range — type annotations, default-value calls, `where`
# constraints, dotted module access, parametric type names — is something the
# user already wrote out, so emitting `::Any` hints there is pure noise.
in_sig_range(byterng::UnitRange{<:Integer}, sig_ranges::Set{UnitRange{Int}}) =
    any(sig::UnitRange{Int} -> byterng ⊆ sig, sig_ranges)

function emit_type_hint!(
        inlay_hints::Vector{InlayHint}, node::SyntaxTreeC, @nospecialize(typ), fi::FileInfo,
        nontrivia_index::Vector{Int}, endpos::Position, postprocessor::LSPostProcessor,
        maxdepth::Int, maxwidth::Int;
        open_paren::Bool = false,
        close_paren_before_type::Bool = false,
        close_paren_after_type::Bool = false,
        # Anchor for the open-paren position. Defaults to `node`, which gives
        # `(node…)::T` — but for prefix unary calls, the caller passes the
        # argument so the operator stays outside the wrap: `-(x::T)::T`.
        paren_start_node::SyntaxTreeC = node,
    )
    if open_paren
        n_parens = max(close_paren_before_type + close_paren_after_type, 1)
        startpos = offset_to_xy(fi, first_token_byte(paren_start_node, nontrivia_index))
        push!(inlay_hints, InlayHint(;
            position = startpos,
            label = "(" ^ n_parens,
            kind = InlayHintKind.Type,
            paddingLeft = false))
    end
    pre = close_paren_before_type ? ")" : ""
    post = close_paren_after_type ? ")" : ""
    rawtyp = CC.widenconst(typ)
    rawtypstr = sprint(show, rawtyp; context = :compact=>true)
    limited_typstr = postprocessor(truncate_typstr(rawtypstr, maxdepth, maxwidth))
    push!(inlay_hints, InlayHint(;
        position = endpos,
        label = "$pre::$limited_typstr$post",
        tooltip = format_tooltip(rawtyp, postprocessor),
        kind = InlayHintKind.Type,
        paddingLeft = false))
    return nothing
end

# `Base.type_limited_string_from_context` clamps width to `max(_, 120)`, which
# is too wide for inline hints — call `type_depth_limit` directly. Two passes:
# `maxdepth` first to cap structural depth, then `maxwidth` to cap textual
# width. Passing `typemax(Int)` for either is the canonical "no limit".
function truncate_typstr(str::String, maxdepth::Int, maxwidth::Int)
    str = Base.type_depth_limit(str, 0; maxdepth)
    str = Base.type_depth_limit(str, maxwidth)
    return str
end

# Compound nodes' `first_byte` may include leading trivia (whitespace, comments,
# newlines), so binary-search the prebuilt sorted list of non-trivia token starts
# for the first non-trivia byte at or after the node's start.
function first_token_byte(node::SyntaxTreeC, nontrivia_index::Vector{Int})
    fb = Int(JS.first_byte(node))
    idx = searchsortedfirst(nontrivia_index, fb)
    idx > length(nontrivia_index) && return fb
    return nontrivia_index[idx]
end

# `Union{}` is valid Julia syntax (consistent with the `::T` shape of every
# other hint), but its meaning isn't obvious at a glance — surface a short
# explanation in the tooltip so unreachable / always-erroring expressions
# are recognizable rather than puzzling.
function format_tooltip(@nospecialize(rawtyp), postprocessor::LSPostProcessor)
    rawtyp === Union{} && return "`Union{}` — this expression provably never produces a value (always throws, or is unreachable)."
    full_typstr = postprocessor(sprint(show, rawtyp))
    return "`$full_typstr`"
end
