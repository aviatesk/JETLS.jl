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

# Helper to run a single definition test
function with_definition_request(tester, text::AbstractString; kwargs...)
    clean_code, positions = JETLS.get_text_and_positions(text; kwargs...)
    withscript(clean_code) do script_path
        uri = filepath2uri(script_path)
        withserver() do (; writereadmsg, id_counter)
            # run the full analysis first
            (; raw_res) = writereadmsg(make_DidOpenTextDocumentNotification(uri, clean_code))
            @test raw_res isa PublishDiagnosticsNotification
            @test raw_res.params.uri == uri
            for (i, pos) in enumerate(positions)
                (; raw_res) = writereadmsg(DefinitionRequest(;
                    id = id_counter[] += 1,
                    params = DefinitionParams(;
                        textDocument = TextDocumentIdentifier(; uri),
                        position = pos)))
                tester(i, raw_res.result, uri)
            end
        end
    end
end

@testset "'Definition' for module, method request/responce" begin
    @testset "function definition" begin
        cnt = 0
        with_definition_request("""
            func(x) = 1
            fu│nc(1.0)
        """) do i, result, uri
            @test length(result) == 1
            @test first(result).uri == uri
            @test first(result).range.start.line == 0
            cnt += 1
        end
        @test cnt == 1
    end

    @testset "Base functions" begin
        cnt = 0
        with_definition_request("""
            Base.Compiler.tm│eet
        """) do i, result, uri
            @test length(result) >= 1
            cnt += 1
        end
        @test cnt == 1

        sin_cand_file, sin_cand_line = functionloc(first(methods(sin, (Float64,))))
        sin_cand_file = JETLS.to_full_path(sin_cand_file)

        cnt = 0
        with_definition_request("""
            si│n(1.0)
        """) do i, result, uri
            @test length(result) >= 1
            @test any(result) do candidate
                JETLS.uri2filepath(candidate.uri) == sin_cand_file &&
                candidate.range.start.line == (sin_cand_line - 1)
            end
            cnt += 1
        end
        @test cnt == 1
    end
    @testset "Base function with invalid location" begin
        cnt = 0
        with_definition_request("""
            1 +│ 2
        """) do i, result, uri
            @test length(result) >= 1
            cnt += 1
        end
        @test cnt == 1
    end

    @testset "function argument position" begin
        cnt = 0
        with_definition_request("""
            func(x) = 1
            func(1.│0)
        """) do i, result, uri
            @test result === null
            cnt += 1
        end
        @test cnt == 1
    end

    @testset "function in module" begin
        cnt = 0
        with_definition_request("""
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
                cnt += 1
            elseif i == 2
                @test result === null
                cnt += 1
            elseif i == 3
                @test length(result) == 1
                @test first(result).uri == uri
                @test first(result).range.start.line == 1
                cnt += 1
            end
        end
        @test cnt == 3
    end

    @testset "Base override" begin
        cnt = 0
        with_definition_request("""
            cos(x) = 1
            Base.co│s(x) = 1
        """) do i, result, uri
            @test length(result) >= 1
            @test all(result) do candidate
                candidate.uri.path != uri # in `Base`, not `cos(x) = 1`
            end
            cnt += 1
        end
        @test cnt == 1
    end

    @testset "struct type in function signature" begin
        cnt = 0
        with_definition_request("""
            struct Hello
                who::String
                Hello(who::AbstractString) = new(String(who))
            end
            function say(h::Hel│lo)
                println("Hello, \$(h.who)")
            end
        """) do i, result, uri
            @test length(result) == 1
            @test first(result).uri == uri
            @test first(result).range.start.line == 2
            cnt += 1
        end
        @test cnt == 1
    end

    @testset "function with default arguments (should be aggregated)" begin
        cnt = 0
        with_definition_request("""
            struct Hello
                who::String
            end
            function say_defarg(h::Hello, s = "Hello")
                println("\$s, \$(h.who)")
            end
            say_defar│g
        """) do i, result, uri
            @test length(result) == 1
            @test first(result).uri == uri
            @test first(result).range.start.line == 3
            cnt += 1
        end
        @test cnt == 1
    end

    @testset "function with keyword arguments (should be aggregated)" begin
        cnt = 0
        with_definition_request("""
            struct Hello
                who::String
            end
            function say_kwarg(h::Hello; s = "Hello")
                println("\$s, \$(h.who)")
            end
            say_kwar│g
        """) do i, result, uri
            @test length(result) == 1
            @test first(result).uri == uri
            @test first(result).range.start.line == 3
            cnt += 1
        end
        @test cnt == 1
    end

    @testset "target node selection" begin
        local cnt = 0
        with_definition_request("""
            func(x) = 1
            func│ # bare function
            func│(1.0) # right edge
            │func(1.0) # left edge
        """) do i, result, uri
            if i == 1
                @test length(result) == 1
                @test first(result).uri == uri
                @test first(result).range.start.line == 0
                cnt += 1
            elseif i == 2
                @test length(result) == 1
                @test first(result).uri == uri
                @test first(result).range.start.line == 0
                cnt += 1
            elseif i == 3
                @test length(result) == 1
                @test first(result).uri == uri
                @test first(result).range.start.line == 0
                cnt += 1
            end
        end
        @test cnt == 3
    end

    @testset "target node selection (qualified function)" begin
        cnt = 0
        with_definition_request("""
            module M
                m_func(x) = 1
            end
            M.m_func│(1.0)
            M.│m_func(1.0)
        """) do i, result, uri
            if i == 1
                @test length(result) == 1
                @test first(result).uri == uri
                @test first(result).range.start.line == 1
                cnt += 1
            elseif i == 2
                @test length(result) == 1
                @test first(result).uri == uri
                @test first(result).range.start.line == 1
                cnt += 1
            end
        end
        @test cnt == 2
    end

    @testset "function in let block" begin
        cnt = 0
        with_definition_request("""
            func(x) = 1
            let; func│; end
        """) do i, result, uri
            @test length(result) == 1
            @test first(result).uri == uri
            @test first(result).range.start.line == 0
            cnt += 1
        end
        @test cnt == 1
    end

    @testset "module location" begin
        cnt = 0
        with_definition_request("""
            module M2
                m_func(x) = 1
            end
            M2│.m_func(1.0)
        """) do i, result, uri
            @test result isa Location
            @test result.uri == uri
            @test result.range.start.line == 0
            cnt += 1
        end
        @test cnt == 1
    end

    @testset "invalid module location" begin
        cnt = 0
        with_definition_request("""
            Core│.isdefined
        """) do i, result, uri
            @test result === null # `Base.moduleloc(Core)` doesn't return anything meaningful
            cnt += 1
        end
        @test cnt == 1
    end

    @testset "local definition" begin
        local cnt = 0
        with_definition_request("""
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
            cnt += 1
        end
        @test cnt == 1
    end
end

@testset "'Definition' for local bindings" begin
    @testset "local definition with macrocall" begin
        cnt = 0
        with_definition_request("""
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
            cnt += 1
        end
        @test cnt == 1
    end
end

end # module test_definition
