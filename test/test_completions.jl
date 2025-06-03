module test_completions

using Test
using JETLS
using JETLS: JL, JS
using JETLS: cursor_bindings, to_completion, CompletionItem, completion_is
using JETLS.LSP

function get_cursor_bindings(s::String, b::Int)
    ps = JS.ParseStream(s)
    JS.parse!(ps; rule=:all)
    st0 = JS.build_tree(JL.SyntaxTree, ps)
    return cursor_bindings(st0, b)
end

function get_local_completions(s::String, b::Int)
    return map(o->to_completion(o[1], o[2], o[3]), get_cursor_bindings(s, b))
end

function cv_has(cs::Vector{CompletionItem}, expected, kind=nothing)
    cdict = Dict(zip(map(c -> c.label, cs), cs))
    for e in expected
        c = get(cdict, e, nothing)
        @test !isnothing(c)
        if !isnothing(kind) && !isnothing(c)
            @test completion_is(c, kind)
        end
    end
end

function cvnhas(cs::Vector{CompletionItem}, not_expected)
    cnames = Set(map(cs -> cs.label, cs))
    for ne in not_expected
        @test !(String(ne) in cnames)
    end
end

"""
    test_cv(code, cursor, expected; kind::Symbol=nothing, not::Vector{String}=[])

Test that completion vector contains CompletionItems with all of `expected`
labels (with `kind` if provided) and none of the names in `not`.  `expected` and
`not` are whitespace-delimited strings.

The position in the code to request completions can be a byte offset or a cursor
string, which is searched for and deleted from the code.

Note that completions are filtered on the client side, so we expect a completion
for "x" in "let x = 1; abc|; end"
"""
function test_cv(code::String, cursor::String, expected::String=""; kwargs...)
    b = findfirst(cursor, code).start
    @assert !isnothing(b) "test_cv requires a cursor \"$cursor\" in code \"$code\""
    return test_cv(replace(code, cursor=>"", count=1), b, expected; kwargs...)
end
function test_cv(code::String,
                 b::Int,
                 expected::String="";
                 kind=nothing,
                 not::String="",)
    cv = get_local_completions(code, b)
    cv_has(cv, split(expected), kind)
    cvnhas(cv, split(not))
    return cv
end

@testset "sanity" begin
    snippets = [
        "let x = 1;                  |  end",
        "let; (y,(x,z)) = (2,(1,3))  |  end",
        "begin; x = 1;               |  end",
        "function f(x);              |  end",
        "function f(x...);           |  end",
        "function f(a::x) where x;   |  end",
        "let; global x;              |  end",
        "for x in 1:10;              |  end",
        "map([]) do x;               |  end",
        "(x ->                       |   1)",
    ]
    for code in snippets
        test_cv(code, "|", "x")
    end
end

@testset "subtree lowering within modules" begin
    code = """
module M
    #=1=#
    export foo

    function foo(x)
        y = 1
        z = 2
        #=2=#
    end

    module M2
        function foo(a)
            b = 1
            c = 2
            #=3=#
        end
    end
end
"""
    test_cv(code, "#=1=#", not="a b c x y z")
    test_cv(code, "#=2=#", "x y z", kind=:local, not="a b c")
    test_cv(code, "#=3=#", "a b c", kind=:local, not="x y z")
end

@testset "nested and adjacent scopes" begin
    code = "let; let; x = 1;   end;        | let;          end; end"; test_cv(code, "|", not="x")
    code = "let; let; x = 1;   end;          let;        | end; end"; test_cv(code, "|", not="x")
    code = "let; let;        | end; x = 1;   let;          end; end"; test_cv(code, "|", not="x")
    code = "let; let;          end; x = 1;   let;        | end; end"; test_cv(code, "|", "x")
    code = "let; let;        | end;          let; x = 1;   end; end"; test_cv(code, "|", not="x")
    code = "let; let;          end;        | let; x = 1;   end; end"; test_cv(code, "|", not="x")
end

@testset "globals in local scope, shadowing" begin

    # global decl should be contained
    code = "function f(g); | let;   global g;   end;   end"; test_cv(code, "|", "g", kind=:argument)
    code = "function f(g);   let;   global g; | end;   end"; test_cv(code, "|", "g", kind=:global)
    code = "function f(g);   let;   global g;   end; | end"; test_cv(code, "|", "g", kind=:argument)
    # global doesn't follow the "before-the-cursor" rule
    code = "function f(g);   let; | global g;   end;   end"; test_cv(code, "|", "g", kind=:global)

    # local shadowing global
    code = """
function f()
    global g = 1; #global1
    let #global2
        let
            local g
            #local1
            let; #=local2=# end
        end
    end
end
"""
    test_cv(code, "#global1", "g", kind=:global)
    test_cv(code, "#global2", "g", kind=:global)
    test_cv(code, "#local1", "g", kind=:local)
    test_cv(code, "#=local2=#", "g", kind=:local)

    # global/local decl below cursor
    code = """
function f(x)
    let
        #1
        global x
        x = 1
        let
            x = 2 # otherwise we would filter this completion out
            #2
            local x
            x
        end
    end
end
"""
    test_cv(code, "#1", "x", kind=:global)
    # broken. JuliaLowering bug?
    # test_cv(code, "#2", "x", kind=:local)
end

@testset "cursor in new symbol" begin
    # Don't suggest a symbol which appears for the first time right before the cursor
    code = "function f(); global g1; g2|; end"
    test_cv(code, "|", "g1", not="g2")
    code = "function f(); global g1; g|2; end"
    test_cv(code, "|", "g1", not="g g2")
end

# completion for code including macros
let code = """
    function foo(x)
        #=cursor=#
        return @inline typeof(x)
    end
    """
    test_cv(code, "#=cursor=#", "x")
end

# local completion for incomplete code shouldn't crash
let code = """
    function fo#=cursor=#
    """
    b = first(findfirst("#=cursor=#", code))
    @test get_cursor_bindings(code, b) === nothing
end
let # XXX somehow wrapping within `module A ... end` is necessary to get `xx` completion for this incomplete code
    s = """
    module A
    function foo(xx, y=x#=cursor=#)
    end
    """
    b = first(findfirst("#=cursor=#", s))
    test_cv(s, b, "xx", kind=:local)
end

# get_completion_items
# ====================

function get_text_and_positions(text::String, target::Regex=r"#=cursor=#")
    positions = JETLS.Position[]
    lines = split(text, '\n')

    # First pass: collect all positions without modifying text
    for (i, line) in enumerate(lines)
        offset = 0  # Track cumulative offset due to previous replacements in same line
        temp_line = line
        while true
            m = match(target, temp_line)
            if m === nothing
                break
            end
            # Position is 0-based, m.offset is 1-based
            char_pos = m.offset - 1 + offset
            push!(positions, JETLS.Position(; line=i-1, character=char_pos))

            # Remove this match and continue searching
            temp_line = temp_line[1:m.offset-1] * temp_line[m.offset+length(m.match):end]
            offset += m.offset - 1
        end
    end

    # Second pass: remove all target occurrences
    cleaned_text = replace(text, target => "")
    return cleaned_text, positions
end

@testset "get_completion_items" begin
    state = JETLS.ServerState()
    text, curpos2 = get_text_and_positions("""
    module Foo

        struct Bar
            x::Int
        end
        function getx(bar::Bar)
            out = bar.x
            #=cursor=#
            return out
        end

        macro weirdmacro(x::Symbol, v)
            name = Symbol(string(x, "_var"))
            return :(\$(esc(name)) = \$v)
        end
        function foo(x)
            @weirdmacro y 1
            #=cursor=# # show `y_var` ideally
            return @inline typeof(y_var)
        end
    end # module Foo
    """)
    @test length(curpos2) == 2
    pos1, pos2  = curpos2
    filename = abspath("foo.jl")
    uri = JETLS.filename2uri(filename)
    JETLS.cache_file_info!(state, uri, #=version=#1, text, filename)
    JETLS.initiate_context!(state, uri)
    let params = CompletionParams(;
            textDocument=TextDocumentIdentifier(string(uri)),
            position=pos1)
        items = JETLS.get_completion_items(state, uri, params)
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
    end
    let params = CompletionParams(;
            textDocument=TextDocumentIdentifier(string(uri)),
            position=pos2)
        items = JETLS.get_completion_items(state, uri, params)
        @test any(items) do item
            item.label == "foo"
        end
        @test any(items) do item
            item.label == "x"
        end
        @test !any(items) do item
            item.label == "y"
        end
        @test_broken any(items) do item
            item.label == "y_var"
        end
    end
end

# completion for empty program should not crash
@testset "empty completion" begin
    state = JETLS.ServerState()
    filename = "empty.jl"
    uri = JETLS.URI(filename)

    let text = ""
        JETLS.cache_file_info!(state, uri, 1, text, filename)
        params = CompletionParams(;
            textDocument=TextDocumentIdentifier(string(uri)),
            position=Position(;line=0,character=0))
        items = JETLS.get_completion_items(state, uri, params)
        # should not crash and return something
        @test length(items) > 0
    end

    let text = "\n \n \n"
        JETLS.cache_file_info!(state, uri, 2, text, filename)
        params = CompletionParams(;
            textDocument=TextDocumentIdentifier(string(uri)),
            position=Position(;line=3,character=0))
        items = JETLS.get_completion_items(state, uri, params)
        # should not crash and return something
        @test length(items) > 0
    end
end

@testset "macro completion" begin
    state = JETLS.ServerState()
    filename = "filename.jl"
    uri = JETLS.URI(filename)

    # `@`-mark should trigger completion of macro names
    let text = """
        function foo(xxx, yyy)
            @
        end
        """
        JETLS.cache_file_info!(state, uri, 1, text, filename)
        params = CompletionParams(;
            textDocument=TextDocumentIdentifier(string(uri)),
            position=Position(;line=1,character=5),
            context=CompletionContext(;
                triggerKind=CompletionTriggerKind.TriggerCharacter,
                triggerCharacter="@"))
        items = JETLS.get_completion_items(state, uri, params)
        @test any(items) do item
            item.label == "@nospecialize" &&
            item.insertText == "nospecialize"
        end
        @test !any(items) do item
            item.label == "foo" || item.label == "xxx" || item.label == "yyy"
        end
    end

    # completion for macro names
    let text = """
        function foo(xxx, yyy)
            @no
        end
        """
        JETLS.cache_file_info!(state, uri, 2, text, filename)
        params = CompletionParams(;
            textDocument=TextDocumentIdentifier(string(uri)),
            position=Position(;line=1,character=7),
            context=CompletionContext(;
                triggerKind=CompletionTriggerKind.Invoked))
        items = JETLS.get_completion_items(state, uri, params)
        @test any(items) do item
            item.label == "@nospecialize" &&
            item.filterText == "nospecialize" &&
            item.insertText == "nospecialize"
        end
        @test !any(items) do item
            item.label == "foo" || item.label == "xxx" || item.label == "yyy"
        end
    end

    # completion within macro call context
    let text = """
        function foo(xxx, yyy)
            @nospecialize xxx y
        end
        """
        JETLS.cache_file_info!(state, uri, 3, text, filename)
        params = CompletionParams(;
            textDocument=TextDocumentIdentifier(string(uri)),
            position=Position(;line=1,character=20),
            context=CompletionContext(;
                triggerKind=CompletionTriggerKind.Invoked))
        items = JETLS.get_completion_items(state, uri, params)
        @test any(items) do item
            item.label == "yyy"
        end
    end

    # allow `nospecia|` complete to `@nospecialize`
    let text = """
        function foo(xxx, yyy)
            nospecia
        end
        """
        JETLS.cache_file_info!(state, uri, 4, text, filename)
        params = CompletionParams(;
            textDocument=TextDocumentIdentifier(string(uri)),
            position=Position(;line=1,character=12),
            context=CompletionContext(;
                triggerKind=CompletionTriggerKind.Invoked))
        items = JETLS.get_completion_items(state, uri, params)
        @test any(items) do item
            item.label == "@nospecialize" &&
            item.filterText == "nospecialize" &&
            item.insertText == "@nospecialize" # NOTE that `@` is included here
        end
    end
end

# Latex&emoji
# ===========

function test_backslash_offset(code::String, expected_result)
    text, positions = get_text_and_positions(code, r"#=cursor=#")
    @assert length(positions) == 1 "test_backslash_offset requires exactly one cursor marker"

    state = JETLS.ServerState()
    filename = "test_backslash.jl"
    uri = JETLS.URI(filename)
    JETLS.cache_file_info!(state, uri, 1, text, filename)

    result = JETLS.get_backslash_offset(state, uri, positions[1])
    @test result == expected_result
    return result
end
@testset "get_backslash_offset" begin
    # Example 1: Current token is backslash
    let code = "\\#=cursor=#"
        test_backslash_offset(code, (1, false))
    end
    let code = "  \\#=cursor=#"
        test_backslash_offset(code, (ncodeunits("  \\"), false))
    end

    # Example 2: Previous token is backslash
    let code = "\\alpha#=cursor=#"
        test_backslash_offset(code, (1, false))
    end
    let code = "\\beta#=cursor=#"
        test_backslash_offset(code, (1, false))
    end
    let code = "  \\gamma#=cursor=#"
        test_backslash_offset(code, (ncodeunits("  \\"), false))
    end
    let code = "\\ #=cursor=#"
        test_backslash_offset(code, nothing)
    end
    let code = "\\  #=cursor=#"
        test_backslash_offset(code, nothing)
    end

    # Example 3: Backslash followed by colon, then cursor
    let code = "\\:#=cursor=#"
        test_backslash_offset(code, (1, true))
    end
    let code = "\\:a#=cursor=#"
        test_backslash_offset(code, (1, true))
    end
    let code = "\\:abc#=cursor=#"
        test_backslash_offset(code, (1, true))
    end
    let code = "  \\:test#=cursor=#"
        test_backslash_offset(code, (ncodeunits("  \\"), true))
    end

    # Example 4: No relevant backslash (should return nothing)
    let code = "abc#=cursor=#"
        test_backslash_offset(code, nothing)
    end
    let code = "#=cursor=#"
        test_backslash_offset(code, nothing)
    end
    let code = "#=cursor=#\\alpha"
        test_backslash_offset(code, nothing)
    end
    let code = "\\alpha beta#=cursor=#"
        test_backslash_offset(code, nothing)
    end
    let code = "\\alpha beta gamma#=cursor=#"
        test_backslash_offset(code, nothing)
    end
    let code = "\"\\alpha\"#=cursor=#"
        test_backslash_offset(code, nothing)
    end
    let code = "\\:a b#=cursor=#"
        test_backslash_offset(code, nothing)
    end

    # Multiple backslashes - should find the most recent one
    let code = "\\alpha \\beta#=cursor=#"
        test_backslash_offset(code, (ncodeunits("\\alpha \\"), false))
    end
    let code = "\\alpha \\beta \\gamma#=cursor=#"
        test_backslash_offset(code, (ncodeunits("\\alpha \\beta \\"), false))
    end

    # In various syntactic contexts
    let code = "f(\\alpha#=cursor=#)"
        test_backslash_offset(code, (ncodeunits("f(\\"), false))
    end
    let code = "[\\beta#=cursor=#]"
        test_backslash_offset(code, (ncodeunits("[\\"), false))
    end
    let code = "{\\gamma#=cursor=#}"
        test_backslash_offset(code, (ncodeunits("{\\"), false))
    end

    # With newlines
    let code = "x = 1\n\\alpha#=cursor=#"
        test_backslash_offset(code, (ncodeunits("x = 1\n\\"), false))
    end
    let code = "function f()\n    \\beta#=cursor=#\nend"
        test_backslash_offset(code, (ncodeunits("function f()\n    \\"), false))
    end

    # Complex expressions
    let code = "f(x) = x^2 + \\sigma#=cursor=#"
        test_backslash_offset(code, (ncodeunits("f(x) = x^2 + \\"), false))
    end
    let code = "result = compute(\\theta#=cursor=#, y)"
        test_backslash_offset(code, (ncodeunits("result = compute(\\"), false))
    end

    # LaTeX-like sequences
    let code = "\\alpha#=cursor=#"
        test_backslash_offset(code, (1, false))
    end
    let code = "\\sum#=cursor=#"
        test_backslash_offset(code, (1, false))
    end
    let code = "\\infty#=cursor=#"
        test_backslash_offset(code, (1, false))
    end
    let code = "\\mathbb#=cursor=#"
        test_backslash_offset(code, (1, false))
    end

    # Special colon cases
    let code = "\\:heart#=cursor=#"
        test_backslash_offset(code, (1, true))
    end
    let code = "\\:smile#=cursor=#"
        test_backslash_offset(code, (1, true))
    end
    let code = "\\:+1#=cursor=#"
        test_backslash_offset(code, (1, true))
    end

    # Unicode characters in code before backslash
    let code = "α = 1; \\beta#=cursor=#"
        test_backslash_offset(code, (ncodeunits("α = 1; \\"), false))
    end
    let code = "# 测试\n\\gamma#=cursor=#"
        test_backslash_offset(code, (ncodeunits("# 测试\n\\"), false))
    end

    # Boundary conditions
    let code = "\\#=cursor=#"
        test_backslash_offset(code, (1, false))
    end
    let code = "\\a#=cursor=#"
        test_backslash_offset(code, (1, false))
    end
    let code = "\\:#=cursor=#"
        test_backslash_offset(code, (1, true))
    end
    let code = "code; \\#=cursor=#"
        test_backslash_offset(code, (ncodeunits("code; \\"), false))
    end

    # Real-world usage patterns
    let code = "E = mc^2 + \\hbar#=cursor=#"
        test_backslash_offset(code, (ncodeunits("E = mc^2 + \\"), false))
    end
    let code = "function hermite(n, x)\n    return \\psi#=cursor=#\nend"
        test_backslash_offset(code, (ncodeunits("function hermite(n, x)\n    return \\"), false))
    end
    let code = "struct Particle\n    momentum::\\vec#=cursor=#\nend"
        test_backslash_offset(code, (ncodeunits("struct Particle\n    momentum::\\"), false))
    end
    let code = "[\\theta#=cursor=# for i in 1:n]"
        test_backslash_offset(code, (ncodeunits("[\\"), false))
    end
    let code = "angle = \\phi#=cursor=#"
        test_backslash_offset(code, (ncodeunits("angle = \\"), false))
    end
end

@testset "Latex/emoji completion" begin
    state = JETLS.ServerState()
    filename = "test_latex_emoji.jl"
    uri = JETLS.URI(filename)

    # `\`-mark should trigger latex completion
    let text = """
        function foo(α, β)
            \\
        end
        """
        JETLS.cache_file_info!(state, uri, 1, text, filename)
        params = CompletionParams(;
            textDocument=TextDocumentIdentifier(string(uri)),
            position=Position(;line=1,character=5),
            context=CompletionContext(;
                triggerKind=CompletionTriggerKind.TriggerCharacter,
                triggerCharacter="\\"))
        items = JETLS.get_completion_items(state, uri, params)
        @test any(items) do item
            item.label == "alpha" &&
            item.sortText == "alpha"
        end
        @test !any(items) do item
            item.label == "foo" || # should not include global completions
            item.label == "β"      # should not include local completions
        end
    end

    let text = """
        function foo(α, β)
            \\:
        end
        """
        JETLS.cache_file_info!(state, uri, 2, text, filename)
        params = CompletionParams(;
            textDocument=TextDocumentIdentifier(string(uri)),
            position=Position(;line=1,character=6),
            context=CompletionContext(;
                triggerKind=CompletionTriggerKind.TriggerCharacter,
                triggerCharacter=":"))
        items = JETLS.get_completion_items(state, uri, params)
        @test any(items) do item
            item.label == ":pizza:" &&
            item.sortText == "pizza"
        end
        @test !any(items) do item
            item.label == "foo" || # should not include global completions
            item.label == "α"   || # should not include local completions
            item.label == "β"   || # should not include local completions
            item.label == "alpha" # should not even include LaTeX completions
        end
    end
end

end # module test_completions
