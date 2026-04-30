module test_jl_syntax_macros

using Test
using JETLS: JETLS, JL, JS

include(normpath(pkgdir(JETLS), "test", "jsjl-utils.jl"))

module lowering_module end

function jlexpand(mod::Module, code::AbstractString)
    st0 = jlparse(code; rule=:statement)
    world = Base.get_world_counter()
    _, st1 = JL.expand_forms_1(mod, st0, true, world)
    return st1
end
jlexpand(code::AbstractString) = jlexpand(lowering_module, code)

function jlresolve(mod::Module, code::AbstractString)
    st0 = jlparse(code; rule=:statement)
    world = Base.get_world_counter()
    return JETLS.jl_lower_for_scope_resolution(mod, st0, world;
        recover_from_macro_errors=false, convert_closures=true)
end
jlresolve(code::AbstractString) = jlresolve(lowering_module, code)

children_kinds(st::JS.SyntaxTree) = JS.Kind[JS.kind(c) for c in JS.children(st)]

@testset "@kwdef" begin
    @testset "macro expansion" begin
        # parametric with defaults
        let st1 = jlexpand("""
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
        let st1 = jlexpand("""
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
        let st1 = jlexpand("""
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
        let st1 = jlexpand("""
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
        let st1 = jlexpand("""
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
        let st1 = jlexpand("""
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
            @test jlresolve(code) isa NamedTuple
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

@testset "Threads.@spawn" begin
    @testset "macro expansion" begin
        # Single-argument form: returns the body unchanged.
        let st1 = jlexpand("Threads.@spawn sin(xxx)")
            @test JS.kind(st1) === JS.K"call"
            @test JS.sourcetext(st1[1]) == "sin"
            @test JS.sourcetext(st1[2]) == "xxx"
        end

        # Two-argument form: emits `block(threadpool, body)`.
        let st1 = jlexpand("Threads.@spawn :default sin(xxx)")
            @test JS.kind(st1) === JS.K"block"
            @test JS.numchildren(st1) == 2
            @test JS.kind(st1[1]) === JS.K"inert"
            @test JS.kind(st1[2]) === JS.K"call"
        end

        # `$x` in the body must be unwrapped: a surviving `K"$"` outside of a
        # quote context would fail later lowering passes.
        let st1 = jlexpand("Threads.@spawn sin(\$xxx)")
            @test JS.kind(st1) === JS.K"call"
            @test all(c -> JS.kind(c) !== JS.K"$", JS.children(st1))
            @test JS.sourcetext(st1[2]) == "xxx"
        end

        # All allowed threadpool literals are accepted.
        for tp in (":interactive", ":default", ":samepool")
            @test jlexpand("Threads.@spawn $tp 1+1") isa JS.SyntaxTree
        end

        # A bare identifier is accepted (e.g. `def = :default; @spawn def body`).
        @test jlexpand("Threads.@spawn pool 1+1") isa JS.SyntaxTree
    end

    @testset "error cases" begin
        # Unsupported literal threadpool is rejected at expansion time, with the
        # same message as the runtime `Base.Threads.@spawn` check.
        let err = try
                jlexpand("Threads.@spawn :foo 1+1")
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
                    jlexpand(code)
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
                    jlexpand(code)
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
        let res = jlresolve("spawnfunc() = Threads.@spawn :default sin(xxx)")
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
            @test JS.sourcetext(last(provs)) == "xxx"
        end
    end
end

@testset "@label" begin
    # Non-identifier argument is rejected.
    let err = try
            jlexpand("@label 42")
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
            jlexpand("@label foo body")
            nothing
        catch err
            err
        end
        @test err isa JL.MacroExpansionError
        @test occursin("only supports the `@label name` form", err.msg)
    end

    # Full lowering succeeds when paired with `@goto`.
    @test jlresolve("""
        function f()
            @goto start
            @label start
        end
        """) isa NamedTuple
end

module test_lowering_module; using Test; end
test_macro_expand(code::AbstractString) = jlexpand(test_lowering_module, code)
test_macro_lower(code::AbstractString) = jlresolve(test_lowering_module, code)

@testset "Test.@test" begin
    @testset "macro expansion" begin
        # Bare expression: returned unchanged.
        let st1 = test_macro_expand("@test x == 1")
            @test JS.kind(st1) === JS.K"call"
            @test strip(JS.sourcetext(st1)) == "x == 1"
        end

        # Special keyword arguments are accepted but discarded.
        for kw in ("broken=true", "skip=cond", "context=ctx")
            let st1 = test_macro_expand("@test x $kw")
                @test JS.kind(st1) === JS.K"Identifier"
                @test strip(JS.sourcetext(st1)) == "x"
            end
        end

        # Other keyword arguments (e.g. `atol`) are forwarded by the real
        # macro to the test expression; the new-style stub accepts them
        # silently.
        let st1 = test_macro_expand("@test foo(x) atol=0.1")
            @test JS.kind(st1) === JS.K"call"
        end
    end

    @testset "validation" begin
        # `broken`/`skip`/`context` may each appear at most once.
        for kw in ("broken", "skip", "context")
            let err = try
                    test_macro_expand("@test x $(kw)=true $(kw)=false")
                    nothing
                catch err
                    err
                end
                @test err isa JL.MacroExpansionError
                @test occursin("cannot set `$kw` keyword multiple times", err.msg)
            end
        end

        # `skip` and `broken` are mutually exclusive.
        let err = try
                test_macro_expand("@test x skip=true broken=true")
                nothing
            catch err
                err
            end
            @test err isa JL.MacroExpansionError
            @test occursin("cannot set both `skip` and `broken`", err.msg)
        end

        # Non-`key=value` positional arguments are rejected.
        let err = try
                test_macro_expand("@test x foo")
                nothing
            catch err
                err
            end
            @test err isa JL.MacroExpansionError
            @test occursin("expected `keyword=value`", err.msg)
        end
    end

    @testset "binding resolution preserves provenance" begin
        # Identifiers inside `@test` keep accurate byte ranges so downstream
        # LSP analyses can recognize them as user-written via `is_from_user_ast`.
        let res = test_macro_lower("testfunc() = @test sin(xxx) == 1.0")
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
            @test JS.sourcetext(last(provs)) == "xxx"
        end
    end
end

@testset "Test.@testset" begin
    @testset "macro expansion" begin
        # Body is wrapped in a `let` block so that bindings introduced inside
        # the testset don't leak into the enclosing scope.
        let st1 = test_macro_expand("""
                @testset "x" begin
                    a = 1
                    @test a == 1
                end
                """)
            @test JS.kind(st1) === JS.K"let"
            @test JS.numchildren(st1) == 2
            @test JS.kind(st1[1]) === JS.K"block" # bindings (empty)
            @test JS.kind(st1[2]) === JS.K"block" # body
        end

        # No description form.
        let st1 = test_macro_expand("@testset begin a = 1 end")
            @test JS.kind(st1) === JS.K"let"
        end

        # Description and options are dropped, only the trailing body matters.
        let st1 = test_macro_expand("""
                @testset MyType "x" verbose=true begin
                    @test true
                end
                """)
            @test JS.kind(st1) === JS.K"let"
        end

        # `for` loop form: the for sits inside the let body block.
        let st1 = test_macro_expand("""
                @testset "x" for i = 1:10
                    @test i > 0
                end
                """)
            @test JS.kind(st1) === JS.K"let"
        end
    end

    @testset "validation" begin
        # No-argument form rejected.
        let err = try
                test_macro_expand("@testset")
                nothing
            catch err
                err
            end
            @test err isa JL.MacroExpansionError
            @test occursin("No arguments to @testset", err.msg)
        end

        # Body argument must be a `for`/`begin`/`call`/`let`.
        for body in ("42", "\"x\"", "x = 1")
            let err = try
                    test_macro_expand("@testset \"name\" $body")
                    nothing
                catch err
                    err
                end
                @test err isa JL.MacroExpansionError
                @test occursin("body argument must be", err.msg)
            end
        end

        # Multiple descriptions / testset types are rejected.
        let err = try
                test_macro_expand("@testset \"a\" \"b\" begin end")
                nothing
            catch err
                err
            end
            @test err isa JL.MacroExpansionError
            @test occursin("multiple descriptions", err.msg)
        end
        let err = try
                test_macro_expand("@testset Foo Bar begin end")
                nothing
            catch err
                err
            end
            @test err isa JL.MacroExpansionError
            @test occursin("multiple testset types", err.msg)
        end

        # Duplicate options are rejected.
        let err = try
                test_macro_expand("@testset verbose=true verbose=false begin end")
                nothing
            catch err
                err
            end
            @test err isa JL.MacroExpansionError
            @test occursin("option `verbose` already provided", err.msg)
        end

        # Unexpected leading arguments (e.g. integer literals) are rejected.
        let err = try
                test_macro_expand("@testset 42 begin end")
                nothing
            catch err
                err
            end
            @test err isa JL.MacroExpansionError
            @test occursin("unexpected argument", err.msg)
        end

        # Qualified testset types (e.g. `Test.DefaultTestSet`) are accepted.
        @test test_macro_expand("@testset Test.DefaultTestSet \"x\" begin end") isa JS.SyntaxTree

        # Interpolated descriptions are accepted.
        @test test_macro_expand("@testset \"name-\$i\" begin end") isa JS.SyntaxTree
    end

    @testset "scope isolation + provenance" begin
        # A binding introduced in one `@testset` body must not be visible from
        # a sibling `@testset`, mirroring the `try`/`catch` scope of the real
        # macro. User-written identifiers must also keep accurate byte ranges
        # so that downstream LSP analyses accept them as user-written via
        # `is_from_user_ast`.
        let res = test_macro_lower("""
                function f()
                    # A local `leaked` exists for the first testset, and the second
                    # testset's reference resolves to a separate global binding.
                    @testset "a" begin
                        leaked = 1
                        @test leaked == 1
                    end
                    @testset "b" begin
                        @test leaked == 1
                    end
                end
                """)
            binding_occurrences = JETLS.compute_binding_occurrences(
                res.ctx3, res.st3, false; include_global_bindings=true)

            local_leaked = filter(collect(binding_occurrences)) do (binfo, _)
                binfo.kind === :local && binfo.name == "leaked"
            end
            global_leaked = filter(collect(binding_occurrences)) do (binfo, _)
                binfo.kind === :global && binfo.name == "leaked"
            end

            @test !isempty(local_leaked)
            @test !isempty(global_leaked)

            (local_binfo, _) = first(local_leaked)
            local_provs = JS.flattened_provenance(JL.binding_ex(res.ctx3, local_binfo.id))
            @test JS.sourcetext(last(local_provs)) == "leaked"
            @test JS.source_location(last(local_provs))[1] == 5

            (global_binfo, _) = first(global_leaked)
            global_provs = JS.flattened_provenance(JL.binding_ex(res.ctx3, global_binfo.id))
            @test JS.sourcetext(last(global_provs)) == "leaked"
            @test JS.source_location(last(global_provs))[1] == 9
        end
    end
end

end # module test_jl_syntax_macros
