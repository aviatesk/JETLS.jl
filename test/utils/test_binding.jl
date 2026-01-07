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
        @test JS.source_line(JL.sourceref(binding)) == 2
        @test length(defs) == 1
        @test JS.source_line(JL.sourceref(only(defs))) == 3
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
                @test JS.source_line(JL.sourceref(binding)) == 2
                @test length(defs) == 1
                @test JS.source_line(JL.sourceref(only(defs))) == 1
                cnt += 1
            elseif i == 2 # y│
                @test !isnothing(res)
                binding, defs = res
                @test JS.source_line(JL.sourceref(binding)) == 3
                @test length(defs) == 1
                @test JS.source_line(JL.sourceref(only(defs))) == 2
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
                @test JS.source_line(JL.sourceref(binding)) == 3
                @test length(defs) == 2 # Both parameter x and local x = 1
                # The definitions should include both x = 1 on line 2 and the parameter x on line 1
                @test any(d -> JS.source_line(JL.sourceref(d)) == 1, defs) # parameter
                @test any(d -> JS.source_line(JL.sourceref(d)) == 2, defs) # local assignment
                cnt += 1
            elseif i == 2 # y│
                @test !isnothing(res)
                binding, defs = res
                @test JS.source_line(JL.sourceref(binding)) == 4
                @test length(defs) == 1
                @test JS.source_line(JL.sourceref(only(defs))) == 3
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
            @test JS.source_line(JL.sourceref(binding)) == 2
            @test length(defs) >= 1
            @test any(defs) do def
                JS.source_line(JL.sourceref(def)) == 1
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
            @test JS.source_line(JL.sourceref(binding)) == 2
            @test length(defs) == 1
            @test JS.source_line(JL.sourceref(only(defs))) == 1
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
                @test JS.source_line(JL.sourceref(binding)) == 4
                @test length(defs) == 1
                @test JS.source_line(JL.sourceref(only(defs))) == 2
                cnt += 1
            elseif i == 2 # y│
                @test !isnothing(res)
                binding, defs = res
                @test JS.source_line(JL.sourceref(binding)) == 4
                @test length(defs) == 1
                @test JS.source_line(JL.sourceref(only(defs))) == 3
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
                @test JS.source_line(JL.sourceref(binding)) == 3
                @test length(defs) == 1
                @test JS.source_line(JL.sourceref(only(defs))) == 2
                cnt += 1
            elseif i == 2 # y│
                @test !isnothing(res)
                binding, defs = res
                @test JS.source_line(JL.sourceref(binding)) == 4
                @test length(defs) == 1
                @test JS.source_line(JL.sourceref(only(defs))) == 3
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
            @test JS.source_line(JL.sourceref(binding)) == 3
            @test length(defs) == 1
            @test JS.source_line(JL.sourceref(only(defs))) == 2
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
            @test JS.source_line(JL.sourceref(binding)) == 2
            @test length(defs) == 1
            @test JS.source_line(JL.sourceref(only(defs))) == 2
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
                @test JS.source_line(JL.sourceref(binding)) == 3
                @test length(defs) == 1
                @test JS.source_line(JL.sourceref(only(defs))) == 2
                cnt += 1
            elseif i == 2 # b│
                @test !isnothing(res)
                binding, defs = res
                @test JS.source_line(JL.sourceref(binding)) == 3
                @test length(defs) == 1
                @test JS.source_line(JL.sourceref(only(defs))) == 2
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
            @test JS.source_line(JL.sourceref(binding)) == 5
            @test length(defs) == 1
            @test JS.source_line(JL.sourceref(only(defs))) == 3
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
            @test JS.source_line(JL.sourceref(binding)) == 5
            @test length(defs) == 1
            @test JS.source_line(JL.sourceref(only(defs))) == 4
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
            @test JS.source_line(JL.sourceref(binding)) == 3
            @test length(defs) == 1
            @test JS.source_line(JL.sourceref(only(defs))) == 2
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
            @test JS.source_line(JL.sourceref(binding)) == 1
            @test length(defs) == 1
            @test JS.source_line(JL.sourceref(only(defs))) == 1
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
            @test JS.source_line(JL.sourceref(binding)) == 4
            @test length(defs) == 1
            @test JS.source_line(JL.sourceref(only(defs))) == 3
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
            @test JS.source_line(JL.sourceref(binding)) == 4
            @test length(defs) == 1
            @test JS.source_line(JL.sourceref(only(defs))) == 3
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
            @test JS.source_line(JL.sourceref(binding)) == 3
            @test length(defs) == 2
            @test any(def -> JS.source_line(JL.sourceref(def)) == 2, defs)
            @test any(def -> JS.source_line(JL.sourceref(def)) == 4, defs)
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
                @test JS.source_line(JL.sourceref(binding)) == 2
                @test length(defs) == 1
                @test JS.source_line(JL.sourceref(only(defs))) == 1
                cnt += 1
            elseif i == 2 # b│
                @test !isnothing(res)
                binding, defs = res
                @test JS.source_line(JL.sourceref(binding)) == 2
                @test length(defs) == 1
                @test JS.source_line(JL.sourceref(only(defs))) == 1
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
            @test JS.source_line(JL.sourceref(binding)) == 4
            @test length(defs) == 1
            @test JS.source_line(JL.sourceref(only(defs))) == 3
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
            @test JS.source_line(JL.sourceref(binding)) == 5
            @test length(defs) == 1
            @test JS.source_line(JL.sourceref(only(defs))) == 7
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

with_binding_occurrences(callback, code::AbstractString; kwargs...) =
    with_binding_occurrences(callback, lowering_module, code; kwargs...)
function with_binding_occurrences(callback, mod::Module, code::AbstractString;
                                  ismacro_callback = nothing)
    st0 = jlparse(code; rule=:statement)
    (; ctx3, st3) = JETLS.jl_lower_for_scope_resolution(mod, st0)
    ismacro = isnothing(ismacro_callback) ? nothing : Ref(false)
    binding_occurrences = JETLS.compute_binding_occurrences(ctx3, st3; ismacro)
    if !isnothing(ismacro_callback)
        ismacro_callback(ismacro)
    end
    callback(binding_occurrences)
end
nomacro_callback(ismacro) = @test !ismacro[]
ismacro_callback(ismacro) = @test ismacro[]

@testset "compute_binding_occurrences" begin
    with_binding_occurrences("""
        function func(x, y, z)
            local w
            println(x)
            return y
        end
        """; ismacro_callback = nomacro_callback) do binding_occurrences
        binfos = collect(keys(binding_occurrences))
        @test length(binfos) == 4
        let i = @something findfirst(binfo->binfo.name=="x", binfos)
            occurrences = binding_occurrences[binfos[i]]
            @test length(occurrences) == 2
            @test count(occurrences) do occurrence
                occurrence.kind === :def &&
                JS.sourcetext(occurrence.tree) == "x" &&
                JS.source_line(occurrence.tree) == 1
            end == 1
            @test count(occurrences) do occurrence
                occurrence.kind === :use &&
                JS.sourcetext(occurrence.tree) == "x" &&
                JS.source_line(occurrence.tree) == 3
            end == 1
        end
        let i = @something findfirst(binfo->binfo.name=="y", binfos)
            occurrences = binding_occurrences[binfos[i]]
            @test length(occurrences) == 2
            @test count(occurrences) do occurrence
                occurrence.kind === :def &&
                JS.sourcetext(occurrence.tree) == "y" &&
                JS.source_line(occurrence.tree) == 1
            end == 1
            @test count(occurrences) do occurrence
                occurrence.kind === :use &&
                JS.sourcetext(occurrence.tree) == "y" &&
                JS.source_line(occurrence.tree) == 4
            end == 1
        end
        let i = @something findfirst(binfo->binfo.name=="z", binfos)
            occurrences = binding_occurrences[binfos[i]]
            @test length(occurrences) == 1
            @test count(occurrences) do occurrence
                occurrence.kind === :def &&
                JS.sourcetext(occurrence.tree) == "z" &&
                JS.source_line(occurrence.tree) == 1
            end == 1
        end
        let i = @something findfirst(binfo->binfo.name=="w", binfos)
            occurrences = binding_occurrences[binfos[i]]
            @test length(occurrences) == 1
            @test count(occurrences) do occurrence
                occurrence.kind === :decl &&
                JS.sourcetext(occurrence.tree) == "w" &&
                JS.source_line(occurrence.tree) == 2
            end == 1
        end
    end

    with_binding_occurrences("""
        macro m(x, y)
            return Expr(:block, __source__, esc(x))
        end
        """; ismacro_callback = ismacro_callback) do binding_occurrences
        binfos = collect(keys(binding_occurrences))
        @test length(binfos) == 4
        let i = @something findfirst(binfo->binfo.name=="x", binfos)
            occurrences = binding_occurrences[binfos[i]]
            @test length(occurrences) == 2
            @test count(occurrences) do occurrence
                occurrence.kind === :def &&
                JS.sourcetext(occurrence.tree) == "x" &&
                JS.source_line(occurrence.tree) == 1
            end == 1
            @test count(occurrences) do occurrence
                occurrence.kind === :use &&
                JS.sourcetext(occurrence.tree) == "x" &&
                JS.source_line(occurrence.tree) == 2
            end == 1
        end
        let i = @something findfirst(binfo->binfo.name=="y", binfos)
            occurrences = binding_occurrences[binfos[i]]
            @test length(occurrences) == 1
            @test count(occurrences) do occurrence
                occurrence.kind === :def &&
                JS.sourcetext(occurrence.tree) == "y" &&
                JS.source_line(occurrence.tree) == 1
            end == 1
        end
        let i = @something findfirst(binfo->binfo.name=="__source__", binfos)
            occurrences = binding_occurrences[binfos[i]]
            @test length(occurrences) == 2
            @test count(occurrences) do occurrence
                occurrence.kind === :def &&
                JS.sourcetext(occurrence.tree) == "m(x, y)" &&
                JS.source_line(occurrence.tree) == 1
            end == 1
            @test count(occurrences) do occurrence
                occurrence.kind === :use &&
                JS.sourcetext(occurrence.tree) == "__source__" &&
                JS.source_line(occurrence.tree) == 2
            end == 1
        end
        let i = @something findfirst(binfo->binfo.name=="__module__", binfos)
            occurrences = binding_occurrences[binfos[i]]
            @test length(occurrences) == 1
            @test count(occurrences) do occurrence
                occurrence.kind === :def &&
                JS.sourcetext(occurrence.tree) == "m(x, y)" &&
                JS.source_line(occurrence.tree) == 1
            end == 1
        end
    end

    @testset "static parameter occurrences" begin
        with_binding_occurrences("""
            function func1(::TTT1) where TTT1<:Integer
                return zero(TTT1)
            end
            """; ismacro_callback = nomacro_callback) do binding_occurrences
            binfos = collect(keys(binding_occurrences))
            # there are two different bindings representing the `TTT1`, one for defineing the
            # signature type and the other for static parameter binding within the method body
            @test length(binfos) == 2
            idxs = findall(binfo->binfo.name=="TTT1", binfos)
            @test length(idxs) == 2
            @test binding_occurrences[binfos[idxs[1]]] === binding_occurrences[binfos[idxs[2]]]
            occurrences = binding_occurrences[binfos[idxs[1]]]
            @test any(occurrences) do occurrence
                occurrence.kind === :use &&
                JS.sourcetext(occurrence.tree) == "TTT1" &&
                JS.source_line(occurrence.tree) == 2
            end
        end

        code1 = """
        function func2(::TTT1, ::TTT2) where TTT1<:Integer where TTT2<:Integer
            return zero(TTT1), zero(TTT2)
        end
        """
        code2 = """
        function func2(::TTT1, ::TTT2) where {TTT1<:Integer, TTT2<:Integer}
            return zero(TTT1), zero(TTT2)
        end
        """
        for code in (code1, code2)
            with_binding_occurrences(code; ismacro_callback = nomacro_callback) do binding_occurrences
                binfos = collect(keys(binding_occurrences))
                # there are two different bindings representing each for `TTT1` and `TTT2`,
                # one for defineing the signature type and the other for static parameter binding within the method body
                @test length(binfos) == 4
                let idxs = findall(binfo->binfo.name=="TTT1", binfos)
                    @test length(idxs) == 2
                    @test binding_occurrences[binfos[idxs[1]]] === binding_occurrences[binfos[idxs[2]]]
                    occurrences = binding_occurrences[binfos[idxs[1]]]
                    @test any(occurrences) do occurrence
                        occurrence.kind === :use &&
                        JS.sourcetext(occurrence.tree) == "TTT1" &&
                        JS.source_line(occurrence.tree) == 2
                    end
                end
                let idxs = findall(binfo->binfo.name=="TTT2", binfos)
                    @test length(idxs) == 2
                    @test binding_occurrences[binfos[idxs[1]]] === binding_occurrences[binfos[idxs[2]]]
                    occurrences = binding_occurrences[binfos[idxs[1]]]
                    @test any(occurrences) do occurrence
                        occurrence.kind === :use &&
                        JS.sourcetext(occurrence.tree) == "TTT2" &&
                        JS.source_line(occurrence.tree) == 2
                    end
                end
            end
        end
    end

    @testset "occurrences of local bindings with the same name" begin
        with_binding_occurrences("""
            let xxx = rand()
                if xxx > 0
                    let xxx = xxx
                        # println(xxx)
                    end
                end
                println(xxx)
            end
            """; ismacro_callback = nomacro_callback) do binding_occurrences
            binfos = collect(keys(binding_occurrences))
            idxs = findall(binfo->binfo.name=="xxx", binfos)
            @test length(idxs) == 2
            @test binding_occurrences[binfos[idxs[1]]] !== binding_occurrences[binfos[idxs[2]]]
            @test count(idxs) do idx
                occurrences = binding_occurrences[binfos[idx]]
                any(occurrences) do occurrence
                    occurrence.kind === :use &&
                    JS.source_line(occurrence.tree) == 7
                end
            end == 1
            @test count(idxs) do idx
                occurrences = binding_occurrences[binfos[idx]]
                all(occurrences) do occurrence
                    occurrence.kind !== :use
                end
            end == 1
        end
    end

    @testset "with return type annotation" begin
        with_binding_occurrences("""
            function func(xxx::TTT)::Float64 where TTT<:Integer
                return sin(xxx)
            end
            """; ismacro_callback = nomacro_callback) do binding_occurrences
            binfos = collect(keys(binding_occurrences))
            idx = only(findall(binfo->binfo.name=="xxx", binfos))
            occurrences = binding_occurrences[binfos[idx]]
            @test any(occurrences) do occurrence
                occurrence.kind === :use &&
                JS.sourcetext(occurrence.tree) == "xxx" &&
                JS.source_line(occurrence.tree) == 2
            end
        end
    end

    @testset "keyword arguments" begin
        with_binding_occurrences("func(a; kw) = kw"; ismacro_callback = nomacro_callback) do binding_occurrences
            @test !any(binding_occurrences) do (binding, occurrences)
                binding.name == "a" && binding.kind === :argument && any(o->o.kind===:use, occurrences)
            end
            @test any(binding_occurrences) do (binding, occurrences)
                binding.name == "kw" && binding.kind === :argument && any(o->o.kind===:use, occurrences)
            end
        end
        with_binding_occurrences("func(a; kw) = a"; ismacro_callback = nomacro_callback) do binding_occurrences
            @test any(binding_occurrences) do (binding, occurrences)
                binding.name == "a" && binding.kind === :argument && any(o->o.kind===:use, occurrences)
            end
            @test !any(binding_occurrences) do (binding, occurrences)
                binding.name == "kw" && binding.kind === :argument && any(o->o.kind===:use, occurrences)
            end
        end
        with_binding_occurrences("func(a; kw) = nothing"; ismacro_callback = nomacro_callback) do binding_occurrences
            @test !any(binding_occurrences) do (binding, occurrences)
                binding.name == "a" && binding.kind === :argument && any(o->o.kind===:use, occurrences)
            end
            @test !any(binding_occurrences) do (binding, occurrences)
                binding.name == "kw" && binding.kind === :argument && any(o->o.kind===:use, occurrences)
            end
        end
    end
end

function with_global_binding_occurrences(
        f, text::AbstractString, target_name::String;
        filename::String = joinpath(@__DIR__, "testfile.jl"))
    clean_code, positions = JETLS.get_text_and_positions(text)
    fi = JETLS.FileInfo(#=version=#0, clean_code, filename)
    st0_top = jlparse(clean_code)
    furi = filename2uri(filename)
    state = JETLS.ServerState()

    @test issorted(positions; by = x -> JETLS.xy_to_offset(fi, x))

    pos = first(positions)
    offset = JETLS.xy_to_offset(clean_code, pos, filename)
    (; ctx3, binding) = @something(
        JETLS._select_target_binding(st0_top, offset, lowering_module),
        error("No binding found at cursor position"))
    target_binfo = JL.get_binding(ctx3, binding)
    @test target_binfo.kind === :global
    @test target_binfo.name == target_name

    occurrences = JETLS.find_global_binding_occurrences!(
        state, furi, fi, st0_top, target_binfo;
        lookup_func = Returns(JETLS.OutOfScope(lowering_module)))

    ranges = Set{Range}()
    for occ in occurrences
        push!(ranges, JETLS.jsobj_to_range(occ.tree, fi))
    end
    f(ranges, positions)
end

macro noop(ex) esc(ex) end

@testset "find_global_binding_occurrences!" begin
    @testset "function definitions and calls" begin
        with_global_binding_occurrences("""
            │foo│() = 42
            bar() = │foo│()
            │foo│(x) = x + 1
            """, "foo") do ranges, positions
            @test length(positions) == 6
            @test length(ranges) == 3
            @test Range(; start=positions[1], var"end"=positions[2]) in ranges
            @test Range(; start=positions[3], var"end"=positions[4]) in ranges
            @test Range(; start=positions[5], var"end"=positions[6]) in ranges
        end
    end

    @testset "global constant" begin
        with_global_binding_occurrences("""
            global │MY_CONST│ = 100
            use_const() = │MY_CONST│ * 2
            another_use() = │MY_CONST│ + 1
            """, "MY_CONST") do ranges, positions
            @test length(positions) == 6
            @test length(ranges) == 3
            @test Range(; start=positions[1], var"end"=positions[2]) in ranges
            @test Range(; start=positions[3], var"end"=positions[4]) in ranges
            @test Range(; start=positions[5], var"end"=positions[6]) in ranges
        end
    end

    @testset "struct type" begin
        with_global_binding_occurrences("""
            struct │MyType│
                x::Int
            end
            make_mytype() = │MyType│(42)
            """, "MyType") do ranges, positions
            @test length(positions) == 4
            @test length(ranges) == 2
            @test Range(; start=positions[1], var"end"=positions[2]) in ranges
            @test Range(; start=positions[3], var"end"=positions[4]) in ranges
        end
    end

    @testset "multiple toplevel expressions" begin
        with_global_binding_occurrences("""
            const │global_var│ = 1

            function use_global()
                return │global_var│
            end

            function modify_global()
                global │global_var│ = 2
            end
            """, "global_var") do ranges, positions
            @test length(positions) == 6
            @test length(ranges) == 3
            @test Range(; start=positions[1], var"end"=positions[2]) in ranges
            @test Range(; start=positions[3], var"end"=positions[4]) in ranges
            @test Range(; start=positions[5], var"end"=positions[6]) in ranges
        end
    end

    @testset "within macro calls" begin
        with_global_binding_occurrences("""
            │foo│() = 42
            bar() = @noop │foo│()
            """, "foo") do ranges, positions
            @test length(positions) == 4
            @test length(ranges) == 2
            @test Range(; start=positions[1], var"end"=positions[2]) in ranges
            @test Range(; start=positions[3], var"end"=positions[4]) in ranges
        end
    end
end

end # module test_binding
