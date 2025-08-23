module test_document_highlight

using Test
using JETLS
using JETLS.LSP

include(normpath(pkgdir(JETLS), "test", "setup.jl"))
include(normpath(pkgdir(JETLS), "test", "jsjl_utils.jl"))

@testset "lowering_document_highlights!" begin
    @testset "local binding highlights" begin
        let code = """
            function func(│xx│x│, yyy)
                println(│xx│x│, yyy)
            end
            """
            clean_code, positions = JETLS.get_text_and_positions(code)
            @test length(positions) == 6
            fi = JETLS.FileInfo(#=version=#0, clean_code, @__FILE__)
            @test issorted(positions; by = x -> JETLS.xy_to_offset(fi, x))
            for pos in positions
                highlights = JETLS.lowering_document_highlights(fi, pos, @__MODULE__)
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
            clean_code, positions = JETLS.get_text_and_positions(code)
            @test length(positions) == 4
            fi = JETLS.FileInfo(#=version=#0, clean_code, @__FILE__)
            @test issorted(positions; by = x -> JETLS.xy_to_offset(fi, x))
            for pos in positions
                highlights = JETLS.lowering_document_highlights(fi, pos, @__MODULE__)
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
            clean_code, positions = JETLS.get_text_and_positions(code)
            @test length(positions) == 6
            fi = JETLS.FileInfo(#=version=#0, clean_code, @__FILE__)
            @test issorted(positions; by = x -> JETLS.xy_to_offset(fi, x))
            for pos in positions
                highlights = JETLS.lowering_document_highlights(fi, pos, @__MODULE__)
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
            clean_code, positions = JETLS.get_text_and_positions(code)
            @test length(positions) == 4
            fi = JETLS.FileInfo(#=version=#0, clean_code, @__FILE__)
            @test issorted(positions; by = x -> JETLS.xy_to_offset(fi, x))
            for pos in positions
                highlights = JETLS.lowering_document_highlights(fi, pos, @__MODULE__)
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
            clean_code, positions = JETLS.get_text_and_positions(code)
            @test length(positions) == 10
            fi = JETLS.FileInfo(#=version=#0, clean_code, @__FILE__)
            @test issorted(positions; by = x -> JETLS.xy_to_offset(fi, x))
            for i = (1,2,5,6,7,8) # x
                pos = positions[i]
                highlights = JETLS.lowering_document_highlights(fi, pos, @__MODULE__)
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
                highlights = JETLS.lowering_document_highlights(fi, pos, @__MODULE__)
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

    @testset "No highlights for global bindings" begin
        code = """
        function func│(xxx, yyy)
            println│(xxx, yyy)
        end
        """
        clean_code, positions = JETLS.get_text_and_positions(code)
        @test length(positions) == 2
        fi = JETLS.FileInfo(#=version=#0, clean_code, @__FILE__)
        for pos in positions
            highlights = JETLS.lowering_document_highlights(fi, pos, @__MODULE__)
            @test length(highlights) == 0
        end
    end
end

end # test_document_highlight
