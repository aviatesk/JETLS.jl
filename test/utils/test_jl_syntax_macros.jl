module test_jl_syntax_macros

using Test
using JETLS: JETLS, JL, JS

include(normpath(pkgdir(JETLS), "test", "jsjl-utils.jl"))

module lowering_module end

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
            body = st_struct[3]
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

        # non-parametric with subtype declaration
        let st1 = kwdef_expand("""
                @kwdef mutable struct A <: Base.AbstractLock
                    a::Int = 10
                end
                """)
            @test JS.kind(st1) === JS.K"block"
            ks = children_kinds(st1)
            @test count(==(JS.K"struct"), ks) == 1
            @test count(==(JS.K"function"), ks) == 1
        end

        # parametric with subtype declaration
        let st1 = kwdef_expand("""
                @kwdef struct A{T <: Real} <: Number
                    a::T = 1.0
                end
                """)
            @test JS.kind(st1) === JS.K"block"
            ks = children_kinds(st1)
            @test count(==(JS.K"struct"), ks) == 1
            @test count(==(JS.K"function"), ks) == 2
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
            body = st_struct[3]
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
            "@kwdef mutable struct A <: Base.AbstractLock\n    a::Int = 10\nend\n",
            "@kwdef struct A{T <: Real} <: Number\n    a::T = 1.0\nend\n",
        ]
            st0 = jlparse(code)
            world = Base.get_world_counter()
            result = JETLS.jl_lower_for_scope_resolution(lowering_module, st0, world)
            @test result isa NamedTuple
        end
    end

    @testset "binding resolution" begin
        for code in [
            "@kwdef struct MyStruct{T <: Real}\n    a::T = 1.0\nend\n",
            "@kwdef struct MyStruct\n    a::Float64 = 1.0\nend\n",
            "@kwdef mutable struct MyStruct{T}\n    const a::T = 1.0\n    b::Int\nend\n",
            "@kwdef struct MyStruct\n    a::Int\nend\n",
            "@kwdef mutable struct MyStruct <: Base.AbstractLock\n    a::Int = 10\nend\n",
            "@kwdef struct MyStruct{T <: Real} <: Number\n    a::T = 1.0\nend\n",
        ]
            st0 = jlparse(code)
            offset = findfirst("MyStruct", code).start
            result = JETLS.select_target_binding(st0, offset, lowering_module)
            @test result !== nothing
            binfo = JL.get_binding(result.ctx3, result.binding)
            @test binfo.name == "MyStruct"
            @test binfo.kind === :global
        end
    end
end

function spawn_expand(code::AbstractString)
    st0 = jlparse(code; rule=:statement)
    world = Base.get_world_counter()
    _, st1 = JL.expand_forms_1(lowering_module, st0, true, world)
    return st1
end

@testset "Threads.@spawn" begin
    @testset "macro expansion" begin
        # Single-argument form: returns the body unchanged.
        let st1 = spawn_expand("Threads.@spawn sin(xxx)")
            @test JS.kind(st1) === JS.K"call"
            @test JS.sourcetext(st1[1]) == "sin"
            @test JS.sourcetext(st1[2]) == "xxx"
        end

        # Two-argument form: emits `block(threadpool, body)`.
        let st1 = spawn_expand("Threads.@spawn :default sin(xxx)")
            @test JS.kind(st1) === JS.K"block"
            @test JS.numchildren(st1) == 2
            @test JS.kind(st1[1]) === JS.K"inert"
            @test JS.kind(st1[2]) === JS.K"call"
        end

        # `$x` in the body must be unwrapped: a surviving `K"$"` outside of a
        # quote context would fail later lowering passes.
        let st1 = spawn_expand("Threads.@spawn sin(\$xxx)")
            @test JS.kind(st1) === JS.K"call"
            @test all(c -> JS.kind(c) !== JS.K"$", JS.children(st1))
            @test JS.sourcetext(st1[2]) == "xxx"
        end

        # All allowed threadpool literals are accepted.
        for tp in (":interactive", ":default", ":samepool")
            @test spawn_expand("Threads.@spawn $tp 1+1") isa JS.SyntaxTree
        end

        # A bare identifier is accepted (e.g. `def = :default; @spawn def body`).
        @test spawn_expand("Threads.@spawn pool 1+1") isa JS.SyntaxTree
    end

    @testset "error cases" begin
        # Unsupported literal threadpool is rejected at expansion time, with the
        # same message as the runtime `Base.Threads.@spawn` check.
        let err = try
                spawn_expand("Threads.@spawn :foo 1+1")
                nothing
            catch err
                err
            end
            @test err isa JL.MacroExpansionError
            @test occursin("unsupported threadpool in @spawn: foo", err.msg)
        end

        # Zero arguments and 3+ arguments both fall through to the variadic fallback method.
        for code in ("Threads.@spawn", "Threads.@spawn :default :foo 1+1")
            let err = try
                    spawn_expand(code)
                    nothing
                catch err
                    err
                end
                @test err isa JL.MacroExpansionError
                @test occursin("wrong number of arguments in @spawn", err.msg)
            end
        end

        # Anything other than `:default`/`:interactive`/`:samepool` literals or
        # a bare identifier is rejected. The original macro defers most of
        # these to a runtime `_spawn_set_thrpool(::Symbol)` MethodError; we
        # catch them at expansion time so the user gets immediate feedback.
        for code in (
                "Threads.@spawn 42 body",          # numeric literal
                "Threads.@spawn 1.0 body",         # float literal
                "Threads.@spawn \"default\" body", # string literal
                "Threads.@spawn true body",        # bool literal
                "Threads.@spawn 'a' body",         # char literal
                "Threads.@spawn f() body",         # call expression
                "Threads.@spawn M.pool body",      # qualified access
                "Threads.@spawn :(foo()) body",    # quoted non-symbol expression
            )
            let err = try
                    spawn_expand(code)
                    nothing
                catch err
                    err
                end
                @test err isa JL.MacroExpansionError
                @test occursin("threadpool argument in @spawn must be", err.msg)
            end
        end
    end

    @testset "binding resolution preserves provenance" begin
        # The whole point of the new-style stub: identifiers inside the
        # expansion must keep accurate byte ranges so that downstream LSP
        # analyses (notably `lowering/undef-global-var`) can accept them via
        # `is_from_user_ast`. With the old-style macro the inner `xxx` ends up
        # with a `0:0` byte range and gets filtered out.
        let code = "spawnfunc() = Threads.@spawn :default sin(xxx)"
            st0 = jlparse(code; rule=:statement)
            world = Base.get_world_counter()
            res = JETLS.jl_lower_for_scope_resolution(lowering_module, st0, world;
                recover_from_macro_errors=false, convert_closures=true)
            binding_occurrences = JETLS.compute_binding_occurrences(
                res.ctx3, res.st3, false; include_global_bindings=true)

            xxx_binfo = nothing
            for (binfo, _) in binding_occurrences
                if binfo.kind === :global && binfo.name == "xxx"
                    xxx_binfo = binfo
                    break
                end
            end
            @test xxx_binfo !== nothing
            provs = JS.flattened_provenance(JL.binding_ex(res.ctx3, xxx_binfo.id))
            @test JETLS.is_from_user_ast(provs)
            # Innermost provenance points at the user-written `xxx`, not the
            # macrocall as a whole.
            @test JS.sourcetext(last(provs)) == "xxx"
        end
    end
end

function label_expand(code::AbstractString)
    st0 = jlparse(code; rule=:statement)
    world = Base.get_world_counter()
    _, st1 = JL.expand_forms_1(lowering_module, st0, true, world)
    return st1
end

@testset "@label" begin
    # Full lowering succeeds when paired with `@goto`.
    let code = """
            function f()
                @goto start
                @label start
            end
            """
        st0 = jlparse(code; rule=:statement)
        world = Base.get_world_counter()
        @test JETLS.jl_lower_for_scope_resolution(lowering_module, st0, world;
            recover_from_macro_errors=false) isa NamedTuple
    end

    # Non-identifier argument is rejected.
    let err = try
            label_expand("@label 42")
            nothing
        catch err
            err
        end
        @test err isa JL.MacroExpansionError
        @test occursin("requires an identifier", err.msg)
    end

    # The block forms (`@label expr`, `@label name expr`) are intentionally not
    # supported; the variadic fallback gives a clear message instead of a
    # `MethodError`.
    let err = try
            label_expand("@label foo body")
            nothing
        catch err
            err
        end
        @test err isa JL.MacroExpansionError
        @test occursin("only supports the `@label name` form", err.msg)
    end
end

end # module test_jl_syntax_macros
