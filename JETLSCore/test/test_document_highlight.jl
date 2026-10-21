module test_document_highlight

using Test
using JETLSCore
using JETLSCore.LSP

include("setup.jl")
include("jsjl-utils.jl")

# Used by the global binding tests:
function myfunc end
global globalvar::Int = 42
const MYCONST = "constant"
struct MyType
    field::Int
end

function highlight_testcase(code::AbstractString, n::Int)
    clean_code, positions = JETLSCore.get_text_and_positions(code)
    @assert length(positions) == n
    fi = JETLSCore.FileInfo(#=version=#0, clean_code, @__FILE__; cache_tree0 = true)
    @assert issorted(positions; by = x -> JETLSCore.xy_to_offset(fi, x))
    return fi, positions
end

# Analyzed in this module, so that `test_document_highlight.name` resolves
function module_document_highlights(fi::JETLSCore.FileInfo, pos::Position)
    state = JETLSCore.ServerState()
    uri = filepath2uri(fi.filename)
    JETLSCore.store!(state.file_cache) do cache
        Base.PersistentDict(cache, uri => fi), nothing
    end
    JETLSCore.cache_out_of_scope!(
        state.analysis_manager, uri, JETLSCore.OutOfScope(@__MODULE__))
    return JETLSCore.document_highlights!(DocumentHighlight[], state, uri, fi, pos)
end

@testset HierarchicalTestSet "document_highlights!" begin
    @testset "local binding highlights" begin
        let code = """
            function func(│xx│x│, yyy)
                println(│xx│x│, yyy)
            end
            """
            fi, positions = highlight_testcase(code, 6)
            for pos in positions
                highlights = JETLSCore.document_highlights(fi, pos)
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
                highlights = JETLSCore.document_highlights(fi, pos)
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
                highlights = JETLSCore.document_highlights(fi, pos)
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
                highlights = JETLSCore.document_highlights(fi, pos)
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

        @testset "highlight across @static branches" begin
            # A binding used in a `@static` branch not selected for the current platform
            # is still highlighted: occurrence analysis retains every branch (as a plain
            # conditional), so the use isn't dropped with the unpicked branch.
            let code = """
                function func()
                    │xx│x│ = 1
                    @static if Sys.iswindows()
                        println(│xx│x│)
                    else
                        println(│xx│x│)
                    end
                end
                """
                fi, positions = highlight_testcase(code, 9)
                for pos in positions
                    highlights = JETLSCore.document_highlights(fi, pos)
                    @test length(highlights) == 3
                    @test count(highlights) do highlight
                        highlight.range.start == positions[1] &&
                        highlight.range.var"end" == positions[3] &&
                        highlight.kind == DocumentHighlightKind.Write
                    end == 1
                    @test count(highlights) do highlight
                        highlight.range.start == positions[4] &&
                        highlight.range.var"end" == positions[6] &&
                        highlight.kind == DocumentHighlightKind.Read
                    end == 1
                    @test count(highlights) do highlight
                        highlight.range.start == positions[7] &&
                        highlight.range.var"end" == positions[9] &&
                        highlight.kind == DocumentHighlightKind.Read
                    end == 1
                end
            end
        end

        @testset "do-block parameters in same lowering unit" begin
            # Two `do h` blocks share the same top-level statement but each
            # introduces its own fresh `h` binding; highlights must not cross.
            let code = """
                let
                    foo() do │h│
                        │h│ + 1
                    end
                    bar() do │h│
                        │h│ * 2
                    end
                end
                """
                fi, positions = highlight_testcase(code, 8)
                for i in (1, 2, 3, 4) # cursor inside the first do-block
                    highlights = JETLSCore.document_highlights(fi, positions[i])
                    @test length(highlights) == 2
                    @test count(highlights) do h
                        h.range.start == positions[1] &&
                        h.range.var"end" == positions[2]
                    end == 1
                    @test count(highlights) do h
                        h.range.start == positions[3] &&
                        h.range.var"end" == positions[4] &&
                        h.kind == DocumentHighlightKind.Read
                    end == 1
                end
                for i in (5, 6, 7, 8) # cursor inside the second do-block
                    highlights = JETLSCore.document_highlights(fi, positions[i])
                    @test length(highlights) == 2
                    @test count(highlights) do h
                        h.range.start == positions[5] &&
                        h.range.var"end" == positions[6]
                    end == 1
                    @test count(highlights) do h
                        h.range.start == positions[7] &&
                        h.range.var"end" == positions[8] &&
                        h.kind == DocumentHighlightKind.Read
                    end == 1
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
                highlights = JETLSCore.document_highlights(fi, pos)
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
                highlights = JETLSCore.document_highlights(fi, pos)
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
                highlights = JETLSCore.document_highlights(fi, pos)
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
                highlights = JETLSCore.document_highlights(fi, pos)
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
                highlights = JETLSCore.document_highlights(fi, pos)
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
                highlights = JETLSCore.document_highlights(fi, pos)
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
                highlights = JETLSCore.document_highlights(fi, pos)
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
                highlights = JETLSCore.document_highlights(fi, pos)
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
                highlights = JETLSCore.document_highlights(fi, pos)
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

        @testset "qualified access highlights" begin
            let code = """
                │qualified_func│() = 42
                function test_document_highlight.│qualified_func│(x::Int)
                    x
                end
                test_document_highlight.│qualified_func│()
                """
                fi, positions = highlight_testcase(code, 6)
                highlights = module_document_highlights(fi, positions[1])
                @test Set((h.range, h.kind) for h in highlights) == Set((
                    (Range(; start=positions[1], var"end"=positions[2]), DocumentHighlightKind.Write),
                    (Range(; start=positions[3], var"end"=positions[4]), DocumentHighlightKind.Write),
                    (Range(; start=positions[5], var"end"=positions[6]), DocumentHighlightKind.Read)))
            end

            # a qualified constructor definition of a parametric type
            let code = """
                struct │ParamC│{T}
                    x::T
                end
                function test_document_highlight.│ParamC│{T}(x::AbstractString) where T
                    test_document_highlight.│ParamC│{T}(parse(T, x))
                end
                """
                fi, positions = highlight_testcase(code, 6)
                highlights = module_document_highlights(fi, positions[1])
                @test Set((h.range, h.kind) for h in highlights) == Set((
                    (Range(; start=positions[1], var"end"=positions[2]), DocumentHighlightKind.Write),
                    (Range(; start=positions[3], var"end"=positions[4]), DocumentHighlightKind.Write),
                    (Range(; start=positions[5], var"end"=positions[6]), DocumentHighlightKind.Read)))
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
                    highlights = JETLSCore.document_highlights(fi, pos)
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

            # aviatesk/JETLS.jl#722: a `@generated` function nested inside a
            # `struct` body must still attribute its argument's inert uses.
            let code = """
                struct Test722
                    x::Int
                    @generated function Test722(│x│)
                        return Expr(:new, :(Test722), :│x│)
                    end
                end
                """
                fi, positions = highlight_testcase(code, 4)
                for pos in positions
                    highlights = JETLSCore.document_highlights(fi, pos)
                    @test length(highlights) == 2
                    @test count(highlights) do highlight
                        highlight.range.start == positions[1] &&
                        highlight.range.var"end" == positions[2]
                    end == 1
                    @test count(highlights) do highlight
                        highlight.range.start == positions[3] &&
                        highlight.range.var"end" == positions[4]
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
                    highlights = JETLSCore.document_highlights(fi, pos)
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
                    highlights = JETLSCore.document_highlights(fi, pos)
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
                    highlights = JETLSCore.document_highlights(fi, pos)
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
                    highlights = JETLSCore.document_highlights(fi, pos)
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
                    highlights = JETLSCore.document_highlights(fi, pos)
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
                    highlights = JETLSCore.document_highlights(fi, pos)
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
                    highlights = JETLSCore.document_highlights(fi, pos)
                    @test length(highlights) == 2
                end
            end

            let code = """
                import Base.│myfunc│
                │myfunc│(1)
                """
                fi, positions = highlight_testcase(code, 4)
                for pos in positions
                    highlights = JETLSCore.document_highlights(fi, pos)
                    @test length(highlights) == 2
                end
            end
        end
    end
end

end # test_document_highlight
