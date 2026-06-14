module test_inlay_hint

using Test
using JETLS
using JETLS.LSP
using JETLS.URIs2

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
    server = JETLS.Server()
    uri = URI("file:///test.jl")
    fi = JETLS.FileInfo(1, code, @__FILE__)
    JETLS.store!(server.state.file_cache) do cache
        Base.PersistentDict(cache, uri => fi), nothing
    end
    if range === nothing
        n_lines = count(==('\n'), code)
        range = Range(;
            start = Position(; line = 0, character = 0),
            var"end" = Position(; line = n_lines, character = 0))
    end
    return JETLS.syntactic_inlay_hints(server.state, uri, fi, range; min_lines)
end

@testset HierarchicalTestSet "block end hints" begin
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

function get_type_inlay_hints_from_request_path(code::AbstractString, range::Range)
    server = JETLS.Server()
    filename = @__FILE__
    uri = filename2uri(filename)
    inferred_context_cache = JETLS.InferredContextCache()
    fi = JETLS.FileInfo(1, code, filename; inferred_context_cache)
    st0_top = JETLS.build_syntax_tree(fi)
    hints = InlayHint[]
    JETLS.type_inlay_hints!(hints, server.state, fi, st0_top, uri, range)
    return hints, inferred_context_cache
end

function get_lazy_type_inlay_hints(code::AbstractString, mod::Module=Main)
    server = JETLS.Server()
    filename = @__FILE__
    uri = filename2uri(filename)
    inferred_context_cache = JETLS.InferredContextCache()
    fi = JETLS.FileInfo(1, code, filename; inferred_context_cache)
    JETLS.store!(server.state.file_cache) do cache
        Base.PersistentDict(cache, uri => fi), nothing
    end
    st0_top = JETLS.build_syntax_tree(fi)
    hints = InlayHint[]
    range = Range(;
        start = Position(; line=0, character=0),
        var"end" = Position(; line=10000, character=0))
    JETLS.iterate_toplevel_tree(st0_top) do st0::JS.SyntaxTree
        ctx = @something JETLS.build_inferred_context_for_range(
            st0_top, mod, JS.byte_range(st0);
            caller="get_lazy_type_inlay_hints",
            cache=inferred_context_cache) return nothing
        JETLS.collect_type_inlay_hints!(
            hints, st0, ctx, fi, uri, range, JETLS.LSPostProcessor();
            lazy_tooltips = true)
    end
    return server, hints
end

function get_type_inlay_hints(
        code::AbstractString, mod::Module=Main;
        range::Union{Range,Nothing} = nothing,
        maxdepth=typemax(Int), maxwidth=typemax(Int)
    )
    filename = @__FILE__
    uri = filename2uri(filename)
    fi = JETLS.FileInfo(1, code, filename)
    st0_top = JETLS.build_syntax_tree(fi)
    hints = InlayHint[]
    rng = range !== nothing ? range :
        Range(;
            start = Position(; line=0, character=0),
            var"end" = Position(; line=10000, character=0))
    JETLS.iterate_toplevel_tree(st0_top) do st0::JS.SyntaxTree
        ctx = @something JETLS.build_inferred_context_for_range(
            st0_top, mod, JS.byte_range(st0);
            caller="get_type_inlay_hints") return nothing
        # Disable production truncation here — these tests exercise the full
        # type-resolution pipeline and assert on the unclipped type strings.
        # Truncation is its own concern and should be tested separately.
        JETLS.collect_type_inlay_hints!(
            hints, st0, ctx, fi, uri, rng, JETLS.LSPostProcessor();
            maxdepth, maxwidth)
    end
    return hints
end

@testset HierarchicalTestSet "type inlay hints" begin
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

    @testset "range filtering" begin
        code = "let x = [1, 2, 3]\n" *
            "    sum(x)\n" *
            "    length(x)\n" *
            "end\n"
        range = Range(;
            start = Position(; line=1, character=0),
            var"end" = Position(; line=1, character=100))
        expected = "let x = [1, 2, 3]\n" *
            "    sum(x::Vector{$Int})::$Int\n" *
            "    length(x)\n" *
            "end\n"
        @test apply_inlay_hints(code, get_type_inlay_hints(code; range)) == expected
    end

    @testset "non-overlapping top-level chunks are not inferred" begin
        code = "let a = [1]\n" *
            "    sum(a)\n" *
            "end\n" *
            "\n" *
            "let b = [1.0]\n" *
            "    sum(b)\n" *
            "end\n"
        range = Range(;
            start = Position(; line=4, character=0),
            var"end" = Position(; line=6, character=100))
        hints, cache = get_type_inlay_hints_from_request_path(code, range)
        expected = "let a = [1]\n" *
            "    sum(a)\n" *
            "end\n" *
            "\n" *
            "let b = [1.0]::Vector{Float64}\n" *
            "    sum(b::Vector{Float64})::Float64\n" *
            "end\n"
        @test apply_inlay_hints(code, hints) == expected
        @test length(JETLS.load(cache)) == 1
    end

    @testset "lazy tooltip resolution" begin
        code = "let M = rand(2, 2)\n" *
            "    M'\n" *
            "end\n"
        server, hints = get_lazy_type_inlay_hints(code)
        hint = only(filter(h -> occursin("Adjoint", h.label), hints))
        @test hint.tooltip === nothing
        @test hint.data isa TypeInlayHintData
        resolved = JETLS.resolve_inlay_hint(server.state, hint)
        @test resolved.label == hint.label
        @test resolved.tooltip isa MarkupContent
        @test resolved.tooltip.kind == MarkupKind.Markdown
        @test resolved.tooltip.value == "```julia\nLinearAlgebra.Adjoint{Float64, Matrix{Float64}}\n```"
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

        # Compound assignments parse as `K"unknown_head"`, which is in the skip set;
        # lowering-introduced operator and LHS references don't leak hints, so
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
                        println(x::Float64)
                    end
                end
                """
            @test apply_inlay_hints(code, get_type_inlay_hints(code)) == expected
        end

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
                        print(s::String)
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
                        println(i::$Int, x::Float64)
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
                        println(value::$Int)
                    end
                end
                """
            @test apply_inlay_hints(code, get_type_inlay_hints(code)) == expected
        end
    end

    # Untyped iter vars resolve precisely via TypeAnnotation's closure
    # argument-type refinement (the generator body is a lowered closure whose
    # argtypes are observed at its `iterate`-driven call sites).
    @testset "comprehension expressions" begin
        @testset "untyped iter var" begin
            let code = """
                    let xs = rand(3)
                        [x for x in xs]
                    end
                    """
                @test apply_inlay_hints(code, get_type_inlay_hints(code)) == """
                    let xs = rand(3)::Vector{Float64}
                        [x for x in xs::Vector{Float64}]::Vector{Float64}
                    end
                    """
            end

            let code = """
                    let xs = rand(3)
                        [2x for x in xs]
                    end
                    """
                @test apply_inlay_hints(code, get_type_inlay_hints(code)) == """
                    let xs = rand(3)::Vector{Float64}
                        [2x::Float64 for x in xs::Vector{Float64}]::Vector{Float64}
                    end
                    """
            end

            let code = """
                    let xs = rand(3)
                        sum(x for x in xs)
                    end
                    """
                @test apply_inlay_hints(code, get_type_inlay_hints(code)) == """
                    let xs = rand(3)::Vector{Float64}
                        sum(x for x in xs::Vector{Float64})::Float64
                    end
                    """
            end

            # `if cond` produces a `K"filter"` around the binding.
            let code = """
                    let xs = [1, 2, 3]
                        [x for x in xs if x > 0]
                    end
                    """
                @test apply_inlay_hints(code, get_type_inlay_hints(code)) == """
                    let xs = [1, 2, 3]::Vector{$Int}
                        [x for x in xs::Vector{$Int} if (x::$Int > 0)::Bool]::Vector{$Int}
                    end
                    """
            end

            # Multi-`for` lowers to nested generator OCs.
            let code = """
                    let xs = [1, 2, 3], ys = [1.0]
                        [x + y for x in xs for y in ys]
                    end
                    """
                @test apply_inlay_hints(code, get_type_inlay_hints(code)) == """
                    let xs = [1, 2, 3]::Vector{$Int}, ys = [1.0]::Vector{Float64}
                        [(x::$Int + y::Float64)::Float64 for x::$Int in xs::Vector{$Int} for y in ys::Vector{Float64}]::Vector{Float64}
                    end
                    """
            end
        end

        @testset "typed iter var" begin
            let code = """
                    let xs = rand(3)
                        [x for x::Float64 in xs]
                    end
                    """
                expected = """
                    let xs = rand(3)::Vector{Float64}
                        [x::Float64 for x::Float64 in xs::Vector{Float64}]::Vector{Float64}
                    end
                    """
                @test apply_inlay_hints(code, get_type_inlay_hints(code)) == expected
            end

            let code = """
                    let xs = rand(3)
                        [2x for x::Float64 in xs]
                    end
                    """
                expected = """
                    let xs = rand(3)::Vector{Float64}
                        [2x::Float64 for x::Float64 in xs::Vector{Float64}]::Vector{Float64}
                    end
                    """
                @test apply_inlay_hints(code, get_type_inlay_hints(code)) == expected
            end

            # `if cond` produces a `K"filter"` around the binding.
            let code = """
                    let xs = [1, 2, 3]
                        [x for x::$Int in xs if x > 0]
                    end
                    """
                expected = """
                    let xs = [1, 2, 3]::Vector{$Int}
                        [x::$Int for x::$Int in xs::Vector{$Int} if (x::$Int > 0)::Bool]::Vector{$Int}
                    end
                    """
                @test apply_inlay_hints(code, get_type_inlay_hints(code)) == expected
            end

            # Multi-`for` (cartesian) lowers to nested OCs; both the body types and
            # the result element type resolve precisely.
            let code = """
                    let xs = [1, 2, 3], ys = [1.0]
                        [x + y for x::$Int in xs for y::Float64 in ys]
                    end
                    """
                @test apply_inlay_hints(code, get_type_inlay_hints(code)) == """
                    let xs = [1, 2, 3]::Vector{$Int}, ys = [1.0]::Vector{Float64}
                        [(x::$Int + y::Float64)::Float64 for x::$Int in xs::Vector{$Int} for y::Float64 in ys::Vector{Float64}]::Vector{Float64}
                    end
                    """
            end
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
        # Branching expressions need `(…)::T`; comparison operators also need
        # callee suppression because lowering reuses source tokens as callees.
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

        # Returned branch values should not pollute the surrounding expression's type.
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

        # Kwbody, public method, and kwcall share the funcdef range; prefer the
        # kwbody so the return hint comes from the user's body.
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

        @testset "interpolated string body" begin
            code = """
                function message(x::String)
                    \"\"\"
                    x is \$x

                    \"\"\"
                end
                """
            expected = """
                function message(x::String)::String
                    \"\"\"
                    x is \$x::String

                    \"\"\"::String
                end
                """
            @test apply_inlay_hints(code, get_type_inlay_hints(code)) == expected
        end

        # `where` bounds are user-written signature syntax and should be skipped.
        # The `::Any` body hints below come from the current TypeAnnotation-side
        # static-parameter limitation, not from the inlay-hint pass.
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

        # Declaration-wrapping macrocalls should not emit their own value hints.
        @testset "decoration macros" begin
            @testset "@inline short-form" begin
                code = "@inline f(x::$Int) = x * 2\n"
                expected = "@inline f(x::$Int)::$Int = (x::$Int * 2)::$Int\n"
                @test apply_inlay_hints(code, get_type_inlay_hints(code)) == expected
            end

            @testset "@noinline long-form" begin
                code = """
                    @noinline function f(x::$Int)
                        return x * 2
                    end
                    """
                expected = """
                    @noinline function f(x::$Int)::$Int
                        return (x::$Int * 2)::$Int
                    end
                    """
                @test apply_inlay_hints(code, get_type_inlay_hints(code)) == expected
            end

            @testset "Base.@propagate_inbounds short-form" begin
                code = "Base.@propagate_inbounds f(x::$Int) = x * 2\n"
                expected = "Base.@propagate_inbounds f(x::$Int)::$Int = (x::$Int * 2)::$Int\n"
                @test apply_inlay_hints(code, get_type_inlay_hints(code)) == expected
            end

            # Nested decoration: outer macrocall's last child is itself a macrocall.
            # `is_funcdef_decl` recurses through the inner macrocall to find the
            # funcdef, so both macrocalls' anchors are suppressed.
            @testset "nested decoration" begin
                let code = "@inline Base.@assume_effects :nothrow f(x::$Int) = x * 2\n"
                    expected = "@inline Base.@assume_effects :nothrow f(x::$Int)::$Int = (x::$Int * 2)::$Int\n"
                    @test apply_inlay_hints(code, get_type_inlay_hints(code)) == expected
                end
                let code = "Base.@assume_effects :nothrow @noinline f(x::$Int) = x * 2\n"
                    expected = "Base.@assume_effects :nothrow @noinline f(x::$Int)::$Int = (x::$Int * 2)::$Int\n"
                    @test apply_inlay_hints(code, get_type_inlay_hints(code)) == expected
                end
            end
        end
    end

    @testset "closures handling" begin
        # `type_for_funcdef` accepts `K"opaque_closure_method"` so single-
        # method local closures get their LHS return-type slot filled the
        # same way top-level methods do.
        @testset "single-method closure LHS return type" begin
            @testset "long-form" begin
                code = """
                    function with_closure(xs::Vector{Int})
                        function inner(y::Int)
                            return y * 2
                        end
                        inner(xs[1])
                    end
                    """
                expected = """
                    function with_closure(xs::Vector{Int})::$Int
                        function inner(y::Int)::$Int
                            return (y::$Int * 2)::$Int
                        end
                        inner((xs::Vector{$Int})[1]::$Int)::$Int
                    end
                    """
                @test apply_inlay_hints(code, get_type_inlay_hints(code)) == expected
            end

            @testset "short-form" begin
                code = """
                    function with_closure(xs::Vector{Int})
                        inner(y::Int) = y * 2
                        inner(xs[1])
                    end
                    """
                expected = """
                    function with_closure(xs::Vector{Int})::$Int
                        inner(y::Int)::$Int = (y::$Int * 2)::$Int
                        inner((xs::Vector{$Int})[1]::$Int)::$Int
                    end
                    """
                @test apply_inlay_hints(code, get_type_inlay_hints(code)) == expected
            end
        end

        @testset "captured variables in closure body" begin
            let code = """
                function with_capture(xs::Vector{Int})
                    factor = 10
                    inner(y::Int) = y * factor
                    inner(xs[1])
                end
                """
                expected = """
                    function with_capture(xs::Vector{Int})::$Int
                        factor = 10
                        inner(y::Int)::$Int = (y::$Int * factor::$Int)::$Int
                        inner((xs::Vector{$Int})[1]::$Int)::$Int
                    end
                    """
                @test apply_inlay_hints(code, get_type_inlay_hints(code)) == expected
            end

            # Multiple captures of distinct types.
            let code = """
                function multi_cap(xs::Vector{Int})
                    a = 1
                    b = 2.0
                    inner(y::Int) = y + a + b
                    inner(xs[1])
                end
                """
                expected = """
                    function multi_cap(xs::Vector{Int})::Float64
                        a = 1
                        b = 2.0
                        inner(y::Int)::Float64 = (y::$Int + a::$Int + b::Float64)::Float64
                        inner((xs::Vector{$Int})[1]::$Int)::Float64
                    end
                    """
                @test apply_inlay_hints(code, get_type_inlay_hints(code)) == expected
            end
        end

        @testset "closure with explicit return-type annotation" begin
            code = """
                function with_rt(xs::Vector{Float64})
                    f(y)::Float64 = xs[1] + y
                    f(2.0)
                end
                """
            expected = """
                function with_rt(xs::Vector{Float64})::Float64
                    f(y::Float64)::Float64 = ((xs::Vector{Float64})[1]::Float64 + y::Float64)::Float64
                    f(2.0)::Float64
                end
                """
            @test apply_inlay_hints(code, get_type_inlay_hints(code)) == expected
        end

        @testset "self-recursive closure boxes captures to Any" begin
            code = """
                function self_rec()
                    fact(n::Int)::Int = n <= 1 ? 1 : n * fact(n - 1)
                    fact(5)
                end
                """
            expected = """
                function self_rec()::Any
                    fact(n::Int)::Int = (n::$Int <= 1)::Bool ? 1 : (n::$Int * fact((n::$Int - 1)::$Int)::Any)::Any
                    fact(5)::Any
                end
                """
            @test apply_inlay_hints(code, get_type_inlay_hints(code)) == expected
        end

        # Each method body still gets its LHS return type, but the call site
        # collapses to `Any` with the current TypeAnnotation precision.
        @testset "multi-method local closure" begin
            code = """
                function with_multi(x::Int)
                    f(y::Int) = y + 1
                    f(y::String) = string(y, "!")
                    f(x)
                end
                """
            @test apply_inlay_hints(code, get_type_inlay_hints(code)) == """
                function with_multi(x::Int)::Any
                    f(y::Int)::$Int = (y::$Int + 1)::$Int
                    f(y::String)::String = string(y::String, "!")::String
                    f(x::$Int)::Any
                end
                """
        end

        @testset "anonymous lambda" begin
            code = """
                let f = (x::Int) -> x + 1
                    f(rand(Int))
                end
                """
            expected = """
                let f = (x::Int) -> (x::$Int + 1)::$Int
                    f(rand(Int)::$Int)::$Int
                end
                """
            @test apply_inlay_hints(code, get_type_inlay_hints(code)) == expected
        end

        # No-paren `x -> body`: parameter byte range overlaps with the OC binding's
        # `PartialOpaque` slot, so the generic path is suppressed (it would emit a
        # misleading `x::OpaqueClosure{…}` hint); the dedicated parameter hint reads
        # the refined argt off the constructed OC instead.
        @testset "no-paren anonymous lambda" begin
            code = """
                let g = x -> 2x
                    g(1.0)
                end
                """
            expected = """
                let g = x::Float64 -> 2x::Float64
                    g(1.0)
                end
                """
            @test apply_inlay_hints(code, get_type_inlay_hints(code)) == expected
        end

        # Multi-call-site lambda: the parameter hint shows the join of the observed
        # call-site argtypes, matching the signature view the body is inferred under.
        @testset "multi-call-site lambda parameter" begin
            code = """
                function genfunc(x::Float64)
                    f = x -> 2x
                    o1 = f(x)
                    o2 = f(rand(Int))
                    o1, o2
                end
                """
            expected = """
                function genfunc(x::Float64)::Tuple{Float64, $Int}
                    f = x::Union{Float64, $Int} -> 2x::Union{Float64, $Int}
                    o1 = f(x::Float64)::Float64
                    o2 = f(rand(Int)::$Int)::$Int
                    (o1::Float64, o2::$Int)::Tuple{Float64, $Int}
                end
                """
            @test apply_inlay_hints(code, get_type_inlay_hints(code)) == expected
        end

        # Parameter hints apply to every local-closure definition form, not just
        # arrow lambdas: anonymous `function (…) … end`, and named local closures
        # in both long and short form (the function name is skipped, and the
        # return-type hint still coexists with the parameter hints).
        @testset "anonymous function form" begin
            code = """
                function outer(s::String)
                    create = function (key, val, flag::Bool)
                        key * val
                    end
                    create(s, s, true)
                end
                """
            expected = """
                function outer(s::String)::String
                    create = function (key::String, val::String, flag::Bool)
                        (key::String * val::String)::String
                    end
                    create(s::String, s::String, true)::String
                end
                """
            @test apply_inlay_hints(code, get_type_inlay_hints(code)) == expected
        end

        @testset "named local closure (long form)" begin
            code = """
                function outer(s::String)
                    function inner(key, val)
                        key * val
                    end
                    inner(s, s)
                end
                """
            expected = """
                function outer(s::String)::String
                    function inner(key::String, val::String)::String
                        (key::String * val::String)::String
                    end
                    inner(s::String, s::String)::String
                end
                """
            @test apply_inlay_hints(code, get_type_inlay_hints(code)) == expected
        end

        @testset "named local closure (short form)" begin
            code = """
                function outer(s::String)
                    inner(key, val) = key * val
                    inner(s, s)
                end
                """
            expected = """
                function outer(s::String)::String
                    inner(key::String, val::String)::String = (key::String * val::String)::String
                    inner(s::String, s::String)::String
                end
                """
            @test apply_inlay_hints(code, get_type_inlay_hints(code)) == expected
        end

        # Top-level methods are not opaque closures, so their parameters get no
        # call-site-refined hints (only the body uses and return type do).
        @testset "top-level method parameters stay un-hinted" begin
            code = """
                function topf(key, val)
                    key * val
                end
                """
            expected = """
                function topf(key, val)::Any
                    (key::Any * val::Any)::Any
                end
                """
            @test apply_inlay_hints(code, get_type_inlay_hints(code)) == expected
        end

        # A destructuring parameter is a single closure argument, but each component
        # is annotated from its own resolved type (consistent with for-loop iteration
        # variable destructuring), not from the aggregate argument type.
        @testset "destructuring parameter (plain)" begin
            code = """
                let ps = [1=>"a", 2=>"b"]
                    foreach(ps) do (k, v)
                        k, v
                    end
                end
                """
            expected = """
                let ps = [1=>"a", 2=>"b"]::Vector{Pair{$Int, String}}
                    foreach(ps::Vector{Pair{$Int, String}}) do (k::$Int, v::String)
                        (k::$Int, v::String)::Tuple{$Int, String}
                    end
                end
                """
            @test apply_inlay_hints(code, get_type_inlay_hints(code)) == expected
        end

        @testset "destructuring parameter (nested)" begin
            code = """
                let ts = [(1, (2.0, "x"))]
                    foreach(ts) do (a, (b, c))
                        a, b, c
                    end
                end
                """
            expected = """
                let ts = [(1, (2.0, "x"))]::Vector{Tuple{$Int, Tuple{Float64, String}}}
                    foreach(ts::Vector{Tuple{$Int, Tuple{Float64, String}}}) do (a::$Int, (b::Float64, c::String))
                        (a::$Int, b::Float64, c::String)::Tuple{$Int, Float64, String}
                    end
                end
                """
            @test apply_inlay_hints(code, get_type_inlay_hints(code)) == expected
        end

        # Property destructuring (`(; a, b)`) reuses each name as both a binding and a
        # `getproperty` field-name symbol; the field-name `Symbol` must not pollute the
        # binding's type (it would otherwise surface as `Union{Int, Symbol}`).
        @testset "destructuring parameter (property)" begin
            code = """
                let nts = [(a=1, b="x")]
                    foreach(nts) do (; a, b)
                        a, b
                    end
                end
                """
            expected = """
                let nts = [(a=1, b="x")]::Vector{@NamedTuple{a::$Int, b::String}}
                    foreach(nts::Vector{@NamedTuple{a::$Int, b::String}}) do (; a::$Int, b::String)
                        (a::$Int, b::String)::Tuple{$Int, String}
                    end
                end
                """
            @test apply_inlay_hints(code, get_type_inlay_hints(code)) == expected
        end

        # A parenthesized two-parameter arrow `(a, b) -> …` is two separate parameters,
        # not a destructuring of one — each gets its own call-site-refined type.
        @testset "two-parameter arrow is not destructuring" begin
            code = """
                function f(x::Float64)
                    g = (a, b) -> a + b
                    g(x, 1) + g(2, 3)
                end
                """
            expected = """
                function f(x::Float64)::Float64
                    g = (a::Union{Float64, $Int}, b::$Int) -> (a::Union{Float64, $Int} + b::$Int)::Union{Float64, $Int}
                    (g(x::Float64, 1)::Float64 + g(2, 3))::Float64
                end
                """
            @test apply_inlay_hints(code, get_type_inlay_hints(code)) == expected
        end

        # `K"do"`, its wrapped call, and its lambda share the end byte; avoid
        # triplicated hints after `end`.
        @testset "typed do-block" begin
            code = """
                let xs = [1, 2, 3]
                    map(xs) do y::Int
                        y + 1
                    end
                end
                """
            expected = """
                let xs = [1, 2, 3]::Vector{$Int}
                    map(xs::Vector{$Int}) do y::Int
                        (y::$Int + 1)::$Int
                    end::Vector{$Int}
                end
                """
            @test apply_inlay_hints(code, get_type_inlay_hints(code)) == expected
        end

        # Verbatim lambda parameter ranges should cover every comma-separated parameter.
        @testset "multi-argument do-block" begin
            code = """
                let xs = [1, 2, 3]
                    foldl(xs; init=0) do acc::Int, x::Int
                        acc + x
                    end
                end
                """
            expected = """
                let xs = [1, 2, 3]::Vector{$Int}
                    foldl(xs::Vector{$Int}; init=0) do acc::Int, x::Int
                        (acc::$Int + x::$Int)::$Int
                    end::$Int
                end
                """
            @test apply_inlay_hints(code, get_type_inlay_hints(code)) == expected
        end

        # Untyped `do x` resolves precisely via closure argument-type refinement —
        # the parameter hint, the body, and `map`'s result element type.
        @testset "untyped do-block" begin
            code = """
                let xs = [1, 2, 3]
                    map(xs) do x
                        x * 2
                    end
                end
                """
            @test apply_inlay_hints(code, get_type_inlay_hints(code)) == """
                let xs = [1, 2, 3]::Vector{$Int}
                    map(xs::Vector{$Int}) do x::$Int
                        (x::$Int * 2)::$Int
                    end::Vector{$Int}
                end
                """
        end

        @testset "nested closures (two levels)" begin
            code = """
                function nested2(xs::Vector{Int})
                    function oc(x::Int)
                        ic(y::Int) = x + y
                        ic(2)
                    end
                    oc(xs[1])
                end
                """
            expected = """
                function nested2(xs::Vector{Int})::$Int
                    function oc(x::Int)::$Int
                        ic(y::Int)::$Int = (x::$Int + y::$Int)::$Int
                        ic(2)::$Int
                    end
                    oc((xs::Vector{$Int})[1]::$Int)::$Int
                end
                """
            @test apply_inlay_hints(code, get_type_inlay_hints(code)) == expected
        end
    end

    @testset "struct definitions" begin
        # Type declarations should not get noise like `x::Int::Any`.
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

    # User-written module/import syntax should not receive nested hints.
    @testset "using / import statements produce no hints" begin
        let code = """
            using Pkg
            using JET: CC, JET
            using JuliaSyntax: JuliaSyntax as JS
            import Markdown: Markdown
            """
            @test apply_inlay_hints(code, get_type_inlay_hints(code)) == code
        end
    end

    # User-written `x::Int = 1` should not become `x::Int::$Int`.
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

    # Bottom-type hints get a tooltip because `Union{}` is easy to misread.
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
            @test h.tooltip isa MarkupContent
            @test h.tooltip.kind == MarkupKind.Markdown
            @test occursin("provably never produces a value", h.tooltip.value)
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
        # Reuse source parens instead of rendering noisy `((expr)::T)` shapes.
        @testset "parenthesized inner-wrap expression" begin
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

        # Reuse source parens so `.foo` still binds outside the type assertion.
        @testset "dotted projection on parenthesized base" begin
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
        @testset "dotted projection on parenthesized inner-wrap expression" begin
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

        # Call, index, and chained-call parens are not decorative.
        @testset "function-call parens are not decorative" begin
            # The inner `x + y` still needs its own wrap inside `f(...)`.
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
end

end # module test_inlay_hint
