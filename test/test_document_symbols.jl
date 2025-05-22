module test_document_symbols

using Test
using JETLS
using JETLS: JL, JS
using JETLS: DocumentSymbol, SymbolKind, Position, get_toplevel_symbols!, get_symbols!

get_toplevel_symbols(ex::JL.SyntaxTree) = get_toplevel_symbols!(ex, DocumentSymbol[])
get_symbols(ex::JL.SyntaxTree) = get_symbols!(ex, DocumentSymbol[])

function test_symbol(s::DocumentSymbol,
                     name::String,
                     kind::SymbolKind.Ty,
                     start_pos,
                     end_pos,
                     children_len)
    @test s.name == name
    @test s.kind == kind
    @test s.range.start == Position(; line = start_pos[1], character = start_pos[2])
    @test s.range.var"end" == Position(; line = end_pos[1], character = end_pos[2])
    if children_len == 0
        @test isnothing(s.children) || isempty(s.children)
    else
        @test !isnothing(s.children)
        @test length(s.children) == children_len
    end
end

"""
The `end` keyword's final byte is offset by -1. Until that's fixed, use this function to
test document symbols whose spans end with an `end`.
"""
function test_symbol_end(s::DocumentSymbol,
                         name::String,
                         kind::SymbolKind.Ty,
                         start_pos,
                         end_pos,
                         children_len)
    end_pos = (end_pos[1], end_pos[2] - 1)
    return test_symbol(s, name, kind, start_pos, end_pos, children_len)
end

@testset "Simple expressions" begin
    src = """
    function f(x::Int)::Int
        y = 1
        println(y)
        return x + y
    end
    """
    symbols = get_symbols(JS.parsestmt(JL.SyntaxTree, src))
    @test length(symbols) == 1
    f_symbol = symbols[1]
    test_symbol_end(f_symbol, "f", SymbolKind.Function, (0, 0), (4, 2), 9)
    # Symbols should be ordered by appearance, with the return type last. Infix operators
    # are stored before their arguments.
    x_symbol1 = f_symbol.children[1]
    test_symbol(x_symbol1, "x", SymbolKind.Variable, (0, 11), (0, 12), 0)
    arg_type_symbol = f_symbol.children[2]
    test_symbol(arg_type_symbol, "Int", SymbolKind.Struct, (0, 14), (0, 17), 0)
    y_symbol1 = f_symbol.children[3]
    test_symbol(y_symbol1, "y", SymbolKind.Variable, (1, 4), (1, 5), 0)
    println_symbol = f_symbol.children[4]
    test_symbol(println_symbol, "println", SymbolKind.Function, (2, 4), (2, 11), 0)
    y_symbol2 = f_symbol.children[5]
    test_symbol(y_symbol2, "y", SymbolKind.Variable, (2, 12), (2, 13), 0)
    plus_symbol = f_symbol.children[6]
    test_symbol(plus_symbol, "+", SymbolKind.Function, (3, 13), (3, 14), 0)
    x_symbol2 = f_symbol.children[7]
    test_symbol(x_symbol2, "x", SymbolKind.Variable, (3, 11), (3, 12), 0)
    y_symbol3 = f_symbol.children[8]
    test_symbol(y_symbol3, "y", SymbolKind.Variable, (3, 15), (3, 16), 0)
    ret_type_symbol = f_symbol.children[9]
    test_symbol(ret_type_symbol, "Int", SymbolKind.Struct, (0, 20), (0, 23), 0)

    src = "function f end"
    symbols = get_symbols(JS.parsestmt(JL.SyntaxTree, src))
    @test length(symbols) == 1
    test_symbol(symbols[1], "f", SymbolKind.Function, (0, 0), (0, 14), 0)

    src = """
    struct S{T}
        x::T
    end
    """
    symbols = get_symbols(JS.parsestmt(JL.SyntaxTree, src))
    @test length(symbols) == 1
    s_symbol = symbols[1]
    # TODO: Should have 2 children, but fields are duplicated for some reason.
    test_symbol_end(s_symbol, "S", SymbolKind.Struct, (0, 0), (2, 2), 3)
    t_symbol = s_symbol.children[1]
    x_symbol = s_symbol.children[2]
    test_symbol(t_symbol, "T", SymbolKind.TypeParameter, (0, 9), (0, 10), 0)
    test_symbol(x_symbol, "x", SymbolKind.Field, (1, 4), (1, 5), 0)
    # TODO: Remove once field duplication is fixed.
    # Check that the extra symbol is the duplicated field, not something else
    @test s_symbol.children[3].name == "x"

    src = """
    macro m(x)
        e = :( println(\$x) )
        esc(e)
    end
    """
    symbols = get_symbols(JS.parsestmt(JL.SyntaxTree, src))
    @test length(symbols) == 1
    m_symbol = symbols[1]
    # TODO: Fix after changing the kind to something more appropriate?
    test_symbol_end(m_symbol, "@m", SymbolKind.Function, (0, 0), (3, 2), 5)

    src = """
    if true
        a = 1
    else
        a = 2
    end
    """
    symbols = get_symbols(JS.parsestmt(JL.SyntaxTree, src))
    @test length(symbols) == 2
    test_symbol(symbols[1], "a", SymbolKind.Variable, (1, 4), (1, 5), 0)
    test_symbol(symbols[2], "a", SymbolKind.Variable, (3, 4), (3, 5), 0)
end

@testset "Toplevel statements" begin
    src = """
    const g = [1]

    module M
        f(x) = 2

        for x in Main.g
            f(x)
        end
    end
    """
    symbols = get_toplevel_symbols(JS.parseall(JL.SyntaxTree, src))
    @test length(symbols) == 2
    g_symbol = symbols[1]
    test_symbol(g_symbol, "g", SymbolKind.Variable, (0, 6), (0, 7), 0)
    m_symbol = symbols[2]
    # TODO: I don't know why there is no binding for `g` in `Main.g`.
    test_symbol_end(m_symbol, "M", SymbolKind.Module, (2, 0), (8, 2), 5)
    # Function definition.
    fdef_symbol = m_symbol.children[1]
    test_symbol(fdef_symbol, "f", SymbolKind.Function, (3, 4), (3, 12), 1)
    farg_symbol = fdef_symbol.children[1]
    test_symbol(farg_symbol, "x", SymbolKind.Variable, (3, 6), (3, 7), 0)
    # For loop.
    # TODO: I don't know why JuliaLowering returns the `Main` binding before `x`.
    main_symbol = m_symbol.children[2]
    test_symbol(main_symbol, "Main", SymbolKind.Variable, (5, 13), (5, 17), 0)
    x_symbol = m_symbol.children[3]
    test_symbol(x_symbol, "x", SymbolKind.Variable, (5, 8), (5, 9), 0)
end

end  # module test_document_symbols
