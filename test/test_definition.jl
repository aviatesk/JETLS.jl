module test_definition

using Test
using JETLS
using JETLS: JL, JS, select_target_node, method_definition_range,
             get_text_and_positions, xy_to_offset

function get_target_node(code::AbstractString, pos::Int)
    parsed_stream = JS.ParseStream(code)
    JS.parse!(parsed_stream; rule=:all)
    st = JS.build_tree(JL.SyntaxTree, parsed_stream)
    node = select_target_node(st, pos)
    return node
end

function get_target_node(code::AbstractString, matcher::Regex=r"│")
    clean_code, positions = get_text_and_positions(code, matcher)
    @assert length(positions) == 1
    return get_target_node(clean_code, xy_to_offset(Vector{UInt8}(clean_code), positions[1]))
end

@testset "select_target_node" begin
    let code = """
        test_│func(5)
        """

        node = get_target_node(code)
        @test (node !== nothing) && (JS.kind(node) === JS.K"Identifier")
        @test node.name_val == "test_func"
    end

    let code = """
        obj.│property = 42
        """

        node = get_target_node(code)
        @test node !== nothing
        @test JS.kind(node) === JS.K"."
        @test length(JS.children(node)) == 2
        @test JS.children(node)[1].name_val == "obj"
        @test JS.children(node)[2].name_val == "property"
    end

    let code = """
        function test_func(x)
            return x │ + 1
        end
        """

        node = get_target_node(code)
        @test node === nothing
    end

    let code = """
        │
        """
        node = get_target_node(code)
        @test node === nothing
    end
end

@testset "method_definition_range" begin
    linenum = @__LINE__; method_for_test_method_definition_range() = 1
    @assert length(methods(method_for_test_method_definition_range)) == 1

    test_method = first(methods(method_for_test_method_definition_range))
    method_range = method_definition_range(test_method)

    @test method_range isa JETLS.Location
    @test JETLS.URIs2.uri2filepath(method_range.uri) == @__FILE__
    @test method_range.range.start.line == (linenum - 1)
end

include("setup.jl")

@testset "go to definition request/responce cycle" begin
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
    """

    sin_cand_file, sin_cand_line = functionloc(first(methods(sin, (Float64,))))

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
                candidate.uri.path == sin_cand_file &&
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
    ]

    clean_code, positions = get_text_and_positions(script_code, r"│")
    @assert length(positions) == length(testers)

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
                    @test tester(raw_res.result, uri)
                end
            end
        end
    end
end

end # module test_definition
