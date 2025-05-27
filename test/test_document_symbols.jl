module test_document_symbols

using Test
using JETLS
using JETLS: JL, JS
using JETLS: DocumentSymbol, SymbolKind, Position, symbols

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
    let
        src = """
        function f(x::Int)::Int
            y = 1
            println(y)
            return x + y
        end
        """
        syms = symbols(JS.parsestmt(JL.SyntaxTree, src))
        @test length(syms) == 1
        f_symbol = syms[1]
        test_symbol_end(f_symbol, "f", SymbolKind.Function, (0, 0), (4, 2), 2)
        # Symbols should be ordered by appearance.
        x_symbol1 = f_symbol.children[1]
        test_symbol(x_symbol1, "x", SymbolKind.Variable, (0, 11), (0, 12), 0)
        y_symbol = f_symbol.children[2]
        test_symbol(y_symbol, "y", SymbolKind.Variable, (1, 4), (1, 5), 0)
    end

    let
        src = "function f end"
        syms = symbols(JS.parsestmt(JL.SyntaxTree, src))
        @test length(syms) == 1
        test_symbol(syms[1], "f", SymbolKind.Function, (0, 0), (0, 14), 0)
    end

    let
        src = """
        struct S{T}
            x::T
        end
        """
        syms = symbols(JS.parsestmt(JL.SyntaxTree, src))
        @test length(syms) == 1
        s_symbol = syms[1]
        test_symbol_end(s_symbol, "S", SymbolKind.Struct, (0, 0), (2, 2), 2)
        t_symbol = s_symbol.children[1]
        x_symbol = s_symbol.children[2]
        test_symbol(t_symbol, "T", SymbolKind.TypeParameter, (0, 9), (0, 10), 0)
        test_symbol(x_symbol, "x", SymbolKind.Field, (1, 4), (1, 5), 0)
    end

    let
        src = """
        macro m(x)
            e = :( println(\$x) )
            esc(e)
        end
        """
        syms = symbols(JS.parsestmt(JL.SyntaxTree, src))
        @test length(syms) == 1
        m_symbol = syms[1]
        # TODO: Fix after changing the kind to something more appropriate?
        # Two explicit children (`x` and `e`) + `__context__`.
        test_symbol_end(m_symbol, "@m", SymbolKind.Function, (0, 0), (3, 2), 3)
    end

    let
        src = """
        if true
            a = 1
        else
            a = 2
        end
        """
        syms = symbols(JS.parsestmt(JL.SyntaxTree, src))
        @test length(syms) == 2
        test_symbol(syms[1], "a", SymbolKind.Variable, (1, 4), (1, 5), 0)
    end

    let
        src = "const T1{T2, 1} = Array{T, 1}"
        syms = symbols(JS.parsestmt(JL.SyntaxTree, src))
        @test length(syms) == 1
        test_symbol(syms[1], "T1{T2, 1}", SymbolKind.Constant, (0, 6), (0, 15), 0)
    end

    let
        src = """
        a = b = begin
            c = 2
            f(x) = 3
        end
        """
        syms = symbols(JS.parsestmt(JL.SyntaxTree, src))
        @test length(syms) == 4
        test_symbol(syms[1], "a", SymbolKind.Variable, (0, 0), (0, 1), 0)
        test_symbol(syms[2], "b", SymbolKind.Variable, (0, 4), (0, 5), 0)
        test_symbol(syms[3], "c", SymbolKind.Variable, (1, 4), (1, 5), 0)
        test_symbol(syms[4], "f", SymbolKind.Function, (2, 4), (2, 12), 1)
    end
end

@testset "Toplevel statements" begin
    let
        src = """
        const g = [1]

        module M
            f(x) = 2

            for x in Main.g
                f(x)
            end
        end
        """
        syms = symbols(JS.children(JS.parseall(JL.SyntaxTree, src)))
        @test length(syms) == 2
        g_symbol = syms[1]
        test_symbol(g_symbol, "g", SymbolKind.Constant, (0, 6), (0, 7), 0)
        m_symbol = syms[2]
        # # TODO: I don't know why there is no binding for `g` in `Main.g`.
        # test_symbol_end(m_symbol, "M", SymbolKind.Module, (2, 0), (8, 2), 3)
        # # Function definition.
        # fdef_symbol = m_symbol.children[1]
        # test_symbol(fdef_symbol, "f", SymbolKind.Function, (3, 4), (3, 12), 1)
        # farg_symbol = fdef_symbol.children[1]
        # test_symbol(farg_symbol, "x", SymbolKind.Variable, (3, 6), (3, 7), 0)
        # # For loop.
        # # TODO: I don't know why JuliaLowering returns the `Main` binding before `x`.
        # main_symbol = m_symbol.children[2]
        # test_symbol(main_symbol, "Main", SymbolKind.Variable, (5, 13), (5, 17), 0)
        # x_symbol = m_symbol.children[3]
        # test_symbol(x_symbol, "x", SymbolKind.Variable, (5, 8), (5, 9), 0)
    end
end

end  # module test_document_symbols
