module test_inlay_hint

using Test
using JETLS
using JETLS.LSP

include(normpath(pkgdir(JETLS), "test", "setup.jl"))
include(normpath(pkgdir(JETLS), "test", "jsjl-utils.jl"))

# Inserts each `hint.label` at its `position` in `code` and returns the
# resulting text, mirroring how an editor renders the hint (honouring
# `paddingLeft` / `paddingRight`). ASCII-only — LSP `Position.character` is
# treated as a byte index into the line. Hints on the same position are
# inserted in their original (traversal) order.
function apply_inlay_hints(code::AbstractString, hints::Vector{InlayHint})
    by_line = Dict{Int,Vector{InlayHint}}()
    for h in hints
        push!(get!(() -> InlayHint[], by_line, h.position.line), h)
    end
    out = IOBuffer()
    lines = split(code, '\n'; keepempty=true)
    for (i, line) in enumerate(lines)
        s = String(line)
        line_hints = sort(get(by_line, i-1, InlayHint[]); by = h -> h.position.character)
        cursor = 0
        for h in line_hints
            c = h.position.character
            print(out, s[cursor+1:c])
            something(h.paddingLeft, false) && print(out, ' ')
            print(out, h.label)
            something(h.paddingRight, false) && print(out, ' ')
            cursor = c
        end
        print(out, s[cursor+1:end])
        i < length(lines) && print(out, '\n')
    end
    return String(take!(out))
end

function get_syntactic_inlay_hints(
        code::AbstractString;
        range::Union{Range,Nothing} = nothing,
        min_lines::Int = 0,
    )
    fi = JETLS.FileInfo(1, code, @__FILE__)
    if range === nothing
        n_lines = count(==('\n'), code)
        range = Range(;
            start = Position(; line = 0, character = 0),
            var"end" = Position(; line = n_lines, character = 0))
    end
    return JETLS.syntactic_inlay_hints(fi, range; min_lines)
end

@testset "block end hints" begin
    @testset "modules" begin
        let code = """
            module TestModule
            x = 1
            end
            """
            expected = """
            module TestModule
            x = 1
            end #= module TestModule =#
            """
            @test apply_inlay_hints(code, get_syntactic_inlay_hints(code)) == expected
        end

        # `end # module TestModule` already names the block, so the hint is
        # suppressed (source round-trips unchanged).
        let code = """
            module TestModule
            x = 1
            y = 2
            end # module TestModule
            """
            @test apply_inlay_hints(code, get_syntactic_inlay_hints(code)) == code
        end

        # `#= module TestModule =#` block-comment form is also recognized.
        let code = """
            module TestModule
            x = 1
            end #= module TestModule =#
            """
            @test apply_inlay_hints(code, get_syntactic_inlay_hints(code)) == code
        end

        @testset "one-liner modules" begin
            let code = """
                module TestModule end
                """
                @test apply_inlay_hints(code, get_syntactic_inlay_hints(code)) == code
            end
        end

        @testset "nested modules" begin
            let code = """
                module Outer
                module Inner
                x = 1
                end
                end
                """
                expected = """
                module Outer
                module Inner
                x = 1
                end #= module Inner =#
                end #= module Outer =#
                """
                @test apply_inlay_hints(code, get_syntactic_inlay_hints(code)) == expected
            end
        end

        # Range that does not include the block's `end` line should suppress
        # the hint entirely.
        @testset "range filtering" begin
            let code = """
                module TestModule
                x = 1
                end
                """
                range = Range(;
                    start = Position(; line = 0, character = 0),
                    var"end" = Position(; line = 1, character = 0))
                @test apply_inlay_hints(code, get_syntactic_inlay_hints(code; range)) == code
            end
        end

        # `end    # some comment` doesn't match the `# module name` shape, so
        # the hint still emits.
        @testset "whitespace before comment" begin
            let code = """
                module TestModule
                x = 1
                end    # some comment
                """
                expected = """
                module TestModule
                x = 1
                end #= module TestModule =#    # some comment
                """
                @test apply_inlay_hints(code, get_syntactic_inlay_hints(code)) == expected
            end
        end

        @testset "baremodule" begin
            let code = """
                baremodule TestModule
                x = 1
                end
                """
                expected = """
                baremodule TestModule
                x = 1
                end #= baremodule TestModule =#
                """
                @test apply_inlay_hints(code, get_syntactic_inlay_hints(code)) == expected
            end
        end
    end

    @testset "functions" begin
        let code = """
            function foo(x, y)
                x + y
            end
            """
            expected = """
            function foo(x, y)
                x + y
            end #= function foo =#
            """
            @test apply_inlay_hints(code, get_syntactic_inlay_hints(code)) == expected
        end

        @testset "short form function" begin
            let code = """
                foo(x) = begin
                    x + 1
                end
                """
                expected = """
                foo(x) = begin
                    x + 1
                end #= foo(...) = =#
                """
                @test apply_inlay_hints(code, get_syntactic_inlay_hints(code)) == expected
            end
        end

        @testset "one-liner function" begin
            let code = """
                function foo(x) x + 1 end
                """
                @test apply_inlay_hints(code, get_syntactic_inlay_hints(code)) == code
            end
        end

        @testset "existing comment" begin
            let code = """
                function foo(x)
                    x + 1
                end # function foo
                """
                @test apply_inlay_hints(code, get_syntactic_inlay_hints(code)) == code
            end
        end
    end

    @testset "macros" begin
        let code = """
            macro mymacro(x)
                esc(x)
            end
            """
            expected = """
            macro mymacro(x)
                esc(x)
            end #= macro @mymacro =#
            """
            @test apply_inlay_hints(code, get_syntactic_inlay_hints(code)) == expected
        end
    end

    @testset "structs" begin
        let code = """
            struct Foo
                x::Int
                y::String
            end
            """
            expected = """
            struct Foo
                x::Int
                y::String
            end #= struct Foo =#
            """
            @test apply_inlay_hints(code, get_syntactic_inlay_hints(code)) == expected
        end

        @testset "mutable struct" begin
            let code = """
                mutable struct Bar
                    x::Int
                end
                """
                expected = """
                mutable struct Bar
                    x::Int
                end #= mutable struct Bar =#
                """
                @test apply_inlay_hints(code, get_syntactic_inlay_hints(code)) == expected
            end
        end
    end

    @testset "control flow" begin
        @testset "if block" begin
            let code = """
                if condition
                    x = 1
                end
                """
                expected = """
                if condition
                    x = 1
                end #= if condition =#
                """
                @test apply_inlay_hints(code, get_syntactic_inlay_hints(code)) == expected
            end

            let code = """
                if x > 0
                    y = 1
                elseif x < 0
                    y = -1
                else
                    y = 0
                end
                """
                expected = """
                if x > 0
                    y = 1
                elseif x < 0
                    y = -1
                else
                    y = 0
                end #= if x > 0 =#
                """
                @test apply_inlay_hints(code, get_syntactic_inlay_hints(code)) == expected
            end
        end

        @testset "@static if block" begin
            let code = """
                @static if Sys.iswindows()
                    const PATH_SEP = '\\\\'
                else
                    const PATH_SEP = '/'
                end
                """
                expected = """
                @static if Sys.iswindows()
                    const PATH_SEP = '\\\\'
                else
                    const PATH_SEP = '/'
                end #= @static if Sys.iswindows() =#
                """
                @test apply_inlay_hints(code, get_syntactic_inlay_hints(code)) == expected
            end
        end

        @testset "let block" begin
            let code = """
                let x = 1,
                    y = 2
                    z = x + y
                end
                """
                expected = """
                let x = 1,
                    y = 2
                    z = x + y
                end #= let x = 1, =#
                """
                @test apply_inlay_hints(code, get_syntactic_inlay_hints(code)) == expected
            end
        end

        @testset "for loop" begin
            let code = """
                for i in 1:10
                    println(i)
                end
                """
                expected = """
                for i in 1:10
                    println(i)
                end #= for i in 1:10 =#
                """
                @test apply_inlay_hints(code, get_syntactic_inlay_hints(code)) == expected
            end
        end

        @testset "while loop" begin
            let code = """
                while x > 0
                    x -= 1
                end
                """
                expected = """
                while x > 0
                    x -= 1
                end #= while x > 0 =#
                """
                @test apply_inlay_hints(code, get_syntactic_inlay_hints(code)) == expected
            end
        end
    end

    @testset "@testset blocks" begin
        let code = """
            @testset "my tests" begin
                @test 1 == 1
            end
            """
            expected = """
            @testset "my tests" begin
                @test 1 == 1
            end #= @testset "my tests" begin =#
            """
            @test apply_inlay_hints(code, get_syntactic_inlay_hints(code)) == expected
        end

        @testset "nested @testset" begin
            let code = """
                @testset "outer" begin
                    @testset "inner" begin
                        @test true
                    end
                end
                """
                expected = """
                @testset "outer" begin
                    @testset "inner" begin
                        @test true
                    end #= @testset "inner" begin =#
                end #= @testset "outer" begin =#
                """
                @test apply_inlay_hints(code, get_syntactic_inlay_hints(code)) == expected
            end
        end
    end
end

function get_type_inlay_hints(
        code::AbstractString, mod::Module=Main;
        maxdepth=typemax(Int), maxwidth=typemax(Int)
    )
    fi = JETLS.FileInfo(1, code, @__FILE__)
    st0_top = JETLS.build_syntax_tree(fi)
    hints = InlayHint[]
    range = Range(;
        start = Position(; line=0, character=0),
        var"end" = Position(; line=10000, character=0))
    JETLS.iterate_toplevel_tree(st0_top) do st0::JS.SyntaxTree
        result = @something JETLS.get_inferrable_tree(st0, mod) return nothing
        (; ctx3, st3) = result
        inferred_tree = @something JETLS.infer_toplevel_tree(ctx3, st3, mod) return nothing
        # Disable production truncation here — these tests exercise the full
        # type-resolution pipeline and assert on the unclipped type strings.
        # Truncation is its own concern and should be tested separately.
        JETLS.collect_type_inlay_hints!(
            hints, st0, st3, inferred_tree, fi, range, JETLS.LSPostProcessor();
            maxdepth, maxwidth)
    end
    return hints
end

# Inserts each `hint.label` at its `position` in `code` and returns the
# resulting text. ASCII-only — LSP `Position.character` is treated as a byte
# index into the line. Hints on the same position are inserted in their
# original (traversal) order.
function apply_inlay_hints(code::AbstractString, hints::Vector{InlayHint})
    by_line = Dict{Int,Vector{InlayHint}}()
    for h in hints
        push!(get!(() -> InlayHint[], by_line, h.position.line), h)
    end
    out = IOBuffer()
    lines = split(code, '\n'; keepempty=true)
    for (i, line) in enumerate(lines)
        s = String(line)
        line_hints = sort(get(by_line, i-1, InlayHint[]); by = h -> h.position.character)
        cursor = 0
        for h in line_hints
            c = h.position.character
            print(out, s[cursor+1:c])
            print(out, h.label)
            cursor = c
        end
        print(out, s[cursor+1:end])
        i < length(lines) && print(out, '\n')
    end
    return String(take!(out))
end

@testset "type inlay hints" begin
    @testset "the basic" begin
        code = """
            let x = [1, 2, 3]
                sum(x)
            end
            """
        expected = """
            let x = [1, 2, 3]::Vector{$Int}
                sum(x::Vector{$Int})::$Int
            end
            """
        @test apply_inlay_hints(code, get_type_inlay_hints(code)) == expected
    end

    @testset "operator expressions" begin
        @testset "infix arithmetic" begin
            code = """
                let v = [1.0, 2.0]
                    v[1] + v[2]
                end
                """
            expected = """
                let v = [1.0, 2.0]::Vector{Float64}
                    ((v::Vector{Float64})[1]::Float64 + (v::Vector{Float64})[2]::Float64)::Float64
                end
                """
            @test apply_inlay_hints(code, get_type_inlay_hints(code)) == expected
        end

        @testset "juxtaposition" begin
            let code = """
                let x = rand()
                    2x
                end
                """
                expected = """
                let x = rand()::Float64
                    2x::Float64
                end
                """
                @test apply_inlay_hints(code, get_type_inlay_hints(code)) == expected
            end
            let code = """
                let x = rand()
                    2(x+1)
                end
                """
                expected = """
                let x = rand()::Float64
                    2(x::Float64+1)::Float64
                end
                """
                @test apply_inlay_hints(code, get_type_inlay_hints(code)) == expected
            end
        end

        # `x::T^2` parses correctly as `(x::T)^2` (since `::` is tighter than `^`),
        # but the rendered text looks visually ambiguous — a reader could mis-group
        # as `x::(T^2)`. Wrap the LHS to make the grouping explicit.
        @testset "power operator wraps LHS with parens" begin
            let code = """
                let x = rand()
                    x^2
                end
                """
                expected = """
                let x = rand()::Float64
                    ((x::Float64)^2)::Float64
                end
                """
                @test apply_inlay_hints(code, get_type_inlay_hints(code)) == expected
            end
        end

        # Prefix unary operator calls (`-x`, `!x`, `~x`, …) need a `(…)::T` wrap
        # so the inner argument's `::T` and the call's `::T` don't collide at the
        # same end position. The wrap anchors at the *argument*'s start, so the
        # operator stays outside: `-(x::Float64)::Float64`, not `(-x::Float64)::Float64`.
        @testset "prefix unary operator wraps argument with parens" begin
            let code = """
                let x = rand()
                    -x
                end
                """
                expected = """
                let x = rand()::Float64
                    -(x::Float64)::Float64
                end
                """
                @test apply_inlay_hints(code, get_type_inlay_hints(code)) == expected
            end
            let code = """
                let cnd = rand() > 0.5
                    !cnd
                end
                """
                expected = """
                let cnd = (rand()::Float64 > 0.5)::Bool
                    !(cnd::Bool)::Bool
                end
                """
                @test apply_inlay_hints(code, get_type_inlay_hints(code)) == expected
            end
        end

        # Postfix `'` (adjoint, `K"'"`) tightly binds to its operand — `M::T'`
        # parses as `M::(T')`, not `(M::T)'`. Suppress the operand's hint so the
        # render stays unambiguous as `M'::T_outer`.
        @testset "postfix adjoint suppresses operand hint" begin
            code = """
                let M = rand(2, 2)
                    M'
                end
                """
            expected = """
                let M = rand(2, 2)::Matrix{Float64}
                    M'::Adjoint{Float64, Matrix{Float64}}
                end
                """
            @test apply_inlay_hints(code, get_type_inlay_hints(code)) == expected
        end

        @testset "indexing wraps the indexed object with parens" begin
            code = """
                let x = [1,2,3]
                    x[1]
                end
                """
            expected = """
                let x = [1,2,3]::Vector{$Int}
                    (x::Vector{$Int})[1]::$Int
                end
                """
            @test apply_inlay_hints(code, get_type_inlay_hints(code)) == expected
        end

        # The open paren must wrap the whole comparison value as `(v[1] < 0.0)::Bool`,
        # not just the operator side as `v[1] (< 0.0)::Bool`.
        @testset "infix comparison wraps the full expression" begin
            code = """
                let v = [1.0]
                    v[1] < 0.0
                end
                """
            expected = """
                let v = [1.0]::Vector{Float64}
                    ((v::Vector{Float64})[1]::Float64 < 0.0)::Bool
                end
                """
            @test apply_inlay_hints(code, get_type_inlay_hints(code)) == expected
        end

        # `op=` lowers to `K"unknown_head"`, which is in the skip set; the
        # rewritten operator (`+`) and its LHS reference don't leak hints, so
        # the `inside += 1` line stays unannotated even though the surrounding
        # expressions get annotated normally.
        @testset "compound assignment emits nothing" begin
            code = """
                let inside = rand(Int)
                    inside += 1
                    inside
                end
                """
            expected = """
                let inside = rand(Int)::$Int
                    inside += 1
                    inside::$Int
                end
                """
            @test apply_inlay_hints(code, get_type_inlay_hints(code)) == expected
        end
    end

    @testset "macrocall expressions" begin
        # No-paren macrocalls render as `(@m … args)::T` exactly once. The
        # `K"Value"` companion node shares the macrocall's byte range but
        # must not produce a second pair of `(` / `)::T`. The `0` fallback
        # arg picks up `::Union{}` because `v::Vector{Int}` is never
        # `nothing`, making that branch unreachable.
        @testset "no-paren macrocall renders as a single (@m …)::T wrap" begin
            code = """
                let v = [1]
                    @something v 0
                end
                """
            expected = """
                let v = [1]::Vector{$Int}
                    (@something v::Vector{$Int} 0::Union{})::Vector{$Int}
                end
                """
            @test apply_inlay_hints(code, get_type_inlay_hints(code)) == expected
        end

        # General (non-`_str`/`_cmd`) macrocalls inline their expansion. The
        # macrocall annotation is the expansion's tail-call type — internal
        # helpers (`typeof(isnothing)` / `typeof(something)` / `Union{}`)
        # don't leak in.
        @testset "general macrocall does not leak macro-internal types" begin
            code = """
                let v = Union{Int,Nothing}[1][1]
                    @something v 0
                end
                """
            expected = """
                let v = (Union{Int,Nothing}[1]::Vector{Union{Nothing, $Int}})[1]::Union{Nothing, $Int}
                    (@something v::Union{Nothing, $Int} 0)::$Int
                end
                """
            @test apply_inlay_hints(code, get_type_inlay_hints(code)) == expected
        end

        # The last byte of a no-paren macrocall coincides with the last byte of
        # its trailing argument. The macrocall's wrap must not also fire on the
        # trailing arg (`return false` here).
        @testset "trailing argument of macrocall is not wrapped" begin
            code = """
                let v = Union{Int,Nothing}[1][1]
                    @something v return false
                end
                """
            expected = """
                let v = (Union{Int,Nothing}[1]::Vector{Union{Nothing, $Int}})[1]::Union{Nothing, $Int}
                    (@something v::Union{Nothing, $Int} return false)::$Int
                end
                """
            @test apply_inlay_hints(code, get_type_inlay_hints(code)) == expected
        end

        @testset "@something across multiple lines" begin
            code = """
                let
                    x = Union{Int,Nothing}[1, nothing][1]
                    y = @something x return false
                    y
                end
                """
            expected = """
                let
                    x = (Union{Int,Nothing}[1, nothing]::Vector{Union{Nothing, $Int}})[1]::Union{Nothing, $Int}
                    y = (@something x::Union{Nothing, $Int} return false)::$Int
                    y::$Int
                end
                """
            @test apply_inlay_hints(code, get_type_inlay_hints(code)) == expected
        end

        @testset "string macro" begin
            code = "lazy\"hello\""
            expected = "lazy\"hello\"::LazyString"
            @test apply_inlay_hints(code, get_type_inlay_hints(code)) == expected
        end
    end

    @testset "tuple expressions" begin
        # Open `K"tuple"` (`x, y` without parens) needs the `(…)::T` wrap because
        # `x, y::T` parses as `x, (y::T)`. Parenthesized `(x, y)` already ends in
        # `)` so `(x, y)::T` parses cleanly without an extra wrap.
        @testset "open tuple wraps with parens" begin
            code = """
                function f(x::Float64, y::Float64)
                    return x, y
                end
                """
            expected = """
                function f(x::Float64, y::Float64)::Tuple{Float64, Float64}
                    return (x::Float64, y::Float64)::Tuple{Float64, Float64}
                end
                """
            @test apply_inlay_hints(code, get_type_inlay_hints(code)) == expected
        end

        @testset "parenthesized tuple needs no extra wrap" begin
            code = """
                function f(x::Float64, y::Float64)
                    return (x, y)
                end
                """
            expected = """
                function f(x::Float64, y::Float64)::Tuple{Float64, Float64}
                    return (x::Float64, y::Float64)::Tuple{Float64, Float64}
                end
                """
            @test apply_inlay_hints(code, get_type_inlay_hints(code)) == expected
        end

        # Outer is open (`(a, b), c` or `c, (a, b)`), inner is parenthesized.
        # Without using `PARENS_FLAG` to detect parenthesization, a leading-char
        # check mis-skips the first form and a trailing-char check mis-skips the
        # second.
        @testset "open tuple wraps when only an inner child is parenthesized" begin
            let code = """
                    function f(x::$Int)
                        return (x, x), x
                    end
                    """
                expected = """
                    function f(x::$Int)::Tuple{Tuple{$Int, $Int}, $Int}
                        return ((x::$Int, x::$Int)::Tuple{$Int, $Int}, x::$Int)::Tuple{Tuple{$Int, $Int}, $Int}
                    end
                    """
                @test apply_inlay_hints(code, get_type_inlay_hints(code)) == expected
            end
            let code = """
                    function f(x::$Int)
                        return x, (x, x)
                    end
                    """
                expected = """
                    function f(x::$Int)::Tuple{$Int, Tuple{$Int, $Int}}
                        return (x::$Int, (x::$Int, x::$Int)::Tuple{$Int, $Int})::Tuple{$Int, Tuple{$Int, $Int}}
                    end
                    """
                @test apply_inlay_hints(code, get_type_inlay_hints(code)) == expected
            end
        end
    end

    # `for var = iter` / `for var in iter` — the iteration variable is
    # registered in `callee_ranges` by the K"=" pass (suppressing the regular
    # Identifier hint) but its inferred type is informative, so we emit a hint
    # on it explicitly. Both `=` and `in` syntactic forms parse to K"=".
    @testset "loop expressions" begin
        let code = """
                let xs = rand(3)
                    for x = xs
                        println(x)
                    end
                end
                """
            expected = """
                let xs = rand(3)::Vector{Float64}
                    for x::Float64 = xs::Vector{Float64}
                        println(x::Float64)::Any
                    end
                end
                """
            @test apply_inlay_hints(code, get_type_inlay_hints(code)) == expected
        end
        # `in` form, identical structure
        let code = """
                let xs = String["a", "b"]
                    for s in xs
                        print(s)
                    end
                end
                """
            expected = """
                let xs = String["a", "b"]::Vector{String}
                    for s::String in xs::Vector{String}
                        print(s::String)::Any
                    end
                end
                """
            @test apply_inlay_hints(code, get_type_inlay_hints(code)) == expected
        end
        # Tuple destructuring `for (i, x) in enumerate(...)` — each destructured
        # variable picks up its own hint; no double-emission with the regular
        # postorder Identifier visit.
        let code = """
                let xs = rand(3)
                    for (i, x) in enumerate(xs)
                        println(i, x)
                    end
                end
                """
            expected = """
                let xs = rand(3)::Vector{Float64}
                    for (i::$Int, x::Float64) in enumerate(xs::Vector{Float64})::Enumerate{Vector{Float64}}
                        println(i::$Int, x::Float64)::Any
                    end
                end
                """
            @test apply_inlay_hints(code, get_type_inlay_hints(code)) == expected
        end
        # Named-tuple destructuring `for (; field) in iter` — the K"parameters"
        # wrapper is walked through to reach the inner Identifier(s).
        let code = """
                let xs = Some{$Int}[Some(1)]
                    for (; value) in xs
                        println(value)
                    end
                end
                """
            expected = """
                let xs = Some{$Int}[Some(1)]::Vector{Some{$Int}}
                    for (; value::$Int) in xs::Vector{Some{$Int}}
                        println(value::$Int)::Any
                    end
                end
                """
            @test apply_inlay_hints(code, get_type_inlay_hints(code)) == expected
        end
    end

    # `f(; kw=v)` lowering plants kwargs `NamedTuple` / `Tuple` constructors at
    # the same byte range as the user's call. `get_type_for_range` picks the
    # user call only — no `Type{NamedTuple{…}}` / `Tuple{…}` chaff in the hint.
    @testset "kwcall expressions should annotate only the call result" begin
        code = """
            let strs = String["10", "20"]
                s = strs[1]
                parse(Int, s; base = 10)
            end
            """
        expected = """
            let strs = String["10", "20"]::Vector{String}
                s = (strs::Vector{String})[1]::String
                parse(Int, s::String; base = 10)::$Int
            end
            """
        @test apply_inlay_hints(code, get_type_inlay_hints(code)) == expected
    end

    @testset "branching expressions" begin
        # `K"&&"`, `K"||"`, `K"comparison"`, and ternary `K"if"` are branching
        # expressions: `::T` after the rightmost operand would bind to that
        # operand alone (e.g. `0 < x < 1::Bool` parses as `0 < x < (1::Bool)`),
        # so they get an enclosing `(…)::T` wrap. `K"comparison"` operators like
        # `<` are user-typed source tokens that the lowering pipeline reuses as
        # callees, so they're put in `callee_ranges` to suppress operator hints.
        @testset "wraps branching expressions" begin
            code = """
                let x = rand()
                    r = 0 < x < 1
                    if (r && rand(Bool)) || rand(Bool)
                        println(r)
                    end
                end
                """
            expected = """
                let x = rand()::Float64
                    r = (0 < x::Float64 < 1)::Bool
                    if (r::Bool && rand(Bool)::Bool)::Bool || rand(Bool)::Bool
                        println(r::Bool)
                    end
                end
                """
            @test apply_inlay_hints(code, get_type_inlay_hints(code)) == expected
        end

        # Ternary in tail position: branches lower to `K"return"` stmts whose
        # types `tmerge` to the ternary's value. The wrap puts `::T` outside.
        @testset "ternary in tail position" begin
            code = """
                function f(b::Bool, x::Int)
                    return b ? x : 0
                end
                """
            expected = """
                function f(b::Bool, x::Int)::$Int
                    return (b ? x::$Int : 0)::$Int
                end
                """
            @test apply_inlay_hints(code, get_type_inlay_hints(code)) == expected
        end

        # Block-form `if c; …; end` ends at the `end` keyword, which is a
        # syntactic boundary — `if c; a; end::T` parses unambiguously as
        # `(if c; a; end)::T`, so no wrap is needed.
        @testset "if-block in tail position" begin
            code = """
                function f(b::Bool)
                    return if b; 1 else 2 end
                end
                """
            expected = """
                function f(b::Bool)::$Int
                    return if b; 1 else 2 end::$Int
                end
                """
            @test apply_inlay_hints(code, get_type_inlay_hints(code)) == expected
        end

        # `if-elseif-else`: the `K"elseif"` branch contributes its value alongside
        # `if` and `else` to the merged type.
        @testset "if-elseif-else in tail position" begin
            code = """
                function f(a::Bool, b::Bool)
                    return if a
                        1
                    elseif b
                        "x"
                    else
                        nothing
                    end
                end
                """
            expected = """
                function f(a::Bool, b::Bool)::Union{Nothing, $Int, String}
                    return if a
                        1
                    elseif b
                        "x"
                    else
                        nothing
                    end::Union{Nothing, $Int, String}
                end
                """
            @test apply_inlay_hints(code, get_type_inlay_hints(code)) == expected
        end

        # A user-written `return X` inside a branching expression exits the
        # function — `X` shouldn't pollute the surrounding expression's value.
        # Without filtering, `if x isa Int; return string(...); end` would leak
        # `String` into the outer `if`'s value type. With the fix, the outer
        # `if` is `Core.Const(nothing)` (only the implicit fall-through reaches
        # `out`), so it gets no annotation at all.
        @testset "user return inside branching expression" begin
            code = """
                function f(x::Union{Int, Nothing})
                    out = if x isa Int
                        return string(x; base = 16)
                    end
                    out
                end
                """
            expected = """
                function f(x::Union{Int, Nothing})::Union{Nothing, String}
                    out = if (x::Union{Nothing, $Int} isa Int)::Bool
                        return string(x::$Int; base = 16)::String
                    end
                    out
                end
                """
            @test apply_inlay_hints(code, get_type_inlay_hints(code)) == expected
        end

        # User `return` itself wraps a branching: the inner `if` is still
        # annotated (it's the user's literal return value, its branches flow
        # through), but the outer `if` doesn't pick up `Int` / `String` from
        # the inner branches because they exit via the return.
        @testset "user return wrapping a branching expression" begin
            code = """
                function g(b::Bool, c::Bool)
                    out = if b
                        return if c; 1; else; "x"; end
                    end
                    out
                end
                """
            expected = """
                function g(b::Bool, c::Bool)::Union{Nothing, $Int, String}
                    out = if b
                        return if c; 1; else; "x"; end::Union{$Int, String}
                    end
                    out
                end
                """
            @test apply_inlay_hints(code, get_type_inlay_hints(code)) == expected
        end

        # `Base.@something y return X` expands so the literal `return X` exits
        # the function when no preceding arg is non-`nothing`. The walker over
        # `st3` (post-macro-expansion) sees the synthesized `return`, so the
        # outer `if`'s value omits `String` (would otherwise leak).
        @testset "return hidden in @something expansion" begin
            code = """
                function h(x::Union{Int, Nothing}, y::Union{Int, Nothing})
                    out = if x isa Int
                        @something y return "no value"
                    end
                    out
                end
                """
            expected = """
                function h(x::Union{Int, Nothing}, y::Union{Int, Nothing})::Union{Nothing, $Int, String}
                    out = if (x::Union{Nothing, $Int} isa Int)::Bool
                        (@something y::Union{Nothing, $Int} return "no value")::$Int
                    end::Union{Nothing, $Int}
                    out::Union{Nothing, $Int}
                end
                """
            @test apply_inlay_hints(code, get_type_inlay_hints(code)) == expected
        end
    end

    @testset "method definitions" begin
        # Method bodies are inferred as their own anonymous chunks, with argtypes
        # resolved from the lowered svec — `infer_method_defs!` walks `:method`
        # 3-arg statements at the lowered toplevel.
        @testset "non-kwarg method body" begin
            code = """
                function add_one(x::Int)
                    return x + 1
                end
                """
            expected = """
                function add_one(x::Int)::$Int
                    return (x::$Int + 1)::$Int
                end
                """
            @test apply_inlay_hints(code, get_type_inlay_hints(code)) == expected
        end

        # Short-form `f(args) = body` is `K"="` with a `K"call"` LHS — same
        # treatment as `function f(...) end` for both the signature filter
        # (no `::Any` clutter on `x::Int`) and the return-type emission at
        # the closing `)` of the signature.
        @testset "short-form function definition" begin
            code = """
                add_one(x::Int) = x + 1
                """
            expected = """
                add_one(x::Int)::$Int = (x::$Int + 1)::$Int
                """
            @test apply_inlay_hints(code, get_type_inlay_hints(code)) == expected
        end

        # Kwarg lowering produces three `:method` 3-arg statements (kwbody, public,
        # kwcall) sharing the funcdef byte range, but only the kwbody's
        # `K"code_info"` carries the user's body (sub-range); the dispatcher and
        # kwcall handler return `Any` from a synthesized body. `type_for_funcdef`
        # prefers the kwbody so the funcdef return type comes from the user's body.
        @testset "kwarg method body" begin
            code = """
                function sum_with_init(xs::Vector{Int}; init::Int = 0)
                    s = init
                    for x in xs
                        s += x
                    end
                    s
                end
                """
            expected = """
                function sum_with_init(xs::Vector{Int}; init::Int = 0)::$Int
                    s = init::$Int
                    for x::$Int in xs::Vector{$Int}
                        s += x::$Int
                    end
                    s::$Int
                end
                """
            @test apply_inlay_hints(code, get_type_inlay_hints(code)) == expected
        end

        # `where {…}` clauses are part of the user-written signature: the `T` / `Number`
        # identifiers inside `T <: Number` shouldn't pick up `::TypeVar` hints.
        # `funcdef_sig_range` covers the full sig (`f(args)` + any `where` / `::T` wrappers)
        # so the where bounds land in `sig_ranges` and are skipped.
        #
        # The `::Any` annotations on body references / return types below are a
        # `TypeAnnotation`-side limitation (static-parameter references in parametric method
        # bodies fall through to `Any`; tracked as `@test_broken` in
        # `test/analysis/test_TypeAnnotation.jl`'s "static-parameter reference in parametric
        # method body"). They aren't inlay-hint bugs, so the expected strings encode the
        # current `Any` rendering rather than being marked broken here.
        @testset "where-clause type parameters" begin
            @testset "long-form" begin
                code = """
                    function func(x::T) where {T <: Number}
                        return 2x
                    end
                    """
                expected = """
                    function func(x::T)::Any where {T <: Number}
                        return 2x::Any
                    end
                    """
                @test apply_inlay_hints(code, get_type_inlay_hints(code)) == expected
            end
            @testset "multiple bounds" begin
                code = """
                    function f(x::T, y::S) where {T <: Number, S <: AbstractString}
                        return (x, y)
                    end
                    """
                expected = """
                    function f(x::T, y::S)::Tuple{Any, Any} where {T <: Number, S <: AbstractString}
                        return (x::Any, y::Any)::Tuple{Any, Any}
                    end
                    """
                @test apply_inlay_hints(code, get_type_inlay_hints(code)) == expected
            end
            @testset "short-form" begin
                code = """
                    add(x::T, y::T) where {T <: Real} = x + y
                    """
                expected = """
                    add(x::T, y::T)::Any where {T <: Real} = (x::Any + y::Any)::Any
                    """
                @test apply_inlay_hints(code, get_type_inlay_hints(code)) == expected
            end
        end
    end

    @testset "closures handling" begin
        # Single-method local closures route through `OpaqueClosure` via
        # `rewrite_local_closures_to_opaque`, so both the body's captures and
        # the enclosing call site (`inner(x)`) infer precisely without any
        # `context_module` dependency.
        @testset "closure body is annotated" begin
            code = """
                function with_closure(xs::Vector{Int})
                    function inner(y::Int)
                        local_var = y * 2
                        return local_var
                    end
                    s = 0
                    for x in xs
                        s += inner(x)
                    end
                    s
                end
                """
            expected = """
                function with_closure(xs::Vector{Int})::$Int
                    function inner(y::Int)
                        local_var = (y::$Int * 2)::$Int
                        return local_var::$Int
                    end
                    s = 0
                    for x::$Int in xs::Vector{$Int}
                        s += inner(x::$Int)::$Int
                    end
                    s::$Int
                end
                """
            @test apply_inlay_hints(code, get_type_inlay_hints(code)) == expected
        end

        # `f(...) do y::T … end` parses as a `K"do"` wrapping a `K"call"` whose
        # last argument is the `K"->"` lambda — all three nodes share the do's
        # end byte. Without explicit handling, each emits a hint at the same
        # position (triplicated `::T::T::T` after `end`). The lambda's parameter
        # list (`do y::T` / `(y::T) -> …`) is also a user-typed signature that
        # shouldn't pick up `::Any` hints inside.
        @testset "do-block return type and parameter list" begin
            code = """
                let xs = [1, 2, 3]
                    map(xs) do y::Int
                        y + 1
                    end
                end
                """
            # `map`'s result infers as `Vector{$Int}` (precise) because the
            # closure → OC rewrite lets the typed `do y::Int` propagate
            # through `most_general_argtypes`. Untyped `do y` would fall
            # back to `Any`.
            expected = """
                let xs = [1, 2, 3]::Vector{$Int}
                    map(xs::Vector{$Int}) do y::Int
                        (y::$Int + 1)::$Int
                    end::Vector{$Int}
                end
                """
            @test apply_inlay_hints(code, get_type_inlay_hints(code)) == expected
        end
    end

    @testset "struct definitions" begin
        # Type declarations carry user-written types; an inferred hint on the
        # `K"::"` field, on the `struct` itself, or on identifiers inside the
        # name expression / type expression would just produce noise like
        # `x::Int::Any`. Source must round-trip unchanged.
        @testset "struct fields produce no hints" begin
            code = """
                struct Foo
                    x::$Int
                    y::String
                end
                """
            @test apply_inlay_hints(code, get_type_inlay_hints(code)) == code
        end
        @testset "parametric struct and supertype clause are clean" begin
            code = """
                struct Bar{T} <: AbstractVector{T}
                    x::T
                end
                """
            @test apply_inlay_hints(code, get_type_inlay_hints(code)) == code
        end
    end

    @testset "abstract / primitive type definitions" begin
        let code = "abstract type AT end\n"
            @test apply_inlay_hints(code, get_type_inlay_hints(code)) == code
        end
        let code = "primitive type PT 8 end\n"
            @test apply_inlay_hints(code, get_type_inlay_hints(code)) == code
        end
    end

    # `x::Int = 1` — the user already wrote `::Int`. Without skipping `K"::"`
    # and registering its RHS as a `sig_range`, this would produce a redundant
    # `x::Int::$Int` (and a stray `::Any` on `Int`).
    @testset "local type declaration should produce no redundant hint" begin
        code = """
            function f()
                x::$Int = 1
                return x
            end
            """
        expected = """
            function f()::$Int
                x::$Int = 1
                return x
            end
            """
        @test apply_inlay_hints(code, get_type_inlay_hints(code)) == expected
    end

    # `Union{}` (the bottom type) is shown alongside other types so unreachable /
    # always-erroring expressions are recognizable. The label is valid Julia
    # (`::Union{}`), and the tooltip carries a short explanation since the
    # bottom type isn't immediately obvious to readers.
    @testset "Union{} annotation surfaces explanation in tooltip" begin
        code = """
            function f()
                error("boom")
            end
            """
        hints = get_type_inlay_hints(code)
        # Both the call result and the function return are unreachable.
        expected = """
            function f()::Union{}
                error("boom")::Union{}
            end
            """
        @test apply_inlay_hints(code, hints) == expected

        union_hints = filter(h -> occursin("::Union{}", h.label), hints)
        @test !isempty(union_hints)
        for h in union_hints
            @test h.tooltip isa AbstractString
            @test occursin("provably never produces a value", h.tooltip)
        end
    end

    # `Const` types (e.g. `x = println` makes both binding and reference
    # `Const(println)`) are filtered by `should_annotate_type`, so the
    # source is unchanged — no `typeof(println)` leaks through.
    @testset "Const types are not annotated" begin
        code = """
            let x = println
                x
            end
            """
        @test apply_inlay_hints(code, get_type_inlay_hints(code)) == code
    end

    @testset "decorative parens" begin
        # When the user already wrote `(expr)`, the source's own `(` `)` provide
        # the syntactic boundary for `::T`. Layering our own `((expr)::T)` is
        # noise — `is_decoratively_parenthesized` detects this and shifts the
        # annotation past the source `)` instead.
        @testset "decorative parens are reused for needs_wrap" begin
            code = """
                let x = rand()
                    r = (0 < x < 1)
                    r
                end
                """
            expected = """
                let x = rand()::Float64
                    r = (0 < x::Float64 < 1)::Bool
                    r::Bool
                end
                """
            @test apply_inlay_hints(code, get_type_inlay_hints(code)) == expected
        end

        # `(y).foo` is dotted-projection wrap (`is_dp`) on top of source parens.
        # The annotation goes between `y` and the source `)` — `(y::Regex).foo`
        # — using the existing parens to keep `.foo` binding outside the type
        # assertion.
        @testset "decorative parens are reused for is_dp" begin
            code = """
                let y = Regex("foo")
                    (y).compile_options
                end
                """
            expected = """
                let y = Regex("foo")::Regex
                    (y::Regex).compile_options::UInt32
                end
                """
            @test apply_inlay_hints(code, get_type_inlay_hints(code)) == expected
        end

        # Combined `is_dp` + `needs_wrap` (`(x + y).foo`) still needs an outer
        # `(...)::T` so `.foo` binds outside the type assertion. The source's
        # parens cover the inner `needs_wrap` — we only add the outer pair.
        @testset "decorative parens with combined is_dp + needs_wrap" begin
            code = """
                function f(x::Float64, y::Float64)
                    return (x + y).a
                end
                """
            # `Float64.a` doesn't exist — inference returns `Union{}` for
            # both the outer `.a` access and the function return. What we
            # care about is the wrap shape on the `+` call.
            expected = """
                function f(x::Float64, y::Float64)::Union{}
                    return ((x::Float64 + y::Float64)::Float64).a::Union{}
                end
                """
            @test apply_inlay_hints(code, get_type_inlay_hints(code)) == expected
        end

        # The decorative-paren detection has to disambiguate function-call /
        # indexed-call / chained-call parens from purely decorative ones. The
        # token immediately before the `(` (skipping intra-line whitespace, but
        # not newlines) is `Identifier` / `]` / `)` exactly when it's a call;
        # anything else (operators, separators, keywords, BOL) is decorative.
        @testset "function-call parens are not treated as decorative" begin
            # `f(x + y)` — `(` follows identifier `f` → call, inner `x + y` still
            # needs our wrap rather than reusing `f`'s call parens.
            code = """
                function g(x::$Int, y::$Int)
                    return f(x + y)
                end
                """
            hints = get_type_inlay_hints(code)
            applied = apply_inlay_hints(code, hints)
            @test occursin("f((x::$Int + y::$Int)::$Int)", applied)
        end
    end

    @testset "type string truncation" begin
        # `maxdepth=3, maxwidth=20` are the production defaults. Verify the two
        # passes cooperate: `maxdepth` clips deep nesting first, `maxwidth` then
        # handles wide-but-shallow types.

        @testset "maxdepth caps nesting" begin
            # `SyntaxTree{Dict{Symbol, Dict{Int64, Any}}}` — depth 3 inner contents.
            let s = "SyntaxTree{Dict{Symbol, Dict{Int64, Any}}}"
                @test JETLS.truncate_typstr(s, 3, typemax(Int)) ==
                    "SyntaxTree{Dict{Symbol, Dict{…}}}"
                @test JETLS.truncate_typstr(s, 2, typemax(Int)) == "SyntaxTree{Dict{…}}"
                @test JETLS.truncate_typstr(s, 1, typemax(Int)) == "SyntaxTree{…}"
            end
        end

        @testset "maxwidth caps wide flat types" begin
            let s = "Tuple{Int64, Int64, Int64, Int64, Int64}"  # 40 chars, depth 1
                # Depth cap can't help — there's no nested level to cut. Width pass
                # collapses the outermost `{...}`.
                @test JETLS.truncate_typstr(s, typemax(Int), 20) == "Tuple{…}"
            end
        end

        @testset "passes compose" begin
            # Deep + wide: depth pass shrinks first, width pass either accepts
            # the shrunk result or further trims it.
            let s = "SyntaxTree{Dict{Symbol, Dict{Int64, Any}}}"
                @test JETLS.truncate_typstr(s, 3, 20) == "SyntaxTree{Dict{…}}"
            end
        end

        @testset "can be no-op" begin
            let s = "Tuple{Float64, Float64, Float64, Float64, Float64, Float64, Float64}"
                @test JETLS.truncate_typstr(s, typemax(Int), typemax(Int)) == s
            end
        end
    end
end

end # module test_inlay_hint
