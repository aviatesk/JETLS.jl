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

@testset "basic inference" begin
    let (; st0, tree) = infer_statement("sin(1.0)")
        @test tree !== nothing
        typ = JETLS.get_type_for_range(tree, JS.byte_range(st0))
        @test typ === Core.Const(0.8414709848078965)
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
        typ = query_source_type(st0, tree, "value = sin(config.scale) + config.offset")
        @test typ !== nothing
        @test CC.widenconst(typ) === Float64
    end

    let (; st0, tree) = infer_statement("Ref((; scale = 2.0))[].scale")
        @test tree !== nothing
        typ = JETLS.get_type_for_range(tree, JS.byte_range(st0))
        @test typ !== nothing
        @test CC.widenconst(typ) === Float64
    end

    let (; st0, tree) = infer_statement("(Ref(Some(42))[]).value")
        @test tree !== nothing
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

@testset "incomplete syntax boundaries" begin
    let (; st0, tree) = infer_statement("sin(")
        @test tree !== nothing
        @test query_child_type(st0, tree, 1) === Core.Const(sin)
        @test query_child_type(st0, tree, 2) === nothing
    end

    let st0 = jlparse("x."; rule=:statement)
        @test JS.kind(st0) === JS.K"."
        @test JS.numchildren(st0) ≥ 2
        @test JS.kind(st0[1]) === JS.K"Identifier"
        @test JS.kind(st0[2]) === JS.K"inert"
    end
    @test_throws JL.LoweringError lower_statement("x.")
    @test_throws JL.LoweringError lower_statement("Base.")
    @test_throws JL.LoweringError lower_statement("foo(; a=")
end

end # module test_ASTTypeAnnotator
