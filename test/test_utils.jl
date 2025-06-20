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
    mktempdir() do temp_dir
        test_file = joinpath(temp_dir, "test_file.jl")
        touch(test_file)
        @test isabspath(test_file)
        result = JETLS.to_full_path(test_file)
        @test isabspath(result)
        @test result == test_file
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

@testset "find_env_path" begin
    # Create a temporary directory structure with Project.toml
    mktempdir() do temp_root
        # Create nested directories with Project.toml at different levels
        proj_dir = joinpath(temp_root, "myproject")
        src_dir = joinpath(proj_dir, "src")
        sub_dir = joinpath(src_dir, "submodule")

        mkpath(sub_dir)
        proj_file = joinpath(proj_dir, "Project.toml")
        touch(proj_file)

        # Test finding Project.toml from various depths
        # find_env_path expects a file path, uses dirname to get the directory
        test_file = joinpath(sub_dir, "test.jl")
        @test JETLS.find_env_path(test_file) == proj_file
        @test JETLS.find_env_path(joinpath(src_dir, "file.jl")) == proj_file
        @test JETLS.find_env_path(joinpath(proj_dir, "file.jl")) == proj_file

        # Test when no Project.toml exists above
        no_proj_dir = joinpath(temp_root, "no_project", "deep", "path")
        mkpath(no_proj_dir)
        @test JETLS.find_env_path(joinpath(no_proj_dir, "file.jl")) === nothing
    end
end

@testset "search_up_file" begin
    mktempdir() do temp_root
        # Create test structure
        dir1 = joinpath(temp_root, "level1")
        dir2 = joinpath(dir1, "level2")
        mkpath(dir2)

        # Create test files at different levels
        touch(joinpath(temp_root, "root.txt"))
        touch(joinpath(dir1, "middle.txt"))

        # Search for files going up the tree
        @test JETLS.search_up_file(dir2, "middle.txt") == joinpath(dir1, "middle.txt")
        @test JETLS.search_up_file(dir2, "root.txt") == joinpath(temp_root, "root.txt")
        @test JETLS.search_up_file(dir2, "nonexistent.txt") === nothing

        # Test with file in the same directory
        touch(joinpath(dir2, "same.txt"))
        @test JETLS.search_up_file(joinpath(dir2, "dummy.jl"), "same.txt") == joinpath(dir2, "same.txt")
    end
end

@testset "issubdir" begin
    if Sys.isunix()
        # Test with absolute paths
        @test JETLS.issubdir("/home/user/project/src", "/home/user/project")
        @test JETLS.issubdir("/home/user/project", "/home/user")
        @test !JETLS.issubdir("/home/user", "/home/user/project")
        @test !JETLS.issubdir("/home/other", "/home/user")

        # Test with same directory
        @test JETLS.issubdir("/home/user", "/home/user")

        # Test with trailing slashes
        @test JETLS.issubdir("/home/user/project/", "/home/user/")
    end

    # Test with relative paths using temporary directories
    mktempdir() do temp_root
        parent = joinpath(temp_root, "parent")
        child = joinpath(parent, "child")
        sibling = joinpath(temp_root, "sibling")

        mkpath(child)
        mkpath(sibling)

        @test JETLS.issubdir(child, parent)
        @test JETLS.issubdir(child, temp_root)
        @test !JETLS.issubdir(parent, child)
        @test !JETLS.issubdir(sibling, parent)
    end
end

@testset "create_source_location_link" begin
    @test JETLS.create_source_location_link("/path/to/file.jl") == "[/path/to/file.jl](file:///path/to/file.jl)"
    @test JETLS.create_source_location_link("/path/to/file.jl", line=42) == "[/path/to/file.jl:42](file:///path/to/file.jl#L42)"
    @test JETLS.create_source_location_link("/path/to/file.jl", line=42, character=10) == "[/path/to/file.jl:42](file:///path/to/file.jl#L42C10)"
end

end # module test_utils
