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
                refs = find_references(clean_code, pos; include_declaration=true)
                @test length(refs) == 4
            end
            for pos in positions
                refs = find_references(clean_code, pos; include_declaration=false)
                @test length(refs) == 2
            end
        end

        let code = """
            function │kwfunc│(x; kw=nothing)
                (x, kw)
            end

            result = │kwfunc│(1)
            """
            clean_code, positions = JETLS.get_text_and_positions(code)
            @test length(positions) == 4
            for pos in positions
                refs = find_references(clean_code, pos; include_declaration=true)
                @test length(refs) == 2
            end
            for pos in positions
                refs = find_references(clean_code, pos; include_declaration=false)
                @test length(refs) == 1
            end
        end
    end

    @testset "docstring function references" begin
        let code = """
            \"\"\"Docstring\"\"\"
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

    @testset "@generated function references" begin
        let code = """
            @generated function foo(│xx│x│)
                return :(copy(│xx│x│) + │xx│x│)
            end
            """
            clean_code, positions = JETLS.get_text_and_positions(code)
            @test length(positions) == 9
            for pos in positions
                refs = find_references(clean_code, pos)
                @test length(refs) == 3
            end
        end

        # Static parameter merging
        let code = """
            @generated function foo(x::│T│) where {│T│}
                return :(zero(│T│))
            end
            """
            clean_code, positions = JETLS.get_text_and_positions(code)
            @test length(positions) == 6
            for pos in positions
                refs = find_references(clean_code, pos)
                @test length(refs) == 3
            end
        end
    end

    @testset "macro references" begin
        # Test from macro definition name
        let code = """
            macro │mymacro│(ex)
                esc(ex)
            end

            @mymacro println("hello")
            @mymacro println("world")
            """
            clean_code, positions = JETLS.get_text_and_positions(code)
            for pos in positions
                refs = find_references(clean_code, pos)
                @test length(refs) == 3
            end
        end

        # Test from macrocall
        let code = """
            macro mymacro(ex)
                esc(ex)
            end

            │@mymacro│ println("hello")
            │@mymacro│ println("world")
            """
            clean_code, positions = JETLS.get_text_and_positions(code)
            for pos in positions
                refs = find_references(clean_code, pos)
                @test length(refs) == 3
            end
        end

        # includeDeclaration=false from macrocall
        let code = """
            macro mymacro(ex)
                esc(ex)
            end

            │@mymacro│ println("hello")
            """
            clean_code, positions = JETLS.get_text_and_positions(code)
            for pos in positions
                refs = find_references(clean_code, pos; include_declaration=false)
                @test length(refs) == 1
            end
        end
    end

    @testset "import/using references" begin
        # Cursor on an imported name should find the import site + uses.
        let code = """
            using Base: │myfunc│
            │myfunc│(1)
            │myfunc│()
            """
            clean_code, positions = JETLS.get_text_and_positions(code)
            @test length(positions) == 6
            for pos in positions
                refs = find_references(clean_code, pos; include_declaration=true)
                @test length(refs) == 3
            end
            # includeDeclaration=false excludes the import site (`:def`).
            for pos in positions
                refs = find_references(clean_code, pos; include_declaration=false)
                @test length(refs) == 2
            end
        end
    end

    @testset "export/public references" begin
        # Cursor on an exported name should find all references, including
        # the export statement itself.
        let code = """
            function │myfunc│(x)
                x + 1
            end
            export │myfunc│
            │myfunc│(1)
            """
            clean_code, positions = JETLS.get_text_and_positions(code)
            @test length(positions) == 6
            for pos in positions
                refs = find_references(clean_code, pos; include_declaration=true)
                @test length(refs) == 3
            end
            # With includeDeclaration=false, the definition in `function myfunc`
            # is excluded, but the `:use` inside `export` is kept.
            for pos in positions
                refs = find_references(clean_code, pos; include_declaration=false)
                @test length(refs) == 2
            end
        end
    end

    # Compound-assignment operators (`+=`, `-=`, ...) combined with a macrocall
    # (`x += @elapsed ...`) parse into a `K"unknown_head"` node whose `name_val`
    # attribute carries the operator name; losing that attribute during
    # `remove_macrocalls` reconstruction used to make scope-resolution silently
    # fail, causing `find_references` to return empty on symbols defined in such
    # functions.
    @testset "compound assignment with macrocall" begin
        # Cursor on the definition site of a function whose body contains
        # `+= @elapsed ...`: select_target_binding must succeed.
        let code = """
            function │foo│(x)
                t = 0.0
                t += @elapsed sleep(0)
                return x + t
            end

            result = │foo│(1)
            """
            clean_code, positions = JETLS.get_text_and_positions(code)
            @test length(positions) == 4
            for pos in positions
                refs = find_references(clean_code, pos)
                @test length(refs) == 2
            end
        end

        # Call site lives inside another function that also uses `+= @elapsed`:
        # exercises find_global_binding_occurrences!'s per-statement lowering.
        let code = """
            function │foo│(x)
                return x + 1
            end

            function bar()
                total = 0.0
                total += @elapsed │foo│(1)
                return total
            end
            """
            clean_code, positions = JETLS.get_text_and_positions(code)
            @test length(positions) == 4
            for pos in positions
                refs = find_references(clean_code, pos)
                @test length(refs) == 2
            end
        end
    end

    # Code-generating macros splice their arguments into an implicit `quote`,
    # so argument-position `\$` interpolations are only legal while the
    # macrocall is present. `_remove_macrocalls` must unwrap these
    # interpolations when lifting macro arguments into a `block`; otherwise
    # scope resolution silently fails on any top-level statement containing
    # `@mymacro … \$x` and references inside such statements are lost.
    # Note: `@mymacro` does not need to exist — the macrocall is stripped
    # before scope resolution runs.
    @testset "macrocall argument with interpolation" begin
        let code = """
            const │MY_CONST│ = Set{Symbol}((:foo,))

            let valid = │MY_CONST│
                @mymacro something(::Type{Int}) = \$valid
            end
            """
            clean_code, positions = JETLS.get_text_and_positions(code)
            @test length(positions) == 4
            for pos in positions
                refs = find_references(clean_code, pos)
                @test length(refs) == 2
            end
        end
    end
end

end # module test_references
