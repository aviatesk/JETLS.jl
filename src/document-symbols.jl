using .JS: children, kind

# Symbols search
# ==============

"""
Search for all symbols in a `SyntaxTree` and store them as an array of
`LSP.DocumentSymbol`s.
"""
function get_symbols!(ex::JL.SyntaxTree, symbols::Vector{DocumentSymbol})
    k = kind(ex)
    if k === K"toplevel"
        for c in children(ex)
            get_symbols!(c, symbols)
        end
    elseif k === K"module"
        module_symbols = DocumentSymbol[]
        for c in children(children(ex)[2])
            get_symbols!(c, module_symbols)
        end
        module_name_ex = children(ex)[1]
        module_symbol = _DocumentSymbol(module_name_ex.name_val,
                                        ex,
                                        SymbolKind.Module,
                                        module_symbols)
        push!(symbols, module_symbol)
    elseif k === K"struct"
        binfos, ctx = lower_and_get_bindings(ex)
        struct_children = DocumentSymbol[]

        type_param_bindings = filter(binfo -> binfo.kind === :static_parameter, binfos)
        for tpb in type_param_bindings
            tpb_symbol = _DocumentSymbol(tpb.name,
                                         JL.binding_ex(ctx, tpb.id),
                                         SymbolKind.TypeParameter)
            push!(struct_children, tpb_symbol)
        end
        field_bindings = filter(binfo -> binfo.kind === :argument, binfos)
        for fb in field_bindings
            fb_symbol = _DocumentSymbol(fb.name,
                                        JL.binding_ex(ctx, fb.id),
                                        SymbolKind.Field)
            push!(struct_children, fb_symbol)
        end

        struct_name_ex = children(ex)[1]
        if kind(struct_name_ex) === K"curly"
            struct_name_ex = children(struct_name_ex)[1]
        end
        struct_name = struct_name_ex.name_val
        struct_symbol = _DocumentSymbol(struct_name,
                                        ex,
                                        SymbolKind.Struct,
                                        struct_children)
        push!(symbols, struct_symbol)
    elseif k === K"function"
        binfos, ctx = lower_and_get_bindings(ex)
        fun_children = DocumentSymbol[]

        arg_bindings = filter(binfo -> binfo.kind === :argument, binfos)
        for ab in arg_bindings
            arg_symbol = _DocumentSymbol(ab.name,
                                         JL.binding_ex(ctx, ab.id),
                                         SymbolKind.Variable)
            push!(fun_children, arg_symbol)
        end
        local_bindings = filter(binfo -> binfo.kind === :local, binfos)
        for lb in local_bindings
            local_symbol = _DocumentSymbol(lb.name,
                                           JL.binding_ex(ctx, lb.id),
                                           SymbolKind.Variable)
            push!(fun_children, local_symbol)
        end

        fun_call_ex = children(ex)[1]
        fun_name = get_function_name(fun_call_ex)
        fun_symbol = _DocumentSymbol(fun_name,
                                     ex,
                                     SymbolKind.Function,
                                     fun_children)
        push!(symbols, fun_symbol)
    elseif k === K"macro"
        binfos, ctx = lower_and_get_bindings(ex)
        macro_children = DocumentSymbol[]

        arg_bindings =
            filter(binfo -> binfo.kind === :argument && binfo.name != "__context__", binfos)
        for ab in arg_bindings
            arg_symbol = _DocumentSymbol(ab.name,
                                         JL.binding_ex(ctx, ab.id),
                                         SymbolKind.Variable)
            push!(macro_children, arg_symbol)
        end
        local_bindings = filter(binfo -> binfo.kind === :local, binfos)
        for lb in local_bindings
            local_symbol = _DocumentSymbol(lb.name,
                                           JL.binding_ex(ctx, lb.id),
                                           SymbolKind.Variable)
            push!(macro_children, local_symbol)
        end

        # TODO: Is this correct for any macro definition?
        # TODO: Not a function. What is the most appropriate kind?
        macro_name = children(children(ex)[1])[1].name_val
        macro_symbol = _DocumentSymbol(macro_name,
                                       ex,
                                       SymbolKind.Function,
                                       macro_children)
        push!(symbols, macro_symbol)
    else
        binfos, ctx = lower_and_get_bindings(ex)
        for b in binfos
            symbol = _DocumentSymbol(b.name,
                                     JL.binding_ex(ctx, b.id),
                                     SymbolKind.Variable)
            symbol in symbols && continue  # Only include the same symbol once.
            push!(symbols, symbol)
        end
    end
    # TODO: Treat `const` specially (use the `Constant` kind)?

    return symbols
end

# Symbols search utils
# --------------------

"""
Get the bindings from a `SyntaxTree` lowered up to scope resolution. Filter out internal
bindings.
"""
function lower_and_get_bindings(st0::JL.SyntaxTree)
    # Lower the syntax tree.
    ctx1, st1 = JL.expand_forms_1(Module(), st0)
    ctx2, st2 = JL.expand_forms_2(ctx1, st1)
    ctx3, _ = JL.resolve_scopes(ctx2, st2)
    # Filter out internal bindings.
    binfos = filter(binfo -> !binfo.is_internal, ctx3.bindings.info)

    return binfos, ctx3
end

"""
Helper constructor for a `LSP.DocumentSymbol` from a `SyntaxTree`.
"""
function _DocumentSymbol(name::String,
                         ex::JL.SyntaxTree,
                         kind::SymbolKind.Ty,
                         children=nothing)
    range = get_range(ex)
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
function get_range(ex::JL.SyntaxTree)
    (line, col) = JS.source_location(ex)
    start_position = Position(; line = line - 1, character = col - 1)
    # Calculate the end position from the byte range and the line start byte.
    line_starts = JS.sourcefile(ex).line_starts
    byte_range = JS.byte_range(ex)
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

    return Range(; start = start_position, var"end" = end_position)
end

"""
Get the function name from a function signature node.
  - `f`
  - `f(...)`
  - `f(...)::T`
"""
function get_function_name(ex::JL.SyntaxTree)
    k = kind(ex)
    if k === K"Identifier"
        return ex.name_val
    elseif k === K"call"
        name_ex = children(ex)[1]
        return kind(name_ex) === K"Identifier" ?
            name_ex.name_val :
            "anonymous"
    elseif k === K"::"
        call_ex = children(ex)[1]
        return get_function_name(call_ex)
    end
end

# This is necessary in order to avoid symbol clutter. Two symbols are "equal" if they
# have the same name and the same kind.
Base.:(==)(s1::DocumentSymbol, s2::DocumentSymbol) =
    s1.name == s2.name && s1.kind == s2.kind

# Request handler
# ===============

function handle_DocumentSymbolRequest(state::ServerState, msg::DocumentSymbolRequest)
    file_uri = URI(msg.params.textDocument.uri)
    file_info = get_fileinfo(state, file_uri)
    isnothing(file_info) &&
        # TODO: Send error/warning/diagnostic?
        return state.send(DocumentSymbolResponse(; id = msg.id, result = DocumentSymbol[]))
    stream = file_info.parsed_stream
    # TODO: Guard for malformed stream.

    ex = JS.build_tree(JL.SyntaxTree, stream)
    symbols = DocumentSymbol[]
    get_symbols!(ex, symbols)

    res = DocumentSymbolResponse(; id = msg.id, result = symbols)
    return state.send(res)
end
