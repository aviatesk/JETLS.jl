module test_path

using Test
using JETLSCore: JETLSCore

@testset "to_full_path" begin
    mktempdir() do temp_dir
        test_file = joinpath(temp_dir, "test_file.jl")
        touch(test_file)
        @test isabspath(test_file)
        result = JETLSCore.to_full_path(test_file)
        @test isabspath(result)
        @test JETLSCore.paths_equal(result, test_file)
    end

    # Test with Base function paths
    @testset "built-in function paths" begin
        m = only(methods(sin,(Float64,)))

        let filepath = JETLSCore.to_full_path(m.file)
            @test isabspath(filepath)
            @test normpath(filepath) == filepath
            @test isfile(filepath)
            @test occursin("trig.jl", filepath)
            # Check that fix_build_path is applied correctly
            @test !occursin("/usr/share/julia/", filepath)
        end
        let filepath = JETLSCore.to_full_path(m.file)
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
        @test JETLSCore.paths_equal(JETLSCore.find_env_path(test_file)::String, proj_file)
        @test JETLSCore.paths_equal(JETLSCore.find_env_path(joinpath(src_dir, "file.jl"))::String, proj_file)
        @test JETLSCore.paths_equal(JETLSCore.find_env_path(joinpath(proj_dir, "file.jl"))::String, proj_file)

        # Test when no Project.toml exists above
        no_proj_dir = joinpath(temp_root, "no_project", "deep", "path")
        mkpath(no_proj_dir)
        @test isnothing(JETLSCore.find_env_path(joinpath(no_proj_dir, "file.jl")))
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
        uri = JETLSCore.filepath2uri(source_file)

        let state = JETLSCore.ServerState()
            @test JETLSCore.find_analysis_env_path(state, uri) === nothing
        end

        let state = JETLSCore.ServerState()
            state.root_path = project_dir
            result = JETLSCore.find_analysis_env_path(state, uri)::String
            @test JETLSCore.paths_equal(result, project_file)
        end

        for module_name in (nothing, "")
            state = JETLSCore.ServerState()
            state.root_path = project_dir
            state.init_options = JETLSCore.InitOptions(; analysis_overrides=[
                JETLSCore.AnalysisOverride(;
                    path=JETLSCore.Glob.FilenameMatch("src/**/*.jl", "dp"),
                    full_analysis=false, module_name)
            ])
            result = JETLSCore.find_analysis_env_path(state, uri)::JETLSCore.OutOfScope
            @test result.module_context === JETLSCore.FallbackAnalysisContext
            @test result.skip_reason == JETLSCore.AnalysisExclusion(uri, "src/**/*.jl")
            @test !JETLSCore.has_analyzed_context(state, uri;
                lookup_func=JETLSCore.gen_lookup_out_of_scope!(state, uri))
            cached = JETLSCore.get_analysis_info(state.analysis_manager, uri)::JETLSCore.OutOfScope
            @test cached.module_context === JETLSCore.FallbackAnalysisContext
            @test !JETLSCore.has_analyzed_context(state, uri)
            @test JETLSCore.collect_search_uris(uri, cached) == Set((uri,))
        end

        let state = JETLSCore.ServerState()
            state.root_path = project_dir
            state.init_options = JETLSCore.InitOptions(; analysis_overrides=[
                JETLSCore.AnalysisOverride(;
                    path=JETLSCore.Glob.FilenameMatch("src/**/*.jl", "dp"),
                    full_analysis=false, module_name="Test")
            ])
            result = JETLSCore.find_analysis_env_path(state, uri)::JETLSCore.OutOfScope
            @test result.module_context === Test
            @test result.skip_reason == JETLSCore.AnalysisExclusion(uri, "src/**/*.jl")
            @test JETLSCore.has_analyzed_context(state, uri;
                lookup_func=JETLSCore.gen_lookup_out_of_scope!(state, uri))
            @test JETLSCore.has_analyzed_context(state, uri)
        end

        let state = JETLSCore.ServerState()
            state.root_path = project_dir
            state.init_options = JETLSCore.InitOptions(; analysis_overrides=[
                JETLSCore.AnalysisOverride(;
                    path=JETLSCore.Glob.FilenameMatch("test/**/*.jl", "dp"),
                    full_analysis=false)
            ])
            result = JETLSCore.find_analysis_env_path(state, uri)::String
            @test JETLSCore.paths_equal(result, project_file)
        end

        let state = JETLSCore.ServerState()
            state.root_path = workspace_dir
            result = JETLSCore.lookup_out_of_scope!(state, uri)::JETLSCore.OutOfScope
            @test result.module_context === nothing
            @test !JETLSCore.has_analyzed_context(state, uri)
        end

        let state = JETLSCore.ServerState(; cli_mode=true)
            state.root_path = workspace_dir
            result = JETLSCore.find_analysis_env_path(state, uri)::String
            @test JETLSCore.paths_equal(result, project_file)
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
        @test JETLSCore.paths_equal(JETLSCore.search_up_file(dir2, "middle.txt")::String, joinpath(dir1, "middle.txt"))
        @test JETLSCore.paths_equal(JETLSCore.search_up_file(dir2, "root.txt")::String, joinpath(temp_root, "root.txt"))
        @test isnothing(JETLSCore.search_up_file(dir2, "nonexistent.txt"))

        # Test with file in the same directory
        touch(joinpath(dir2, "same.txt"))
        @test JETLSCore.paths_equal(JETLSCore.search_up_file(joinpath(dir2, "dummy.jl"), "same.txt")::String, joinpath(dir2, "same.txt"))
    end
end

@testset "safe_ispath and safe_isfile" begin
    mktempdir() do dir
        file = joinpath(dir, "file.jl")
        touch(file)
        @test JETLSCore.safe_ispath(dir)
        @test !JETLSCore.safe_isfile(dir)
        @test JETLSCore.safe_ispath(file)
        @test JETLSCore.safe_isfile(file)
        for path in (joinpath(dir, "missing.jl"), joinpath(dir, "a"^300), joinpath(dir, "a\0b"))
            @test !JETLSCore.safe_ispath(path)
            @test !JETLSCore.safe_isfile(path)
        end
    end
end

@testset "paths_equal" begin
    @test JETLSCore.paths_equal("project", "project")
    @test JETLSCore.paths_equal("project", joinpath("project", "src", ".."))
    @test !JETLSCore.paths_equal("project", "project-other")
    @test !JETLSCore.paths_equal(abspath("project"), "project")
    @static if Sys.iswindows()
        @test JETLSCore.paths_equal("C:\\Users\\Foo", "c:/users/foo/")
    else
        @test !JETLSCore.paths_equal("/home/user/Project", "/home/user/project")
    end
end

@testset "issubdir" begin
    let parent = "project",
        child = joinpath(parent, "src", "file.jl")
        @test JETLSCore.issubdir(child, parent)
    end

    if Sys.isunix()
        # Test with absolute paths
        @test JETLSCore.issubdir("/home/user/project/src", "/home/user/project")
        @test JETLSCore.issubdir("/home/user/project", "/home/user")
        @test !JETLSCore.issubdir("/home/user", "/home/user/project")
        @test !JETLSCore.issubdir("/home/other", "/home/user")

        # Test with same directory
        @test JETLSCore.issubdir("/home/user", "/home/user")

        # Test with trailing slashes
        @test JETLSCore.issubdir("/home/user/project/", "/home/user/")
    end

    @static if Sys.iswindows()
        # Drive-letter casing must not affect the comparison: URI round-trip
        # lowercases the drive letter while `pwd()` preserves the original case.
        @test JETLSCore.issubdir("c:\\Users\\foo\\bar", "C:\\Users\\foo")
        @test JETLSCore.issubdir("C:\\Users\\foo\\bar", "c:\\Users\\foo")
        @test JETLSCore.issubdir("C:\\Users\\Foo", "c:\\users\\foo")
        @test !JETLSCore.issubdir("C:\\Users\\other", "c:\\Users\\foo")
        @test !JETLSCore.issubdir(
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

        @test JETLSCore.issubdir(child, parent)
        @test JETLSCore.issubdir(child, temp_root)
        @test JETLSCore.issubdir(nested, parent)
        @test !JETLSCore.issubdir(parent, child)
        @test !JETLSCore.issubdir(sibling, parent)
        @test !JETLSCore.issubdir(prefix_sibling, parent)
        @test !JETLSCore.issubdir(nested, relpath(parent))
        @test !JETLSCore.issubdir(relpath(nested), parent)
    end
end

@testset "glob_candidate_path" begin
    mktempdir() do temp_root
        root = joinpath(temp_root, "project")
        nested = joinpath(root, "src", "subdir", "file.jl")
        outside = joinpath(temp_root, "project-other", "src", "file.jl")
        @test JETLSCore.glob_candidate_path(nested, root) == "src/subdir/file.jl"
        @test JETLSCore.glob_candidate_path(outside, root) == replace(normpath(outside), '\\' => '/')
        @test JETLSCore.glob_candidate_path(nested, nothing) == replace(normpath(nested), '\\' => '/')
    end
    @static if Sys.iswindows()
        @test JETLSCore.glob_candidate_path(
            "C:\\Users\\Foo\\Project\\src\\file.jl",
            "c:/users/foo/project") == "src/file.jl"
    end
end

@testset "glob path utilities" begin
    let path = "examples/[case]?*.jl"
        escaped = JETLSCore.escape_path_for_glob(path)
        @test escaped == "examples/\\[case\\]\\?\\*.jl"
        matcher = JETLSCore.Glob.FilenameMatch(escaped, "dp")
        @test occursin(matcher, path)
        @test !occursin(matcher, "examples/case1.jl")
    end
    let path = "src/config.jl"
        @test JETLSCore.escape_path_for_glob(path) == path
    end
end

end # test_path
