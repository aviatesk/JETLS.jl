module test_utils

using Test
using JETLS

function test_string_positions(s)
    v = Vector{UInt8}(s)
    for b in eachindex(s)
        pos = JETLS.offset_to_xy(v, b)
        b2 =  JETLS.xy_to_offset(v, pos)
        @test b === b2
    end
    # One past the last byte is a valid position in an editor
    b = length(v) + 1
    pos = JETLS.offset_to_xy(v, b)
    b2 =  JETLS.xy_to_offset(v, pos)
    @test b === b2
end

@testset "Cursor file position <-> byte" begin
    fake_files = [
        "",
        "1",
        "\n\n\n",
        """
        aaa
        b
        ccc
        Αα,Ββ,Γγ,Δδ,Εε,Ζζ,Ηη,Θθ,Ιι,Κκ,Λλ,Μμ,Νν,Ξξ,Οο,Ππ,Ρρ,Σσς,Ττ,Υυ,Φφ,Χχ,Ψψ,Ωω
        """
    ]
    for i in eachindex(fake_files)
        @testset "fake_files[$i]" begin
            test_string_positions(fake_files[i])
        end
    end
end

@testset "Guard against invalid positions" begin
    let code = """
        sin
        @nospecialize
        cos(
        """ |> Vector{UInt8}
        ok = true
        for i = 0:10, j = 0:10
            ok &= JETLS.xy_to_offset(code, JETLS.Position(i, j)) isa Int
        end
        @test ok
    end
end

@testset "to_full_path" begin
    let temp_dir = mktempdir()
        test_file = joinpath(temp_dir, "test_file.jl")
        touch(test_file)
        try
            @test isabspath(test_file)
            result = JETLS.to_full_path(test_file)
            @test isabspath(result)
            @test result == test_file
        finally
            rm(temp_dir, recursive=true, force=true)
        end
    end

    # Test with Base function paths
    @testset "built-in function paths" begin
        m = only(methods(sin,(Float64,)))

        let file = m.file
            filepath = JETLS.to_full_path(m.file)
            @test isabspath(filepath)
            @test normpath(filepath) == filepath
            @test isfile(filepath)
            @test occursin("trig.jl", filepath)
            # Check that fix_build_path is applied correctly
            @test !occursin("/usr/share/julia/", filepath)
        end
        let (file, line) = Base.updated_methodloc(m)
            filepath = JETLS.to_full_path(m.file)
            @test isabspath(filepath)
            @test normpath(filepath) == filepath
            @test isfile(filepath)
            @test occursin("trig.jl", filepath)
            # Check that fix_build_path is applied correctly
            @test !occursin("/usr/share/julia/", filepath)
        end
    end
end

@testset "create_source_location_link" begin
    @test JETLS.create_source_location_link("/path/to/file.jl") == "[/path/to/file.jl](file:///path/to/file.jl)"
    @test JETLS.create_source_location_link("/path/to/file.jl", line=42) == "[/path/to/file.jl:42](file:///path/to/file.jl#L42)"
    @test JETLS.create_source_location_link("/path/to/file.jl", line=42, character=10) == "[/path/to/file.jl:42](file:///path/to/file.jl#L42C10)"
end

end # module test_utils
