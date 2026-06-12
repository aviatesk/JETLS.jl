const INLAY_HINT_REGISTRATION_ID = "jetls-inlay-hint"
const INLAY_HINT_REGISTRATION_METHOD = "textDocument/inlayHint"

function inlay_hint_options()
    return InlayHintOptions(;
        resolveProvider = true)
end

function inlay_hint_registration(static::Bool)
    return Registration(;
        id = INLAY_HINT_REGISTRATION_ID,
        method = INLAY_HINT_REGISTRATION_METHOD,
        registerOptions = InlayHintRegistrationOptions(;
            documentSelector = DEFAULT_DOCUMENT_SELECTOR,
            resolveProvider = true,
            id = static ? INLAY_HINT_REGISTRATION_ID : nothing))
end

supports_inlay_hint_resolve(state::ServerState, property::AbstractString) =
    property in @something getcapability(
        state, :textDocument, :inlayHint, :resolveSupport, :properties) return false

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
        result = localize_inlay_hints(state, uri, inlay_hints)))
end

function handle_InlayHintResolveRequest(
        server::Server, msg::InlayHintResolveRequest, cancel_flag::CancelFlag
    )
    result = resolve_inlay_hint(server.state, msg.params, cancel_flag)
    if isnothing(result)
        return send(server, InlayHintResolveResponse(; id = msg.id, result = null))
    elseif result isa ResponseError
        return send(server, InlayHintResolveResponse(; id = msg.id, result = nothing, error = result))
    end
    return send(server, InlayHintResolveResponse(; id = msg.id, result))
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

function syntactic_inlay_hints(
        state::ServerState, uri::URI, fi::FileInfo, range::Range;
        kwargs...
    )
    symbols = get_document_symbols!(state, uri, fi)
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
        (; context_module, postprocessor, world) = get_context_info(state, uri, startpos)
        ctx = @something build_inferred_context_for_range(
            st0_top, context_module, JS.byte_range(st0);
            world, caller="type_inlay_hints!",
            cache=fi.inferred_context_cache) return nothing
        collect_type_inlay_hints!(
            inlay_hints, st0, ctx, fi, uri, range, postprocessor, nontrivia_index;
            lazy_tooltips = supports_inlay_hint_resolve(state, "tooltip"))
    end
    return inlay_hints
end

# Precompute non-trivia token starts so `first_token_byte` can use binary search.
function build_nontrivia_byte_index(ps::JS.ParseStream)
    indices = Int[]
    for tc in TokenCursor(ps)
        is_trivia(tc, #=pass_newlines=#true) && continue
        push!(indices, JS.first_byte(tc))
    end
    return indices
end

# Type hints often depend on a node's role in its parent, but `SyntaxTree`
# traversal doesn't expose parent links. Record role-specific ranges first,
# then consult them during postorder emission.
function collect_type_inlay_hints!(
        inlay_hints::Vector{InlayHint}, st0::SyntaxTreeC, ctx::InferredTreeContext,
        fi::FileInfo, uri::URI, range::Range, postprocessor::LSPostProcessor,
        nontrivia_index::Vector{Int} = build_nontrivia_byte_index(fi.parsed_stream);
        # Keep inline labels glanceable even for deeply nested inferred types.
        maxdepth::Int = 3,
        maxwidth::Int = 20,
        lazy_tooltips::Bool = false,
    )
    # Role-specific ranges collected by the preorder pass.
    # - `callee_ranges`: nodes whose own hint should be suppressed.
    # - `paren_wrap_ranges`: nodes needing wrapper parens because access follows.
    # - `verbatim_ranges`: user-written syntax spans that should not get hints.
    callee_ranges = Set{UnitRange{Int}}()
    paren_wrap_ranges = Set{UnitRange{Int}}()
    verbatim_ranges = Set{UnitRange{Int}}()
    # Interpolated strings have `K"string"` and `K"String"` nodes sharing the
    # same source range; avoid duplicate labels like `::String::String`.
    emitted_ranges = Set{UnitRange{Int}}()
    label_cache = IdDict{Any,String}()
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
            sig_rng !== nothing && push!(verbatim_ranges, sig_rng)
        end
        if JS.kind(node) === JS.K"->" && JS.numchildren(node) >= 1
            # Lambda parameters are signature syntax; suppress the misleading
            # OC slot hint for no-paren single-Identifier forms too.
            params = node[1]
            if JS.kind(params) in JS.KSet"tuple Identifier"
                push!(verbatim_ranges, JS.byte_range(params))
            end
        end
        if JS.kind(node) === JS.K"comparison"
            # Chained-comparison operators lower like callees, which would give
            # noisy `Union{typeof(<), Bool, …}` hints.
            for i = 2:2:JS.numchildren(node)
                push!(callee_ranges, JS.byte_range(node[i]))
            end
        end
        if JS.kind(node) === JS.K"=" && JS.numchildren(node) >= 1
            lhs = node[1]
            if JS.kind(lhs) === JS.K"Identifier"
                push!(callee_ranges, JS.byte_range(lhs))
            else
                # Non-Identifier LHS may be a short-form function definition;
                # suppress hints inside its signature when applicable.
                sig_rng = funcdef_sig_range(node)
                sig_rng !== nothing && push!(verbatim_ranges, sig_rng)
            end
        end
        if JS.kind(node) === JS.K"unknown_head" && JS.numchildren(node) >= 1
            # Compound assignments parse as `K"unknown_head"` with the operator in
            # `name_val`; lowering introduces references that pollute the LHS range.
            push!(callee_ranges, JS.byte_range(node[1]))
        end
        # Postfix `'` (adjoint): the operand's hint at end-of-operand would
        # land between the operand and `'`, producing syntactically ambiguous
        # rendering like `M::T'::T_outer` (which parses as `M::(T')`).
        # Suppress the operand's hint so the K"'" emits cleanly as `M'::T`.
        if JS.kind(node) === JS.K"'" && JS.numchildren(node) >= 1
            push!(callee_ranges, JS.byte_range(node[1]))
        end
        # Register for-loop iteration variables so regular postorder emission
        # skips them; dedicated hints are emitted in the `K"for"` branch below.
        if JS.kind(node) === JS.K"for" && JS.numchildren(node) >= 1
            spec = node[1]
            if JS.kind(spec) === JS.K"=" && JS.numchildren(spec) >= 1
                register_for_loop_vars!(callee_ranges, spec[1])
            end
        end
        # Register comprehension iteration variables like for-loop variables.
        if JS.kind(node) in JS.KSet"generator filter"
            spec = comprehension_iter_spec(node)
            if spec !== nothing && JS.numchildren(spec) >= 1
                register_for_loop_vars!(callee_ranges, spec[1])
            end
        end
        if JS.kind(node) === JS.K"::" && JS.numchildren(node) >= 1
            push!(callee_ranges, JS.byte_range(node[1]))
            # The RHS is a user-written type expression — suppress annotations
            # on any identifier nested inside (e.g. `Int` in `x::Int`,
            # `Vector{Int}` in `x::Vector{Int}`).
            if JS.numchildren(node) >= 2
                push!(verbatim_ranges, JS.byte_range(node[2]))
            end
        end
        # User-written type declaration names should not get nested `::Any` hints.
        if JS.kind(node) === JS.K"struct" && JS.numchildren(node) >= 2
            push!(verbatim_ranges, JS.byte_range(node[2])) # node[1] is mutable flag
        end
        if JS.kind(node) in JS.KSet"abstract primitive" && JS.numchildren(node) >= 1
            push!(verbatim_ranges, JS.byte_range(node[1]))
        end
        # User-written module/import syntax should not receive nested hints.
        if JS.kind(node) in JS.KSet"using import"
            push!(verbatim_ranges, JS.byte_range(node))
        end
    end

    traverse(st0, #=postorder=#true) do node::SyntaxTreeC
        k = JS.kind(node)
        k === JS.K"Value" && return nothing

        byterng = JS.byte_range(node)

        # Emit function return hints on the signature, not the full definition.
        if k in JS.KSet"function macro =" && (call_node = funcdef_call_node(node)) !== nothing
            endpos = offset_to_xy(fi, JS.last_byte(call_node) + 1)
            endpos ∈ range || return nothing
            byterng in emitted_ranges && return nothing
            ret_typ = @something get_type_for_range(ctx, byterng) return nothing
            emit_type_hint!(
                inlay_hints, call_node, ret_typ, fi, uri, nontrivia_index, endpos,
                postprocessor, label_cache, maxdepth, maxwidth, lazy_tooltips, byterng)
            push!(emitted_ranges, byterng)
            return nothing
        end

        # Skip nodes that would clobber user syntax or duplicate a more specific hint.
        k in JS.KSet"function macro = do -> :: struct abstract primitive" && return nothing
        # Decorating macrocalls should not be framed as value-typed expressions.
        if k === JS.K"macrocall" && JS.numchildren(node) >= 1 && is_funcdef_decl(node[end])
            return nothing
        end
        # Emit dedicated hints for registered for-loop iteration variables.
        if k === JS.K"for" && JS.numchildren(node) >= 1
            spec = node[1]
            if JS.kind(spec) === JS.K"=" && JS.numchildren(spec) >= 1
                emit_for_loop_var_hints!(
                    inlay_hints, spec[1], ctx, fi, uri, range, nontrivia_index,
                    postprocessor, label_cache, maxdepth, maxwidth, lazy_tooltips)
            end
        end
        # Emit per-variable hints and skip the comprehension lowering node.
        if k in JS.KSet"generator filter"
            spec = comprehension_iter_spec(node)
            if spec !== nothing && JS.numchildren(spec) >= 1
                emit_for_loop_var_hints!(
                    inlay_hints, spec[1], ctx, fi, uri, range, nontrivia_index,
                    postprocessor, label_cache, maxdepth, maxwidth, lazy_tooltips)
            end
            return nothing
        end
        # `K"flatten"` wraps the outer K"generator" of a multi-`for` (cartesian)
        # comprehension; its anchor would surface the same `Generator{…}`-class
        # lowering noise.
        k === JS.K"flatten" && return nothing

        k in JS.KSet"unknown_head for while in iteration block return break continue" && return nothing

        in_verbatim_range(byterng, verbatim_ranges) && return nothing
        byterng in emitted_ranges && return nothing

        # `emit_type_hint!` has no later visibility filter.
        endpos = offset_to_xy(fi, JS.last_byte(node) + 1)
        endpos ∈ range || return nothing

        if k in JS.KSet"call dotcall"
            JS.numchildren(node) >= 1 || return nothing
        end
        # Suppress container labels registered in `callee_ranges`; macrocalls
        # remain anchors in their own right.
        k !== JS.K"macrocall" && byterng in callee_ranges && return nothing
        typ = get_type_for_range(ctx, byterng)
        typ === nothing && return nothing
        should_annotate_type(typ) || return nothing

        # Wrap forms where `::T` would otherwise bind to the wrong expression,
        # or where trailing field/index access must stay outside the assertion.
        is_dp = byterng in paren_wrap_ranges
        is_infix_call = k in JS.KSet"call dotcall" &&
            (JS.is_infix_op_call(node) || JS.is_postfix_op_call(node) ||
             JS.is_prefix_op_call(node))
        is_noparen_macro = k === JS.K"macrocall" && noparen_macrocall(node)
        is_logical_or_chained = k in JS.KSet"&& || comparison" ||
            (k === JS.K"if" && is_ternary(node, fi))
        needs_wrap = is_infix_call || is_noparen_macro || is_logical_or_chained || is_open_tuple(node)
        # Reuse decorative source parens when possible; for prefix unary calls,
        # start the wrap at the argument so the operator remains outside.
        is_prefix_unary = k in JS.KSet"call dotcall" && JS.is_prefix_op_call(node) &&
            JS.numchildren(node) >= 2
        paren_start_node = is_prefix_unary ? node[2] : node
        if (needs_wrap || is_dp) && is_decoratively_parenthesized(node, fi)
            past = needs_wrap ? offset_to_xy(fi, byte_past_close_paren(node, fi)) : endpos
            emit_type_hint!(
                inlay_hints, node, typ, fi, uri, nontrivia_index, past, postprocessor,
                label_cache, maxdepth, maxwidth, lazy_tooltips, byterng;
                open_paren = needs_wrap && is_dp,
                close_paren_before_type = false,
                close_paren_after_type = k !== JS.K"macrocall" && needs_wrap && is_dp,
                paren_start_node)
        else
            emit_type_hint!(
                inlay_hints, node, typ, fi, uri, nontrivia_index, endpos, postprocessor,
                label_cache, maxdepth, maxwidth, lazy_tooltips, byterng;
                open_paren = needs_wrap || is_dp,
                close_paren_before_type = needs_wrap,
                close_paren_after_type = k !== JS.K"macrocall" && is_dp,
                paren_start_node)
        end
        push!(emitted_ranges, byterng)
        return nothing
    end
    return inlay_hints
end

# Detect function-definition shapes under decorating macrocalls. Unlike
# `funcdef_call_node`, this accepts user-written return annotations.
function is_funcdef_decl(node::SyntaxTreeC)
    k = JS.kind(node)
    if k === JS.K"function" || k === JS.K"macro"
        return true
    elseif k === JS.K"="
        JS.numchildren(node) >= 1 || return false
        return JS.kind(unwrap_funcdef_sig(node[1])) === JS.K"call"
    elseif k === JS.K"macrocall"
        # Nested decoration: `@inline @noinline f(x) = body`. The outer
        # macrocall's last argument is itself a `K"macrocall"` whose last
        # argument is the funcdef.
        JS.numchildren(node) >= 1 || return false
        return is_funcdef_decl(node[end])
    end
    return false
end

# Locate the `K"="` iteration binding inside a comprehension generator/filter.
function comprehension_iter_spec(node::SyntaxTreeC)
    JS.numchildren(node) >= 2 || return nothing
    spec = node[2]
    JS.kind(spec) === JS.K"filter" && JS.numchildren(spec) >= 2 && (spec = spec[2])
    return JS.kind(spec) === JS.K"=" ? spec : nothing
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

# Byte range of the user-written signature, including `where` and return-type
# wrappers, for suppressing hints inside declaration syntax.
function funcdef_sig_range(funcdef::SyntaxTreeC)
    JS.numchildren(funcdef) >= 1 || return nothing
    sig = funcdef[1]
    JS.kind(unwrap_funcdef_sig(sig)) === JS.K"call" || return nothing
    return JS.byte_range(sig)
end

should_annotate_type(@nospecialize(typ)) = !(typ isa Core.Const)

# Register both variables and destructuring wrappers so the regular postorder
# pass doesn't emit duplicate or wrapper-level iteration hints.
function register_for_loop_vars!(callee_ranges::Set{UnitRange{Int}}, lhs::SyntaxTreeC)
    k = JS.kind(lhs)
    if k === JS.K"Identifier"
        push!(callee_ranges, JS.byte_range(lhs))
    elseif k in JS.KSet"tuple parameters"
        push!(callee_ranges, JS.byte_range(lhs))
        for child in JS.children(lhs)
            register_for_loop_vars!(callee_ranges, child)
        end
    end
    return nothing
end

# Emit one hint per variable in an iteration LHS, including destructuring forms.
function emit_for_loop_var_hints!(
        inlay_hints::Vector{InlayHint}, lhs::SyntaxTreeC,
        ctx::InferredTreeContext, fi::FileInfo, uri::URI, range::Range,
        nontrivia_index::Vector{Int}, postprocessor::LSPostProcessor,
        label_cache::IdDict{Any,String}, maxdepth::Int, maxwidth::Int, lazy_tooltips::Bool
    )
    k = JS.kind(lhs)
    if k === JS.K"Identifier"
        emit_loop_var_hint!(
            inlay_hints, lhs, ctx, fi, uri, range, nontrivia_index, postprocessor,
            label_cache, maxdepth, maxwidth, lazy_tooltips)
    elseif k in JS.KSet"tuple parameters"
        for child in JS.children(lhs)
            emit_for_loop_var_hints!(
                inlay_hints, child, ctx, fi, uri, range, nontrivia_index, postprocessor,
                label_cache, maxdepth, maxwidth, lazy_tooltips)
        end
    end
    return nothing
end

function emit_loop_var_hint!(
        inlay_hints::Vector{InlayHint}, lvar::SyntaxTreeC,
        ctx::InferredTreeContext, fi::FileInfo, uri::URI, range::Range,
        nontrivia_index::Vector{Int}, postprocessor::LSPostProcessor,
        label_cache::IdDict{Any,String}, maxdepth::Int, maxwidth::Int, lazy_tooltips::Bool,
    )
    byterng = JS.byte_range(lvar)
    ltyp = @something get_type_for_range(ctx, byterng) return nothing
    should_annotate_type(ltyp) || return nothing
    endpos = offset_to_xy(fi, JS.last_byte(lvar) + 1)
    endpos ∈ range || return nothing
    emit_type_hint!(
        inlay_hints, lvar, ltyp, fi, uri, nontrivia_index, endpos, postprocessor,
        label_cache, maxdepth, maxwidth, lazy_tooltips, byterng)
    return nothing
end

# Ternary and block-form `if` both parse as `K"if"`; distinguish by first token.
function is_ternary(node::SyntaxTreeC, fi::FileInfo)
    JS.kind(node) === JS.K"if" || return false
    tc = @something next_nontrivia(fi.parsed_stream, JS.first_byte(node)) return false
    return JS.kind(tc) !== JS.K"if"
end

# `(x, y)::T` parses cleanly because the `)` is a syntactic boundary, but
# `x, y::T` parses as `x, (y::T)`. The parser sets `PARENS_FLAG` on
# `K"tuple"` exactly when it's surrounded by `(` `)` (independent of any
# nested tuple's parens), so checking the flag is the precise discriminator.
is_open_tuple(node::SyntaxTreeC) =
    JS.kind(node) === JS.K"tuple" && !(JS.hasattr(node, :syntax_flags) && JS.has_flags(node.syntax_flags, JS.PARENS_FLAG))

# Recover dropped `K"parens"` nodes from neighboring tokens. A preceding `(` is
# decorative unless it belongs to a call, index, or chained-call form.
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

# Whether a byte range is contained in user-written syntax that should not get hints.
in_verbatim_range(byterng::UnitRange{Int}, verbatim_ranges::Set{UnitRange{Int}}) =
    any(rng::UnitRange{Int} -> byterng ⊆ rng, verbatim_ranges)

function emit_type_hint!(
        inlay_hints::Vector{InlayHint}, node::SyntaxTreeC, @nospecialize(typ), fi::FileInfo,
        uri::URI, nontrivia_index::Vector{Int}, endpos::Position,
        postprocessor::LSPostProcessor, label_cache::IdDict{Any,String},
        maxdepth::Int, maxwidth::Int, lazy_tooltips::Bool, type_range::UnitRange{Int};
        open_paren::Bool = false,
        close_paren_before_type::Bool = false,
        close_paren_after_type::Bool = false,
        # Prefix unary calls pass the argument so the operator stays outside the wrap.
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
    label_typstr = get!(label_cache, rawtyp) do
        typstr = sprint(show, rawtyp; context = :compact=>true)
        truncate_typstr(postprocessor(typstr), maxdepth, maxwidth)
    end
    tooltip = data = nothing
    if lazy_tooltips && should_lazy_resolve_tooltip(rawtyp)
        data = LSP.TypeInlayHintData(uri, fi.version, first(type_range), last(type_range))
    else
        tooltip = format_type_inlay_hint_tooltip(rawtyp, postprocessor)
    end
    push!(inlay_hints, InlayHint(;
        position = endpos,
        label = "$pre::$label_typstr$post",
        tooltip,
        kind = InlayHintKind.Type,
        paddingLeft = false,
        data))
    return nothing
end

# Find the first non-trivia token start at or after the node's byte range.
function first_token_byte(node::SyntaxTreeC, nontrivia_index::Vector{Int})
    fb = JS.first_byte(node)
    idx = searchsortedfirst(nontrivia_index, fb)
    idx > length(nontrivia_index) && return fb
    return nontrivia_index[idx]
end

# Lazy tooltip resolution avoids allocating full `show` output for complex types,
# but serializing `TypeInlayHintData` is more expensive than sending short
# tooltips. Keep simple scalar-like types eager and defer parameterized, alias,
# union, and other potentially expensive type displays.
function should_lazy_resolve_tooltip(@nospecialize rawtyp)
    rawtyp === Union{} && return false
    rawtyp isa DataType && isempty(rawtyp.parameters) && return false
    rawtyp isa TypeVar && return false
    return true
end

# Explain `Union{}` hints, which otherwise look like obscure valid syntax.
function format_type_inlay_hint_tooltip(@nospecialize(rawtyp), postprocessor::LSPostProcessor)
    if rawtyp === Union{}
        return "`Union{}` — this expression provably never produces a value (always throws, or is unreachable)."
    end
    full_typstr = postprocessor(sprint(show, rawtyp))
    return "```julia\n$full_typstr\n```"
end

# Resolve a lazy type-hint tooltip by recomputing the type for the source range
# stored in `hint.data`, leaving stale or already-resolved hints unchanged.
function resolve_inlay_hint(
        state::ServerState, hint::InlayHint, cancel_flag::CancelFlag = CancelFlag(false)
    )
    data = @something hint.data return hint
    data.firstByte <= data.lastByte || return hint
    type_range = data.firstByte:data.lastByte
    result = get_file_info(state, data.uri, cancel_flag)
    if isnothing(result)
        return nothing
    elseif result isa ResponseError
        return result
    end
    fi = result
    fi.version == data.version || return hint
    st0_top = build_syntax_tree(fi)
    pos = offset_to_xy(fi, data.firstByte)
    (; context_module, postprocessor, world) = get_context_info(state, data.uri, pos)
    ctx = @something build_inferred_context_for_range(
        st0_top, context_module, type_range;
        world, caller="inlayHint/resolve", cache=fi.inferred_context_cache) return hint
    typ = @something get_type_for_range(ctx, type_range) return hint
    rawtyp = CC.widenconst(typ)
    tooltip = format_type_inlay_hint_tooltip(rawtyp, postprocessor)
    return InlayHint(hint; tooltip)
end
