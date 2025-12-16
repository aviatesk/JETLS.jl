module test_rename

using Test
using JETLS
using JETLS.LSP

include(normpath(pkgdir(JETLS), "test", "setup.jl"))
include(normpath(pkgdir(JETLS), "test", "jsjl-utils.jl"))

@testset "local_binding_rename_preparation" begin
    state = JETLS.ServerState()
    let code = """
        function func(│xx│x│, yyy)
            │pri│ntln│(│xx│x│, yyy)
        end
        """
        filename = joinpath(@__DIR__, "testfile.jl")
        clean_code, positions = JETLS.get_text_and_positions(code)
        @test length(positions) == 9
        fi = JETLS.FileInfo(#=version=#0, clean_code, filename)
        furi = filename2uri(filename)
        @test issorted(positions; by = x -> JETLS.xy_to_offset(fi, x))
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
        filename = joinpath(@__DIR__, "testfile.jl")
        clean_code, positions = JETLS.get_text_and_positions(code)
        @test length(positions) == 1
        fi = JETLS.FileInfo(#=version=#0, clean_code, filename)
        furi = filename2uri(filename)
        rename_prep = JETLS.local_binding_rename_preparation(state, furi, fi, only(positions), @__MODULE__)
        @test isnothing(rename_prep)
    end

    @testset "static parameter rename prepare" begin
        let code = """
            func(::│TTT│) where │TTT│<:Integer = zero(│TTT│)
            """
            filename = joinpath(@__DIR__, "testfile.jl")
            clean_code, positions = JETLS.get_text_and_positions(code)
            @test length(positions) == 6
            fi = JETLS.FileInfo(#=version=#0, clean_code, filename)
            furi = filename2uri(filename)
            @test issorted(positions; by = x -> JETLS.xy_to_offset(fi, x))
            for pos in positions
                rename_prep = JETLS.local_binding_rename_preparation(state, furi, fi, pos, @__MODULE__)
                @test !isnothing(rename_prep)
                @test rename_prep.placeholder == "TTT"
            end
        end
    end

    @testset "rename prepare with macrocall" begin
        let code = """
            func(│xxx│) = @something rand((│xxx│, nothing)) return nothing
            """
            filename = joinpath(@__DIR__, "testfile.jl")
            clean_code, positions = JETLS.get_text_and_positions(code)
            @test length(positions) == 4
            fi = JETLS.FileInfo(#=version=#0, clean_code, filename)
            furi = filename2uri(filename)
            @test issorted(positions; by = x -> JETLS.xy_to_offset(fi, x))
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
        filename = joinpath(@__DIR__, "testfile.jl")
        clean_code, positions = JETLS.get_text_and_positions(code)
        @test length(positions) == 9
        fi = JETLS.FileInfo(#=version=#0, clean_code, filename)
        @test issorted(positions; by = x -> JETLS.xy_to_offset(fi, x))
        furi = filename2uri("Untitled" * filename)
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
        filename = joinpath(@__DIR__, "testfile.jl")
        clean_code, positions = JETLS.get_text_and_positions(code)
        @test length(positions) == 1
        fi = JETLS.FileInfo(#=version=#0, clean_code, filename)
        furi = filename2uri("Untitled" * filename)
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
        filename = joinpath(@__DIR__, "testfile.jl")
        clean_code, positions = JETLS.get_text_and_positions(code)
        @test length(positions) == 4
        fi = JETLS.FileInfo(#=version=#0, clean_code, filename)
        @test issorted(positions; by = x -> JETLS.xy_to_offset(fi, x))
        furi = filename2uri("Untitled" * filename)
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
            filename = joinpath(@__DIR__, "testfile.jl")
            clean_code, positions = JETLS.get_text_and_positions(code)
            @test length(positions) == 6
            fi = JETLS.FileInfo(#=version=#0, clean_code, filename)
            @test issorted(positions; by = x -> JETLS.xy_to_offset(fi, x))
            furi = filename2uri("Untitled" * filename)
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

    @testset "rename with macrocall" begin
        let code = """
            func(│xxx│) = @something rand((│xxx│, nothing)) return nothing
            """
            filename = joinpath(@__DIR__, "testfile.jl")
            clean_code, positions = JETLS.get_text_and_positions(code)
            @test length(positions) == 4
            fi = JETLS.FileInfo(#=version=#0, clean_code, filename)
            @test issorted(positions; by = x -> JETLS.xy_to_offset(fi, x))
            furi = filename2uri("Untitled" * filename)
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
end

@testset "global_binding_rename_preparation" begin
    state = JETLS.ServerState()
    let code = """
        │foo│() = 42
        │bar│ = │foo│()
        │println│(│bar│)
        """
        filename = joinpath(@__DIR__, "testfile.jl")
        clean_code, positions = JETLS.get_text_and_positions(code)
        @test length(positions) == 10
        fi = JETLS.FileInfo(#=version=#0, clean_code, filename)
        furi = filename2uri(filename)
        @test issorted(positions; by = x -> JETLS.xy_to_offset(fi, x))

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
        filename = joinpath(@__DIR__, "testfile.jl")
        clean_code, positions = JETLS.get_text_and_positions(code)
        @test length(positions) == 1
        fi = JETLS.FileInfo(#=version=#0, clean_code, filename)
        furi = filename2uri(filename)
        rename_prep = JETLS.global_binding_rename_preparation(
            state, furi, fi, only(positions), @__MODULE__)
        @test isnothing(rename_prep)
    end
end

@testset "global_binding_rename" begin
    server = JETLS.Server()
    let code = """
        │foo│() = 42
        baz() = │foo│()
        │foo│(x) = x + 1
        """
        filename = joinpath(@__DIR__, "testfile.jl")
        clean_code, positions = JETLS.get_text_and_positions(code)
        @test length(positions) == 6
        fi = JETLS.FileInfo(#=version=#0, clean_code, filename)
        @test issorted(positions; by = x -> JETLS.xy_to_offset(fi, x))
        furi = filename2uri("Untitled" * filename)
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
end

end # test_rename
