module test_type_annotation

using Test
using JETLS
using JETLS: CC, JL, JS
using JETLS.TypeAnnotation
using JETLS.TypeAnnotation: get_inferrable_tree, infer_toplevel_tree

module type_annotate_module end

# Run the full TypeAnnotation pipeline through its exported driver and return
# `(fi, ctx)` for the toplevel containing byte 1 — i.e. the *first* top-level
# statement in `code`. The tests below either pass single-toplevel snippets
# (the common case) or place the statement under test first. `fi` is returned
# so tests can use `xy_to_offset` etc. against the source.
function type_annotate(code::AbstractString, context_module::Module = type_annotate_module)
    fi = JETLS.FileInfo(1, code, @__FILE__)
    st0_top = JETLS.build_syntax_tree(fi)
    ctx = build_inferred_context_at(st0_top, context_module, 1:1)
    @test ctx !== nothing
    return fi, ctx
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
function query_all_types(fi::JETLS.FileInfo, ctx::InferredTreeContext, text::AbstractString)
    st0_top = JETLS.build_syntax_tree(fi)
    types = Any[]
    JETLS.traverse(st0_top) do node::JS.SyntaxTree
        if JS.sourcetext(node) == text
            push!(types, get_type_for_range(ctx, JS.byte_range(node)))
        end
        return nothing
    end
    return types
end

# Smoke-test for the single-shot driver — the rest of the file exercises the
# composed `build_inferred_context_at` + `get_type_for_range` form via
# `type_annotate`, so this just verifies the convenience wrapper composes the
# same answer for one query.
@testset "infer_type_at_range" begin
    let code = "sin(1.0)"
        fi = JETLS.FileInfo(1, code, @__FILE__)
        st0_top = JETLS.build_syntax_tree(fi)
        typ = infer_type_at_range(st0_top, Main, range_of(code, "sin(1.0)"))
        @test typ === Core.Const(sin(1.0))
    end
end

@testset HierarchicalTestSet "get_inferrable_tree" begin
    # `iterate_toplevel_tree` walks each top-level expression independently;
    # `get_inferrable_tree` is invoked once per thunk. Verify it lowers all
    # of them, not just the first.
    @testset "valid input returns inferrable tree for each thunk" begin
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

@testset HierarchicalTestSet "Inference accuracy and robustness" begin
    # Method bodies are inferred as their own anonymous thunks: argtypes are
    # resolved from the lowered svec, no full-analysis-defined `Method` is
    # required for the body's user-named slots.
    @testset "annotates non-kwarg method body" begin
        let code = """
            function add_one(x::Int)
                x + 1
            end
            """
            _, ctx = type_annotate(code)
            @test widenconst(get_type_for_range(ctx, range_of(code, "x + 1"))) === Int
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
            _, ctx = type_annotate(code)
            @test widenconst(get_type_for_range(ctx, range_of(code, "init + xs[1]"))) === Int
        end
    end

    # Single-method local closures are converted to `OpaqueClosure` form via
    # `JL.rewrite_local_closures_to_opaque` before `convert_closures`, so CC
    # resolves both the body and the call site precisely (synthetic-struct
    # closures would collapse both to `Any` since their type isn't materialized
    # in `context_module`).
    @testset "annotates closure" begin
        let code = """
            function with_closure(xs::Vector{Int})
                inner(y::Int) = y * 2
                inner(xs[1])
            end
            """
            _, ctx = type_annotate(code)
            @testset "body" begin
                @test widenconst(get_type_for_range(ctx, range_of(code, "y * 2"))) === Int
            end
            @testset "closure call from outer body" begin
                @test widenconst(get_type_for_range(ctx, range_of(code, "inner(xs[1])"))) === Int
            end
            # `type_for_funcdef` walks `K"opaque_closure_method"` (mirroring its `K"method"`
            # branch) so the funcdef's byte range surfaces the OC body's return type.
            @testset "funcdef byte range" begin
                rng = range_of(code, "inner(y::Int) = y * 2")
                @test widenconst(get_type_for_range(ctx, rng)) === Int
            end
        end

        # Captured variables flow through the OC's env tuple; the body's
        # `getfield(self, i)` access (emitted by `convert_closures` in opaque
        # mode) resolves precisely from CC's PartialOpaque env type.
        @testset "captured variable in closure body" begin
            let code = """
                function with_capture(xs::Vector{Int})
                    factor = 10
                    inner(y::Int) = y * factor
                    inner(xs[1])
                end
                """
                _, ctx = type_annotate(code)
                @test widenconst(get_type_for_range(ctx, range_of(code, "y * factor"))) === Int
            end
        end

        # Multiple captures of different types — the OC's env tuple keeps each
        # capture's type independently; integer-positional access in the body
        # resolves each precisely.
        @testset "multiple captures of different types" begin
            let code = """
                function multi_cap(xs::Vector{Int})
                    a = 1
                    b = 2.0
                    inner(y::Int) = y + a + b
                    inner(xs[1])
                end
                """
                _, ctx = type_annotate(code)
                @test widenconst(get_type_for_range(ctx, range_of(code, "y + a + b"))) === Float64
                @test widenconst(get_type_for_range(ctx, range_of(code, "inner(xs[1])"))) === Float64
            end
        end

        # Nested closures: the inner closure is registered eagerly via
        # `Base.uncompressed_ir` walk of each outer OC's body, so by the time
        # CC's depth-first inference reaches the inner OC's call site, the
        # inner Method already has its citree mapping in `oc_body_trees`.
        @testset "nested closures (two levels)" begin
            let code = """
                function nested2(xs::Vector{Int})
                    function oc(x::Int)
                        ic(y::Int) = x + y
                        ic(2)
                    end
                    oc(xs[1])
                end
                """
                _, ctx = type_annotate(code)
                @test widenconst(get_type_for_range(ctx, range_of(code, "x + y"))) === Int
                @test widenconst(get_type_for_range(ctx, range_of(code, "ic(2)"))) === Int
                @test widenconst(get_type_for_range(ctx, range_of(code, "oc(xs[1])"))) === Int
            end
        end

        # Two independent single-method closures in the same scope. The rewrite
        # fires for both and their OCs don't interfere (each gets its own LHS
        # binding), so each call site infers precisely.
        @testset "sibling closures (different names)" begin
            let code = """
                function siblings(xs::Vector{Int})
                    a(x::Int) = x + 1
                    b(x::Int) = x * 2
                    (a(xs[1]), b(xs[1]))
                end
                """
                _, ctx = type_annotate(code)
                @test widenconst(get_type_for_range(ctx, range_of(code, "a(xs[1])"))) === Int
                @test widenconst(get_type_for_range(ctx, range_of(code, "b(xs[1])"))) === Int
            end
        end

        # Closure A captures a variable, closure B captures closure A. CC sees
        # B's env contain a `PartialOpaque` for A and dispatches A's call
        # precisely.
        @testset "closure capturing another closure" begin
            let code = """
                function chain(xs::Vector{Int})
                    x = 10
                    a(y::Int) = x + y
                    b(z::Int) = a(z) * 2
                    b(xs[1])
                end
                """
                _, ctx = type_annotate(code)
                @test widenconst(get_type_for_range(ctx, range_of(code, "a(z) * 2"))) === Int
                @test widenconst(get_type_for_range(ctx, range_of(code, "b(xs[1])"))) === Int
            end
        end

        # Body annotations are always signature-based — same model as top-level method
        # bodies. Body inference uses the eager `most_general_argtypes(po.typ)`
        # specialization, and per-call-site specializations only update the call site
        # annotation (`finishinfer!`'s marker is consumed once at the eager `finishinfer!`
        # and skipped for subsequent dispatches). The untyped multi-call shape below is the
        # most observable demonstration: under "last-write-wins" the body would depend on
        # which call site CC infers last; here it should be `Any`.
        @testset "closure body annotation is signature-based" begin
            let code = """
                function multi_call(xs::Vector{Float64}, ys::Vector{Int})
                    f(x) = 2x
                    (f(xs[1]), f(ys[1]))
                end
                """
                _, ctx = type_annotate(code)
                @test widenconst(get_type_for_range(ctx, range_of(code, "2x"))) === Any
                @test widenconst(get_type_for_range(ctx, range_of(code, "f(xs[1])"))) === Float64
                @test widenconst(get_type_for_range(ctx, range_of(code, "f(ys[1])"))) === Int
            end
        end

        # Reassigned captures get boxed by `convert_closures` and the body
        # reads `Core.Box.contents::Any` — JL-side erasure that the rewrite
        # can't lift, so we just assert the resulting `Any`.
        @testset "reassigned captured variable boxes to Any" begin
            let code = """
                function box_reassign(xs::Vector{Int})
                    counter = 0
                    inner(y::Int) = (counter += y; counter)
                    inner(xs[1])
                end
                """
                _, ctx = type_annotate(code)
                @test widenconst(get_type_for_range(ctx, range_of(code, "inner(xs[1])"))) === Any
            end
        end

        # Mutation outside the closure body that targets a captured variable
        # also forces boxing — same Box-erasure as the reassignment case.
        @testset "captured variable mutated after closure creation" begin
            # Take a dummy argument so the def signature and call expression
            # are distinguishable substrings — `range_of` would otherwise
            # match the def first.
            let code = """
                function box_outer_mut(xs::Vector{Int})
                    counter = 0
                    inner(_) = counter
                    counter += xs[1]
                    inner(nothing)
                end
                """
                _, ctx = type_annotate(code)
                @test widenconst(get_type_for_range(ctx, range_of(code, "inner(nothing)"))) === Any
            end
        end

        # Closures with `::RT` annotation: the rewrite preserves the lambda's
        # return-type assertion (we pass the entire `lambda` subtree into
        # `K"_opaque_closure"`), so JL's `convert_closures` keeps the
        # body-level typeassert. The call site here flows the `PartialOpaque`
        # directly without a `widenconst` boundary, so the precise rt comes
        # from `abstract_call_opaque_closure`'s body inference, independent of
        # any refinement to `PartialOpaque.typ`.
        @testset "closure with return type annotation" begin
            let code = """
                function with_rt_annot(xs::Vector{Float64})
                    f(y)::Float64 = xs[1] + y
                    f(2.0)
                end
                """
                _, ctx = type_annotate(code)
                @test widenconst(get_type_for_range(ctx, range_of(code, "f(2.0)"))) === Float64
            end
            let code = """
                function with_rt_annot(xs::Vector{Float64})
                    f(y)::Int = xs[1] + y
                    f(2.0)
                end
                """
                _, ctx = type_annotate(code)
                @test widenconst(get_type_for_range(ctx, range_of(code, "f(2.0)"))) === Int
            end
            # `::typeof(captured)` resolves through the OC's env tuple, so the
            # return type assertion still infers precisely.
            let code = """
                function with_computed_rt(xs::Vector{Float64})
                    x = xs[1]
                    f(y)::typeof(x) = x + y
                    f(2.0)
                end
                """
                _, ctx = type_annotate(code)
                @test widenconst(get_type_for_range(ctx, range_of(code, "f(2.0)"))) === Float64
            end
        end

        # Self-referencing closures need boxing for the self capture (the
        # binding has no value at OC construction time), and `Box.contents`
        # is `::Any` — same JL-side erasure as the reassigned-capture case,
        # also present for native closures, so we just assert the `Any`.
        @testset "self-recursive closure" begin
            let code = """
                function self_rec()
                    fact(n::Int)::Int = n <= 1 ? 1 : n * fact(n - 1)
                    fact(5)
                end
                """
                _, ctx = type_annotate(code)
                @test widenconst(get_type_for_range(ctx, range_of(code, "fact(5)"))) === Any
            end
        end

        # Multi-method local closures fall through to JL's synthetic struct
        # path, but `infer_toplevel_tree` skips `Core.eval`, so the synthetic
        # type never reaches `context_module` and the call collapses. Lifting
        # this needs sandbox-materialization on the JETLS side — broken until.
        @testset "multi-method local closure" begin
            let code = """
                function with_multi_method(x::Int)
                    f(y::Int) = y + 1
                    f(y::String) = string(y, "!")
                    f(x)
                end
                """
                _, ctx = type_annotate(code)
                @test_broken widenconst(get_type_for_range(ctx, range_of(code, "f(x)"))) === Int
            end
        end

        @testset "do-block as closure argument to map" begin
            # Typed `do x::Int`: `ASTTypeAnnotator`'s override of
            # `abstract_eval_new_opaque_closure` refines `PartialOpaque.typ`'s
            # rt from `OC{argt, T} where T` to `OC{argt, Int}`. The resulting
            # `Generator{Vector{Int}, OC{argt, Int}}` is fully concrete, so
            # the OC's rt also survives `Base._collect`'s
            # `Compiler.return_type(first, …)` probe and sizes the result
            # vector to `Vector{Int}`. The override is JETLS-only because the
            # refinement is IPO-unsound for upstream Julia (`typeof(oc)`'s `R`
            # is fixed at construction by `rt_ub`, not the body's actual
            # return); see JuliaLang/julia#61718.
            let code = """
                function with_do_typed(xs::Vector{Int})
                    map(xs) do x::Int
                        x * 2
                    end
                end
                """
                _, ctx = type_annotate(code)
                @test widenconst(get_type_for_range(ctx, range_of(code, "x * 2"))) === Int
                map_call = range_of(code, "map(xs) do x::Int\n        x * 2\n    end")
                @test widenconst(get_type_for_range(ctx, map_call)) === Vector{Int}
            end

            # Untyped `do x`: the body is annotated from the eager
            # `most_general_argtypes(Tuple{Any})` specialization (signature view, like a
            # top-level untyped method body), so `x * 2` is `Any`. That matches what native
            # closure inference would expose for the method body.
            # The call-site annotation widens to `Vector` though: the OC's rt parameter
            # stays `T<:Any` (no concrete rt to bind from the eager body), so
            # `Generator{Vector{Int}, F<:OC{Tuple{Any}, T}}` is non-concrete and
            # `Base._collect` can't recover the element type. Native closures dispatch
            # through the synthetic struct's method table and infer this as `Vector{Int}`;
            # matching that here would need call-site-aware refinement (thus kept `@test_broken`).
            let code = """
                function with_do(xs::Vector{Int})
                    map(xs) do x
                        x * 2
                    end
                end
                """
                _, ctx = type_annotate(code)
                @test widenconst(get_type_for_range(ctx, range_of(code, "x * 2"))) === Any
                map_call = range_of(code, "map(xs) do x\n        x * 2\n    end")
                @test_broken widenconst(get_type_for_range(ctx, map_call)) === Vector{Int}
            end
        end
    end

    # `MustAliasesLattice` / `InterMustAliasesLattice` overrides on
    # `ASTTypeAnnotator` propagate branch-narrowed types back to subsequent
    # reads of the same `slot.field` on immutable, concretely-typed objects
    # — without them, each `getfield` call on a Union-typed field returns
    # the unrefined Union even inside the guarded branch.
    @testset "MustAlias narrowing on field accesses" begin
        let code = """
            function f(s::Some{Union{Nothing,Int}})
                if !isnothing(s.value)
                    s.value
                else
                    0
                end
            end
            """
            fi, ctx = type_annotate(code)
            types = query_all_types(fi, ctx, "s.value")
            @test any(t -> widenconst(t) === Int, types)
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
            _, ctx = type_annotate(code)
            rng = range_of(code, "NamedTuple{(:a,)}((b ? \"Z\" : nothing,))")
            @test widenconst(get_type_for_range(ctx, rng)) <:
                NamedTuple{(:a,), <:Tuple{Union{Nothing, String}}}
        end
    end

    # Limitation: `Expr(:static_parameter, i)` references inside a parametric
    # method body. The thunk's MI is a thunk MI (`def isa Module`); CC's
    # `sptypes_from_meth_instance` forces `EMPTY_SPTYPES` for toplevel MIs,
    # so a body expression that depends on `T` can't recover its bound and
    # falls through to `Any`.
    @testset "static-parameter reference in parametric method body" begin
        let code = """
            function make_zero(::Type{T}) where T <: Number
                convert(T, 1)
            end
            """
            _, ctx = type_annotate(code)
            # A static-parameter-aware path would land somewhere `<: Number`.
            @test_broken widenconst(get_type_for_range(ctx, range_of(code, "convert(T, 1)"))) <: Number
        end
    end
end

module myfunc_module
myfunc(x::Int) = x + 1
end

# Helper macro for the "user-defined macro injecting K\"return\"" test below:
# the macrocall site `@return_zero` carries no `return` in its source,
# but the macro's expansion does — so `st3` (post-macro-expansion) is the
# only tree where the `K"return"` is visible. Walking `st0` would miss it
# and the IR `K"return"` it produces would mis-classify as a synthetic
# tail-position return.
module test_return_zero_module
macro return_zero()
    return quote
        return 0
    end
end
end

@testset HierarchicalTestSet "Surface-kind dispatch (get_type_for_range)" begin
    # Generic fallback: a single typed node lives at the byte range, so the
    # tmerge path collapses to that node's type.
    @testset "generic byte-range fallback" begin
        let code = "let x = [1.0]; x; end"
            _, ctx = type_annotate(code)
            @test widenconst(get_type_for_range(ctx, range_of(code, "[1.0]"))) ===
                Vector{Float64}
        end
    end

    # When no node matches the byte range, the result is `nothing` so the caller
    # can distinguish "no annotation" from "annotation says `nothing`".
    @testset "returns nothing for non-matching range" begin
        let code = "let x = 1; x; end"
            _, ctx = type_annotate(code)
            @test get_type_for_range(ctx, 10_000:10_001) === nothing
        end
    end

    # OC construction scaffolding shares its byte range with the user's yield expression
    # for comprehension/`map` lambdas; queries at that range should surface only the body's
    # value type. See `tmerge_at_range`.
    @testset "OC construction noise at user expression byte range" begin
        @testset "comprehension with typed iterator yield" begin
            let code = "let xs = rand(3); [yld for yld::Float64 in xs]; end"
                _, ctx = type_annotate(code)
                # First `yld` in source order is the yield expression.
                @test widenconst(get_type_for_range(ctx, range_of(code, "yld"))) === Float64
            end
        end
        @testset "typed comprehension with typed iterator yield" begin
            let code = "let xs = rand(3); Float64[yld for yld::Float64 in xs]; end"
                _, ctx = type_annotate(code)
                # First `yld` in source order is the yield expression.
                @test widenconst(get_type_for_range(ctx, range_of(code, "yld"))) === Float64
            end
        end

        @testset "comprehension with typed iterator with filter on iterator" begin
            let code = "let xs = rand(3); [yld for yld::Float64 in xs if yld > 0]; end"
                _, ctx = type_annotate(code)
                # First `yld` in source order is the yield expression.
                @test widenconst(get_type_for_range(ctx, range_of(code, "yld"))) === Float64
            end
        end

        @testset "comprehension with typed tuple yield" begin
            let code = """
                let xs = rand(3), ys = rand(3)
                    [(x, y) for (x, y)::Tuple{Float64,Float64} in zip(xs, ys)]
                end
                """
                _, ctx = type_annotate(code)
                # First `(x, y)` in source order is the yield expression.
                @test widenconst(get_type_for_range(ctx, range_of(code, "(x, y)"))) ===
                    Tuple{Float64,Float64}
            end
        end

        # Multi-`for` lowers to nested OCs whose construction sites overlap source-wise;
        # the inner-body slot must still resolve precisely. See `populate_oc_body_scope!`.
        @testset "nested OC scopes (multi-for comprehension)" begin
            let code = """
                let xs = [1, 2, 3], ys = [1.0]
                    [x + y for x::Int in xs for y::Float64 in ys]
                end
                """
                _, ctx = type_annotate(code)
                rng = range_of(code, "x + y")
                @test widenconst(get_type_for_range(ctx, rng)) === Float64
            end
        end

        # An explicit closure binding's reference surfaces `OpaqueClosure{…}` legitimately
        # — the filter must not strip it.
        @testset "explicit closure binding reference still surfaces the OC type" begin
            let code = "let f = (x::Int) -> x + 1; f; end"
                _, ctx = type_annotate(code)
                # Reference `f` is the second occurrence (`; f;` near the end).
                ref_rng = let i = findlast("f", code)
                    first(i):last(i)
                end
                @test widenconst(get_type_for_range(ctx, ref_rng)) <: Core.OpaqueClosure
            end
        end
    end

    @testset "regular call dispatches to the user's call result" begin
        let code = "let v = [1.0, 2.0]; sum(v); end"
            _, ctx = type_annotate(code)
            @test widenconst(get_type_for_range(ctx, range_of(code, "sum(v)"))) ===
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
            _, ctx = type_annotate(code)
            typ = widenconst(get_type_for_range(
                ctx, range_of(code, "parse(Int, s; base = 10)")))
            @test typ === Int
            @test !occursin("NamedTuple", string(typ))
            @test !occursin("Tuple", string(typ))
        end
    end

    # `(; a, b)` / `(a = x, b = y)` should surface the user-visible
    # `@NamedTuple{…}` value, not widen with the kwargs-constructor scaffolding
    # that lowering plants at the same byte range.
    @testset "NamedTuple literal returns the constructor's result type" begin
        @testset "explicit-semicolon form" begin
            let code = "let a = 1, b = 2; (; a, b); end"
                _, ctx = type_annotate(code)
                typ = widenconst(get_type_for_range(ctx, range_of(code, "(; a, b)")))
                @test typ === @NamedTuple{a::Int, b::Int}
            end
        end
        @testset "implicit `key=value` form" begin
            let code = "let x = 1; (a = x, b = 2x); end"
                _, ctx = type_annotate(code)
                typ = widenconst(get_type_for_range(ctx, range_of(code, "(a = x, b = 2x)")))
                @test typ === @NamedTuple{a::Int, b::Int}
            end
        end
        @testset "positional tuple unaffected" begin
            let code = "let x = 1, y = 2.0; (x, y); end"
                _, ctx = type_annotate(code)
                typ = widenconst(get_type_for_range(ctx, range_of(code, "(x, y)")))
                @test typ === Tuple{Int, Float64}
            end
        end
    end

    # `_str` macros expand to a single Core call.
    @testset "string macro returns the expansion result type" begin
        let code = "lazy\"hello\""
            _, ctx = type_annotate(code)
            @test widenconst(get_type_for_range(
                ctx, range_of(code, "lazy\"hello\""))) <: Base.LazyString
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
            _, ctx = type_annotate(code)
            @test widenconst(get_type_for_range(
                ctx, range_of(code, "@something x return false"))) === Int
        end
    end

    # `@invoke` / `@invokelatest` lower to `Core.invoke(f, Tuple{...}, args...)`
    # and `Base.invokelatest(f, args...)` respectively. Both calls must dispatch
    # to the user-visible result, not to internal scaffolding.
    @testset "@invoke dispatches via Core.invoke and surfaces its result type" begin
        let code = "let xs = [1, 2, 3]; @invoke length(xs::AbstractArray); end"
            _, ctx = type_annotate(code)
            @test widenconst(get_type_for_range(
                ctx, range_of(code, "@invoke length(xs::AbstractArray)"))) === Int
        end
    end

    # `Base.invokelatest` is opaque to inference (the dispatched method may live
    # in a future world), so the result type is `Any`. This still confirms the
    # macro lowered to a real call rather than degrading inference entirely.
    @testset "@invokelatest surfaces a call type (Any) without degrading inference" begin
        let code = "let v = [1.0, 2.0]; @invokelatest sum(v); end"
            _, ctx = type_annotate(code)
            @test widenconst(get_type_for_range(
                ctx, range_of(code, "@invokelatest sum(v)"))) === Any
        end
    end

    # `T[expr for ...]` should surface the constructed `Array{T,N}` type, not
    # widen to `Any` from the inlined loop's scaffolding calls.
    @testset "typed comprehension returns the constructed array type" begin
        @testset "1D with local-var iter length" begin
            let code = "let n = 5; Int[i*2 for i in 1:n]; end"
                _, ctx = type_annotate(code)
                @test widenconst(get_type_for_range(
                    ctx, range_of(code, "Int[i*2 for i in 1:n]"))) === Vector{Int}
            end
        end
        @testset "1D with non-Int element" begin
            let code = "Float64[i*2.0 for i in 1:5]"
                _, ctx = type_annotate(code)
                @test widenconst(get_type_for_range(
                    ctx, range_of(code, "Float64[i*2.0 for i in 1:5]"))) === Vector{Float64}
            end
        end
        @testset "2D" begin
            let code = "Int[i*j for i in 1:3, j in 1:4]"
                _, ctx = type_annotate(code)
                @test widenconst(get_type_for_range(
                    ctx, range_of(code, "Int[i*j for i in 1:3, j in 1:4]"))) === Matrix{Int}
            end
        end
        @testset "untyped comprehension still works via tmerge fallback" begin
            let code = "[i for i in 1:5]"
                _, ctx = type_annotate(code)
                @test widenconst(get_type_for_range(
                    ctx, range_of(code, "[i for i in 1:5]"))) === Vector{Int}
            end
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
                _, ctx = type_annotate(code)
                rng = range_of(code, "for x in xs\n        print(x)\n    end")
                @test get_type_for_range(ctx, rng) === Core.Const(nothing)
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
                _, ctx = type_annotate(code)
                rng = range_of(code, "while i < 3\n        i += 1\n    end")
                @test get_type_for_range(ctx, rng) === Core.Const(nothing)
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
                _, ctx = type_annotate(code)
                rng = range_of(code, rstrip(code, '\n'))
                @test widenconst(get_type_for_range(ctx, rng)) === Int
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
                _, ctx = type_annotate(code)
                rng = range_of(code, rstrip(code, '\n'))
                typ = widenconst(get_type_for_range(ctx, rng))
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
                _, ctx = type_annotate(code)
                rng = range_of(code, rstrip(code, '\n'))
                @test widenconst(get_type_for_range(ctx, rng)) === Expr
            end
        end

        @testset "positional default-argument function" begin
            let code = """
                function add_or_zero(x::Int = 0)
                    return x + 1
                end
                """
                _, ctx = type_annotate(code)
                rng = range_of(code, rstrip(code, '\n'))
                @test widenconst(get_type_for_range(ctx, rng)) === Int
            end
        end

        @testset "multiple positional defaults" begin
            let code = """
                function f(x::Int = 0, y::Int = 1, z::Int = 2)
                    x + y + z
                end
                """
                _, ctx = type_annotate(code)
                rng = range_of(code, rstrip(code, '\n'))
                @test widenconst(get_type_for_range(ctx, rng)) === Int
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
                _, ctx = type_annotate(code)
                rng = range_of(code, rstrip(code, '\n'))
                @test widenconst(get_type_for_range(ctx, rng)) === Int
            end
        end

        # Macro-wrapped funcdef (`@inline f(x) = body`) — `flattened_provenance` for nodes
        # inside the expansion is `[macrocall, function]`. Registering every entry in
        # `surface_kind_index` makes the inner funcdef's span dispatch to
        # `type_for_funcdef`, while the macrocall's outer span still routes to
        # `type_for_macroexpansion` independently.
        @testset "macro-wrapped funcdef registers both provenance spans" begin
            let code = """
                @inline f(x::Int) = x + 1
                """
                _, ctx = type_annotate(code)
                @test widenconst(get_type_for_range(ctx, range_of_kind(code, JS.K"="))) === Int
                @test get_type_for_range(ctx, range_of_kind(code, JS.K"macrocall")) !== nothing
            end
        end

        # Querying just the function name's byte range at the def site used to
        # return `Union{typeof(f), Type{typeof(f)}}` because the method's
        # argtypes svec lowers to a `core.Typeof(f)` call sharing that range.
        # `tmerge_at_range` filters this scaffolding so the user-visible value
        # (`Const(f)`) survives intact.
        @testset "method-def function name surfaces the value, not Union with Type{T}" begin
            let code = """
                function myfunc(x::Int)
                    x + 1
                end
                """
                _, ctx = type_annotate(code, myfunc_module)
                typ = get_type_for_range(ctx, range_of(code, "myfunc"))
                @test typ isa Core.Const
                @test typ.val === myfunc_module.myfunc
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
                _, ctx = type_annotate(code)
                rng = range_of(code, "0 < x < 10")
                @test widenconst(get_type_for_range(ctx, rng)) === Bool
            end
        end
        @testset "chained comparison in tail position" begin
            let code = """
                function f(x::Int)
                    return 0 < x < 10
                end
                """
                _, ctx = type_annotate(code)
                rng = range_of_kind(code, JS.K"comparison")
                @test widenconst(get_type_for_range(ctx, rng)) === Bool
            end
        end

        @testset "&& in `=` RHS" begin
            let code = """
                function f(x::Int)
                    r = x > 0 && x
                    r
                end
                """
                _, ctx = type_annotate(code)
                rng = range_of(code, "x > 0 && x")
                @test widenconst(get_type_for_range(ctx, rng)) === Union{Bool, Int}
            end
        end
        @testset "&& in tail position" begin
            let code = """
                function f(x::Int)
                    return x > 0 && x
                end
                """
                _, ctx = type_annotate(code)
                rng = range_of_kind(code, JS.K"&&")
                @test widenconst(get_type_for_range(ctx, rng)) === Union{Bool, Int}
            end
        end
        @testset "|| in tail position" begin
            let code = """
                function f(x::Int)
                    return x > 0 || nothing
                end
                """
                _, ctx = type_annotate(code)
                rng = range_of_kind(code, JS.K"||")
                @test widenconst(get_type_for_range(ctx, rng)) === Union{Bool, Nothing}
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
                _, ctx = type_annotate(code)
                rng = range_of(code, "b ? x : nothing")
                @test widenconst(get_type_for_range(ctx, rng)) === Union{Int, Nothing}
            end
        end
        @testset "ternary in tail position" begin
            let code = """
                function f(b::Bool, x::Int)
                    return b ? x : nothing
                end
                """
                _, ctx = type_annotate(code)
                rng = range_of_kind(code, JS.K"if")
                @test widenconst(get_type_for_range(ctx, rng)) === Union{Int, Nothing}
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
                _, ctx = type_annotate(code)
                rng = range_of_kind(code, JS.K"if")
                @test widenconst(get_type_for_range(ctx, rng)) === Union{Int, Nothing}
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
                _, ctx = type_annotate(code)
                rng = range_of_kind(code, JS.K"if")
                typ = widenconst(get_type_for_range(ctx, rng))
                @test typ === Union{Int, String, Nothing}
            end
        end
        # A user-written `return X` inside a branching expression exits the
        # function entirely; `X` must not contribute to the enclosing
        # expression's value (only the implicit fall-through does). When
        # `X` is itself a tail-recursing form (`if` / `&&` / `||` / ternary
        # / comparison / `block`), lowering splits it into per-branch tail
        # returns at narrower byte ranges than `X` itself, so a literal
        # byte-range match doesn't suffice. The walker over `st3`
        # (post-desugaring, post-macro-expansion) handles all these uniform
        # cases since they're already collapsed to `K"if"` / `K"block"` /
        # nested `K"return"`.
        #
        # In every case below, the outer `if b ... end` should resolve to
        # `Nothing` (the implicit fall-through is the only path that reaches
        # `out`). `try` / `catch` is not yet covered (recorded as
        # `@test_broken`).
        @testset "user return inside branching expression" begin
            @testset "simple value" begin
                let code = """
                    function format(x::Union{Int, Nothing})
                        out = if x isa Int
                            return string(x; base = 16)
                        end
                        return out
                    end
                    """
                    _, ctx = type_annotate(code)
                    rng = range_of_kind(code, JS.K"if")
                    @test get_type_for_range(ctx, rng) === Core.Const(nothing)
                end
            end
            @testset "wraps another if-else" begin
                let code = """
                    function f(b::Bool, c::Bool)
                        out = if b
                            return if c; 1; else; "x"; end
                        end
                        out
                    end
                    """
                    _, ctx = type_annotate(code)
                    # Inner if (the user's literal return value) tmerges its
                    # branches correctly, as for any branching expression.
                    inner_rng = range_of(code, "if c; 1; else; \"x\"; end")
                    @test widenconst(get_type_for_range(ctx, inner_rng)) === Union{Int, String}
                    outer_rng = range_of_kind(code, JS.K"if")
                    @test widenconst(get_type_for_range(ctx, outer_rng)) === Nothing
                end
            end
            @testset "wraps if-elseif-else" begin
                let code = """
                    function f(b::Bool, c::Bool, d::Bool)
                        out = if b
                            return if c; 1; elseif d; 2; else; 3; end
                        end
                        out
                    end
                    """
                    _, ctx = type_annotate(code)
                    outer_rng = range_of_kind(code, JS.K"if")
                    @test widenconst(get_type_for_range(ctx, outer_rng)) === Nothing
                end
            end
            @testset "wraps ternary" begin
                let code = """
                    function f(b::Bool, c::Bool)
                        out = if b
                            return c ? 1 : "x"
                        end
                        out
                    end
                    """
                    _, ctx = type_annotate(code)
                    outer_rng = range_of_kind(code, JS.K"if")
                    @test widenconst(get_type_for_range(ctx, outer_rng)) === Nothing
                end
            end
            @testset "wraps &&" begin
                let code = """
                    function f(b::Bool, c::Bool, x::Int)
                        out = if b
                            return c && x
                        end
                        out
                    end
                    """
                    _, ctx = type_annotate(code)
                    outer_rng = range_of_kind(code, JS.K"if")
                    @test widenconst(get_type_for_range(ctx, outer_rng)) === Nothing
                end
            end
            @testset "wraps ||" begin
                let code = """
                    function f(b::Bool, c::Bool, x::Int)
                        out = if b
                            return c || x
                        end
                        out
                    end
                    """
                    _, ctx = type_annotate(code)
                    outer_rng = range_of_kind(code, JS.K"if")
                    @test widenconst(get_type_for_range(ctx, outer_rng)) === Nothing
                end
            end
            @testset "wraps chained comparison" begin
                let code = """
                    function f(b::Bool, x::Int)
                        out = if b
                            return 0 < x < 10
                        end
                        out
                    end
                    """
                    _, ctx = type_annotate(code)
                    outer_rng = range_of_kind(code, JS.K"if")
                    @test widenconst(get_type_for_range(ctx, outer_rng)) === Nothing
                end
            end
            @testset "wraps begin/end block" begin
                let code = """
                    function f(b::Bool, x::Int)
                        out = if b
                            return begin x; "tail" end
                        end
                        out
                    end
                    """
                    _, ctx = type_annotate(code)
                    outer_rng = range_of_kind(code, JS.K"if")
                    @test widenconst(get_type_for_range(ctx, outer_rng)) === Nothing
                end
            end
            @testset "wraps try/catch" begin
                let code = """
                    function f(b::Bool)
                        out = if b
                            return try; 1; catch; "x"; end
                        end
                        out
                    end
                    """
                    _, ctx = type_annotate(code)
                    outer_rng = range_of_kind(code, JS.K"if")
                    @test widenconst(get_type_for_range(ctx, outer_rng)) === Nothing
                end
            end
        end

        # A `return` inside a macro expansion is invisible at the surface
        # but visible in `st3` (post-expansion). The walker picks it up
        # the same as a directly-written `return`.
        @testset "return hidden by macro expansion" begin
            # `@something args... return X` expands such that the literal
            # `return X` exits the function when none of the args are
            # non-`nothing`. Without filtering the macro-expanded
            # `K"return"` SSA, the outer `if`'s value would leak the
            # return-value type (`String` below).
            @testset "Base.@something with `return` fallback" begin
                let code = """
                    function f(x::Union{Int, Nothing}, y::Union{Int, Nothing})
                        out = if x isa Int
                            @something y return "no value"
                        end
                        out
                    end
                    """
                    _, ctx = type_annotate(code)
                    outer_rng = range_of_kind(code, JS.K"if")
                    @test widenconst(get_type_for_range(ctx, outer_rng)) === Union{Int, Nothing}
                    # `out` at its trailing-line use site: the `String` from
                    # `return "no value"` exits the function rather than
                    # flowing through, so `out`'s narrowed type omits it
                    # (it's `Union{Int, Nothing}`, not `Union{Int, Nothing, String}`).
                    out_use_rng = findlast("out", code)
                    @test widenconst(get_type_for_range(ctx, out_use_rng)) === Union{Int, Nothing}
                end
            end

            # Unlike `@something y return ...` above (where `return` is in
            # the macrocall args and thus visible in `st0`), here the user
            # source has no `return` token at all — only the macro's
            # expansion emits one. `st0`-only walking would miss it.
            @testset "user-defined macro injecting K\"return\"" begin
                let code = """
                    function f(cond::Bool)
                        out = if cond
                            @return_zero
                        end
                        out
                    end
                    """
                    _, ctx = type_annotate(code, test_return_zero_module)
                    outer_rng = range_of_kind(code, JS.K"if")
                    # `Int` (from `return 0`) would leak in without st3 walking:
                    # `Union{Int, Nothing}` would be the wrong answer.
                    @test widenconst(get_type_for_range(ctx, outer_rng)) === Nothing
                end
            end
        end
    end
end

@testset HierarchicalTestSet "Multi-position / composition behaviors" begin
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
            _, ctx = type_annotate(code)
            @test widenconst(get_type_for_range(
                ctx, range_of(code, "sincos(xs[1])"))) === Tuple{Float64, Float64}
            @test widenconst(get_type_for_range(
                ctx, range_of(code, "a + b"))) === Float64
        end
    end

    # Chained dotted access on a dereferenced `Ref`: `Ref(...)[].field`
    # exercises K"." → K"ref" → K"call" composition. Each link in the chain
    # has to land its own `:type` for editor features (hover / inlay) to
    # show useful information when the cursor is anywhere along the access.
    @testset "property access via dereferenced Ref" begin
        let code = "Ref((; scale = 2.0))[].scale"
            _, ctx = type_annotate(code)
            @test widenconst(get_type_for_range(
                ctx, range_of(code, "Ref((; scale = 2.0))"))) ===
                Base.RefValue{NamedTuple{(:scale,), Tuple{Float64}}}
            @test widenconst(get_type_for_range(
                ctx, range_of(code, "Ref((; scale = 2.0))[]"))) ===
                NamedTuple{(:scale,), Tuple{Float64}}
            @test widenconst(get_type_for_range(
                ctx, range_of(code, "Ref((; scale = 2.0))[].scale"))) ===
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
            fi, ctx = type_annotate(code)
            cfg_types = query_all_types(fi, ctx, "cfg")
            @test length(cfg_types) == 3 # binding + two field accesses
            @test all(t -> widenconst(t) ===
                NamedTuple{(:scale, :offset), Tuple{Float64, Int}}, cfg_types)
            raw_types = query_all_types(fi, ctx, "raw")
            @test length(raw_types) == 2 # binding + reference in `raw * cfg.offset`
            @test all(t -> widenconst(t) === Float64, raw_types)
            result_types = query_all_types(fi, ctx, "result")
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
            fi, ctx = type_annotate(code)
            types = query_all_types(fi, ctx, "xxx")
            @test any(t -> widenconst(t) === Int, types)
            @test any(t -> widenconst(t) === String, types)
        end
    end

end

@testset HierarchicalTestSet "Pipeline-level edge cases" begin
    # JuliaSyntax doesn't bail on incomplete source — it produces a partial tree with
    # `K"error"` siblings around the well-formed parts. `get_inferrable_tree` strips those
    # error nodes, and JuliaLowering happily lowers what remains, so type queries on the
    # well-formed portion come back accurate. This is what powers completion past `.` on
    # a half-typed buffer.
    @testset "partial inference on incomplete source" begin
        # Toplevel `sin(`: the trailing `(error-t)` arg is stripped, leaving `(call sin)`.
        # The `sin` reference itself still resolves — usable for signature help on a half-typed call.
        let code = "sin("
            _, ctx = type_annotate(code)
            @test get_type_for_range(ctx, range_of(code, "sin")) === Core.Const(sin)
        end
        # K"error" buried inside a function body: the body parses to `(. x (inert end))`
        # plus a sibling K"error", stripping the latter leaves a well-formed function.
        # The body's `x` reference picks up the parameter's declared type, which is
        # what completion on `x.|` needs.
        let code = """
            function f(x::Some{String})
                x.
            end
            """
            fi, ctx = type_annotate(code)
            x_types = query_all_types(fi, ctx, "x")
            @test any(t -> widenconst(t) === Some{String}, x_types)
        end
        # Locally bound variable with no declared type: `s` gets `Float64` from `sum(xs)`,
        # which the analysis must recover — AST reading alone can't.
        let code = """
            function f(xs::Vector{Float64})
                s = sum(xs)
                s.
            end
            """
            fi, ctx = type_annotate(code)
            s_types = query_all_types(fi, ctx, "s")
            @test any(t -> widenconst(t) === Float64, s_types)
        end
    end

    # Top-level bare assignment `x = sin(1.0)` lowers to a thunk that
    # prepends `Core.declare_global(Main, :x, true)` + `Expr(:latestworld)`
    # before the RHS. Without intervention the world bump would make
    # `abstract_eval_globalref` widen `Main.sin` to `Any` and the call to
    # infer as `Any`; `strip_latestworld!` neutralizes the directive
    # before inference so the RHS keeps a precise `Float64`.
    @testset "top-level bare assignment RHS" begin
        let code = "global x = sin(1.0)"
            _, ctx = type_annotate(code)
            @test widenconst(get_type_for_range(ctx, range_of(code, "sin(1.0)"))) === Float64
        end
    end
end

@testset HierarchicalTestSet "get_matches_for_range" begin
    # CC's dispatch picks the `sin` method matching `Float64` for `sin(1.0)`;
    # matches should narrow to just that one method even though `sin` has many overloads.
    @testset "narrows to the dispatched method" begin
        let code = "sin(1.0)"
            _, ctx = type_annotate(code)
            ms = get_matches_for_range(ctx, range_of(code, "sin(1.0)"))
            @test ms isa Vector{Core.MethodMatch}
            @test length(ms) == 1
            m = only(ms).method
            @test m.name === :sin
            # The dispatched method covers `Float64`; could be a parametric
            # `where T<:Union{Float32,Float64}` definition in Base.
            @test Tuple{typeof(sin), Float64} <: m.sig
        end
    end

    # `K"ref"` (`xs[i]`) lowers to a `getindex` call, so its matches expose
    # the dispatched `getindex` method.
    @testset "exposes operator dispatch for K\"ref\"" begin
        let code = "let arr = Int[1, 2, 3], i = 1; arr[i]; end"
            _, ctx = type_annotate(code)
            ms = get_matches_for_range(ctx, range_of(code, "arr[i]"))
            @test ms isa Vector{Core.MethodMatch}
            @test length(ms) == 1
            m = only(ms).method
            @test m.name === :getindex
            # The dispatched method covers `Float64`; could be a parametric
            # `where T<:Union{Float32,Float64}` definition in Base.
            @test Tuple{typeof(getindex), Vector{Int}, Int} <: m.sig
        end
    end

    # Non-call surfaces (a local binding occurrence, an `if` expression, …) don't carry a
    # `:matches` attribute on any `K"call"` at their byte range
    @testset "returns nothing for non-call surfaces" begin
        let code = "let x = 42; x; end"
            _, ctx = type_annotate(code)
            @test get_matches_for_range(ctx, range_of(code, "x = 42")) === nothing
        end
    end
end

end # module test_type_annotation
