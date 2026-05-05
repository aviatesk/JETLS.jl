module test_binding

using Test
using JETLS: JETLS
using JETLS.LSP
using JETLS.LSP.URIs2

include(normpath(pkgdir(JETLS), "test", "jsjl-utils.jl"))

module lowering_module end

function with_target_binding(f, text::AbstractString; kwargs...)
    clean_code, positions = JETLS.get_text_and_positions(text; kwargs...)
    st0_top = jlparse(clean_code)
    cnt = 0
    for (i, pos) in enumerate(positions)
        offset = JETLS.xy_to_offset(clean_code, pos, @__FILE__)
        cnt += f(i, JETLS.select_target_binding(st0_top, offset, lowering_module))
    end
    return cnt
end

@testset "select_target_binding" begin
    @test with_target_binding("""
        let │x│xx│
            │x│xx│ = 42
            println(│x│xx│)
        end
        """) do i, (; binding)
        @test JS.sourcetext(binding) == "xxx"
        if i in (1,2,3)
            @test JS.source_line(binding) == 1
        elseif i in (4,5,6)
            @test JS.source_line(binding) == 2
        else
            @test JS.source_line(binding) == 3
        end
        return true
    end == 9

    # Don't select the internal bindings introduced with kwfunc definitions, where
    # the binding representing the kwfunc has a range that spans the entire `func(args...; kwargs...)`.
    # See `!startswith(binfo.name, "#")` within `find_target_binding`
    @test with_target_binding("""
        function func(x; │kw│=nothing)
            println(kw)
        end
        """) do _, (; binding)
        @test JS.sourcetext(binding) == "kw"
        @test JS.source_line(binding) == 1
        return true
    end == 2

    # Don't select a binding for keyword argument within `kwcall`
    let binfo = Ref{JL.BindingInfo}()
        @test with_target_binding("""
            function func(x; │kw│=nothing)
                println(│kw│)
            end
            """) do i, (; ctx3, binding)
            if i in (1, 2)
                @test JS.sourcetext(binding) == "kw"
                @test JS.source_line(binding) == 1
                binfo[] = JL.get_binding(ctx3, binding)
            else
                @test JS.sourcetext(binding) == "kw"
                @test JS.source_line(binding) == 2
                @test JL.get_binding(ctx3, binding).id == binfo[].id
            end
            return true
        end == 4
    end

    # Perform analysis on a `block` unit containing `local`
    let binfo = Ref{JL.BindingInfo}()
        @test with_target_binding("""
            begin
                local │xxx│ = 42
                getxxx() = │xxx│
            end
            """) do i, (; ctx3, binding)
            if i in (1, 2)
                @test JS.sourcetext(binding) == "xxx"
                @test JS.source_line(binding) == 2
                binfo[] = JL.get_binding(ctx3, binding)
            else
                @test JS.sourcetext(binding) == "xxx"
                @test JS.source_line(binding) == 3
                @test JL.get_binding(ctx3, binding).id == binfo[].id
            end
            return true
        end == 4
    end

    # Macrocall name binding
    @test with_target_binding("""
        │@info│ "hello"
        """) do _, (; ctx3, binding)
        binfo = JL.get_binding(ctx3, binding)
        @test binfo.kind === :global
        @test binfo.name == "@info"
        return true
    end == 2

    # Qualified macrocall: cursor at module name returns module binding
    @test with_target_binding("""
        │Bas│e.@info "hello"
        """) do _, (; ctx3, binding)
        binfo = JL.get_binding(ctx3, binding)
        @test binfo.kind === :global
        @test binfo.name == "Base"
        return true
    end == 2

    # Docstring function: cursor on argument should select the argument binding
    @test with_target_binding("""
        \"\"\"Docstring\"\"\"
        function func(│xxx│, yyy)
            println(│xxx│, yyy)
        end
        """) do _, (; ctx3, binding)
        @test JS.sourcetext(binding) == "xxx"
        binfo = JL.get_binding(ctx3, binding)
        @test binfo.kind === :argument
        return true
    end == 4

    # Qualified macrocall: cursor at end of macro name returns nothing
    @test with_target_binding("""
        Base.@info│ "hello"
        """) do _, result
        @test result === nothing
        return true
    end == 1

    # User-written identifiers escaped into a macro's generated code
    # (here via `\$` inside `@eval`) should resolve to the enclosing
    # user binding, not to any binding synthesized by the macro itself.
    @test with_target_binding("""
        let │valid_keys│ = 42
            @eval some_func() = \$│valid_keys│
        end
        """) do _, (; ctx3, binding)
        binfo = JL.get_binding(ctx3, binding)
        @test binfo.name == "valid_keys"
        @test binfo.kind === :local
        return true
    end == 4

    # User-written identifiers sitting in a macro's inert/quoted template
    # (here the type name inside `@eval`) should resolve to the matching
    # module-level global.
    @test with_target_binding("""
        struct │LSAnalyzer│ end
        let x = 1
            @eval some_func(::│LSAnalyzer│) = \$x
        end
        """) do _, (; ctx3, binding)
        binfo = JL.get_binding(ctx3, binding)
        @test binfo.name == "LSAnalyzer"
        @test binfo.kind === :global
        return true
    end == 4
end

function with_target_binding_definitions(f, text::AbstractString; kwargs...)
    clean_code, positions = JETLS.get_text_and_positions(text; kwargs...)
    st0_top = jlparse(clean_code)
    cnt = 0
    for (i, pos) in enumerate(positions)
        offset = JETLS.xy_to_offset(clean_code, pos, @__FILE__)
        cnt += f(i, JETLS.select_target_binding_definitions(st0_top, offset, lowering_module))
    end
    return cnt
end

@testset "`select_target_binding_definitions" begin
    @test with_target_binding_definitions("""
        function mapfunc(xs)
            Any[Core.Const(x│)
                for x in xs]
        end
    """) do _, res
        @test !isnothing(res)
        binding, defs = res
        @test JS.source_line(JS.sourceref(binding)) == 2
        @test length(defs) == 1
        @test JS.source_line(JS.sourceref(only(defs))) == 3
        return true
    end == 1

    @testset "simple" begin
        @test with_target_binding_definitions("""
            function func(x)
                y = x│ + 1
                return y│
            end
        """) do i, res
            if i == 1 # x│
                @test !isnothing(res)
                binding, defs = res
                @test JS.source_line(JS.sourceref(binding)) == 2
                @test length(defs) == 1
                @test JS.source_line(JS.sourceref(only(defs))) == 1
                return true
            elseif i == 2 # y│
                @test !isnothing(res)
                binding, defs = res
                @test JS.source_line(JS.sourceref(binding)) == 3
                @test length(defs) == 1
                @test JS.source_line(JS.sourceref(only(defs))) == 2
                return true
            end
        end == 2
    end

    @testset "parameter shadowing" begin
        @test with_target_binding_definitions("""
            function redef(x)
                x = 1
                y = x│ + 1
                return y│
            end
        """) do i, res
            if i == 1 # x│
                @test !isnothing(res)
                binding, defs = res
                @test JS.source_line(JS.sourceref(binding)) == 3
                @test length(defs) == 2 # Both parameter x and local x = 1
                # The definitions should include both x = 1 on line 2 and the parameter x on line 1
                @test any(d -> JS.source_line(JS.sourceref(d)) == 1, defs) # parameter
                @test any(d -> JS.source_line(JS.sourceref(d)) == 2, defs) # local assignment
                return true
            elseif i == 2 # y│
                @test !isnothing(res)
                binding, defs = res
                @test JS.source_line(JS.sourceref(binding)) == 4
                @test length(defs) == 1
                @test JS.source_line(JS.sourceref(only(defs))) == 3
                return true
            end
        end == 2
    end

    @testset "function self-reference" begin
        @test with_target_binding_definitions("""
            function rec(x)
                return rec│(x + 1)
            end
        """) do _, res
            @test !isnothing(res)
            binding, defs = res
            @test JS.source_line(JS.sourceref(binding)) == 2
            @test length(defs) >= 1
            @test any(defs) do def
                JS.source_line(JS.sourceref(def)) == 1
            end
            return true
        end == 1
    end

    @testset "static parameter" begin
        @test with_target_binding_definitions("""
            function func(::TTT) where TTT<:Integer
                return TTT│
            end
        """) do _, res
            @test !isnothing(res)
            binding, defs = res
            @test JS.source_line(JS.sourceref(binding)) == 2
            @test length(defs) == 1
            @test JS.source_line(JS.sourceref(only(defs))) == 1
            return true
        end == 1
    end

    @testset "closure captures" begin
        @test with_target_binding_definitions("""
            function closure()
                x = 1
                function inner(y)
                    return x│ + y│
                end
                return inner
            end
        """) do i, res
            if i == 1 # x│
                @test !isnothing(res)
                binding, defs = res
                @test JS.source_line(JS.sourceref(binding)) == 4
                @test length(defs) == 1
                @test JS.source_line(JS.sourceref(only(defs))) == 2
                return true
            elseif i == 2 # y│
                @test !isnothing(res)
                binding, defs = res
                @test JS.source_line(JS.sourceref(binding)) == 4
                @test length(defs) == 1
                @test JS.source_line(JS.sourceref(only(defs))) == 3
                return true
            end
        end == 2
    end

    @testset "let binding" begin
        @test with_target_binding_definitions("""
            function let_binding()
                let x = 1
                    y = x│ + 1
                    return y│
                end
            end
        """) do i, res
            if i == 1 # x│
                @test !isnothing(res)
                binding, defs = res
                @test JS.source_line(JS.sourceref(binding)) == 3
                @test length(defs) == 1
                @test JS.source_line(JS.sourceref(only(defs))) == 2
                return true
            elseif i == 2 # y│
                @test !isnothing(res)
                binding, defs = res
                @test JS.source_line(JS.sourceref(binding)) == 4
                @test length(defs) == 1
                @test JS.source_line(JS.sourceref(only(defs))) == 3
                return true
            end
        end == 2
    end

    @testset "for loop variable" begin
        @test with_target_binding_definitions("""
            function loop_var(n)
                for i in 1:n
                    println(i│)
                end
            end
        """) do _, res
            @test !isnothing(res)
            binding, defs = res
            @test JS.source_line(JS.sourceref(binding)) == 3
            @test length(defs) == 1
            @test JS.source_line(JS.sourceref(only(defs))) == 2
            return true
        end == 1
    end

    @testset "comprehension variable" begin
        @test with_target_binding_definitions("""
            let
                v = [│xxx^2 for xxx in 1:5]
                return v
            end
        """) do _, res
            @test !isnothing(res)
            binding, defs = res
            @test JS.source_line(JS.sourceref(binding)) == 2
            @test length(defs) == 1
            @test JS.source_line(JS.sourceref(only(defs))) == 2
            return true
        end == 1
    end

    @testset "destructuring assignment" begin
        @test with_target_binding_definitions("""
            function destructuring()
                (a, b) = (1, 2)
                return a│ + b│
            end
        """) do i, res
            if i == 1 # a│
                @test !isnothing(res)
                binding, defs = res
                @test JS.source_line(JS.sourceref(binding)) == 3
                @test length(defs) == 1
                @test JS.source_line(JS.sourceref(only(defs))) == 2
                return true
            elseif i == 2 # b│
                @test !isnothing(res)
                binding, defs = res
                @test JS.source_line(JS.sourceref(binding)) == 3
                @test length(defs) == 1
                @test JS.source_line(JS.sourceref(only(defs))) == 2
                return true
            end
        end == 2
    end

    @testset "conditional binding" begin
        @test with_target_binding_definitions("""
            function if_branch(x)
                if x > 0
                    y = x
                end
                return y│
            end
        """) do _, res
            @test !isnothing(res)
            binding, defs = res
            @test JS.source_line(JS.sourceref(binding)) == 5
            @test length(defs) == 1
            @test JS.source_line(JS.sourceref(only(defs))) == 3
            return true
        end == 1
    end

    @testset "try-catch variable" begin
        @test with_target_binding_definitions("""
            function try_catch()
                try
                    error("boom")
                catch err
                    return err│
                end
            end
        """) do _, res
            @test !isnothing(res)
            binding, defs = res
            @test JS.source_line(JS.sourceref(binding)) == 5
            @test length(defs) == 1
            @test JS.source_line(JS.sourceref(only(defs))) == 4
            return true
        end == 1
    end

    @testset "do block parameter" begin
        @test with_target_binding_definitions("""
            function do_block()
                map(1:3) do t
                    t│ + 1
                end
            end
        """) do _, res
            @test !isnothing(res)
            binding, defs = res
            @test JS.source_line(JS.sourceref(binding)) == 3
            @test length(defs) == 1
            @test JS.source_line(JS.sourceref(only(defs))) == 2
            return true
        end == 1
    end

    @testset "lambda parameter" begin
        @test with_target_binding_definitions("""
            sq = x -> x│ ^ 2
        """) do _, res
            @test !isnothing(res)
            binding, defs = res
            @test JS.source_line(JS.sourceref(binding)) == 1
            @test length(defs) == 1
            @test JS.source_line(JS.sourceref(only(defs))) == 1
            return true
        end == 1
    end

    @testset "nested let scopes" begin
        @test with_target_binding_definitions("""
            function nested_let()
                let x = 1
                    let x = 2
                        return x│
                    end
                end
            end
        """) do _, res
            @test !isnothing(res)
            binding, defs = res
            @test JS.source_line(JS.sourceref(binding)) == 4
            @test length(defs) == 1
            @test JS.source_line(JS.sourceref(only(defs))) == 3
            return true
        end == 1
    end

    @testset "for loop shadowing" begin
        @test with_target_binding_definitions("""
            function loop_shadow()
                x = 0
                for x = 1:3
                    println(x│)
                end
            end
        """) do _, res
            @test !isnothing(res)
            binding, defs = res
            @test JS.source_line(JS.sourceref(binding)) == 4
            @test length(defs) == 1
            @test JS.source_line(JS.sourceref(only(defs))) == 3
            return true
        end == 1
    end

    @testset "closure recapture" begin
        @test with_target_binding_definitions("""
            function recapture()
                x = 1
                f = () -> x│ + 1
                x = 2
                return f()
            end
        """) do _, res
            @test !isnothing(res)
            binding, defs = res
            @test JS.source_line(JS.sourceref(binding)) == 3
            @test length(defs) == 2
            @test any(def -> JS.source_line(JS.sourceref(def)) == 2, defs)
            @test any(def -> JS.source_line(JS.sourceref(def)) == 4, defs)
            return true
        end == 1
    end

    @testset "keyword arguments" begin
        @test with_target_binding_definitions("""
            function keyword_args(; a = 1, b = 2)
                a│ + b│
            end
        """) do i, res
            if i == 1 # a│
                @test !isnothing(res)
                binding, defs = res
                @test JS.source_line(JS.sourceref(binding)) == 2
                @test length(defs) == 1
                @test JS.source_line(JS.sourceref(only(defs))) == 1
                return true
            elseif i == 2 # b│
                @test !isnothing(res)
                binding, defs = res
                @test JS.source_line(JS.sourceref(binding)) == 2
                @test length(defs) == 1
                @test JS.source_line(JS.sourceref(only(defs))) == 1
                return true
            end
        end == 2
    end

    @testset "inner function parameter shadowing" begin
        @test with_target_binding_definitions("""
            function outer()
                x = 1
                function inner(x)
                    return x│ + 1
                end
                return inner
            end
        """) do _, res
            @test !isnothing(res)
            binding, defs = res
            @test JS.source_line(JS.sourceref(binding)) == 4
            @test length(defs) == 1
            @test JS.source_line(JS.sourceref(only(defs))) == 3
            return true
        end == 1
    end

    @testset "non-linear control flow" begin
        @test with_target_binding_definitions("""
            function not_linear()
                finish = false
                @label l1
                (!finish) && @goto l2
                return x│
                @label l2
                x = 1
                finish = true
                @goto l1
            end
        """) do _, res
            @test !isnothing(res)
            binding, defs = res
            @test JS.source_line(JS.sourceref(binding)) == 5
            @test length(defs) == 1
            @test JS.source_line(JS.sourceref(only(defs))) == 7
            return true
        end == 1
    end

    @testset "undefined variable" begin
        @test with_target_binding_definitions("""
            function undefined_var()
                return x│
            end
        """) do _, res
            @test isnothing(res)
            return true
        end == 1
    end

    # `` `...` `` parses to `Core.@cmd(LineNumberNode, CmdString)` where the
    # cmd content is a single opaque `CmdString` leaf — the parser does not
    # split `\$name` interpolations into child nodes. So a cursor placed on
    # the `x` inside `` `\$x` `` resolves to the `CmdString` (not an
    # `Identifier`), and binding lookup can't reach the `x` argument above.
    # Macro expansion recovers usedness but with byte-range-0:0 provenance,
    # which doesn't help source-position-based lookups.
    @testset "cmd literal interpolation" begin
        @test with_target_binding_definitions("""
            function f(x)
                `echo \$x│`
            end
        """) do _, res
            @test_broken !isnothing(res)
            return true
        end == 1
    end
end

end # module test_binding
