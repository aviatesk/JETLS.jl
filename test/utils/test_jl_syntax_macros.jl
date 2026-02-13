module test_jl_syntax_macros

using Test
using JETLS: JETLS, JL, JS

include(normpath(pkgdir(JETLS), "test", "jsjl-utils.jl"))

global lowering_module::Module = Module()

function kwdef_expand(code::AbstractString)
    st0 = jlparse(code; rule=:statement)
    world = Base.get_world_counter()
    _, st1 = JL.expand_forms_1(lowering_module, st0, true, world)
    return st1
end

children_kinds(st::JS.SyntaxTree) = JS.Kind[JS.kind(c) for c in JS.children(st)]

@testset "@kwdef" begin
    @testset "macro expansion" begin
        # parametric with defaults
        let st1 = kwdef_expand("""
                @kwdef struct A{T <: Real}
                    a::T = 1.0
                    b::Int
                end
                """)
            @test JS.kind(st1) === JS.K"block"
            ks = children_kinds(st1)
            @test count(==(JS.K"struct"), ks) == 1
            # parametric: 2 constructors (S(...) and S{T}(...) where {T})
            @test count(==(JS.K"function"), ks) == 2

            # struct fields should have defaults stripped
            st_struct = st1[findfirst(==(JS.K"struct"), ks)]
            body = st_struct[2]
            for field in JS.children(body)
                @test JS.kind(field) !== JS.K"="
            end
        end

        # non-parametric with defaults
        let st1 = kwdef_expand("""
                @kwdef struct A
                    a::Float64 = 1.0
                end
                """)
            @test JS.kind(st1) === JS.K"block"
            ks = children_kinds(st1)
            @test count(==(JS.K"struct"), ks) == 1
            # non-parametric: only 1 constructor
            @test count(==(JS.K"function"), ks) == 1
        end

        # no defaults: keyword constructor is still generated
        let st1 = kwdef_expand("""
                @kwdef struct A
                    a::Int
                end
                """)
            @test JS.kind(st1) === JS.K"block"
            ks = children_kinds(st1)
            @test count(==(JS.K"struct"), ks) == 1
            @test count(==(JS.K"function"), ks) == 1
        end

        # mutable struct with const field default
        let st1 = kwdef_expand("""
                @kwdef mutable struct A{T <: Real}
                    const a::T = 1.0
                    b::Int
                end
                """)
            @test JS.kind(st1) === JS.K"block"
            ks = children_kinds(st1)
            @test count(==(JS.K"struct"), ks) == 1
            @test count(==(JS.K"function"), ks) == 2

            st_struct = st1[findfirst(==(JS.K"struct"), ks)]
            body = st_struct[2]
            # `const a::T` should remain, but no `=`
            has_const = false
            for field in JS.children(body)
                @test JS.kind(field) !== JS.K"="
                if JS.kind(field) === JS.K"const"
                    has_const = true
                end
            end
            @test has_const
        end
    end

    @testset "full lowering succeeds" begin
        for code in [
            "@kwdef struct A{T <: Real}\n    a::T = 1.0\nend\n",
            "@kwdef struct A\n    a::Float64 = 1.0\nend\n",
            "@kwdef mutable struct A{T}\n    const a::T = 1.0\n    b::Int\nend\n",
            "@kwdef struct A\n    a::Int\nend\n",
        ]
            st0 = jlparse(code)
            world = Base.get_world_counter()
            result = JETLS.jl_lower_for_scope_resolution(
                lowering_module, st0, world)
            @test result isa NamedTuple
        end
    end

    @testset "binding resolution" begin
        for code in [
            "@kwdef struct MyStruct{T <: Real}\n    a::T = 1.0\nend\n",
            "@kwdef struct MyStruct\n    a::Float64 = 1.0\nend\n",
            "@kwdef mutable struct MyStruct{T}\n    const a::T = 1.0\n    b::Int\nend\n",
            "@kwdef struct MyStruct\n    a::Int\nend\n",
        ]
            st0 = jlparse(code)
            offset = findfirst("MyStruct", code).start
            result = JETLS._select_target_binding(
                st0, offset, lowering_module)
            @test result !== nothing
            binfo = JL.get_binding(result.ctx3, result.binding)
            @test binfo.name == "MyStruct"
            @test binfo.kind === :global
        end
    end
end

end # module test_jl_syntax_macros
