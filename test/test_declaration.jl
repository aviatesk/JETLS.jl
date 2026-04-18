module test_declaration

using Test
using JETLS
using JETLS.LSP

include(normpath(pkgdir(JETLS), "test", "setup.jl"))

function declaration_testcase(
        code::AbstractString, n::Int;
        filename::AbstractString = joinpath(@__DIR__, "testfile_$(gensym(:declaration)).jl")
    )
    clean_code, positions = JETLS.get_text_and_positions(code)
    @assert length(positions) == n
    fi = JETLS.FileInfo(#=version=#0, clean_code, filename)
    @assert issorted(positions; by = x -> JETLS.xy_to_offset(fi, x))
    furi = filename2uri(filename)
    server = JETLS.Server()
    JETLS.store!(server.state.file_cache) do cache
        Base.PersistentDict(cache, furi => fi), nothing
    end
    return server, fi, positions, furi
end
find_declaration_locations(server, furi, fi, pos) =
    first(JETLS.find_declaration(server, furi, fi, pos))

@testset "declaration for imported names" begin
    let code = """
        using Base: │sin│
        │si│n(1.0)
        """
        server, fi, positions, furi = declaration_testcase(code, 4)
        for pos in positions
            locations = find_declaration_locations(server, furi, fi, pos)
            @test length(locations) == 1
            loc = only(locations)
            @test loc.uri == furi
            @test loc.range.start.line == 0
        end
    end

    # `using M: foo as bar` — cursor anywhere on the alias or its uses
    # should jump to the alias identifier in the import statement.
    let code = """
        using Base: sin as │mysin│
        │mysin│(1.0)
        """
        server, fi, positions, furi = declaration_testcase(code, 4)
        for pos in positions
            locations = find_declaration_locations(server, furi, fi, pos)
            @test length(locations) == 1
            loc = only(locations)
            @test loc.uri == furi
            @test loc.range.start.line == 0
        end
    end
end

@testset "declaration for `local` declarations" begin
    let code = """
        function f()
            local │x│
            │x│ = 1
            return │x│
        end
        """
        server, fi, positions, furi = declaration_testcase(code, 6)
        for pos in positions
            locations = find_declaration_locations(server, furi, fi, pos)
            @test length(locations) == 1
            loc = only(locations)
            @test loc.uri == furi
            @test loc.range.start.line == 1
        end
    end
end

@testset "declaration returns empty when no `:decl` exists" begin
    # A bare global assignment records only `:def`, so declaration finds
    # no location.
    let code = """
        │x│ = 1
        println(│x│)
        """
        server, fi, positions, furi = declaration_testcase(code, 4)
        for pos in positions
            locations = find_declaration_locations(server, furi, fi, pos)
            @test isempty(locations)
        end
    end
end

@testset "declaration falls back to definition when enabled" begin
    # With fallback enabled, a symbol that has only a `:def` (no `:decl`)
    # resolves through `find_definition` rather than returning empty.
    let code = """
        │x│ = 1
        println(│x│)
        """
        server, fi, positions, furi = declaration_testcase(code, 4)
        for pos in positions
            locations, _ = JETLS.find_declaration(
                server, furi, fi, pos; fallback_to_definition=true)
            @test length(locations) == 1
            @test only(locations).uri == furi
            @test only(locations).range.start.line == 0
        end
    end

    # When a `:decl` is available, fallback is not triggered — the import
    # site is preferred over the reflection-based source.
    let code = """
        using Base: │sin│
        │sin│(1.0)
        """
        server, fi, positions, furi = declaration_testcase(code, 4)
        for pos in positions
            locations, _ = JETLS.find_declaration(
                server, furi, fi, pos; fallback_to_definition=true)
            @test length(locations) == 1
            @test only(locations).uri == furi
            @test only(locations).range.start.line == 0
        end
    end
end

end # module test_declaration
