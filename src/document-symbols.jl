using .JS: children, kind
using .JL: @ast

# Symbols search
# ==============

function symbols(st::JL.SyntaxTree)::Vector{DocumentSymbol}
    k = kind(st)
    if k === K"module"
        sts = symbols(children(st[2]))
        return [_DocumentSymbol(children(st)[1].name_val, st, SymbolKind.Module, sts)]
    elseif k === K"struct"
        lowering_res = lower_and_get_bindings(st)
        isnothing(lowering_res) && return DocumentSymbol[]

        ctx, binfos = lowering_res
        struct_children = DocumentSymbol[]
        # Type parameters.
        type_param_bindings = filter(binfo -> binfo.kind === :static_parameter, binfos)
        type_param_names = [b.name for b in type_param_bindings]
        type_params_str = isempty(type_param_names) ?
            "" :
            "{" * join(type_param_names, ", ") * "}"
        # Fields and inner constructors.
        for c in children(st[2])
            kc = kind(c)
            if JS.is_identifier(c)
                push!(struct_children, _DocumentSymbol(c.name_val,
                                                       c,
                                                       SymbolKind.Field))
            elseif kc === K"::"
                push!(struct_children, _DocumentSymbol(c[1].name_val,
                                                       c[1],
                                                       SymbolKind.Field))
            elseif kc === K"function"
                if !isempty(type_param_bindings)
                    c = remove_type_param(c)
                end
                constructor_symbol = symbols(c)[1]
                constructor_name = constructor_symbol.name * type_params_str
                constructor_symbol =
                    DocumentSymbol(;
                                   name = constructor_name,
                                   kind = constructor_symbol.kind,
                                   range = constructor_symbol.range,
                                   selectionRange = constructor_symbol.selectionRange,
                                   children = constructor_symbol.children)
                push!(struct_children, constructor_symbol)
            end
        end
        # Struct symbol.
        struct_name_st, _, _ = JL.analyze_type_sig(ctx, st[1])
        struct_name = struct_name_st.name_val * type_params_str
        struct_symbol = _DocumentSymbol(struct_name,
                                        st,
                                        SymbolKind.Struct,
                                        struct_children)
        return [struct_symbol]
    elseif k === K"function" || k === K"macro"
        lowering_res = lower_and_get_bindings(st)
        isnothing(lowering_res) && return DocumentSymbol[]

        ctx, binfos = lowering_res
        fun_children = DocumentSymbol[]
        # Argument symbols.
        # TODO: This gives wrong results for functions with inner function defs.
        arg_bindings = filter(binfo -> binfo.kind === :argument, binfos)
        for b in arg_bindings
            b_symbol = _DocumentSymbol(b.name,
                                       JL.binding_ex(ctx, b.id),
                                       SymbolKind.Variable)
            push!(fun_children, b_symbol)
        end
        if length(children(st)) == 1  # `function f end`
            fun_symbol = _DocumentSymbol(st[1].name_val,
                                         st,
                                         SymbolKind.Function,
                                         fun_children)
            return [fun_symbol]
        end
        # Body symbols.
        append!(fun_children, symbols(children(st[2])))
        # Function symbol.
        fun_name_st = JL.assigned_function_name(st[1])
        fun_name = isnothing(fun_name_st) ? "anonymous" : fun_name_st.name_val
        if k === K"macro"
            fun_name = "@" * fun_name
        end
        fun_symbol = _DocumentSymbol(fun_name, st, SymbolKind.Function, fun_children)
        return [fun_symbol]
    elseif k === K"doc"
        return symbols(st[2])
    elseif JS.is_syntactic_assignment(st)
        return symbols_assignment(st, SymbolKind.Variable)
    elseif k === K"const"
        return symbols_assignment(st[1], SymbolKind.Constant)
    elseif k === K"if" || k === K"elseif"
        return symbols(children(st)[2:end])
    elseif k === K"block"
        return symbols(children(st))
    elseif k === K"for"
        iteration_var_st = st[1][1][1]
        lowering_res = lower_and_get_bindings(iteration_var_st)
        isnothing(lowering_res) && return DocumentSymbol[]

        iteration_var_ctx, iteration_var_binfos = lowering_res
        # Iteration variable symbols.
        syms = DocumentSymbol[]
        for b in iteration_var_binfos
            push!(syms, _DocumentSymbol(b.name,
                                        JL.binding_ex(iteration_var_ctx, b.id),
                                        SymbolKind.Variable))
        end
        # Body symbols.
        append!(syms, symbols(children(st[2])))
        return syms
    elseif k === K"while"
        return symbols(children(st[2]))
    else
        lowering_res = lower_and_get_bindings(st)
        isnothing(lowering_res) && return DocumentSymbol[]

        ctx, binfos = lowering_res
        local_bindings = filter(binfo -> binfo.kind === :local, binfos)
        syms = DocumentSymbol[]
        for b in local_bindings
            push!(syms, _DocumentSymbol(b.name,
                                        JL.binding_ex(ctx, b.id),
                                        SymbolKind.Variable))
        end
        return syms
    end
end

symbols(sts::JL.SyntaxList)::Vector{DocumentSymbol} =
    reduce(vcat, map(symbols, sts); init=DocumentSymbol[])

function symbols_assignment(st::JL.SyntaxTree, sym_kind::SymbolKind.Ty)
    syms = symbols_assignment_lhs(st[1], sym_kind)
    append!(syms, symbols(st[2]))

    return syms
end

function symbols_assignment_lhs(lhs::JL.SyntaxTree, sym_kind::SymbolKind.Ty)
    syms = DocumentSymbol[]
    if kind(lhs) === K"tuple"
        for c in children(lhs)
            syms_c = symbols_assignment_lhs(c, sym_kind)
            append!(syms, syms_c)
        end
    elseif kind(lhs) === K"::"
        return [_DocumentSymbol(lhs[1].name_val, lhs[1], sym_kind)]
    elseif kind(lhs) === K"curly"
        type_name = lhs.source.file.code[JS.byte_range(lhs)]
        return [_DocumentSymbol(string(type_name), lhs, sym_kind)]
    elseif JS.is_identifier(lhs)
        sym = _DocumentSymbol(lhs.name_val, lhs, sym_kind)
        push!(syms, sym)
    end

    return syms
end

# Symbols search utils
# --------------------

function lower_and_get_bindings(ex::JL.SyntaxTree)
    ctx, _ = try
        jl_lower_for_completion(ex)
    catch err
        # @info "Error in lowering" err
        return nothing
    end
    binfos = filter(binfo -> !binfo.is_internal, ctx.bindings.info)

    return ctx, binfos
end

"""
Remove the type parameters from an inner constructor in order ot make it lowerable.
"""
function remove_type_param(st::JL.SyntaxTree)
    call = st[1][1]  # Skip the `where`.
    constr_name = call[1][1]
    body = st[2]

    # TODO: Does it matter what context we have here?
    ctx = JL.MacroExpansionContext(JL.syntax_graph(st), JL.Bindings(),
                                   JL.ScopeLayer[], JL.ScopeLayer(1, Module(), false))
    k = kind(st)
    return @ast ctx st [k [K"call" constr_name call[2:end]...] body]
end

"""
Helper constructor for a `LSP.DocumentSymbol` from a `SyntaxTree`.
"""
function _DocumentSymbol(name::String,
                         st::JL.SyntaxTree,
                         kind::SymbolKind.Ty,
                         children=nothing)
    range = get_range(st)
    return DocumentSymbol(;
                          name = name,
                          kind = kind,
                          range = range,
                          selectionRange = range,
                          children = children)
end

# TODO: `end` keyword is not highlighted.
"""
Get the `LSP.Range` of a `SyntaxTree`.
"""
function get_range(st::JL.SyntaxTree)
    (line, col) = JS.source_location(st)
    start_position = Position(; line = line - 1, character = col - 1)
    # Calculate the end position from the byte range and the line start byte.
    line_starts = JS.sourcefile(st).line_starts
    byte_range = JS.byte_range(st)
    if length(line_starts) == line || byte_range.stop < line_starts[line + 1]
        # `ex` does not span multiple lines.
        # TODO: Calculate the last column in terms of characters, not bytes.
        end_position = Position(; line = line - 1, character = col + length(byte_range) - 1)
    else
        # `ex` spans multiple lines.
        end_byte = byte_range.stop
        # TODO: Is there a smarter way to do this?
        # Calculate the ending line.
        end_line = line
        for i in line+1:length(line_starts)-1
            if line_starts[i + 1] > end_byte
                end_line = i
                break
            end
        end
        if end_line == line
            end_line = length(line_starts)
        end
        # Calculate the ending column.
        # TODO: Calculate it in terms of characters, not bytes.
        end_col = end_byte - line_starts[end_line]
        # End position.
        end_position = Position(; line = end_line - 1, character = end_col - 1)
    end
    # code = JS.sourcetext(st)
    # start_position = offset_to_xy(code, byte_range.start)
    # end_position = offset_to_xy(code, byte_range.stop)

    return Range(; start = start_position, var"end" = end_position)
end

# Request handler
# ===============

function handle_DocumentSymbolRequest(state::ServerState, msg::DocumentSymbolRequest)
    file_uri = URI(msg.params.textDocument.uri)
    file_info = get_fileinfo(state, file_uri)
    isnothing(file_info) &&
        return state.send(DocumentSymbolResponse(; id = msg.id, result = DocumentSymbol[]))
    stream = file_info.parsed_stream

    st = JS.build_tree(JL.SyntaxTree, stream)
    syms = symbols(children(st))

    res = DocumentSymbolResponse(; id = msg.id, result = syms)
    return state.send(res)
end
