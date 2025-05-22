using .JS: children, kind

# Symbols search
# ==============

"""
Search for all symbols in a `SyntaxTree` and store them as an array of
`LSP.DocumentSymbol`s.
"""
function get_toplevel_symbols!(ex::JL.SyntaxTree, symbols::Vector{DocumentSymbol})
    for c in children(ex)
        get_symbols!(c, symbols)
    end
    return symbols
end

function get_symbols!(ex::JL.SyntaxTree, symbols::Vector{DocumentSymbol})
    k = kind(ex)
    if k === K"module"
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
    elseif k === K"function" || k === K"macro"
        # Since there is no special kind for macros, macro definitions can be treated like
        # function definitions.
        fun_children = DocumentSymbol[]

        fun_call_ex = ex[1]
        type_ex = nothing
        if kind(fun_call_ex) === K"::"
            type_ex = fun_call_ex[2]
            fun_call_ex = fun_call_ex[1]
        end

        # Get argument symbols.
        arg_exs = JL.SyntaxTree[]
        if kind(fun_call_ex) === K"call"
            push_args!(arg_exs, fun_call_ex, 2)
        elseif kind(fun_call_ex) === K"tuple"  # Anonymous function.
            push_args!(arg_exs, fun_call_ex, 1)
        end
        for arg_ex in arg_exs
            # TODO: Should function args have a different kind than `SymbolKind.Variable`?
            get_symbols!(arg_ex, fun_children)
        end

        # Get body symbols.
        if length(children(ex)) > 1
            body_exs = kind(ex[2]) === K"block" ? children(ex[2]) : [ex[2]]
            for body_ex in body_exs
                get_symbols!(body_ex, fun_children)
            end
        end

        # Create the return type symbol, if any.
        if !isnothing(type_ex)
            type_symbol = _DocumentSymbol(get_type_name(type_ex),
                                          type_ex,
                                          SymbolKind.Struct)
            push!(fun_children, type_symbol)
        end

        # Create the function symbol.
        name = get_function_name(fun_call_ex)
        if k === K"macro"
            name = "@" * name
        end
        fun_symbol = _DocumentSymbol(name,
                                     ex,
                                     SymbolKind.Function,
                                     fun_children)
        push!(symbols, fun_symbol)


    elseif k === K"call"
        if JS.is_infix_op_call(ex)
            fun_symbol = _DocumentSymbol(ex[2].name_val,
                                         ex[2],
                                         SymbolKind.Function)
            push!(symbols, fun_symbol)
            args = [ex[1], ex[3:end]...]
            for arg in args
                get_symbols!(arg, symbols)
            end
        else
            if JS.is_identifier(ex[1])
                fun_symbol = _DocumentSymbol(ex[1].name_val,
                                             ex[1],
                                             SymbolKind.Function)
                push!(symbols, fun_symbol)
            end
            if length(children(ex)) >= 2
                for arg in ex[2:end]
                    get_symbols!(arg, symbols)
                end
            end
        end
    elseif k === K"macrocall"
        # TODO: For now, macro calls are are treated similarly to function calls. This
        #       should be changed after `JuliaLowering` handles macro expansion.
        macro_symbol = _DocumentSymbol(ex[1].name_val,
                                       ex[1],
                                       SymbolKind.Function)
        push!(symbols, macro_symbol)
        if length(children(ex)) > 1
            for c in ex[2:end]
                get_symbols!(c, symbols)
            end
        end
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
    elseif k === K"::"
        if JS.is_prefix_op_call(ex)
            type_symbol = _DocumentSymbol(get_type_name(ex[1]),
                                          ex[1],
                                          SymbolKind.Struct)
            push!(symbols, type_symbol)
        else
            get_symbols!(ex[1], symbols)
            type_symbol = _DocumentSymbol(get_type_name(ex[2]),
                                          ex[2],
                                          SymbolKind.Struct)
            push!(symbols, type_symbol)
        end
    elseif k === K"if" || k === K"block"
        for c in children(ex)
            get_symbols!(c, symbols)
        end
    elseif k === K"for" || k === K"while" || k === K"="
        get_symbols!(ex[1], symbols)
        get_symbols!(ex[2], symbols)
    elseif k === K"const" || k === K"return"
        get_symbols!(ex[1], symbols)
    else
        binfos, ctx = lower_and_get_bindings(ex)
        for b in binfos
            symbol = _DocumentSymbol(b.name,
                                     JL.binding_ex(ctx, b.id),
                                     SymbolKind.Variable)
            push!(symbols, symbol)
        end
    end

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

function push_args!(arg_exs, fun_call_ex, start)
    for arg_ex in fun_call_ex[start:end]
        kind(arg_ex) === K"parameters" ?
            push!(arg_exs, arg_ex[1])  :
            push!(arg_exs, arg_ex)
    end
    return arg_exs
end

"""
Get the type name from the rhs of a `::` node.
  - `::T`      -> "T"
  - `::T1{T2}` -> "T1{T2}"
"""
function get_type_name(ex::JL.SyntaxTree)
    return JS.is_identifier(ex) ?
        ex.name_val             :
        ex[1].name_val * "{" * get_type_name(ex[2]) * "}"
end

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
    get_toplevel_symbols!(ex, symbols)

    res = DocumentSymbolResponse(; id = msg.id, result = symbols)
    return state.send(res)
end
