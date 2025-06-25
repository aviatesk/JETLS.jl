module test_definition

using Test
using JETLS

@testset "method_definition_range" begin
    linenum = @__LINE__; method_for_test_method_definition_range() = 1
    @assert length(methods(method_for_test_method_definition_range)) == 1
    test_method = first(methods(method_for_test_method_definition_range))
    method_location = JETLS.get_location(test_method)
    @test method_location isa JETLS.Location
    @test JETLS.URIs2.uri2filepath(method_location.uri) == @__FILE__
    @test method_location.range.start.line == (linenum - 1)
end

module TestModuleDefinitionRange
myidentity(x) = x
end
const LINE_TestModuleDefinitionRange = (@__LINE__) - 3

@testset "module_definition_location" begin
    loc = JETLS.get_location(TestModuleDefinitionRange)
    @test loc isa JETLS.Location
    @test JETLS.URIs2.uri2filepath(loc.uri) == @__FILE__
    @test loc.range.start.line == LINE_TestModuleDefinitionRange-1
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
            (length(result) == 1) &&
            (first(result) isa Location) &&
            (first(result).uri == uri) &&
            (first(result).range.start.line == 18)

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

@testset "'Definition' for local bindings request/responce" begin
    script_code = """
    #= 1=# function func(x)
    #= 2=#     y = x│ + 1
    #= 3=#     return y│
    #= 4=# end
    #= 5=#
    #= 6=# function redef(x)
    #= 7=#     x = 1
    #= 8=#     y = x│ + 1
    #= 9=#     return y│
    #=10=# end
    #=11=#
    #=12=# function rec(x)
    #=13=#     return rec│(x + 1)
    #=14=# end
    #=15=#
    #=16=# function closure()
    #=17=#     x = 1
    #=18=#     function inner(y)
    #=19=#         return x│ + y│
    #=20=#     end
    #=21=#     return inner
    #=22=# end
    #=23=#
    #=24=# function let_binding()
    #=25=#     let x = 1
    #=26=#         y = x│ + 1
    #=27=#         return y│
    #=28=#     end
    #=29=# end
    #=30=#
    #=31=# function loop_var(n)
    #=32=#     for i in 1:n
    #=33=#         println(i│)
    #=34=#     end
    #=35=# end
    #=36=#
    #=37=# function compre()
    #=38=#     v = [│x^2 for x in 1:5]
    #=39=#     return v
    #=40=# end
    #=41=#
    #=42=# function destructuring()
    #=43=#     (a, b) = (1, 2)
    #=44=#     return a│ + b
    #=45=# end
    #=46=#
    #=47=# function if_branch(x)
    #=48=#     if x > 0
    #=49=#         y = x
    #=50=#     end
    #=51=#     return y│
    #=52=# end
    #=53=#
    #=54=# function try_catch()
    #=55=#     try
    #=56=#         error("boom")
    #=57=#     catch err
    #=58=#         return err│
    #=59=#     end
    #=60=# end
    #=61=#
    #=62=# function do_block()
    #=63=#     map(1:3) do t
    #=64=#         t│ + 1
    #=65=#     end
    #=66=# end
    #=67=#
    #=68=# sq = x -> x│ ^ 2
    #=69=#
    #=70=# function nested_let()
    #=71=#     let x = 1
    #=72=#         let x = 2
    #=73=#             return x│
    #=74=#         end
    #=75=#     end
    #=76=# end
    #=77=#
    #=78=# function loop_shadow()
    #=79=#     x = 0
    #=80=#     for x = 1:3
    #=81=#         println(x│)
    #=82=#     end
    #=83=# end
    #=84=#
    #=85=# function recapture()
    #=86=#     x = 1
    #=87=#     f = () -> x│ + 1
    #=88=#     x = 2
    #=89=#     return f()
    #=90=# end
    #=91=#
    #=92=# function keyword_args(; a = 1, b = 2)
    #=93=#     a│ + b│
    #=94=# end
    #=95=#
    #=96=# function outer()
    #=97=#     x = 1
    #=98=#     function inner(x)
    #=99=#         return x│ + 1
    #=100=#    end
    #=101=#    return inner
    #=102=# end
    #=103=#
    #=104=# function not_linear()
    #=105=#     finish = false
    #=106=#     @label l1
    #=107=#     (!finish) && @goto l2
    #=108=#     return x│
    #=109=#     @label l2
    #=110=#     x = 1
    #=111=#     finish = true
    #=112=#     @goto l1
    #=113=# end
    #=114=#
    #=115=# function undefined_var()
    #=116=#     return x│
    #=117=# end
    """

    testers = [
        # y = x│ + 1
        (result, uri) ->
            (length(result) == 1) &&
            (first(result).uri == uri) &&
            (first(result).range.start.line == 0) &&
            (first(result).range.start.character == 14) &&
            (first(result).range.var"end".line == 0) &&
            (first(result).range.var"end".character == 15)

        # return y│
        (result, uri) ->
            (length(result) == 1) &&
            (first(result).uri == uri) &&
            (first(result).range.start.line == 1) &&
            (first(result).range.start.character == 4) &&
            (first(result).range.var"end".line == 1) &&
            (first(result).range.var"end".character == 5)

        # y = x│ + 1 (should be x = 1)
        (result, uri) ->
            (length(result) == 1) &&
            (first(result).uri == uri) &&
            (first(result).range.start.line == 6) &&
            (first(result).range.start.character == 4) &&
            (first(result).range.var"end".line == 6) &&
            (first(result).range.var"end".character == 5)

        # return y│
        (result, uri) ->
            (length(result) == 1) &&
            (first(result).uri == uri) &&
            (first(result).range.start.line == 7) &&
            (first(result).range.start.character == 4) &&
            (first(result).range.var"end".line == 7) &&
            (first(result).range.var"end".character == 5)

        # return rec│(x + 1)
        (result, uri) ->
            (length(result) >= 1) &&
            (any(result) do candidate
                candidate.uri == uri &&
                candidate.range.start.line == 11 &&
                candidate.range.start.character == 9 &&
                candidate.range.var"end".line == 11 &&
                candidate.range.var"end".character == 12
            end)

        # return x│ + y│
        (result, uri) ->
            (length(result) == 1) &&
            (first(result).uri == uri) &&
            (first(result).range.start.line == 16) &&
            (first(result).range.start.character == 4) &&
            (first(result).range.var"end".line == 16) &&
            (first(result).range.var"end".character == 5)

        # return x│ + y│
        (result, uri) ->
            (length(result) == 1) &&
            (first(result).uri == uri) &&
            (first(result).range.start.line == 17) &&
            (first(result).range.start.character == 19) &&
            (first(result).range.var"end".line == 17) &&
            (first(result).range.var"end".character == 20)

        # y = x│ + 1
        (result, uri) ->
            (length(result) == 1) &&
            (first(result).uri == uri) &&
            (first(result).range.start.line == 24) &&
            (first(result).range.start.character == 8) &&
            (first(result).range.var"end".line == 24) &&
            (first(result).range.var"end".character == 9)

        # return y│
        (result, uri) ->
            (length(result) == 1) &&
            (first(result).uri == uri) &&
            (first(result).range.start.line == 25) &&
            (first(result).range.start.character == 8) &&
            (first(result).range.var"end".line == 25) &&
            (first(result).range.var"end".character == 9)

        # println(i│)
        (result, uri) ->
            (length(result) == 1) &&
            (first(result).uri == uri) &&
            (first(result).range.start.line == 31) &&
            (first(result).range.start.character == 8) &&
            (first(result).range.var"end".line == 31) &&
            (first(result).range.var"end".character == 9)

        # v = [│x^2 for x in 1:5]
        (result, uri) ->
            (length(result) == 1) &&
            (first(result).uri == uri) &&
            (first(result).range.start.line == 37) &&
            (first(result).range.start.character == 17) &&
            (first(result).range.var"end".line == 37) &&
            (first(result).range.var"end".character == 18)

        # return a│ + b
        (result, uri) ->
            (length(result) == 1) &&
            (first(result).uri == uri) &&
            (first(result).range.start.line == 42) &&
            (first(result).range.start.character == 5) &&
            (first(result).range.var"end".line == 42) &&
            (first(result).range.var"end".character == 6)

        # return y│
        (result, uri) ->
            (length(result) == 1) &&
            (first(result).uri == uri) &&
            (first(result).range.start.line == 48) &&
            (first(result).range.start.character == 8) &&
            (first(result).range.var"end".line == 48) &&
            (first(result).range.var"end".character == 9)

        # return err│
        (result, uri) ->
            (length(result) == 1) &&
            (first(result).uri == uri) &&
            (first(result).range.start.line == 56) &&
            (first(result).range.start.character == 10) &&
            (first(result).range.var"end".line == 56) &&
            (first(result).range.var"end".character == 13)

        # t│ + 1
        (result, uri) ->
            (length(result) == 1) &&
            (first(result).uri == uri) &&
            (first(result).range.start.line == 62) &&
            (first(result).range.start.character == 16) &&
            (first(result).range.var"end".line == 62) &&
            (first(result).range.var"end".character == 17)

        # sq = x -> x│ ^ 2 (lambda parameter)
        (result, uri) ->
            (length(result) == 1) &&
            (first(result).uri == uri) &&
            (first(result).range.start.line == 67) &&
            (first(result).range.start.character == 5) &&
            (first(result).range.var"end".line == 67) &&
            (first(result).range.var"end".character == 6)

        # return x│
        (result, uri) ->
            (length(result) == 1) &&
            (first(result).uri == uri) &&
            (first(result).range.start.line == 71) &&
            (first(result).range.start.character == 12) &&
            (first(result).range.var"end".line == 71) &&
            (first(result).range.var"end".character == 13)

        # println(x│)
        (result, uri) ->
            (length(result) == 1) &&
            (first(result).uri == uri) &&
            (first(result).range.start.line == 79) &&
            (first(result).range.start.character == 8) &&
            (first(result).range.var"end".line == 79) &&
            (first(result).range.var"end".character == 9)

        # f = () -> x│ + 1
        (result, uri) ->
            (length(result) == 1) &&
            (first(result).uri == uri) &&
            (first(result).range.start.line == 85) &&
            (first(result).range.start.character == 4) &&
            (first(result).range.var"end".line == 85) &&
            (first(result).range.var"end".character == 5)

        # return a│ + b
        (result, uri) ->
            (length(result) == 1) &&
            (first(result).uri == uri) &&
            (first(result).range.start.line == 91) &&
            (first(result).range.start.character == 24) &&
            (first(result).range.var"end".line == 91) &&
            (first(result).range.var"end".character == 25)

        # return a + b│
        (result, uri) ->
            (length(result) == 1) &&
            (first(result).uri == uri) &&
            (first(result).range.start.line == 91) &&
            (first(result).range.start.character == 31) &&
            (first(result).range.var"end".line == 91) &&
            (first(result).range.var"end".character == 32)

        # return x│ + 1
        (result, uri) ->
            (length(result) == 1) &&
            (first(result).uri == uri) &&
            (first(result).range.start.line == 98) &&
            (first(result).range.start.character == 8) &&
            (first(result).range.var"end".line == 98) &&
            (first(result).range.var"end".character == 9)

        # return x│
        (result, uri) ->
            (length(result) == 1) &&
            (first(result).uri == uri) &&
            (first(result).range.start.line == 109) &&
            (first(result).range.start.character == 4) &&
            (first(result).range.var"end".line == 109) &&
            (first(result).range.var"end".character == 5)

        # return x│
        (result, uri) ->
            (result === null)
    ]

    # remove prefixes like `#= 1=#` first
    script_code = join(replace.(split(script_code, '\n'), r"#=\s*\d+\s*=#\s" => ""), '\n')
    clean_code, positions = JETLS.get_text_and_positions(script_code, r"│")
    @assert length(positions) == length(testers)

    broken_cases = [
        3,  # y = x│ + 1 (overwriting `x`)`
        11, # v = [│x^2 for x in 1:5]
        22, # return x│ + 1 (overwriting `x` in inner function)
        23, # return x│ (control flow including `@goto`)
    ]

    withscript(clean_code) do script_path
        uri = filepath2uri(script_path)
        withserver() do (; writereadmsg, id_counter)
            # run the full analysis first
            (; raw_res) = writereadmsg(make_DidOpenTextDocumentNotification(uri, clean_code))
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

                    @test tester(raw_res.result, uri) broken=(i in broken_cases)
                end
            end
        end
    end
end


end # module test_definition
