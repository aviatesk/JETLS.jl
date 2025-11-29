module test_lookup_analysis_entry

using Test
using Pkg
using JETLS
using JETLS: lookup_analysis_entry, ScriptInEnvAnalysisEntry, entryenvpath
using JETLS.URIs2: filepath2uri

@testset "lookup_analysis_entry for docs" begin
    mktempdir() do temp_root
        proj_dir = joinpath(temp_root, "TestPkg")
        mkpath(proj_dir)
        env_path = joinpath(proj_dir, "Project.toml")
        write(env_path, """
            name = "TestPkg"
            uuid = "12345678-1234-1234-1234-123456789012"
            version = "0.1.0"
            """)

        src_dir = joinpath(proj_dir, "src")
        docs_dir = joinpath(proj_dir, "docs")
        mkpath(src_dir)
        mkpath(docs_dir)
        mkpath(joinpath(docs_dir, "src"))

        write(joinpath(src_dir, "TestPkg.jl"), "module TestPkg end")
        write(joinpath(docs_dir, "make.jl"), "# docs make script")

        # Test docs with docs/Project.toml
        let docs_env_path = joinpath(docs_dir, "Project.toml")
            write(docs_env_path, """
                [deps]
                Documenter = "e30172f5-a6a5-5a46-863b-614d45cd2de4"
                """)

            filepath = joinpath(docs_dir, "make.jl")
            uri = filepath2uri(filepath)
            server = Server()
            server.state.root_path = proj_dir
            entry = lookup_analysis_entry(server, uri)
            @test entry isa ScriptInEnvAnalysisEntry
            @test entryenvpath(entry) == docs_env_path
        end

        # Test docs without docs/Project.toml (falls back to root Project.toml)
        let docs_env_path = joinpath(docs_dir, "Project.toml")
            rm(docs_env_path; force=true)

            filepath = joinpath(docs_dir, "make.jl")
            uri = filepath2uri(filepath)
            server = Server()
            server.state.root_path = proj_dir
            entry = lookup_analysis_entry(server, uri)
            @test entry isa ScriptInEnvAnalysisEntry
            @test entryenvpath(entry) == env_path
        end
    end
end

end # module test_lookup_analysis_entry
