module test_completions

using Test
using JETLS
using JETLS: JL, JS
using JETLS.LSP
using JETLS.URIs2

include("setup.jl")
include("jsjl_utils.jl")

global lowering_module::Module = Module()
function get_cursor_bindings(fi::JETLS.FileInfo, b::Int)
    st0 = fi.syntax_tree0
    cb = JETLS.cursor_bindings(st0, b, lowering_module)
    return isnothing(cb) ? [] : cb
end

function get_local_completions(s::AbstractString, b::Int)
    uri = JETLS.URIs2.filepath2uri(@__FILE__)
    fi = JETLS.FileInfo(#=version=#0, s, @__FILE__)
    return map(get_cursor_bindings(fi, b)) do ((bi, st, dist))
        JETLS.to_completion(bi, st, dist, uri, fi)
    end
end

# Test that completion vector contains CompletionItems with all of `expected`
# labels (with `kind` if provided).
# Note that completions are filtered on the client side, so we expect a completion
# for "x" in "let x = 1; abc|; end"
function cv_has(cs::Vector{CompletionItem}, expected; kind=nothing)
    cdict = Dict(zip(map(c -> c.label, cs), cs))
    for e in expected
        c = get(cdict, e, nothing)
        @test !isnothing(c)
        if !isnothing(kind) && !isnothing(c)
            @test JETLS.completion_is(c, kind)
        end
    end
end

# Test that completion vector does not contain any of `unexpected` labels.
function cv_nhas(cs::Vector{CompletionItem}, unexpected)
    cnames = Set(map(cs -> cs.label, cs))
    for ne in unexpected
        @test !(String(ne) in cnames)
    end
end

function with_completion(f, text::String; kwargs...)
    clean_code, positions = JETLS.get_text_and_positions(text; kwargs...)
    for (i, pos) in enumerate(positions)
        cv = get_local_completions(clean_code, JETLS.xy_to_offset(clean_code, pos, @__FILE__))
        f(i, cv)
    end
end

# shorthand for testing single cursor completion
function test_single_cv(
        code::String, expected::Vector{String};
        unexpected::Vector{String} = String[], kind = nothing,
        matcher::Regex = r"│", kwargs...
    )
    @assert count(matcher, code) == 1 "test_single_cv requires exactly one cursor marker"
    with_completion(code; matcher, kwargs...) do _, cv
        cv_has(cv, expected; kind)
        cv_nhas(cv, unexpected)
    end
end

@testset "sanity" begin
    snippets = [
        "let x = 1;                  │  end",
        "let; (y,(x,z)) = (2,(1,3))  │  end",
        "function f(x);              │  end",
        "function f(x...);           │  end",
        "function f(a::x) where x;   │  end",
        "let; global x;              │  end",
        "for x in 1:10;              │  end",
        "map([]) do x;               │  end",
        "(x ->                       │   1)",
    ]
    for code in snippets
        test_single_cv(code, ["x"])
    end
end

@testset "subtree lowering within modules" begin
    code = """
module M
    │
    export foo

    function foo(x)
        y = 1
        z = 2
        │
    end

    module M2
        function foo(a)
            b = 1
            c = 2
            │
        end
    end
end
"""
    cnt = 0
    with_completion(code) do i, cv
        if i == 1
            cv_nhas(cv, ["a", "b", "c", "x", "y", "z"])
            cnt += 1
        elseif i == 2
            cv_has(cv, ["x", "y", "z"], kind=:local)
            cv_nhas(cv, ["a", "b", "c"])
            cnt += 1
        elseif i == 3
            cv_has(cv, ["a", "b", "c"], kind=:local)
            cv_nhas(cv, ["x", "y", "z"])
            cnt += 1
        end
    end
    @test cnt == 3
end

@testset "nested and adjacent scopes" begin
    code = "let; let; x = 1;   end;        │ let;          end; end"; test_single_cv(code, String[], unexpected=["x"])
    code = "let; let; x = 1;   end;          let;        │ end; end"; test_single_cv(code, String[], unexpected=["x"])
    code = "let; let;        │ end; x = 1;   let;          end; end"; test_single_cv(code, String[], unexpected=["x"])
    code = "let; let;          end; x = 1;   let;        │ end; end"; test_single_cv(code, ["x"])
    code = "let; let;        │ end;          let; x = 1;   end; end"; test_single_cv(code, String[], unexpected=["x"])
    code = "let; let;          end;        │ let; x = 1;   end; end"; test_single_cv(code, String[], unexpected=["x"])
end

@testset "globals in local scope, shadowing" begin

    # global decl should be contained
    code = "function f(g); │ let;   global g;   end;   end"; test_single_cv(code, ["g"], kind=:argument)
    code = "function f(g);   let;   global g; │ end;   end"; test_single_cv(code, ["g"], kind=:global)
    code = "function f(g);   let;   global g;   end; │ end"; test_single_cv(code, ["g"], kind=:argument)
    # global doesn't follow the "before-the-cursor" rule
    code = "function f(g);   let; │ global g;   end;   end"; test_single_cv(code, ["g"], kind=:global)

    # local shadowing global
    code = """
function f()
    global g = 1; │
    let │
        let
            local g
            │
            let; │ end
        end
    end
end
"""

    cnt = 0
    with_completion(code) do i, cv
        if i == 1
            cv_has(cv, ["g"], kind=:global)
            cnt += 1
        elseif i == 2
            cv_has(cv, ["g"], kind=:global)
            cnt += 1
        elseif i == 3
            cv_has(cv, ["g"], kind=:local)
            cnt += 1
        elseif i == 4
            cv_has(cv, ["g"], kind=:local)
            cnt += 1
        end
    end
    @test cnt == 4

    # global/local decl below cursor
    code = """
function f(x)
    let
        │
        global x
        x = 1
        let
            x = 2 # otherwise we would filter this completion out
            │
            local x
            x
        end
    end
end
"""
    cnt = 0
    with_completion(code) do i, cv
        if i == 1
            cv_has(cv, ["x"], kind=:global)
            cnt += 1
        elseif i == 2
            # broken. JuliaLowering bug?
            # cv_has(cv, ["x"], kind=:local)
            cnt += 1
        end
    end
    @test cnt == 2
end

@testset "cursor in new symbol" begin
    # Don't suggest a symbol which appears for the first time right before the cursor
    code = "function f(); global g1; g2│; end"
    test_single_cv(code, ["g1"], unexpected=["g2"])
    code = "function f(); global g1; g│2; end"
    test_single_cv(code, ["g1"], unexpected=["g", "g2"])
    code = "function f(); global g1; │g2; end"
    test_single_cv(code, ["g1"], unexpected=["g2"])
end

# completion for code including macros
let code = """
    function foo(x)
        │
        return @inline typeof(x)
    end
    """
    test_single_cv(code, ["x"])
end

# local completion for incomplete code shouldn't crash
let code = """
    function fo│
    """
    @expect_jl_err test_single_cv(code, String[])
end
let # XXX somehow wrapping within `module A ... end` is necessary to get `xx` completion for this incomplete code
    code = """
    module A
    function foo(xx, y=x│)
    end
    """
    test_single_cv(code, ["xx"], kind=:local)
end

# get_completion_items
# ====================

function with_completion_request(
        tester::Function, text::AbstractString;
        context::Union{Nothing, CompletionContext} = nothing,
        full_analysis::Bool = false,
        kwargs...
    )
    clean_code, positions = JETLS.get_text_and_positions(text; kwargs...)

    withscript(clean_code) do script_path
        uri = filepath2uri(script_path)
        withserver() do (; writereadmsg, id_counter, server)
            if full_analysis
                (; raw_res) = writereadmsg(make_DidOpenTextDocumentNotification(uri, clean_code))
                @test raw_res isa PublishDiagnosticsNotification
                @test raw_res.params.uri == uri
            else
                JETLS.cache_file_info!(server.state, uri, 1, clean_code)
                JETLS.cache_saved_file_info!(server.state, uri, clean_code)
                JETLS.initiate_analysis_unit!(server, uri)
            end

            for (i, pos) in enumerate(positions)
                params = CompletionParams(;
                    textDocument = TextDocumentIdentifier(; uri),
                    position = pos,
                    context = context)
                (; raw_res) = writereadmsg(CompletionRequest(;
                        id = id_counter[] += 1,
                        params = params))
                tester(i, raw_res.result, uri)
            end
        end
    end
end

@testset "get_completion_items" begin
    program = """
     module Foo
        struct Bar
            x::Int
        end
        function getx(bar::Bar)
            out = bar.x
            │
            return out
        end

        macro weirdmacro(x::Symbol, v)
            name = Symbol(string(x, "_var"))
            return :(\$(esc(name)) = \$v; internal_to_macro = 1)
        end
        function foo(x)
            @weirdmacro y 1
            @timed from_timed = 1
            │ # show `y_var` ideally
            return @inline typeof(y_var)
        end

        baremodule ModuleCompletion
        const xxx = nothing
        end
        function dot_completion_test(xarg)
            ModuleCompletion.x│
        end

        function str_macro_test()
            tex│
        end
    end # module Foo
    """

    cnt = 0
    with_completion_request(program) do i, result, uri
        items = result.items
        if i == 1
            @test any(items) do item
                item.label == "bar"
            end
            @test any(items) do item
                item.label == "out"
            end
            @test any(items) do item
                item.label == "Bar"
            end
            @test any(items) do item
                item.label == "sin"
            end
            cnt += 1
        elseif i == 2
            @test any(items) do item
                item.label == "foo"
            end
            @test any(items) do item
                item.label == "x"
            end
            @test !any(items) do item
                item.label == "y"
            end
            @test any(items) do item
                item.label == "y_var"
            end
            @test any(items) do item
                item.label == "from_timed"
            end
            @test !any(items) do item
                contains(item.label, "internal_to_macro") ||
                    contains(item.label, "#")
            end
            cnt += 1
        elseif i == 3
            # `dot_completion_test`: dot-prefixed global completion
            xxxidx = findfirst(item->item.label=="xxx", items)
            @test !isnothing(xxxidx)
            coreidx = findfirst(item->item.label=="Core", items) # Core is still available for baremodule
            @test !isnothing(xxxidx)
            @test items[xxxidx].sortText < items[coreidx].sortText # prioritize showing names defined within the completion context module
            @test isnothing(findfirst(item->item.label=="getx", items))
            @test isnothing(findfirst(item->item.label=="foo", items))
            @test isnothing(findfirst(item->item.label=="xarg", items)) # local completion should be disabled
            cnt += 1
        elseif i == 4
            # `str_macro_test`: string macro case
            @test any(items) do item
                item.label == "text\"\"" &&
                item.data isa CompletionData && item.data.name == "@text_str"
            end
            cnt += 1
        end
    end
    @test cnt == 4
end

@testset "local completion for methods with `@nospecialize`" begin
    text = """
    function foo(@nospecialize(xxx), @nospecialize(yyy))
        y│
    end
    """

    context = CompletionContext(; triggerKind=CompletionTriggerKind.Invoked)
    cnt = 0
    with_completion_request(text; context) do i, result, uri
        items = result.items
        @test any(items) do item
            item.label == "yyy"
        end
        cnt += 1
    end
    @test cnt == 1
end

# completion for empty program should not crash
@testset "empty completion" begin
    let text = "│"
        cnt = 0
        with_completion_request(text) do i, result, uri
            items = result.items
            # should not crash and return something
            @test length(items) > 0
            cnt += 1
        end
        @test cnt == 1
    end

    let text = "\n\n\n│"
        cnt = 0
        with_completion_request(text) do i, result, uri
            items = result.items
            # should not crash and return something
            @test length(items) > 0
            cnt += 1
        end
        @test cnt == 1
    end
end

@testset "macro completion" begin
    # `@`-mark should trigger completion of macro names
    let text = """
        function foo(xxx, yyy)
            @│
        end
        """
        context = CompletionContext(;
            triggerKind=CompletionTriggerKind.TriggerCharacter,
            triggerCharacter="@")
        cnt = 0
        with_completion_request(text; context) do i, result, uri
            items = result.items
            @test any(items) do item
                item.label == "@nospecialize" &&
                item.textEdit.newText == "@nospecialize"
            end
            @test !any(items) do item
                item.label == "foo" || item.label == "xxx" || item.label == "yyy"
            end
            cnt += 1
        end
        @test cnt == 1
    end

    # completion for macro names
    let text = """
        function foo(xxx, yyy)
            @no│
        end
        """
        context = CompletionContext(; triggerKind=CompletionTriggerKind.Invoked)
        cnt = 0
        with_completion_request(text; context) do i, result, uri
            items = result.items
            @test any(items) do item
                item.label == "@nospecialize" &&
                item.textEdit.newText == "@nospecialize"
            end
            @test !any(items) do item
                item.label == "foo" || item.label == "xxx" || item.label == "yyy"
            end
            cnt += 1
        end
        @test cnt == 1
    end

    # completion within macro call context
    let text = """
        function foo(xxx, yyy)
            @nospecialize xxx y│
        end
        """
        context = CompletionContext(; triggerKind=CompletionTriggerKind.Invoked)
        cnt = 0
        with_completion_request(text; context) do i, result, uri
            items = result.items
            @test any(items) do item
                item.label == "yyy"
            end
            cnt += 1
        end
        @test cnt == 1
    end

    # allow `nospecia│` complete to `@nospecialize`
    let text = """
        function foo(xxx, yyy)
            nospecia│
        end
        """
        context = CompletionContext(; triggerKind=CompletionTriggerKind.Invoked)
        cnt = 0
        with_completion_request(text; context) do i, result, uri
            items = result.items
            @test any(items) do item
                item.label == "@nospecialize" &&
                item.textEdit.newText == "@nospecialize"
            end
            cnt += 1
        end
        @test cnt == 1
    end
end

# Latex&emoji
# ===========

function test_backslash_offset(code::String, expected_result)
    text, positions = JETLS.get_text_and_positions(code)
    @assert length(positions) == 1 "test_backslash_offset requires exactly one cursor marker"

    state = JETLS.ServerState()
    filename = abspath("test_backslash.jl")
    uri = filename2uri(filename)
    fi = JETLS.cache_file_info!(state, uri, 1, text)

    result = JETLS.get_backslash_offset(fi, positions[1])
    @test result == expected_result
    return result
end

@testset "get_backslash_offset" begin
    # Example 1: Current token is backslash
    let code = "\\│"
        test_backslash_offset(code, (1, false))
    end
    let code = "  \\│"
        test_backslash_offset(code, (sizeof("  \\"), false))
    end

    # Example 2: Previous token is backslash
    let code = "\\alpha│"
        test_backslash_offset(code, (1, false))
    end
    let code = "\\beta│"
        test_backslash_offset(code, (1, false))
    end
    let code = "  \\gamma│"
        test_backslash_offset(code, (sizeof("  \\"), false))
    end
    let code = "\\ │"
        test_backslash_offset(code, nothing)
    end
    let code = "\\  │"
        test_backslash_offset(code, nothing)
    end

    # Example 3: Backslash followed by colon, then cursor
    let code = "\\:│"
        test_backslash_offset(code, (1, true))
    end
    let code = "\\:a│"
        test_backslash_offset(code, (1, true))
    end
    let code = "\\:abc│"
        test_backslash_offset(code, (1, true))
    end
    let code = "  \\:test│"
        test_backslash_offset(code, (sizeof("  \\"), true))
    end

    # Example 4: No relevant backslash (should return nothing)
    let code = "abc│"
        test_backslash_offset(code, nothing)
    end
    let code = "│"
        test_backslash_offset(code, nothing)
    end
    let code = "│\\alpha"
        test_backslash_offset(code, nothing)
    end
    let code = "\\alpha beta│"
        test_backslash_offset(code, nothing)
    end
    let code = "\\alpha beta gamma│"
        test_backslash_offset(code, nothing)
    end
    let code = "\"\\alpha\"│"
        test_backslash_offset(code, nothing)
    end
    let code = "\\:a b│"
        test_backslash_offset(code, nothing)
    end

    # Multiple backslashes - should find the most recent one
    let code = "\\alpha \\beta│"
        test_backslash_offset(code, (sizeof("\\alpha \\"), false))
    end
    let code = "\\alpha \\beta \\gamma│"
        test_backslash_offset(code, (sizeof("\\alpha \\beta \\"), false))
    end

    # In various syntactic contexts
    let code = "f(\\alpha│)"
        test_backslash_offset(code, (sizeof("f(\\"), false))
    end
    let code = "[\\beta│]"
        test_backslash_offset(code, (sizeof("[\\"), false))
    end
    let code = "{\\gamma│}"
        test_backslash_offset(code, (sizeof("{\\"), false))
    end

    # With newlines
    let code = "x = 1\n\\alpha│"
        test_backslash_offset(code, (sizeof("x = 1\n\\"), false))
    end
    let code = "function f()\n    \\beta│\nend"
        test_backslash_offset(code, (sizeof("function f()\n    \\"), false))
    end

    # Complex expressions
    let code = "f(x) = x^2 + \\sigma│"
        test_backslash_offset(code, (sizeof("f(x) = x^2 + \\"), false))
    end
    let code = "result = compute(\\theta│, y)"
        test_backslash_offset(code, (sizeof("result = compute(\\"), false))
    end

    # LaTeX-like sequences
    let code = "\\alpha│"
        test_backslash_offset(code, (1, false))
    end
    let code = "\\sum│"
        test_backslash_offset(code, (1, false))
    end
    let code = "\\infty│"
        test_backslash_offset(code, (1, false))
    end
    let code = "\\mathbb│"
        test_backslash_offset(code, (1, false))
    end

    # Special colon cases
    let code = "\\:heart│"
        test_backslash_offset(code, (1, true))
    end
    let code = "\\:smile│"
        test_backslash_offset(code, (1, true))
    end
    let code = "\\:+1│"
        test_backslash_offset(code, (1, true))
    end

    # Unicode characters in code before backslash
    let code = "α = 1; \\beta│"
        test_backslash_offset(code, (sizeof("α = 1; \\"), false))
    end
    let code = "# 测试\n\\gamma│"
        test_backslash_offset(code, (sizeof("# 测试\n\\"), false))
    end

    # Boundary conditions
    let code = "\\│"
        test_backslash_offset(code, (1, false))
    end
    let code = "\\a│"
        test_backslash_offset(code, (1, false))
    end
    let code = "\\:│"
        test_backslash_offset(code, (1, true))
    end
    let code = "code; \\│"
        test_backslash_offset(code, (sizeof("code; \\"), false))
    end

    # Real-world usage patterns
    let code = "E = mc^2 + \\hbar│"
        test_backslash_offset(code, (sizeof("E = mc^2 + \\"), false))
    end
    let code = "function hermite(n, x)\n    return \\psi│\nend"
        test_backslash_offset(code, (sizeof("function hermite(n, x)\n    return \\"), false))
    end
    let code = "struct Particle\n    momentum::\\vec│\nend"
        test_backslash_offset(code, (sizeof("struct Particle\n    momentum::\\"), false))
    end
    let code = "[\\theta│ for i in 1:n]"
        test_backslash_offset(code, (sizeof("[\\"), false))
    end
    let code = "angle = \\phi│"
        test_backslash_offset(code, (sizeof("angle = \\"), false))
    end

    # within comment/string scope
    let code = "# this is a single line comment \\phi│"
        test_backslash_offset(code, (sizeof("# this is a single line comment \\"), false))
    end
    let code = "# this is a single line comment \\:│"
        test_backslash_offset(code, (sizeof("# this is a single line comment \\"), true))
    end
    let code = "#=\nthis is a multi line comment \\phi│\n=#"
        test_backslash_offset(code, (sizeof("#=\nthis is a multi line comment \\"), false))
    end
    let code = "\"\\phi│\""
        test_backslash_offset(code, (sizeof("\"\\"), false))
    end
end

@testset "Latex/emoji completion" begin
    # `\`-mark should trigger latex completion
    let text = """
        function foo(α, β)
            \\│
        end
        """
        context = CompletionContext(;
            triggerKind=CompletionTriggerKind.TriggerCharacter,
            triggerCharacter="\\")
        cnt = 0
        with_completion_request(text; context) do i, result, uri
            items = result.items
            @test any(items) do item
                item.label == "\\alpha"
            end
            @test !any(items) do item
                item.label == "foo" || # should not include global completions
                item.label == "β"      # should not include local completions
            end
            cnt += 1
        end
        @test cnt == 1
    end

    let text = """
        function foo(α, β)
            \\:│
        end
        """
        context = CompletionContext(;
            triggerKind=CompletionTriggerKind.TriggerCharacter,
            triggerCharacter=":")
        cnt = 0
        with_completion_request(text; context) do i, result, uri
            items = result.items
            @test any(items) do item
                item.label == "\\:pizza:"
            end
            @test !any(items) do item
                item.label == "foo" || # should not include global completions
                item.label == "α"   || # should not include local completions
                item.label == "β"   || # should not include local completions
                item.label == "alpha" # should not even include LaTeX completions
            end
            cnt += 1
        end
        @test cnt == 1
    end
end

end # module test_completions
