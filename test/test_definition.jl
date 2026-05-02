module test_definition

using Test
using JETLS

@testset "method location" begin
    linenum = @__LINE__; method_for_test_method_definition_range() = 1
    @assert length(methods(method_for_test_method_definition_range)) == 1
    test_method = first(methods(method_for_test_method_definition_range))
    method_location = JETLS.Location(test_method)
    @test method_location isa JETLS.LSP.Location
    @test JETLS.URIs2.uri2filepath(method_location.uri) == @__FILE__
    @test method_location.range.start.line == (linenum - 1)
end

module TestModuleDefinitionRange
myidentity(x) = x
end
const LINE_TestModuleDefinitionRange = (@__LINE__) - 3

@testset "module location" begin
    loc = JETLS.Location(TestModuleDefinitionRange)
    @test loc isa JETLS.LSP.Location
    @test JETLS.URIs2.uri2filepath(loc.uri) == @__FILE__
    @test loc.range.start.line == LINE_TestModuleDefinitionRange-1
end

include("setup.jl")

# Full-analysis helper — use this only for tests that exercise the
# reflection-based fallback (`Base` symbols, module `moduleloc`, etc.).
# Lowering-only tests should use `with_find_definition` instead, which
# skips the full server lifecycle and runs much faster.
function with_definition_request(tester, text::AbstractString; kwargs...)
    clean_code, positions = JETLS.get_text_and_positions(text; kwargs...)
    withscript(clean_code) do script_path
        uri = filepath2uri(script_path)
        withserver() do (; writereadmsg, id_counter)
            # run the full analysis first
            (; raw_res) = writereadmsg(make_DidOpenTextDocumentNotification(uri, clean_code))
            @test raw_res isa PublishDiagnosticsNotification
            @test raw_res.params.uri == uri
            cnt = 0
            for (i, pos) in enumerate(positions)
                (; raw_res) = writereadmsg(DefinitionRequest(;
                    id = id_counter[] += 1,
                    params = DefinitionParams(;
                        textDocument = TextDocumentIdentifier(; uri),
                        position = pos)))
                cnt += tester(i, raw_res.result, uri)
            end
            return cnt
        end
    end
end

# Lightweight helper that invokes `find_definition` directly. Suitable
# for tests that only need source-level (lowering-based) binding
# resolution.
function with_find_definition(tester, text::AbstractString; kwargs...)
    clean_code, positions = JETLS.get_text_and_positions(text; kwargs...)
    filename = joinpath(@__DIR__, "testfile_$(gensym(:definition)).jl")
    fi = JETLS.FileInfo(#=version=#0, clean_code, filename)
    furi = filename2uri(filename)
    server = JETLS.Server()
    JETLS.store!(server.state.file_cache) do cache
        Base.PersistentDict(cache, furi => fi), nothing
    end
    cnt = 0
    for (i, pos) in enumerate(positions)
        locations, _ = JETLS.find_definition(server, furi, fi, pos)
        cnt += tester(i, isempty(locations) ? null : locations, furi)
    end
    return cnt
end

@testset "'Definition' for modules and methods" begin
    @testset "function definition" begin
        @test with_find_definition("""
            func(x) = 1
            fu│nc(1.0)
            func(1.│0)
            let; func│; end
        """) do i, result, uri
            if i == 1
                @test length(result) == 1
                @test first(result).uri == uri
                @test first(result).range.start.line == 0
            elseif i == 2  # cursor on argument position
                @test result === null
            elseif i == 3  # function in let block
                @test length(result) == 1
                @test first(result).uri == uri
                @test first(result).range.start.line == 0
            end
            return 1
        end == 3
    end

    @testset "Base functions" begin
        sin_cand_file_, sin_cand_line = functionloc(first(methods(sin, (Float64,))))
        sin_cand_file = JETLS.to_full_path(sin_cand_file_)

        @test with_definition_request("""
            Base.Compiler.tm│eet
            si│n(1.0)
            1 +│ 2
            cos(x) = 1
            global x::Float64 = let x = 42
                Base.co│s(x)
            end
        """) do i, result, uri
            @test length(result) >= 1
            if i == 2  # sin
                @test any(result) do candidate
                    JETLS.uri2filepath(candidate.uri) == sin_cand_file &&
                    candidate.range.start.line == (sin_cand_line - 1)
                end
            elseif i == 4  # Base.cos (should point to Base, not local cos)
                @test all(result) do candidate
                    candidate.uri.path != uri
                end
            end
            return 1
        end == 4
    end

    @testset "function in module" begin
        @test with_definition_request("""
            module M
                m_func(x) = 1
                m_│func(1.0)
            end
            m_│func(1.0)
            M.m_│func(1.0)
        """) do i, result, uri
            if i == 1
                @test length(result) == 1
                @test first(result).uri == uri
                @test first(result).range.start.line == 1
            elseif i == 2
                @test result === null
            elseif i == 3
                @test length(result) == 1
                @test first(result).uri == uri
                @test first(result).range.start.line == 1
            end
            return 1
        end == 3
    end

    @testset "struct type and function aggregation" begin
        @test with_find_definition("""
            struct Hello
                who::String
                Hello(who::AbstractString) = new(String(who))
            end
            function say(h::Hel│lo)
                println("Hello, \$(h.who)")
            end
            function say_defarg(h::Hello, s = "Hello")
                println("\$s, \$(h.who)")
            end
            function say_kwarg(h::Hello; s = "Hello")
                println("\$s, \$(h.who)")
            end
            say_defar│g
            say_kwar│g
        """) do i, result, uri
            @test length(result) == 1
            @test first(result).uri == uri
            if i == 1  # struct type in function signature
                @test first(result).range.start.line == 0
            elseif i == 2  # function with default arguments (aggregated)
                @test first(result).range.start.line == 7
            elseif i == 3  # function with keyword arguments (aggregated)
                @test first(result).range.start.line == 10
            end
            return 1
        end == 3
    end

    @testset "target node selection" begin
        @test with_definition_request("""
            func(x) = 1
            func│ # bare function
            func│(1.0) # right edge
            │func(1.0) # left edge
            module M
                m_func(x) = 1
            end
            M.m_func│(1.0)
            M.│m_func(1.0)
        """) do i, result, uri
            @test length(result) == 1
            @test first(result).uri == uri
            if i <= 3  # simple function
                @test first(result).range.start.line == 0
            else  # qualified function (i == 4 or 5)
                @test first(result).range.start.line == 5
            end
            return 1
        end == 5
    end

    @testset "module location" begin
        @test with_definition_request("""
            module M2
                m_func(x) = 1
            end
            M2│.m_func(1.0)
            Core│.isdefined
        """) do i, result, uri
            if i == 1
                @test result isa Vector{Location}
                @test length(result) == 1
                @test only(result).uri == uri
                @test only(result).range.start.line == 0
            elseif i == 2  # Core doesn't return meaningful location
                @test result === null
            end
            return 1
        end == 2
    end

end

@testset "'Definition' for local bindings" begin
    @testset "local definition" begin
        @test with_find_definition("""
            function func(x, y)
                if rand(Bool)
                    z = x
                else
                    z = y
                end
                return z│
            end
        """) do _, results, uri
            @test results isa Vector{Location}
            @test length(results) == 2
            @test any(results) do result
                result.uri == uri &&
                result.range.start.line == 2
            end
            @test any(results) do result
                result.uri == uri &&
                result.range.start.line == 4
            end
            return 1
        end == 1
    end

    @testset "local definition with docstring" begin
        @test with_find_definition("""
            \"\"\"Docstring\"\"\"
            function func(xxx, yyy)
                value = xxx│ + yyy
                return value
            end
        """) do _, results, uri
            @test results isa Vector{Location}
            @test length(results) == 1
            @test any(results) do result
                result.uri == uri &&
                result.range.start.line == 1
            end
            return 1
        end == 1
    end

    @testset "local definition with macrocall" begin
        @test with_find_definition("""
            function func(xxx, yyy)
                value = @something rand((xxx│, yyy, nothing))
                return value
            end
        """) do _, results, uri
            @test results isa Vector{Location}
            @test length(results) == 1
            @test any(results) do result
                result.uri == uri &&
                result.range.start.line == 0
            end
            return 1
        end == 1
    end
end

@testset "'Definition' for imported names" begin
    # Cursor on an imported name should NOT stop at the import site.
    # The import site is a declaration (`:decl`), so `textDocument/definition`
    # falls through to reflection-based lookup and jumps to the source
    # (e.g. `sin` in Base).
    sin_cand_file_, sin_cand_line = functionloc(first(methods(sin, (Float64,))))
    sin_cand_file = JETLS.to_full_path(sin_cand_file_)
    @test with_definition_request("""
        using Base: sin
        si│n(1.0)
    """) do _, results, uri
        @test results isa Vector{Location}
        @test length(results) >= 1
        # Jump must go outside the current file (to Base's source).
        @test all(r -> JETLS.uri2filepath(r.uri) != JETLS.uri2filepath(uri), results)
        @test any(results) do r
            JETLS.uri2filepath(r.uri) == sin_cand_file &&
            r.range.start.line == (sin_cand_line - 1)
        end
        return 1
    end == 1
end

@testset "'Definition' for global bindings" begin
    @test with_find_definition("""
        GLOBAL_VAR = 42
        const CONST_VAR = 100
        MUTABLE_VAR = 1
        MUTABLE_VAR = 2
        function use_globals()
            GLOBAL_VA│R + CONST_VA│R + MUTABLE_VA│R
        end
    """) do i, results, uri
        @test results isa Vector{Location}
        if i == 1  # GLOBAL_VAR
            @test length(results) == 1
            @test first(results).uri == uri
            @test first(results).range.start.line == 0
        elseif i == 2  # CONST_VAR
            @test length(results) == 1
            @test first(results).uri == uri
            @test first(results).range.start.line == 1
        elseif i == 3  # MUTABLE_VAR (multiple assignments)
            @test length(results) == 2
            @test any(r -> r.range.start.line == 2, results)
            @test any(r -> r.range.start.line == 3, results)
        end
        return 1
    end == 3
end

end # module test_definition
