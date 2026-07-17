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

@testset HierarchicalTestSet "find_references" begin
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

            # `local xxx` is a declaration site, not a reference; it should be
            # excluded together with the assignment when `includeDeclaration=false`.
            let code = """
                function func()
                    local │xx│x│
                    │xx│x│ = 1
                    return │xx│x│
                end
                """
                clean_code, positions = JETLS.get_text_and_positions(code)
                for pos in positions
                    refs = find_references(clean_code, pos; include_declaration=true)
                    @test length(refs) == 3
                end
                for pos in positions
                    refs = find_references(clean_code, pos; include_declaration=false)
                    @test length(refs) == 1
                    ref = only(refs)
                    @test ref.range.start == positions[7] && ref.range.var"end" == positions[9]
                end
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

        @testset "struct inner constructors" begin
            let code = """
                struct │MyType│
                    x::Int
                    │MyType│() = new(0)
                    function │MyType│(x::Int)
                        new(x)
                    end
                end
                make_mytype() = │MyType│(42)
                """
                clean_code, positions = JETLS.get_text_and_positions(code)
                @test length(positions) == 8
                for pos in positions
                    @test length(find_references(clean_code, pos)) == 4
                    refs = find_references(clean_code, pos; include_declaration=false)
                    @test length(refs) == 1
                    @test only(refs).range == Range(; start=positions[7], var"end"=positions[8])
                end
            end
        end

        @testset "struct definition is not a use" begin
            let code = """
                struct │MyType│
                    x::Int
                end
                f(::│MyType│) = nothing
                """
                clean_code, positions = JETLS.get_text_and_positions(code)
                @test length(positions) == 4
                refs = find_references(clean_code, positions[1]; include_declaration=false)
                expected = Range(; start=positions[3], var"end"=positions[4])
                @test length(refs) == 1 && only(refs).range == expected
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

    @testset "ordinary inert references" begin
        # Code-shaped ordinary quotes resolve free names in the construction module.
        let code = """
            global │x│ = nothing
            f() = :(use(│x│))
            g() = :(│x│ = 1)
            """
            clean_code, positions = JETLS.get_text_and_positions(code)
            @test length(positions) == 6
            for pos in positions
                @test length(find_references(clean_code, pos)) == 3
            end
        end

        # An atomic quoted identifier is Symbol data, not a reference target.
        let code = "names = (:│sin│, :cos)"
            clean_code, positions = JETLS.get_text_and_positions(code)
            @test length(positions) == 2
            for pos in positions
                @test isempty(find_references(clean_code, pos))
            end
        end

        # A bare quoted name does not capture a same-named function argument.
        let code = """
            global │x│ = nothing
            function f(│x│)
                return :(G(│x│))
            end
            """
            clean_code, positions = JETLS.get_text_and_positions(code)
            @test length(positions) == 6
            expected = (2, 2, 1, 1, 2, 2)
            @test all(zip(positions, expected)) do (pos, nrefs)
                length(find_references(clean_code, pos)) == nrefs
            end
        end

        let code = """
            global │x│ = nothing
            function f(│x│)
                return :(G(\$│x│))
            end
            """
            clean_code, positions = JETLS.get_text_and_positions(code)
            @test length(positions) == 6
            for pos in positions[1:2]
                @test length(find_references(clean_code, pos)) == 1
            end
            for pos in positions[3:6]
                @test length(find_references(clean_code, pos)) == 2
            end
        end

        let code = """
            f() = :(let │x│ = 1
                │x│
            end)
            """
            clean_code, positions = JETLS.get_text_and_positions(code)
            @test length(positions) == 4
            for pos in positions
                @test length(find_references(clean_code, pos)) == 2
            end
        end

        let code = """
            function f()
                let │x│ = 1
                    return :(G(\$│x│))
                end
            end
            """
            clean_code, positions = JETLS.get_text_and_positions(code)
            @test length(positions) == 4
            for pos in positions
                @test length(find_references(clean_code, pos)) == 2
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

        let code = """
            Base.@generated function foo(│x│)
                return :(│x│)
            end
            """
            clean_code, positions = JETLS.get_text_and_positions(code)
            @test length(positions) == 4
            for pos in positions
                @test length(find_references(clean_code, pos)) == 2
            end
        end

        # Quote-local bindings shadow generated-function arguments.
        let code = """
            @generated function foo(│x│)
                return :(let │x│ = 1
                    │x│
                end)
            end
            """
            clean_code, positions = JETLS.get_text_and_positions(code)
            @test length(positions) == 6
            @test length(find_references(clean_code, positions[1])) == 1
            @test length(find_references(clean_code, positions[3])) == 2
        end

        # The `let` initializer sees the generated argument, while the new
        # binding shadows it in the body.
        let code = """
            @generated function foo(│x│)
                return :(let │x│ = │x│
                    │x│
                end)
            end
            """
            clean_code, positions = JETLS.get_text_and_positions(code)
            @test length(positions) == 8
            argument_ranges = Set((
                Range(; start=positions[1], var"end"=positions[2]),
                Range(; start=positions[5], var"end"=positions[6])))
            local_ranges = Set((
                Range(; start=positions[3], var"end"=positions[4]),
                Range(; start=positions[7], var"end"=positions[8])))
            for pos in positions[[1, 2, 5, 6]]
                refs = find_references(clean_code, pos)
                @test Set(r.range for r in refs) == argument_ranges
            end
            for pos in positions[[3, 4, 7, 8]]
                refs = find_references(clean_code, pos)
                @test Set(r.range for r in refs) == local_ranges
            end
        end

        # Assignments in the generated method body introduce function locals.
        let code = """
            @generated function foo(x)
                return quote
                    │y│ = x
                    │y│
                end
            end
            """
            clean_code, positions = JETLS.get_text_and_positions(code)
            @test length(positions) == 4
            for pos in positions
                @test length(find_references(clean_code, pos)) == 2
            end
        end

        # Nested generated-body scopes also shadow the generated argument.
        for code in (
                """
                @generated function foo(│x│)
                    return :(function inner(│x│)
                        │x│
                    end)
                end
                """,
                """
                @generated function foo(│x│)
                    return :(map(1:2) do │x│
                        │x│
                    end)
                end
                """,
                """
                @generated function foo(│x│)
                    return :(for │x│ = 1:2
                        println(│x│)
                    end)
                end
                """,
                """
                @generated function foo(│x│)
                    return :([│x│ + 1 for │x│ in 1:2])
                end
                """)
            clean_code, positions = JETLS.get_text_and_positions(code)
            @test length(positions) == 6
            outer_range = Range(; start=positions[1], var"end"=positions[2])
            local_ranges = Set((
                Range(; start=positions[3], var"end"=positions[4]),
                Range(; start=positions[5], var"end"=positions[6])))
            for pos in positions[1:2]
                refs = find_references(clean_code, pos)
                @test Set(r.range for r in refs) == Set((outer_range,))
            end
            for pos in positions[3:6]
                refs = find_references(clean_code, pos)
                @test Set(r.range for r in refs) == local_ranges
            end
        end

        # A quote-local static-parameter name shadows the outer static parameter.
        let code = """
            @generated function foo(x::│T│) where {│T│}
                return :(let │T│ = 1
                    │T│
                end)
            end
            """
            clean_code, positions = JETLS.get_text_and_positions(code)
            @test length(positions) == 8
            outer_ranges = Set((
                Range(; start=positions[1], var"end"=positions[2]),
                Range(; start=positions[3], var"end"=positions[4])))
            local_ranges = Set((
                Range(; start=positions[5], var"end"=positions[6]),
                Range(; start=positions[7], var"end"=positions[8])))
            for pos in positions[1:4]
                refs = find_references(clean_code, pos)
                @test Set(r.range for r in refs) == outer_ranges
            end
            for pos in positions[5:8]
                refs = find_references(clean_code, pos)
                @test Set(r.range for r in refs) == local_ranges
            end
        end

        # The generated argument scope must not leak into a nested quote stage.
        let code = """
            @generated function foo(│x│)
                return :(begin
                    │x│
                    :(│x│)
                end)
            end
            """
            clean_code, positions = JETLS.get_text_and_positions(code)
            @test length(positions) == 6
            outer_ranges = Set((
                Range(; start=positions[1], var"end"=positions[2]),
                Range(; start=positions[3], var"end"=positions[4])))
            for pos in positions[1:4]
                refs = find_references(clean_code, pos)
                @test Set(r.range for r in refs) == outer_ranges
            end
            for pos in positions[5:6]
                @test isempty(find_references(clean_code, pos))
            end
        end

        # Interpolation removes the nested quote stage and refers to the generated
        # argument in the surrounding output scope.
        let code = """
            @generated function foo(│x│)
                return :( :(\$│x│) )
            end
            """
            clean_code, positions = JETLS.get_text_and_positions(code)
            @test length(positions) == 4
            expected_ranges = Set((
                Range(; start=positions[1], var"end"=positions[2]),
                Range(; start=positions[3], var"end"=positions[4])))
            for pos in positions
                refs = find_references(clean_code, pos)
                @test Set(r.range for r in refs) == expected_ranges
            end
        end

        # Nested interpolation respects locals introduced in the generated output.
        let code = """
            @generated function foo(│x│)
                return :(let │x│ = 1
                    :(\$│x│)
                end)
            end
            """
            clean_code, positions = JETLS.get_text_and_positions(code)
            @test length(positions) == 6
            outer_range = Range(; start=positions[1], var"end"=positions[2])
            local_ranges = Set((
                Range(; start=positions[3], var"end"=positions[4]),
                Range(; start=positions[5], var"end"=positions[6])))
            for pos in positions[1:2]
                refs = find_references(clean_code, pos)
                @test Set(r.range for r in refs) == Set((outer_range,))
            end
            for pos in positions[3:6]
                refs = find_references(clean_code, pos)
                @test Set(r.range for r in refs) == local_ranges
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
            clean_code, positions = JETLS.get_text_and_positions(code)
            @test length(positions) == 4
            for pos in positions
                refs = find_references(clean_code, pos)
                @test length(refs) == 2
            end
        end

        # Regression test for `is_matching_global_binding` + occurrence remap:
        # a `@generated` argument whose name coincides with a module-level
        # `global` must NOT be linked to that global. In earlier implementations
        # the inert `:(xxx)` recorded `xxx` as `:argument (mod=nothing)` and the
        # `nothing`-mod fallback in `is_matching_global_binding` matched it to
        # the same-named `:global (mod=<module>)`, producing bogus cross-links.
        let code = """
            @generated function func(│xxxx│)
                :(│xxxx│)
            end
            global │xxxx│ = 42
            """
            clean_code, positions = JETLS.get_text_and_positions(code)
            @test length(positions) == 6  # 2 markers per identifier × 3 identifiers
            # Argument and its inert `:use` are linked to each other (2 refs),
            # but the module-level `global xxxx` is an independent binding.
            refs_arg   = find_references(clean_code, positions[1])  # `func(xxxx)` arg
            refs_inert = find_references(clean_code, positions[3])  # inert `:(xxxx)`
            refs_glob  = find_references(clean_code, positions[5])  # `global xxxx = 42`
            @test length(refs_arg) == 2
            @test length(refs_inert) == 2
            @test length(refs_glob) == 1
            @test Set(r.range for r in refs_arg) == Set(r.range for r in refs_inert)
        end

    end

    # A future confidence model should exclude a generated temporary used only
    # as compile-time AST data from both references and rename. Unused-import
    # analysis may consume separate possible-use information.
    @testset "speculative generated quote references" begin
        let code = """
            │helper│() = nothing
            @generated function f(x)
                pattern = :(│helper│())
                inspect(pattern)
                return :(nothing)
            end
            """
            clean_code, positions = JETLS.get_text_and_positions(code)
            @test length(positions) == 4
            expected = (1, 1, 0, 0)
            for (pos, nrefs) in zip(positions, expected)
                @test_broken length(find_references(clean_code, pos)) == nrefs
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

        # Unescaped macro-output globals resolve in the definition module, while
        # interpolated macro arguments remain argument uses.
        let code = """
            │helper│(x) = x
            macro m(│ex│)
                return :(│helper│(\$│ex│))
            end
            """
            clean_code, positions = JETLS.get_text_and_positions(code)
            @test length(positions) == 8
            for pos in positions[[1, 2, 5, 6]]
                @test length(find_references(clean_code, pos)) == 2
            end
            for pos in positions[[3, 4, 7, 8]]
                @test length(find_references(clean_code, pos)) == 2
            end
        end

        # Hygienic locals in macro output have their own quote-local binding.
        let code = """
            macro m(ex)
                return quote
                    local │y│ = \$ex
                    │y│
                end
            end
            """
            clean_code, positions = JETLS.get_text_and_positions(code)
            @test length(positions) == 4
            for pos in positions
                @test length(find_references(clean_code, pos)) == 2
            end
        end

        # Escaped output is caller-owned, not linked to definition-module globals.
        for escape in ("esc", "Base.esc")
            code = """
                │helper│(x) = x
                macro escaped()
                    return $escape(:(│helper│(│x│)))
                end
                """
            clean_code, positions = JETLS.get_text_and_positions(code)
            @test length(positions) == 6
            for pos in positions[1:2]
                @test length(find_references(clean_code, pos)) == 1
            end
            for pos in positions[3:6]
                @test isempty(find_references(clean_code, pos))
            end
        end

        # The macro policy also applies to macro definitions nested inside
        # enclosing statements such as version-conditional `if` blocks.
        let code = """
            │helper│(x) = x
            if VERSION >= v"1.11"
                macro escaped()
                    return esc(:(│helper│(│x│)))
                end
            end
            """
            clean_code, positions = JETLS.get_text_and_positions(code)
            @test length(positions) == 6
            for pos in positions[1:2]
                @test length(find_references(clean_code, pos)) == 1
            end
            for pos in positions[3:6]
                @test isempty(find_references(clean_code, pos))
            end
        end

        # Escaped macro output does not expose nested macrocall bindings.
        for escape in ("esc", "Base.esc")
            code = """
                macro │helper│()
                    nothing
                end
                macro escaped()
                    return $escape(:(│@helper│))
                end
                """
            clean_code, positions = JETLS.get_text_and_positions(code)
            @test length(positions) == 4
            for pos in positions[1:2]
                @test length(find_references(clean_code, pos)) == 1
            end
            for pos in positions[3:4]
                @test isempty(find_references(clean_code, pos))
            end
        end

        # Interpolation inside escaped output still executes in definition scope.
        let code = """
            macro │helper│()
                :(nothing)
            end
            macro escaped()
                return esc(:(\$(│@helper│)))
            end
            """
            clean_code, positions = JETLS.get_text_and_positions(code)
            @test length(positions) == 4
            for pos in positions
                @test length(find_references(clean_code, pos)) == 2
            end
        end

        # Macro-body code-shaped quotes use definition-module globals.
        let code = """
            │helper│(x) = x
            macro m()
                temporary = :(│helper│(│x│))
                return temporary
            end
            """
            clean_code, positions = JETLS.get_text_and_positions(code)
            @test length(positions) == 6
            expected = (2, 2, 2, 2, 1, 1)
            @test all(zip(positions, expected)) do (pos, nrefs)
                length(find_references(clean_code, pos)) == nrefs
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

    # `@ccall foo(...)` treats `foo` as a C library symbol, not a reference to
    # a Julia binding. `@ccall` has a new-style JuliaLowering implementation
    # that correctly encodes this by wrapping `foo` in `K"inert"`, so scope
    # resolution must leave it alone. That only holds while
    # `_remove_macrocalls` preserves the `@ccall` macrocall (because the
    # macrocall is in `NEW_STYLE_MACROCALL_NAMES`) — if it ever falls back to
    # the generic stripping path, `foo` gets lifted into a plain `block` and
    # is misresolved to the enclosing Julia binding of the same name.
    @testset "@ccall C symbol vs enclosing Julia binding" begin
        let code = """
            let │strlen│ = length
                @ccall strlen("foo"::Cstring)::Csize_t
            end
            """
            clean_code, positions = JETLS.get_text_and_positions(code)
            @test length(positions) == 2
            # The `let` binding position finds only itself; the C symbol
            # `strlen` inside `@ccall` is not linked to the Julia local.
            refs_at_let = find_references(clean_code, positions[1])
            @test length(refs_at_let) == 1
        end
    end

    @testset "cursor on inert global inside @eval" begin
        # One-argument `@eval` resolves inert globals in the construction module.
        for eval_macro in ("@eval", "Base.@eval")
            code = """
                struct │LSAnalyzer│ end
                let x = 1
                    $eval_macro some_func(::│LSAnalyzer│) = \$x
                end
                """
            clean_code, positions = JETLS.get_text_and_positions(code)
            @test length(positions) == 4
            for pos in positions
                refs = find_references(clean_code, pos)
                @test length(refs) == 2
            end
        end

        # Quoted atomic input remains Symbol data rather than a global reference.
        for eval_macro in ("@eval", "Base.@eval")
            code = """
                global │gvar│ = nothing
                $eval_macro :│gvar│
                """
            clean_code, positions = JETLS.get_text_and_positions(code)
            @test length(positions) == 4
            for pos in positions[1:2]
                @test length(find_references(clean_code, pos)) == 1
            end
            for pos in positions[3:4]
                @test isempty(find_references(clean_code, pos))
            end
        end

        # Nested quote stages inside `@eval` remain unresolved.
        let code = """
            global │x│ = nothing
            @eval begin
                q = :(use(│x│))
            end
            """
            clean_code, positions = JETLS.get_text_and_positions(code)
            @test length(positions) == 4
            for pos in positions
                @test_broken length(find_references(clean_code, pos)) == 2
            end
        end

        # Macrocalls in the evaluated stage resolve in the construction module.
        for eval_macro in ("@eval", "Base.@eval")
            code = """
                macro │helper│()
                    nothing
                end
                $eval_macro begin
                    │@helper│
                end
                """
            clean_code, positions = JETLS.get_text_and_positions(code)
            @test length(positions) == 4
            for pos in positions
                @test length(find_references(clean_code, pos)) == 2
            end
        end

        # Nested quote stages inside `@eval` do not expose macrocall bindings.
        for eval_macro in ("@eval", "Base.@eval")
            code = """
                macro │helper│()
                    nothing
                end
                $eval_macro begin
                    q = :(│@helper│)
                end
                """
            clean_code, positions = JETLS.get_text_and_positions(code)
            @test length(positions) == 4
            for pos in positions[1:2]
                @test length(find_references(clean_code, pos)) == 1
            end
            for pos in positions[3:4]
                @test isempty(find_references(clean_code, pos))
            end
        end

        # Two-argument `@eval` is unsupported because its target module may be
        # dynamic, so its inert global is left unresolved even for `Main`.
        for eval_macro in ("@eval", "Base.@eval")
            code = """
                struct │LSAnalyzer│ end
                $eval_macro SomeModule some_func(::│LSAnalyzer│) = nothing
                """
            clean_code, positions = JETLS.get_text_and_positions(code)
            @test length(positions) == 4
            for (i, pos) in enumerate(positions)
                refs = find_references(clean_code, pos)
                @test length(refs) == (i <= 2 ? 1 : 0)
            end
        end

        # Nested macrocalls in two-argument `@eval` input are unresolved too.
        for eval_macro in ("@eval", "Base.@eval")
            code = """
                macro │helper│()
                    nothing
                end
                $eval_macro SomeModule │@helper│
                """
            clean_code, positions = JETLS.get_text_and_positions(code)
            @test length(positions) == 4
            for pos in positions[1:2]
                @test length(find_references(clean_code, pos)) == 1
            end
            for pos in positions[3:4]
                @test isempty(find_references(clean_code, pos))
            end
        end
    end
end

end # module test_references
