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

# TODO: Use explicit stack.
function get_symbols!(ex::JL.SyntaxTree,
                      symbols::Vector{DocumentSymbol};
                      ignore_duplicates=true)
    k = kind(ex)
    if k === K"module"
        module_symbols = DocumentSymbol[]
        for c in children(children(ex)[2])
            get_symbols!(c, module_symbols; ignore_duplicates)
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
        ctx, _ = try
            jl_lower_for_completion(ex)
        catch err
            # @info "Error in lowering" err
            return symbols
        end
        binfos = filter(binfo -> !binfo.is_internal, ctx.bindings.info)

        fun_children = DocumentSymbol[]
        # Get argument symbols.
        arg_bindings = filter(binfo -> binfo.kind === :argument, binfos)
        for arg_binding in arg_bindings
            # TODO: Is there a better way to not include this binding? Does filtering by
            #       `!binfo.is_always_defined` make sense?
            arg_binding.name == "__context__" && continue
            arg_symbol = _DocumentSymbol(arg_binding.name,
                                         JL.binding_ex(ctx, arg_binding.id),
                                         SymbolKind.Variable)
            push!(fun_children, arg_symbol)
        end

        # Get local symbols.
        local_bindings = filter(binfo -> binfo.kind === :local, binfos)
        for local_binding in local_bindings
            local_symbol = _DocumentSymbol(local_binding.name,
                                           JL.binding_ex(ctx, local_binding.id),
                                           SymbolKind.Variable)
            push!(fun_children, local_symbol)
        end

        # Create the function symbol.
        # TODO: Is the function binding always first in a function definition?
        fun_binding = binfos[1]
        fun_symbol = _DocumentSymbol(fun_binding.name,
                                     ex,
                                     SymbolKind.Function,
                                     fun_children)
        push!(symbols, fun_symbol)
    elseif k === K"call" || k === K"macrocall"
        # Skip.
    elseif k === K"struct"
        ctx, _ = try
            jl_lower_for_completion(ex)
        catch err
            # @info "Error in lowering" err
            return symbols
        end
        binfos = filter(binfo -> !binfo.is_internal, ctx.bindings.info)

        struct_children = DocumentSymbol[]
        type_param_bindings = filter(binfo -> binfo.kind === :static_parameter, binfos)
        for tpb in type_param_bindings
            tpb_symbol = _DocumentSymbol(tpb.name,
                                         JL.binding_ex(ctx, tpb.id),
                                         SymbolKind.TypeParameter)
            push!(struct_children, tpb_symbol)
        end
        # TODO: Find out why the fields are duplicated.
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
        # Don't include the type symbol, but include the lhs symbol, if any.
        if !JS.is_prefix_op_call(ex)
            get_symbols!(ex[1], symbols; ignore_duplicates)
        end
    elseif k === K"const" || k === K"="
        get_symbols!(ex[1], symbols; ignore_duplicates=false)
    elseif k === K"doc"
        get_symbols!(ex[2], symbols; ignore_duplicates)
    else
        ctx, _ = try
            jl_lower_for_completion(ex)
        catch err
            # @info "Error in lowering" err
            return symbols
        end
        binfos = filter(binfo -> !binfo.is_internal, ctx.bindings.info)
        for b in binfos
            if ignore_duplicates &&
                !isnothing(findfirst(s -> s.name == b.name && s.kind == SymbolKind.Variable,
                                     symbols))
                continue
            end
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

# Request handler
# ===============

function handle_DocumentSymbolRequest(state::ServerState, msg::DocumentSymbolRequest)
    file_uri = URI(msg.params.textDocument.uri)
    file_info = get_fileinfo(state, file_uri)
    isnothing(file_info) &&
        return state.send(DocumentSymbolResponse(; id = msg.id, result = DocumentSymbol[]))
    stream = file_info.parsed_stream

    ex = JS.build_tree(JL.SyntaxTree, stream)
    symbols = DocumentSymbol[]
    get_toplevel_symbols!(ex, symbols)

    res = DocumentSymbolResponse(; id = msg.id, result = symbols)
    return state.send(res)
end
