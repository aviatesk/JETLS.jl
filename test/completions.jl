using Test
using JETLS: JL, JS
using JETLS: cursor_bindings, to_completion, CompletionItem, completion_is

function get_local_completions(s::String, b::Int)
    ps = JS.ParseStream(s)
    JS.parse!(ps; rule=:all)
    st0 = JS.build_tree(JL.SyntaxTree, ps)

    out = cursor_bindings(st0, b)
    # @info out
    map(o->to_completion(o[1], o[2], o[3]), out)
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

# unit tests including local/global completions
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

let state = JETLS.ServerState(identity)
    text, curpos1 = get_text_and_positions("""module Foo
    struct Bar
        x::Int
    end
    function getx(bar::Bar)
        out = bar.x
        #=cursor=#
        return out
    end

    nothing # TODO remove this line when the correct implementation of https://github.com/aviatesk/JET.jl/pull/707 is available
end
""")
    @test length(curpos1) == 1
    pos = only(curpos1)
    filename = abspath("foo.jl")
    uri = JETLS.filename2uri(filename)
    JETLS.cache_file_info!(state, uri, #=version=#1, text, filename)
    JETLS.initiate_context!(state, uri)
    # XXX `@invokelatest` is required for `names` to return all the symbols of the `Foo`, in particular `:Bar`
    items = @invokelatest JETLS.get_completion_items(state, uri, pos)
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
