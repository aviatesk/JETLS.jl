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
    uri = msg.params.textDocument.uri
    range = msg.params.range

    result = get_file_info(server.state, uri, cancel_flag)
    if isnothing(result)
        return send(server, InlayHintResponse(; id = msg.id, result = null))
    elseif result isa ResponseError
        return send(server, InlayHintResponse(; id = msg.id, result = nothing, error = result))
    end
    fi = result

    min_lines = get_config(server, :inlay_hint, :block_end_min_lines)
    inlay_hints = InlayHint[]
    symbols = get_document_symbols!(server.state, uri, fi)
    syntactic_inlay_hints!(inlay_hints, symbols, fi, range; min_lines)

    st0_top = build_syntax_tree(fi)
    type_inlay_hints!(inlay_hints, server.state, fi,
        st0_top, uri, range)

    return send(server, InlayHintResponse(;
        id = msg.id,
        result = @somereal inlay_hints null))
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
            startswith(lstrip(commentstr), "# $keyword") ||
            startswith(lstrip(commentstr), "#= $keyword"))
            return
        end
    end
    newText = " #= "* label * " =#"
    offset = encoded_length(newText, fi.encoding)
    textEdits = TextEdit[TextEdit(;
        range = Range(;
            start = Position(endpos; character = endpos.character+1),
            var"end" = Position(endpos; character = endpos.character+1+offset)),
        newText)]
    push!(inlay_hints, InlayHint(;
        position = endpos,
        textEdits,
        label = String(label),
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
        startswith(detail, "if") && return "if", first(split(detail, '\n'))
        startswith(detail, "@static if") && return "@static if", first(split(detail, '\n'))
        startswith(detail, "let") && return "let", first(split(detail, '\n'))
        startswith(detail, "for") && return "for", first(split(detail, '\n'))
        startswith(detail, "while") && return "while", first(split(detail, '\n'))
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

const TYPE_INLAY_HINT_MARKER = "# JETLS: TYPE_INLAY_HINT_ENABLED"

function has_type_inlay_hint_marker(
        ps::JS.ParseStream, first_byte::Integer
    )
    tc = @something token_at_offset(ps, Int(first_byte)) return false
    while true
        tc = @something prev_tok(tc) return false
        k = JS.kind(tc)
        if k === JS.K"Comment"
            text = String(ps.textbuf[JS.byte_range(tc)])
            return startswith(text, TYPE_INLAY_HINT_MARKER)
        elseif JS.is_whitespace(k)
            continue
        else
            return false
        end
    end
end

function should_annotate_type(@nospecialize(typ))
    return !(typ isa Core.Const)
end

function _get_call_return_type(inferred_tree::JL.SyntaxTree, callee_range::UnitRange{Int})
    ret_typ = Ref{Any}(nothing)
    traverse(inferred_tree) do st5::JL.SyntaxTree
        if (is_from_user_ast(JS.flattened_provenance(st5)) &&
            JS.byte_range(st5) == callee_range && hasproperty(st5, :type))
            ntyp = st5.type
            ntyp isa Core.Const && return
            if ret_typ[] === nothing
                ret_typ[] = ntyp
            else
                ret_typ[] = CC.tmerge(ntyp, ret_typ[])
            end
        end
    end
    return ret_typ[]
end

_callee_child_index(node::JS.SyntaxTree) =
    (JS.is_infix_op_call(node) || JS.is_postfix_op_call(node)) ? 2 : 1

function _funcdef_call_node(funcdef::JS.SyntaxTree)
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

function _get_funcdef_return_type(
        inferred_tree::JL.SyntaxTree, func_range::UnitRange{Int}
    )
    ret_typ = Ref{Any}(nothing)
    traverse(inferred_tree) do st5::JL.SyntaxTree
        JS.kind(st5) === JS.K"method" || return
        JS.byte_range(st5) == func_range || return
        for i = 1:JS.numchildren(st5)
            child = st5[i]
            JS.kind(child) === JS.K"code_info" || continue
            JS.numchildren(child) >= 1 || continue
            block = child[1]
            for j = 1:JS.numchildren(block)
                stmt = block[j]
                if JS.kind(stmt) === JS.K"return" && hasproperty(stmt, :type)
                    ntyp = stmt.type
                    if ret_typ[] === nothing
                        ret_typ[] = ntyp
                    else
                        ret_typ[] = CC.tmerge(ntyp, ret_typ[])
                    end
                end
            end
        end
    end
    return ret_typ[]
end

function _emit_type_hint!(
        inlay_hints::Vector{InlayHint}, node::JS.SyntaxTree, @nospecialize(typ),
        fi::FileInfo, range::Range, postprocessor::LSPostProcessor;
        open_paren::Bool = false,
        close_paren_before_type::Bool = false,
        close_paren_after_type::Bool = false
    )
    last_byte = Int(JS.last_byte(node))
    endpos = offset_to_xy(fi, last_byte + 1)
    endpos ∉ range && return
    typstr = postprocessor(string(CC.widenconst(typ))::String)
    if open_paren
        n_parens = max(close_paren_before_type + close_paren_after_type, 1)
        # In the EST, compound nodes' `first_byte` includes leading trivia,
        # and children may not be in source order (e.g., infix calls have the
        # operator as child[1]). Find the earliest child `first_byte` to get
        # the position of the first actual token.
        fb = Int(JS.first_byte(node))
        nc = JS.numchildren(node)
        if nc >= 1
            min_cfb = typemax(Int)
            for i in 1:nc
                child = node[i]
                JS.kind(child) === JS.K"Value" && continue
                cfb = Int(JS.first_byte(child))
                min_cfb = min(min_cfb, cfb)
            end
            if min_cfb < typemax(Int)
                fb = min_cfb
            end
        end
        startpos = offset_to_xy(fi, fb)
        push!(inlay_hints, InlayHint(;
            position = startpos,
            label = "(" ^ n_parens,
            kind = InlayHintKind.Type,
            paddingLeft = false))
    end
    pre = close_paren_before_type ? ")" : ""
    post = close_paren_after_type ? ")" : ""
    push!(inlay_hints, InlayHint(;
        position = endpos,
        label = "$pre::$typstr$post",
        kind = InlayHintKind.Type,
        paddingLeft = false))
    return nothing
end

function _collect_type_inlay_hints!(
        inlay_hints::Vector{InlayHint}, st0::JS.SyntaxTree,
        inferred_tree::JL.SyntaxTree, fi::FileInfo,
        range::Range, postprocessor::LSPostProcessor
    )
    callee_ranges = Set{UnitRange{UInt32}}()
    paren_wrap_ranges = Set{UnitRange{UInt32}}()
    noparen_mc_ends = Set{UInt32}()
    funcdef_sig_ranges = Set{UnitRange{UInt32}}()
    traverse(st0) do node::JS.SyntaxTree
        if JS.kind(node) === JS.K"." && JS.numchildren(node) >= 2
            push!(paren_wrap_ranges, JS.byte_range(node[1]))
            push!(callee_ranges, JS.byte_range(node[2]))
        end
        if JS.kind(node) === JS.K"ref" && JS.numchildren(node) >= 1
            push!(paren_wrap_ranges, JS.byte_range(node[1]))
        end
        if noparen_macrocall(node)
            push!(noparen_mc_ends, JS.last_byte(node))
        end
        if JS.kind(node) in JS.KSet"call dotcall" && JS.numchildren(node) >= 1
            ci = _callee_child_index(node)
            push!(callee_ranges, JS.byte_range(node[ci]))
        end
        if JS.kind(node) in JS.KSet"function macro"
            call_node = _funcdef_call_node(node)
            if call_node !== nothing
                push!(funcdef_sig_ranges, JS.byte_range(call_node))
            end
        end
        if JS.kind(node) === JS.K"?" && JS.numchildren(node) >= 1
            push!(paren_wrap_ranges, JS.byte_range(node[1]))
        end
        if JS.kind(node) === JS.K"=" && JS.numchildren(node) >= 1
            lhs = node[1]
            if JS.kind(lhs) === JS.K"Identifier"
                push!(callee_ranges, JS.byte_range(lhs))
            end
        end
        if JS.kind(node) === JS.K"unknown_head" && JS.numchildren(node) >= 1
            # Compound assignment (`op=`) lowering introduces operator
            # references that pollute the LHS byte range.
            push!(callee_ranges, JS.byte_range(node[1]))
        end
        if JS.kind(node) === JS.K"::" && JS.numchildren(node) >= 1
            push!(callee_ranges, JS.byte_range(node[1]))
        end
    end
    traverse(st0, #=postorder=#true) do node::JS.SyntaxTree
        byterng = JS.byte_range(node)
        k = JS.kind(node)
        if k in JS.KSet"call dotcall"
            byterng in funcdef_sig_ranges && return
            nc = JS.numchildren(node)
            nc >= 1 || return
            typ = get_type_for_range(inferred_tree, byterng)
            if typ === nothing
                ci = _callee_child_index(node)
                callee_rng = JS.byte_range(node[ci])
                typ = _get_call_return_type(inferred_tree, callee_rng)
            end
            if typ !== nothing && should_annotate_type(typ)
                is_infix = JS.is_infix_op_call(node) || JS.is_postfix_op_call(node)
                is_dp = byterng in paren_wrap_ranges
                is_mc = !is_dp && !is_infix && JS.last_byte(node) in noparen_mc_ends
                _emit_type_hint!(
                    inlay_hints, node, typ,
                    fi, range, postprocessor;
                    open_paren = is_infix || is_dp || is_mc,
                    close_paren_before_type = is_infix || is_mc,
                    close_paren_after_type = is_dp)
            end
        elseif k === JS.K"macrocall" && is_special_macrocall(node)
            typ = @something get_type_for_macroexpansion(inferred_tree, byterng) return nothing
            should_annotate_type(typ) || return
            _emit_type_hint!(
                inlay_hints, node, typ,
                fi, range, postprocessor)
        elseif k in JS.KSet"= unknown_head for while in iteration block let"
            return nothing
        elseif k === JS.K"?"
            typ = @something get_type_for_range(inferred_tree, byterng) return nothing
            should_annotate_type(typ) || return
            _emit_type_hint!(
                inlay_hints, node, typ,
                fi, range, postprocessor;
                open_paren = true,
                close_paren_before_type = true)
        elseif k in JS.KSet"function macro"
            call_node = @something _funcdef_call_node(node) return nothing
            ret_typ = @something _get_funcdef_return_type(inferred_tree, byterng) return nothing
            _emit_type_hint!(
                inlay_hints, call_node, ret_typ,
                fi, range, postprocessor)
        elseif byterng ∉ callee_ranges
            typ = @something get_type_for_range(inferred_tree, byterng) return nothing
            should_annotate_type(typ) || return
            is_dp = byterng in paren_wrap_ranges
            is_mc = !is_dp && JS.last_byte(node) in noparen_mc_ends
            _emit_type_hint!(
                inlay_hints, node, typ,
                fi, range, postprocessor;
                open_paren = is_dp || is_mc,
                close_paren_before_type = is_mc,
                close_paren_after_type = is_dp)
        end
    end
    return inlay_hints
end

function type_inlay_hints!(
        inlay_hints::Vector{InlayHint}, state::ServerState, fi::FileInfo,
        st0_top::JS.SyntaxTree, uri::URI, range::Range
    )
    iterate_toplevel_tree(st0_top) do st0::JS.SyntaxTree
        fb = Int(JS.first_byte(st0))
        has_type_inlay_hint_marker(fi.parsed_stream, fb) || return nothing
        pos = offset_to_xy(fi, fb)
        (; mod, postprocessor) = get_context_info(state, uri, pos)
        (; ctx3, st3) = @something get_inferrable_tree(st0, mod) return nothing
        inferred_tree = @something infer_toplevel_tree(ctx3, st3, mod) return nothing
        _collect_type_inlay_hints!(
            inlay_hints, st0, inferred_tree, fi, range, postprocessor)
    end
    return inlay_hints
end
