module test_definition

using Test
using JETLS
using JETLS: JS, JL

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

include("jsjl_utils.jl")

function with_local_definitions(f, text::AbstractString, matcher::Regex=r"│")
    clean_code, positions = JETLS.get_text_and_positions(text, matcher)
    st0_top = jlparse(clean_code)
    for (i, pos) in enumerate(positions)
        offset = JETLS.xy_to_offset(Vector{UInt8}(clean_code), pos)
        f(i, JETLS.local_definitions(st0_top, offset))
    end
end

@testset "local definitions" begin
    with_local_definitions("""
        function mapfunc(xs)
            Any[Core.Const(x│)
                for x in xs]
        end
    """) do _, res
        @test !isnothing(res)
        binding, defs = res
        @test JS.source_line(JL.sourceref(binding)) == 2
        @test length(defs) == 1
        @test JS.source_line(JL.sourceref(only(defs))) == 3
    end

    @testset "simple" begin
        cnt = 0
        with_local_definitions("""
            function func(x)
                y = x│ + 1
                return y│
            end
        """) do i, res
            if i == 1 # x│
                @test !isnothing(res)
                binding, defs = res
                @test JS.source_line(JL.sourceref(binding)) == 2
                @test length(defs) == 1
                @test JS.source_line(JL.sourceref(only(defs))) == 1
                cnt += 1
            elseif i == 2 # y│
                @test !isnothing(res)
                binding, defs = res
                @test JS.source_line(JL.sourceref(binding)) == 3
                @test length(defs) == 1
                @test JS.source_line(JL.sourceref(only(defs))) == 2
                cnt += 1
            end
        end
        @test cnt == 2
    end

    @testset "parameter shadowing" begin
        cnt = 0
        with_local_definitions("""
            function redef(x)
                x = 1
                y = x│ + 1
                return y│
            end
        """) do i, res
            if i == 1 # x│
                @test !isnothing(res)
                binding, defs = res
                @test JS.source_line(JL.sourceref(binding)) == 3
                @test length(defs) == 2 # Both parameter x and local x = 1
                # The definitions should include both x = 1 on line 2 and the parameter x on line 1
                @test any(d -> JS.source_line(JL.sourceref(d)) == 1, defs) # parameter
                @test any(d -> JS.source_line(JL.sourceref(d)) == 2, defs) # local assignment
                cnt += 1
            elseif i == 2 # y│
                @test !isnothing(res)
                binding, defs = res
                @test JS.source_line(JL.sourceref(binding)) == 4
                @test length(defs) == 1
                @test JS.source_line(JL.sourceref(only(defs))) == 3
                cnt += 1
            end
        end
        @test cnt == 2
    end

    @testset "function self-reference" begin
        cnt = 0
        with_local_definitions("""
            function rec(x)
                return rec│(x + 1)
            end
        """) do _, res
            @test !isnothing(res)
            binding, defs = res
            @test JS.source_line(JL.sourceref(binding)) == 2
            @test length(defs) >= 1
            @test any(defs) do def
                JS.source_line(JL.sourceref(def)) == 1
            end
            cnt += 1
        end
        @test cnt == 1
    end

    @testset "closure captures" begin
        cnt = 0
        with_local_definitions("""
            function closure()
                x = 1
                function inner(y)
                    return x│ + y│
                end
                return inner
            end
        """) do i, res
            if i == 1 # x│
                @test !isnothing(res)
                binding, defs = res
                @test JS.source_line(JL.sourceref(binding)) == 4
                @test length(defs) == 1
                @test JS.source_line(JL.sourceref(only(defs))) == 2
                cnt += 1
            elseif i == 2 # y│
                @test !isnothing(res)
                binding, defs = res
                @test JS.source_line(JL.sourceref(binding)) == 4
                @test length(defs) == 1
                @test JS.source_line(JL.sourceref(only(defs))) == 3
                cnt += 1
            end
        end
        @test cnt == 2
    end

    @testset "let binding" begin
        cnt = 0
        with_local_definitions("""
            function let_binding()
                let x = 1
                    y = x│ + 1
                    return y│
                end
            end
        """) do i, res
            if i == 1 # x│
                @test !isnothing(res)
                binding, defs = res
                @test JS.source_line(JL.sourceref(binding)) == 3
                @test length(defs) == 1
                @test JS.source_line(JL.sourceref(only(defs))) == 2
                cnt += 1
            elseif i == 2 # y│
                @test !isnothing(res)
                binding, defs = res
                @test JS.source_line(JL.sourceref(binding)) == 4
                @test length(defs) == 1
                @test JS.source_line(JL.sourceref(only(defs))) == 3
                cnt += 1
            end
        end
        @test cnt == 2
    end

    @testset "for loop variable" begin
        cnt = 0
        with_local_definitions("""
            function loop_var(n)
                for i in 1:n
                    println(i│)
                end
            end
        """) do _, res
            @test !isnothing(res)
            binding, defs = res
            @test JS.source_line(JL.sourceref(binding)) == 3
            @test length(defs) == 1
            @test JS.source_line(JL.sourceref(only(defs))) == 2
            cnt += 1
        end
        @test cnt == 1
    end

    @testset "comprehension variable" begin
        cnt = 0
        with_local_definitions("""
            let
                v = [│xxx^2 for xxx in 1:5]
                return v
            end
        """) do _, res
            @test !isnothing(res)
            binding, defs = res
            @test JS.source_line(JL.sourceref(binding)) == 2
            @test length(defs) == 1
            @test JS.source_line(JL.sourceref(only(defs))) == 2
            cnt += 1
        end
        @test cnt == 1
    end

    @testset "destructuring assignment" begin
        cnt = 0
        with_local_definitions("""
            function destructuring()
                (a, b) = (1, 2)
                return a│ + b│
            end
        """) do i, res
            if i == 1 # a│
                @test !isnothing(res)
                binding, defs = res
                @test JS.source_line(JL.sourceref(binding)) == 3
                @test length(defs) == 1
                @test JS.source_line(JL.sourceref(only(defs))) == 2
                cnt += 1
            elseif i == 2 # b│
                @test !isnothing(res)
                binding, defs = res
                @test JS.source_line(JL.sourceref(binding)) == 3
                @test length(defs) == 1
                @test JS.source_line(JL.sourceref(only(defs))) == 2
                cnt += 1
            end
        end
        @test cnt == 2
    end

    @testset "conditional binding" begin
        cnt = 0
        with_local_definitions("""
            function if_branch(x)
                if x > 0
                    y = x
                end
                return y│
            end
        """) do _, res
            @test !isnothing(res)
            binding, defs = res
            @test JS.source_line(JL.sourceref(binding)) == 5
            @test length(defs) == 1
            @test JS.source_line(JL.sourceref(only(defs))) == 3
            cnt += 1
        end
        @test cnt == 1
    end

    @testset "try-catch variable" begin
        cnt = 0
        with_local_definitions("""
            function try_catch()
                try
                    error("boom")
                catch err
                    return err│
                end
            end
        """) do _, res
            @test !isnothing(res)
            binding, defs = res
            @test JS.source_line(JL.sourceref(binding)) == 5
            @test length(defs) == 1
            @test JS.source_line(JL.sourceref(only(defs))) == 4
            cnt += 1
        end
        @test cnt == 1
    end

    @testset "do block parameter" begin
        cnt = 0
        with_local_definitions("""
            function do_block()
                map(1:3) do t
                    t│ + 1
                end
            end
        """) do _, res
            @test !isnothing(res)
            binding, defs = res
            @test JS.source_line(JL.sourceref(binding)) == 3
            @test length(defs) == 1
            @test JS.source_line(JL.sourceref(only(defs))) == 2
            cnt += 1
        end
        @test cnt == 1
    end

    @testset "lambda parameter" begin
        cnt = 0
        with_local_definitions("""
            sq = x -> x│ ^ 2
        """) do _, res
            @test !isnothing(res)
            binding, defs = res
            @test JS.source_line(JL.sourceref(binding)) == 1
            @test length(defs) == 1
            @test JS.source_line(JL.sourceref(only(defs))) == 1
            cnt += 1
        end
        @test cnt == 1
    end

    @testset "nested let scopes" begin
        cnt = 0
        with_local_definitions("""
            function nested_let()
                let x = 1
                    let x = 2
                        return x│
                    end
                end
            end
        """) do _, res
            @test !isnothing(res)
            binding, defs = res
            @test JS.source_line(JL.sourceref(binding)) == 4
            @test length(defs) == 1
            @test JS.source_line(JL.sourceref(only(defs))) == 3
            cnt += 1
        end
        @test cnt == 1
    end

    @testset "for loop shadowing" begin
        cnt = 0
        with_local_definitions("""
            function loop_shadow()
                x = 0
                for x = 1:3
                    println(x│)
                end
            end
        """) do _, res
            @test !isnothing(res)
            binding, defs = res
            @test JS.source_line(JL.sourceref(binding)) == 4
            @test length(defs) == 1
            @test JS.source_line(JL.sourceref(only(defs))) == 3
            cnt += 1
        end
        @test cnt == 1
    end

    @testset "closure recapture" begin
        cnt = 0
        with_local_definitions("""
            function recapture()
                x = 1
                f = () -> x│ + 1
                x = 2
                return f()
            end
        """) do _, res
            @test !isnothing(res)
            binding, defs = res
            @test JS.source_line(JL.sourceref(binding)) == 3
            @test length(defs) == 2
            @test any(def -> JS.source_line(JL.sourceref(def)) == 2, defs)
            @test any(def -> JS.source_line(JL.sourceref(def)) == 4, defs)
            cnt += 1
        end
        @test cnt == 1
    end

    @testset "keyword arguments" begin
        cnt = 0
        with_local_definitions("""
            function keyword_args(; a = 1, b = 2)
                a│ + b│
            end
        """) do i, res
            if i == 1 # a│
                @test !isnothing(res)
                binding, defs = res
                @test JS.source_line(JL.sourceref(binding)) == 2
                @test length(defs) == 1
                @test JS.source_line(JL.sourceref(only(defs))) == 1
                cnt += 1
            elseif i == 2 # b│
                @test !isnothing(res)
                binding, defs = res
                @test JS.source_line(JL.sourceref(binding)) == 2
                @test length(defs) == 1
                @test JS.source_line(JL.sourceref(only(defs))) == 1
                cnt += 1
            end
        end
        @test cnt == 2
    end

    @testset "inner function parameter shadowing" begin
        cnt = 0
        with_local_definitions("""
            function outer()
                x = 1
                function inner(x)
                    return x│ + 1
                end
                return inner
            end
        """) do _, res
            @test !isnothing(res)
            binding, defs = res
            @test JS.source_line(JL.sourceref(binding)) == 4
            @test length(defs) == 1
            @test JS.source_line(JL.sourceref(only(defs))) == 3
            cnt += 1
        end
        @test cnt == 1
    end

    @testset "non-linear control flow" begin
        cnt = 0
        with_local_definitions("""
            function not_linear()
                finish = false
                @label l1
                (!finish) && @goto l2
                return x│
                @label l2
                x = 1
                finish = true
                @goto l1
            end
        """) do _, res
            @test !isnothing(res)
            binding, defs = res
            @test JS.source_line(JL.sourceref(binding)) == 5
            @test length(defs) == 1
            @test JS.source_line(JL.sourceref(only(defs))) == 7
            cnt += 1
        end
        @test cnt == 1
    end

    @testset "undefined variable" begin
        cnt = 0
        with_local_definitions("""
            function undefined_var()
                return x│
            end
        """) do _, res
            @test isnothing(res)
            cnt += 1
        end
        @test cnt == 1
    end
end

include("setup.jl")

# Helper to run a single global definition test
function test_global_definition(tester::Function, text::AbstractString)
    clean_code, positions = JETLS.get_text_and_positions(text, r"│")

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
        test_global_definition("""
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
        test_global_definition("""
            Base.Compiler.tm│eet
        """) do i, result, uri
            @test length(result) >= 1
            cnt += 1
        end
        @test cnt == 1

        sin_cand_file, sin_cand_line = functionloc(first(methods(sin, (Float64,))))
        sin_cand_file = JETLS.to_full_path(sin_cand_file)

        cnt = 0
        test_global_definition("""
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
        test_global_definition("""
            1 +│ 2
        """) do i, result, uri
            @test length(result) >= 1
            cnt += 1
        end
        @test cnt == 1
    end

    @testset "function argument position" begin
        cnt = 0
        test_global_definition("""
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
        test_global_definition("""
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
        test_global_definition("""
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
        test_global_definition("""
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
        test_global_definition("""
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
        test_global_definition("""
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
        test_global_definition("""
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
        test_global_definition("""
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
        test_global_definition("""
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
        test_global_definition("""
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
        test_global_definition("""
            Core│.isdefined
        """) do i, result, uri
            @test result === null # `Base.moduleloc(Core)` doesn't return anything meaningful
            cnt += 1
        end
        @test cnt == 1
    end
end

end # module test_definition
