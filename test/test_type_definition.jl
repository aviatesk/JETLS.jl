module test_type_definition

using Test
using JETLS

include("setup.jl")

# Lightweight helper that invokes `find_type_definition` directly. Mirrors
# `with_find_definition` in `test_definition.jl` — sufficient for type
# resolution that depends only on Base/Core globals (which are already
# materialized; the lightweight server's context module is `Main`).
function with_find_type_definition(tester, text::AbstractString; kwargs...)
    clean_code, positions = JETLS.get_text_and_positions(text; kwargs...)
    filename = joinpath(@__DIR__, "testfile_$(gensym(:type_definition)).jl")
    fi = JETLS.FileInfo(#=version=#0, clean_code, filename)
    furi = filename2uri(filename)
    server = JETLS.Server()
    JETLS.store!(server.state.file_cache) do cache
        Base.PersistentDict(cache, furi => fi), nothing
    end
    cnt = 0
    for (i, pos) in enumerate(positions)
        ret = JETLS.find_type_definition(server, furi, fi, pos)
        if ret === nothing
            cnt += tester(i, null, furi)
        else
            cnt += tester(i, ret[1], furi)
        end
    end
    return cnt
end

# Locations for a Base type's constructor methods, used to assert the
# response points into Base rather than the test buffer.
function base_method_files(@nospecialize T)
    files = Set{String}()
    for m in methods(T)
        JETLS.is_location_unknown(m) && continue
        file, _ = functionloc(m)
        file === nothing && continue
        push!(files, JETLS.to_full_path(String(file)))
    end
    return files
end

@testset HierarchicalTestSet "find_type_definition" begin
    @testset "type-annotated parameter" begin
        # cursor on the body usage of `x` infers to `Int`
        @test with_find_type_definition("""
                function f(x::Int)
                    x│
                end
            """) do _, result, _
            @test result !== null
            int_files = base_method_files(Int)
            @test all(loc -> JETLS.uri2filepath(loc.uri) in int_files, result)
            return 1
        end == 1
    end

    @testset "local binding inferred from literal" begin
        # `x` infers to `Core.Const(42)`; the type-of-value is `Int`
        @test with_find_type_definition("""
                function f()
                    x = 42
                    x│
                end
            """) do _, result, _
            @test result !== null
            int_files = base_method_files(Int)
            @test all(loc -> JETLS.uri2filepath(loc.uri) in int_files, result)
            return 1
        end == 1
    end

    @testset "type name itself" begin
        # cursor on `Int` infers to `Core.Const(Int)`; navigation target is
        # `Int` (not `DataType`).
        @test with_find_type_definition("""
                const T = I│nt
            """) do _, result, _
            @test result !== null
            int_files = base_method_files(Int)
            @test all(loc -> JETLS.uri2filepath(loc.uri) in int_files, result)
            return 1
        end == 1
    end

    @testset "dot expression" begin
        # cursor on the RHS of `Base.Pair` — `select_target_identifier` walks up
        # to the surrounding `K"."` and the type query on `Base.Pair` returns
        # `Core.Const(Pair)`.
        @test with_find_type_definition("""
                const T = Base.Pa│ir
            """) do _, result, _
            @test result !== null
            pair_files = base_method_files(Pair)
            @test all(loc -> JETLS.uri2filepath(loc.uri) in pair_files, result)
            return 1
        end == 1
    end

    @testset "call return type" begin
        # cursor right after `)` falls through identifier selection and lands on
        # the enclosing call; the type query returns the call's return type.
        @test with_find_type_definition("""
                function f()
                    sin(1.0)│
                end
            """) do _, result, _
            @test result !== null
            float_files = base_method_files(Float64)
            @test all(loc -> JETLS.uri2filepath(loc.uri) in float_files, result)
            return 1
        end == 1

        # `do`-block calls — JuliaSyntax extends the call's byte range to the
        # closing `end`, so `func() do ... end│` resolves to the call's return
        # type just like `func()│`.
        @test with_find_type_definition("""
                function f()
                    map([1,2,3]) do x
                        x + 1
                    end│
                end
            """) do _, result, _
            @test result !== null
            vec_files = base_method_files(Vector)
            @test all(loc -> JETLS.uri2filepath(loc.uri) in vec_files, result)
            return 1
        end == 1
    end

    @testset "no identifier at cursor" begin
        @test with_find_type_definition("""
                const T = Int │
            """) do _, result, _
            @test result === null
            return 1
        end == 1
    end

    # Full-server lifecycle tests for the document-symbol-cache primary path.
    # User-defined types only resolve to their `struct`/`abstract type` site
    # once full-analysis has populated `analysis_manager`.
    @testset "user-defined struct via document symbol cache" begin
        text = """
            struct MyType
                x::Int
            end
            function f(v::MyType)
                v│
            end
            """
        clean_code, positions = JETLS.get_text_and_positions(text)
        withscript(clean_code) do script_path
            uri = filepath2uri(script_path)
            withserver() do (; writereadmsg, id_counter)
                (; raw_res) = writereadmsg(
                    make_DidOpenTextDocumentNotification(uri, clean_code))
                @test raw_res isa PublishDiagnosticsNotification
                (; raw_res) = writereadmsg(TypeDefinitionRequest(;
                    id = id_counter[] += 1,
                    params = TypeDefinitionParams(;
                        textDocument = TextDocumentIdentifier(; uri),
                        position = only(positions))))
                result = raw_res.result
                @test result !== null
                # Should land on the `struct MyType` declaration (line 0),
                # not on a constructor's first line.
                @test length(result) == 1
                @test first(result).uri == uri
                @test first(result).range.start.line == 0
            end
        end
    end
end

end # module test_type_definition
