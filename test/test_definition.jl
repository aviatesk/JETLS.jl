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
    clean_code, positions = JETLS.get_text_and_positions(text, r"│")
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
                @test length(defs) == 1
                # The definition should be x = 1 on line 2, not the parameter x on line 1
                @test JS.source_line(JL.sourceref(only(defs))) == 2 broken=true
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

@testset "'Definition' for module, method request/responce" begin
    script_code = """
    #= 1=# func(x) = 1
    #= 2=# fu│nc(1.0)
    #= 3=# si│n(1.0)
    #= 4=#
    #= 5=# Core.Compiler.tm│eet
    #= 6=# Co│re.Compiler.tmeet
    #= 7=#
    #= 8=# func(1.│0)
    #= 9=# sin(1.│0)
    #=10=#
    #=11=# module M
    #=12=#     m_func(x) = 1
    #=13=#     m_│func(1.0)
    #=14=# end
    #=15=#
    #=16=# m_│func(1.0)
    #=17=# M.m_│func(1.0)
    #=18=#
    #=19=# module M2
    #=20=#     m_func(x) = 1
    #=21=#     m_│func(1.0)
    #=22=# end
    #=23=#
    #=24=# M2.m_│func(1.0)
    #=25=#
    #=26=# cos(x) = 1
    #=27=#
    #=28=# Base.co│s(x) = 1
    #=29=#
    #=30=# struct Hello
    #=31=#     who::String
    #=32=#     Hello(who::AbstractString) = new(String(who))
    #=33=# end
    #=34=# function say(h::Hel│lo)
    #=35=#     println("Hello, \$(hello.who)")
    #=36=# end
    #=37=#
    #=38=# function say_defarg(h::Hello, s = "Hello")
    #=39=#     println("\$s, \$(hello.who)")
    #=40=# end
    #=41=# say_defar│g
    #=42=#
    #=43=# function say_kwarg(h::Hello; s = "Hello")
    #=44=#     println("\$s, \$(hello.who)")
    #=45=# end
    #=46=# say_kwar│g
    #=47=#
    #=48=# func│
    #=49=# func│(1.0)
    #=50=# func(│1.0)
    #=51=# │func(1.0)
    #=52=# M.m_func│(1.0)
    #=53=# M.│m_func(1.0)
    #=54=# let; func│; end
    #=55=#
    #=56=# 1 +│ 2
    #=57=#
    #=58=# M2│.m_func(1.0)
    #=58=# Core│.isdefined
    """

    sin_cand_file, sin_cand_line = functionloc(first(methods(sin, (Float64,))))
    sin_cand_file = JETLS.to_full_path(sin_cand_file)

    testers = [
        # fu│nc(1.0)
        (result, uri) ->
            (length(result) == 1) &&
            (first(result).uri == uri) &&
            (first(result).range.start.line == 0)

        # si│n(x)
        (result, uri) ->
            (length(result) >= 1) &&
            (any(result) do candidate
                JETLS.uri2filepath(candidate.uri) == sin_cand_file &&
                candidate.range.start.line == (sin_cand_line - 1)
            end)

        # Core.Compiler.tm│eet
        (result, uri) ->
            (length(result) >= 1)

        # Co│re.Compiler.tmeet
        (result, uri) -> (result === null)

        # func(1.│0)
        (result, uri) -> (result === null)

        # sin(1.│0)
        (result, uri) -> (result === null)

        # m_│func(1.0) in module M
        (result, uri) ->
            (length(result) == 1) &&
            (first(result).uri == uri) &&
            (first(result).range.start.line == 11)

        # m_│func(1.0)
        (result, uri) -> (result === null)

        # M.m_│func(1.0)
        (result, uri) ->
            (length(result) == 1) &&
            (first(result).uri == uri) &&
            (first(result).range.start.line == 11)

        # m_│func(1.0) in module M2
        (result, uri) ->
            (length(result) == 1) &&
            (first(result).uri == uri) &&
            (first(result).range.start.line == 19)

        # M2.m_│func(1.0)
        (result, uri) ->
            (length(result) == 1) &&
            (first(result).uri == uri) &&
            (first(result).range.start.line == 19)

        # Base.co│s(x)
        (result, uri) ->
            (length(result) >= 1) &&
            (all(result) do candidate
                candidate.uri.path != uri # in `Base`, not `cos(x) = 1`
            end)

        # function say(h::Hel|lo)
        (result, uri) ->
            (length(result) == 1) &&
            (first(result).uri == uri) &&
            (first(result).range.start.line == 31)

        # say_defar│g
        (result, uri) ->
            (length(result) == 1) && # aggregation
            (first(result).uri == uri) &&
            (first(result).range.start.line == 37)

        # say_kwar│g
        (result, uri) ->
            (length(result) == 1) && # aggregation
            (first(result).uri == uri) &&
            (first(result).range.start.line == 42)

        # func│
        (result, uri) ->
            (length(result) == 1) &&
            (first(result).uri == uri) &&
            (first(result).range.start.line == 0)

        # func│(1.0)
        (result, uri) ->
            (length(result) == 1) &&
            (first(result).uri == uri) &&
            (first(result).range.start.line == 0)

        # func(│1.0)
        (result, uri) -> (result === null)

        # │func(1.0)
        (result, uri) ->
            (length(result) == 1) &&
            (first(result).uri == uri) &&
            (first(result).range.start.line == 0) &&
            (first(result).range.start.character == 0)


        # M.m_func│(1.0)
        (result, uri) ->
            (length(result) == 1) &&
            (first(result).uri == uri) &&
            (first(result).range.start.line == 11)

        # M.│m_func(1.0)
        (result, uri) ->
            (length(result) == 1) &&
            (first(result).uri == uri) &&
            (first(result).range.start.line == 11)

        # let; func│; end
        (result, uri) ->
            (length(result) == 1) &&
            (first(result).uri == uri) &&
            (first(result).range.start.line == 0)

        # 1 +│ 2
        (result, uri) ->
            (length(result) >= 1)

        # M2│.m_func(1.0)
        (result, uri) ->
            (result isa Location) &&
            (result.uri == uri) &&
            (result.range.start.line == 18)

        # Core│.isdefined
        (result, uri) -> (result === null) # `Base.moduleloc(Core)` doesn't return anything meaningful
    ]

    clean_code, positions = JETLS.get_text_and_positions(script_code, r"│")
    @assert length(positions) == length(testers)

    withscript(clean_code) do script_path
        uri = filepath2uri(script_path)
        withserver() do (; writereadmsg, id_counter)
            # run the full analysis first
            (; raw_res) = writereadmsg(make_DidOpenTextDocumentNotification(uri, read(script_path, String)))
            @test raw_res isa PublishDiagnosticsNotification
            @test raw_res.params.uri == uri

            for (i, (pos, tester)) in enumerate(zip(positions, testers))
                @testset let loc = functionloc(only(methods(tester))),
                             id = id_counter[] += 1,
                             i = i
                    (; raw_res) = writereadmsg(DefinitionRequest(;
                        id,
                        params = DefinitionParams(;
                            textDocument = TextDocumentIdentifier(; uri),
                            position = pos)))
                    @test tester(raw_res.result, uri)
                end
            end
        end
    end
end

end # module test_definition
