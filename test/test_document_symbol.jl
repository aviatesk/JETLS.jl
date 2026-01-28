module test_document_symbol

using Test
using JETLS: JETLS, JL, JS
using JETLS.LSP

function make_file_info(code::AbstractString)
    return JETLS.FileInfo(1, code, @__FILE__, PositionEncodingKind.UTF16)
end

@testset "JETLS.extract_document_symbols" begin
    @testset "module" begin
        code = """
        module Foo
            function bar()
            end
        end
        """
        fi = make_file_info(code)
        st0 = JETLS.build_syntax_tree(fi)
        symbols = JETLS.extract_document_symbols(st0, fi)
        @test length(symbols) == 1
        @test symbols[1].name == "Foo"
        @test symbols[1].kind == SymbolKind.Module
        @test symbols[1].children !== nothing
        @test length(symbols[1].children) == 1
        @test symbols[1].children[1].name == "bar"
        @test symbols[1].children[1].kind == SymbolKind.Function
    end

    @testset "function" begin
        code = """
        function foo(x)
            return x + 1
        end
        """
        fi = make_file_info(code)
        st0 = JETLS.build_syntax_tree(fi)
        symbols = JETLS.extract_document_symbols(st0, fi)
        @test length(symbols) == 1
        @test symbols[1].name == "foo"
        @test symbols[1].kind == SymbolKind.Function
        @test symbols[1].detail == "function foo(x)"
    end

    @testset "short function" begin
        code = "f(x) = x + 1"
        fi = make_file_info(code)
        st0 = JETLS.build_syntax_tree(fi)
        symbols = JETLS.extract_document_symbols(st0, fi)
        @test length(symbols) == 1
        @test symbols[1].name == "f"
        @test symbols[1].kind == SymbolKind.Function
        @test symbols[1].detail == "f(x) ="
    end

    @testset "macro" begin
        code = """
        macro foo(x)
            esc(x)
        end
        """
        fi = make_file_info(code)
        st0 = JETLS.build_syntax_tree(fi)
        symbols = JETLS.extract_document_symbols(st0, fi)
        @test length(symbols) == 1
        @test symbols[1].name == "@foo"
        @test symbols[1].kind == SymbolKind.Function
        @test symbols[1].detail == "macro foo(x)"
    end

    @testset "struct" begin
        code = """
        struct Foo
            x::Int
            y::String
        end
        """
        fi = make_file_info(code)
        st0 = JETLS.build_syntax_tree(fi)
        symbols = JETLS.extract_document_symbols(st0, fi)
        @test length(symbols) == 1
        @test symbols[1].name == "Foo"
        @test symbols[1].kind == SymbolKind.Struct
        @test symbols[1].detail == "struct Foo"
        @test symbols[1].children !== nothing
        @test length(symbols[1].children) == 2
        @test symbols[1].children[1].name == "x"
        @test symbols[1].children[1].kind == SymbolKind.Field
        @test symbols[1].children[1].detail == "x::Int"
        @test symbols[1].children[2].name == "y"
        @test symbols[1].children[2].kind == SymbolKind.Field
        @test symbols[1].children[2].detail == "y::String"
    end

    @testset "parametric struct" begin
        code = """
        struct Foo{T} <: AbstractFoo
            x::T
        end
        """
        fi = make_file_info(code)
        st0 = JETLS.build_syntax_tree(fi)
        symbols = JETLS.extract_document_symbols(st0, fi)
        @test length(symbols) == 1
        @test symbols[1].name == "Foo"
        @test symbols[1].kind == SymbolKind.Struct
        @test symbols[1].detail == "struct Foo{T} <: AbstractFoo"
    end

    @testset "abstract type" begin
        code = "abstract type AbstractFoo end"
        fi = make_file_info(code)
        st0 = JETLS.build_syntax_tree(fi)
        symbols = JETLS.extract_document_symbols(st0, fi)
        @test length(symbols) == 1
        @test symbols[1].name == "AbstractFoo"
        @test symbols[1].kind == SymbolKind.Interface
        @test symbols[1].detail == "abstract type AbstractFoo"
    end

    @testset "primitive type" begin
        let code = "primitive type MyInt 32 end"
            fi = make_file_info(code)
            st0 = JETLS.build_syntax_tree(fi)
            symbols = JETLS.extract_document_symbols(st0, fi)
            @test length(symbols) == 1
            @test symbols[1].name == "MyInt"
            @test symbols[1].kind == SymbolKind.Number
            @test symbols[1].detail == "primitive type MyInt 32"
        end

        let code = "primitive type MyFloat <: AbstractFloat 64 end"
            fi = make_file_info(code)
            st0 = JETLS.build_syntax_tree(fi)
            symbols = JETLS.extract_document_symbols(st0, fi)
            @test length(symbols) == 1
            @test symbols[1].name == "MyFloat"
            @test symbols[1].kind == SymbolKind.Number
            @test symbols[1].detail == "primitive type MyFloat <: AbstractFloat 64"
        end
    end

    @testset "const" begin
        code = "const FOO = 42"
        fi = make_file_info(code)
        st0 = JETLS.build_syntax_tree(fi)
        symbols = JETLS.extract_document_symbols(st0, fi)
        @test length(symbols) == 1
        @test symbols[1].name == "FOO"
        @test symbols[1].kind == SymbolKind.Constant
        @test symbols[1].detail == "const FOO = 42"

        let code = """
            const X = begin
                y = 1
                y + 1
            end
            """
            fi = make_file_info(code)
            st0 = JETLS.build_syntax_tree(fi)
            symbols = JETLS.extract_document_symbols(st0, fi)
            @test length(symbols) == 2
            @test symbols[1].name == "X"
            @test symbols[1].kind == SymbolKind.Constant
            @test symbols[2].name == "y"
            @test symbols[2].kind == SymbolKind.Variable
        end
    end

    @testset "variable assignment" begin
        code = "x = 10"
        fi = make_file_info(code)
        st0 = JETLS.build_syntax_tree(fi)
        symbols = JETLS.extract_document_symbols(st0, fi)
        @test length(symbols) == 1
        @test symbols[1].name == "x"
        @test symbols[1].kind == SymbolKind.Variable
    end

    @testset "function assignment" begin
        code = "f = (x) -> x + 1"
        fi = make_file_info(code)
        st0 = JETLS.build_syntax_tree(fi)
        symbols = JETLS.extract_document_symbols(st0, fi)
        @test length(symbols) == 1
        @test symbols[1].name == "f"
        @test symbols[1].kind == SymbolKind.Variable
    end

    @testset "assignment with block RHS" begin
        let code = """
            x = begin
                a = 1
                b = 2
            end
            """
            fi = make_file_info(code)
            st0 = JETLS.build_syntax_tree(fi)
            symbols = JETLS.extract_document_symbols(st0, fi)
            @test length(symbols) == 3
            names = [s.name for s in symbols]
            @test "x" in names
            @test "a" in names
            @test "b" in names
        end
    end

    @testset "assignment with let RHS" begin
        let code = """
            x = let
                a = 1
                a + 1
            end
            """
            fi = make_file_info(code)
            st0 = JETLS.build_syntax_tree(fi)
            symbols = JETLS.extract_document_symbols(st0, fi)
            @test length(symbols) == 1
            @test symbols[1].name == "x"
            @test symbols[1].kind == SymbolKind.Variable
            @test symbols[1].children !== nothing
            @test length(symbols[1].children) == 1
            let_sym = symbols[1].children[1]
            @test let_sym.detail == "let"
            @test let_sym.kind == SymbolKind.Namespace
            @test let_sym.children !== nothing
            @test length(let_sym.children) == 1
            @test let_sym.children[1].name == "a"
        end
    end

    @testset "multiple symbols" begin
        code = """
        const A = 1
        const B = 2

        function foo()
        end

        struct Bar
            x::Int
        end
        """
        fi = make_file_info(code)
        st0 = JETLS.build_syntax_tree(fi)
        symbols = JETLS.extract_document_symbols(st0, fi)
        @test length(symbols) == 4
        names = [s.name for s in symbols]
        @test "A" in names
        @test "B" in names
        @test "foo" in names
        @test "Bar" in names
    end

    @testset "begin block" begin
        let code = """
            begin
                a = 42
                b = 10
            end
            """
            fi = make_file_info(code)
            st0 = JETLS.build_syntax_tree(fi)
            symbols = JETLS.extract_document_symbols(st0, fi)
            @test length(symbols) == 2
            @test symbols[1].name == "a"
            @test symbols[1].kind == SymbolKind.Variable
            @test symbols[2].name == "b"
            @test symbols[2].kind == SymbolKind.Variable
        end
    end

    @testset "@enum" begin
        let code = "@enum Color red green blue"
            fi = make_file_info(code)
            st0 = JETLS.build_syntax_tree(fi)
            symbols = JETLS.extract_document_symbols(st0, fi)
            @test length(symbols) == 1
            @test symbols[1].name == "Color"
            @test symbols[1].kind == SymbolKind.Enum
            @test symbols[1].detail == "@enum Color"
            @test symbols[1].children !== nothing
            @test length(symbols[1].children) == 3
            @test symbols[1].children[1].name == "red"
            @test symbols[1].children[1].kind == SymbolKind.EnumMember
            @test symbols[1].children[1].detail == "red::Color"
            @test symbols[1].children[2].name == "green"
            @test symbols[1].children[3].name == "blue"
        end

        let code = "@enum Fruit apple=1 orange=2"
            fi = make_file_info(code)
            st0 = JETLS.build_syntax_tree(fi)
            symbols = JETLS.extract_document_symbols(st0, fi)
            @test length(symbols) == 1
            @test symbols[1].name == "Fruit"
            @test symbols[1].kind == SymbolKind.Enum
            @test symbols[1].children !== nothing
            @test length(symbols[1].children) == 2
            @test symbols[1].children[1].name == "apple"
            @test symbols[1].children[1].detail == "apple::Fruit"
            @test symbols[1].children[2].name == "orange"
            @test symbols[1].children[2].detail == "orange::Fruit"
        end

        let code = "@enum Fruit::Int apple orange"
            fi = make_file_info(code)
            st0 = JETLS.build_syntax_tree(fi)
            symbols = JETLS.extract_document_symbols(st0, fi)
            @test length(symbols) == 1
            @test symbols[1].name == "Fruit"
            @test symbols[1].kind == SymbolKind.Enum
            @test symbols[1].detail == "@enum Fruit::Int"
        end

        let code = """
            @enum Color begin
                red
                green
                blue
            end
            """
            fi = make_file_info(code)
            st0 = JETLS.build_syntax_tree(fi)
            symbols = JETLS.extract_document_symbols(st0, fi)
            @test length(symbols) == 1
            @test symbols[1].name == "Color"
            @test symbols[1].kind == SymbolKind.Enum
            @test symbols[1].detail == "@enum Color"
            @test symbols[1].children !== nothing
            @test length(symbols[1].children) == 3
            @test symbols[1].children[1].name == "red"
            @test symbols[1].children[2].name == "green"
            @test symbols[1].children[3].name == "blue"
        end
    end
end

@testset "dotted function names" begin
    @testset "Base.show" begin
        code = "Base.show(io::IO, x) = print(io, x)"
        fi = make_file_info(code)
        st0 = JETLS.build_syntax_tree(fi)
        symbols = JETLS.extract_document_symbols(st0, fi)
        @test length(symbols) == 1
        @test symbols[1].name == "Base.show"
        @test symbols[1].kind == SymbolKind.Function
    end

    @testset "Tables.getcolumn function" begin
        code = """
        function Tables.getcolumn(row::Row, col::Symbol)
            return row[col]
        end
        """
        fi = make_file_info(code)
        st0 = JETLS.build_syntax_tree(fi)
        symbols = JETLS.extract_document_symbols(st0, fi)
        @test length(symbols) == 1
        @test symbols[1].name == "Tables.getcolumn"
        @test symbols[1].kind == SymbolKind.Function
    end
end

@testset "macrocall wrapped definitions" begin
    @testset "@inline function" begin
        code = """
        @inline function foo(x)
            return x
        end
        """
        fi = make_file_info(code)
        st0 = JETLS.build_syntax_tree(fi)
        symbols = JETLS.extract_document_symbols(st0, fi)
        @test length(symbols) == 1
        @test symbols[1].name == "foo"
        @test symbols[1].kind == SymbolKind.Function
    end

    @testset "@noinline short function" begin
        code = "@noinline bar(x) = x + 1"
        fi = make_file_info(code)
        st0 = JETLS.build_syntax_tree(fi)
        symbols = JETLS.extract_document_symbols(st0, fi)
        @test length(symbols) == 1
        @test symbols[1].name == "bar"
        @test symbols[1].kind == SymbolKind.Function
    end

    @testset "Base.@propagate_inbounds function" begin
        code = """
        Base.@propagate_inbounds function getindex(x, i)
            return x[i]
        end
        """
        fi = make_file_info(code)
        st0 = JETLS.build_syntax_tree(fi)
        symbols = JETLS.extract_document_symbols(st0, fi)
        @test length(symbols) == 1
        @test symbols[1].name == "getindex"
        @test symbols[1].kind == SymbolKind.Function
    end
end

@testset "function with return type annotation" begin
    let code = """
        function foo(x)::Int
            return x
        end
        """
        fi = make_file_info(code)
        st0 = JETLS.build_syntax_tree(fi)
        symbols = JETLS.extract_document_symbols(st0, fi)
        @test length(symbols) == 1
        @test symbols[1].name == "foo"
        @test symbols[1].kind == SymbolKind.Function
    end

    let code = "bar(x)::Float64 = x + 1.0"
        fi = make_file_info(code)
        st0 = JETLS.build_syntax_tree(fi)
        symbols = JETLS.extract_document_symbols(st0, fi)
        @test length(symbols) == 1
        @test symbols[1].name == "bar"
        @test symbols[1].kind == SymbolKind.Function
    end
end

@testset "inner constructors" begin
    let code = """
        struct AAA
            a::Int
            AAA() = new()
            AAA(a) = new(a)
        end
        """
        fi = make_file_info(code)
        st0 = JETLS.build_syntax_tree(fi)
        symbols = JETLS.extract_document_symbols(st0, fi)
        @test length(symbols) == 1
        @test symbols[1].name == "AAA"
        @test symbols[1].kind == SymbolKind.Struct
        @test symbols[1].children !== nothing
        @test length(symbols[1].children) == 3
        @test symbols[1].children[1].name == "a"
        @test symbols[1].children[1].kind == SymbolKind.Field
        @test symbols[1].children[2].name == "AAA"
        @test symbols[1].children[2].kind == SymbolKind.Function
        @test symbols[1].children[3].name == "AAA"
        @test symbols[1].children[3].kind == SymbolKind.Function
    end

    let code = """
        struct Point{T}
            x::T
            y::T
            Point{T}(x, y) where {T} = new{T}(x, y)
        end
        """
        fi = make_file_info(code)
        st0 = JETLS.build_syntax_tree(fi)
        symbols = JETLS.extract_document_symbols(st0, fi)
        @test length(symbols) == 1
        @test symbols[1].name == "Point"
        @test symbols[1].children !== nothing
        @test length(symbols[1].children) == 3
        @test symbols[1].children[3].name == "Point"
        @test symbols[1].children[3].kind == SymbolKind.Function
    end
end

@testset "docstring" begin
    let code = """
        \"\"\"
            Foo

        A struct with docstring.
        \"\"\"
        struct Foo
            x::Int
        end
        """
        fi = make_file_info(code)
        st0 = JETLS.build_syntax_tree(fi)
        symbols = JETLS.extract_document_symbols(st0, fi)
        @test length(symbols) == 1
        @test symbols[1].name == "Foo"
        @test symbols[1].kind == SymbolKind.Struct
    end

    let code = """
        \"\"\"
            bar(x)

        A function with docstring.
        \"\"\"
        function bar(x)
            return x
        end
        """
        fi = make_file_info(code)
        st0 = JETLS.build_syntax_tree(fi)
        symbols = JETLS.extract_document_symbols(st0, fi)
        @test length(symbols) == 1
        @test symbols[1].name == "bar"
        @test symbols[1].kind == SymbolKind.Function
    end
end

@testset "global variable" begin
    let code = "global xxx::T = nothing"
        fi = make_file_info(code)
        st0 = JETLS.build_syntax_tree(fi)
        symbols = JETLS.extract_document_symbols(st0, fi)
        @test length(symbols) == 1
        @test symbols[1].name == "xxx"
        @test symbols[1].kind == SymbolKind.Variable
    end

    let code = "global x, y = 1, 2"
        fi = make_file_info(code)
        st0 = JETLS.build_syntax_tree(fi)
        symbols = JETLS.extract_document_symbols(st0, fi)
        @test length(symbols) == 2
        @test symbols[1].name == "x"
        @test symbols[1].kind == SymbolKind.Variable
        @test symbols[2].name == "y"
        @test symbols[2].kind == SymbolKind.Variable
    end

    let code = "global xxx"
        fi = make_file_info(code)
        st0 = JETLS.build_syntax_tree(fi)
        symbols = JETLS.extract_document_symbols(st0, fi)
        @test length(symbols) == 1
        @test symbols[1].name == "xxx"
        @test symbols[1].kind == SymbolKind.Variable
    end

    let code = "global xxx::Int"
        fi = make_file_info(code)
        st0 = JETLS.build_syntax_tree(fi)
        symbols = JETLS.extract_document_symbols(st0, fi)
        @test length(symbols) == 1
        @test symbols[1].name == "xxx"
        @test symbols[1].kind == SymbolKind.Variable
        @test symbols[1].detail == "global xxx::Int"
    end
end

@testset "let block" begin
    let code = """
        let x = 42
            y = x
            println(x, y)
        end
        """
        fi = make_file_info(code)
        st0 = JETLS.build_syntax_tree(fi)
        symbols = JETLS.extract_document_symbols(st0, fi)
        @test length(symbols) == 1
        @test symbols[1].detail == "let x = 42"
        @test symbols[1].kind == SymbolKind.Namespace
        @test symbols[1].children !== nothing
        @test length(symbols[1].children) == 2
        names = Set(c.name for c in symbols[1].children)
        @test "x" in names
        @test "y" in names
    end

    let code = """
        let x = 1,
            y = 2
            println(x, y)
        end
        """
        fi = make_file_info(code)
        st0 = JETLS.build_syntax_tree(fi)
        symbols = JETLS.extract_document_symbols(st0, fi)
        @test length(symbols) == 1
        @test symbols[1].detail == "let x = 1,\n    y = 2"
        @test symbols[1].kind == SymbolKind.Namespace
        @test symbols[1].children !== nothing
        @test length(symbols[1].children) == 2
        names = Set(c.name for c in symbols[1].children)
        @test "x" in names
        @test "y" in names
    end
end

@testset "while block" begin
    let code = """
        while true
            x = 1
            break
        end
        """
        fi = make_file_info(code)
        st0 = JETLS.build_syntax_tree(fi)
        symbols = JETLS.extract_document_symbols(st0, fi)
        @test length(symbols) == 1
        @test symbols[1].detail == "while true"
        @test symbols[1].kind == SymbolKind.Namespace
        @test symbols[1].children !== nothing
        @test length(symbols[1].children) == 1
        @test symbols[1].children[1].name == "x"
    end
end

@testset "for block" begin
    let code = """
        for i in 1:10
            x = i
        end
        """
        fi = make_file_info(code)
        st0 = JETLS.build_syntax_tree(fi)
        symbols = JETLS.extract_document_symbols(st0, fi)
        @test length(symbols) == 1
        @test symbols[1].detail == "for i in 1:10"
        @test symbols[1].kind == SymbolKind.Namespace
        @test symbols[1].children !== nothing
        names = Set(c.name for c in symbols[1].children)
        @test "i" in names
        @test "x" in names
    end
end

@testset "if block" begin
    let code = """
        if cond
            x = 1
        end
        """
        fi = make_file_info(code)
        st0 = JETLS.build_syntax_tree(fi)
        symbols = JETLS.extract_document_symbols(st0, fi)
        @test length(symbols) == 1
        @test symbols[1].detail == "if cond"
        @test symbols[1].kind == SymbolKind.Namespace
        @test symbols[1].children !== nothing
        @test length(symbols[1].children) == 1
        @test symbols[1].children[1].name == "x"
    end

    let code = """
        if cond1
            a = nothing
        elseif cond2
            b = :mysymbol
        else
            c = missing
        end
        """
        fi = make_file_info(code)
        st0 = JETLS.build_syntax_tree(fi)
        symbols = JETLS.extract_document_symbols(st0, fi)
        @test length(symbols) == 1
        @test symbols[1].detail == "if cond1"
        @test symbols[1].kind == SymbolKind.Namespace
        @test symbols[1].children !== nothing
        @test length(symbols[1].children) == 3
        names = [c.name for c in symbols[1].children]
        @test names == ["a", "b", "c"]
    end

    let code = """
        @static if VERSION >= v"1.10"
            foo() = 1
        else
            foo() = 2
        end
        """
        fi = make_file_info(code)
        st0 = JETLS.build_syntax_tree(fi)
        symbols = JETLS.extract_document_symbols(st0, fi)
        @test length(symbols) == 1
        @test symbols[1].detail == "@static if VERSION >= v\"1.10\""
        @test symbols[1].kind == SymbolKind.Namespace
        @test symbols[1].children !== nothing
        @test length(symbols[1].children) == 2
        @test all(c.name == "foo" for c in symbols[1].children)
    end
end

@testset "const tuple destructuring" begin
    let code = "const x, y = 1, 2"
        fi = make_file_info(code)
        st0 = JETLS.build_syntax_tree(fi)
        symbols = JETLS.extract_document_symbols(st0, fi)
        @test length(symbols) == 2
        @test symbols[1].name == "x"
        @test symbols[1].kind == SymbolKind.Constant
        @test symbols[2].name == "y"
        @test symbols[2].kind == SymbolKind.Constant
    end

    let code = "const a::Int, b::String = 1, \"hello\""
        fi = make_file_info(code)
        st0 = JETLS.build_syntax_tree(fi)
        symbols = JETLS.extract_document_symbols(st0, fi)
        @test length(symbols) == 2
        @test symbols[1].name == "a"
        @test symbols[1].kind == SymbolKind.Constant
        @test symbols[2].name == "b"
        @test symbols[2].kind == SymbolKind.Constant
    end
end

@testset "local symbol details" begin
    @testset "argument with type annotation" begin
        let code = """
            function foo(x::Int, y::String)
                return x
            end
            """
            fi = make_file_info(code)
            st0 = JETLS.build_syntax_tree(fi)
            symbols = JETLS.extract_document_symbols(st0, fi)
            @test length(symbols) == 1
            children = symbols[1].children
            @test children !== nothing
            x_sym = only(filter(c -> c.name == "x", children))
            y_sym = only(filter(c -> c.name == "y", children))
            @test x_sym.detail == "x::Int"
            @test y_sym.detail == "y::String"
        end
    end

    @testset "argument with default value" begin
        let code = """
            function foo(x=nothing)
                return x
            end
            """
            fi = make_file_info(code)
            st0 = JETLS.build_syntax_tree(fi)
            symbols = JETLS.extract_document_symbols(st0, fi)
            @test length(symbols) == 1
            children = symbols[1].children
            @test children !== nothing
            x_sym = only(filter(c -> c.name == "x", children))
            @test x_sym.detail == "x=nothing"
        end
    end

    @testset "argument with varargs" begin
        let code = """
            function foo(args...)
                return args
            end
            """
            fi = make_file_info(code)
            st0 = JETLS.build_syntax_tree(fi)
            symbols = JETLS.extract_document_symbols(st0, fi)
            @test length(symbols) == 1
            children = symbols[1].children
            @test children !== nothing
            args_sym = only(filter(c -> c.name == "args", children))
            @test args_sym.detail == "args..."
        end
    end

    @testset "argument with @nospecialize" begin
        let code = """
            function foo(@nospecialize arg)
                return typeof(arg)
            end
            """
            fi = make_file_info(code)
            st0 = JETLS.build_syntax_tree(fi)
            symbols = JETLS.extract_document_symbols(st0, fi)
            @test length(symbols) == 1
            children = symbols[1].children
            @test children !== nothing
            args_sym = only(filter(c -> c.name == "arg", children))
            @test args_sym.detail == "@nospecialize arg"
        end
    end

    @testset "local variable with assignment" begin
        let code = """
            function foo()
                x = 42
                return x
            end
            """
            fi = make_file_info(code)
            st0 = JETLS.build_syntax_tree(fi)
            symbols = JETLS.extract_document_symbols(st0, fi)
            @test length(symbols) == 1
            children = symbols[1].children
            @test children !== nothing
            x_sym = only(filter(c -> c.name == "x", children))
            @test x_sym.detail == "x = 42"
        end
    end

    @testset "local variable with type annotation" begin
        let code = """
            function foo()
                x::Int = 42
                return x
            end
            """
            fi = make_file_info(code)
            st0 = JETLS.build_syntax_tree(fi)
            symbols = JETLS.extract_document_symbols(st0, fi)
            @test length(symbols) == 1
            children = symbols[1].children
            @test children !== nothing
            x_sym = only(filter(c -> c.name == "x", children))
            @test x_sym.detail == "x::Int = 42"
        end
    end

    @testset "nested function" begin
        let code = """
            function outer(x)
                function inner(y)
                    return x + y
                end
                return inner
            end
            """
            fi = make_file_info(code)
            st0 = JETLS.build_syntax_tree(fi)
            symbols = JETLS.extract_document_symbols(st0, fi)
            @test length(symbols) == 1
            children = symbols[1].children
            @test children !== nothing
            inner_sym = only(filter(c -> c.name == "inner", children))
            @test inner_sym.kind == SymbolKind.Function
            @test inner_sym.detail == "function inner(y)"
            # inner's children should include y
            @test inner_sym.children !== nothing
            y_sym = only(filter(c -> c.name == "y", inner_sym.children))
            @test y_sym.kind == SymbolKind.Object
        end
    end

    @testset "static parameter" begin
        let code = """
            function foo(x::T) where {T <: Number}
                return x
            end
            """
            fi = make_file_info(code)
            st0 = JETLS.build_syntax_tree(fi)
            symbols = JETLS.extract_document_symbols(st0, fi)
            @test length(symbols) == 1
            children = symbols[1].children
            @test children !== nothing
            T_syms = filter(c -> c.name == "T", children)
            @test length(T_syms) == 1
            @test T_syms[1].kind == SymbolKind.TypeParameter
            @test T_syms[1].detail == "T <: Number"
        end
    end

    @testset "nested function with default argument" begin
        let code = """
            function outer()
                function inner(x=nothing)
                    return x
                end
                return inner
            end
            """
            fi = make_file_info(code)
            st0 = JETLS.build_syntax_tree(fi)
            symbols = JETLS.extract_document_symbols(st0, fi)
            @test length(symbols) == 1
            children = symbols[1].children
            @test children !== nothing
            inner_sym = only(filter(c -> c.name == "inner", children))
            @test inner_sym.children !== nothing
            x_sym = only(filter(c -> c.name == "x", inner_sym.children))
            @test x_sym.detail == "x=nothing"
        end
    end

    @testset "for loop iterator" begin
        let code = """
            for i in 1:10
                x = i
            end
            """
            fi = make_file_info(code)
            st0 = JETLS.build_syntax_tree(fi)
            symbols = JETLS.extract_document_symbols(st0, fi)
            @test length(symbols) == 1
            children = symbols[1].children
            @test children !== nothing
            i_sym = only(filter(c -> c.name == "i", children))
            @test i_sym.detail == "for i in 1:10"
            x_sym = only(filter(c -> c.name == "x", children))
            @test x_sym.detail == "x = i"
        end
    end

    @testset "tuple destructuring" begin
        let code = """
            function foo()
                x, y = 1, 2
                return x + y
            end
            """
            fi = make_file_info(code)
            st0 = JETLS.build_syntax_tree(fi)
            symbols = JETLS.extract_document_symbols(st0, fi)
            @test length(symbols) == 1
            children = symbols[1].children
            @test children !== nothing
            x_sym = only(filter(c -> c.name == "x", children))
            y_sym = only(filter(c -> c.name == "y", children))
            @test x_sym.detail == "x, y = 1, 2"
            @test y_sym.detail == "x, y = 1, 2"
        end
    end

    @testset "let block variable" begin
        let code = """
            let x = 42
                x + 1
            end
            """
            fi = make_file_info(code)
            st0 = JETLS.build_syntax_tree(fi)
            symbols = JETLS.extract_document_symbols(st0, fi)
            @test length(symbols) == 1
            children = symbols[1].children
            @test children !== nothing
            x_sym = only(filter(c -> c.name == "x", children))
            @test x_sym.detail == "x = 42"
        end
    end

    @testset "named tuple destructuring (local)" begin
        let code = """
            function foo(obj)
                (; x, y) = obj
                return x + y
            end
            """
            fi = make_file_info(code)
            st0 = JETLS.build_syntax_tree(fi)
            symbols = JETLS.extract_document_symbols(st0, fi)
            @test length(symbols) == 1
            children = symbols[1].children
            @test children !== nothing
            x_sym = only(filter(c -> c.name == "x", children))
            y_sym = only(filter(c -> c.name == "y", children))
            @test x_sym.detail == "(; x, y) = obj"
            @test y_sym.detail == "(; x, y) = obj"
        end
    end
end

@testset "keyword argument" begin
    let code = """
        function outer()
            function inner(_; kw)
                return kw
            end
            return inner
        end
        """
        fi = make_file_info(code)
        st0 = JETLS.build_syntax_tree(fi)
        symbols = JETLS.extract_document_symbols(st0, fi)
        @test length(symbols) == 1
        children = symbols[1].children
        @test children !== nothing
        inner_sym = only(filter(c -> c.name == "inner", children))
        @test inner_sym.children !== nothing
        kw_sym = only(filter(c -> c.name == "kw", inner_sym.children))
        @test kw_sym.detail == "; kw"
    end

    # Varargs keyword argument should show only its own detail, not the entire parameters block
    let code = """
        function outer()
            function inner(_; kw=nothing, kws...)
                return (kw, kws)
            end
            return inner
        end
        """
        fi = make_file_info(code)
        st0 = JETLS.build_syntax_tree(fi)
        symbols = JETLS.extract_document_symbols(st0, fi)
        @test length(symbols) == 1
        children = symbols[1].children
        @test children !== nothing
        inner_sym = only(filter(c -> c.name == "inner", children))
        @test inner_sym.children !== nothing
        kw_sym = only(filter(c -> c.name == "kw", inner_sym.children))
        @test kw_sym.detail == "kw=nothing"
        kws_sym = only(filter(c -> c.name == "kws", inner_sym.children))
        @test kws_sym.detail == "kws..."
    end
end

@testset "named tuple destructuring (global)" begin
    let code = "(; a, b) = obj"
        fi = make_file_info(code)
        st0 = JETLS.build_syntax_tree(fi)
        symbols = JETLS.extract_document_symbols(st0, fi)
        @test length(symbols) == 2
        a_sym = only(filter(s -> s.name == "a", symbols))
        b_sym = only(filter(s -> s.name == "b", symbols))
        @test a_sym.kind == SymbolKind.Variable
        @test b_sym.kind == SymbolKind.Variable
        @test a_sym.detail == "(; a, b) = obj"
        @test b_sym.detail == "(; a, b) = obj"
    end
end

@testset "deduplication" begin
    # Arguments should not be duplicated when kwsorter scopes are merged
    let code = """
        function kwfunc(x; kw)
            x, kw
        end
        """
        fi = make_file_info(code)
        st0 = JETLS.build_syntax_tree(fi)
        symbols = JETLS.extract_document_symbols(st0, fi)
        @test length(symbols) == 1
        children = symbols[1].children
        @test children !== nothing
        x_syms = filter(c -> c.name == "x", children)
        @test length(x_syms) == 1  # x should appear only once, not duplicated
    end
end

end # module test_document_symbol
