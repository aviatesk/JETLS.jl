module test_definition

using Test
using JETLS

@testset "method_definition_range" begin
    linenum = @__LINE__; method_for_test_method_definition_range() = 1
    @assert length(methods(method_for_test_method_definition_range)) == 1

    test_method = first(methods(method_for_test_method_definition_range))
    method_range = JETLS.method_definition_range(test_method)

    @test method_range isa JETLS.Location
    @test JETLS.URIs2.uri2filepath(method_range.uri) == @__FILE__
    @test method_range.range.start.line == (linenum - 1)
end

module TestModuleDefinitionRange
myidentity(x) = x
end
const LINE_TestModuleDefinitionRange = (@__LINE__) - 3

@testset "module_definition_location" begin
    loc = JETLS.module_definition_location(TestModuleDefinitionRange)
    @test loc isa JETLS.Location
    @test JETLS.URIs2.uri2filepath(loc.uri) == @__FILE__
    @test loc.range.start.line == LINE_TestModuleDefinitionRange-1
end

include("setup.jl")

@testset "'Definition' request/responce" begin
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
            (first(result).range.start.line == 0)

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
