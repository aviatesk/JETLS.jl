module test_references

using Test
using JETLS
using JETLS.LSP

include(normpath(pkgdir(JETLS), "test", "setup.jl"))

function find_references(code::AbstractString, pos::Position; include_declaration::Bool=true)
    server = JETLS.Server()
    uri = URI("file:///test.jl")
    fi = JETLS.FileInfo(#=version=#0, code, "test.jl")
    JETLS.store!(server.state.file_cache) do cache
        Base.PersistentDict(cache, uri => fi), nothing
    end
    locations = JETLS.find_references(server, uri, fi, pos; include_declaration)
    return locations
end

@testset "find_references" begin
    @testset "local binding references" begin
        let code = """
            function func(│xx│x│, yyy)
                println(│xx│x│, yyy)
            end
            """
            clean_code, positions = JETLS.get_text_and_positions(code)
            for pos in positions
                refs = find_references(clean_code, pos)
                @test length(refs) == 2
                @test any(ref -> ref.range.start == positions[1] && ref.range.var"end" == positions[3], refs)
                @test any(ref -> ref.range.start == positions[4] && ref.range.var"end" == positions[6], refs)
            end
        end
    end

    @testset "includeDeclaration=false" begin
        let code = """
            function func(│xx│x│, yyy)
                println(│xx│x│, yyy)
            end
            """
            clean_code, positions = JETLS.get_text_and_positions(code)
            for pos in positions
                refs = find_references(clean_code, pos; include_declaration=false)
                @test length(refs) == 1
                ref = only(refs)
                @test ref.range.start == positions[4] && ref.range.var"end" == positions[6]
            end
        end
    end

    @testset "global binding references" begin
        let code = """
            function │myfunc│(x)
                x + 1
            end

            result1 = │myfunc│(1)

            function │myfunc│(x, y)
                x + y
            end

            result2 = │myfunc│(2, 3)
            """
            clean_code, positions = JETLS.get_text_and_positions(code)
            @test length(positions) == 8
            for pos in positions
                refs = find_references(clean_code, pos; include_declaration=false)
                @test length(refs) == 4
            end
        end
    end
end

end # module test_references
