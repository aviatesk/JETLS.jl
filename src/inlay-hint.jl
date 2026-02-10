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

# JETLS: TYPE_INLAY_HINT_ENABLED
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
        startpos = offset_to_xy(fi, Int(JS.first_byte(node)))
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
        callee_ranges = Set{UnitRange{UInt32}}()
        paren_wrap_ranges = Set{UnitRange{UInt32}}()
        noparen_mc_ends = Set{UInt32}()
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
            if JS.kind(node) in JS.KSet"call dotcall" &&
               JS.numchildren(node) >= 1
                ci = _callee_child_index(node)
                push!(callee_ranges, JS.byte_range(node[ci]))
            end
        end
        traverse(st0, #=postorder=#true) do node::JS.SyntaxTree
            byterng = JS.byte_range(node)
            k = JS.kind(node)
            if k in JS.KSet"call dotcall"
                nc = JS.numchildren(node)
                nc >= 1 || return
                ci = _callee_child_index(node)
                callee_rng = JS.byte_range(node[ci])
                typ = get_type_for_range(inferred_tree, byterng)
                if typ === nothing
                    typ = _get_call_return_type(inferred_tree, callee_rng)
                end
                if typ !== nothing &&
                   should_annotate_type(typ)
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
            elseif k in JS.KSet"= op="
                return nothing
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
    end
    return inlay_hints
end
