# DocumentSymbol feature implementation
#
# The basic approach is to first analyze `st0` and collect top-level symbols through surface
# AST level analysis.
# Then, for top-level trees that introduce local scopes, we perform scope analysis
# (i.e. get `ctx3`) to collect bindings for each local scope.
#
# A drawback of this approach is that macro expansion is not performed in the top-level
# surface AST level analysis, so cases like `@enum` cannot be fully handled.
# However, if we were to analyze `st1` after macro expansion, we would need to analyze
# much more complex ASTs than `st0`, and the algorithmic complexity would increase
# significantly, especially since K"escape" and K"hygienic-scope" are introduced at
# unspecified locations.
# The current approach of performing scope analysis only on trees that introduce local
# scopes seems to achieve a good trade-off between implementation complexity and analysis
# result accuracy.
#
# To compensate for the lack of macro expansion, this algorithm includes special-case
# handling for common macros like `@enum`.

const DOCUMENT_SYMBOL_REGISTRATION_ID = "jetls-document-symbol"
const DOCUMENT_SYMBOL_REGISTRATION_METHOD = "textDocument/documentSymbol"

function document_symbol_options()
    return DocumentSymbolOptions()
end

function document_symbol_registration()
    return Registration(;
        id = DOCUMENT_SYMBOL_REGISTRATION_ID,
        method = DOCUMENT_SYMBOL_REGISTRATION_METHOD,
        registerOptions = DocumentSymbolRegistrationOptions(;
            documentSelector = DEFAULT_DOCUMENT_SELECTOR,
        )
    )
end

function handle_DocumentSymbolRequest(
        server::Server, msg::DocumentSymbolRequest, cancel_flag::CancelFlag)
    state = server.state
    uri = msg.params.textDocument.uri
    result = get_file_info(state, uri, cancel_flag)
    if isnothing(result)
        return send(server, DocumentSymbolResponse(; id = msg.id, result = null))
    elseif result isa ResponseError
        return send(server, DocumentSymbolResponse(; id = msg.id, result = nothing, error = result))
    end
    fi = result
    symbols = get_document_symbols!(state, uri, fi)
    result = isempty(symbols) ? null : map(strip_name_from_detail, symbols)
    return send(server, DocumentSymbolResponse(; id = msg.id, result))
end

function strip_name_from_detail(sym::DocumentSymbol)
    detail = sym.detail
    if detail !== nothing && startswith(detail, sym.name)
        rest = lstrip(detail[ncodeunits(sym.name)+1:end])
        detail = isempty(rest) ? nothing : String(rest)
    end
    children = sym.children
    if children !== nothing
        children = map(strip_name_from_detail, children)
    end
    return DocumentSymbol(sym; detail, children)
end

function get_document_symbols!(state::ServerState, uri::URI, fi::FileInfo)
    return store!(state.document_symbol_cache) do cache::DocumentSymbolCacheData
        if haskey(cache, uri)
            symbols = cache[uri]
            return cache, symbols
        end
        st0 = build_syntax_tree(fi)
        pos = Position(; line=0, character=0)
        (; mod) = get_context_info(state, uri, pos)
        symbols = extract_document_symbols(st0, fi, mod)
        return DocumentSymbolCacheData(cache, uri => symbols), symbols
    end
end

function invalidate_document_symbol_cache!(state::ServerState, uri::URI)
    store!(state.document_symbol_cache) do cache::DocumentSymbolCacheData
        if haskey(cache, uri)
            Base.delete(cache, uri), nothing
        else
            cache, nothing
        end
    end
end

function extract_document_symbols(st0_top::JS.SyntaxTree, fi::FileInfo, mod::Module=Main)
    @assert JS.kind(st0_top) === JS.K"toplevel"
    symbols = DocumentSymbol[]
    extract_toplevel_symbols!(symbols, st0_top, fi, mod)
    sort!(symbols; by = s::DocumentSymbol -> (s.range.start.line, s.range.start.character))
    return symbols
end

function extract_toplevel_symbols!(
        symbols::Vector{DocumentSymbol}, st0::JS.SyntaxTree, fi::FileInfo, mod::Module
    )
    for i = 1:JS.numchildren(st0)
        extract_toplevel_symbol!(symbols, st0[i], fi, mod)
    end
end

function extract_toplevel_symbol!(symbols::Vector{DocumentSymbol}, st0::JS.SyntaxTree, fi::FileInfo, mod::Module)
    k = JS.kind(st0)
    if k === JS.K"module" || k === JS.K"baremodule"
        extract_module_symbol!(symbols, st0, fi, mod)
    elseif k === JS.K"function"
        extract_function_symbol!(symbols, st0, fi, mod)
    elseif k === JS.K"macro"
        extract_macro_symbol!(symbols, st0, fi, mod)
    elseif k === JS.K"struct"
        extract_struct_symbol!(symbols, st0, fi, mod)
    elseif k === JS.K"abstract"
        extract_abstract_type_symbol!(symbols, st0, fi)
    elseif k === JS.K"primitive"
        extract_primitive_type_symbol!(symbols, st0, fi)
    elseif k === JS.K"const"
        extract_const_symbols!(symbols, st0, fi, mod)
    elseif k === JS.K"global"
        extract_global_symbols!(symbols, st0, fi, mod)
    elseif k === JS.K"="
        extract_toplevel_assignment_symbols!(symbols, st0, fi, mod)
    elseif k === JS.K"let"
        extract_let_symbol!(symbols, st0, fi, mod)
    elseif k === JS.K"while"
        extract_while_symbol!(symbols, st0, fi, mod)
    elseif k === JS.K"for"
        extract_for_symbol!(symbols, st0, fi, mod)
    elseif k === JS.K"if"
        extract_if_symbol!(symbols, st0, fi, mod)
    elseif k === JS.K"toplevel" || k === JS.K"block"
        extract_toplevel_symbols!(symbols, st0, fi, mod)
    elseif k === JS.K"macrocall"
        extract_macrocall_symbol!(symbols, st0, fi, mod)
    elseif k === JS.K"doc"
        extract_doc_symbol!(symbols, st0, fi, mod)
    end
    return nothing
end

function extract_module_symbol!(
        symbols::Vector{DocumentSymbol}, st0::JS.SyntaxTree, fi::FileInfo, parent_mod::Module
    )
    JS.numchildren(st0) ≥ 2 || return nothing
    name_node = st0[1]
    name = @something extract_name_val(name_node) return nothing
    mod = parent_mod
    if invokelatest(isdefinedglobal, parent_mod, Symbol(name))
        mod = invokelatest(getglobal, parent_mod, Symbol(name))::Module
    end
    children = DocumentSymbol[]
    body = st0[end]
    if JS.kind(body) === JS.K"block"
        extract_toplevel_symbols!(children, body, fi, mod)
    end
    is_baremodule = JS.has_flags(JS.flags(st0), JS.BARE_MODULE_FLAG)
    detail = (is_baremodule ? "baremodule " : "module ") * name
    push!(symbols, DocumentSymbol(;
        name,
        detail,
        kind = SymbolKind.Module,
        range = jsobj_to_range(st0, fi),
        selectionRange = jsobj_to_range(name_node, fi),
        children = @somereal children Some(nothing)))
    return nothing
end

function extract_function_symbol!(
        symbols::Vector{DocumentSymbol}, st0::JS.SyntaxTree, fi::FileInfo, mod::Module
    )
    JS.numchildren(st0) ≥ 1 || return nothing
    sig = st0[1]
    name, name_node = @something extract_function_name(sig) return nothing
    children = @something extract_scoped_children(st0, fi, mod) Some(nothing)
    is_short_form = JS.has_flags(JS.flags(st0), JS.SHORT_FORM_FUNCTION_FLAG)
    detail = is_short_form ? JS.sourcetext(sig) * " =" : "function " * JS.sourcetext(sig)
    push!(symbols, DocumentSymbol(;
        name,
        detail,
        kind = SymbolKind.Function,
        range = jsobj_to_range(st0, fi),
        selectionRange = jsobj_to_range(name_node, fi),
        children))
    return nothing
end

function extract_function_name(sig::JS.SyntaxTree)
    sig = unwrap_where(sig)
    k = JS.kind(sig)
    if k === JS.K"::"
        JS.numchildren(sig) ≥ 1 || return nothing
        return extract_function_name(sig[1])::Union{Nothing,Tuple{String,JS.SyntaxTree}}
    end
    if k === JS.K"call" || k === JS.K"dotcall"
        JS.numchildren(sig) ≥ 1 || return nothing
        callee = sig[1]
        if JS.kind(callee) === JS.K"::"
            JS.numchildren(callee) ≥ 1 || return nothing
            callee = callee[1]
        end
        name = @something extract_dotted_name(callee) return nothing
        return (name, callee)
    elseif k === JS.K"tuple"
        return nothing
    elseif JS.is_identifier(k)
        name = @something extract_name_val(sig) return nothing
        return (name, sig)
    elseif k === JS.K"."
        name = @something extract_dotted_name(sig) return nothing
        return (name, sig)
    end
    return nothing
end

function extract_dotted_name(node::JS.SyntaxTree)
    k = JS.kind(node)
    if JS.is_identifier(k)
        return extract_name_val(node)
    elseif k === JS.K"."
        JS.numchildren(node) ≥ 2 || return nothing
        lhs = @something extract_dotted_name(node[1]) return nothing
        rhs_node = node[2]
        rhs = @something if JS.kind(rhs_node) === JS.K"quote" && JS.numchildren(rhs_node) ≥ 1
            extract_name_val(rhs_node[1])
        else
            extract_name_val(rhs_node)
        end return nothing
        return lhs * "." * rhs
    elseif k === JS.K"curly"
        JS.numchildren(node) ≥ 1 || return nothing
        return extract_dotted_name(node[1])
    end
    return nothing
end

function extract_macro_symbol!(
        symbols::Vector{DocumentSymbol}, st0::JS.SyntaxTree, fi::FileInfo, mod::Module
    )
    JS.numchildren(st0) ≥ 1 || return nothing
    sig_orig = st0[1]
    sig = unwrap_where(sig_orig)
    if JS.kind(sig) === JS.K"call"
        JS.numchildren(sig) ≥ 1 || return nothing
        callee = sig[1]
        name = @something extract_name_val(callee) return nothing
        name_node = callee
    elseif JS.is_identifier(sig)
        name = @something extract_name_val(sig) return nothing
        name_node = sig
    else
        return nothing
    end
    name = "@" * name
    detail = "macro " * JS.sourcetext(sig_orig)
    children = @something extract_scoped_children(st0, fi, mod) Some(nothing)
    push!(symbols, DocumentSymbol(;
        name,
        detail,
        kind = SymbolKind.Function,
        range = jsobj_to_range(st0, fi),
        selectionRange = jsobj_to_range(name_node, fi),
        children))
    return nothing
end

function extract_struct_symbol!(
        symbols::Vector{DocumentSymbol}, st0::JS.SyntaxTree, fi::FileInfo, mod::Module
    )
    JS.numchildren(st0) ≥ 1 || return nothing
    sig_node = st0[1]
    name_node = sig_node
    if JS.kind(name_node) === JS.K"<:"
        JS.numchildren(name_node) ≥ 1 || return nothing
        name_node = name_node[1]
    end
    if JS.kind(name_node) === JS.K"curly"
        JS.numchildren(name_node) ≥ 1 || return nothing
        name_node = name_node[1]
    end
    name = @something extract_name_val(name_node) return nothing
    is_mutable = JS.has_flags(JS.flags(st0), JS.MUTABLE_FLAG)
    detail = (is_mutable ? "mutable struct " : "struct ") * lstrip(JS.sourcetext(sig_node))
    children = DocumentSymbol[]
    if JS.numchildren(st0) ≥ 2
        body = st0[2]
        for i = 1:JS.numchildren(body)
            child = body[i]
            child_k = JS.kind(child)
            if child_k === JS.K"function"
                extract_function_symbol!(children, child, fi, mod)
            elseif child_k === JS.K"="
                extract_toplevel_assignment_symbols!(children, child, fi, mod)
            else
                extract_struct_field!(children, child, fi)
            end
        end
    end
    push!(symbols, DocumentSymbol(;
        name,
        detail,
        kind = SymbolKind.Struct,
        range = jsobj_to_range(st0, fi),
        selectionRange = jsobj_to_range(name_node, fi),
        children = @somereal children Some(nothing)))
    return nothing
end

function extract_struct_field!(
        symbols::Vector{DocumentSymbol}, st0::JS.SyntaxTree, fi::FileInfo
    )
    field_node = st0
    k = JS.kind(st0)
    if k === JS.K"const" && JS.numchildren(st0) ≥ 1
        field_node = st0[1]
        k = JS.kind(field_node)
    end
    name_node = field_node
    if k === JS.K"::" && JS.numchildren(field_node) ≥ 1
        name_node = field_node[1]
    end
    name = @something extract_name_val(name_node) return nothing
    detail = lstrip(JS.sourcetext(st0))
    push!(symbols, DocumentSymbol(;
        name,
        detail,
        kind = SymbolKind.Field,
        range = jsobj_to_range(st0, fi),
        selectionRange = jsobj_to_range(name_node, fi)))
    return nothing
end

function extract_abstract_type_symbol!(
        symbols::Vector{DocumentSymbol}, st0::JS.SyntaxTree, fi::FileInfo
    )
    JS.numchildren(st0) ≥ 1 || return nothing
    name_node = def_node = st0[1]
    if JS.kind(name_node) === JS.K"<:"
        JS.numchildren(name_node) ≥ 1 || return nothing
        name_node = name_node[1]
    end
    if JS.kind(name_node) === JS.K"curly"
        JS.numchildren(name_node) ≥ 1 || return nothing
        name_node = name_node[1]
    end
    name = @something extract_name_val(name_node) return nothing
    detail = "abstract type " * lstrip(JS.sourcetext(def_node))
    push!(symbols, DocumentSymbol(;
        name,
        detail,
        kind = SymbolKind.Interface,
        range = jsobj_to_range(st0, fi),
        selectionRange = jsobj_to_range(name_node, fi)))
    return nothing
end

function extract_primitive_type_symbol!(
        symbols::Vector{DocumentSymbol}, st0::JS.SyntaxTree, fi::FileInfo
    )
    JS.numchildren(st0) ≥ 2 || return nothing
    def_node = st0[1]
    bits_node = st0[2]
    name_node = def_node
    if JS.kind(name_node) === JS.K"<:"
        JS.numchildren(name_node) ≥ 1 || return nothing
        name_node = name_node[1]
    end
    name = @something extract_name_val(name_node) return nothing
    detail = "primitive type " * lstrip(JS.sourcetext(def_node)) * " " * JS.sourcetext(bits_node)
    push!(symbols, DocumentSymbol(;
        name,
        detail,
        kind = SymbolKind.Number,
        range = jsobj_to_range(st0, fi),
        selectionRange = jsobj_to_range(name_node, fi)))
    return nothing
end

function extract_const_symbols!(
        symbols::Vector{DocumentSymbol}, st0::JS.SyntaxTree, fi::FileInfo, mod::Module
    )
    JS.numchildren(st0) ≥ 1 || return nothing
    assign = st0[1]
    JS.kind(assign) === JS.K"=" || return nothing
    JS.numchildren(assign) ≥ 2 || return nothing
    lhs = assign[1]
    rhs = assign[2]
    range = jsobj_to_range(st0, fi)
    detail = lstrip(JS.sourcetext(st0))
    extract_assignment_symbols!(symbols, lhs, rhs, range, SymbolKind.Constant, detail, fi, mod)
    return nothing
end

function extract_global_symbols!(
        symbols::Vector{DocumentSymbol}, st0::JS.SyntaxTree, fi::FileInfo, mod::Module
    )
    JS.numchildren(st0) ≥ 1 || return nothing
    inner = st0[1]
    range = jsobj_to_range(st0, fi)
    detail = lstrip(JS.sourcetext(st0))
    if JS.kind(inner) === JS.K"="
        JS.numchildren(inner) ≥ 2 || return nothing
        lhs = inner[1]
        rhs = inner[2]
        extract_assignment_symbols!(symbols, lhs, rhs, range, SymbolKind.Variable, detail, fi, mod)
    else
        extract_assignment_symbols!(symbols, inner, nothing, range, SymbolKind.Variable, detail, fi, mod)
    end
    return nothing
end

function extract_assignment_symbols!(
        symbols::Vector{DocumentSymbol}, lhs::JS.SyntaxTree, rhs::Union{JS.SyntaxTree,Nothing},
        range::Range, kind::SymbolKind.Ty, detail::AbstractString, fi::FileInfo, mod::Module
    )
    children = if rhs !== nothing && JS.kind(rhs) === JS.K"let"
        let_children = DocumentSymbol[]
        extract_let_symbol!(let_children, rhs, fi, mod)
        @somereal let_children Some(nothing)
    else
        nothing
    end
    lhs_kind = JS.kind(lhs)
    if lhs_kind === JS.K"tuple"
        # Handle named tuple destructuring: `(; x, y) = ...`
        if JS.numchildren(lhs) == 1 && JS.kind(lhs[1]) === JS.K"parameters"
            params = lhs[1]
            for i = 1:JS.numchildren(params)
                name_node = params[i]
                name = @something extract_name_val(name_node) continue
                push!(symbols, DocumentSymbol(;
                    name,
                    detail,
                    kind,
                    range,
                    selectionRange = jsobj_to_range(name_node, fi),
                    children))
            end
        else
            # Handle regular tuple destructuring: `x, y = ...` or `(a, b) = ...`
            for i = 1:JS.numchildren(lhs)
                name_node = lhs[i]
                if JS.kind(name_node) === JS.K"::"
                    JS.numchildren(name_node) ≥ 1 || continue
                    name_node = name_node[1]
                end
                name = @something extract_name_val(name_node) continue
                push!(symbols, DocumentSymbol(;
                    name,
                    detail,
                    kind,
                    range,
                    selectionRange = jsobj_to_range(name_node, fi),
                    children))
            end
        end
    else
        name_node = lhs
        if lhs_kind === JS.K"::"
            JS.numchildren(lhs) ≥ 1 || return nothing
            name_node = lhs[1]
        end
        name = @something extract_name_val(name_node) return nothing
        push!(symbols, DocumentSymbol(;
            name,
            detail,
            kind,
            range,
            selectionRange = jsobj_to_range(name_node, fi),
            children))
    end
    if rhs !== nothing && JS.kind(rhs) === JS.K"block"
        extract_toplevel_symbols!(symbols, rhs, fi, mod)
    end
    return nothing
end

function extract_toplevel_assignment_symbols!(
        symbols::Vector{DocumentSymbol}, st0::JS.SyntaxTree, fi::FileInfo, mod::Module
    )
    JS.numchildren(st0) ≥ 2 || return nothing
    lhs = st0[1]
    JS.kind(lhs) in JS.KSet". ref" && return nothing # Skip property assignment like obj.field = value
    rhs = st0[2]
    range = jsobj_to_range(st0, fi)
    detail = lstrip(JS.sourcetext(st0))
    kind = is_anonymous_function_rhs(rhs) ? SymbolKind.Function : SymbolKind.Variable
    extract_assignment_symbols!(symbols, lhs, rhs, range, kind, detail, fi, mod)
    return nothing
end

extract_let_symbol!(args...) = extract_namespace_symbol!(args..., "let ")

extract_while_symbol!(args...) = extract_namespace_symbol!(args..., "while ")

extract_for_symbol!(args...) = extract_namespace_symbol!(args..., "for ")

function extract_namespace_symbol!(
        symbols::Vector{DocumentSymbol}, st0::JS.SyntaxTree, fi::FileInfo, mod::Module,
        prefix::AbstractString
    )
    JS.numchildren(st0) ≥ 2 || return nothing
    children = @something extract_scoped_children(st0, fi, mod) return nothing
    body = st0[end]
    if JS.kind(body) === JS.K"block"
        extract_macrocalls_from_block!(children, body, fi, mod)
    end
    push!(symbols, DocumentSymbol(;
        name = " ",
        detail = rstrip(prefix * lstrip(JS.sourcetext(st0[1]))),
        kind = SymbolKind.Namespace,
        range = jsobj_to_range(st0, fi),
        selectionRange = jsobj_to_range(st0[1], fi),
        children))
    return nothing
end

function extract_if_symbol!(
        symbols::Vector{DocumentSymbol}, st0::JS.SyntaxTree, fi::FileInfo, mod::Module;
        prefix::AbstractString="if ",
        range_node::JS.SyntaxTree=st0
    )
    JS.numchildren(st0) ≥ 2 || return nothing
    children = DocumentSymbol[]
    extract_if_children!(children, st0, fi, mod)
    isempty(children) && return nothing
    push!(symbols, DocumentSymbol(;
        name = " ",
        detail = rstrip(prefix * lstrip(JS.sourcetext(st0[1]))),
        kind = SymbolKind.Namespace,
        range = jsobj_to_range(range_node, fi),
        selectionRange = jsobj_to_range(st0[1], fi),
        children))
    return nothing
end

function extract_if_children!(
        children::Vector{DocumentSymbol}, st0::JS.SyntaxTree, fi::FileInfo, mod::Module
    )
    for i in 2:JS.numchildren(st0)
        child = st0[i]
        k = JS.kind(child)
        if k === JS.K"block"
            extract_toplevel_symbols!(children, child, fi, mod)
        elseif k === JS.K"elseif" || k === JS.K"if"
            extract_if_children!(children, child, fi, mod)
        end
    end
    return nothing
end

function extract_macrocalls_from_block!(
        symbols::Vector{DocumentSymbol}, st::JS.SyntaxTree, fi::FileInfo, mod::Module
    )
    for i = 1:JS.numchildren(st)
        child = st[i]
        if JS.kind(child) === JS.K"macrocall"
            extract_macrocall_symbol!(symbols, child, fi, mod)
        end
    end
    return nothing
end

function extract_macrocall_symbol!(
        symbols::Vector{DocumentSymbol}, st0::JS.SyntaxTree, fi::FileInfo, mod::Module
    )
    macro_name = get_macrocall_name(st0)
    if macro_name == "@enum"
        extract_enum_symbol!(symbols, st0, fi)
    elseif macro_name == "@static"
        extract_static_if_symbol!(symbols, st0, fi, mod)
    elseif macro_name == "@testset"
        extract_testset_symbol!(symbols, st0, fi, mod)
    elseif macro_name == "@test"
        extract_test_symbol!(symbols, st0, fi)
    else
        extract_toplevel_symbols!(symbols, st0, fi, mod)
    end
    return nothing
end

function extract_static_if_symbol!(
        symbols::Vector{DocumentSymbol}, st0::JS.SyntaxTree, fi::FileInfo, mod::Module
    )
    JS.numchildren(st0) ≥ 2 || return nothing
    if_node = st0[2]
    JS.kind(if_node) === JS.K"if" || return nothing
    extract_if_symbol!(symbols, if_node, fi, mod; prefix="@static if ", range_node=st0)
    return nothing
end

function get_macrocall_name(st0::JS.SyntaxTree)
    JS.numchildren(st0) ≥ 1 || return nothing
    macro_node = st0[1]
    if JS.kind(macro_node) === JS.K"."
        JS.numchildren(macro_node) ≥ 2 || return nothing
        rhs = macro_node[2]
        if JS.kind(rhs) === JS.K"quote" && JS.numchildren(rhs) ≥ 1
            return extract_name_val(rhs[1])
        else
            return extract_name_val(rhs)
        end
    else
        return extract_name_val(macro_node)
    end
end

function extract_testset_symbol!(
        symbols::Vector{DocumentSymbol}, st0::JS.SyntaxTree, fi::FileInfo, mod::Module
    )
    JS.numchildren(st0) ≥ 2 || return nothing

    # Find the description string node (may not be at position 2 if CustomTestSet or options are present)
    description_node = nothing
    for i = 2:JS.numchildren(st0)-1
        child = st0[i]
        if JS.kind(child) === JS.K"string"
            description_node = child
            break
        end
    end
    description = isnothing(description_node) ? "" : @something extract_string_content(description_node) ""

    body = st0[end]
    body_kind = JS.kind(body)
    children = DocumentSymbol[]
    if body_kind === JS.K"block"
        extract_toplevel_symbols!(children, body, fi, mod)
    elseif body_kind === JS.K"for" || body_kind === JS.K"let"
        JS.numchildren(body) ≥ 2 || return nothing
        body_block = body[end]
        if JS.kind(body_block) === JS.K"block"
            extract_toplevel_symbols!(children, body_block, fi, mod)
        end
    elseif body_kind === JS.K"call"
        # Function call: @testset "desc" test_func()
        # No children to extract, the test function itself is the body
    else
        extract_toplevel_symbol!(children, body, fi, mod)
    end

    # For @testset let, use bindings node as selection range since there's no description
    selection_node = !isnothing(description_node) ? description_node :
        body_kind === JS.K"let" ? body[1] : body

    push!(symbols, DocumentSymbol(;
        name = isempty(description) ? "@testset" : ("@testset \"$(description)\""),
        detail = first(split(JS.sourcetext(st0), '\n')),
        kind = SymbolKind.Event,
        range = jsobj_to_range(st0, fi),
        selectionRange = jsobj_to_range(selection_node, fi),
        children = @somereal children Some(nothing)))
    return nothing
end

function extract_string_content(st0::JS.SyntaxTree)
    JS.kind(st0) === JS.K"string" || return nothing
    JS.numchildren(st0) ≥ 1 || return nothing
    first_child = st0[1]
    if JS.numchildren(st0) == 1 && JS.kind(first_child) === JS.K"String"
        # Simple string without interpolation
        return JS.hasattr(first_child, :value) ? first_child.value : nothing
    else
        # Interpolated string - extract content from source text
        src = JS.sourcetext(st0)
        return startswith(src, '"') && endswith(src, '"') ? strip(src, '"') : src
    end
end

function extract_test_symbol!(symbols::Vector{DocumentSymbol}, st0::JS.SyntaxTree, fi::FileInfo)
    JS.numchildren(st0) ≥ 2 || return nothing
    expr_node = st0[2]
    expr_text = lstrip(JS.sourcetext(expr_node))
    push!(symbols, DocumentSymbol(;
        name = expr_text,
        detail = "@test " * expr_text,
        kind = SymbolKind.Boolean,
        range = jsobj_to_range(st0, fi),
        selectionRange = jsobj_to_range(expr_node, fi)))
    return nothing
end

function extract_enum_symbol!(symbols::Vector{DocumentSymbol}, st0::JS.SyntaxTree, fi::FileInfo)
    JS.numchildren(st0) ≥ 2 || return nothing
    type_node = st0[2]
    name_node = type_node
    if JS.kind(type_node) === JS.K"::"
        JS.numchildren(type_node) ≥ 1 || return nothing
        name_node = type_node[1]
    end
    name = @something extract_name_val(name_node) return nothing
    children = DocumentSymbol[]
    for i = 3:JS.numchildren(st0)
        extract_enum_value!(children, st0[i], name, fi)
    end
    push!(symbols, DocumentSymbol(;
        name,
        detail = "@enum " * lstrip(JS.sourcetext(type_node)),
        kind = SymbolKind.Enum,
        range = jsobj_to_range(st0, fi),
        selectionRange = jsobj_to_range(name_node, fi),
        children = @somereal children Some(nothing)))
    return nothing
end

function extract_enum_value!(
        symbols::Vector{DocumentSymbol}, st0::JS.SyntaxTree, enum_name::String, fi::FileInfo
    )
    if JS.kind(st0) === JS.K"block"
        for i = 1:JS.numchildren(st0)
            extract_enum_value!(symbols, st0[i], enum_name, fi)
        end
        return nothing
    end
    name_node = st0
    if JS.kind(st0) === JS.K"="
        JS.numchildren(st0) ≥ 1 || return nothing
        name_node = st0[1]
    end
    name = @something extract_name_val(name_node) return nothing
    push!(symbols, DocumentSymbol(;
        name,
        detail = name * "::" * enum_name,
        kind = SymbolKind.EnumMember,
        range = jsobj_to_range(st0, fi),
        selectionRange = jsobj_to_range(name_node, fi)))
    return nothing
end

function extract_doc_symbol!(
        symbols::Vector{DocumentSymbol}, st0::JS.SyntaxTree, fi::FileInfo, mod::Module
    )
    JS.numchildren(st0) ≥ 2 || return nothing
    definition = st0[2]
    temp_symbols = DocumentSymbol[]
    extract_toplevel_symbol!(temp_symbols, definition, fi, mod)
    isempty(temp_symbols) && return nothing
    range = jsobj_to_range(st0, fi)
    for sym in temp_symbols
        push!(symbols, DocumentSymbol(sym; range))
    end
    return nothing
end

# Binding-based extraction for scoped children (function body, let block, etc.)
function extract_scoped_children(st0::JS.SyntaxTree, fi::FileInfo, mod::Module)
    (; ctx3) = try
        jl_lower_for_scope_resolution(mod, st0)
    catch
        return nothing
    end
    parent_map = build_parent_map(st0)
    # Pass the root construct's range so that scope analysis doesn't create
    # duplicate Namespace symbols for the root construct itself
    root_range = (JS.first_byte(st0), JS.last_byte(st0))
    return @somereal extract_local_symbols_from_scopes(ctx3, parent_map, fi, root_range) Some(nothing)
end

build_parent_map(st0::JS.SyntaxTree) =
    build_parent_map!(Dict{Tuple{Int,Int},JS.SyntaxTree}(), st0, nothing)
function build_parent_map!(
        map::Dict{Tuple{Int,Int},JS.SyntaxTree},
        st0::JS.SyntaxTree,
        parent::Union{Nothing,JS.SyntaxTree}
    )
    fb, lb = JS.first_byte(st0), JS.last_byte(st0)
    if parent !== nothing && !(iszero(fb) && iszero(lb))
        map[(fb,lb)] = parent
    end
    for i in 1:JS.numchildren(st0)
        build_parent_map!(map, st0[i], st0)
    end
    return map
end

function build_func_to_scopes(ctx3::JL.VariableAnalysisContext)
    func_to_scopes = Dict{Int,Vector{Int}}()
    kwsorter_to_func = Dict{Int,Int}()  # kwsorter bid → main func bid
    for (func_bid, cb) in ctx3.closure_bindings
        if !isempty(cb.lambdas)
            func_to_scopes[func_bid] = Int[lb.scope_id for lb in cb.lambdas]
        end
        binfo = JL.get_binding(ctx3, func_bid)
        # Detect kwsorter pattern: #funcname#N
        m = match(r"^#(.+)#\d+$", binfo.name)
        if m !== nothing
            main_func_name = m.captures[1]
            # Find the main function binding with this name
            for (other_bid, _) in ctx3.closure_bindings
                other_binfo = JL.get_binding(ctx3, other_bid)
                if other_binfo.name == main_func_name
                    kwsorter_to_func[func_bid] = other_bid
                    break
                end
            end
        end
    end
    # Merge kwsorter scopes into main function scopes
    for (kwsorter_bid, main_func_bid) in kwsorter_to_func
        if haskey(func_to_scopes, kwsorter_bid) && haskey(func_to_scopes, main_func_bid)
            append!(func_to_scopes[main_func_bid], func_to_scopes[kwsorter_bid])
        end
    end
    return func_to_scopes
end

struct LocalScopeContext
    ctx3::JL.VariableAnalysisContext
    parent_map::Dict{Tuple{Int,Int},JS.SyntaxTree}
    scope_children::Dict{Int,Vector{Int}}
    func_scope_ids::Set{Int}
    func_to_scopes::Dict{Int,Vector{Int}}
    fi::FileInfo
    seen::Set{Tuple{Int,Int}}
    root_range::Tuple{Int,Int}
end
function LocalScopeContext(
        lctx::LocalScopeContext;
        ctx3::JL.VariableAnalysisContext = lctx.ctx3,
        parent_map::Dict{Tuple{Int, Int}, JS.SyntaxTree} = lctx.parent_map,
        scope_children::Dict{Int, Vector{Int}} = lctx.scope_children,
        func_scope_ids::Set{Int} = lctx.func_scope_ids,
        func_to_scopes::Dict{Int, Vector{Int}} = lctx.func_to_scopes,
        fi::FileInfo = lctx.fi,
        seen::Set{Tuple{Int, Int}} = lctx.seen,
        root_range::Tuple{Int, Int} = lctx.root_range
    )
    return LocalScopeContext(
        ctx3, parent_map, scope_children, func_scope_ids, func_to_scopes, fi, seen, root_range
    )
end

function extract_local_symbols_from_scopes(
        ctx3::JL.VariableAnalysisContext, parent_map::Dict{Tuple{Int,Int},JS.SyntaxTree},
        fi::FileInfo, root_range::Tuple{Int,Int}=(0,0)
    )
    scopes = ctx3.scopes
    isempty(scopes) && return nothing
    func_to_scopes = build_func_to_scopes(ctx3)
    func_scope_ids = Set{Int}()
    for scope_ids in values(func_to_scopes)
        union!(func_scope_ids, scope_ids)
    end
    # Build scope tree from parent_id relationships (for hierarchical nesting)
    scope_children = Dict{Int,Vector{Int}}()
    for scope in scopes
        scope.parent_id == 0 && continue
        1 ≤ scope.parent_id ≤ length(scopes) || continue
        push!(get!(Vector{Int}, scope_children, scope.parent_id), scope.id)
    end
    # Root scopes: not nested function scopes, and parent is outside our scope set.
    # Descendant scopes are discovered through `scope_children` via `extract_child_scope_symbols!`.
    root_scope_ids = Int[]
    for scope in scopes
        scope.id in func_scope_ids && continue
        is_root = scope.parent_id == 0 || !(1 ≤ scope.parent_id ≤ length(scopes))
        is_root || continue
        push!(root_scope_ids, scope.id)
    end
    lctx = LocalScopeContext(ctx3, parent_map, scope_children, func_scope_ids,
        func_to_scopes, fi, Set{Tuple{Int,Int}}(), root_range)
    return extract_local_scope_bindings(lctx, root_scope_ids)
end

is_any_local_binding(binfo::JL.BindingInfo) =
    binfo.kind === :local || binfo.kind === :argument || binfo.kind === :static_parameter

function extract_local_scope_bindings(lctx::LocalScopeContext, scope_ids::Vector{Int})
    symbols = DocumentSymbol[]
    extract_local_scope_bindings!(symbols, lctx, scope_ids)
    return symbols
end
function extract_local_scope_bindings!(
        symbols::Vector{DocumentSymbol}, lctx::LocalScopeContext,
        scope_ids::Vector{Int}
    )
    (; ctx3, parent_map, scope_children, func_to_scopes, fi, seen) = lctx
    # Collect static parameter names from these scopes and all descendants
    # to avoid showing duplicate local variable references.
    # This is needed because `where` clauses create intermediate scope_blocks
    # with the type parameter as `:local`, while the function lambda scope
    # has the same name as `:static_parameter`.
    static_param_names = Set{String}()
    collect_static_param_names!(static_param_names, ctx3, scope_ids, scope_children)
    for scope_id in scope_ids
        1 ≤ scope_id ≤ length(ctx3.scopes) || continue
        scope = ctx3.scopes[scope_id]
        for (_, bid) in scope.vars
            binfo = JL.get_binding(ctx3, bid)
            binfo.is_internal && continue
            contains(binfo.name, '#') && continue
            binfo.kind === :global && continue
            # Skip non-static_parameter bindings if a static_parameter with the same name exists
            if binfo.kind !== :static_parameter && binfo.name in static_param_names
                continue
            end
            binding_node = JL.binding_ex(ctx3, bid)
            prov = JS.flattened_provenance(binding_node)
            isempty(prov) && continue
            source_node = first(prov)
            # TODO This is a variable introduced in macro expanded code
            # For now we completely ignore such cases, but in the future we might want to
            # include such variables as document-symbols too.
            # For example, variables like `group` that are implicitly introduced in cases like
            # `@info "log" x = x` may not be useful in most cases, but in cases like
            # `func(x) = (@asis y = 42; x + y)` using `macro asis(x); :($(esc(x))); end`,
            # we might want `y` to appear in the outline.
            if length(prov) > 1
                if !is_nospecialize_or_specialize_macrocall3(source_node)
                    continue
                end
            end
            fb, lb = JS.first_byte(source_node), JS.last_byte(source_node)
            (iszero(fb) && iszero(lb)) && continue
            # Skip duplicates (e.g., from kwsorter scope merging)
            (fb, lb) in seen && continue
            push!(seen, (fb, lb))
            range = jsobj_to_range(source_node, fi)
            selectionRange = range
            detail = nothing
            anon_scope_ids = nothing
            is_func = haskey(func_to_scopes, bid)
            if is_func
                kind = SymbolKind.Function
                parent = get(parent_map, (fb,lb), nothing)
                if !isnothing(parent) && JS.kind(parent) === JS.K"call"
                    call_fb, call_lb = JS.first_byte(parent), JS.last_byte(parent)
                    grandparent = get(parent_map, (call_fb, call_lb), nothing)
                    is_short_form = !isnothing(grandparent) &&
                        JS.kind(grandparent) === JS.K"function" &&
                        JS.has_flags(JS.flags(grandparent), JS.SHORT_FORM_FUNCTION_FLAG)
                    detail = is_short_form ?
                        JS.sourcetext(parent) * " =" :
                        "function " * JS.sourcetext(parent)
                end
            elseif binfo.kind === :static_parameter
                kind = SymbolKind.TypeParameter
                parent = get(parent_map, (fb,lb), nothing)
                if !isnothing(parent) && JS.kind(parent) === JS.K"<:"
                    detail = JS.sourcetext(parent)
                end
            elseif binfo.kind === :argument
                if JS.kind(source_node) === JS.K"macrocall"
                    detail = JS.sourcetext(source_node)
                else
                    detail = extract_argument_detail(parent_map, fb, lb)
                end
                # Why doesn't LSP provide `SymbolKind.Argument`?
                # It's absolutely necessary before `SymbolKind.Event`...
                # Anyway, here we use `SymbolKind.Object` to make it clear
                # that this is different from :local bindings
                kind = SymbolKind.Object
            else
                anon_scope_ids = find_anon_func_scope_ids(parent_map, fb, lb, func_to_scopes, ctx3)
                if anon_scope_ids !== nothing
                    kind = SymbolKind.Function
                    parent = get(parent_map, (fb, lb), nothing)
                    detail = !isnothing(parent) ? lstrip(JS.sourcetext(parent)) : nothing
                else
                    kind = SymbolKind.Variable
                    detail = extract_local_variable_detail(parent_map, fb, lb)
                end
            end
            children_symbols = nothing
            if is_func
                child_lctx = LocalScopeContext(lctx; seen=Set{Tuple{Int,Int}}(), root_range=(0, 0))
                children_symbols = extract_local_scope_bindings(child_lctx, func_to_scopes[bid])
            elseif anon_scope_ids !== nothing
                child_lctx = LocalScopeContext(lctx; seen=Set{Tuple{Int,Int}}(), root_range=(0, 0))
                children_symbols = extract_local_scope_bindings(child_lctx, anon_scope_ids)
            end
            push!(symbols, DocumentSymbol(;
                name = binfo.name,
                detail,
                kind,
                range,
                selectionRange,
                children = @somereal children_symbols Some(nothing)))
        end
        # Process child scopes to create hierarchical scope symbols
        extract_child_scope_symbols!(symbols, lctx, scope_id)
    end
    return symbols
end

function collect_static_param_names!(
        names::Set{String}, ctx3::JL.VariableAnalysisContext,
        scope_ids::Vector{Int}, scope_children::Dict{Int,Vector{Int}}
    )
    for scope_id in scope_ids
        1 ≤ scope_id ≤ length(ctx3.scopes) || continue
        for (_, bid) in ctx3.scopes[scope_id].vars
            binfo = JL.get_binding(ctx3, bid)
            binfo.kind === :static_parameter && push!(names, binfo.name)
        end
        child_ids = get(scope_children, scope_id, nothing)
        isnothing(child_ids) && continue
        collect_static_param_names!(names, ctx3, child_ids, scope_children)
    end
    return names
end

function extract_child_scope_symbols!(
        symbols::Vector{DocumentSymbol}, lctx::LocalScopeContext, scope_id::Int
    )
    (; ctx3, parent_map, scope_children, func_scope_ids, fi, seen, root_range) = lctx
    child_ids = @something get(scope_children, scope_id, nothing) return nothing
    # Group child scopes by their st0 source construct (for/let/while/try).
    # Multiple lowered scope_blocks may map to the same source construct
    # (e.g. a for loop creates scope_blocks for both iteration vars and body).
    # Scopes without a construct (or whose construct is already processed)
    # are collected as "transparent" and their bindings are inlined.
    construct_groups = Dict{Tuple{Int,Int},Tuple{JS.SyntaxTree,Vector{Int}}}()
    transparent_ids = Int[]
    for child_id in child_ids
        child_id in func_scope_ids && continue
        1 ≤ child_id ≤ length(ctx3.scopes) || continue
        construct = find_scope_construct(ctx3, ctx3.scopes[child_id], parent_map)
        if construct === nothing
            push!(transparent_ids, child_id)
            continue
        end
        key = (JS.first_byte(construct), JS.last_byte(construct))
        if key == root_range || key in seen
            push!(transparent_ids, child_id)
            continue
        end
        group = get!(construct_groups, key) do
            (construct, Int[])
        end
        push!(group[2], child_id)
    end
    for (key, (construct, group_ids)) in construct_groups
        key in seen || push!(seen, key)
        if JS.kind(construct) === JS.K"try"
            push_try_namespace_symbol!(symbols, construct, lctx, group_ids)
        else
            child_symbols = @somereal extract_local_scope_bindings(lctx, group_ids) continue
            push_namespace_symbol!(symbols, construct, child_symbols, fi)
        end
    end
    if !isempty(transparent_ids)
        extract_local_scope_bindings!(symbols, lctx, transparent_ids)
    end
    return nothing
end

function push_namespace_symbol!(
        symbols::Vector{DocumentSymbol}, construct::JS.SyntaxTree,
        children::Vector{DocumentSymbol}, fi::FileInfo
    )
    JS.numchildren(construct) ≥ 1 || return nothing
    k = JS.kind(construct)
    prefix = k === JS.K"for" ? "for " :
             k === JS.K"while" ? "while " :
             k === JS.K"let" ? "let " : ""
    detail = rstrip(prefix * lstrip(JS.sourcetext(construct[1])))
    push!(symbols, DocumentSymbol(;
        name = " ",
        detail,
        kind = SymbolKind.Namespace,
        range = jsobj_to_range(construct, fi),
        selectionRange = jsobj_to_range(construct[1], fi),
        children))
    return nothing
end

function push_try_namespace_symbol!(
        symbols::Vector{DocumentSymbol}, try_node::JS.SyntaxTree,
        lctx::LocalScopeContext, group_ids::Vector{Int}
    )
    (; ctx3, parent_map, fi) = lctx
    clause_children = DocumentSymbol[]
    parts = String[]
    for i in 1:JS.numchildren(try_node)
        child = try_node[i]
        ck = JS.kind(child)
        clause_kind = ck === JS.K"block" ? "try" :
            ck === JS.K"catch" ? "catch" :
            ck === JS.K"else" ? "else" :
            ck === JS.K"finally" ? "finally" :
            continue
        push!(parts, clause_kind)
        clause_ids = Int[id for id in group_ids
            if _classify_try_clause(ctx3, id, parent_map) == clause_kind]
        isempty(clause_ids) && continue
        clause_symbols = @somereal extract_local_scope_bindings(lctx, clause_ids) continue
        push!(clause_children, DocumentSymbol(;
            name = " ",
            detail = clause_kind,
            kind = SymbolKind.Namespace,
            range = jsobj_to_range(child, fi),
            selectionRange = jsobj_to_range(child, fi),
            children = clause_symbols))
    end
    isempty(clause_children) && return nothing
    push!(symbols, DocumentSymbol(;
        name = " ",
        detail = join(parts, " ... "),
        kind = SymbolKind.Namespace,
        range = jsobj_to_range(try_node, fi),
        selectionRange = jsobj_to_range(try_node, fi),
        children = clause_children))
    return nothing
end

function _classify_try_clause(
        ctx3::JL.VariableAnalysisContext, scope_id::Int,
        parent_map::Dict{Tuple{Int,Int},JS.SyntaxTree}
    )
    1 ≤ scope_id ≤ length(ctx3.scopes) || return "try"
    scope = ctx3.scopes[scope_id]
    scope_st = JS.SyntaxTree(JS.syntax_graph(ctx3), scope.node_id)
    prov = JS.flattened_provenance(scope_st)
    isempty(prov) && return "try"
    source_node = first(prov)
    k = JS.kind(source_node)
    k === JS.K"catch" && return "catch"
    k === JS.K"else" && return "else"
    k === JS.K"finally" && return "finally"
    # else/finally body scope_blocks may have `block` provenance
    # (pointing to the block inside the clause, not the clause itself).
    # Check parent_map to distinguish from the try body.
    if k === JS.K"block"
        fb = JS.first_byte(source_node)
        lb = JS.last_byte(source_node)
        parent = get(parent_map, (fb, lb), nothing)
        if parent !== nothing
            pk = JS.kind(parent)
            pk === JS.K"else" && return "else"
            pk === JS.K"finally" && return "finally"
        end
    end
    return "try"
end

function find_scope_construct(
        ctx3::JL.VariableAnalysisContext, scope::JL.ScopeInfo,
        parent_map::Dict{Tuple{Int,Int},JS.SyntaxTree}
    )
    scope_st = JS.SyntaxTree(JS.syntax_graph(ctx3), scope.node_id)
    prov = JS.flattened_provenance(scope_st)
    isempty(prov) && return nothing
    source_node = first(prov)
    k = JS.kind(source_node)
    fb, lb = JS.first_byte(source_node), JS.last_byte(source_node)
    (iszero(fb) && iszero(lb)) && return nothing
    if k in JS.KSet"for while let try"
        # Look up the actual st0 node via parent_map, since the
        # provenance node lives in the lowered graph and has different
        # children.
        parent = get(parent_map, (fb, lb), nothing)
        isnothing(parent) && return nothing
        for i in 1:JS.numchildren(parent)
            child = parent[i]
            if JS.first_byte(child) == fb && JS.last_byte(child) == lb
                return child
            end
        end
    elseif k in JS.KSet"block catch else finally"
        # try expansion creates scope_blocks whose provenance points to
        # the try body (block), catch/else/finally clause, or the block
        # inside else/finally — not the try node itself.
        # Walk up parent_map (at most 2 levels) to find the try node.
        node = get(parent_map, (fb, lb), nothing)
        while node !== nothing
            JS.kind(node) === JS.K"try" && return node
            JS.kind(node) in JS.KSet"catch else finally" || break
            nfb, nlb = JS.first_byte(node), JS.last_byte(node)
            node = get(parent_map, (nfb, nlb), nothing)
        end
    end
    return nothing
end

function extract_argument_detail(
        parent_map::Dict{Tuple{Int,Int},JS.SyntaxTree}, fb::Int, lb::Int
    )
    parent = get(parent_map, (fb, lb), nothing)
    detail = nothing
    if !isnothing(parent) && JS.kind(parent) in JS.KSet":: kw ..."
        detail = lstrip(JS.sourcetext(parent))
        fb, lb = JS.first_byte(parent), JS.last_byte(parent)
        parent = get(parent_map, (fb, lb), nothing)
    end
    # Handle keyword arguments: `f(; kw)` or `f(; kw=default)`
    # Only use parameters if we don't already have a more specific detail
    if isnothing(detail) && !isnothing(parent) && JS.kind(parent) === JS.K"parameters"
        detail = lstrip(JS.sourcetext(parent))
    end
    return detail
end

function extract_local_variable_detail(
        parent_map::Dict{Tuple{Int,Int},JS.SyntaxTree}, fb::Int, lb::Int
    )
    parent = get(parent_map, (fb, lb), nothing)
    detail = nothing
    # Handle type annotation: `x::T` or `x::T = value`
    if !isnothing(parent) && JS.kind(parent) === JS.K"::"
        detail = lstrip(JS.sourcetext(parent))
        fb, lb = JS.first_byte(parent), JS.last_byte(parent)
        parent = get(parent_map, (fb, lb), nothing)
    end
    # Handle named tuple destructuring: `(; x, y) = ...`
    if !isnothing(parent) && JS.kind(parent) === JS.K"parameters"
        fb, lb = JS.first_byte(parent), JS.last_byte(parent)
        parent = get(parent_map, (fb, lb), nothing)
    end
    # Handle tuple destructuring: `x, y = ...` or `(a, b) = ...`
    if !isnothing(parent) && JS.kind(parent) === JS.K"tuple"
        fb, lb = JS.first_byte(parent), JS.last_byte(parent)
        parent = get(parent_map, (fb, lb), nothing)
    end
    # Handle assignment: `x = value`
    if !isnothing(parent) && JS.kind(parent) === JS.K"="
        detail = strip(first(split(JS.sourcetext(parent), '\n')))
        fb, lb = JS.first_byte(parent), JS.last_byte(parent)
        parent = get(parent_map, (fb, lb), nothing)
    end
    # Handle for loop iterator: `for i in collection`
    if !isnothing(parent) && JS.kind(parent) === JS.K"in"
        detail = "for " * lstrip(JS.sourcetext(parent))
        fb, lb = JS.first_byte(parent), JS.last_byte(parent)
        parent = get(parent_map, (fb, lb), nothing)
    end
    # Handle local declaration: `local x` or `local x, y`
    if !isnothing(parent) && JS.kind(parent) === JS.K"local"
        detail = lstrip(JS.sourcetext(parent))
    end
    return detail
end

is_anonymous_function_rhs(st::JS.SyntaxTree) = JS.kind(st) === JS.K"->" ||
    (JS.kind(st) === JS.K"function" && JS.numchildren(st) ≥ 1 && JS.kind(st[1]) !== JS.K"call")

function find_anon_func_scope_ids(
        parent_map::Dict{Tuple{Int,Int},JS.SyntaxTree}, fb::Int, lb::Int,
        func_to_scopes::Dict{Int,Vector{Int}}, ctx3::JL.VariableAnalysisContext
    )
    parent = @something get(parent_map, (fb, lb), nothing) return nothing
    JS.kind(parent) === JS.K"=" || return nothing
    JS.numchildren(parent) ≥ 2 || return nothing
    rhs = parent[2]
    is_anonymous_function_rhs(rhs) || return nothing
    anon_body = rhs[JS.numchildren(rhs)]
    anon_fb, anon_lb = JS.first_byte(anon_body), JS.last_byte(anon_body)
    graph = JS.syntax_graph(ctx3)
    for (func_bid, scope_ids) in func_to_scopes
        binfo = JL.get_binding(ctx3, func_bid)
        binfo.is_internal || continue
        for scope_id in scope_ids
            1 ≤ scope_id ≤ length(ctx3.scopes) || continue
            scope_node = JS.SyntaxTree(graph, ctx3.scopes[scope_id].node_id)
            if JS.first_byte(scope_node) == anon_fb && JS.last_byte(scope_node) == anon_lb
                return scope_ids
            end
        end
    end
    return nothing
end
