module test_occurrence_analysis

using Test
using JETLS: JETLS
using JETLS.LSP
using JETLS.LSP.URIs2

include(normpath(pkgdir(JETLS), "test", "jsjl-utils.jl"))

global lowering_module::Module = Module()

with_binding_occurrences(callback, code::AbstractString; kwargs...) =
    with_binding_occurrences(callback, lowering_module, code; kwargs...)
function with_binding_occurrences(callback, mod::Module, code::AbstractString;
                                  ismacro_callback = nothing,
                                  remove_macrocalls::Bool = false)
    st0 = jlparse(code; rule=:statement)
    if remove_macrocalls
        st0 = JETLS.remove_macrocalls(st0)
    end
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

    @testset "remove_macrocalls" begin
        with_binding_occurrences("func(@nospecialize args) = typeof(args)"; remove_macrocalls=true) do binding_occurrences
            @test any(binding_occurrences) do (binding, occurrences)
                binding.name == "args" && binding.kind === :argument && any(o->o.kind===:use, occurrences)
            end
        end
        with_binding_occurrences("(@main)(args::Vector{String}) = println(args)"; remove_macrocalls=true) do binding_occurrences
            @test any(binding_occurrences) do (binding, occurrences)
                binding.name == "args" && binding.kind === :argument && any(o->o.kind===:use, occurrences)
            end
        end
        with_binding_occurrences("""
            function @main(args::Vector{String})
                println(args)
            end
            """; remove_macrocalls=true) do binding_occurrences
            @test any(binding_occurrences) do (binding, occurrences)
                binding.name == "args" && binding.kind === :argument && any(o->o.kind===:use, occurrences)
            end
        end
    end
end

function get_binding_occurrences_st0(text::AbstractString;
        filename::String = joinpath(@__DIR__, "testfile.jl"), kwargs...)
    fi = JETLS.FileInfo(#=version=#0, text, filename)
    st0 = jlparse(text; rule=:statement)
    uri = filename2uri(filename)
    state = JETLS.ServerState()
    return JETLS.compute_binding_occurrences_st0(state, uri, fi, st0;
        lookup_func = Returns(JETLS.OutOfScope(lowering_module)), kwargs...)
end

@testset "compute_binding_occurrences_st0" begin
    @testset "macro calls" begin
        let boccs = get_binding_occurrences_st0("@nospecialize"; include_global_bindings=true)
            @test length(boccs) == 1
            binfo, occs = only(boccs)
            @test binfo.name == "@nospecialize"
            @test length(occs) == 1
        end
        let boccs = get_binding_occurrences_st0("Base.@nospecialize"; include_global_bindings=true)
            @test length(boccs) == 1
            binfo, occs = only(boccs)
            @test binfo.name == "Base"
            @test length(occs) == 1
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

    @testset "macro calls" begin
        with_global_binding_occurrences("""
            macro │mymacro│(ex)
                esc(ex)
            end
            result = │@mymacro│ @noop 42
            """, "@mymacro") do ranges, positions
            @test length(positions) == 4
            @test length(ranges) == 2
            @test Range(; start=positions[1], var"end"=positions[2]) in ranges
            @test Range(; start=positions[3], var"end"=positions[4]) in ranges
        end
        with_global_binding_occurrences("""
            macro │mymacro│(ex)
                esc(ex)
            end
            result = @noop │@mymacro│ 42
            """, "@mymacro") do ranges, positions
            @test length(positions) == 4
            @test length(ranges) == 2
            @test Range(; start=positions[1], var"end"=positions[2]) in ranges
            @test Range(; start=positions[3], var"end"=positions[4]) in ranges
        end
        with_global_binding_occurrences("""
            macro │mymacro│(ex)
                esc(ex)
            end
            result = @noop @noop │@mymacro│ 42
            """, "@mymacro") do ranges, positions
            @test length(positions) == 4
            @test length(ranges) == 2
            @test Range(; start=positions[1], var"end"=positions[2]) in ranges
            @test Range(; start=positions[3], var"end"=positions[4]) in ranges
        end
        with_global_binding_occurrences("""
            macro │inner│(ex)
                esc(ex)
            end
            result = @noop │@inner│ @noop 42
            """, "@inner") do ranges, positions
            @test length(positions) == 4
            @test length(ranges) == 2
            @test Range(; start=positions[1], var"end"=positions[2]) in ranges
            @test Range(; start=positions[3], var"end"=positions[4]) in ranges
        end

        # Multiple macro calls at same level
        with_global_binding_occurrences("""
            macro │m│(ex)
                esc(ex)
            end
            result1 = │@m│ 1
            result2 = │@m│ 2
            result3 = │@m│ @noop │@m│ 3
            """, "@m") do ranges, positions
            @test length(positions) == 10
            @test length(ranges) == 5
        end
    end
end

end # module test_occurrence_analysis
