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

jleval(mod::Module, code::AbstractString) = JL.eval(mod, jlparse(code; rule=:statement))
jleval(code::AbstractString) = jleval(lowering_module, code)

children_kinds(st::JS.SyntaxTree) = JS.Kind[JS.kind(c) for c in JS.children(st)]

# Look up the first binding matching `kind`/`name` in the resolved scope and
# verify its last provenance entry's sourcetext is `name` — i.e. the user-
# written identifier survived macro expansion with its byte range intact, so
# downstream LSP analyses (`is_from_user_ast` etc.) can recognize it as
# user code. Used by every macro stub's "binding resolution preserves
# provenance" testset.
function assert_binding_provenance(res, kind::Symbol, name::AbstractString)
    binding_occurrences = JETLS.compute_binding_occurrences(
        res.ctx3, res.st3, false; include_global_bindings=true)
    binfo = nothing
    for (b, _) in binding_occurrences
        if b.kind === kind && b.name == name
            binfo = b
            break
        end
    end
    @test binfo !== nothing
    binfo === nothing && return nothing
    provs = JS.flattened_provenance(JL.binding_ex(res.ctx3, binfo.id))
    @test JS.sourcetext(last(provs)) == name
    return (binfo, provs)
end

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
            assert_binding_provenance(res, :global, "xxx")
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

@testset "@something" begin
    @testset "binding resolution preserves provenance" begin
        let res = jlresolve("somefunc(xxx) = @something(xxx, yyy)")
            assert_binding_provenance(res, :argument, "xxx")
            assert_binding_provenance(res, :global, "yyy")
        end
    end

    @testset "runtime semantics" begin
        # Drive the new-style macro definition end-to-end via `JL.eval` and check the
        # results match `Base.@something`'s contract: returns the first non-`nothing`
        # argument (unwrapped from `Some` if present), short-circuits later arguments,
        # and throws when every argument is `nothing` (or no arguments are supplied).

        # Returns the first non-`nothing` argument
        @test jleval("@something 1") === 1
        @test jleval("@something \"abc\"") === "abc"
        @test jleval("@something nothing 2") === 2
        @test jleval("@something nothing nothing 3") === 3

        # `Some`-wrapped value is unwrapped; `Some(nothing)` returns `nothing` (the canonical "explicit `nothing`" sentinel)
        @test jleval("@something Some(42)") === 42
        @test jleval("@something nothing Some(7)") === 7
        @test jleval("@something Some(nothing)") === nothing

        # All-`nothing` (and the zero-argument form) throws
        @test_throws ArgumentError jleval("@something nothing")
        @test_throws ArgumentError jleval("@something nothing nothing")
        @test_throws ArgumentError jleval("@something")

        # Short-circuit: later arguments are not evaluated once an earlier one produces a non-`nothing` value.
        @test jleval("""let counter = Ref(false)
            r = @something 42 (counter[] = true; 99)
            (r, counter[])
        end""") === (42, false)
        @test jleval("""let counter = Ref(false)
            r = @something nothing (counter[] = true; 99)
            (r, counter[])
        end""") === (99, true)
    end
end

@testset "@assert" begin
    @testset "macro expansion" begin
        # Bare condition: lowered to `cond ? nothing : throw(AssertionError(...))`
        # so the false branch terminates control flow.
        let st1 = jlexpand("@assert x == 1")
            @test JS.kind(st1) === JS.K"if"
        end

        # Condition + user message uses the message as the AssertionError arg.
        let st1 = jlexpand("@assert x == 1 \"failed\"")
            @test JS.kind(st1) === JS.K"if"
        end

        # Base silently ignores extra trailing message arguments; extras are
        # piled into a leading block so they remain visible to the resolver.
        let st1 = jlexpand("@assert x == 1 \"a\" \"b\"")
            @test JS.kind(st1) === JS.K"block"
            @test JS.kind(st1[end]) === JS.K"if"
        end
    end

    @testset "validation" begin
        # Zero-argument form rejected.
        let err = try
                jlexpand("@assert")
                nothing
            catch err
                err
            end
            @test err isa JL.MacroExpansionError
            @test occursin("at least one argument is required", err.msg)
        end
    end

    @testset "binding resolution preserves provenance" begin
        # Identifiers in the condition and the message must both be visible
        # to the resolver as user-written.
        let res = jlresolve("@assert sin(xxx) == 0 \"oops: \$yyy\"")
            assert_binding_provenance(res, :global, "xxx")
            assert_binding_provenance(res, :global, "yyy")
        end
    end
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

        # Keyword arguments keep only the RHS so the `K"="` node doesn't reach
        # later lowering passes, but identifiers in the RHS still flow through
        # to scope resolution.
        for kw in ("broken=true", "skip=cond", "context=ctx", "atol=0.1")
            let st1 = test_macro_expand("@test x $kw")
                @test JS.kind(st1) === JS.K"block"
                @test all(c -> JS.kind(c) !== JS.K"=", JS.children(st1))
            end
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
        let res = test_macro_lower("@test sin(xxx) == 1.0")
            assert_binding_provenance(res, :global, "xxx")
        end
        # Identifiers inside kw RHS values must keep their provenance so
        # downstream LSP analyses (undef-var, references, ...) see them as
        # user-written. With the kw fully dropped, `yyy` would be invisible.
        let res = test_macro_lower("@test sin(xxx) == 1.0 broken=yyy")
            assert_binding_provenance(res, :global, "xxx")
            assert_binding_provenance(res, :global, "yyy")
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
        # a sibling `@testset`, mirroring the `try`/`catch` scope of the real macro.
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
            local_result = assert_binding_provenance(res, :local, "leaked")
            @test local_result !== nothing &&
                JS.source_location(last(local_result[2]))[1] == 5

            global_result = assert_binding_provenance(res, :global, "leaked")
            @test global_result !== nothing &&
                JS.source_location(last(global_result[2]))[1] == 9
        end
    end
end

@testset "Test.@test_throws" begin
    @testset "macro expansion" begin
        # Both args flow through a `block` so identifiers in either get scope analysis.
        let st1 = test_macro_expand("@test_throws BoundsError xxx[4]")
            @test JS.kind(st1) === JS.K"block"
            @test JS.numchildren(st1) == 2
        end
    end

    @testset "validation" begin
        # `@test_throws` strictly requires two positional arguments.
        for code in ("@test_throws", "@test_throws BoundsError",
                     "@test_throws BoundsError xxx yyy")
            let err = try
                    test_macro_expand(code)
                    nothing
                catch err
                    err
                end
                @test err isa JL.MacroExpansionError
                @test occursin("@test_throws expects exactly two arguments", err.msg)
            end
        end
    end

    @testset "binding resolution preserves provenance" begin
        let res = test_macro_lower("@test_throws BoundsError getindex(xxx)")
            assert_binding_provenance(res, :global, "xxx")
        end
    end
end

@testset "Test.@test_broken / Test.@test_skip" begin
    @testset "macro expansion" begin
        for name in ("@test_broken", "@test_skip")
            let st1 = test_macro_expand("$name xxx == 1")
                @test JS.kind(st1) === JS.K"call"
                @test strip(JS.sourcetext(st1)) == "xxx == 1"
            end
            # Keyword arguments keep only the RHS in a block so identifiers
            # there still flow through to scope resolution.
            let st1 = test_macro_expand("$name foo(xxx) atol=0.1")
                @test JS.kind(st1) === JS.K"block"
                @test all(c -> JS.kind(c) !== JS.K"=", JS.children(st1))
            end
        end
    end

    @testset "validation" begin
        # Non-`key=value` positional arguments are rejected.
        for name in ("@test_broken", "@test_skip")
            let err = try
                    test_macro_expand("$name xxx foo")
                    nothing
                catch err
                    err
                end
                @test err isa JL.MacroExpansionError
                @test occursin("expected `keyword=value`", err.msg)
            end
        end
    end

    @testset "binding resolution preserves provenance" begin
        for name in ("@test_broken", "@test_skip")
            let res = test_macro_lower("$name sin(xxx) == 1.0")
                assert_binding_provenance(res, :global, "xxx")
            end
            let res = test_macro_lower("$name sin(xxx) == 1.0 atol=yyy")
                assert_binding_provenance(res, :global, "xxx")
                assert_binding_provenance(res, :global, "yyy")
            end
        end
    end
end

@testset "Test.@test_warn / Test.@test_nowarn" begin
    @testset "macro expansion" begin
        let st1 = test_macro_expand("@test_warn \"oops\" foo(xxx)")
            @test JS.kind(st1) === JS.K"block"
            @test JS.numchildren(st1) == 2
        end
        let st1 = test_macro_expand("@test_nowarn foo(xxx)")
            @test JS.kind(st1) === JS.K"call"
            @test JS.sourcetext(st1[1]) == "foo"
            @test JS.sourcetext(st1[2]) == "xxx"
        end
    end

    @testset "binding resolution preserves provenance" begin
        let res = test_macro_lower("@test_warn \"oops\" sin(xxx)")
            assert_binding_provenance(res, :global, "xxx")
        end
    end
end

@testset "Test.@test_logs" begin
    @testset "macro expansion" begin
        # Patterns + body all flow through a `block`.
        let st1 = test_macro_expand("@test_logs (:info, \"msg\") foo(xxx)")
            @test JS.kind(st1) === JS.K"block"
            @test JS.numchildren(st1) == 2
        end

        # Keyword arguments (e.g. `min_level=Logging.Warn`) keep only the RHS so
        # the `K"="` node doesn't reach later lowering passes.
        let st1 = test_macro_expand("@test_logs min_level=yyy foo(xxx)")
            @test JS.kind(st1) === JS.K"block"
            @test all(c -> JS.kind(c) !== JS.K"=", JS.children(st1))
        end
    end

    @testset "validation" begin
        let err = try
                test_macro_expand("@test_logs")
                nothing
            catch err
                err
            end
            @test err isa JL.MacroExpansionError
            @test occursin("@test_logs needs at least one argument", err.msg)
        end
    end

    @testset "binding resolution preserves provenance" begin
        # Both the pattern's RHS keyword value and the body must keep accurate
        # byte ranges so downstream LSP analyses accept them as user-written.
        let res = test_macro_lower("@test_logs (:info, \"msg\") min_level=yyy sin(xxx)")
            assert_binding_provenance(res, :global, "xxx")
            assert_binding_provenance(res, :global, "yyy")
        end
    end
end

@testset "Test.@test_deprecated" begin
    @testset "macro expansion" begin
        let st1 = test_macro_expand("@test_deprecated foo(xxx)")
            @test JS.kind(st1) === JS.K"call"
        end
        let st1 = test_macro_expand("@test_deprecated r\"warn\" foo(xxx)")
            @test JS.kind(st1) === JS.K"block"
            @test JS.numchildren(st1) == 2
        end
    end

    @testset "validation" begin
        for code in ("@test_deprecated", "@test_deprecated a b c")
            let err = try
                    test_macro_expand(code)
                    nothing
                catch err
                    err
                end
                @test err isa JL.MacroExpansionError
                @test occursin("@test_deprecated expects one or two arguments", err.msg)
            end
        end
    end
end

@testset "Test.@inferred" begin
    @testset "macro expansion" begin
        let st1 = test_macro_expand("@inferred foo(xxx)")
            @test JS.kind(st1) === JS.K"call"
        end
        let st1 = test_macro_expand("@inferred Int foo(xxx)")
            @test JS.kind(st1) === JS.K"block"
            @test JS.numchildren(st1) == 2
        end
    end

    @testset "validation" begin
        for code in ("@inferred", "@inferred Int foo(x) extra")
            let err = try
                    test_macro_expand(code)
                    nothing
                catch err
                    err
                end
                @test err isa JL.MacroExpansionError
                @test occursin("@inferred expects one or two arguments", err.msg)
            end
        end
    end

    @testset "binding resolution preserves provenance" begin
        let res = test_macro_lower("@inferred Int sin(xxx)")
            assert_binding_provenance(res, :global, "xxx")
        end
    end
end

@testset "Base.@assume_effects" begin
    @testset "macro expansion" begin
        # Function-definition body is returned unchanged.
        let st1 = jlexpand("Base.@assume_effects :foldable f(x) = x + 1")
            @test JS.kind(st1) === JS.K"="
            @test JS.kind(st1[1]) === JS.K"call" # f(x)
        end

        # `@ccall` body is passed through; the new-style `@ccall` macro then
        # handles its own expansion downstream.
        let st1 = jlexpand("Base.@assume_effects :total @ccall foo()::Cvoid")
            @test st1 isa JS.SyntaxTree
        end

        # Call-site annotation: the body expression is returned unchanged.
        let st1 = jlexpand("Base.@assume_effects :foldable foo(xxx)")
            @test JS.kind(st1) === JS.K"call"
            @test JS.sourcetext(st1[1]) == "foo"
            @test JS.sourcetext(st1[2]) == "xxx"
        end

        # Multiple settings, including negation and shortcuts.
        let st1 = jlexpand("Base.@assume_effects :total !:nothrow foo(xxx)")
            @test JS.kind(st1) === JS.K"call"
            @test JS.sourcetext(st1[2]) == "xxx"
        end

        # Declaration form (no body): expands to a no-op placeholder.
        let st1 = jlexpand("Base.@assume_effects :foldable")
            @test JS.kind(st1) === JS.K"Value"
        end
    end

    @testset "validation" begin
        # Zero-argument form rejected.
        let err = try
                jlexpand("Base.@assume_effects")
                nothing
            catch err
                err
            end
            @test err isa JL.MacroExpansionError
            @test occursin("at least one argument is required", err.msg)
        end

        # Unknown setting name (in non-final position) is rejected.
        let err = try
                jlexpand("Base.@assume_effects :badname foo()")
                nothing
            catch err
                err
            end
            @test err isa JL.MacroExpansionError
            @test occursin("unrecognized effect setting `:badname`", err.msg)
        end

        # Setting in non-final position must look like a setting form.
        for bad in ("42", "\"foldable\"", "foo()")
            let err = try
                    jlexpand("Base.@assume_effects $bad foo()")
                    nothing
                catch err
                    err
                end
                @test err isa JL.MacroExpansionError
                @test occursin("expected an effect setting", err.msg)
            end
        end

        # `:nortcall` and `:consistent_overlay` are not accepted as standalone
        # inputs — they're internal-only (set via shortcuts).
        for setting in (":nortcall", ":consistent_overlay")
            let err = try
                    jlexpand("Base.@assume_effects $setting foo()")
                    nothing
                catch err
                    err
                end
                @test err isa JL.MacroExpansionError
                @test occursin("unrecognized effect setting", err.msg)
            end
        end

        # An unrecognized last argument is treated as a body (call-site
        # annotation), not as a typo'd setting — matches Base's behavior.
        @test jlexpand("Base.@assume_effects :foldable badname") isa JS.SyntaxTree
    end

    @testset "all recognized settings accepted" begin
        for setting in (":consistent", ":effect_free", ":nothrow",
                        ":terminates_globally", ":terminates_locally",
                        ":notaskstate", ":inaccessiblememonly",
                        ":noub", ":noub_if_noinbounds",
                        ":foldable", ":removable", ":total")
            @test jlexpand("Base.@assume_effects $setting f() = 1") isa JS.SyntaxTree
            # Negated form should also be accepted.
            @test jlexpand("Base.@assume_effects !$setting f() = 1") isa JS.SyntaxTree
        end
    end

    @testset "binding resolution preserves provenance" begin
        # The whole point of the new-style stub: identifiers inside the body
        # must keep accurate byte ranges so downstream LSP analyses can accept
        # them as user-written via `is_from_user_ast`.
        let res = jlresolve("g() = Base.@assume_effects :foldable sin(xxx)")
            assert_binding_provenance(res, :global, "xxx")
        end
    end
end

end # module test_jl_syntax_macros
