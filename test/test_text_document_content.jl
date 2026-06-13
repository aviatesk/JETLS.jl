module test_text_document_content

using Test
using JETLS
using JETLS.LSP
using JETLS.LSP.URIs2

function server_with_show_document_support()
    server = JETLS.Server()
    capabilities = ClientCapabilities(;
        window = WindowClientCapabilities(;
            showDocument = ShowDocumentClientCapabilities(; support = true)))
    server.state.init_params = InitializeParams(;
        processId = nothing,
        rootUri = nothing,
        capabilities)
    return server
end

function macroexpand_testcase(text::AbstractString)
    server = server_with_show_document_support()
    uri = filepath2uri(joinpath(pkgdir(JETLS), "test", "macroexpand_testcase.jl"))
    fi = JETLS.cache_file_info!(server, uri, 1, text)
    st0 = JETLS.build_syntax_tree(fi)
    macrocall = @something JETLS.macrocall_at_range(st0, 1:1) error("missing macrocall")
    content_uri = JETLS.macro_expansion_content_uri(uri, macrocall)
    return (; server, uri, fi, macrocall, content_uri)
end

@testset "macro expansion content" begin
    let case = macroexpand_testcase("@time 1 + 2\n")
        content_uri = JETLS.URI(string(case.content_uri))
        params = JETLS.parse_text_document_content_query(content_uri)
        @test params["source"] == string(case.uri)
        @test params["start"] == "1"
        @test params["stop"] == "11"

        text = JETLS.macro_expansion_text(case.server, content_uri)
        @test occursin("# Macro call:", text)
        @test occursin("@time 1 + 2", text)
        @test occursin("└─────────┘ ── the macro call being expanded", text)
        @test occursin("macroexpand_testcase.jl:1", text)
        @test occursin("# Expanded code view:", text)
        @test occursin("@time nothing", text)
        @test occursin("Expr(:escape, :(1 + 2))", text)
    end

    let case = macroexpand_testcase("@unexisting_macro 1\n")
        content_uri = JETLS.URI(string(case.content_uri))
        text = JETLS.macro_expansion_text(case.server, content_uri)
        @test occursin("# Macro call:", text)
        @test occursin("@unexisting_macro 1", text)
        @test occursin("└─────────────────┘ ── the macro call being expanded", text)
        @test occursin("# Expansion error trace:", text)
        @test occursin("UndefVarError", text)
        @test occursin("@unexisting_macro", text)
        @test !occursin("# Expanded code view:", text)
    end
end

@testset "simplify_macro_expansion!" begin
    # `GlobalRef`s to the context module collapse to bare symbols; a non-exported
    # `Base` name (`bar`) stays qualified.
    ex = Expr(:call, GlobalRef(Main, :foo), GlobalRef(Base, :bar), 1)
    JETLS.simplify_macro_expansion!(ex, Main)
    @test ex.args[1] === :foo
    @test ex.args[2] === GlobalRef(Base, :bar)
    @test ex.args[3] === 1

    # exported `Base`/`Core` names also collapse, regardless of context module
    @test JETLS.simplify_macro_expansion!(GlobalRef(Base, :println), Main) === :println
    @test JETLS.simplify_macro_expansion!(GlobalRef(Core, :throw), Main) === :throw
    # non-exported `Base`/`Core` names stay qualified
    @test JETLS.simplify_macro_expansion!(GlobalRef(Core, :Intrinsics), Main) === GlobalRef(Core, :Intrinsics)

    # recurses into nested expressions
    nested = Expr(:block, Expr(:call, GlobalRef(Main, :g)))
    JETLS.simplify_macro_expansion!(nested, Main)
    @test nested.args[1].args[1] === :g

    # also handles a top-level `GlobalRef`
    @test JETLS.simplify_macro_expansion!(GlobalRef(Main, :h), Main) === :h
    @test JETLS.simplify_macro_expansion!(GlobalRef(Base, :bar), Main) === GlobalRef(Base, :bar)
end

@testset "strip_macro_expansion_linenums!" begin
    # standalone line nodes in block bodies are dropped
    blk = Expr(:block, LineNumberNode(1, :f), :a, LineNumberNode(2, :f), :b)
    JETLS.strip_macro_expansion_linenums!(blk)
    @test blk.args == [:a, :b]

    # a macro call's location node (arg 2) is cleared, but the slot is kept
    mc = Expr(:macrocall, Symbol("@m"), LineNumberNode(3, :f), :x)
    JETLS.strip_macro_expansion_linenums!(mc)
    @test mc.args[2] === nothing
    @test mc.args[3] === :x

    # recurses into nested quoted expressions
    q = QuoteNode(Expr(:block, LineNumberNode(4, :f), :z))
    JETLS.strip_macro_expansion_linenums!(q)
    @test q.value.args == [:z]
end

@testset "macro expansion code action" begin
    let case = macroexpand_testcase("@time 1 + 2\n")
        actions = Union{CodeAction,Command}[]
        range = Range(;
            start = Position(; line = 0, character = 1),
            var"end" = Position(; line = 0, character = 1))
        JETLS.macro_expansion_code_actions!(
            actions, case.server, case.uri, case.fi, range)
        @test length(actions) == 1
        action = only(actions)
        @test action.title == "Show macro expansion for `@time`"
        @test action.kind === nothing
        @test action.command.command == JETLS.COMMAND_OPEN_MACRO_EXPANSION
        @test only(action.command.arguments) == string(case.content_uri)
    end
end

end # module test_text_document_content
