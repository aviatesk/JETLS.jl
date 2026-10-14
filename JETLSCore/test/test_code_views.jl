module test_code_views

using Test
using JETLS
using JETLS: JS
using JETLS.LSP
using JETLS.LSP.URIs2

function server_with_show_document_support(; kwargs...)
    server = JETLS.Server(; kwargs...)
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

function toplevel_expansion_testcase(text::AbstractString)
    server = server_with_show_document_support()
    uri = filepath2uri(joinpath(pkgdir(JETLS), "test", "macroexpand_testcase.jl"))
    fi = JETLS.cache_file_info!(server, uri, 1, text)
    st0 = JETLS.build_syntax_tree(fi)
    tree = @something JETLS.lowerable_toplevel_at(st0, 1) error("missing toplevel tree")
    content_uri = JETLS.macro_expansion_content_uri(uri, tree; toplevel=true)
    return (; server, uri, fi, tree, content_uri)
end

function notebook_testcase(cell_texts::Vector{String})
    recorder = JETLS.ServerMessageRecorder()
    server = server_with_show_document_support(; callback = recorder)
    state = server.state
    notebook_uri = URI("file:///code-views.ipynb")
    cells = JETLS.NotebookCellInfo[
        JETLS.NotebookCellInfo(
            URI("vscode-notebook-cell:/code-views.ipynb#W$(i)sZmlsZQ%3D%3D"),
            NotebookCellKind.Code, 1, text)
        for (i, text) in enumerate(cell_texts)]
    concat = JETLS.concatenate_cells(cells)
    notebook = JETLS.NotebookInfo(1, "jupyter-notebook", state.encoding, cells, concat)
    JETLS.store!(state.notebook_cache) do cache
        Base.PersistentDict(cache, notebook_uri => notebook), nothing
    end
    JETLS.store!(state.cell_to_notebook) do cache
        for cell in cells
            cache = Base.PersistentDict(cache, cell.uri => notebook_uri)
        end
        cache, nothing
    end
    fi = JETLS.cache_notebook_file_info!(server, notebook_uri, notebook)
    return (; server, recorder, notebook_uri, cells, fi)
end

function type_annotation_testcase(text::AbstractString; offset::Int = 1)
    server = server_with_show_document_support()
    uri = filepath2uri(joinpath(pkgdir(JETLS), "test", "annotate_testcase.jl"))
    fi = JETLS.cache_file_info!(server, uri, 1, text)
    st0 = JETLS.build_syntax_tree(fi)
    tree = @something JETLS.lowerable_toplevel_at(st0, offset) error("missing toplevel tree")
    content_uri = JETLS.type_annotation_content_uri(uri, tree)
    return (; server, uri, fi, tree, content_uri)
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
    case = macroexpand_testcase("@time 1 + 2\n")
    actions = Union{CodeAction,Command}[]
    range = Range(;
        start = Position(; line = 0, character = 1),
        var"end" = Position(; line = 0, character = 1))
    JETLS.macro_expansion_code_actions!(
        actions, case.server, case.uri, case.fi, range)
    titles = String[a.title for a in actions]
    # the call-site action targets the `@time` macrocall
    callsite = actions[findfirst(==("Show macro expansion for `@time`"), titles)]
    @test callsite.kind === nothing
    @test callsite.command.command == JETLS.COMMAND_OPEN_MACRO_EXPANSION
    @test only(callsite.command.arguments) == string(case.content_uri)
    # the whole-form action is also offered, since the form contains a macro
    @test "Expand all macros in this top-level form" in titles
end

@testset "toplevel macro expansion content" begin
    case = toplevel_expansion_testcase("function f()\n    @assert false\nend\n")
    content_uri = JETLS.URI(string(case.content_uri))
    params = JETLS.parse_text_document_content_query(content_uri)
    @test params["mode"] == "toplevel"
    @test params["source"] == string(case.uri)

    text = JETLS.macro_expansion_text(case.server, content_uri)
    @test occursin("All macros expanded", text)
    @test occursin("macroexpand_testcase.jl:1", text)
    @test !occursin("the macro call being expanded", text) # no per-call provenance
    # the nested `@assert` is recursively expanded away
    @test occursin("AssertionError", text)
    @test !occursin("@assert", text)
end

@testset "toplevel macro expansion code action" begin
    full_range() = Range(;
        start = Position(; line = 0, character = 0),
        var"end" = Position(; line = 0, character = 0))
    # offered when the enclosing top-level form contains a macrocall
    let case = toplevel_expansion_testcase("function f()\n    @assert false\nend\n")
        actions = Union{CodeAction,Command}[]
        JETLS.macro_expansion_code_actions!(
            actions, case.server, case.uri, case.fi, full_range())
        titles = String[a.title for a in actions]
        action = actions[findfirst(==("Expand all macros in this top-level form"), titles)]
        @test action.command.command == JETLS.COMMAND_OPEN_MACRO_EXPANSION
        @test only(action.command.arguments) == string(case.content_uri)
    end
    # not offered when the form has no macrocalls
    let case = toplevel_expansion_testcase("function f()\n    return 1\nend\n")
        actions = Union{CodeAction,Command}[]
        JETLS.macro_expansion_code_actions!(
            actions, case.server, case.uri, case.fi, full_range())
        @test isempty(actions)
    end
end

@testset "macro expansion: suppress `@doc` docstring" begin
    server = server_with_show_document_support()
    uri = filepath2uri(joinpath(pkgdir(JETLS), "test", "macroexpand_testcase.jl"))
    fi = JETLS.cache_file_info!(server, uri, 1,
        """
        \"\"\"
        doc
        \"\"\"
        f(x) = @assert x > 0
        """)
    has_callsite(actions) = any(a -> startswith(a.title, "Show macro expansion"), actions)
    # cursor in the docstring: the enclosing macrocall is `@doc`, which is skipped
    let actions = Union{CodeAction,Command}[]
        range = Range(; start = Position(; line = 1, character = 2),
                        var"end" = Position(; line = 1, character = 2))
        JETLS.macro_expansion_code_actions!(actions, server, uri, fi, range)
        @test !has_callsite(actions)
    end
    # cursor on the `function` keyword: only the whole-form action, not `@doc`
    let actions = Union{CodeAction,Command}[]
        range = Range(; start = Position(; line = 3, character = 0),
                        var"end" = Position(; line = 3, character = 0))
        JETLS.macro_expansion_code_actions!(actions, server, uri, fi, range)
        titles = String[a.title for a in actions]
        @test "Expand all macros in this top-level form" in titles
        @test !has_callsite(actions)
    end
end

@testset "type annotation content" begin
    let case = type_annotation_testcase("function f(a, b)\n    return a + b\nend\n")
        content_uri = JETLS.URI(string(case.content_uri))
        params = JETLS.parse_text_document_content_query(content_uri)
        @test params["source"] == string(case.uri)

        text = JETLS.type_annotation_text(case.server, content_uri)
        @test occursin("Inferred type annotations", text)
        @test occursin("annotate_testcase.jl:1", text)
        # the original source is preserved; annotations are spliced in additively
        @test occursin("function f(a, b)", text)
        # untyped parameters infer to `Any`, applied as `::Any`
        @test occursin("::Any", text)
    end

    let case = type_annotation_testcase("@__undefined_macro_for_test__ xyz\n")
        content_uri = JETLS.URI(string(case.content_uri))
        text = JETLS.type_annotation_text(case.server, content_uri)
        @test occursin("Failed to infer type annotations", text)
        @test occursin("annotate_testcase.jl:1", text)
        @test occursin("@__undefined_macro_for_test__ xyz", text)
    end
end

@testset "type annotation code action" begin
    full_range() = Range(;
        start = Position(; line = 0, character = 0),
        var"end" = Position(; line = 0, character = 0))
    let case = type_annotation_testcase("function f(a, b)\n    return a + b\nend\n")
        actions = Union{CodeAction,Command}[]
        JETLS.type_annotation_code_actions!(
            actions, case.server, case.uri, case.fi, full_range())
        titles = String[a.title for a in actions]
        action = actions[findfirst(==("Show inferred type annotations"), titles)]
        @test action.command.command == JETLS.COMMAND_OPEN_TYPE_ANNOTATION
        @test only(action.command.arguments) == string(case.content_uri)
    end
    # Skip type annotation code action for docstrings
    let case = type_annotation_testcase(
            "\"\"\"\ndoc\n\"\"\"\nf(x) = x + 1\n"; offset=5)
        let actions = Union{CodeAction,Command}[]
            range = Range(;
                start = Position(; line = 1, character = 1),
                var"end" = Position(; line = 1, character = 1))
            JETLS.type_annotation_code_actions!(
                actions, case.server, case.uri, case.fi, range)
            @test isempty(actions)
        end
        let actions = Union{CodeAction,Command}[]
            range = Range(;
                start = Position(; line = 3, character = 0),
                var"end" = Position(; line = 3, character = 0))
            JETLS.type_annotation_code_actions!(
                actions, case.server, case.uri, case.fi, range)
            @test "Show inferred type annotations" in String[a.title for a in actions]
        end
    end
    # not offered on declaration forms with no inferable values
    for code in ("using Base\n", "import Base: map\n", "export foo, bar\n",
                 "public baz\n", "abstract type A end\n", "primitive type P 8 end\n")
        case = type_annotation_testcase(code)
        actions = Union{CodeAction,Command}[]
        JETLS.type_annotation_code_actions!(
            actions, case.server, case.uri, case.fi, full_range())
        @test isempty(actions)
    end
    # still offered on `struct` (inner constructors have inferable bodies)
    let case = type_annotation_testcase(
            "struct Point\n    x::Int\n    Point(x::Int) = new(x + 1)\nend\n")
        actions = Union{CodeAction,Command}[]
        JETLS.type_annotation_code_actions!(
            actions, case.server, case.uri, case.fi, full_range())
        @test "Show inferred type annotations" in String[a.title for a in actions]
    end
end

@testset "notebook code views" begin
    case = notebook_testcase(String[
        "x = 1\ny = 2",
        "function f(a, b)\n    @assert a > 0\n    return a + b\nend"])
    (; server, recorder, cells, fi) = case
    cell2 = cells[2].uri
    cell2_offset = JETLS.xy_to_offset(fi,
        JETLS.adjust_position(server.state, cell2, Position(; line = 0, character = 0)))
    st0 = JETLS.build_syntax_tree(fi)
    tree = @something JETLS.lowerable_toplevel_at(st0, cell2_offset) error("missing toplevel tree")
    @test first(JS.byte_range(tree)) == cell2_offset

    # The request range is cell-local; the offered views must target the form in cell 2,
    # not whatever occupies the same lines at the start of the notebook.
    msg = CodeActionRequest(; id = 1, params = CodeActionParams(;
        textDocument = TextDocumentIdentifier(; uri = cell2),
        range = Range(;
            start = Position(; line = 0, character = 0),
            var"end" = Position(; line = 0, character = 0)),
        context = CodeActionContext(; diagnostics = Diagnostic[])))
    JETLS.handle_CodeActionRequest(server, msg, JETLS.DUMMY_CANCEL_FLAG)
    response = take!(recorder.sent_queue)
    @test response isa CodeActionResponse
    titles = String[a.title for a in response.result]
    let action = response.result[findfirst(==("Show inferred type annotations"), titles)]
        @test only(action.command.arguments) ==
            string(JETLS.type_annotation_content_uri(cell2, tree))
    end
    let action = response.result[findfirst(==("Expand all macros in this top-level form"), titles)]
        @test only(action.command.arguments) ==
            string(JETLS.macro_expansion_content_uri(cell2, tree; toplevel=true))
    end

    # The content is produced from the notebook document the cell belongs to.
    let content_uri = JETLS.URI(string(JETLS.type_annotation_content_uri(cell2, tree)))
        params = JETLS.parse_text_document_content_query(content_uri)
        @test URI(params["source"]) == cell2
        text = JETLS.type_annotation_text(server, content_uri)
        @test occursin("Inferred type annotations", text)
        @test occursin("function f(a, b)", text)
        @test occursin("::Any", text)
    end
    let content_uri = JETLS.URI(string(JETLS.macro_expansion_content_uri(cell2, tree; toplevel=true)))
        text = JETLS.macro_expansion_text(server, content_uri)
        @test occursin("All macros expanded", text)
        @test occursin("AssertionError", text)
        @test !occursin("@assert", text)
    end
end

end # module test_code_views
