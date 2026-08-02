module test_path

using Test
using JETLS: JETLS

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
        @test isnothing(JETLS.find_env_path(joinpath(no_proj_dir, "file.jl")))
    end
end

@testset "find_analysis_env_path" begin
    mktempdir() do temp_root
        project_dir = joinpath(temp_root, "project")
        source_file = joinpath(project_dir, "src", "main.jl")
        project_file = joinpath(project_dir, "Project.toml")
        workspace_dir = joinpath(temp_root, "workspace")
        mkpath(dirname(source_file))
        mkpath(workspace_dir)
        touch(source_file)
        touch(project_file)
        uri = JETLS.filepath2uri(source_file)
        normalized_project_file =
            JETLS.uri2filepath(JETLS.filepath2uri(project_file))::String

        let state = JETLS.ServerState()
            @test JETLS.find_analysis_env_path(state, uri) === nothing
        end

        let state = JETLS.ServerState()
            state.root_path = project_dir
            @test JETLS.find_analysis_env_path(state, uri) == normalized_project_file
        end

        let state = JETLS.ServerState()
            state.root_path = project_dir
            state.init_options = JETLS.InitOptions(; analysis_overrides=[
                JETLS.AnalysisOverride(;
                    path=JETLS.Glob.FilenameMatch("src/**/*.jl", "dp"))
            ])
            @test JETLS.find_analysis_env_path(state, uri) isa JETLS.OutOfScope
        end

        let state = JETLS.ServerState()
            state.root_path = workspace_dir
            @test JETLS.find_analysis_env_path(state, uri) isa JETLS.OutOfScope
        end

        let state = JETLS.ServerState(; cli_mode=true)
            state.root_path = workspace_dir
            @test JETLS.find_analysis_env_path(state, uri) == normalized_project_file
        end
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
        @test isnothing(JETLS.search_up_file(dir2, "nonexistent.txt"))

        # Test with file in the same directory
        touch(joinpath(dir2, "same.txt"))
        @test JETLS.search_up_file(joinpath(dir2, "dummy.jl"), "same.txt") == joinpath(dir2, "same.txt")
    end
end

@testset "issubdir" begin
    let parent = "project",
        child = joinpath(parent, "src", "file.jl")
        @test JETLS.issubdir(child, parent)
    end

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

    @static if Sys.iswindows()
        # Drive-letter casing must not affect the comparison: URI round-trip
        # lowercases the drive letter while `pwd()` preserves the original case.
        @test JETLS.issubdir("c:\\Users\\foo\\bar", "C:\\Users\\foo")
        @test JETLS.issubdir("C:\\Users\\foo\\bar", "c:\\Users\\foo")
        @test JETLS.issubdir("C:\\Users\\Foo", "c:\\users\\foo")
        @test !JETLS.issubdir("C:\\Users\\other", "c:\\Users\\foo")
        @test !JETLS.issubdir(
            "D:\\Users\\Foo\\Project\\file.jl", "c:/users/foo/project")
    end

    # Test with relative paths using temporary directories
    mktempdir() do temp_root
        parent = joinpath(temp_root, "parent")
        child = joinpath(parent, "child")
        nested = joinpath(parent, "src", "subdir", "..", "file.jl")
        sibling = joinpath(temp_root, "sibling")
        prefix_sibling = joinpath(temp_root, "parent-other", "file.jl")

        mkpath(child)
        mkpath(sibling)

        @test JETLS.issubdir(child, parent)
        @test JETLS.issubdir(child, temp_root)
        @test JETLS.issubdir(nested, parent)
        @test !JETLS.issubdir(parent, child)
        @test !JETLS.issubdir(sibling, parent)
        @test !JETLS.issubdir(prefix_sibling, parent)
        @test !JETLS.issubdir(nested, relpath(parent))
        @test !JETLS.issubdir(relpath(nested), parent)
    end
end

@testset "glob_candidate_path" begin
    mktempdir() do temp_root
        root = joinpath(temp_root, "project")
        nested = joinpath(root, "src", "subdir", "file.jl")
        outside = joinpath(temp_root, "project-other", "src", "file.jl")
        @test JETLS.glob_candidate_path(nested, root) == "src/subdir/file.jl"
        @test JETLS.glob_candidate_path(outside, root) == replace(normpath(outside), '\\' => '/')
        @test JETLS.glob_candidate_path(nested, nothing) == replace(normpath(nested), '\\' => '/')
    end
    @static if Sys.iswindows()
        @test JETLS.glob_candidate_path(
            "C:\\Users\\Foo\\Project\\src\\file.jl",
            "c:/users/foo/project") == "src/file.jl"
    end
end

end # test_path
