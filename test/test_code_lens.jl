module test_code_lens

using Test
using JETLS
using JETLS.LSP
using JETLS.URIs2

function get_code_lenses_with_counts(code::AbstractString)
    server = JETLS.Server()
    uri = URI("file:///test.jl")
    fi = JETLS.FileInfo(#=version=#0, code, "test.jl")
    JETLS.store!(server.state.file_cache) do cache
        Base.PersistentDict(cache, uri => fi), nothing
    end
    code_lenses = CodeLens[]
    JETLS.references_code_lenses!(code_lenses, server.state, uri, fi)
    results = Tuple{CodeLens,Int}[]
    for lens in code_lenses
        data = lens.data::ReferencesCodeLensData
        pos = Position(; line = data.line, character = data.character)
        locations = JETLS.find_references(server, uri, fi, pos;
            include_declaration = false)
        count = locations isa Vector ? length(locations) : 0
        push!(results, (lens, count))
    end
    return results
end

@testset "references code lens" begin
    @testset "function with references" begin
        let code = """
            function myfunc(x)
                x + 1
            end
            result = myfunc(42)
            """
            results = get_code_lenses_with_counts(code)
            @test length(results) == 1
            lens, count = results[1]
            @test lens.data isa ReferencesCodeLensData
            @test count ≥ 1
        end
    end

    @testset "function with multiple references" begin
        let code = """
            function foo(x)
                x + 1
            end
            a = foo(1)
            b = foo(2)
            c = foo(3)
            """
            results = get_code_lenses_with_counts(code)
            @test length(results) == 1
            _, count = results[1]
            @test count ≥ 3
        end
    end

    @testset "struct with references" begin
        let code = """
            struct MyStruct
                x::Int
            end
            obj = MyStruct(1)
            """
            results = get_code_lenses_with_counts(code)
            @test length(results) == 1
            _, count = results[1]
            @test count ≥ 1
        end
    end

    @testset "multiple symbols with different reference counts" begin
        let code = """
            struct Foo end
            function bar(x::Foo)
                x
            end
            obj = Foo()
            result = bar(obj)
            """
            results = get_code_lenses_with_counts(code)
            @test length(results) == 2
            counts = sort([c for (_, c) in results])
            @test counts[1] < counts[2]
        end
    end

    @testset "qualified names" begin # currently supported
        let code = """
            struct X end
            Base.show(io::IO, ::X) = print(io, "X")
            """
            results = get_code_lenses_with_counts(code)
            @test length(results) == 1
        end
    end
end

end # module test_code_lens
