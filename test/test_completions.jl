module test_completions

using Test
using JETLS
using JETLS: JL, JS
using JETLS: cursor_bindings, to_completion, CompletionItem, completion_is

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

function get_text_and_positions(text::String)
    positions = JETLS.Position[]
    lines = split(text, '\n')
    for (i, line) in enumerate(lines)
        for m in eachmatch(r"#=cursor=#", line)
            # Position is 0-based
            push!(positions, JETLS.Position(; line=i-1, character=m.match.offset-1))
            lines[i] = replace(line, r"#=cursor=#" => "")
        end
    end
    return join(lines, '\n'), positions
end

@testset "get_completion_items" begin
    state = JETLS.ServerState(identity)
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
    let items = JETLS.get_completion_items(state, uri, pos1)
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
    let items = @invokelatest JETLS.get_completion_items(state, uri, pos2)
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

end # module test_completions
