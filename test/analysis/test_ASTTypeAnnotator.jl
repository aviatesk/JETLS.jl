module test_ASTTypeAnnotator

using Test
using JETLS
using JETLS: JS, JL, CC

include(normpath(pkgdir(JETLS), "test", "jsjl-utils.jl"))

module inference_module end

function lower_statement(code::AbstractString, mod::Module=inference_module)
    st0 = jlparse(code; rule=:statement)
    st0_clean = JETLS.without_kinds(st0, (JS.K"error",))
    ctx1, st1 = JL.expand_forms_1(mod, st0_clean, true, Base.get_world_counter())
    ctx2, st2 = JL.expand_forms_2(ctx1, st1)
    ctx3, st3 = JL.resolve_scopes(ctx2, st2)
    return (; st0, ctx3, st3)
end

function infer_statement(code::AbstractString, mod::Module=inference_module)
    (; st0, ctx3, st3) = lower_statement(code, mod)
    tree = JETLS.infer_toplevel_tree(ctx3, st3, mod)
    return (; st0, tree)
end

function query_child_type(st0::JS.SyntaxTree, tree::JS.SyntaxTree, idx::Int)
    child = st0[idx]
    return JETLS.get_type_for_range(tree, JS.byte_range(child))
end

function only_node_with_text(st0::JS.SyntaxTree, text::AbstractString)
    matches = JS.SyntaxTree[]
    JETLS.traverse(st0) do node::JS.SyntaxTree
        JS.sourcetext(node) == text && push!(matches, node)
    end
    return only(matches)
end

function query_source_type(st0::JS.SyntaxTree, tree::JS.SyntaxTree, text::AbstractString)
    node = only_node_with_text(st0, text)
    return JETLS.get_type_for_range(tree, JS.byte_range(node))
end

function query_source_types(st0::JS.SyntaxTree, tree::JS.SyntaxTree, text::AbstractString)
    types = Any[]
    JETLS.traverse(st0) do node::JS.SyntaxTree
        if JS.sourcetext(node) == text
            push!(types, JETLS.get_type_for_range(tree, JS.byte_range(node)))
        end
    end
    return types
end

@testset "basic inference" begin
    let (; st0, tree) = infer_statement("sin(1.0)")
        @test tree !== nothing
        typ = JETLS.get_type_for_range(tree, JS.byte_range(st0))
        @test typ === Core.Const(sin(1.0))
        @test JETLS.get_type_for_range(tree, 9999:10000) === nothing
    end

    let (; st0, tree) = infer_statement("Base.sin(1.0)")
        @test tree !== nothing
        typ = JETLS.get_type_for_range(tree, JS.byte_range(st0))
        @test typ !== nothing
        @test CC.widenconst(typ) === Float64
    end
end

@testset "real-world expressions" begin
    let (; st0, tree) = infer_statement("""
        let
            config = (; scale = 2.0, offset = 1)
            value = sin(config.scale) + config.offset
            value
        end""")
        @test tree !== nothing
        config_types = query_source_types(st0, tree, "config")
        @test length(config_types) == 3
        @test all(==(Core.Const((; scale = 2.0, offset = 1))), config_types)

        @test query_source_type(st0, tree, "config.scale") === Core.Const(2.0)
        @test query_source_type(st0, tree, "config.offset") === Core.Const(1)
        @test query_source_type(st0, tree, "sin(config.scale)") === Core.Const(sin(2.0))

        typ = query_source_type(st0, tree, "value = sin(config.scale) + config.offset")
        @test typ !== nothing
        @test CC.widenconst(typ) === Float64

        value_types = query_source_types(st0, tree, "value")
        @test length(value_types) == 2
        @test all(==(Core.Const(sin(2.0) + 1)), value_types)
    end

    let (; st0, tree) = infer_statement("Ref((; scale = 2.0))[].scale")
        @test tree !== nothing
        typ = query_source_type(st0, tree, "Ref((; scale = 2.0))[]")
        @test typ !== nothing
        @test CC.widenconst(typ) === NamedTuple{(:scale,), Tuple{Float64}}

        typ = JETLS.get_type_for_range(tree, JS.byte_range(st0))
        @test typ !== nothing
        @test CC.widenconst(typ) === Float64
    end

    let (; st0, tree) = infer_statement("(Ref(Some(42))[]).value")
        @test tree !== nothing
        typ = query_source_type(st0, tree, "Ref(Some(42))[]")
        @test typ !== nothing
        @test CC.widenconst(typ) === Some{Int64}

        typ = JETLS.get_type_for_range(tree, JS.byte_range(st0))
        @test typ !== nothing
        @test CC.widenconst(typ) === Int64
    end
end

@testset "Core top-level declaration handling" begin
    let (; st0, tree) = infer_statement("x = sin(1.0)")
        @test tree !== nothing
        rhs_typ = query_child_type(st0, tree, 2)
        @test rhs_typ !== nothing
        @test rhs_typ !== Union{}
        @test CC.widenconst(rhs_typ) === Float64
    end

    let (; st0, tree) = infer_statement("const answer = sin(1.0)")
        @test tree !== nothing
        decl_typ = query_child_type(st0, tree, 1)
        @test decl_typ === Nothing
    end
end

@testset "function definitions" begin
    let (; st0, tree) = infer_statement("""
        function f(xs::Vector{Float64})
            cfg = (scale = 2.0, offset = 1)

            if length(xs) > 0
                a, b = sincos(xs[1])
            else
                a, b = (0.0, 1.0)
            end

            z = let
                raw = abs(sin(cos(cfg.scale)))
                raw * cfg.offset
            end

            result = a + b + z
            result
        end""")
        @test tree !== nothing

        typ = query_source_type(st0, tree, "xs[1]")
        @test typ !== nothing
        @test CC.widenconst(typ) === Float64

        typ = query_source_type(st0, tree, "cfg.scale")
        @test typ !== nothing
        @test CC.widenconst(typ) === Float64

        typ = query_source_type(st0, tree, "cfg.offset")
        @test typ !== nothing
        @test CC.widenconst(typ) === Int64

        cfg_types = query_source_types(st0, tree, "cfg")
        @test length(cfg_types) == 3
        @test all(
            t -> CC.widenconst(t) === NamedTuple{(:scale, :offset), Tuple{Float64, Int64}},
            cfg_types
        )

        a_types = query_source_types(st0, tree, "a")
        @test !isempty(a_types)
        @test all(t -> CC.widenconst(t) === Float64, a_types)

        typ = query_source_type(st0, tree, "abs(sin(cos(cfg.scale)))")
        @test typ !== nothing
        @test CC.widenconst(typ) === Float64

        typ = query_source_type(st0, tree, "raw * cfg.offset")
        @test typ !== nothing
        @test CC.widenconst(typ) === Float64

        raw_types = query_source_types(st0, tree, "raw")
        @test length(raw_types) == 2
        @test all(t -> CC.widenconst(t) === Float64, raw_types)

        z_types = query_source_types(st0, tree, "z")
        @test length(z_types) == 2
        @test all(t -> CC.widenconst(t) === Float64, z_types)

        result_types = query_source_types(st0, tree, "result")
        @test length(result_types) == 2
        @test all(t -> CC.widenconst(t) === Float64, result_types)

        typ = query_source_type(st0, tree, "a + b + z")
        @test typ !== nothing
        @test CC.widenconst(typ) === Float64
    end
end

@testset "recoverable incomplete syntax" begin
    let (; st0, tree) = infer_statement("sin(")
        @test tree !== nothing
        @test query_child_type(st0, tree, 1) === Core.Const(sin)
        @test query_child_type(st0, tree, 2) === nothing
    end
end

end # module test_ASTTypeAnnotator
