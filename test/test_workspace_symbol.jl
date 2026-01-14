module test_workspace_symbol

using Test
using JETLS: JETLS, JS
using JETLS.LSP
using JETLS.LSP.URIs2

function get_workspace_symbols(code::AbstractString)
    fi = JETLS.FileInfo(1, code, @__FILE__, PositionEncodingKind.UTF8)
    st0 = JETLS.build_syntax_tree(fi)
    workspace_symbols = WorkspaceSymbol[]
    doc_symbols = JETLS.extract_document_symbols(st0, fi)
    uri = URI("file:///$(@__FILE__)")
    JETLS.flatten_document_symbols!(workspace_symbols, doc_symbols, uri)
    return workspace_symbols
end

@testset "workspace symbol" begin
    code = """
    module Foo
        function bar(x)
            y = x + 1
            return y
        end
        const BAZ = 42
    end
    """

    workspace_symbols = get_workspace_symbols(code)

    @test length(workspace_symbols) >= 3
    names = [s.name for s in workspace_symbols]
    @test "Foo" in names
    @test "bar" in names
    @test "BAZ" in names

    # containerName is set from DocumentSymbol.detail
    foo_sym = first(filter(s -> s.name == "Foo", workspace_symbols))
    @test foo_sym.containerName == "module Foo"
    @test foo_sym.kind == SymbolKind.Module

    bar_sym = first(filter(s -> s.name == "bar", workspace_symbols))
    @test bar_sym.containerName == "function bar(x)"
    @test bar_sym.kind == SymbolKind.Function

    baz_sym = first(filter(s -> s.name == "BAZ", workspace_symbols))
    @test baz_sym.containerName == "const BAZ = 42"
    @test baz_sym.kind == SymbolKind.Constant
end

end # module test_workspace_symbol
