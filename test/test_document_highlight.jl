module test_document_highlight

using Test
using JETLS
using JETLS.LSP

include(normpath(pkgdir(JETLS), "test", "setup.jl"))
include(normpath(pkgdir(JETLS), "test", "jsjl-utils.jl"))

# Used by the global binding tests:
function myfunc end
global globalvar::Int = 42
const MYCONST = "constant"
struct MyType
    field::Int
end

function highlight_testcase(code::AbstractString, n::Int)
    clean_code, positions = JETLS.get_text_and_positions(code)
    @assert length(positions) == n
    fi = JETLS.FileInfo(#=version=#0, clean_code, @__FILE__)
    @assert issorted(positions; by = x -> JETLS.xy_to_offset(fi, x))
    return fi, positions
end

@testset "document_highlights!" begin
    @testset "local binding highlights" begin
        let code = """
            function func(│xx│x│, yyy)
                println(│xx│x│, yyy)
            end
            """
            fi, positions = highlight_testcase(code, 6)
            for pos in positions
                highlights = JETLS.document_highlights(fi, pos)
                @test length(highlights) == 2
                @test any(highlights) do highlight
                    highlight.range.start == positions[1] &&
                    highlight.range.var"end" == positions[3] &&
                    highlight.kind == DocumentHighlightKind.Write
                end
                @test any(highlights) do highlight
                    highlight.range.start == positions[4] &&
                    highlight.range.var"end" == positions[6] &&
                    highlight.kind == DocumentHighlightKind.Read
                end
            end
        end

        let code = """
            function func(xxx; │kw│)
                println(xxx, │kw│)
            end
            """
            fi, positions = highlight_testcase(code, 4)
            for pos in positions
                highlights = JETLS.document_highlights(fi, pos)
                @test length(highlights) == 2
                @test any(highlights) do highlight
                    highlight.range.start == positions[1] &&
                    highlight.range.var"end" == positions[2] &&
                    highlight.kind == DocumentHighlightKind.Write
                end
                @test any(highlights) do highlight
                    highlight.range.start == positions[3] &&
                    highlight.range.var"end" == positions[4] &&
                    highlight.kind == DocumentHighlightKind.Read
                end
            end
        end

        @testset "static parameter highlight" begin
            code = """
            func(::│TTT│) where │TTT│<:Number = zero(│TTT│)
            """
            fi, positions = highlight_testcase(code, 6)
            for pos in positions
                highlights = JETLS.document_highlights(fi, pos)
                @test length(highlights) == 3
                @test any(highlights) do highlight
                    highlight.range.start == positions[1] &&
                    highlight.range.var"end" == positions[2]
                end
                @test any(highlights) do highlight
                    highlight.range.start == positions[3] &&
                    highlight.range.var"end" == positions[4] &&
                    highlight.kind == DocumentHighlightKind.Write
                end
                @test any(highlights) do highlight
                    highlight.range.start == positions[5] &&
                    highlight.range.var"end" == positions[6] &&
                    highlight.kind == DocumentHighlightKind.Read
                end
            end
        end

        @testset "highlight with macrocalls" begin
            code = """
            func(│xxx│) = @something rand((│xxx│, nothing)) return nothing
            """
            fi, positions = highlight_testcase(code, 4)
            for pos in positions
                highlights = JETLS.document_highlights(fi, pos)
                @test length(highlights) == 2
                @test any(highlights) do highlight
                    highlight.range.start == positions[1] &&
                    highlight.range.var"end" == positions[2] &&
                    highlight.kind == DocumentHighlightKind.Write
                end
                @test any(highlights) do highlight
                    highlight.range.start == positions[3] &&
                    highlight.range.var"end" == positions[4] &&
                    highlight.kind == DocumentHighlightKind.Read
                end
            end
        end

        @testset "highlight with @nospecialize" begin
            code = """
            function func(@nospecialize(│xxx│), yyy)
                zzz = │xxx│, yyy
                zzz, yyy
            end
            """
            fi, positions = highlight_testcase(code, 4)
            for pos in positions
                highlights = JETLS.document_highlights(fi, pos)
                @test length(highlights) == 2
                @test any(highlights) do highlight
                    highlight.range.start == positions[1] &&
                    highlight.range.var"end" == positions[2] &&
                    highlight.kind == DocumentHighlightKind.Write
                end
                @test any(highlights) do highlight
                    highlight.range.start == positions[3] &&
                    highlight.range.var"end" == positions[4] &&
                    highlight.kind == DocumentHighlightKind.Read
                end
            end
        end

        let code = """
            let │xxx│, │yyy│ = :yyy
                │xxx│ = :xxx
                println(│xxx│, │yyy│)
            end
            """
            fi, positions = highlight_testcase(code, 10)
            for i = (1,2,5,6,7,8) # x
                pos = positions[i]
                highlights = JETLS.document_highlights(fi, pos)
                @test length(highlights) == 3
                @test count(highlights) do highlight
                    highlight.range.start == positions[1] &&
                    highlight.range.var"end" == positions[2] &&
                    highlight.kind == DocumentHighlightKind.Text # only declaration
                end == 1
                @test count(highlights) do highlight
                    highlight.range.start == positions[5] &&
                    highlight.range.var"end" == positions[6] &&
                    highlight.kind == DocumentHighlightKind.Write
                end == 1
                @test count(highlights) do highlight
                    highlight.range.start == positions[7] &&
                    highlight.range.var"end" == positions[8] &&
                    highlight.kind == DocumentHighlightKind.Read
                end == 1
            end
            for i = (3,4,9,10) # y
                pos = positions[i]
                highlights = JETLS.document_highlights(fi, pos)
                @test length(highlights) == 2 # no duplications for the declaration and the write
                @test count(highlights) do highlight
                    highlight.range.start == positions[3] &&
                    highlight.range.var"end" == positions[4] &&
                    highlight.kind == DocumentHighlightKind.Write # prefer write
                end == 1
                @test count(highlights) do highlight
                    highlight.range.start == positions[9] &&
                    highlight.range.var"end" == positions[10] &&
                    highlight.kind == DocumentHighlightKind.Read
                end == 1
            end
        end
    end

    @testset "global bindings highlights" begin
        let code = """
            function │myfunc│(x)
                x + 1
            end

            │myfunc│(1)

            function │myfunc│(x, y)
                x + y
            end

            result = │myfunc│(2, 3)
            """
            fi, positions = highlight_testcase(code, 8)
            for pos in positions
                highlights = JETLS.document_highlights(fi, pos)
                @test length(highlights) == 4
                @test count(highlights) do highlight
                    highlight.range.start == positions[1] &&
                    highlight.range.var"end" == positions[2] &&
                    highlight.kind == DocumentHighlightKind.Write
                end == 1
                @test count(highlights) do highlight
                    highlight.range.start == positions[3] &&
                    highlight.range.var"end" == positions[4] &&
                    highlight.kind == DocumentHighlightKind.Read
                end == 1
                @test count(highlights) do highlight
                    highlight.range.start == positions[5] &&
                    highlight.range.var"end" == positions[6] &&
                    highlight.kind == DocumentHighlightKind.Write
                end == 1
                @test count(highlights) do highlight
                    highlight.range.start == positions[7] &&
                    highlight.range.var"end" == positions[8] &&
                    highlight.kind == DocumentHighlightKind.Read
                end == 1
            end
        end

        # self-recursion: recursive calls are genuine uses and should be
        # highlighted alongside the definition
        let code = """
            function │fib│(n)
                if n < 2
                    return n
                end
                return │fib│(n-1) + │fib│(n-2)
            end
            """
            fi, positions = highlight_testcase(code, 6)
            for pos in positions
                highlights = JETLS.document_highlights(fi, pos)
                @test length(highlights) == 3
                @test count(highlights) do highlight
                    highlight.range.start == positions[1] &&
                    highlight.range.var"end" == positions[2] &&
                    highlight.kind == DocumentHighlightKind.Write
                end == 1
                @test count(highlights) do highlight
                    highlight.range.start == positions[3] &&
                    highlight.range.var"end" == positions[4] &&
                    highlight.kind == DocumentHighlightKind.Read
                end == 1
                @test count(highlights) do highlight
                    highlight.range.start == positions[5] &&
                    highlight.range.var"end" == positions[6] &&
                    highlight.kind == DocumentHighlightKind.Read
                end == 1
            end
        end

        let code = """
            global │globalvar│::Int = 42

            function use_global()
                println(│globalvar│)
            end

            │globalvar│ = 100
            """
            fi, positions = highlight_testcase(code, 6)
            for pos in positions
                highlights = JETLS.document_highlights(fi, pos)
                @test length(highlights) == 3
                @test count(highlights) do highlight
                    highlight.range.start == positions[1] &&
                    highlight.range.var"end" == positions[2] &&
                    highlight.kind == DocumentHighlightKind.Write
                end == 1
                @test count(highlights) do highlight
                    highlight.range.start == positions[3] &&
                    highlight.range.var"end" == positions[4] &&
                    highlight.kind == DocumentHighlightKind.Read
                end == 1
                @test count(highlights) do highlight
                    highlight.range.start == positions[5] &&
                    highlight.range.var"end" == positions[6] &&
                    highlight.kind == DocumentHighlightKind.Write
                end == 1
            end
        end

        let code = """
            const │MYCONST│ = "constant"

            function get_const()
                │MYCONST│
            end
            """
            fi, positions = highlight_testcase(code, 4)
            for pos in positions
                highlights = JETLS.document_highlights(fi, pos)
                @test length(highlights) == 2
                @test count(highlights) do highlight
                    highlight.range.start == positions[1] &&
                    highlight.range.var"end" == positions[2] &&
                    highlight.kind == DocumentHighlightKind.Write
                end == 1
                @test count(highlights) do highlight
                    highlight.range.start == positions[3] &&
                    highlight.range.var"end" == positions[4] &&
                    highlight.kind == DocumentHighlightKind.Read
                end == 1
            end
        end

        let code = """
            const │MYCONST│ = "constant"

            macro noop(ex) esc(ex) end

            function get_const()
                @noop │MYCONST│
            end
            """
            fi, positions = highlight_testcase(code, 4)
            for pos in positions
                highlights = JETLS.document_highlights(fi, pos)
                @test length(highlights) == 2
                @test count(highlights) do highlight
                    highlight.range.start == positions[1] &&
                    highlight.range.var"end" == positions[2] &&
                    highlight.kind == DocumentHighlightKind.Write
                end == 1
                @test count(highlights) do highlight
                    highlight.range.start == positions[3] &&
                    highlight.range.var"end" == positions[4] &&
                    highlight.kind == DocumentHighlightKind.Read
                end == 1
            end
        end

        let code = """
            struct │MyType│
                field::Int
            end

            function process(x::│MyType│)
                x.field
            end

            instance = │MyType│(42)
            """
            fi, positions = highlight_testcase(code, 6)
            for pos in positions
                highlights = JETLS.document_highlights(fi, pos)
                @test length(highlights) == 3
                @test count(highlights) do highlight
                    highlight.range.start == positions[1] &&
                    highlight.range.var"end" == positions[2] &&
                    highlight.kind == DocumentHighlightKind.Write
                end == 1
                @test count(highlights) do highlight
                    highlight.range.start == positions[3] &&
                    highlight.range.var"end" == positions[4] &&
                    highlight.kind == DocumentHighlightKind.Read
                end == 1
                @test count(highlights) do highlight
                    highlight.range.start == positions[5] &&
                    highlight.range.var"end" == positions[6] &&
                    highlight.kind == DocumentHighlightKind.Read
                end == 1
            end
        end

        @testset "@generated function highlights" begin
            let code = """
                @generated function foo(│x│)
                    return :(copy(│x│) + │x│)
                end
                """
                fi, positions = highlight_testcase(code, 6)
                for pos in positions
                    highlights = JETLS.document_highlights(fi, pos)
                    @test length(highlights) == 3
                    @test count(highlights) do highlight
                        highlight.range.start == positions[1] &&
                        highlight.range.var"end" == positions[2]
                    end == 1
                    @test count(highlights) do highlight
                        highlight.range.start == positions[3] &&
                        highlight.range.var"end" == positions[4]
                    end == 1
                    @test count(highlights) do highlight
                        highlight.range.start == positions[5] &&
                        highlight.range.var"end" == positions[6]
                    end == 1
                end
            end

            # Static parameter merging: `T` in argument annotation, `where` clause,
            # and body should all be unified.
            let code = """
                @generated function foo(x::│T│) where {│T│}
                    return :(zero(│T│))
                end
                """
                fi, positions = highlight_testcase(code, 6)
                for pos in positions
                    highlights = JETLS.document_highlights(fi, pos)
                    @test length(highlights) == 3
                end
            end
        end

        @testset "highlight with docstring" begin
            let code = """
                \"\"\"Docstring\"\"\"
                function func(│xxx│, yyy)
                    println(│xxx│, yyy)
                end
                """
                fi, positions = highlight_testcase(code, 4)
                for pos in positions
                    highlights = JETLS.document_highlights(fi, pos)
                    @test length(highlights) == 2
                    @test any(highlights) do highlight
                        highlight.range.start == positions[1] &&
                        highlight.range.var"end" == positions[2] &&
                        highlight.kind == DocumentHighlightKind.Write
                    end
                    @test any(highlights) do highlight
                        highlight.range.start == positions[3] &&
                        highlight.range.var"end" == positions[4] &&
                        highlight.kind == DocumentHighlightKind.Read
                    end
                end
            end
        end

        @testset "macro binding highlights" begin
            let code = """
                macro │mymacr│o│(ex)
                    esc(ex)
                end

                │@mymacro│ println("hello")
                │@mymacro│ println("world")
                """
                fi, positions = highlight_testcase(code, 7)
                for pos in positions
                    highlights = JETLS.document_highlights(fi, pos)
                    @test length(highlights) == 3
                    @test count(highlights) do highlight
                        highlight.range.start == positions[1] &&
                        highlight.range.var"end" == positions[3] &&
                        highlight.kind == DocumentHighlightKind.Write
                    end == 1
                    @test count(highlights) do highlight
                        highlight.range.start == positions[4] &&
                        highlight.range.var"end" == positions[5] &&
                        highlight.kind == DocumentHighlightKind.Read
                    end == 1
                    @test count(highlights) do highlight
                        highlight.range.start == positions[6] &&
                        highlight.range.var"end" == positions[7] &&
                        highlight.kind == DocumentHighlightKind.Read
                    end == 1
                end
            end
        end

        @testset "export/public highlights" begin
            let code = """
                function │myfunc│(x)
                    x + 1
                end
                export │myfunc│
                │myfunc│(1)
                """
                fi, positions = highlight_testcase(code, 6)
                for pos in positions
                    highlights = JETLS.document_highlights(fi, pos)
                    @test length(highlights) == 3
                    @test count(highlights) do highlight
                        highlight.range.start == positions[1] &&
                        highlight.range.var"end" == positions[2] &&
                        highlight.kind == DocumentHighlightKind.Write
                    end == 1
                    @test count(highlights) do highlight
                        highlight.range.start == positions[3] &&
                        highlight.range.var"end" == positions[4] &&
                        highlight.kind == DocumentHighlightKind.Read
                    end == 1
                    @test count(highlights) do highlight
                        highlight.range.start == positions[5] &&
                        highlight.range.var"end" == positions[6] &&
                        highlight.kind == DocumentHighlightKind.Read
                    end == 1
                end
            end

            let code = """
                const │MYCONST│ = "constant"
                public │MYCONST│
                get_const() = │MYCONST│ + 1
                """
                fi, positions = highlight_testcase(code, 6)
                for pos in positions
                    highlights = JETLS.document_highlights(fi, pos)
                    @test length(highlights) == 3
                end
            end
        end

        @testset "import/using highlights" begin
            # Import sites are `:decl` occurrences (like `local x`), so they
            # highlight as `Text` rather than `Write`.
            let code = """
                using Base: │myfunc│
                │myfunc│(1)
                """
                fi, positions = highlight_testcase(code, 4)
                for pos in positions
                    highlights = JETLS.document_highlights(fi, pos)
                    @test length(highlights) == 2
                    @test count(highlights) do highlight
                        highlight.range.start == positions[1] &&
                        highlight.range.var"end" == positions[2] &&
                        highlight.kind == DocumentHighlightKind.Text
                    end == 1
                    @test count(highlights) do highlight
                        highlight.range.start == positions[3] &&
                        highlight.range.var"end" == positions[4] &&
                        highlight.kind == DocumentHighlightKind.Read
                    end == 1
                end
            end

            # Alias: clicking on the alias name highlights it + uses
            let code = """
                using Base: foo as │myfunc│
                │myfunc│(1)
                """
                fi, positions = highlight_testcase(code, 4)
                for pos in positions
                    highlights = JETLS.document_highlights(fi, pos)
                    @test length(highlights) == 2
                end
            end

            let code = """
                import Base.│myfunc│
                │myfunc│(1)
                """
                fi, positions = highlight_testcase(code, 4)
                for pos in positions
                    highlights = JETLS.document_highlights(fi, pos)
                    @test length(highlights) == 2
                end
            end
        end
    end
end

end # test_document_highlight
