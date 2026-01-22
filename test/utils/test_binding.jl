module test_binding

using Test
using JETLS: JETLS
using JETLS.LSP
using JETLS.LSP.URIs2

include(normpath(pkgdir(JETLS), "test", "jsjl-utils.jl"))

global lowering_module::Module = Module()

function with_target_binding(f, text::AbstractString; kwargs...)
    clean_code, positions = JETLS.get_text_and_positions(text; kwargs...)
    st0_top = jlparse(clean_code)
    for (i, pos) in enumerate(positions)
        offset = JETLS.xy_to_offset(clean_code, pos, @__FILE__)
        f(i, JETLS.select_target_binding(st0_top, offset, lowering_module))
    end
end

function _with_target_binding(f, text::AbstractString; kwargs...)
    clean_code, positions = JETLS.get_text_and_positions(text; kwargs...)
    st0_top = jlparse(clean_code)
    for (i, pos) in enumerate(positions)
        offset = JETLS.xy_to_offset(clean_code, pos, @__FILE__)
        f(i, JETLS._select_target_binding(st0_top, offset, lowering_module))
    end
end

@testset "select_target_binding" begin
    let cnt = 0
        with_target_binding("""
            let │x│xx│
                │x│xx│ = 42
                println(│x│xx│)
            end
            """) do i, binding
            @test JS.sourcetext(binding) == "xxx"
            if i in (1,2,3)
                @test JS.source_line(binding) == 1
            elseif i in (4,5,6)
                @test JS.source_line(binding) == 2
            else
                @test JS.source_line(binding) == 3
            end
            cnt += 1
        end
        @test cnt == 9
    end

    # Don't select the internal bindings introduced with kwfunc definitions, where
    # the binding representing the kwfunc has a range that spans the entire `func(args...; kwargs...)`.
    # See `!startswith(binfo.name, "#")` within `__select_target_binding`
    let cnt = 0
        with_target_binding("""
            function func(x; │kw│=nothing)
                println(kw)
            end
            """) do i, binding
            @test JS.sourcetext(binding) == "kw"
            @test JS.source_line(binding) == 1
            cnt += 1
        end
        @test cnt == 2
    end

    # Don't select a binding for keyword argument within `kwcall`
    let cnt = 0
        local binfo = nothing
        _with_target_binding("""
            function func(x; │kw│=nothing)
                println(│kw│)
            end
            """) do i, (; ctx3, binding)
            if i in (1, 2)
                @test JS.sourcetext(binding) == "kw"
                @test JS.source_line(binding) == 1
                binfo = JL.get_binding(ctx3, binding)
            else
                @test JS.sourcetext(binding) == "kw"
                @test JS.source_line(binding) == 2
                @test JL.get_binding(ctx3, binding).id == binfo.id
            end
            cnt += 1
        end
        @test cnt == 4
    end

    # Perform analysis on a `block` unit containing `local`
    let cnt = 0
        local binfo = nothing
        _with_target_binding("""
            begin
                local │xxx│ = 42
                getxxx() = │xxx│
            end
            """) do i, (; ctx3, binding)
            if i in (1, 2)
                @test JS.sourcetext(binding) == "xxx"
                @test JS.source_line(binding) == 2
                binfo = JL.get_binding(ctx3, binding)
            else
                @test JS.sourcetext(binding) == "xxx"
                @test JS.source_line(binding) == 3
                @test JL.get_binding(ctx3, binding).id == binfo.id
            end
            cnt += 1
        end
        @test cnt == 4
    end

    # Macrocall name binding
    let cnt = 0
        _with_target_binding("""
            │@info│ "hello"
            """) do i, (; ctx3, binding)
            binfo = JL.get_binding(ctx3, binding)
            @test binfo.kind === :global
            @test binfo.name == "@info"
            cnt += 1
        end
        @test cnt == 2
    end

    # Qualified macrocall: cursor at module name returns module binding
    let cnt = 0
        _with_target_binding("""
            │Bas│e.@info "hello"
            """) do _, (; ctx3, binding)
            binfo = JL.get_binding(ctx3, binding)
            @test binfo.kind === :global
            @test binfo.name == "Base"
            cnt += 1
        end
        @test cnt == 2
    end

    # Qualified macrocall: cursor at end of macro name returns nothing
    let cnt = 0
        with_target_binding("""
            Base.@info│ "hello"
            """) do _, binding
            @test binding === nothing
            cnt += 1
        end
        @test cnt == 1
    end
end

function with_target_binding_definitions(f, text::AbstractString; kwargs...)
    clean_code, positions = JETLS.get_text_and_positions(text; kwargs...)
    st0_top = jlparse(clean_code)
    for (i, pos) in enumerate(positions)
        offset = JETLS.xy_to_offset(clean_code, pos, @__FILE__)
        f(i, JETLS.select_target_binding_definitions(st0_top, offset, lowering_module))
    end
end

@testset "`select_target_binding_definitions" begin
    with_target_binding_definitions("""
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
    end

    @testset "simple" begin
        cnt = 0
        with_target_binding_definitions("""
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
                cnt += 1
            elseif i == 2 # y│
                @test !isnothing(res)
                binding, defs = res
                @test JS.source_line(JS.sourceref(binding)) == 3
                @test length(defs) == 1
                @test JS.source_line(JS.sourceref(only(defs))) == 2
                cnt += 1
            end
        end
        @test cnt == 2
    end

    @testset "parameter shadowing" begin
        cnt = 0
        with_target_binding_definitions("""
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
                cnt += 1
            elseif i == 2 # y│
                @test !isnothing(res)
                binding, defs = res
                @test JS.source_line(JS.sourceref(binding)) == 4
                @test length(defs) == 1
                @test JS.source_line(JS.sourceref(only(defs))) == 3
                cnt += 1
            end
        end
        @test cnt == 2
    end

    @testset "function self-reference" begin
        cnt = 0
        with_target_binding_definitions("""
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
            cnt += 1
        end
        @test cnt == 1
    end

    @testset "static parameter" begin
        cnt = 0
        with_target_binding_definitions("""
            function func(::TTT) where TTT<:Integer
                return TTT│
            end
        """) do _, res
            @test !isnothing(res)
            binding, defs = res
            @test JS.source_line(JS.sourceref(binding)) == 2
            @test length(defs) == 1
            @test JS.source_line(JS.sourceref(only(defs))) == 1
            cnt += 1
        end
        @test cnt == 1
    end

    @testset "closure captures" begin
        cnt = 0
        with_target_binding_definitions("""
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
                cnt += 1
            elseif i == 2 # y│
                @test !isnothing(res)
                binding, defs = res
                @test JS.source_line(JS.sourceref(binding)) == 4
                @test length(defs) == 1
                @test JS.source_line(JS.sourceref(only(defs))) == 3
                cnt += 1
            end
        end
        @test cnt == 2
    end

    @testset "let binding" begin
        cnt = 0
        with_target_binding_definitions("""
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
                cnt += 1
            elseif i == 2 # y│
                @test !isnothing(res)
                binding, defs = res
                @test JS.source_line(JS.sourceref(binding)) == 4
                @test length(defs) == 1
                @test JS.source_line(JS.sourceref(only(defs))) == 3
                cnt += 1
            end
        end
        @test cnt == 2
    end

    @testset "for loop variable" begin
        cnt = 0
        with_target_binding_definitions("""
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
            cnt += 1
        end
        @test cnt == 1
    end

    @testset "comprehension variable" begin
        cnt = 0
        with_target_binding_definitions("""
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
            cnt += 1
        end
        @test cnt == 1
    end

    @testset "destructuring assignment" begin
        cnt = 0
        with_target_binding_definitions("""
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
                cnt += 1
            elseif i == 2 # b│
                @test !isnothing(res)
                binding, defs = res
                @test JS.source_line(JS.sourceref(binding)) == 3
                @test length(defs) == 1
                @test JS.source_line(JS.sourceref(only(defs))) == 2
                cnt += 1
            end
        end
        @test cnt == 2
    end

    @testset "conditional binding" begin
        cnt = 0
        with_target_binding_definitions("""
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
            cnt += 1
        end
        @test cnt == 1
    end

    @testset "try-catch variable" begin
        cnt = 0
        with_target_binding_definitions("""
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
            cnt += 1
        end
        @test cnt == 1
    end

    @testset "do block parameter" begin
        cnt = 0
        with_target_binding_definitions("""
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
            cnt += 1
        end
        @test cnt == 1
    end

    @testset "lambda parameter" begin
        cnt = 0
        with_target_binding_definitions("""
            sq = x -> x│ ^ 2
        """) do _, res
            @test !isnothing(res)
            binding, defs = res
            @test JS.source_line(JS.sourceref(binding)) == 1
            @test length(defs) == 1
            @test JS.source_line(JS.sourceref(only(defs))) == 1
            cnt += 1
        end
        @test cnt == 1
    end

    @testset "nested let scopes" begin
        cnt = 0
        with_target_binding_definitions("""
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
            cnt += 1
        end
        @test cnt == 1
    end

    @testset "for loop shadowing" begin
        cnt = 0
        with_target_binding_definitions("""
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
            cnt += 1
        end
        @test cnt == 1
    end

    @testset "closure recapture" begin
        cnt = 0
        with_target_binding_definitions("""
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
            cnt += 1
        end
        @test cnt == 1
    end

    @testset "keyword arguments" begin
        cnt = 0
        with_target_binding_definitions("""
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
                cnt += 1
            elseif i == 2 # b│
                @test !isnothing(res)
                binding, defs = res
                @test JS.source_line(JS.sourceref(binding)) == 2
                @test length(defs) == 1
                @test JS.source_line(JS.sourceref(only(defs))) == 1
                cnt += 1
            end
        end
        @test cnt == 2
    end

    @testset "inner function parameter shadowing" begin
        cnt = 0
        with_target_binding_definitions("""
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
            cnt += 1
        end
        @test cnt == 1
    end

    @testset "non-linear control flow" begin
        cnt = 0
        with_target_binding_definitions("""
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
            cnt += 1
        end
        @test cnt == 1
    end

    @testset "undefined variable" begin
        cnt = 0
        with_target_binding_definitions("""
            function undefined_var()
                return x│
            end
        """) do _, res
            @test isnothing(res)
            cnt += 1
        end
        @test cnt == 1
    end
end

end # module test_binding
