module test_occurrence_analysis

using Test
using JETLS: JETLS
using JETLS.LSP
using JETLS.LSP.URIs2

include(normpath(pkgdir(JETLS), "test", "jsjl-utils.jl"))

module lowering_module end

with_binding_occurrences(callback, code::AbstractString; kwargs...) =
    with_binding_occurrences(callback, lowering_module, code; kwargs...)
function with_binding_occurrences(callback, mod::Module, code::AbstractString;
                                  remove_macrocalls::Bool = false,
                                  is_generated::Bool = false)
    st0 = jlparse(code; rule=:statement)
    if remove_macrocalls
        st0 = JETLS.remove_macrocalls(st0)
    end
    (; ctx3, st3) = JETLS.jl_lower_for_scope_resolution(mod, st0)
    binding_occurrences = JETLS.compute_binding_occurrences(ctx3, st3, is_generated)
    callback(binding_occurrences)
end

@testset "compute_binding_occurrences" begin
    with_binding_occurrences("""
        function func(x, y, z)
            local w
            println(x)
            return y
        end
        """) do binding_occurrences
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
        """) do binding_occurrences
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
            """) do binding_occurrences
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
            with_binding_occurrences(code) do binding_occurrences
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
            """) do binding_occurrences
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
            """) do binding_occurrences
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
        with_binding_occurrences("func(a; kw) = kw") do binding_occurrences
            @test !any(binding_occurrences) do (binding, occurrences)
                binding.name == "a" && binding.kind === :argument && any(o->o.kind===:use, occurrences)
            end
            @test any(binding_occurrences) do (binding, occurrences)
                binding.name == "kw" && binding.kind === :argument && any(o->o.kind===:use, occurrences)
            end
        end
        with_binding_occurrences("func(a; kw) = a") do binding_occurrences
            @test any(binding_occurrences) do (binding, occurrences)
                binding.name == "a" && binding.kind === :argument && any(o->o.kind===:use, occurrences)
            end
            @test !any(binding_occurrences) do (binding, occurrences)
                binding.name == "kw" && binding.kind === :argument && any(o->o.kind===:use, occurrences)
            end
        end
        with_binding_occurrences("func(a; kw) = nothing") do binding_occurrences
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
        # Compound-assignment operators (`+=`, `-=`, ...) are parsed as
        # `K"unknown_head"` with a `name_val` attribute that JuliaLowering's
        # validator requires. `remove_macrocalls` must preserve `name_val` when
        # reconstructing the parent node, otherwise lowering fails.
        with_binding_occurrences("""
            function func()
                t = 0.0
                t += @elapsed sleep(0)
                return t
            end
            """; remove_macrocalls=true) do binding_occurrences
            @test any(binding_occurrences) do (binding, occurrences)
                binding.name == "t" && binding.kind === :local && any(o->o.kind===:use, occurrences)
            end
        end
        # `$` interpolations at macrocall-argument position are only legal
        # because the macro will typically splice the argument into a quote.
        # Once `remove_macrocalls` lifts the arguments into a bare `block`,
        # any surviving `$` would be out of context and fail lowering, so
        # the transform must unwrap interpolations on the lifted children.
        # Note: `@mymacro` does not need to exist — the macrocall is stripped
        # before `jl_lower_for_scope_resolution` runs.
        with_binding_occurrences("""
            function func()
                x = 10
                @mymacro foo = \$x
                return x
            end
            """; remove_macrocalls=true) do binding_occurrences
            @test any(binding_occurrences) do (binding, occurrences)
                binding.name == "x" && binding.kind === :local && any(o->o.kind===:use, occurrences)
            end
        end
        # `` `...` `` parses to `Core.@cmd(LineNumberNode, CmdString)` whose
        # `CmdString` leaf has no JuliaLowering rule. `is_cmd0` lets the macro
        # expand instead of stripping, so names interpolated with `\$` end up
        # as `:use` occurrences. Their source provenance collapses to 0:0 but
        # usedness tracking is correct.
        with_binding_occurrences("""
            function func(x)
                y = 2
                `echo \$x --v=\$(y+1) bar`
            end
            """; remove_macrocalls=true) do binding_occurrences
            binfos = collect(keys(binding_occurrences))
            let i = @something findfirst(b->b.name=="x" && b.kind===:argument, binfos)
                occurrences = collect(binding_occurrences[binfos[i]])
                x_use = findfirst(o->o.kind===:use, occurrences)
                @test !isnothing(x_use)
                # Old-style `@cmd` expansion collapses source provenance of
                # interpolated uses to byte-range 0:0, which breaks
                # source-position based features (rename/references). A proper
                # fix needs upstream parser/lowering support for cmd-literal
                # interpolations.
                @test_broken JS.first_byte(occurrences[x_use].tree) > 0
            end
            let i = @something findfirst(b->b.name=="y" && b.kind===:local, binfos)
                occurrences = collect(binding_occurrences[binfos[i]])
                y_use = findfirst(o->o.kind===:use, occurrences)
                @test !isnothing(y_use)
                @test_broken JS.first_byte(occurrences[y_use].tree) > 0
            end
        end
    end

    # aviatesk/JETLS.jl#480
    @testset "is_generated" begin
        with_binding_occurrences("""
            @generated function replicate(rng::T) where {T}
                hasmethod(copy, (T,)) && return :(copy(rng))
                return :(deepcopy(rng))
            end
            """; is_generated=true) do binding_occurrences
            @test any(binding_occurrences) do (binding, occurrences)
                binding.name == "rng" && binding.kind === :argument &&
                any(occurrences) do o
                    o.kind === :use && JS.sourcetext(o.tree) == "rng"
                end
            end
        end

        with_binding_occurrences("""
            @generated function foo(x, unused)
                return :(x + 1)
            end
            """; is_generated=true) do binding_occurrences
            @test any(binding_occurrences) do (binding, occurrences)
                binding.name == "x" && binding.kind === :argument &&
                any(o -> o.kind === :use, occurrences)
            end
            @test !any(binding_occurrences) do (binding, occurrences)
                binding.name == "unused" && binding.kind === :argument &&
                any(o -> o.kind === :use, occurrences)
            end
        end
    end
end

function get_binding_occurrences_st0(text::AbstractString;
        filename::String = joinpath(@__DIR__, "testfile.jl"),
        include_global_bindings::Bool = true, kwargs...)
    fi = JETLS.FileInfo(#=version=#0, text, filename)
    st0 = jlparse(text; rule=:statement)
    uri = filename2uri(filename)
    state = JETLS.ServerState()
    return JETLS.compute_binding_occurrences_st0(state, uri, fi, st0;
        lookup_func = Returns(JETLS.OutOfScope(lowering_module)),
        include_global_bindings, kwargs...)
end

@testset "compute_binding_occurrences_st0" begin
    @testset "macro calls" begin
        let boccs = get_binding_occurrences_st0("@nospecialize")
            @test length(boccs) == 1
            binfo, occs = only(boccs)
            @test binfo.name == "@nospecialize"
            @test length(occs) == 1
        end
        let boccs = get_binding_occurrences_st0("Base.@nospecialize")
            @test length(boccs) == 1
            binfo, occs = only(boccs)
            @test binfo.name == "Base"
            @test length(occs) == 1
        end
    end

    @testset "export/public" begin
        let boccs = get_binding_occurrences_st0("export foo, @bar, baz")
            @test length(boccs) == 3
            for name in ("foo", "@bar", "baz")
                i = @something findfirst(((b, _),) -> b.name == name, collect(boccs))
                binfo, occs = collect(boccs)[i]
                @test binfo.kind === :global
                @test length(occs) == 1
                @test only(occs).kind === :use
            end
        end
        let boccs = get_binding_occurrences_st0("public qux")
            @test length(boccs) == 1
            binfo, occs = only(boccs)
            @test binfo.name == "qux"
            @test binfo.kind === :global
            @test only(occs).kind === :use
        end
        # Without `include_global_bindings`, export/public yields no occurrences
        let boccs = get_binding_occurrences_st0("export foo";
                                                include_global_bindings=false)
            @test boccs !== nothing && isempty(boccs)
        end
    end

    @testset "import/using" begin
        # `using M: a, b` / `import M: a, b` — each name as `:decl`
        for keyword in ("using", "import")
            let boccs = get_binding_occurrences_st0("$keyword Base: foo, bar")
                @test length(boccs) == 2
                for name in ("foo", "bar")
                    i = @something findfirst(((b, _),) -> b.name == name, collect(boccs))
                    binfo, occs = collect(boccs)[i]
                    @test binfo.kind === :global
                    @test length(occs) == 1
                    @test only(occs).kind === :decl
                end
            end
        end
        # `using M: a as b` — the alias is the local binding
        let boccs = get_binding_occurrences_st0("using Base: foo as bar")
            @test length(boccs) == 1
            binfo, occs = only(boccs)
            @test binfo.name == "bar"
            @test only(occs).kind === :decl
        end
        # `import M.a` — last component is the local binding
        let boccs = get_binding_occurrences_st0("import Base.foo")
            @test length(boccs) == 1
            binfo, occs = only(boccs)
            @test binfo.name == "foo"
            @test only(occs).kind === :decl
        end
        # `using M` / `import M` — the module name is the local binding
        for keyword in ("using", "import")
            let boccs = get_binding_occurrences_st0("$keyword Base")
                @test length(boccs) == 1
                binfo, occs = only(boccs)
                @test binfo.name == "Base"
                @test only(occs).kind === :decl
            end
        end
        # `using A, B` — each module name
        let boccs = get_binding_occurrences_st0("using Base, LinearAlgebra")
            @test length(boccs) == 2
            for name in ("Base", "LinearAlgebra")
                i = @something findfirst(((b, _),) -> b.name == name, collect(boccs))
                binfo, occs = collect(boccs)[i]
                @test only(occs).kind === :decl
            end
        end
        # `using M.a` / `import M.a` — trailing component is the local binding
        for keyword in ("using", "import")
            let boccs = get_binding_occurrences_st0("$keyword Base.Iterators")
                @test length(boccs) == 1
                binfo, occs = only(boccs)
                @test binfo.name == "Iterators"
                @test only(occs).kind === :decl
            end
        end
        # Relative: `using .A` / `import ..A.B` — trailing component
        let boccs = get_binding_occurrences_st0("using .Inner")
            @test length(boccs) == 1
            binfo, occs = only(boccs)
            @test binfo.name == "Inner"
            @test only(occs).kind === :decl
        end
    end

    @testset "local declaration" begin
        only_locals(boccs) = filter(((b, _),) -> b.kind === :local, collect(boccs))
        # `local x = 1` inside a function — `x` gets `:decl` and `:def`.
        let locals = only_locals(get_binding_occurrences_st0(
                "function f(); local x = 1; end"))
            @test length(locals) == 1
            binfo, occs = only(locals)
            @test binfo.name == "x"
            @test count(o -> o.kind === :decl, occs) == 1
            @test count(o -> o.kind === :def, occs) == 1
        end
        # `local x, y` — each name recorded as `:decl` (plus `:def` from the
        # following assignment).
        let locals = only_locals(get_binding_occurrences_st0(
                "function f(); local x, y; x = 1; y = 2; end"))
            @test length(locals) == 2
            for name in ("x", "y")
                i = @something findfirst(((b, _),) -> b.name == name, locals)
                binfo, occs = locals[i]
                @test count(o -> o.kind === :decl, occs) == 1
                @test count(o -> o.kind === :def, occs) == 1
            end
        end
        # Bare `local x` followed by an assignment and a use.
        let locals = only_locals(get_binding_occurrences_st0(
                "function f(); local x; x = 1; x; end"))
            @test length(locals) == 1
            binfo, occs = only(locals)
            @test binfo.name == "x"
            @test count(o -> o.kind === :decl, occs) == 1
            @test count(o -> o.kind === :def, occs) == 1
            @test count(o -> o.kind === :use, occs) == 1
        end
        # `local` also works in a `let` block.
        let locals = only_locals(get_binding_occurrences_st0(
                "let; local x = 1; end"))
            @test length(locals) == 1
            binfo, occs = only(locals)
            @test binfo.name == "x"
            @test count(o -> o.kind === :decl, occs) == 1
            @test count(o -> o.kind === :def, occs) == 1
        end
    end

    @testset "global declaration" begin
        # `global x = 1` — the name is recorded as `:decl` (plus its `:def`).
        let boccs = get_binding_occurrences_st0("global x = 1")
            @test length(boccs) == 1
            binfo, occs = only(boccs)
            @test binfo.name == "x"
            @test binfo.kind === :global
            @test count(o -> o.kind === :decl, occs) == 1
            @test count(o -> o.kind === :def, occs) == 1
        end
        # `global x, y` — each name recorded as `:decl`.
        let boccs = get_binding_occurrences_st0("global x, y")
            @test length(boccs) == 2
            for name in ("x", "y")
                i = @something findfirst(((b, _),) -> b.name == name, collect(boccs))
                binfo, occs = collect(boccs)[i]
                @test binfo.kind === :global
                @test only(occs).kind === :decl
            end
        end
        # Bare `global x` — single `:decl` occurrence.
        let boccs = get_binding_occurrences_st0("global x")
            @test length(boccs) == 1
            binfo, occs = only(boccs)
            @test binfo.name == "x"
            @test binfo.kind === :global
            @test only(occs).kind === :decl
        end
        # Without `include_global_bindings`, `global` yields no occurrences
        # (no local/argument bindings to track).
        let boccs = get_binding_occurrences_st0("global x = 1";
                                                include_global_bindings=false)
            @test boccs !== nothing && isempty(boccs)
        end
    end

    # Inert (quoted) content inside `@generated` functions is processed via
    # `_unwrap_interpolations`, which must preserve `name_val` on ancestors of
    # interpolations (e.g. `K"unknown_head"` from compound assignments like `+=`)
    # so that lowering succeeds and global bindings inside the quote are recorded.
    @testset "inert content with compound assignment + interpolation" begin
        let boccs = get_binding_occurrences_st0("""
                @generated function f(x)
                    return quote
                        total = 0
                        sleep(0)
                        total += \$x
                        return total
                    end
                end
                """)
            @test boccs !== nothing
            # `sleep` is referenced only inside the inert block, so finding it
            # requires `_unwrap_interpolations` to succeed through the `+=` node.
            i = @something findfirst(((b, _),) -> b.name == "sleep", collect(boccs))
            binfo, occs = collect(boccs)[i]
            @test binfo.kind === :global
            @test any(o -> o.kind === :use, occs)
        end
    end

    # Code-generating macros splice their arguments into an implicit `quote`,
    # so argument-position `$` interpolations are valid in source. When
    # `remove_macrocalls` lifts those arguments into a bare `block`, the `$`
    # must be unwrapped — otherwise lowering fails for the whole enclosing
    # statement and any occurrences it contains are dropped.
    # Note: `@mymacro` does not need to exist — the macrocall is stripped
    # before `jl_lower_for_scope_resolution` runs.
    @testset "macrocall argument with interpolation" begin
        let boccs = get_binding_occurrences_st0("""
                let valid = MY_CONST
                    @mymacro something(::Type{Int}) = \$valid
                end
                """)
            @test boccs !== nothing
            # Without the interpolation fix in `_remove_macrocalls`, lowering
            # of this `let` fails because `\$valid` is left bare in a `block`
            # after the macrocall is stripped — and `MY_CONST` is never
            # recorded.
            i = @something findfirst(((b, _),) -> b.name == "MY_CONST", collect(boccs))
            binfo, occs = collect(boccs)[i]
            @test binfo.kind === :global
            @test any(o -> o.kind === :use, occs)
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

    @assert issorted(positions; by = x -> JETLS.xy_to_offset(fi, x))

    pos = first(positions)
    offset = JETLS.xy_to_offset(clean_code, pos, filename)
    (; ctx3, binding) = @something(
        JETLS.select_target_binding(st0_top, offset, lowering_module),
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

    @testset "import/using" begin
        with_global_binding_occurrences("""
            using Base: │foo│
            │foo│(1)
            """, "foo") do ranges, positions
            @test length(positions) == 4
            @test length(ranges) == 2
            @test Range(; start=positions[1], var"end"=positions[2]) in ranges
            @test Range(; start=positions[3], var"end"=positions[4]) in ranges
        end
        with_global_binding_occurrences("""
            using Base: foo as │bar│
            │bar│(1)
            """, "bar") do ranges, positions
            @test length(positions) == 4
            @test length(ranges) == 2
            @test Range(; start=positions[1], var"end"=positions[2]) in ranges
            @test Range(; start=positions[3], var"end"=positions[4]) in ranges
        end
        with_global_binding_occurrences("""
            import Base.│foo│
            │foo│(1)
            """, "foo") do ranges, positions
            @test length(positions) == 4
            @test length(ranges) == 2
            @test Range(; start=positions[1], var"end"=positions[2]) in ranges
            @test Range(; start=positions[3], var"end"=positions[4]) in ranges
        end
    end

    @testset "export/public" begin
        with_global_binding_occurrences("""
            │foo│() = 42
            export │foo│
            bar() = │foo│()
            """, "foo") do ranges, positions
            @test length(positions) == 6
            @test length(ranges) == 3
            @test Range(; start=positions[1], var"end"=positions[2]) in ranges
            @test Range(; start=positions[3], var"end"=positions[4]) in ranges
            @test Range(; start=positions[5], var"end"=positions[6]) in ranges
        end
        with_global_binding_occurrences("""
            const │MY_CONST│ = 100
            public │MY_CONST│
            use_const() = │MY_CONST│ * 2
            """, "MY_CONST") do ranges, positions
            @test length(positions) == 6
            @test length(ranges) == 3
            @test Range(; start=positions[1], var"end"=positions[2]) in ranges
            @test Range(; start=positions[3], var"end"=positions[4]) in ranges
            @test Range(; start=positions[5], var"end"=positions[6]) in ranges
        end
        # Macro identifiers in export
        with_global_binding_occurrences("""
            macro │mymacro│(ex)
                esc(ex)
            end
            export │@mymacro│
            result = │@mymacro│ 42
            """, "@mymacro") do ranges, positions
            @test length(positions) == 6
            @test length(ranges) == 3
            @test Range(; start=positions[1], var"end"=positions[2]) in ranges
            @test Range(; start=positions[3], var"end"=positions[4]) in ranges
            @test Range(; start=positions[5], var"end"=positions[6]) in ranges
        end
    end
end

end # module test_occurrence_analysis
