module test_rename

using Test
using JETLS
using JETLS.LSP

include(normpath(pkgdir(JETLS), "test", "setup.jl"))
include(normpath(pkgdir(JETLS), "test", "jsjl_utils.jl"))

@testset "local_binding_rename_preparation" begin
    let code = """
        function func(│xx│x│, yyy)
            │pri│ntln│(│xx│x│, yyy)
        end
        """
        clean_code, positions = JETLS.get_text_and_positions(code)
        @test length(positions) == 9
        fi = JETLS.FileInfo(#=version=#0, parsedstream(clean_code))
        @test issorted(positions; by = x -> JETLS.xy_to_offset(fi, x))
        for (i, pos) in enumerate(positions)
            if i in (4,5,6) # println
                rename_prep = JETLS.local_binding_rename_preparation(fi, pos, @__MODULE__)
                @test isnothing(rename_prep)
            else
                rename_prep = JETLS.local_binding_rename_preparation(fi, pos, @__MODULE__)
                @test !isnothing(rename_prep)
                @test rename_prep.placeholder == "xxx"
            end
        end
    end

    let code = """
        func(xxx) = println(xxx, 4│2)
        """
        clean_code, positions = JETLS.get_text_and_positions(code)
        @test length(positions) == 1
        fi = JETLS.FileInfo(#=version=#0, parsedstream(clean_code))
        rename_prep = JETLS.local_binding_rename_preparation(fi, only(positions), @__MODULE__)
        @test isnothing(rename_prep)
    end
end

@testset "local_binding_rename" begin
    let code = """
        function func(│xx│x│, yyy)
            │pri│ntln│(│xx│x│, yyy)
        end
        """
        clean_code, positions = JETLS.get_text_and_positions(code)
        @test length(positions) == 9
        fi = JETLS.FileInfo(#=version=#0, parsedstream(clean_code))
        @test issorted(positions; by = x -> JETLS.xy_to_offset(fi, x))
        furi = filename2uri("Untitled" * @__FILE__)
        for (i, pos) in enumerate(positions)
            if i in (4,5,6) # println, should never be called if client supports rename prepare
                rename = JETLS.local_binding_rename(furi, fi, pos, @__MODULE__, "zzz")
                @test isnothing(rename)
            else
                (; result, error) = JETLS.local_binding_rename(furi, fi, pos, @__MODULE__, "zzz")
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
        clean_code, positions = JETLS.get_text_and_positions(code)
        @test length(positions) == 1
        fi = JETLS.FileInfo(#=version=#0, parsedstream(clean_code))
        furi = filename2uri("Untitled" * @__FILE__)
        let
            (; result, error) = JETLS.local_binding_rename(furi, fi, only(positions), @__MODULE__, "zzz zzz")
            @test isnothing(result) && error isa ResponseError
        end
        let
            (; result, error) = JETLS.local_binding_rename(furi, fi, only(positions), @__MODULE__, "42zzz")
            @test isnothing(result) && error isa ResponseError
        end
        let
            (; result, error) = JETLS.local_binding_rename(furi, fi, only(positions), @__MODULE__, "'zzz'")
            @test isnothing(result) && error isa ResponseError
        end
    end

    # Allow renaming on var"names"
    let code = """func(var"│xxx│") = println(var"│xxx│")"""
        clean_code, positions = JETLS.get_text_and_positions(code)
        @test length(positions) == 4
        fi = JETLS.FileInfo(#=version=#0, parsedstream(clean_code))
        @test issorted(positions; by = x -> JETLS.xy_to_offset(fi, x))
        furi = filename2uri("Untitled" * @__FILE__)
        for pos in positions
            (; result, error) = JETLS.local_binding_rename(furi, fi, pos, @__MODULE__, "zzz zzz")
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
end

end # test_rename
