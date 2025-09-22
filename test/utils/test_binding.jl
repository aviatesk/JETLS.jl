module test_binding

using Test
using JETLS: JETLS

include(normpath(pkgdir(JETLS), "test", "jsjl_utils.jl"))

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
                binfo = JL.lookup_binding(ctx3, binding)
            else
                @test JS.sourcetext(binding) == "kw"
                @test JS.source_line(binding) == 2
                @test JL.lookup_binding(ctx3, binding).id == binfo.id
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
                binfo = JL.lookup_binding(ctx3, binding)
            else
                @test JS.sourcetext(binding) == "xxx"
                @test JS.source_line(binding) == 3
                @test JL.lookup_binding(ctx3, binding).id == binfo.id
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
end

end # module test_binding
