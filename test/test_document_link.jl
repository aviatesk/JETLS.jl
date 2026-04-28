module test_document_link

using Test
using JETLS
using JETLS.LSP
using JETLS.URIs2

function get_document_links(code::AbstractString, filename::AbstractString)
    server = JETLS.Server()
    uri = filename2uri(filename)
    fi = JETLS.FileInfo(#=version=#0, code, filename)
    JETLS.store!(server.state.file_cache) do cache
        Base.PersistentDict(cache, uri => fi), nothing
    end
    links = DocumentLink[]
    JETLS.collect_include_document_links!(links, server.state, uri, fi)
    return links, uri
end

@testset "include() document links" begin
    @testset "single existing include" begin
        mktempdir() do dir
            touch(joinpath(dir, "foo.jl"))
            main = joinpath(dir, "main.jl")
            links, _ = get_document_links("""include("foo.jl")""", main)
            @test length(links) == 1
            link = links[1]
            @test link.target == filename2uri(joinpath(dir, "foo.jl"))
            # range should cover just the string content `foo.jl`,
            # not the surrounding quotes
            @test link.range.start.line == 0
            @test link.range.start.character == 9   # after `include("`
            @test link.range.var"end".line == 0
            @test link.range.var"end".character == 15 # before closing `"`
        end
    end

    @testset "subdirectory path" begin
        mktempdir() do dir
            mkdir(joinpath(dir, "sub"))
            touch(joinpath(dir, "sub", "bar.jl"))
            main = joinpath(dir, "main.jl")
            links, _ = get_document_links("""include("sub/bar.jl")""", main)
            @test length(links) == 1
            @test links[1].target == filename2uri(joinpath(dir, "sub", "bar.jl"))
        end
    end

    @testset "non-existent file is skipped" begin
        mktempdir() do dir
            main = joinpath(dir, "main.jl")
            links, _ = get_document_links("""include("missing.jl")""", main)
            @test isempty(links)
        end
    end

    @testset "interpolated path is skipped" begin
        mktempdir() do dir
            touch(joinpath(dir, "foo.jl"))
            main = joinpath(dir, "main.jl")
            links, _ = get_document_links(
                """x = "foo"; include("\$x.jl")""", main)
            @test isempty(links)
        end
    end

    @testset "include_dependency" begin
        mktempdir() do dir
            touch(joinpath(dir, "data.txt"))
            main = joinpath(dir, "main.jl")
            links, _ = get_document_links(
                """include_dependency("data.txt")""", main)
            @test length(links) == 1
            @test links[1].target == filename2uri(joinpath(dir, "data.txt"))
        end
    end
end

end # test_document_link
