module test_rename

using Test
using JETLS
using JETLS.LSP

include(normpath(pkgdir(JETLS), "test", "setup.jl"))
include(normpath(pkgdir(JETLS), "test", "jsjl-utils.jl"))

function rename_testcase(
        code::AbstractString, n::Int;
        filename::AbstractString = joinpath(@__DIR__, "testfile.jl"),
    )
    clean_code, positions = JETLS.get_text_and_positions(code)
    @test length(positions) == n
    fi = JETLS.FileInfo(#=version=#0, clean_code, filename)
    @test issorted(positions; by = x -> JETLS.xy_to_offset(fi, x))
    furi = filename2uri(filename)
    return fi, positions, furi
end

@testset "local_binding_rename_preparation" begin
    state = JETLS.ServerState()
    let code = """
        function func(│xx│x│, yyy)
            │pri│ntln│(│xx│x│, yyy)
        end
        """
        fi, positions, furi = rename_testcase(code, 9)
        for (i, pos) in enumerate(positions)
            if i in (4,5,6) # println
                rename_prep = JETLS.local_binding_rename_preparation(state, furi, fi, pos, @__MODULE__)
                @test isnothing(rename_prep)
            else
                rename_prep = JETLS.local_binding_rename_preparation(state, furi, fi, pos, @__MODULE__)
                @test !isnothing(rename_prep)
                @test rename_prep.placeholder == "xxx"
            end
        end
    end

    let code = """
        func(xxx) = println(xxx, 4│2)
        """
        fi, positions, furi = rename_testcase(code, 1)
        rename_prep = JETLS.local_binding_rename_preparation(state, furi, fi, only(positions), @__MODULE__)
        @test isnothing(rename_prep)
    end

    @testset "static parameter rename prepare" begin
        let code = """
            func(::│TTT│) where │TTT│<:Integer = zero(│TTT│)
            """
            fi, positions, furi = rename_testcase(code, 6)
            for pos in positions
                rename_prep = JETLS.local_binding_rename_preparation(state, furi, fi, pos, @__MODULE__)
                @test !isnothing(rename_prep)
                @test rename_prep.placeholder == "TTT"
            end
        end
    end

    @testset "rename prepare with docstring" begin
        let code = """
            \"\"\"Docstring\"\"\"
            function func(│xxx│, yyy)
                println(│xxx│, yyy)
            end
            """
            fi, positions, furi = rename_testcase(code, 4)
            for pos in positions
                rename_prep = JETLS.local_binding_rename_preparation(state, furi, fi, pos, @__MODULE__)
                @test !isnothing(rename_prep)
                @test rename_prep.placeholder == "xxx"
            end
        end
    end

    @testset "rename prepare with macrocall" begin
        let code = """
            func(│xxx│) = @something rand((│xxx│, nothing)) return nothing
            """
            fi, positions, furi = rename_testcase(code, 4)
            for pos in positions
                rename_prep = JETLS.local_binding_rename_preparation(state, furi, fi, pos, @__MODULE__)
                @test !isnothing(rename_prep)
                @test rename_prep.placeholder == "xxx"
            end
        end
    end
end

@testset "local_binding_rename" begin
    server = JETLS.Server()
    let code = """
        function func(│xx│x│, yyy)
            │pri│ntln│(│xx│x│, yyy)
        end
        """
        fi, positions, furi = rename_testcase(code, 9)
        for (i, pos) in enumerate(positions)
            if i in (4,5,6) # println, should never be called if client supports rename prepare
                rename = JETLS.local_binding_rename(server, furi, fi, pos, @__MODULE__, "zzz")
                @test isnothing(rename)
            else
                (; result, error) = JETLS.local_binding_rename(server, furi, fi, pos, @__MODULE__, "zzz")
                @test result isa WorkspaceEdit && isnothing(error)
                for (uri, edits) in result.changes
                    @test furi == uri
                    @test length(edits) == 2
                    @test count(edits) do edit
                        edit.newText == "zzz" &&
                        edit.range == Range(; start=positions[1], var"end"=positions[3])
                    end == 1
                    @test count(edits) do edit
                        edit.newText == "zzz" &&
                        edit.range == Range(; start=positions[7], var"end"=positions[9])
                    end == 1
                end
            end
        end
    end

    # Guard against invalid variable names
    let code = "func(xx│x, yyy) = println(xxx, yyy)"
        fi, positions, furi = rename_testcase(code, 1)
        let
            (; result, error) = JETLS.local_binding_rename(server, furi, fi, only(positions), @__MODULE__, "zzz zzz")
            @test isnothing(result) && error isa ResponseError
        end
        let
            (; result, error) = JETLS.local_binding_rename(server, furi, fi, only(positions), @__MODULE__, "42zzz")
            @test isnothing(result) && error isa ResponseError
        end
        let
            (; result, error) = JETLS.local_binding_rename(server, furi, fi, only(positions), @__MODULE__, "'zzz'")
            @test isnothing(result) && error isa ResponseError
        end
    end

    # Allow renaming on var"names"
    let code = """func(var"│xxx│") = println(var"│xxx│")"""
        fi, positions, furi = rename_testcase(code, 4)
        for pos in positions
            (; result, error) = JETLS.local_binding_rename(server, furi, fi, pos, @__MODULE__, "zzz zzz")
            @test result isa WorkspaceEdit && isnothing(error)
            for (uri, edits) in result.changes
                @test furi == uri
                @test length(edits) == 2
                @test count(edits) do edit
                    edit.newText == "zzz zzz" &&
                    edit.range == Range(; start=positions[1], var"end"=positions[2])
                end == 1
                @test count(edits) do edit
                    edit.newText == "zzz zzz" &&
                    edit.range == Range(; start=positions[3], var"end"=positions[4])
                end == 1
            end
        end
    end

    @testset "static parameter rename" begin
        let code = """
            func(::│TTT│) where │TTT│<:Integer = zero(│TTT│)
            """
            fi, positions, furi = rename_testcase(code, 6)
            for pos in positions
                (; result, error) = JETLS.local_binding_rename(server, furi, fi, pos, @__MODULE__, "SSS")
                @test result isa WorkspaceEdit && isnothing(error)
                for (uri, edits) in result.changes
                    @test furi == uri
                    @test length(edits) == 3
                    @test count(edits) do edit
                        edit.newText == "SSS" &&
                        edit.range == Range(; start=positions[1], var"end"=positions[2])
                    end == 1
                    @test count(edits) do edit
                        edit.newText == "SSS" &&
                        edit.range == Range(; start=positions[3], var"end"=positions[4])
                    end == 1
                    @test count(edits) do edit
                        edit.newText == "SSS" &&
                        edit.range == Range(; start=positions[5], var"end"=positions[6])
                    end == 1
                end
            end
        end
    end

    @testset "rename with docstring" begin
        let code = """
            \"\"\"Docstring\"\"\"
            function func(│xxx│, yyy)
                println(│xxx│, yyy)
            end
            """
            fi, positions, furi = rename_testcase(code, 4)
            for pos in positions
                (; result, error) = JETLS.local_binding_rename(server, furi, fi, pos, @__MODULE__, "zzz")
                @test result isa WorkspaceEdit && isnothing(error)
                for (uri, edits) in result.changes
                    @test furi == uri
                    @test length(edits) == 2
                    @test count(edits) do edit
                        edit.newText == "zzz" &&
                        edit.range == Range(; start=positions[1], var"end"=positions[2])
                    end == 1
                    @test count(edits) do edit
                        edit.newText == "zzz" &&
                        edit.range == Range(; start=positions[3], var"end"=positions[4])
                    end == 1
                end
            end
        end
    end

    @testset "rename with macrocall" begin
        let code = """
            func(│xxx│) = @something rand((│xxx│, nothing)) return nothing
            """
            fi, positions, furi = rename_testcase(code, 4)
            for pos in positions
                (; result, error) = JETLS.local_binding_rename(server, furi, fi, pos, @__MODULE__, "yyy")
                @test result isa WorkspaceEdit && isnothing(error)
                for (uri, edits) in result.changes
                    @test furi == uri
                    @test length(edits) == 2
                    @test count(edits) do edit
                        edit.newText == "yyy" &&
                        edit.range == Range(; start=positions[1], var"end"=positions[2])
                    end == 1
                    @test count(edits) do edit
                        edit.newText == "yyy" &&
                        edit.range == Range(; start=positions[3], var"end"=positions[4])
                    end == 1
                end
            end
        end
    end

    @testset "@generated function rename" begin
        let code = """
            @generated function foo(│x│)
                return :(copy(│x│) + │x│)
            end
            """
            fi, positions, furi = rename_testcase(code, 6)
            for pos in positions
                (; result, error) = JETLS.local_binding_rename(
                    server, furi, fi, pos, @__MODULE__, "y")
                @test result isa WorkspaceEdit && isnothing(error)
                for (uri, edits) in result.changes
                    @test furi == uri
                    @test length(edits) == 3
                    @test all(edit -> edit.newText == "y", edits)
                end
            end
        end

        # Static parameter merging
        let code = """
            @generated function foo(x::│T│) where {│T│}
                return :(zero(│T│))
            end
            """
            fi, positions, furi = rename_testcase(code, 6)
            for pos in positions
                (; result, error) = JETLS.local_binding_rename(
                    server, furi, fi, pos, @__MODULE__, "S")
                @test result isa WorkspaceEdit && isnothing(error)
                for (uri, edits) in result.changes
                    @test furi == uri
                    @test length(edits) == 3
                    @test all(edit -> edit.newText == "S", edits)
                end
            end
        end
    end
end

@testset "global_binding_rename_preparation" begin
    state = JETLS.ServerState()
    let code = """
        │foo│() = 42
        │bar│ = │foo│()
        │println│(│bar│)
        """
        fi, positions, furi = rename_testcase(code, 10)

        for pos in positions[1:2]
            rename_prep = JETLS.global_binding_rename_preparation(state, furi, fi, pos, @__MODULE__)
            @test !isnothing(rename_prep)
            @test rename_prep.placeholder == "foo"
        end

        for pos in positions[3:4]
            rename_prep = JETLS.global_binding_rename_preparation(state, furi, fi, pos, @__MODULE__)
            @test !isnothing(rename_prep)
            @test rename_prep.placeholder == "bar"
        end

        for pos in positions[5:6]
            rename_prep = JETLS.global_binding_rename_preparation(state, furi, fi, pos, @__MODULE__)
            @test !isnothing(rename_prep)
            @test rename_prep.placeholder == "foo"
        end

        for pos in positions[7:8]
            rename_prep = JETLS.global_binding_rename_preparation(state, furi, fi, pos, @__MODULE__)
            @test !isnothing(rename_prep)
            @test rename_prep.placeholder == "println"
        end

        for pos in positions[9:10]
            rename_prep = JETLS.global_binding_rename_preparation(state, furi, fi, pos, @__MODULE__)
            @test !isnothing(rename_prep)
            @test rename_prep.placeholder == "bar"
        end
    end

    # Non-binding position should be rejected
    let code = "func(xxx) = println(xxx, 4│2)"
        fi, positions, furi = rename_testcase(code, 1)
        rename_prep = JETLS.global_binding_rename_preparation(
            state, furi, fi, only(positions), @__MODULE__)
        @test isnothing(rename_prep)
    end

    @testset "macro rename prepare" begin
        # From definition site
        let code = """
            macro │mymacro│(ex)
                esc(ex)
            end
            @mymacro println("hello")
            """
            fi, positions, furi = rename_testcase(code, 2)
            # Only test start position (end position selects implicit macro arg)
            rename_prep = JETLS.global_binding_rename_preparation(
                state, furi, fi, positions[1], @__MODULE__)
            @test !isnothing(rename_prep)
            @test rename_prep.placeholder == "mymacro"
        end

        # From macrocall site
        let code = """
            macro mymacro(ex)
                esc(ex)
            end
            │@my│macro println("hello")
            """
            fi, positions, furi = rename_testcase(code, 2)
            for pos in positions
                rename_prep = JETLS.global_binding_rename_preparation(
                    state, furi, fi, pos, @__MODULE__)
                @test !isnothing(rename_prep)
                @test rename_prep.placeholder == "mymacro"
            end
        end
    end
end

@testset "global_binding_rename" begin
    server = JETLS.Server()
    let code = """
        │foo│() = 42
        baz() = │foo│()
        │foo│(x) = x + 1
        """
        fi, positions, furi = rename_testcase(code, 6)
        for pos in positions
            (; result, error) = JETLS.global_binding_rename(server, furi, fi, pos, @__MODULE__, "qux")
            @test result isa WorkspaceEdit && isnothing(error)
            for (uri, edits) in result.changes
                @test furi == uri
                @test length(edits) == 3
                @test all(edit -> edit.newText == "qux", edits)
            end
        end
    end

    @testset "macro rename" begin
        # All occurrences should be renamed to the identifier without `@`,
        # and `@` at call sites should be preserved.
        let code = """
            macro │mymacro(ex)
                esc(ex)
            end
            │@│mymacro println("hello")
            │@│mymacro println("world")
            """
            fi, positions, furi = rename_testcase(code, 5)
            # Test from definition position
            let pos = positions[1]
                (; result, error) = JETLS.global_binding_rename(
                    server, furi, fi, pos, @__MODULE__, "newmacro")
                @test result isa WorkspaceEdit && isnothing(error)
                for (uri, edits) in result.changes
                    @test furi == uri
                    @test length(edits) == 3
                    @test all(edit -> edit.newText == "newmacro", edits)
                    # Call site ranges should skip `@`
                    for edit in edits
                        if edit.range.start.line != positions[1].line
                            @test edit.range.start.character == positions[2].character + 1
                        end
                    end
                end
            end
            # Test from macrocall positions
            for pos in positions[2:5]
                (; result, error) = JETLS.global_binding_rename(
                    server, furi, fi, pos, @__MODULE__, "newmacro")
                @test result isa WorkspaceEdit && isnothing(error)
                for (uri, edits) in result.changes
                    @test length(edits) == 3
                    @test all(edit -> edit.newText == "newmacro", edits)
                end
            end
        end

        # newName with `@` prefix should also work
        let code = """
            macro │mymacro(ex)
                esc(ex)
            end
            │@│mymacro println("hello")
            """
            fi, positions, furi = rename_testcase(code, 3)
            for pos in positions
                (; result, error) = JETLS.global_binding_rename(
                    server, furi, fi, pos, @__MODULE__, "@newmacro")
                @test result isa WorkspaceEdit && isnothing(error)
                for (_, edits) in result.changes
                    @test all(edit -> edit.newText == "newmacro", edits)
                end
            end
        end
    end

    @testset "import/using rename" begin
        # Renaming from a cursor on an imported name should rewrite every
        # occurrence, including the import site itself.
        let code = """
            using Base: │foo│
            │foo│(1)
            bar() = │foo│()
            """
            fi, positions, furi = rename_testcase(code, 6)
            for pos in positions
                (; result, error) = JETLS.global_binding_rename(
                    server, furi, fi, pos, @__MODULE__, "qux")
                @test result isa WorkspaceEdit && isnothing(error)
                for (_, edits) in result.changes
                    @test length(edits) == 3
                    @test all(edit -> edit.newText == "qux", edits)
                end
            end
        end
    end

    @testset "export/public rename" begin
        # Renaming from a cursor inside `export`/`public` should rewrite every
        # occurrence, including the export statement itself.
        let code = """
            │foo│() = 42
            export │foo│
            bar() = │foo│()
            """
            fi, positions, furi = rename_testcase(code, 6)
            for pos in positions
                (; result, error) = JETLS.global_binding_rename(
                    server, furi, fi, pos, @__MODULE__, "qux")
                @test result isa WorkspaceEdit && isnothing(error)
                for (_, edits) in result.changes
                    @test length(edits) == 3
                    @test all(edit -> edit.newText == "qux", edits)
                end
            end
        end
    end
end

@testset "file_rename_preparation" begin
    state = JETLS.ServerState()
    mktempdir() do dir
        touch(joinpath(dir, "foo.jl"))
        mkdir(joinpath(dir, "subdir"))
        touch(joinpath(dir, "subdir/foo.jl"))
        touch(joinpath(dir, "README.md"))

        for target_name = ("foo.jl", "subdir/foo.jl", "README.md")
            let code = """include("│$(target_name)│")"""
                fi, positions, furi = rename_testcase(code, 2;
                    filename = joinpath(dir, "main.jl"))
                for pos in positions
                    rename_prep = JETLS.file_rename_preparation(state, furi, fi, pos)
                    @test !isnothing(rename_prep)
                    @test rename_prep.placeholder == target_name
                end
            end
        end

        let code = """include("│nonexistent.jl│")"""
            fi, positions, furi = rename_testcase(code, 2;
                filename = joinpath(dir, "main.jl"))
            rename_prep = JETLS.file_rename_preparation(state, furi, fi, positions[1])
            @test isnothing(rename_prep)
        end
    end
end

@testset "file_rename" begin
    server = JETLS.Server()
    mktempdir() do dir
        touch(joinpath(dir, "foo.jl"))
        let code = """include("│foo.jl│")"""
            fi, positions, furi = rename_testcase(code, 2;
                filename = joinpath(dir, "main.jl"))
            for pos in positions
                (; result, error) = JETLS.file_rename(server, furi, fi, pos, "bar.jl")
                @test result isa WorkspaceEdit && isnothing(error)
                @test length(result.changes) == 1
                edits = result.changes[furi]
                @test length(edits) == 1
                @test edits[1].newText == "bar.jl"
            end
        end
    end
end

end # test_rename
