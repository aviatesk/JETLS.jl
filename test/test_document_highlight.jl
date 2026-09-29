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

function make_document_highlight_request(id::Int, uri::URI, pos::Position)
    return DocumentHighlightRequest(;
        id,
        params = DocumentHighlightParams(;
            textDocument = TextDocumentIdentifier(; uri),
            position = pos))
end

function test_snapshot_highlights(highlights::Vector{DocumentHighlight}, positions::Vector{Position})
    expected = Set(
        (Range(; start = positions[i], var"end" = positions[i+1]),
            i == 1 ? DocumentHighlightKind.Write : DocumentHighlightKind.Read)
        for i in 1:2:length(positions))
    @test length(highlights) == length(expected)
    @test Set((highlight.range, highlight.kind) for highlight in highlights) == expected
end

@testset "document highlight snapshot ordering" begin
    captured, captured_positions = JETLS.get_text_and_positions(
        "let │captured│ = 1\n    │captured│\nend")
    later, later_positions = JETLS.get_text_and_positions(
        "let │later│ = 2\n    │later│ + │later│\nend")
    pos = Position(; line = 1, character = 5)

    @testset "prior and later didChange" begin
        with_manual_dispatch_server() do server, recorder
            uri = filepath2uri(@__FILE__)
            JETLS.cache_file_info!(server, uri, 1, "let initial = 0\n    initial\nend")
            request = make_document_highlight_request(1, uri, pos)
            next_request = make_document_highlight_request(2, uri, pos)
            @test JETLS.is_snapshot_msg(request)
            prepared = queued_snapshot_requests(server, [
                make_DidChangeTextDocumentNotification(uri, captured, 2), request,
                make_DidChangeTextDocumentNotification(uri, later, 3), next_request])
            @test length(prepared) == 2
            @test prepared[1].msg === request
            @test prepared[2].msg === next_request
            @test prepared[1].msg.params.position == pos
            @test prepared[1].snapshot.fi.version == 2
            @test prepared[1].snapshot.cache_uri == uri
            @test prepared[1].snapshot.notebook === nothing
            @test prepared[2].snapshot.fi.version == 3
            @test JETLS.get_file_info(server.state, uri) === prepared[2].snapshot.fi
            @test prepared[1].snapshot.fi !== prepared[2].snapshot.fi

            for (item, positions) in zip(prepared, (captured_positions, later_positions))
                response = dispatch_snapshot_request(server, recorder, item)
                @test response isa DocumentHighlightResponse
                @test response.error === nothing
                test_snapshot_highlights(response.result, positions)
            end
        end
    end

    @testset "missing cache is not retried" begin
        with_manual_dispatch_server() do server, recorder
            uri = filepath2uri(@__FILE__)
            request = make_document_highlight_request(1, uri, pos)
            prepared = only(queued_snapshot_requests(server, [request]))
            @test prepared.snapshot === nothing
            @test JETLS.get_file_info(server.state, uri) === nothing
            JETLS.cache_file_info!(server, uri, 1, captured)
            current = only(queued_snapshot_requests(server, [
                make_document_highlight_request(2, uri, pos)]))
            @test current.snapshot !== nothing

            response = dispatch_snapshot_request(server, recorder, prepared)
            @test response isa ResponseMessage
            @test response.error === nothing
            @test response.result === null
            response = dispatch_snapshot_request(server, recorder, current)
            @test response isa DocumentHighlightResponse
            @test response.error === nothing
            test_snapshot_highlights(response.result, captured_positions)
        end
    end

    @testset "close and reopen at the same version" begin
        with_manual_dispatch_server() do server, recorder
            uri = filepath2uri(@__FILE__)
            JETLS.cache_file_info!(server, uri, 1, captured)
            request = make_document_highlight_request(1, uri, pos)
            prepared = only(queued_snapshot_requests(server, [
                request, make_DidCloseTextDocumentNotification(uri)]))
            @test prepared.snapshot.fi.version == 1
            @test JETLS.get_file_info(server.state, uri) === nothing
            while isready(recorder.sent_queue)
                @test take!(recorder.sent_queue) isa PublishDiagnosticsNotification
            end
            current = only(queued_snapshot_requests(server, [
                make_DidOpenTextDocumentNotification(uri, later; version = 1),
                make_document_highlight_request(2, uri, pos)]))
            @test current.snapshot.fi.version == 1
            @test current.snapshot.fi.identity != prepared.snapshot.fi.identity
            @test JETLS.get_file_info(server.state, uri) === current.snapshot.fi

            response = dispatch_snapshot_request(server, recorder, prepared)
            @test response isa DocumentHighlightResponse
            @test response.error === nothing
            test_snapshot_highlights(response.result, captured_positions)
            response = dispatch_snapshot_request(server, recorder, current)
            @test response isa DocumentHighlightResponse
            @test response.error === nothing
            test_snapshot_highlights(response.result, later_positions)
        end
    end

    @testset "cancellation before prepared dispatch" begin
        with_manual_dispatch_server() do server, recorder
            uri = filepath2uri(@__FILE__)
            JETLS.cache_file_info!(server, uri, 1, captured)
            request = make_document_highlight_request(1, uri, pos)
            prepared = only(queued_snapshot_requests(server, [request]))
            @test prepared.snapshot !== nothing
            JETLS.handler_concurrent_message(server, CancelRequestNotification(;
                params = CancelParams(; id = request.id)))
            @test JETLS.is_cancelled(server.state.currently_handled[request.id])
            response = dispatch_snapshot_request(server, recorder, prepared)
            @test response isa ResponseMessage
            @test response.result === nothing
            @test response.error isa ResponseError
            @test response.error.code == ErrorCodes.RequestCancelled
        end
    end
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
                    highlights = JETLS.document_highlights(fi, pos)
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
                    highlights = JETLS.document_highlights(fi, positions[i])
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
                    highlights = JETLS.document_highlights(fi, positions[i])
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
                    highlights = JETLS.document_highlights(fi, pos)
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
