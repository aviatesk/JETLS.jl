module test_type_annotation

using Test
using JETLS
using JETLS: JL, JS
using JETLS.TypeAnnotation
using JETLS.JET: CC

# Run the full pipeline a typical caller would: parse → lower → infer.
# Returns `(fi, inferred)` so byte-range queries against `inferred` line up with `code`.
function type_annotate(code::AbstractString, mod::Module = Main; expect_degrade::Bool=false)
    fi = JETLS.FileInfo(1, code, @__FILE__)
    st0_top = JETLS.build_syntax_tree(fi)
    inferred = Ref{JETLS.SyntaxTreeC}()
    JETLS.iterate_toplevel_tree(st0_top) do st0::JS.SyntaxTree
        result = @something get_inferrable_tree(st0, mod) return nothing
        (; ctx3, st3) = result
        inferred[] = infer_toplevel_tree(ctx3, st3, mod)
        return nothing
    end
    if expect_degrade
        @test !isassigned(inferred)
        return nothing
    else
        @test isassigned(inferred)
    end
    return fi, inferred[]
end

# Byte range of the literal substring `s` inside `code`, in `JS.byte_range`
# coordinates. Tests use ASCII so char and byte indices coincide.
range_of(code::AbstractString, s::AbstractString) =
    @something findfirst(s, code) error(lazy"`$s` is not found in $code")

# Walk the surface tree of `code` and return the byte range of the first
# encountered node of the given `kind`. Use this when you need the exact
# `JS.byte_range` of a kind whose source includes leading trivia (e.g.
# `K"comparison"` in tail position swallows the space between `return` and the
# first operand) — `findfirst`-based `range_of` mismatches in those cases.
function range_of_kind(code::AbstractString, kind::JS.Kind)
    fi = JETLS.FileInfo(1, code, @__FILE__)
    st0_top = JETLS.build_syntax_tree(fi)
    return @something JETLS.traverse(st0_top) do node::JS.SyntaxTree
        JS.kind(node) === kind || return nothing
        return JETLS.TraversalReturn(JS.byte_range(node); terminate=true)
    end error(lazy"no surface node of kind $kind in $code")
end

# Convenience: query helpers strip Const wrappers via `widenconst` so tests
# don't need to special-case the constant-prop result on simple literals.
widenconst(typ) = CC.widenconst(@something typ return nothing)

# Walk the surface tree, query `get_type_for_range` at every node whose
# source text matches `text`, and return the resulting types. Use this to
# assert that **every** occurrence of an identifier (or expression) gets
# an annotation, not just the first one.
function query_all_types(
        fi::JETLS.FileInfo, inferred::JETLS.SyntaxTreeC, text::AbstractString
    )
    st0_top = JETLS.build_syntax_tree(fi)
    types = Any[]
    JETLS.traverse(st0_top) do node::JS.SyntaxTree
        if JS.sourcetext(node) == text
            push!(types, get_type_for_range(inferred, JS.byte_range(node)))
        end
        return nothing
    end
    return types
end

@testset "get_inferrable_tree" begin
    # `iterate_toplevel_tree` walks each top-level expression independently;
    # `get_inferrable_tree` is invoked once per chunk. Verify it lowers all
    # of them, not just the first.
    @testset "valid input returns inferrable tree for each chunk" begin
        let code = """
            let x = 1
                x
            end
            function add_one(y::Int)
                y + 1
            end
            const C = 42
            """
            fi = JETLS.FileInfo(1, code, @__FILE__)
            st0_top = JETLS.build_syntax_tree(fi)
            results = []
            JETLS.iterate_toplevel_tree(st0_top) do st0::JS.SyntaxTree
                r = get_inferrable_tree(st0, Main)
                r === nothing || push!(results, r)
                return nothing
            end
            @test length(results) == 3
            for (; ctx3, st3) in results
                @test ctx3 isa JL.VariableAnalysisContext
                @test st3 isa JS.SyntaxTree
                @test infer_toplevel_tree(ctx3, st3, @__MODULE__) isa JETLS.SyntaxTreeC
            end
        end
    end

    # Lowering errors (e.g. undefined macros) are reported as `nothing` so
    # callers don't need to wrap every call in `try`.
    @testset "lowering failure returns nothing" begin
        let code = "@__undefined_macro_for_test__ xyz"
            fi = JETLS.FileInfo(1, code, @__FILE__)
            st0_top = JETLS.build_syntax_tree(fi)
            JETLS.iterate_toplevel_tree(st0_top) do st0::JS.SyntaxTree
                @test isnothing(get_inferrable_tree(st0, @__MODULE__))
                return nothing
            end
        end
    end
end

@testset "Inference robustness across method shapes" begin
    # Method bodies are inferred as their own anonymous chunks: argtypes are
    # resolved from the lowered svec, no full-analysis-defined `Method` is
    # required for the body's user-named slots.
    @testset "annotates non-kwarg method body" begin
        let code = """
            function add_one(x::Int)
                x + 1
            end
            """
            _, inferred = type_annotate(code)
            @test widenconst(get_type_for_range(inferred, range_of(code, "x + 1"))) === Int
        end
    end

    # Kwarg lowering produces three `:method` 3-arg statements (kwbody,
    # public, kwcall); the user's body lives in kwbody and we expect its
    # user-named slots to resolve.
    @testset "annotates kwarg method body" begin
        let code = """
            function sum_xs(xs::Vector{Int}; init::Int = 0)
                s = init + xs[1]
                s
            end
            """
            _, inferred = type_annotate(code)
            @test widenconst(get_type_for_range(inferred, range_of(code, "init + xs[1]"))) === Int
        end
    end

    # Closures are hoisted to toplevel `:method` 3-arg statements by
    # `JL.convert_closures`, so the closure body itself is inferred.
    @testset "annotates closure" begin
        let code = """
            function with_closure(xs::Vector{Int})
                inner(y::Int) = y * 2
                inner(xs[1])
            end
            """
            _, inferred = type_annotate(code)
            @testset "body" begin
                @test widenconst(get_type_for_range(inferred, range_of(code, "y * 2"))) === Int
            end

            # Limitation: from the enclosing function's body, calling a closure
            # dispatches on a synthetic type that isn't in `context_module`, so the
            # call site degrades to `Any`. Recorded as `@test_broken` to flip when
            # the synthetic-name lookup gap is closed.
            @testset "closure call from outer body" begin
                @test_broken widenconst(get_type_for_range(inferred, range_of(code, "inner(xs[1])"))) === Int
            end
        end

        # Limitation: a captured variable inside the closure body is accessed via
        # the synthetic self type's field. Since the self slot resolves to `Any`,
        # the captured variable infers as `Any` and `Any`-typedness propagates
        # through any operation involving it. The reference inside the closure
        # would otherwise be `Int` once the gap is closed.
        @testset "captured variable in closure body" begin
            let code = """
                function with_capture(xs::Vector{Int})
                    factor = 10
                    inner(y::Int) = y * factor
                    inner(xs[1])
                end
                """
                _, inferred = type_annotate(code)
                @test_broken widenconst(get_type_for_range(inferred, range_of(code, "y * factor"))) === Int
            end
        end
    end

    # `(::Type{NamedTuple{names}})(::Tuple{Union{T1,T2}})` and similar constructor calls
    # have a method whose `spec_types` carries free type vars
    # (`(NT::Type{NamedTuple{names}})(args::Tuple) where names`); for thunk-MI inference,
    # `abstract_call_gf_by_type` refuses to infer any non-`isdispatchtuple` match,
    # collapsing the result to `Any`. `ASTTypeAnnotator`'s explicit override of
    # `bail_out_toplevel_call` allows the precise parameterized result.
    @testset "type constructor with Union-typed tuple element" begin
        let code = """
            function f(b::Bool)
                NamedTuple{(:a,)}((b ? "Z" : nothing,))
            end
            """
            _, inferred = type_annotate(code)
            rng = range_of(code, "NamedTuple{(:a,)}((b ? \"Z\" : nothing,))")
            @test widenconst(get_type_for_range(inferred, rng)) <:
                NamedTuple{(:a,), <:Tuple{Union{Nothing, String}}}
        end
    end

    # Limitation: `Expr(:static_parameter, i)` references inside a parametric
    # method body. The chunk's MI is a thunk MI (`def isa Module`); CC's
    # `sptypes_from_meth_instance` forces `EMPTY_SPTYPES` for toplevel MIs,
    # so a body expression that depends on `T` can't recover its bound and
    # falls through to `Any`.
    @testset "static-parameter reference in parametric method body" begin
        let code = """
            function make_zero(::Type{T}) where T <: Number
                convert(T, 1)
            end
            """
            _, inferred = type_annotate(code)
            # A static-parameter-aware path would land somewhere `<: Number`.
            @test_broken widenconst(get_type_for_range(inferred, range_of(code, "convert(T, 1)"))) <: Number
        end
    end
end

@testset "Surface-kind dispatch (get_type_for_range)" begin
    # Generic fallback: a single typed node lives at the byte range, so the
    # tmerge path collapses to that node's type.
    @testset "generic byte-range fallback" begin
        let code = "let x = [1.0]; x; end"
            _, inferred = type_annotate(code)
            @test widenconst(get_type_for_range(inferred, range_of(code, "[1.0]"))) ===
                Vector{Float64}
        end
    end

    # When no node matches the byte range, the result is `nothing` so the caller
    # can distinguish "no annotation" from "annotation says `nothing`".
    @testset "returns nothing for non-matching range" begin
        let code = "let x = 1; x; end"
            _, inferred = type_annotate(code)
            @test get_type_for_range(inferred, 10_000:10_001) === nothing
        end
    end

    @testset "regular call dispatches to the user's call result" begin
        let code = "let v = [1.0, 2.0]; sum(v); end"
            _, inferred = type_annotate(code)
            @test widenconst(get_type_for_range(inferred, range_of(code, "sum(v)"))) ===
                Float64
        end
    end

    # Kwcall lowering plants the kwargs `NamedTuple` / `Tuple` constructors at the
    # same byte range as the user's call. K"call" dispatch picks the last K"call",
    # which is the user-visible result.
    @testset "kwcall returns user's result type, not kwargs constructor" begin
        let code = """
            let strs = String["10", "20"]
                s = strs[1]
                parse(Int, s; base = 10)
            end
            """
            _, inferred = type_annotate(code)
            typ = widenconst(get_type_for_range(
                inferred, range_of(code, "parse(Int, s; base = 10)")))
            @test typ === Int
            @test !occursin("NamedTuple", string(typ))
            @test !occursin("Tuple", string(typ))
        end
    end

    # `_str` macros expand to a single Core call.
    @testset "string macro returns the expansion result type" begin
        let code = "lazy\"hello\""
            _, inferred = type_annotate(code)
            @test widenconst(get_type_for_range(
                inferred, range_of(code, "lazy\"hello\""))) <: Base.LazyString
        end
    end

    # `@something x return false` expands to a let-block whose tail call yields
    # `Int` once the `nothing` branch is ruled out — every helper inside the
    # expansion shares the macrocall's byte range, so naive tmerge would mix in
    # boolean checks etc.
    @testset "general macrocall returns the expansion tail-call type" begin
        let code = """
            let x = Union{Int,Nothing}[1, nothing][1]
                @something x return false
            end
            """
            _, inferred = type_annotate(code)
            @test widenconst(get_type_for_range(
                inferred, range_of(code, "@something x return false"))) === Int
        end
    end

    # for/while loops always evaluate to `nothing`. The iteration machinery
    # (`iterate(xs)`, `iterate(xs, state)`, `=== nothing` checks, body return) all
    # places typed nodes at the loop's byte range, so naive tmerge would produce a
    # chaotic `Union{Nothing, Bool, Tuple{…}}`-ish result.
    @testset "loops" begin
        @testset "for loop returns Const(nothing)" begin
            let code = """
                let xs = [1, 2, 3]
                    for x in xs
                        print(x)
                    end
                end
                """
                _, inferred = type_annotate(code)
                rng = range_of(code, "for x in xs\n        print(x)\n    end")
                @test get_type_for_range(inferred, rng) === Core.Const(nothing)
            end
        end
        @testset "while loop returns Const(nothing)" begin
            let code = """
                let i = 0
                    while i < 3
                        i += 1
                    end
                end
                """
                _, inferred = type_annotate(code)
                rng = range_of(code, "while i < 3\n        i += 1\n    end")
                @test get_type_for_range(inferred, rng) === Core.Const(nothing)
            end
        end
    end

    # `K"function"` / `K"macro"` dispatch returns the method body's `tmerge`d
    # return-statement type. Naive lookup would either pull in unrelated nodes
    # inside the body (slot reads, intermediate calls) or land on dispatcher
    # methods synthesized for default args / kwargs (which share the funcdef
    # byte range and return `Any`).
    @testset "function and macro definitions" begin
        @testset "single return path" begin
            let code = """
                function add_one(x::Int)
                    return x + 1
                end
                """
                _, inferred = type_annotate(code)
                rng = range_of(code, rstrip(code, '\n'))
                @test widenconst(get_type_for_range(inferred, rng)) === Int
            end
        end

        # Multiple `return` statements `tmerge` into a Union.
        @testset "branching returns tmerge" begin
            let code = """
                function maybe_int(x::Int)
                    if x > 0
                        return x
                    else
                        return nothing
                    end
                end
                """
                _, inferred = type_annotate(code)
                rng = range_of(code, rstrip(code, '\n'))
                typ = widenconst(get_type_for_range(inferred, rng))
                @test typ === Union{Int, Nothing}
            end
        end

        # Macros are also K"method" lowered, so the same dispatch applies.
        @testset "macro definition" begin
            let code = """
                macro just_one()
                    return :(1 + 1)
                end
                """
                _, inferred = type_annotate(code)
                rng = range_of(code, rstrip(code, '\n'))
                @test widenconst(get_type_for_range(inferred, rng)) === Expr
            end
        end

        @testset "positional default-argument function" begin
            let code = """
                function add_or_zero(x::Int = 0)
                    return x + 1
                end
                """
                _, inferred = type_annotate(code)
                rng = range_of(code, rstrip(code, '\n'))
                @test widenconst(get_type_for_range(inferred, rng)) === Int
            end
        end

        @testset "multiple positional defaults" begin
            let code = """
                function f(x::Int = 0, y::Int = 1, z::Int = 2)
                    x + y + z
                end
                """
                _, inferred = type_annotate(code)
                rng = range_of(code, rstrip(code, '\n'))
                @test widenconst(get_type_for_range(inferred, rng)) === Int
            end
        end

        @testset "kwarg function definition" begin
            let code = """
                function sum_with_init(xs::Vector{Int}; init::Int = 0)
                    s = init
                    for x in xs
                        s += x
                    end
                    s
                end
                """
                _, inferred = type_annotate(code)
                rng = range_of(code, rstrip(code, '\n'))
                @test widenconst(get_type_for_range(inferred, rng)) === Int
            end
        end
    end

    # Branching expressions: value type is the `tmerge` of all branches. Each
    # group below pairs a `K"="` RHS case with a tail-position case (lowering
    # of branches differs between the two contexts).
    @testset "branching expressions" begin
        @testset "chained comparison in `=` RHS" begin
            let code = """
                let x = 1
                    r = 0 < x < 10
                end
                """
                _, inferred = type_annotate(code)
                rng = range_of(code, "0 < x < 10")
                @test widenconst(get_type_for_range(inferred, rng)) === Bool
            end
        end
        @testset "chained comparison in tail position" begin
            let code = """
                function f(x::Int)
                    return 0 < x < 10
                end
                """
                _, inferred = type_annotate(code)
                rng = range_of_kind(code, JS.K"comparison")
                @test widenconst(get_type_for_range(inferred, rng)) === Bool
            end
        end

        @testset "&& in `=` RHS" begin
            let code = """
                function f(x::Int)
                    r = x > 0 && x
                    r
                end
                """
                _, inferred = type_annotate(code)
                rng = range_of(code, "x > 0 && x")
                @test widenconst(get_type_for_range(inferred, rng)) === Union{Bool, Int}
            end
        end
        @testset "&& in tail position" begin
            let code = """
                function f(x::Int)
                    return x > 0 && x
                end
                """
                _, inferred = type_annotate(code)
                rng = range_of_kind(code, JS.K"&&")
                @test widenconst(get_type_for_range(inferred, rng)) === Union{Bool, Int}
            end
        end
        @testset "|| in tail position" begin
            let code = """
                function f(x::Int)
                    return x > 0 || nothing
                end
                """
                _, inferred = type_annotate(code)
                rng = range_of_kind(code, JS.K"||")
                @test widenconst(get_type_for_range(inferred, rng)) === Union{Bool, Nothing}
            end
        end

        # Ternary's surface kind is `K"if"` (same as block-form), but the
        # inferred tree's provenance keeps the parser's `K"?"` — the dispatch
        # has to handle both kinds to cover ternary in any context.
        @testset "ternary in `=` RHS" begin
            let code = """
                function f(b::Bool, x::Int)
                    r = b ? x : nothing
                    r
                end
                """
                _, inferred = type_annotate(code)
                rng = range_of(code, "b ? x : nothing")
                @test widenconst(get_type_for_range(inferred, rng)) === Union{Int, Nothing}
            end
        end
        @testset "ternary in tail position" begin
            let code = """
                function f(b::Bool, x::Int)
                    return b ? x : nothing
                end
                """
                _, inferred = type_annotate(code)
                rng = range_of_kind(code, JS.K"if")
                @test widenconst(get_type_for_range(inferred, rng)) === Union{Int, Nothing}
            end
        end

        @testset "if-block in tail position" begin
            let code = """
                function f(b::Bool)
                    return if b
                        1
                    else
                        nothing
                    end
                end
                """
                _, inferred = type_annotate(code)
                rng = range_of_kind(code, JS.K"if")
                @test widenconst(get_type_for_range(inferred, rng)) === Union{Int, Nothing}
            end
        end
        @testset "if-elseif-else" begin
            let code = """
                function f(a::Bool, b::Bool)
                    if a
                        1
                    elseif b
                        "x"
                    else
                        nothing
                    end
                end
                """
                _, inferred = type_annotate(code)
                rng = range_of_kind(code, JS.K"if")
                typ = widenconst(get_type_for_range(inferred, rng))
                @test typ === Union{Int, String, Nothing}
            end
        end
    end
end

@testset "Multi-position / composition behaviors" begin
    # Tuple-destructuring assignment `a, b = sincos(x)` lowers to two slot
    # assignments via `iterate(t)` / `iterate(t, state)`. The slot positions
    # have to pick up the element type, not just `Any`, so each `a` / `b`
    # reference resolves to `Float64` after destructuring.
    @testset "slot types from tuple destructuring" begin
        let code = """
            function f(xs::Vector{Float64})
                a, b = sincos(xs[1])
                a + b
            end
            """
            _, inferred = type_annotate(code)
            @test widenconst(get_type_for_range(
                inferred, range_of(code, "sincos(xs[1])"))) === Tuple{Float64, Float64}
            @test widenconst(get_type_for_range(
                inferred, range_of(code, "a + b"))) === Float64
        end
    end

    # Chained dotted access on a dereferenced `Ref`: `Ref(...)[].field`
    # exercises K"." → K"ref" → K"call" composition. Each link in the chain
    # has to land its own `:type` for editor features (hover / inlay) to
    # show useful information when the cursor is anywhere along the access.
    @testset "property access via dereferenced Ref" begin
        let code = "Ref((; scale = 2.0))[].scale"
            _, inferred = type_annotate(code)
            @test widenconst(get_type_for_range(
                inferred, range_of(code, "Ref((; scale = 2.0))"))) ===
                Base.RefValue{NamedTuple{(:scale,), Tuple{Float64}}}
            @test widenconst(get_type_for_range(
                inferred, range_of(code, "Ref((; scale = 2.0))[]"))) ===
                NamedTuple{(:scale,), Tuple{Float64}}
            @test widenconst(get_type_for_range(
                inferred, range_of(code, "Ref((; scale = 2.0))[].scale"))) ===
                Float64
        end
    end

    # Multi-reference exhaustiveness: every occurrence of `cfg` / `raw` /
    # `result` in the body should be annotated, not just the first. Catches
    # regressions where annotation only reaches the binding site or the last
    # assignment.
    @testset "every reference of a local gets annotated" begin
        let code = """
            function f(xs::Vector{Float64})
                cfg = (scale = 2.0, offset = 1)
                raw = abs(sin(cos(cfg.scale)))
                result = raw * cfg.offset
                result
            end
            """
            fi, inferred = type_annotate(code)
            cfg_types = query_all_types(fi, inferred, "cfg")
            @test length(cfg_types) == 3 # binding + two field accesses
            @test all(t -> widenconst(t) ===
                NamedTuple{(:scale, :offset), Tuple{Float64, Int}}, cfg_types)
            raw_types = query_all_types(fi, inferred, "raw")
            @test length(raw_types) == 2 # binding + reference in `raw * cfg.offset`
            @test all(t -> widenconst(t) === Float64, raw_types)
            result_types = query_all_types(fi, inferred, "result")
            @test length(result_types) == 2 # binding + tail reference
            @test all(t -> widenconst(t) === Float64, result_types)
        end
    end

    # Type narrowing across control flow: each `xxx` reference within a
    # branch should pick up its branch-narrowed type (Int / String).
    @testset "narrowed type across control flow" begin
        let code = """
            function f(xxx::Union{Int, String})
                if xxx isa Int
                    sin(xxx)
                else
                    uppercase(xxx)
                end
            end
            """
            fi, inferred = type_annotate(code)
            types = query_all_types(fi, inferred, "xxx")
            @test any(t -> widenconst(t) === Int, types)
            @test any(t -> widenconst(t) === String, types)
        end
    end
end

@testset "Pipeline-level edge cases" begin
    # LSP requests routinely arrive on incomplete source as the user types.
    # The pipeline (`get_inferrable_tree` → `infer_toplevel_tree`) must
    # degrade gracefully — never throw — and the caller decides whether to
    # show partial results or skip annotation for that chunk.
    @testset "incomplete syntax doesn't crash the pipeline" begin
        # lowering refuses to consume the K"error" leaf
        @test isnothing(type_annotate("sin(", @__MODULE__; expect_degrade=true))
        # Same property when the K"error" is buried inside a function body —
        # the outer `function ... end` shape parses fine, but lowering still
        # refuses the whole chunk and the pipeline degrades to `nothing`
        # instead of throwing.
        let code = """
            function f(x::Some{String})
                x.
            end
            """
            @test isnothing(type_annotate(code, @__MODULE__; expect_degrade=true))
        end
    end

    # Top-level bare assignment `x = sin(1.0)` lowers to a chunk that
    # prepends `Core.declare_global(Main, :x, true)` + `Expr(:latestworld)`
    # before the RHS. Without intervention the world bump would make
    # `abstract_eval_globalref` widen `Main.sin` to `Any` and the call to
    # infer as `Any`; `strip_latestworld!` neutralizes the directive
    # before inference so the RHS keeps a precise `Float64`.
    @testset "top-level bare assignment RHS" begin
        let code = "global x = sin(1.0)"
            _, inferred = type_annotate(code)
            @test widenconst(get_type_for_range(inferred, range_of(code, "sin(1.0)"))) === Float64
        end
    end
end

end # module test_type_annotation
