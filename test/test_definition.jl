module test_definition

using Test
using JETLS
using JETLS: JL, JS, get_best_node, method_definition_range, definition_locations,
             get_text_and_positions, xy_to_offset


function get_target_node(code::AbstractString, pos::Int)
    parsed_stream = JS.ParseStream(code)
    JS.parse!(parsed_stream; rule=:all)
    st = JS.build_tree(JL.SyntaxTree, parsed_stream)
    node = get_best_node(st, pos)
    return node
end

function get_target_node(code::AbstractString, matcher::Regex=r"│")
    clean_code, positions = get_text_and_positions(code, matcher)
    @assert length(positions) == 1
    return get_target_node(clean_code, xy_to_offset(Vector{UInt8}(clean_code), positions[1]))
end

@testset "get_best_node" begin
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
    @test endswith(method_range.uri.path, PROGRAM_FILE)
    @test method_range.range.start.line == (linenum - 1)
end

include("setup.jl")

@testset "go to definition request/responce cycle" begin
    script_code = """
    func(x) = 1
    fu│nc(1.0)
    si│n(1.0)

    Co│re.Compiler.tmeet

    func(1.│0)
    sin(1.│0)

    module M
        m_func(x) = 1
        m_│func(1.0)
    end

    m_│func(1.0)
    M.m_│func(1.0)

    module M2
        m_func(x) = 1
        m_│func(1.0)
    end

    M2.m_│func(1.0)

    cos(x) = 1

    Base.co│s(x) = 1
    """

    sin_cand_file, sin_cand_line = functionloc(first(methods(sin, (Float64,))))

    testers = [
        # fu│nc(1.0)
        (result, uri) ->
            (length(result) == 1) &&
            (first(result).uri == uri) &&
            (first(result).range.start.line == 0),

        # si│n(x)
        (result, uri) ->
            (length(result) >= 1) &&
            (any(result) do candidate
                candidate.uri.path == sin_cand_file &&
                candidate.range.start.line == (sin_cand_line - 1)
            end),

        # Co│re.Compiler.tmeet
        (result, uri) ->
            (length(result) >= 1),

        # func(1.│0)
        (result, uri) -> (result === null),

        # sin(1.│0)
        (result, uri) -> (result === null),

        # m_│func(1.0) in module M
        (result, uri) ->
            (length(result) == 1) &&
            (first(result).uri == uri) &&
            (first(result).range.start.line == 6),

        # m_│func(1.0)
        (result, uri) -> (result === null),

        # M.m_│func(1.0)
        (result, uri) ->
            (length(result) == 1) &&
            (first(result).uri == uri) &&
            (first(result).range.start.line == 12),

        # m_│func(1.0) in module M2
        (result, uri) ->
            (length(result) == 1) &&
            (first(result).uri == uri) &&
            (first(result).range.start.line == 16),

        # M2.m_│func(1.0)
        (result, uri) ->
            (length(result) == 1) &&
            (first(result).uri == uri) &&
            (first(result).range.start.line == 18),

        # Base.co│s(x)
        (result, uri) ->
            (length(result) >= 1) &&
            (all(result) do candidate
                candidate.uri.path != uri # in `Base`, not `cos(x) = 1`
            end)
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

            for (pos, tester) in zip(positions, testers)
                let id = id_counter[] += 1
                    (; raw_res) = writereadmsg(DefinitionRequest(;
                        id,
                        params = DefinitionParams(;
                            textDocument = TextDocumentIdentifier(; uri),
                            position = pos)))
                    tester(raw_res.result, uri)
                end
            end
        end
    end
end

end # module test_definition
