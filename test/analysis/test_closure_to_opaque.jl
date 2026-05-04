module test_closure_to_opaque

using Test
using JETLS
using JETLS: JL, JS, rewrite_local_closures_to_opaque

# Run the rewrite + the rest of JL lowering, then `Core.eval` the resulting
# `:thunk` so tests can assert against the runtime value the rewritten IR
# produces. Returns `(value, st3_oc)` — `st3_oc` is the post-rewrite tree so
# tests can assert structural facts (e.g. an OC was actually emitted).
function rewrite_lower_eval(code::AbstractString)
    mod = Module()
    fi = JETLS.FileInfo(1, code, @__FILE__)
    st0_top = JETLS.build_syntax_tree(fi)
    last_value = Ref{Any}(nothing)
    last_st3_oc = Ref{Union{JETLS.SyntaxTreeC,Nothing}}(nothing)
    JETLS.iterate_toplevel_tree(st0_top) do st0::JS.SyntaxTree
        result = JETLS.TypeAnnotation.get_inferrable_tree(st0, mod)
        result === nothing && error("get_inferrable_tree failed for: $code")
        (; ctx3, st3) = result
        st3_oc = rewrite_local_closures_to_opaque(ctx3, st3)
        ctx4, st4 = JL.convert_closures(ctx3, st3_oc)
        _, st5 = JL.linearize_ir(ctx4, st4)
        lwr = JL.to_lowered_expr(st5)
        last_value[] = Core.eval(mod, lwr)
        last_st3_oc[] = st3_oc
        return nothing
    end
    return (last_value[], last_st3_oc[])
end

# Variant that stops before `Core.eval`, for cases where the lowered code goes
# through paths whose runtime requirements aren't met on the current Julia
# (e.g. synthetic-struct closures' `declare_const` is v1.14-only). Returns the
# post-rewrite tree only — sufficient for structural assertions like "the
# rewrite did NOT fire for this shape".
function rewrite_only(code::AbstractString)
    mod = Module()
    fi = JETLS.FileInfo(1, code, @__FILE__)
    st0_top = JETLS.build_syntax_tree(fi)
    last_st3_oc = Ref{Union{JETLS.SyntaxTreeC,Nothing}}(nothing)
    JETLS.iterate_toplevel_tree(st0_top) do st0::JS.SyntaxTree
        result = JETLS.TypeAnnotation.get_inferrable_tree(st0, mod)
        result === nothing && error("get_inferrable_tree failed for: $code")
        (; ctx3, st3) = result
        last_st3_oc[] = rewrite_local_closures_to_opaque(ctx3, st3)
        return nothing
    end
    return last_st3_oc[]
end

# Count `K"_opaque_closure"` nodes in `tree`. Used to verify the rewrite emits
# exactly one OC per source-level closure (no synthetic duplication).
function count_opaque_closures(tree::JETLS.SyntaxTreeC)
    n = JS.kind(tree) === JS.K"_opaque_closure" ? 1 : 0
    if !JS.is_leaf(tree)
        for c in JS.children(tree)
            n += count_opaque_closures(c)
        end
    end
    return n
end

@testset "single-method closure → OC" begin
    let (val, tree) = rewrite_lower_eval("""
            let f = x -> 2x
                f(21)
            end
            """)
        @test val == 42
        @test count_opaque_closures(tree) == 1
    end

    let (val, tree) = rewrite_lower_eval("""
            let f = (x::Int) -> x + 1
                f(41)
            end
            """)
        @test val == 42
        @test count_opaque_closures(tree) == 1
    end

    let (val, tree) = rewrite_lower_eval("""
            let
                function inner(x)
                    x * 3
                end
                inner(14)
            end
            """)
        @test val == 42
        @test count_opaque_closures(tree) == 1
    end
end

@testset "captured variables" begin
    let (val, tree) = rewrite_lower_eval("""
            let y = 10
                f = x -> x + y
                f(32)
            end
            """)
        @test val == 42
        @test count_opaque_closures(tree) == 1
    end

    let (val, tree) = rewrite_lower_eval("""
            let a = 2,
                b = 20
                f = x -> a*x + b
                f(11)
            end
            """)
        @test val == 42
        @test count_opaque_closures(tree) == 1
    end
end

@testset "return type annotation" begin
    # Literal `::RT` on the closure: native `f(y)::T = body` lowers to
    # `convert(T, body)::T`, and the rewrite preserves that by passing the
    # whole `lambda` subtree into `K"_opaque_closure"` — we don't use OC's
    # own `rt_lb`/`rt_ub` slots (which would assert without converting).
    let (val, tree) = rewrite_lower_eval("""
            let f(y)::Float64 = 2.0 + y
                f(3.0)
            end
            """)
        @test val === 5.0
        @test count_opaque_closures(tree) == 1
    end
    # Convert-not-just-assert check: with native `convert + typeassert`
    # semantics, `2.0 + 3.0 == 5.0` becomes `convert(Int, 5.0) === 5`.
    # If someone later replaced this with OC's `_->Int` slot, the same
    # body would `TypeError: expected Int, got Float64`.
    let (val, tree) = rewrite_lower_eval("""
            let f(y)::Int = 2.0 + y
                f(3.0)
            end
            """)
        @test val === 5
        @test count_opaque_closures(tree) == 1
    end

    # Computed `::typeof(x)` referring to a captured variable.
    let (val, tree) = rewrite_lower_eval("""
            let x = 1.5
                f(y)::typeof(x) = x + y
                f(2.5)
            end
            """)
        @test val === 4.0
        @test count_opaque_closures(tree) == 1
    end
end

@testset "vararg closure" begin
    let (val, tree) = rewrite_lower_eval("""
            let f = (xs...,) -> sum(xs)
                f(1, 2, 3, 4, 5)
            end
            """)
        @test val == 15
        @test count_opaque_closures(tree) == 1
    end
end

@testset "sibling closures (different names)" begin
    # Two single-method closures in the same scope — each is independently
    # eligible, so the rewrite fires for both and the resulting OCs don't
    # interfere (each gets its own LHS binding).
    let (val, tree) = rewrite_lower_eval("""
            let
                f = x -> 2x
                g = x -> x + 10
                (f(21), g(32))
            end
            """)
        @test val == (42, 42)
        @test count_opaque_closures(tree) == 2
    end

    let (val, tree) = rewrite_lower_eval("""
            let
                function inc(x)
                    x + 1
                end
                function dbl(x)
                    x * 2
                end
                (inc(41), dbl(21))
            end
            """)
        @test val == (42, 42)
        @test count_opaque_closures(tree) == 2
    end
end

@testset "nested closures" begin
    let (val, tree) = rewrite_lower_eval("""
            let outer = x -> begin
                    inner = y -> x + y
                    inner(10)
                end
                outer(32)
            end
            """)
        @test val == 42
        @test count_opaque_closures(tree) == 2
    end
end

@testset "do-block as map argument" begin
    let (val, tree) = rewrite_lower_eval("""
            let xs = [1, 2, 3]
                map(xs) do x
                    2x
                end
            end
            """)
        @test val == [2, 4, 6]
        @test count_opaque_closures(tree) == 1
    end
end

# Multi-method local closures aren't representable as a single OC, so the rewrite
# must skip them and let `JL.convert_closures` produce a synthetic struct. JL wraps
# each method definition in its own inner block, so a sibling-only count would see
# only one `K"method_defs"` per block. The pre-pass in
# `_collect_multi_method_bindings` walks the whole tree to count `K"method_defs"`
# per `var_id`, which is what lets the rewrite skip both methods here.
@testset "multi-method local closure should fall through" begin
    let tree = rewrite_only("""
            let
                f(x::Int) = x + 1
                f(x::String) = string(x, "!")
                (f(41), f("hi"))
            end
            """)
        @test count_opaque_closures(tree) == 0
    end
end

end # module test_closure_to_opaque
