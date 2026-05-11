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
    return JETLS.jl_lower_for_scope_resolution(mod, st0;
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

# Negative counterpart of `assert_binding_provenance`: verifies that no
# binding of the given kind/name exists. Used for identifiers that the macro
# stub intentionally drops (e.g. kwarg keys in logging macros, which are
# metadata symbols and not user references).
function assert_no_binding(res, kind::Symbol, name::AbstractString)
    binding_occurrences = JETLS.compute_binding_occurrences(
        res.ctx3, res.st3, false; include_global_bindings=true)
    found = any(binding_occurrences) do (b, _)
        b.kind === kind && b.name == name
    end
    @test !found
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

@testset "@show" begin
    @testset "macro expansion" begin
        # Zero-arg form: real `@show` returns `nothing`; the stub emits a
        # placeholder `K"Value"` node.
        let st1 = jlexpand("@show")
            @test JS.kind(st1) === JS.K"Value"
        end

        # Single-arg form: returned unchanged so it slots into expressions like
        # `x = @show foo` without an extra block wrapper.
        let st1 = jlexpand("@show xxx")
            @test JS.kind(st1) === JS.K"Identifier"
            @test JS.sourcetext(st1) == "xxx"
        end

        # Multi-arg form: each user expression flows through a `block`.
        let st1 = jlexpand("@show xxx yyy zzz")
            @test JS.kind(st1) === JS.K"block"
            @test JS.numchildren(st1) == 3
        end
    end

    @testset "binding resolution preserves provenance" begin
        let res = jlresolve("@show sin(xxx) cos(yyy)")
            assert_binding_provenance(res, :global, "xxx")
            assert_binding_provenance(res, :global, "yyy")
        end
    end
end

# `@logmsg` is not exported from `Base`, so a module that uses it must
# `using Logging` (or `using Base.CoreLogging`). The other logging macros
# (`@debug`/`@info`/`@warn`/`@error`) are exported from `Base` by default.
module logging_module
    using Logging
end
logging_expand(code::AbstractString) = jlexpand(logging_module, code)
logging_resolve(code::AbstractString) = jlresolve(logging_module, code)

@testset "@debug / @info / @warn / @error" begin
    @testset "macro expansion" begin
        for name in ("@debug", "@info", "@warn", "@error")
            # Bare message: wrapped in a `block` so the trailing
            # `nothing::K"Value"` matches the macros' "always returns
            # `nothing`" contract.
            let st1 = logging_expand("$name \"msg\"")
                @test JS.kind(st1) === JS.K"block"
                @test JS.kind(st1[end]) === JS.K"Value"
            end

            # Mixed kwargs / bare positional / splat: kwarg RHS and the splat
            # operand both flow through, the wrapping `K"="` and `K"..."`
            # nodes are dropped so they don't reach later lowering passes.
            let st1 = logging_expand("$name \"msg\" xxx yyy=zzz extras...")
                @test JS.kind(st1) === JS.K"block"
                @test all(c -> JS.kind(c) ∉ JS.KSet"= ...", JS.children(st1))
            end

            # The message itself can be a `begin`/`end` block (per the
            # docstring's lazy-evaluation example); it flows through unchanged.
            let st1 = logging_expand("$name begin x = 1; \"got \$x\" end")
                @test JS.kind(st1) === JS.K"block"
                @test JS.kind(st1[1]) === JS.K"block"
            end
        end
    end

    @testset "validation" begin
        # Zero-arg form rejected for each macro.
        for name in ("@debug", "@info", "@warn", "@error")
            let err = try
                    logging_expand(name)
                    nothing
                catch err
                    err
                end
                @test err isa JL.MacroExpansionError
                @test occursin("$name requires at least one argument", err.msg)
            end
        end

        # Duplicate kwarg names are flagged at expansion time; without this,
        # they'd surface only as a generic `syntax: field name "k" repeated`
        # error from lowering the synthesized `(; k=1, k=2)` named tuple.
        # Metadata keys (`_module`, `_group`, ...) are checked the same way,
        # even though Base silently overwrites them.
        for name in ("@debug", "@info", "@warn", "@error")
            for code in ("$name \"msg\" k=1 k=2",
                         "$name \"msg\" _module=a _module=b")
                let err = try
                        logging_expand(code)
                        nothing
                    catch err
                        err
                    end
                    @test err isa JL.MacroExpansionError
                    @test occursin("provided more than once", err.msg)
                end
            end
        end
    end

    @testset "binding resolution preserves provenance" begin
        # Identifiers in the message (including string interpolations), the
        # kwarg values, the bare positional args, and any splat operand should
        # all stay visible to scope resolution as user-written. The kwarg
        # *key* `ppp`, on the other hand, is a metadata symbol — it must not
        # reach scope resolution.
        for name in ("@debug", "@info", "@warn", "@error")
            let res = logging_resolve("$name \"msg: \$xxx\" yyy ppp=fff(qqq) eee...")
                assert_binding_provenance(res, :global, "xxx")
                assert_binding_provenance(res, :global, "yyy")
                assert_binding_provenance(res, :global, "fff")
                assert_binding_provenance(res, :global, "qqq")
                assert_binding_provenance(res, :global, "eee")
                assert_no_binding(res, :global, "ppp")
            end
        end
    end
end

@testset "@logmsg" begin
    @testset "macro expansion" begin
        # Both `level` and `message` flow through a `block`; the trailing
        # `nothing::K"Value"` matches the macro's return contract.
        let st1 = logging_expand("@logmsg lvl \"msg\" xxx yyy=zzz")
            @test JS.kind(st1) === JS.K"block"
            @test JS.kind(st1[end]) === JS.K"Value"
        end
    end

    @testset "validation" begin
        # 0 and 1 arg both fall through to the variadic fallback, since
        # `@logmsg` requires both a `level` and a `message`.
        for code in ("@logmsg", "@logmsg lvl")
            let err = try
                    logging_expand(code)
                    nothing
                catch err
                    err
                end
                @test err isa JL.MacroExpansionError
                @test occursin("@logmsg requires at least two arguments", err.msg)
            end
        end

        # Duplicate kwargs are flagged the same way as for the level-implicit
        # logging macros.
        let err = try
                logging_expand("@logmsg lvl \"msg\" foo=1 foo=2")
                nothing
            catch err
                err
            end
            @test err isa JL.MacroExpansionError
            @test occursin("provided more than once", err.msg)
        end
    end

    @testset "binding resolution preserves provenance" begin
        # The level expression must stay visible — `@logmsg` is the only
        # logging macro that takes a user-written level, and it's frequently
        # a custom `LogLevel` constant whose definition site we want to track.
        # The kwarg key `yyy` is a metadata symbol and must not surface as a
        # binding.
        let res = logging_resolve("@logmsg lvl \"msg: \$xxx\" yyy=zzz")
            assert_binding_provenance(res, :global, "lvl")
            assert_binding_provenance(res, :global, "xxx")
            assert_binding_provenance(res, :global, "zzz")
            assert_no_binding(res, :global, "yyy")
        end
    end
end

# Helper: walk the EST and return the first `K"core"` / `K"top"` node whose
# inner `K"Identifier"` matches `name`. Used to verify that the expansion
# synthesizes `Core.invoke` / `Base.invokelatest` (and the synthesized
# `getproperty` / `setindex!` / etc. references).
function find_named_ref(st::JS.SyntaxTree, k::JS.Kind, name::AbstractString)
    if JS.kind(st) === k && JS.numchildren(st) >= 1
        inner = st[1]
        if JS.kind(inner) === JS.K"Identifier" &&
            hasproperty(inner, :name_val) && inner.name_val == name
            return st
        end
    end
    for c in JS.children(st)
        r = find_named_ref(c, k, name)
        r === nothing || return r
    end
    return nothing
end

@testset "@invoke / @invokelatest" begin
    @testset "@invoke macro expansion" begin
        # `f(args...)` -> `Core.invoke(f, Tuple{T1, ...}, args...)`.
        let st1 = jlexpand("@invoke f(x::T, y)")
            @test JS.kind(st1) === JS.K"call"
            @test find_named_ref(st1, JS.K"core", "invoke") !== nothing
            @test find_named_ref(st1, JS.K"core", "Tuple") !== nothing
            # Annotation-less arg `y` falls back to `Core.Typeof(y)`.
            @test find_named_ref(st1, JS.K"core", "Typeof") !== nothing
        end

        # `x.f` -> `Core.invoke(Base.getproperty, Tuple{...}, x, :f)`.
        let st1 = jlexpand("@invoke x.f")
            @test JS.kind(st1) === JS.K"call"
            @test find_named_ref(st1, JS.K"core", "invoke") !== nothing
            @test find_named_ref(st1, JS.K"top", "getproperty") !== nothing
        end

        # `xs[i]` -> `Core.invoke(Base.getindex, Tuple{...}, xs, i)`.
        let st1 = jlexpand("@invoke xs[i]")
            @test find_named_ref(st1, JS.K"top", "getindex") !== nothing
        end

        # `x.f = v` -> `Core.invoke(Base.setproperty!, Tuple{...}, x, :f, v)`.
        let st1 = jlexpand("@invoke x.f = v")
            @test find_named_ref(st1, JS.K"top", "setproperty!") !== nothing
        end

        # `xs[i] = v` -> `Core.invoke(Base.setindex!, Tuple{...}, xs, v, i)`.
        let st1 = jlexpand("@invoke xs[i] = v")
            @test find_named_ref(st1, JS.K"top", "setindex!") !== nothing
        end

        # kwargs survive as a `K"parameters"` block on the synthesized call.
        let st1 = jlexpand("@invoke f(x::T; k=v)")
            @test any(c -> JS.kind(c) === JS.K"parameters", JS.children(st1))
        end
    end

    @testset "@invokelatest macro expansion" begin
        # `f(args...)` -> `Base.invokelatest(f, args...)`. Note no `Tuple{...}`
        # — types are not part of `invokelatest`'s signature.
        let st1 = jlexpand("@invokelatest f(x, y)")
            @test JS.kind(st1) === JS.K"call"
            @test find_named_ref(st1, JS.K"top", "invokelatest") !== nothing
            @test find_named_ref(st1, JS.K"core", "Tuple") === nothing
        end

        let st1 = jlexpand("@invokelatest x.f")
            @test find_named_ref(st1, JS.K"top", "invokelatest") !== nothing
            @test find_named_ref(st1, JS.K"top", "getproperty") !== nothing
        end

        let st1 = jlexpand("@invokelatest xs[i] = v")
            @test find_named_ref(st1, JS.K"top", "setindex!") !== nothing
        end

        # kwargs survive on the synthesized call.
        let st1 = jlexpand("@invokelatest f(x; k=v)")
            @test any(c -> JS.kind(c) === JS.K"parameters", JS.children(st1))
        end
    end

    @testset "validation" begin
        for name in ("@invoke", "@invokelatest")
            # Zero / multiple arguments fall through to the variadic fallback.
            for code in ("$name", "$name f(x) g(y)")
                let err = try
                        jlexpand(code)
                        nothing
                    catch err
                        err
                    end
                    @test err isa JL.MacroExpansionError
                    @test occursin("expects exactly one argument", err.msg)
                end
            end

            # Bare identifier / literal isn't one of the allowed call shapes.
            for code in ("$name 42", "$name foo")
                let err = try
                        jlexpand(code)
                        nothing
                    catch err
                        err
                    end
                    @test err isa JL.MacroExpansionError
                    @test occursin("expected a `:call` expression", err.msg)
                end
            end

            # `=` form requires the LHS to be `x.f` or `xs[i]`.
            let err = try
                    jlexpand("$name a = b")
                    nothing
                catch err
                    err
                end
                @test err isa JL.MacroExpansionError
                @test occursin("setproperty!", err.msg)
            end
        end
    end

    @testset "binding resolution preserves provenance" begin
        for name in ("@invoke", "@invokelatest")
            # `f`, the positional arg, and (for `@invoke`) the `::T` annotation
            # should all remain visible to scope resolution.
            let res = jlresolve("$name fff(xxx::TTT)")
                assert_binding_provenance(res, :global, "fff")
                assert_binding_provenance(res, :global, "xxx")
                assert_binding_provenance(res, :global, "TTT")
            end
            # In setter forms, both the receiver and the rhs identifier survive.
            let res = jlresolve("$name xs[iii] = vvv")
                assert_binding_provenance(res, :global, "xs")
                assert_binding_provenance(res, :global, "iii")
                assert_binding_provenance(res, :global, "vvv")
            end
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
