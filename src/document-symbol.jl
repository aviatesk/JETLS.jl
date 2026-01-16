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
    return send(server,
        DocumentSymbolResponse(;
            id = msg.id,
            result = @somereal symbols null))
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
        symbols::Vector{DocumentSymbol}, st::JS.SyntaxTree, fi::FileInfo, mod::Module
    )
    for i = 1:JS.numchildren(st)
        extract_toplevel_symbol!(symbols, st[i], fi, mod)
    end
end

function extract_toplevel_symbol!(symbols::Vector{DocumentSymbol}, st::JS.SyntaxTree, fi::FileInfo, mod::Module)
    k = JS.kind(st)
    if k === JS.K"module" || k === JS.K"baremodule"
        extract_module_symbol!(symbols, st, fi, mod)
    elseif k === JS.K"function"
        extract_function_symbol!(symbols, st, fi, mod)
    elseif k === JS.K"macro"
        extract_macro_symbol!(symbols, st, fi, mod)
    elseif k === JS.K"struct"
        extract_struct_symbol!(symbols, st, fi, mod)
    elseif k === JS.K"abstract"
        extract_abstract_type_symbol!(symbols, st, fi)
    elseif k === JS.K"primitive"
        extract_primitive_type_symbol!(symbols, st, fi)
    elseif k === JS.K"const"
        extract_const_symbols!(symbols, st, fi, mod)
    elseif k === JS.K"global"
        extract_global_symbols!(symbols, st, fi, mod)
    elseif k === JS.K"="
        extract_toplevel_assignment_symbols!(symbols, st, fi, mod)
    elseif k === JS.K"let"
        extract_let_symbol!(symbols, st, fi, mod)
    elseif k === JS.K"while"
        extract_while_symbol!(symbols, st, fi, mod)
    elseif k === JS.K"for"
        extract_for_symbol!(symbols, st, fi, mod)
    elseif k === JS.K"toplevel" || k === JS.K"block"
        extract_toplevel_symbols!(symbols, st, fi, mod)
    elseif k === JS.K"macrocall"
        extract_macrocall_symbol!(symbols, st, fi, mod)
    elseif k === JS.K"doc"
        extract_doc_symbol!(symbols, st, fi, mod)
    end
    return nothing
end

function extract_module_symbol!(
        symbols::Vector{DocumentSymbol}, st::JS.SyntaxTree, fi::FileInfo, parent_mod::Module
    )
    JS.numchildren(st) ≥ 2 || return nothing
    name_node = st[1]
    name = @something extract_name_val(name_node) return nothing
    mod = parent_mod
    if invokelatest(isdefinedglobal, parent_mod, Symbol(name))
        mod = invokelatest(getglobal, parent_mod, Symbol(name))::Module
    end
    children = DocumentSymbol[]
    body = st[end]
    if JS.kind(body) === JS.K"block"
        extract_toplevel_symbols!(children, body, fi, mod)
    end
    is_baremodule = JS.has_flags(JS.flags(st), JS.BARE_MODULE_FLAG)
    detail = (is_baremodule ? "baremodule " : "module ") * name
    push!(symbols, DocumentSymbol(;
        name,
        detail,
        kind = SymbolKind.Module,
        range = jsobj_to_range(st, fi),
        selectionRange = jsobj_to_range(name_node, fi),
        children = @somereal children Some(nothing)))
    return nothing
end

function extract_function_symbol!(
        symbols::Vector{DocumentSymbol}, st::JS.SyntaxTree, fi::FileInfo, mod::Module
    )
    JS.numchildren(st) ≥ 1 || return nothing
    sig = st[1]
    name, name_node = @something extract_function_name(sig) return nothing
    children = @somereal extract_scoped_children(st, fi, mod) Some(nothing)
    is_short_form = JS.has_flags(JS.flags(st), JS.SHORT_FORM_FUNCTION_FLAG)
    detail = is_short_form ? JS.sourcetext(sig) * " =" : "function " * JS.sourcetext(sig)
    push!(symbols, DocumentSymbol(;
        name,
        detail,
        kind = SymbolKind.Function,
        range = jsobj_to_range(st, fi),
        selectionRange = jsobj_to_range(name_node, fi),
        children))
    return nothing
end

function extract_macro_symbol!(
        symbols::Vector{DocumentSymbol}, st::JS.SyntaxTree, fi::FileInfo, mod::Module
    )
    JS.numchildren(st) ≥ 1 || return nothing
    sig_orig = st[1]
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
    children = @somereal extract_scoped_children(st, fi, mod) Some(nothing)
    push!(symbols, DocumentSymbol(;
        name,
        detail,
        kind = SymbolKind.Function,
        range = jsobj_to_range(st, fi),
        selectionRange = jsobj_to_range(name_node, fi),
        children))
    return nothing
end

function extract_struct_symbol!(
        symbols::Vector{DocumentSymbol}, st::JS.SyntaxTree, fi::FileInfo, mod::Module
    )
    JS.numchildren(st) ≥ 1 || return nothing
    sig_node = st[1]
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
    is_mutable = JS.has_flags(JS.flags(st), JS.MUTABLE_FLAG)
    detail = (is_mutable ? "mutable struct " : "struct ") * lstrip(JS.sourcetext(sig_node))
    children = DocumentSymbol[]
    if JS.numchildren(st) ≥ 2
        body = st[2]
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
        range = jsobj_to_range(st, fi),
        selectionRange = jsobj_to_range(name_node, fi),
        children = @somereal children Some(nothing)))
    return nothing
end

function extract_struct_field!(
        symbols::Vector{DocumentSymbol}, st::JS.SyntaxTree, fi::FileInfo
    )
    field_node = st
    k = JS.kind(st)
    if k === JS.K"const" && JS.numchildren(st) ≥ 1
        field_node = st[1]
        k = JS.kind(field_node)
    end
    name_node = field_node
    if k === JS.K"::" && JS.numchildren(field_node) ≥ 1
        name_node = field_node[1]
    end
    name = @something extract_name_val(name_node) return nothing
    detail = lstrip(JS.sourcetext(st))
    push!(symbols, DocumentSymbol(;
        name,
        detail,
        kind = SymbolKind.Field,
        range = jsobj_to_range(st, fi),
        selectionRange = jsobj_to_range(name_node, fi)))
    return nothing
end

function extract_abstract_type_symbol!(
        symbols::Vector{DocumentSymbol}, st::JS.SyntaxTree, fi::FileInfo
    )
    JS.numchildren(st) ≥ 1 || return nothing
    name_node = def_node = st[1]
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
        range = jsobj_to_range(st, fi),
        selectionRange = jsobj_to_range(name_node, fi)))
    return nothing
end

function extract_primitive_type_symbol!(
        symbols::Vector{DocumentSymbol}, st::JS.SyntaxTree, fi::FileInfo
    )
    JS.numchildren(st) ≥ 2 || return nothing
    def_node = st[1]
    bits_node = st[2]
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
        kind = SymbolKind.Class,
        range = jsobj_to_range(st, fi),
        selectionRange = jsobj_to_range(name_node, fi)))
    return nothing
end

function extract_const_symbols!(
        symbols::Vector{DocumentSymbol}, st::JS.SyntaxTree, fi::FileInfo, mod::Module
    )
    JS.numchildren(st) ≥ 1 || return nothing
    assign = st[1]
    JS.kind(assign) === JS.K"=" || return nothing
    JS.numchildren(assign) ≥ 2 || return nothing
    lhs = assign[1]
    rhs = assign[2]
    range = jsobj_to_range(st, fi)
    detail = lstrip(JS.sourcetext(st))
    extract_assignment_symbols!(symbols, lhs, rhs, range, SymbolKind.Constant, detail, fi, mod)
    return nothing
end

function extract_global_symbols!(
        symbols::Vector{DocumentSymbol}, st::JS.SyntaxTree, fi::FileInfo, mod::Module
    )
    JS.numchildren(st) ≥ 1 || return nothing
    inner = st[1]
    range = jsobj_to_range(st, fi)
    detail = lstrip(JS.sourcetext(st))
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
        symbols::Vector{DocumentSymbol}, st::JS.SyntaxTree, fi::FileInfo, mod::Module
    )
    JS.numchildren(st) ≥ 2 || return nothing
    lhs = st[1]
    JS.kind(lhs) in JS.KSet". ref" && return nothing # Skip property assignment like obj.field = value
    rhs = st[2]
    range = jsobj_to_range(st, fi)
    detail = lstrip(JS.sourcetext(st))
    extract_assignment_symbols!(symbols, lhs, rhs, range, SymbolKind.Variable, detail, fi, mod)
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

extract_let_symbol!(args...) = extract_namespace_symbol!(args..., "let ")

extract_while_symbol!(args...) = extract_namespace_symbol!(args..., "while ")

extract_for_symbol!(args...) = extract_namespace_symbol!(args..., "for ")

function extract_namespace_symbol!(
        symbols::Vector{DocumentSymbol}, st::JS.SyntaxTree, fi::FileInfo, mod::Module,
        prefix::AbstractString
    )
    JS.numchildren(st) ≥ 2 || return nothing
    children = @somereal extract_scoped_children(st, fi, mod) return nothing
    detail = rstrip(prefix * lstrip(JS.sourcetext(st[1])))
    push!(symbols, DocumentSymbol(;
        name = " ",
        detail,
        kind = SymbolKind.Namespace,
        range = jsobj_to_range(st, fi),
        selectionRange = jsobj_to_range(st[1], fi),
        children))
    return nothing
end

function extract_macrocall_symbol!(
        symbols::Vector{DocumentSymbol}, st::JS.SyntaxTree, fi::FileInfo, mod::Module
    )
    if is_enum_macrocall(st)
        extract_enum_symbol!(symbols, st, fi)
    else
        extract_toplevel_symbols!(symbols, st, fi, mod)
    end
    return nothing
end

function is_enum_macrocall(st::JS.SyntaxTree)
    JS.numchildren(st) ≥ 2 || return false
    macro_node = st[1]
    macro_name = if JS.kind(macro_node) === JS.K"."
        JS.numchildren(macro_node) ≥ 2 || return false
        rhs = macro_node[2]
        if JS.kind(rhs) === JS.K"quote" && JS.numchildren(rhs) ≥ 1
            extract_name_val(rhs[1])
        else
            extract_name_val(rhs)
        end
    else
        extract_name_val(macro_node)
    end
    return macro_name == "@enum"
end

function extract_enum_symbol!(symbols::Vector{DocumentSymbol}, st::JS.SyntaxTree, fi::FileInfo)
    JS.numchildren(st) ≥ 2 || return nothing
    type_node = st[2]
    name_node = type_node
    if JS.kind(type_node) === JS.K"::"
        JS.numchildren(type_node) ≥ 1 || return nothing
        name_node = type_node[1]
    end
    name = @something extract_name_val(name_node) return nothing
    children = DocumentSymbol[]
    for i = 3:JS.numchildren(st)
        extract_enum_value!(children, st[i], name, fi)
    end
    push!(symbols, DocumentSymbol(;
        name,
        detail = "@enum " * lstrip(JS.sourcetext(type_node)),
        kind = SymbolKind.Enum,
        range = jsobj_to_range(st, fi),
        selectionRange = jsobj_to_range(name_node, fi),
        children = @somereal children Some(nothing)))
    return nothing
end

function extract_enum_value!(
        symbols::Vector{DocumentSymbol}, st::JS.SyntaxTree, enum_name::String, fi::FileInfo
    )
    if JS.kind(st) === JS.K"block"
        for i = 1:JS.numchildren(st)
            extract_enum_value!(symbols, st[i], enum_name, fi)
        end
        return nothing
    end
    name_node = st
    if JS.kind(st) === JS.K"="
        JS.numchildren(st) ≥ 1 || return nothing
        name_node = st[1]
    end
    name = @something extract_name_val(name_node) return nothing
    push!(symbols, DocumentSymbol(;
        name,
        detail = name * "::" * enum_name,
        kind = SymbolKind.EnumMember,
        range = jsobj_to_range(st, fi),
        selectionRange = jsobj_to_range(name_node, fi)))
    return nothing
end

function extract_doc_symbol!(
        symbols::Vector{DocumentSymbol}, st::JS.SyntaxTree, fi::FileInfo, mod::Module
    )
    JS.numchildren(st) ≥ 2 || return nothing
    definition = st[2]
    temp_symbols = DocumentSymbol[]
    extract_toplevel_symbol!(temp_symbols, definition, fi, mod)
    isempty(temp_symbols) && return nothing
    range = jsobj_to_range(st, fi)
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
    return @somereal extract_local_symbols_from_scopes(ctx3, parent_map, fi) Some(nothing)
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

function extract_local_symbols_from_scopes(
        ctx3::JL.VariableAnalysisContext, parent_map::Dict{Tuple{Int,Int},JS.SyntaxTree},
        fi::FileInfo
    )
    scopes = ctx3.scopes
    isempty(scopes) && return DocumentSymbol[]
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
    # Nested function scopes (their symbols will be extracted as children of the function binding)
    nested_func_scope_ids = Set{Int}()
    for scope_ids in values(func_to_scopes)
        union!(nested_func_scope_ids, scope_ids)
    end
    symbols = DocumentSymbol[]
    top_scope_ids = Int[scope.id for scope in scopes
        if (scope.id ∉ nested_func_scope_ids &&
            any(((_, bid),) -> is_any_local_binding(JL.get_binding(ctx3, bid)), scope.vars))]
    extract_local_scope_bindings!(symbols, ctx3, parent_map, top_scope_ids, func_to_scopes, fi)
    return symbols
end

is_any_local_binding(binfo::JL.BindingInfo) =
    binfo.kind === :local || binfo.kind === :argument || binfo.kind === :static_parameter

function extract_local_scope_bindings!(symbols::Vector{DocumentSymbol},
        ctx3::JL.VariableAnalysisContext, parent_map::Dict{Tuple{Int,Int},JS.SyntaxTree},
        scope_ids::Vector{Int}, func_to_scopes::Dict{Int,Vector{Int}}, fi::FileInfo
    )
    # Collect static parameter names to avoid showing duplicate local variable references
    static_param_names = Set{String}()
    for scope_id in scope_ids
        1 ≤ scope_id ≤ length(ctx3.scopes) || continue
        for (_, bid) in ctx3.scopes[scope_id].vars
            binfo = JL.get_binding(ctx3, bid)
            binfo.kind === :static_parameter && push!(static_param_names, binfo.name)
        end
    end
    seen = Set{Tuple{Int,Int}}()
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
            # TODO This is a variable introduced in macro expanded code
            # For now we completely ignore such cases, but in the future we might want to
            # include such variables as document-symbols too.
            # For example, variables like `group` that are implicitly introduced in cases like
            # `@info "log" x = x` may not be useful in most cases, but in cases like
            # `func(x) = (@asis y = 42; x + y)` using `macro asis(x); :($(esc(x))); end`,
            # we might want `y` to appear in the outline.
            length(prov) > 1 && continue
            source_node = first(prov)
            fb, lb = JS.first_byte(source_node), JS.last_byte(source_node)
            (iszero(fb) && iszero(lb)) && continue
            # Skip duplicates (e.g., from kwsorter scope merging)
            (fb, lb) in seen && continue
            push!(seen, (fb, lb))
            range = jsobj_to_range(source_node, fi)
            selectionRange = range
            detail = nothing
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
            else
                kind = SymbolKind.Variable
                if binfo.kind === :argument
                    detail = extract_argument_detail(parent_map, fb, lb)
                else
                    detail = extract_local_variable_detail(parent_map, fb, lb)
                end
            end
            children_symbols = nothing
            if is_func
                children_symbols = DocumentSymbol[]
                extract_local_scope_bindings!(children_symbols, ctx3, parent_map,
                    func_to_scopes[bid], func_to_scopes, fi)
            end
            push!(symbols, DocumentSymbol(;
                name = binfo.name,
                detail,
                kind,
                range,
                selectionRange,
                children = @somereal children_symbols Some(nothing)))
        end
    end
    return symbols
end

function extract_argument_detail(
        parent_map::Dict{Tuple{Int,Int},JS.SyntaxTree}, fb::Int, lb::Int
    )
    parent = get(parent_map, (fb, lb), nothing)
    detail = nothing
    if !isnothing(parent) && JS.kind(parent) in JS.KSet":: ..."
        detail = lstrip(JS.sourcetext(parent))
        fb, lb = JS.first_byte(parent), JS.last_byte(parent)
        parent = get(parent_map, (fb, lb), nothing)
    end
    if !isnothing(parent) && JS.kind(parent) === JS.K"kw"
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
        detail = lstrip(JS.sourcetext(parent))
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
