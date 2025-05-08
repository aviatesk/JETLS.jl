function handle_DocumentSymbolRequest(state::ServerState, msg::DocumentSymbolRequest)
    file_uri = URI(msg.params.textDocument.uri)
    stream = state.file_cache[file_uri].parsed_stream
    ex = JuliaSyntax.build_tree(JuliaSyntax.SyntaxNode, stream)

    res = DocumentSymbolResponse(; id = msg.id, result = get_symbols(ex))
    return state.send(res)
end

# Utils
# -----

"""
Search for all globally available symbols in a `SyntaxNode` and return them as an array of
`LSP.DocumentSymbol`s.
"""
function get_symbols(ex::JuliaSyntax.SyntaxNode)
    if JuliaSyntax.kind(ex) === K"toplevel"
        return [get_symbol(c) for c in JuliaSyntax.children(ex)]
    else
        return [get_symbol(ex)]
    end
end

function get_symbol(ex::JuliaSyntax.SyntaxNode)
    if JuliaSyntax.kind(ex) === K"module"
        children = [get_symbol(c) for c in JuliaSyntax.children(ex.children[2])]
        return _DocumentSymbol(ex.children[1], SymbolKind.Module, children)
    elseif JuliaSyntax.kind(ex) === K"struct"
        struct_body = ex.children[2]
        struct_children = DocumentSymbol[]
        for c in JuliaSyntax.children(struct_body)
            # TODO: Can a struct field be anything other than `id` or `id::T`?
            if JuliaSyntax.kind(c) === K"::"
                push!(struct_children, _DocumentSymbol(c.children[1], SymbolKind.Field))
            elseif JuliaSyntax.is_identifier(c)
                push!(struct_children, _DocumentSymbol(c, SymbolKind.Field))
            end
        end
        struct_name = ex.children[1]
        if JuliaSyntax.kind(struct_name) === K"curly"
            type_param = _DocumentSymbol(struct_name.children[2], SymbolKind.TypeParameter)
            struct_name = struct_name.children[1]
            push!(struct_children, type_param)
        end
        return _DocumentSymbol(struct_name, SymbolKind.Struct, struct_children)
    elseif JuliaSyntax.kind(ex) === K"function"
        call_node = ex.children[1]
        function_node = call_node.children[1]
        if !JuliaSyntax.is_identifier(function_node)
            if JuliaSyntax.is_infix_op_call(ex)  # (f::T)(args)
                function_node = function_node.children[1]
            end
            # TODO: Are there other possibilities here?
        end
        # TODO: Should the selection range cover the entire function definition?
        return _DocumentSymbol(function_node, SymbolKind.Function)
    elseif JuliaSyntax.kind(ex) === K"="
        # TODO: This probably doesn't cover all cases correctly.
        return _DocumentSymbol(ex.children[1], SymbolKind.Variable)
    elseif JuliaSyntax.kind(ex) === K"const"
        return _DocumentSymbol(ex.children[1].children[1], SymbolKind.Variable)
    else
        # TODO: Macros. Anything else? (Maybe `@enum`s?)
        ex_kind = JuliaSyntax.kind(ex)
        filename = JuliaSyntax.sourcefile(ex).filename
        filename_str = isnothing(filename) ? "" : "$filename:"
        (line, col) = JuliaSyntax.source_location(ex)
        @info "[DocumentSymbols] Unimplemented for expression kind $ex_kind at $filename_str($line, $col)"
        dummy_pos = Position(; line = 0, character = 0)
        dummy_range = Range(; start = dummy_pos, var"end" = dummy_pos)
        return DocumentSymbol(;
                              name = "unimplemented",
                              kind = SymbolKind.Null,
                              range = dummy_range,
                              selectionRange = dummy_range)
    end
end

"""
Helper constructor for a `LSP.DocumentSymbol` from a `SyntaxNode`.
"""
function _DocumentSymbol(ex::JuliaSyntax.SyntaxNode, kind::SymbolKind.Ty, children=nothing)
    name = string(ex.val)
    range = get_range(ex)

    return DocumentSymbol(;
                          name = name,
                          kind = kind,
                          range = range,
                          selectionRange = range,
                          children = children)
end

# TODO: Should this be inside `get_range` or is it useful on its own?
"""
Convert the source location of a `SyntaxNode` to a 0-indexed location.
"""
function lsp_source_location(ex::JuliaSyntax.SyntaxNode)
    (line, col) = JuliaSyntax.source_location(ex)
    return (line - 1, col - 1)
end

"""
Get the `LSP.Range` of a `SyntaxNode`.
"""
function get_range(ex::JuliaSyntax.SyntaxNode)
    (line, col) = lsp_source_location(ex)
    start_position = Position(; line = line, character = col)
    end_position = Position(; line = line, character = col + ex.raw.span)

    return Range(; start = start_position, var"end" = end_position)
end
