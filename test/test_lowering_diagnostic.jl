module test_lowering_diagnostics

using Test
using JETLS
using JETLS: JL, JS
using JETLS.LSP
using JETLS.LSP.URIs2

include(normpath(pkgdir(JETLS), "test", "setup.jl"))
include(normpath(pkgdir(JETLS), "test", "jsjl-utils.jl"))

module lowering_module end

get_lowered_diagnostics(text::AbstractString; kwargs...) = get_lowered_diagnostics(lowering_module, text; kwargs...)
function get_lowered_diagnostics(mod::Module, text::AbstractString; kwargs...)
    filename = abspath(pkgdir(JETLS), "test", "test_lowering_diagnostic.jl")
    fi = JETLS.FileInfo(#=version=#0, text, filename)
    uri = filepath2uri(filename)
    st0_top = JETLS.build_syntax_tree(fi)
    @assert JS.kind(st0_top) === JS.K"toplevel"
    diagnostics = LSP.Diagnostic[]
    JETLS.iterate_toplevel_tree(st0_top) do st0::JS.SyntaxTree
        JETLS.lowering_diagnostics!(diagnostics, uri, fi, mod, st0; kwargs...)
    end
    return diagnostics
end

macro gen_unused(x)
    quote
        unused = nothing
        $(esc(x))
    end
end

macro just_return(x)
    :($(esc(x)))
end

length_utf16(s::AbstractString) = sum(c::Char -> codepoint(c) < 0x10000 ? 1 : 2, collect(s); init=0)

@testset "unused binding detection" begin
    let diagnostics = get_lowered_diagnostics("""
        y = let x = 42
            sin(42)
        end
        """)
        @test length(diagnostics) == 1
        diagnostic = only(diagnostics)
        @test diagnostic.message == "Unused local binding `x`"
        @test diagnostic.range.start.line == 0
        @test diagnostic.range.start.character == sizeof("y = let ")
        @test diagnostic.range.var"end".line == 0
        @test diagnostic.range.var"end".character == sizeof("y = let x")
    end

    let diagnostics = get_lowered_diagnostics("""
        function foo(x, y)
            return x
        end
        """)
        @test length(diagnostics) == 1
        diagnostic = only(diagnostics)
        @test diagnostic.message == "Unused argument `y`"
        @test diagnostic.range.start.line == 0
        @test diagnostic.range.var"end".line == 0
    end

    let diagnostics = get_lowered_diagnostics("""
        function foo(x)
            local y
            return x
        end
        """)
        @test length(diagnostics) == 1
        diagnostic = only(diagnostics)
        @test diagnostic.message == "Unused local binding `y`"
        @test diagnostic.range.start.line == 1
        @test diagnostic.range.var"end".line == 1
    end

    let diagnostics = get_lowered_diagnostics("""
        function foo(x; y=nothing)
            return x
        end
        """)
        @test length(diagnostics) == 1
        diagnostic = only(diagnostics)
        @test diagnostic.message == "Unused argument `y`"
        @test diagnostic.range.start.line == 0
        @test diagnostic.range.var"end".line == 0
    end

    let diagnostics = get_lowered_diagnostics("""
        \"\"\"Docstring\"\"\"
        function foo(x, y)
            return x
        end
        """)
        @test length(diagnostics) == 1
        diagnostic = only(diagnostics)
        @test diagnostic.message == "Unused argument `y`"
    end

    let diagnostics = get_lowered_diagnostics("""
        function foo(x; y)
            return x, y
        end
        """)
        @test isempty(diagnostics)
    end

    let diagnostics = get_lowered_diagnostics("""
        let x = collect(1:10)
            ys = [x for (i, x) in enumerate(x)]
            ys
        end
        """)
        @test length(diagnostics) == 1
        diagnostic = only(diagnostics)
        @test diagnostic.message == "Unused local binding `i`"
        @test diagnostic.range.start.line == 1
        @test diagnostic.range.var"end".line == 1
    end

    @testset "Arguments that are only used within argument list" begin
        @test isempty(get_lowered_diagnostics("hasmatch(x::RegexMatch, y::Bool=isempty(x.matches)) = y"))
        @test """
        function CompletionItem(item::CompletionItem; label::String=item.label, kind::Union{Nothing,Int}=item.kind)
            return CompletionItem(; label, kind)
        end
        """ |> get_lowered_diagnostics |> isempty
        let diagnostics = get_lowered_diagnostics("""
            hasmatch(x::RegexMatch, y::Bool=isempty(x.matches)) = nothing
            """)
            @test length(diagnostics) == 1
            diagnostic = only(diagnostics)
            @test diagnostic.message == "Unused argument `y`"
            @test diagnostic.range.start.line == 0
            @test diagnostic.range.var"end".line == 0
        end
        let diagnostics = get_lowered_diagnostics("""
            hasmatch(x::RegexMatch, y::Bool=false) = nothing
            """)
            @test length(diagnostics) == 2
            @test any(diagnostics) do diagnostic
                diagnostic.message == "Unused argument `x`" &&
                diagnostic.range.start.line == 0 &&
                diagnostic.range.var"end".line == 0
            end
            @test any(diagnostics) do diagnostic
                diagnostic.message == "Unused argument `y`" &&
                diagnostic.range.start.line == 0 &&
                diagnostic.range.var"end".line == 0
            end
        end
        let diagnostics = get_lowered_diagnostics("""
            hasmatch(x::RegexMatch, y::Bool=false) = x
            """)
            @test length(diagnostics) == 1
            diagnostic = only(diagnostics)
            @test diagnostic.message == "Unused argument `y`"
            @test diagnostic.range.start.line == 0
            @test diagnostic.range.var"end".line == 0
        end
        let diagnostics = get_lowered_diagnostics("""
            hasmatch(x::RegexMatch, y::Bool=false) = y
            """)
            @test length(diagnostics) == 1
            diagnostic = only(diagnostics)
            @test diagnostic.message == "Unused argument `x`"
            @test diagnostic.range.start.line == 0
            @test diagnostic.range.var"end".line == 0
        end
    end

    @testset "tolerate bad syntax, broken macros" begin
        let diagnostics = get_lowered_diagnostics("""
            function foo(x)
                local y
                @i_do_not_exist
                return x
            # no end
            """)
            @test length(diagnostics) == 2
            @test any(diagnostics) do diagnostic
                diagnostic.message == "Unused local binding `y`" &&
                diagnostic.range.start.line == 1 &&
                diagnostic.range.var"end".line == 1
            end
        end

        let diagnostics = get_lowered_diagnostics("""
            function foo(x)
                local y = x
                @r_str 1 2 3 4 # methoderror
            end
            """)
            @test length(diagnostics) == 2
            @test any(diagnostics) do diagnostic
                diagnostic.message == "Unused local binding `y`" &&
                diagnostic.range.start.line == 1 &&
                diagnostic.range.var"end".line == 1
            end
        end
    end

    @testset "unused inner function" begin
        diagnostics = get_lowered_diagnostics("""
        function foo(x)
            function inner(y)
                x + y
            end
            return 2x
        end
        """)
        @test length(diagnostics) == 1
        diagnostic = only(diagnostics)
        @test diagnostic.message == "Unused local binding `inner`"
        @test diagnostic.range.start.line == 1
        @test diagnostic.range.var"end".line == 1
    end

    @testset "unused inner function (nested)" begin
        diagnostics = get_lowered_diagnostics("""
        function foo(x)
            function inner(y)
                function innernested()
                    x + y
                end
            end
            return 2x
        end
        """)
        @test length(diagnostics) == 2
        @test any(diagnostics) do diagnostic
            diagnostic.message == "Unused local binding `inner`" &&
            diagnostic.range.start.line == 1 &&
            diagnostic.range.var"end".line == 1
        end
        @test any(diagnostics) do diagnostic
            diagnostic.message == "Unused local binding `innernested`" &&
            diagnostic.range.start.line == 2 &&
            diagnostic.range.var"end".line == 2
        end
    end

    @testset "used inner function" begin
        diagnostics = get_lowered_diagnostics("""
        function foo(x)
            function inner(y)
                x + y
            end
            return 2inner(x)
        end
        """)
        @test isempty(diagnostics)
    end

    @testset "keyword function" begin
        # https://github.com/aviatesk/JETLS.jl/issues/390
        @test isempty(get_lowered_diagnostics("func(a; kw) = a, kw"))
        @test isempty(get_lowered_diagnostics("func(a; kw=a) = kw"))
        @test isempty(get_lowered_diagnostics("func(a; kw1, kw2) = a, kw1, kw2"))
        @test isempty(get_lowered_diagnostics("func(a; kws...) = a, kws"))
        @test isempty(get_lowered_diagnostics("func(a; kw, kws...) = a, kw, kws"))
        let diagnostics = get_lowered_diagnostics("func(a; kw) = a")
            @test length(diagnostics) == 1
            diagnostic = only(diagnostics)
            @test diagnostic.message == "Unused argument `kw`"
            @test diagnostic.range.start.line == 0
        end
        let diagnostics = get_lowered_diagnostics("func(a; kw) = kw")
            @test length(diagnostics) == 1
            diagnostic = only(diagnostics)
            @test diagnostic.message == "Unused argument `a`"
            @test diagnostic.range.start.line == 0
        end
        let diagnostics = get_lowered_diagnostics("func(a; kws...) = a")
            @test length(diagnostics) == 1
            diagnostic = only(diagnostics)
            @test diagnostic.message == "Unused argument `kws`"
            @test diagnostic.range.start.line == 0
        end
        let diagnostics = get_lowered_diagnostics("func(a; kw1, kw2) = kw1, kw2")
            @test length(diagnostics) == 1
            diagnostic = only(diagnostics)
            @test diagnostic.message == "Unused argument `a`"
            @test diagnostic.range.start.line == 0
        end
        let diagnostics = get_lowered_diagnostics("func(a; kw1, kw2) = a, kw2")
            @test length(diagnostics) == 1
            diagnostic = only(diagnostics)
            @test diagnostic.message == "Unused argument `kw1`"
            @test diagnostic.range.start.line == 0
        end
        let diagnostics = get_lowered_diagnostics("func(a; kw, kws...) = a, kw")
            @test length(diagnostics) == 1
            diagnostic = only(diagnostics)
            @test diagnostic.message == "Unused argument `kws`"
            @test diagnostic.range.start.line == 0
        end
        let diagnostics = get_lowered_diagnostics("func(a; kw) = nothing")
            @test length(diagnostics) == 2
            @test any(diagnostics) do diagnostic
                diagnostic.message == "Unused argument `a`" &&
                diagnostic.range.start.line == 0
            end
            @test any(diagnostics) do diagnostic
                diagnostic.message == "Unused argument `kw`" &&
                diagnostic.range.start.line == 0
            end
        end
    end

    @testset "macro definition" begin
        @test isempty(get_lowered_diagnostics("macro mymacro() end"))
        @test isempty(get_lowered_diagnostics("macro mymacro(x) x end"))
        let diagnostics = get_lowered_diagnostics("macro mymacro(x, y) x end")
            @test length(diagnostics) == 1
            diagnostic = only(diagnostics)
            @test diagnostic.message == "Unused argument `y`"
            @test diagnostic.range.start.line == 0
        end
        let diagnostics = get_lowered_diagnostics("""
            function foo(__module__, name)
                getglobal(@__MODULE__, name)
            end
            """; allow_unused_underscore=false)
            @test length(diagnostics) == 1
            diagnostic = only(diagnostics)
            @test diagnostic.message == "Unused argument `__module__`"
            @test diagnostic.range.start.line == 0
        end
    end

    @testset "struct definition" begin
        @test isempty(get_lowered_diagnostics("struct A end"))
        @test isempty(get_lowered_diagnostics("struct A; x::Int; end"))
        @test isempty(get_lowered_diagnostics("struct A{T}; x::T; end"))
        let diagnostics = get_lowered_diagnostics("""
            struct A
                x::Int
                A(x::Int, y::Int) = new(x)
            end
            """)
            @test length(diagnostics) == 1
            diagnostic = only(diagnostics)
            @test diagnostic.message == "Unused argument `y`"
            @test diagnostic.range.start.line == 2
        end
        let diagnostics = get_lowered_diagnostics("""
            struct A{T}
                x::T
                A(x::T, y::Int) where T = new{T}(x)
            end
            """)
            @test length(diagnostics) == 1
            diagnostic = only(diagnostics)
            @test diagnostic.message == "Unused argument `y`"
            @test diagnostic.range.start.line == 2
        end
        # constructor definition with keyword arguments
        let diagnostics = get_lowered_diagnostics("""
            struct A{T}
                x::T
                A(x::T; override::Union{Nothing,T}) where T = new{T}(@something override x)
            end
            """)
            @test isempty(diagnostics)
        end
        let diagnostics = get_lowered_diagnostics("""
            struct A{T}
                x::T
                A(x::T; override::Union{Nothing,T}) where T = new{T}(x)
            end
            """)
            @test length(diagnostics) == 1
            diagnostic = only(diagnostics)
            @test diagnostic.message == "Unused argument `override`"
            @test diagnostic.range.start.line == 2
        end
    end

    # https://github.com/aviatesk/JETLS.jl/issues/481
    @testset "keyword argument constraining used static parameter" begin
        # keyword arg constraining a used static parameter should not be reported
        let diagnostics = get_lowered_diagnostics("""
            f(; dtype::Type{T}=Float32) where {T} = T
            """)
            @test isempty(diagnostics)
        end
        # keyword arg constraining an unused static parameter should still be reported
        let diagnostics = get_lowered_diagnostics("""
            f(; dtype::Type{T}=Float32) where {T} = 1
            """)
            @test length(diagnostics) == 1
            @test only(diagnostics).message == "Unused argument `dtype`"
        end
        # positional arg constraining a used static parameter should still be reported
        let diagnostics = get_lowered_diagnostics("""
            f(x::Type{T}) where {T} = T
            """)
            @test length(diagnostics) == 1
            @test only(diagnostics).message == "Unused argument `x`"
        end
        # keyword arg with multiple type parameters, at least one used
        let diagnostics = get_lowered_diagnostics("""
            f(; x::Pair{S,T}=1=>2) where {S,T} = S
            """)
            @test isempty(diagnostics)
        end
        # full example from the issue
        let diagnostics = get_lowered_diagnostics("""
            function compute_rotary_embedding_params(
                head_dim::Integer,
                max_sequence_length::Integer;
                base::Number,
                dtype::Type{T}=Float32,
                low_memory_variant::Bool=true,
            ) where {T}
                θ = inv.(T.(base .^ (range(0, head_dim - 1; step=2)[1:(head_dim ÷ 2)] ./ head_dim)))
                seq_idx = collect(T, 0:(max_sequence_length - 1))
                angles = reshape(θ, :, 1) .* reshape(seq_idx, 1, :)
                low_memory_variant || (angles = vcat(angles, angles))
                return (; cos_cache=cos.(angles), sin_cache=sin.(angles))
            end
            """)
            @test isempty(diagnostics)
        end

        # aviatesk/JETLS.jl#592
        let diagnostics = get_lowered_diagnostics("""
            function group(
                by,
                f,
                itr;
                T::Type = eltype(itr),
                By::Type = only(Base.return_types(by, (T,))),
                F::Type = only(Base.return_types(f, (T,))),
            )::Dict{By, Vector{F}}
                return foldl(itr; init = Dict{By, Vector{F}}()) do acc, x
                    push!(get!(acc, by(x), F[]), f(x))
                    return acc
                end
            end
            """)
            @test isempty(diagnostics)
        end
    end

    @testset "module splitter" begin
        script = """
        module TestModuleSplit
        global y::Float64 = let x = 42
            sin(42)
        end
        end # module TestModuleSplit
        """
        withscript(script) do script_path
            uri = filepath2uri(script_path)
            withserver() do (; writereadmsg, id_counter, server)
                JETLS.cache_file_info!(server, uri, 1, script)
                JETLS.cache_saved_file_info!(server.state, uri, script)
                JETLS.request_analysis!(server, uri, #=invalidate=#false; wait=true, notify_diagnostics=false)

                id = id_counter[] += 1
                (; raw_res) = writereadmsg(DocumentDiagnosticRequest(;
                    id,
                    params = DocumentDiagnosticParams(;
                        textDocument = TextDocumentIdentifier(; uri)
                    )))
                @test raw_res isa DocumentDiagnosticResponse
                @test raw_res.result isa RelatedFullDocumentDiagnosticReport
                @test length(raw_res.result.items) == 1
                diagnostic = only(raw_res.result.items)
                @test diagnostic.message == "Unused local binding `x`"
                @test diagnostic.range.start.line == 1
                @test diagnostic.range.var"end".line == 1
            end
        end
    end

    @testset "string macro support" begin
        diagnostics = get_lowered_diagnostics("""
        let s = rand(Int)
            lazy"s = \$s"
        end
        """)
        @test isempty(diagnostics)
    end

    @testset "cmdstring macro support" begin
        diagnostics = get_lowered_diagnostics("""
        function testrunner_cmd(filepath::String, tcl::Int, test_env_path::Union{Nothing,String})
            testrunner_exe = Sys.which("testrunner")
            if isnothing(test_env_path)
                return `\$testrunner_exe --verbose --json \$filepath L\$tcl`
            else
                return `\$testrunner_exe --verbose --project=\$test_env_path --json \$filepath L\$tcl`
            end
        end
        """)
        @test isempty(diagnostics)
    end

    @testset "Unused bindings within macro code" begin
        diagnostics = get_lowered_diagnostics(@__MODULE__, """
        function func(x)
            return @gen_unused x
        end
        """)
        @test isempty(diagnostics)
    end

    @testset "@nospecialize macro" begin
        diagnostics = get_lowered_diagnostics("""
        function kwargs_dict(@nospecialize configs)
            return ()
        end
        """)
        @test length(diagnostics) == 1
        diagnostic = only(diagnostics)
        @test diagnostic.message == "Unused argument `configs`"
        @test diagnostic.range.start.line == 0
        @test diagnostic.range.var"end".line == 0
    end

    # # This should be reported ideally, but currently JuliaLowering cannot track
    # # precise provenance for code expanded from old macros, so it gets caught by the check in analyze_unused_bindings!
    @testset "argument decl with macro" begin
        diagnostics = get_lowered_diagnostics(@__MODULE__, """
        func(@just_return x) = nothing
        """)
        res = length(diagnostics) == 1
        @test_broken res
        if res
            diagnostic = only(diagnostics)
            @test diagnostic.message == "Unused argument `x`"
            @test diagnostic.range.start.line == 0
            @test diagnostic.range.start.character == length("func(")
            @test diagnostic.range.var"end".line == 0
            @test diagnostic.range.var"end".character == length("func(@just_return x")
        end
    end

    @testset "Handle position encoding" begin
        diagnostics = get_lowered_diagnostics("""
        f(😀, x) = 😀
        """)
        @test length(diagnostics) == 1
        diagnostic = only(diagnostics)
        @test diagnostic.range.start.line == 0
        @test diagnostic.range.start.character == length_utf16("f(😀, ")
        @test diagnostic.range.var"end".line == 0
        @test diagnostic.range.var"end".character == length_utf16("f(😀, x")
    end

    @testset "comprehension" begin
        let diagnostics = get_lowered_diagnostics("""
            func(xs) = [x for x in xs]
            """)
            @test isempty(diagnostics)
        end

        let diagnostics = get_lowered_diagnostics("""
            func(xs) = [x for (i, x) in enumerate(xs)]
            """)
            @test length(diagnostics) == 1
            diagnostic = only(diagnostics)
            @test diagnostic.range.start.line == 0
            @test diagnostic.range.start.character == length_utf16("func(xs) = [x for (")
            @test diagnostic.range.var"end".line == 0
            @test diagnostic.range.var"end".character == length_utf16("func(xs) = [x for (i")
        end

        # aviatesk/JETLS.jl#360
        let diagnostics = get_lowered_diagnostics("""
            func(xs) = [x for (i, x) in enumerate(xs) if isodd(i)]
            """)
            @test isempty(diagnostics)
        end

        let diagnostics = get_lowered_diagnostics("""
            func(xs) = [x for (i, x) in xs if true]
            """)
            @test length(diagnostics) == 1
            diagnostic = only(diagnostics)
            @test diagnostic.range.start.line == 0
            @test diagnostic.range.start.character == length_utf16("func(xs) = [x for (")
            @test diagnostic.range.var"end".line == 0
            @test diagnostic.range.var"end".character == length_utf16("func(xs) = [x for (i")
        end
    end

    @testset "allow_unused_underscore" begin
        let diagnostics = get_lowered_diagnostics("""
            function foo(_x, y)
                return y
            end
            """)
            @test isempty(diagnostics)
        end

        let diagnostics = get_lowered_diagnostics("""
            function foo(_x, y)
                return y
            end
            """; allow_unused_underscore=false)
            @test length(diagnostics) == 1
            diagnostic = only(diagnostics)
            @test diagnostic.message == "Unused argument `_x`"
        end

        let diagnostics = get_lowered_diagnostics("""
            y = let _x = 42
                sin(42)
            end
            """)
            @test isempty(diagnostics)
        end

        let diagnostics = get_lowered_diagnostics("""
            y = let _x = 42
                sin(42)
            end
            """; allow_unused_underscore=false)
            @test length(diagnostics) == 1
            diagnostic = only(diagnostics)
            @test diagnostic.message == "Unused local binding `_x`"
        end
    end

    # aviatesk/JETLS.jl#480
    @testset "@generated function" begin
        let diagnostics = get_lowered_diagnostics("""
            @generated function replicate(rng::T) where {T}
                hasmethod(copy, (T,)) && return :(copy(rng))
                return :(deepcopy(rng))
            end
            """)
            @test isempty(diagnostics)
        end

        let diagnostics = get_lowered_diagnostics("""
            @generated function foo(x, unused)
                return :(x + 1)
            end
            """)
            @test length(diagnostics) == 1
            @test only(diagnostics).message == "Unused argument `unused`"
        end
    end
end

module EmptyModule end
@testset "unused binding detection (before full-analysis, without macro expansion)" begin
    # `@sprintf` is not available yet for EmptyModule (simulating the lowering analysis behavior before full-analysis complete)
    # https://github.com/aviatesk/JETLS.jl/issues/522
    diagnostics = get_lowered_diagnostics(EmptyModule, """
        let
            OLR = SW_in = 0.0
            @info @sprintf("OLR: %.1f W/m², SW_in: %.1f W/m², net: %.1f W/m²",
                            OLR, SW_in, SW_in - OLR)
        end
        """; skip_analysis_requiring_context=true)
    @test isempty(diagnostics)
end

macro m_throw(_)
    throw("show this error message")
end
macro m_gen_invalid(n)
    :([return i for i in 1:$n])
end

include(normpath(pkgdir(JETLS), "test", "fixtures", "macros.jl"))
let filename = normpath(pkgdir(JETLS), "test", "fixtures", "macros-JL.jl")
    JL.include_string(@__MODULE__, read(filename,String), filename)
end

@testset "JuliaLowering error diagnostics" begin
    @testset "lowering error diagnostics" begin
        diagnostics = get_lowered_diagnostics(@__MODULE__, "macro foo(x, y) \$(x) end")
        @test length(diagnostics) == 1
        diagnostic = only(diagnostics)
        @test diagnostic.source == JETLS.DIAGNOSTIC_SOURCE_LIVE
        @test diagnostic.message == "`\$` expression outside string or quote"
    end

    @testset "toplevel lowering error diagnostics" begin
        let diagnostics = get_lowered_diagnostics("""
            macro foo(x, y) \$(x) end
            macro bar(x, y) \$(x) end
            """)
            @test length(diagnostics) == 2
            @test count(diagnostics) do diagnostic
                diagnostic.source == JETLS.DIAGNOSTIC_SOURCE_LIVE &&
                diagnostic.message == "`\$` expression outside string or quote" &&
                diagnostic.range.start.line == 0 &&
                diagnostic.range.var"end".line == 0
            end == 1
            @test count(diagnostics) do diagnostic
                diagnostic.source == JETLS.DIAGNOSTIC_SOURCE_LIVE &&
                diagnostic.message == "`\$` expression outside string or quote" &&
                diagnostic.range.start.line == 1 &&
                diagnostic.range.var"end".line == 1
            end == 1
        end
    end

    @testset "macro not found error diagnostics" begin
        diagnostics = get_lowered_diagnostics(@__MODULE__, "x = @notexisting 42")
        @test length(diagnostics) == 1
        diagnostic = only(diagnostics)
        @test diagnostic.source == JETLS.DIAGNOSTIC_SOURCE_LIVE
        @test diagnostic.message == "Macro name `@notexisting` not found"
        @test diagnostic.range.start.line == 0
        @test diagnostic.range.start.character == sizeof("x = ")
        @test diagnostic.range.var"end".line == 0
        @test diagnostic.range.var"end".character == sizeof("x = @notexisting")
    end

    @testset "@. macro (aviatesk/JETLS.jl#409)" begin
        diagnostics = get_lowered_diagnostics(@__MODULE__, """
        function foo()
            x = rand(10)
            y = rand(10)
            @views @. muladd(x[1:end], y[1], y[1:end])
        end
        """)
        @test isempty(diagnostics)
    end

    @testset "string macro not found error diagnostics" begin
        diagnostics = get_lowered_diagnostics(@__MODULE__, "x = notexisting\"string\"")
        @test length(diagnostics) == 1
        diagnostic = only(diagnostics)
        @test diagnostic.source == JETLS.DIAGNOSTIC_SOURCE_LIVE
        @test diagnostic.message == "Macro name `@notexisting_str` not found"
        @test diagnostic.range.start.line == 0
        @test diagnostic.range.start.character == sizeof("x = ")
        @test diagnostic.range.var"end".line == 0
        @test diagnostic.range.var"end".character == sizeof("x = notexisting")
    end

    @testset "macro expansion error diagnostics" begin
        diagnostics = get_lowered_diagnostics(@__MODULE__, "x = @m_throw 42")
        @test length(diagnostics) == 1
        diagnostic = only(diagnostics)
        @test diagnostic.source == JETLS.DIAGNOSTIC_SOURCE_LIVE
        @test diagnostic.message == "Error expanding macro\n\"show this error message\""
        @test diagnostic.range.start.line == 0
        @test diagnostic.range.start.character == sizeof("x = ")
        @test diagnostic.range.var"end".line == 0
        @test diagnostic.range.var"end".character == sizeof("x = @m_throw 42")
    end

    @testset "nested macro expansion error diagnostics" begin
        diagnostics = get_lowered_diagnostics(@__MODULE__, """let
            @m_outer_error missing
        end""")
        @test length(diagnostics) == 1
        diagnostic = only(diagnostics)
        @test diagnostic.source == JETLS.DIAGNOSTIC_SOURCE_LIVE
        @test diagnostic.message == "Error expanding macro\nError in foo"
        @test diagnostic.range.start.line == 1
        @test diagnostic.range.start.character == 4
        @test diagnostic.range.var"end".line == 1
        @test diagnostic.range.var"end".character == sizeof("    @m_outer_error missing")
    end

    @testset "nested macro expansion error diagnostics (with JL provenance)" begin
        diagnostics = get_lowered_diagnostics(@__MODULE__, """let
            @m_outer_error_JL missing
        end""")
        @test length(diagnostics) == 1
        diagnostic = only(diagnostics)
        @test diagnostic.source == JETLS.DIAGNOSTIC_SOURCE_LIVE
        @test diagnostic.message == "Error expanding macro\nError in foo"
        @test diagnostic.range.start.line == 1
        @test diagnostic.range.start.character == 4
        @test diagnostic.range.var"end".line == 1
        @test diagnostic.range.var"end".character == sizeof("    @m_outer_error_JL missing")
    end

    @testset "lowering error within macro expanded code" begin
        diagnostics = get_lowered_diagnostics(@__MODULE__, """let x = 42
            println(x)
            @m_gen_invalid x
        end
        """)
        @test length(diagnostics) == 1
        diagnostic = only(diagnostics)
        @test diagnostic.source == JETLS.DIAGNOSTIC_SOURCE_LIVE
        @test diagnostic.message == "`return` not allowed inside comprehension or generator"
        @test diagnostic.range.start.line == 2
        @test diagnostic.range.var"end".line == 2
    end
end

module TestLoweringUndefGlobalBinding
const myfunc = (x) -> x
end

@testset "Undefined global binding report" begin
    @test isempty(get_lowered_diagnostics(@__MODULE__, "let x = 42; println(sin(x)); end"))
    let diagnostics = get_lowered_diagnostics(@__MODULE__, """let x = 42
            undeffunc(x)
        end
        """)
        @test length(diagnostics) == 1
        diagnostic = only(diagnostics)
        @test diagnostic.source == JETLS.DIAGNOSTIC_SOURCE_LIVE
        @test diagnostic.code == JETLS.LOWERING_UNDEF_GLOBAL_VAR_CODE
        @test diagnostic.message == "`$(@__MODULE__).undeffunc` is not defined"
        @test diagnostic.range.start.line == 1
        @test diagnostic.range.start.character == 4
        @test diagnostic.range.var"end".line == 1
        @test diagnostic.range.var"end".character == 13
    end

    @test isempty(get_lowered_diagnostics(TestLoweringUndefGlobalBinding, "let x = 42; println(myfunc(x)); end"))
    let diagnostics = get_lowered_diagnostics(TestLoweringUndefGlobalBinding, """let x = 42
            undeffunc(x)
        end
        """)
        @test length(diagnostics) == 1
        diagnostic = only(diagnostics)
        @test diagnostic.source == JETLS.DIAGNOSTIC_SOURCE_LIVE
        @test diagnostic.message == "`$(TestLoweringUndefGlobalBinding).undeffunc` is not defined"
        @test diagnostic.range.start.line == 1
        @test diagnostic.range.start.character == 4
        @test diagnostic.range.var"end".line == 1
        @test diagnostic.range.var"end".character == 13
    end

    @test isempty(get_lowered_diagnostics(@__MODULE__, """
        struct Issue492
            global function make_issue492()
                new()
            end
        end
    """))
end

@testset "Undefined local binding report" begin
    @testset "sequential assignment then use - no diagnostic" begin
        @test isempty(get_lowered_diagnostics("""
            function f()
                y = 1
                println(y)
            end
            """))
    end

    @testset "use before assignment - strict undef (Warning)" begin
        let diagnostics = get_lowered_diagnostics("""
            function f()
                println(y)
                y = 1
            end
            """)
            @test length(diagnostics) == 2
            undef_diag = diagnostics[findfirst(
                d -> d.code == JETLS.LOWERING_UNDEF_LOCAL_VAR_CODE,
                diagnostics)]
            @test undef_diag.severity == DiagnosticSeverity.Warning
            @test undef_diag.message == "Variable `y` is used before it is defined"
            @test undef_diag.range.start.line == 1
            dead_store_diag = diagnostics[findfirst(
                d -> d.code == JETLS.LOWERING_UNUSED_ASSIGNMENT_CODE,
                diagnostics)]
            @test dead_store_diag.severity == DiagnosticSeverity.Information
            @test dead_store_diag.message == "Value assigned to `y` is never used"
            @test dead_store_diag.range.start.line == 2
        end
    end

    @testset "if-else both branches assign - no diagnostic" begin
        @test isempty(get_lowered_diagnostics("""
            function f()
                if rand() > 0.5
                    y = 1
                else
                    y = 2
                end
                println(y)
            end
            """))
    end

    @testset "if-else one branch assigns - maybe undef (Information)" begin
        let diagnostics = get_lowered_diagnostics("""
            function f()
                if rand() > 0.5
                    y = 1
                else
                    nothing
                end
                println(y)
            end
            """)
            @test length(diagnostics) == 1
            diagnostic = only(diagnostics)
            @test diagnostic.code == JETLS.LOWERING_UNDEF_LOCAL_VAR_CODE
            @test diagnostic.severity == DiagnosticSeverity.Information
            @test diagnostic.message == "Variable `y` may be used before it is defined"
        end
    end

    @testset "while loop - maybe undef" begin
        let diagnostics = get_lowered_diagnostics("""
            function f()
                local y
                while rand() > 0.5
                    y = 1
                end
                println(y)
            end
            """)
            @test length(diagnostics) == 1
            diagnostic = only(diagnostics)
            @test diagnostic.code == JETLS.LOWERING_UNDEF_LOCAL_VAR_CODE
            @test diagnostic.severity == DiagnosticSeverity.Information
        end
    end

    @testset "@isdefined guard - no diagnostic" begin
        @test isempty(get_lowered_diagnostics("""
            function f(x)
                if x > 0
                    y = 42
                end
                if @isdefined(y)
                    return sin(y)
                end
            end
            """))
    end

    @testset "@isdefined in && chain - no diagnostic" begin
        @test isempty(get_lowered_diagnostics("""
            function f(x)
                if x > 0
                    y = 42
                end
                if x > 0 && @isdefined(y)
                    return sin(y)
                end
            end
            """))
    end

    @testset "@assert @isdefined hint" begin
        @test isempty(get_lowered_diagnostics("""
            function f(x)
                if x > 0
                    y = x
                end
                if x > 0
                    @assert @isdefined(y) "compiler hint to tell the definedness of this variable"
                    return sin(y)
                end
            end
            """))
    end

    @testset "closure assigns to captured variable - maybe undef" begin
        # When a closure assigns to a captured variable, we don't know when/if
        # the closure is called, so report "may be undefined" instead of
        # "must be undefined"
        let diagnostics = get_lowered_diagnostics("""
            function func(a)
                local x
                function inner(y)
                    x = y
                end
                f = inner
                f(a)
                return x
            end
            """)
            undef_diags = filter(d -> d.code == JETLS.LOWERING_UNDEF_LOCAL_VAR_CODE, diagnostics)
            @test length(undef_diags) == 1
            diagnostic = only(undef_diags)
            @test diagnostic.severity == DiagnosticSeverity.Information
            @test diagnostic.message == "Variable `x` may be used before it is defined"
        end
    end

    @testset "relatedInformation shows definition locations" begin
        let diagnostics = get_lowered_diagnostics("""
            function f()
                if rand() > 0.5
                    y = 1
                end
                println(y)
            end
            """)
            @test length(diagnostics) == 1
            diagnostic = only(diagnostics)
            @test diagnostic.relatedInformation !== nothing
            @test length(diagnostic.relatedInformation) == 1
            ri = only(diagnostic.relatedInformation)
            @test ri.message == "`y` is defined here"
            @test ri.location.range.start.line == 2  # y = 1 is on line 2
        end
    end

    @testset "diagnostic points to the use on undef path, not the defined use" begin
        let diagnostics = get_lowered_diagnostics("""
            function f(x::Bool, y::Bool)
                if x
                    z = "Hi"
                    println(z)
                end
                if y
                    println(z)
                end
            end
            """)
            @test length(diagnostics) == 1
            diagnostic = only(diagnostics)
            @test diagnostic.code == JETLS.LOWERING_UNDEF_LOCAL_VAR_CODE
            @test diagnostic.severity == DiagnosticSeverity.Information
            @test diagnostic.range.start.line == 6  # println(z) in the second if block
        end
    end

    @testset "multiple undef uses each get their own diagnostic" begin
        let diagnostics = get_lowered_diagnostics("""
            function f(x::Bool)
                if x
                    z = 1
                end
                println(z)
                println(z)
            end
            """)
            undef_diags = filter(
                d -> d.code == JETLS.LOWERING_UNDEF_LOCAL_VAR_CODE, diagnostics)
            @test length(undef_diags) == 2
            @test undef_diags[1].range.start.line == 4
            @test undef_diags[2].range.start.line == 5
            @test all(d -> d.severity == DiagnosticSeverity.Information, undef_diags)
        end
    end

    @testset "multiple definitions show multiple relatedInformation" begin
        let diagnostics = get_lowered_diagnostics("""
            function f()
                if rand() > 0.5
                    y = 1
                elseif rand() > 0.5
                    y = 2
                end
                println(y)
            end
            """)
            @test length(diagnostics) == 1
            diagnostic = only(diagnostics)
            @test diagnostic.relatedInformation !== nothing
            @test length(diagnostic.relatedInformation) == 2
        end
    end
end

@testset "dead store detection" begin
    @testset "assignment at end of function is dead" begin
        let diagnostics = get_lowered_diagnostics("""
            function foo(x::Bool)
                if x
                    z = "Hi"
                    println(z)
                end
                if x
                    z = "Hey"
                end
            end
            """)
            @test length(diagnostics) == 1
            diagnostic = only(diagnostics)
            @test diagnostic.code == JETLS.LOWERING_UNUSED_ASSIGNMENT_CODE
            @test diagnostic.severity == DiagnosticSeverity.Information
            @test diagnostic.message == "Value assigned to `z` is never used"
            @test diagnostic.range.start.line == 6
        end
    end

    @testset "unconditional overwrite" begin
        let diagnostics = get_lowered_diagnostics("""
            function f()
                z = "initial"
                z = "overwrite"
                println(z)
            end
            """)
            @test length(diagnostics) == 1
            diagnostic = only(diagnostics)
            @test diagnostic.code == JETLS.LOWERING_UNUSED_ASSIGNMENT_CODE
            @test diagnostic.message == "Value assigned to `z` is never used"
            @test diagnostic.range.start.line == 1
            data = diagnostic.data
            @test data isa JETLS.UnusedVariableData
            @test !data.is_tuple_unpacking
            @test data.assignment_range !== nothing
            @test data.lhs_eq_range !== nothing
        end
    end

    @testset "conditional overwrite - no dead store" begin
        @test isempty(get_lowered_diagnostics("""
            function f(x::Bool)
                z = "initial"
                if x
                    z = "updated"
                end
                println(z)
            end
            """))
    end

    @testset "multiple dead stores" begin
        let diagnostics = get_lowered_diagnostics("""
            function f()
                z = 1
                z = 2
                z = 3
                println(z)
            end
            """)
            dead_stores = filter(d -> d.message == "Value assigned to `z` is never used", diagnostics)
            @test length(dead_stores) == 2
        end
    end

    @testset "dead store after last use" begin
        let diagnostics = get_lowered_diagnostics("""
            function f()
                z = 1
                println(z)
                z = 2
                return
            end
            """)
            @test length(diagnostics) == 1
            diagnostic = only(diagnostics)
            @test diagnostic.message == "Value assigned to `z` is never used"
            @test diagnostic.range.start.line == 3
        end
    end

    @testset "lhs_eq_range for string RHS includes delimiter" begin
        let diagnostics = get_lowered_diagnostics("""
            function f()
                z = "initial"
                z = "overwrite"
                println(z)
            end
            """)
            @test length(diagnostics) == 1
            diagnostic = only(diagnostics)
            data = diagnostic.data
            @test data isa JETLS.UnusedVariableData
            # "Delete assignment" should remove `z = ` and keep `"initial"`
            # lhs_eq_range end character should point to `"`, not past it
            lhs_eq = data.lhs_eq_range
            @test lhs_eq.start.character == 4  # start of `z`
            @test lhs_eq.var"end".character == 8  # start of `"` in `"initial"`
        end
    end

    @testset "underscore prefix suppresses dead store" begin
        @test isempty(get_lowered_diagnostics("""
            function f()
                _z = 1
                _z = 2
                println(_z)
            end
            """))
    end

    @testset "closure capture - no dead store" begin
        let diagnostics = get_lowered_diagnostics("""
            function f()
                x = 1
                f = () -> x
                x = 2
                return f
            end
            """)
            # x is captured by a closure, so dead store analysis skips it.
            # The only diagnostic should be the captured-boxed-variable one.
            @test all(d -> d.code != JETLS.LOWERING_UNUSED_ASSIGNMENT_CODE, diagnostics)
        end
    end
end

@testset "captured boxed variable detection" begin
    # Variable modified after capture -> boxed
    let diagnostics = get_lowered_diagnostics("""
        function foo()
            x = 1
            f = () -> x
            x = 2
            return f
        end
        """)
        @test length(diagnostics) == 1
        diagnostic = only(diagnostics)
        @test diagnostic.message == "`x` is captured and boxed"
        @test diagnostic.code == JETLS.LOWERING_CAPTURED_BOXED_VARIABLE_CODE
        @test diagnostic.severity == DiagnosticSeverity.Information
        @test diagnostic.range.start.line == 1
        @test diagnostic.range.var"end".line == 1
        @test length(diagnostic.relatedInformation) == 1
        ri = only(diagnostic.relatedInformation)
        @test ri.message == "Captured by closure"
        @test ri.location.range.start.line == 2
        @test ri.location.range.start.character == length("    f = () -> ") # points to `x`, not `() -> x`
    end

    # Multiple captured variables
    let diagnostics = get_lowered_diagnostics("""
        function bar()
            a = b = 1
            f = () -> (a, b)
            a = b = 2
            return f
        end
        """)
        @test length(diagnostics) == 2
        @test all(d -> d.code == JETLS.LOWERING_CAPTURED_BOXED_VARIABLE_CODE, diagnostics)
        names = Set(match(r"`(\w+)`", d.message).captures[1] for d in diagnostics)
        @test names == Set(["a", "b"])
    end

    # No capture, no modification -> no diagnostic
    @test isempty(get_lowered_diagnostics("""
        function baz(x)
            y = x
            return sin(y)
        end
        """))

    # Multiple closures capturing same variable
    let diagnostics = get_lowered_diagnostics("""
        function multi()
            x = 1
            f = () -> x
            g = () -> x + 1
            x = 2
            return f, g
        end
        """)
        @test length(diagnostics) == 1
        diagnostic = only(diagnostics)
        @test diagnostic.message == "`x` is captured and boxed"
        # Should have 2 related information entries (one for each closure)
        @test diagnostic.relatedInformation !== nothing
        @test length(diagnostic.relatedInformation) == 2
    end

    # Nested closure
    let diagnostics = get_lowered_diagnostics("""
        function nested()
            x = 1
            f = () -> begin
                g = () -> x
                g
            end
            x = 2
            return f
        end
        """)
        @test length(diagnostics) == 1
        diagnostic = only(diagnostics)
        @test diagnostic.message == "`x` is captured and boxed"
        @test diagnostic.relatedInformation !== nothing
        @test length(diagnostic.relatedInformation) == 2
    end

    # do block capture
    let diagnostics = get_lowered_diagnostics("""
        function with_do()
            x = 1
            result = map([1,2,3]) do i
                i + x
            end
            x = 2
            return result
        end
        """)
        @test length(diagnostics) == 1
        diagnostic = only(diagnostics)
        @test diagnostic.message == "`x` is captured and boxed"
    end

    # From performance tips
    let diagnostics = get_lowered_diagnostics("""
        function abmult1(r::Int)
            if r < 0
                r = -r
            end
            f = x -> x * r
            return f
        end
        """)
        @test length(diagnostics) == 1
        diagnostic = only(diagnostics)
        @test diagnostic.message == "`r` is captured and boxed"
    end
    let diagnostics = get_lowered_diagnostics("""
        function abmult2(r::Int)
            if r < 0
                r = -r
            end
            f = let r = r
                x -> x * r
            end
            return f
        end
        """)
        @test isempty(diagnostics)
    end
    let diagnostics = get_lowered_diagnostics("""
        function abmult3(r0::Int)
            r::Int = r0
            if r < 0
                r = -r
            end
            f = x -> x * r
            return f
        end
        """)
        @test length(diagnostics) == 1
        diagnostic = only(diagnostics)
        @test diagnostic.message == "`r` is captured and boxed"
    end
    let diagnostics = get_lowered_diagnostics("""
        function abmult4(r0::Int)
            r = Ref(r0)
            if r0 < 0
                r[] = -r0
            end
            f = x -> x * r[]
            return f
        end
        """)
        @test isempty(diagnostics)
    end

    # https://github.com/aviatesk/JETLS.jl/issues/508
    let diagnostics = get_lowered_diagnostics("""
        struct Foo{T}
            x::T
            function Foo(x)
                T = typeof(x)
                return new{T}(x)
            end
        end
        """)
        @test isempty(diagnostics)
    end
end

is_unsorted_import_names_diagnostic(diagnostic) =
    diagnostic.message == "Names are not sorted alphabetically" &&
    diagnostic.code == JETLS.LOWERING_UNSORTED_IMPORT_NAMES_CODE &&
    diagnostic.severity == JETLS.DiagnosticSeverity.Hint &&
    diagnostic.data isa UnsortedImportData

@testset "unsorted import names" begin
    let diagnostics = get_lowered_diagnostics("""
        import Foo: c, a, b
        """)
        @test length(diagnostics) == 1
        diagnostic = only(diagnostics)
        @test is_unsorted_import_names_diagnostic(diagnostic)
        @test diagnostic.data.new_text == "import Foo: a, b, c"
    end

    let diagnostics = get_lowered_diagnostics("""
        using Bar: x, y, z
        """)
        @test isempty(diagnostics)
    end

    let diagnostics = get_lowered_diagnostics("""
        export c, a, b
        """)
        @test length(diagnostics) == 1
        @test is_unsorted_import_names_diagnostic(only(diagnostics))
    end

    let diagnostics = get_lowered_diagnostics("""
        public z, y
        """)
        @test length(diagnostics) == 1
        @test is_unsorted_import_names_diagnostic(only(diagnostics))
    end

    let diagnostics = get_lowered_diagnostics("""
        using Foo: bar as baz, alpha as a
        """)
        @test length(diagnostics) == 1
        @test is_unsorted_import_names_diagnostic(only(diagnostics))
    end

    let diagnostics = get_lowered_diagnostics("""
        using Foo: alpha as a, bar as baz
        """)
        @test isempty(diagnostics)
    end

    let diagnostics = get_lowered_diagnostics("""
        using ..Parent: b, a
        """)
        @test length(diagnostics) == 1
        @test is_unsorted_import_names_diagnostic(only(diagnostics))
    end

    let diagnostics = get_lowered_diagnostics("""
        export foo, bar
        """)
        @test length(diagnostics) == 1
        @test is_unsorted_import_names_diagnostic(only(diagnostics))
    end

    let diagnostics = get_lowered_diagnostics("""
        import Core, ..Base, Base
        """)
        @test length(diagnostics) == 1
        @test is_unsorted_import_names_diagnostic(only(diagnostics))
    end

    let diagnostics = get_lowered_diagnostics("""
        using Core, Base
        """)
        @test length(diagnostics) == 1
        @test is_unsorted_import_names_diagnostic(only(diagnostics))
    end

    let diagnostics = get_lowered_diagnostics("""
        import Base, Core
        """)
        @test isempty(diagnostics)
    end
end

function get_unused_import_diagnostics(text::AbstractString)
    server = JETLS.Server()
    uri = URI("file:///test_unused_imports.jl")
    fi = JETLS.cache_file_info!(server, uri, 1, text)
    st0_top = JETLS.build_syntax_tree(fi)
    return JETLS.analyze_unused_imports(server, uri, fi, st0_top; skip_context_check=true)
end

@testset "unused imports detection" begin
    let diagnostics = get_unused_import_diagnostics("""
        using Base: sin, cos
        sin(1.0)
        """)
        @test length(diagnostics) == 1
        diagnostic = only(diagnostics)
        @test diagnostic.message == "Unused import `cos`"
        @test DiagnosticTag.Unnecessary in diagnostic.tags
        @test diagnostic.range.start.line == 0
        @test diagnostic.range.start.character == sizeof("using Base: sin, ")
        @test diagnostic.range.var"end".line == 0
        @test diagnostic.range.var"end".character == sizeof("using Base: sin, cos")
    end

    # Macro imports should not be reported as unused when the macro is used
    # + Qualified macro calls (Module.@macro) should track module usage
    let diagnostics = get_unused_import_diagnostics("""
        using Base: @nospecialize
        function f(@nospecialize x)
            x
        end

        using Preferences: Preferences
        const DEV_MODE = Preferences.@load_preference("DEV_MODE", false)
        """)
        @test isempty(diagnostics)
    end

    # `using M.Submodule` should not be tracked (imports all exports, not explicit)
    let diagnostics = get_unused_import_diagnostics("""
        using Core.IR
        """)
        @test isempty(diagnostics)
    end

    # Re-exported names should not be reported as unused
    let diagnostics = get_unused_import_diagnostics("""
        using Base: sin
        export sin
        """)
        @test isempty(diagnostics)
    end
    # `public` statement also counts as usage
    let diagnostics = get_unused_import_diagnostics("""
        using Base: cos
        public cos
        """)
        @test isempty(diagnostics)
    end

    # Imports used only in @generated function body should not be reported as unused
    let diagnostics = get_unused_import_diagnostics("""
        using Base.Iterators: flatten
        @generated foo(x) = :(flatten(x))
        """)
        @test isempty(diagnostics)
    end

    # Imports used inside macro body quoted expressions should not be reported as unused
    let diagnostics = get_unused_import_diagnostics("""
        using Base.Iterators: flatten
        macro myflatten(xs) :(flatten(\$(esc(xs)))) end
        """)
        @test isempty(diagnostics)
    end

    # Imports used in quoted expressions inside helper functions for macros
    let diagnostics = get_unused_import_diagnostics("""
        using Base.Iterators: flatten
        genfunc(xs) = :(flatten(\$(esc(xs))))
        macro myflatten(xs) genfunc(xs) end
        """)
        @test isempty(diagnostics)
    end

    # Imports used in @generated function with interpolation in dot expression
    let diagnostics = get_unused_import_diagnostics("""
        using Base.Iterators: flatten
        @generated function issue594(x)
            name = Symbol("field_name")
            return :(flatten(x.\$name))
        end
        """)
        @test isempty(diagnostics)
    end

    let diagnostics = get_unused_import_diagnostics("""
        \"\"\"
        Docstring for `module Issue586`
        \"\"\"
        module Issue586
        using Base: sin
        export sin
        issue586(x) = sin(x)
        end
        """)
        @test isempty(diagnostics)
    end

    # Import used in nested module should not suppress warning for top-level import
    @testset "module context tracking" begin
        script = """
        module A
        using Base: sin
        func(x) = sin(x)
        export func
        end

        using Base: sin
        """
        withscript(script) do script_path
            uri = filepath2uri(script_path)
            withserver() do (; writereadmsg, id_counter, server)
                JETLS.cache_file_info!(server, uri, 1, script)
                JETLS.cache_saved_file_info!(server.state, uri, script)
                JETLS.request_analysis!(server, uri, #=invalidate=#false; wait=true, notify_diagnostics=false)

                id = id_counter[] += 1
                (; raw_res) = writereadmsg(DocumentDiagnosticRequest(;
                    id,
                    params = DocumentDiagnosticParams(;
                        textDocument = TextDocumentIdentifier(; uri)
                    )))
                @test raw_res isa DocumentDiagnosticResponse
                @test raw_res.result isa RelatedFullDocumentDiagnosticReport
                unused_import_diags = filter(raw_res.result.items) do d
                    d.code == JETLS.LOWERING_UNUSED_IMPORT_CODE
                end
                @test length(unused_import_diags) == 1
                diagnostic = only(unused_import_diags)
                @test diagnostic.message == "Unused import `sin`"
                @test diagnostic.range.start.line == 6
            end
        end
    end
end

@testset "unreachable code detection" begin
    let diagnostics = get_lowered_diagnostics("""
        function foo()
            return 1
            x = 2
        end
        """)
        unreachable = filter(d -> d.code == JETLS.LOWERING_UNREACHABLE_CODE, diagnostics)
        @test length(unreachable) == 1
        @test only(unreachable).message == "Unreachable code"
        @test only(unreachable).range.start.line == 2
    end

    # multiple unreachable statements should be merged into one diagnostic
    let diagnostics = get_lowered_diagnostics("""
        function foo()
            return 1
            x = 2
            y = 3
        end
        """)
        unreachable = filter(d -> d.code == JETLS.LOWERING_UNREACHABLE_CODE, diagnostics)
        @test length(unreachable) == 1
        @test only(unreachable).range.start.line == 2
        @test only(unreachable).range.var"end".line == 3
    end

    # noreturn optimization: code after `throw` is unreachable
    let diagnostics = get_lowered_diagnostics("""
        function foo()
            throw(ErrorException("error"))
            x = 2
        end
        """)
        unreachable = filter(d -> d.code == JETLS.LOWERING_UNREACHABLE_CODE, diagnostics)
        @test length(unreachable) == 1
        @test only(unreachable).range.start.line == 2
    end

    # noreturn optimization: code after `error` is unreachable
    let diagnostics = get_lowered_diagnostics("""
        function foo()
            error("something went wrong")
            x = 2
        end
        """)
        unreachable = filter(d -> d.code == JETLS.LOWERING_UNREACHABLE_CODE, diagnostics)
        @test length(unreachable) == 1
        @test only(unreachable).range.start.line == 2
    end

    # noreturn optimization: nested noreturn call in argument position
    let diagnostics = get_lowered_diagnostics("""
        function foo(x)
            println(error(x))
            return x
        end
        """)
        unreachable = filter(d -> d.code == JETLS.LOWERING_UNREACHABLE_CODE, diagnostics)
        @test length(unreachable) == 1
        @test only(unreachable).range.start.line == 2
    end

    # noreturn optimization: assignment with noreturn RHS
    let diagnostics = get_lowered_diagnostics("""
        function foo(x)
            y = error(x)
            println(y)
        end
        """)
        unreachable = filter(d -> d.code == JETLS.LOWERING_UNREACHABLE_CODE, diagnostics)
        @test length(unreachable) == 1
        @test only(unreachable).range.start.line == 2
    end

    # noreturn optimization: code after `rethrow` in catch is unreachable
    let diagnostics = get_lowered_diagnostics("""
        function foo()
            try
                do_something()
            catch
                rethrow()
                println("unreachable")
            end
        end
        """)
        unreachable = filter(d -> d.code == JETLS.LOWERING_UNREACHABLE_CODE, diagnostics)
        @test length(unreachable) == 1
        @test only(unreachable).range.start.line == 5
    end

    # noreturn optimization: code after `exit` is unreachable
    let diagnostics = get_lowered_diagnostics("""
        function foo()
            exit(1)
            x = 2
        end
        """)
        unreachable = filter(d -> d.code == JETLS.LOWERING_UNREACHABLE_CODE, diagnostics)
        @test length(unreachable) == 1
        @test only(unreachable).range.start.line == 2
    end

    # no diagnostic when there's no unreachable code
    let diagnostics = get_lowered_diagnostics("""
        function foo()
            x = 2
            return x
        end
        """)
        unreachable = filter(d -> d.code == JETLS.LOWERING_UNREACHABLE_CODE, diagnostics)
        @test isempty(unreachable)
    end

    # return in a branch doesn't make subsequent code unreachable
    let diagnostics = get_lowered_diagnostics("""
        function foo(x)
            if x > 0
                return 1
            end
            return 0
        end
        """)
        unreachable = filter(d -> d.code == JETLS.LOWERING_UNREACHABLE_CODE, diagnostics)
        @test isempty(unreachable)
    end

    # return as the last statement in a function body: no unreachable code
    let diagnostics = get_lowered_diagnostics("""
        function foo()
            return 1
        end
        """)
        unreachable = filter(d -> d.code == JETLS.LOWERING_UNREACHABLE_CODE, diagnostics)
        @test isempty(unreachable)
    end

    # all branches return: code after if/else is unreachable
    let diagnostics = get_lowered_diagnostics("""
        function foo()
            if rand(Bool)
                println("true")
                return 1
            else
                println("false")
                return 2
            end
            println("fallback")
        end
        """)
        unreachable = filter(d -> d.code == JETLS.LOWERING_UNREACHABLE_CODE, diagnostics)
        @test length(unreachable) == 1
        @test only(unreachable).range.start.line == 8
    end

    # all branches throw: code after if/else is unreachable
    let diagnostics = get_lowered_diagnostics("""
        function foo(x)
            if x > 0
                error("positive")
            else
                error("non-positive")
            end
            println("unreachable")
        end
        """)
        unreachable = filter(d -> d.code == JETLS.LOWERING_UNREACHABLE_CODE, diagnostics)
        @test length(unreachable) == 1
        @test only(unreachable).range.start.line == 6
    end

    # mixed return/throw in branches: code after if/else is unreachable
    let diagnostics = get_lowered_diagnostics("""
        function foo(x)
            if x > 0
                return 1
            else
                error("error")
            end
            println("unreachable")
        end
        """)
        unreachable = filter(d -> d.code == JETLS.LOWERING_UNREACHABLE_CODE, diagnostics)
        @test length(unreachable) == 1
        @test only(unreachable).range.start.line == 6
    end

    # only one branch returns: code after if/else is still reachable
    let diagnostics = get_lowered_diagnostics("""
        function foo(x)
            if x > 0
                return 1
            else
                println("negative")
            end
            println("reachable")
        end
        """)
        unreachable = filter(d -> d.code == JETLS.LOWERING_UNREACHABLE_CODE, diagnostics)
        @test isempty(unreachable)
    end

    # all branches of if/elseif/else return: code after is unreachable
    let diagnostics = get_lowered_diagnostics("""
        function foo(x)
            if x > 0
                return 1
            elseif x < 0
                return -1
            else
                return 0
            end
            println("unreachable")
        end
        """)
        unreachable = filter(d -> d.code == JETLS.LOWERING_UNREACHABLE_CODE, diagnostics)
        @test length(unreachable) == 1
        @test only(unreachable).range.start.line == 8
    end

    # one elseif branch doesn't return: code after is reachable
    let diagnostics = get_lowered_diagnostics("""
        function foo(x)
            if x > 0
                return 1
            elseif x < 0
                println("negative")
            else
                return 0
            end
            println("reachable")
        end
        """)
        unreachable = filter(d -> d.code == JETLS.LOWERING_UNREACHABLE_CODE, diagnostics)
        @test isempty(unreachable)
    end

    # try/catch: both branches return → unreachable
    let diagnostics = get_lowered_diagnostics("""
        function foo()
            try
                return 1
            catch
                return 2
            end
            println("unreachable")
        end
        """)
        unreachable = filter(d -> d.code == JETLS.LOWERING_UNREACHABLE_CODE, diagnostics)
        @test length(unreachable) == 1
    end

    # try/catch: only catch returns → reachable
    let diagnostics = get_lowered_diagnostics("""
        function foo()
            try
                println("might throw")
            catch
                return 1
            end
            println("reachable")
        end
        """)
        unreachable = filter(d -> d.code == JETLS.LOWERING_UNREACHABLE_CODE, diagnostics)
        @test isempty(unreachable)
    end

    # try/finally: try body returns → unreachable
    let diagnostics = get_lowered_diagnostics("""
        function foo()
            try
                return 1
            finally
                println("cleanup")
            end
            println("unreachable")
        end
        """)
        unreachable = filter(d -> d.code == JETLS.LOWERING_UNREACHABLE_CODE, diagnostics)
        @test length(unreachable) == 1
    end

    # try/finally: try body doesn't return → reachable
    let diagnostics = get_lowered_diagnostics("""
        function foo()
            try
                println("might throw")
            finally
                println("cleanup")
            end
            println("reachable")
        end
        """)
        unreachable = filter(d -> d.code == JETLS.LOWERING_UNREACHABLE_CODE, diagnostics)
        @test isempty(unreachable)
    end

    # code after `continue` in a loop is unreachable
    let diagnostics = get_lowered_diagnostics("""
        function foo()
            for i = 1:10
                continue
                println(i)
            end
        end
        """)
        unreachable = filter(d -> d.code == JETLS.LOWERING_UNREACHABLE_CODE, diagnostics)
        @test length(unreachable) == 1
    end

    # code after `break` in a loop is unreachable
    let diagnostics = get_lowered_diagnostics("""
        function foo()
            for i = 1:10
                break
                println(i)
            end
        end
        """)
        unreachable = filter(d -> d.code == JETLS.LOWERING_UNREACHABLE_CODE, diagnostics)
        @test length(unreachable) == 1
    end

    # all branches break/continue: code after if/else in loop is unreachable
    let diagnostics = get_lowered_diagnostics("""
        function foo()
            for i = 1:10
                if i < 5
                    break
                else
                    continue
                end
                println("unreachable")
            end
        end
        """)
        unreachable = filter(d -> d.code == JETLS.LOWERING_UNREACHABLE_CODE, diagnostics)
        @test length(unreachable) == 1
    end

    # only one branch breaks: code after if/else in loop is reachable
    let diagnostics = get_lowered_diagnostics("""
        function foo()
            for i = 1:10
                if i < 5
                    break
                else
                    println("else")
                end
                println("reachable")
            end
        end
        """)
        unreachable = filter(d -> d.code == JETLS.LOWERING_UNREACHABLE_CODE, diagnostics)
        @test isempty(unreachable)
    end

    # code after `break` in a while loop is unreachable
    let diagnostics = get_lowered_diagnostics("""
        function foo()
            while true
                break
                println("unreachable")
            end
        end
        """)
        unreachable = filter(d -> d.code == JETLS.LOWERING_UNREACHABLE_CODE, diagnostics)
        @test length(unreachable) == 1
    end

    # code after `continue` in a while loop is unreachable
    let diagnostics = get_lowered_diagnostics("""
        function foo()
            i = 0
            while i < 10
                i += 1
                continue
                println("unreachable")
            end
        end
        """)
        unreachable = filter(d -> d.code == JETLS.LOWERING_UNREACHABLE_CODE, diagnostics)
        @test length(unreachable) == 1
    end

    # code after `return` in a while loop body is unreachable
    let diagnostics = get_lowered_diagnostics("""
        function foo()
            while true
                return 1
                println("unreachable")
            end
        end
        """)
        unreachable = filter(d -> d.code == JETLS.LOWERING_UNREACHABLE_CODE, diagnostics)
        @test length(unreachable) == 1
    end

    # Consecutive-run termination: when a reachable sibling appears between two would-be
    # unreachable runs (here `@label skip` is reachable via the `@goto skip` edge),
    # `analyze_unreachable_code!` must stop folding subsequent siblings into the
    # diagnostic's range when iteration hits a reachable child. Otherwise the merged range
    # would extend past the label all the way to the end of the block, swallowing the
    # genuinely reachable `println("after")` into the report.
    let diagnostics = get_lowered_diagnostics("""
        function foo()
            @goto skip
            println("unreachable")
            @label skip
            println("after")
        end
        """)
        unreachable = filter(d -> d.code == JETLS.LOWERING_UNREACHABLE_CODE, diagnostics)
        @test length(unreachable) == 1
        d = only(unreachable)
        # The diagnostic's range must end at line 3 (`println("unreachable")`),
        # not extend through line 4 (`@label skip`) or line 5 (`println("after")`).
        @test d.range.var"end".line == 2  # 0-indexed: line 3
    end

    # Source-order filter for lowering artifacts: `for i = 1:N; break; ...` lowers to a
    # do-while whose body block has the user body followed by an iterate-step assignment
    # (`(= next iterate(itr, state))`) whose source provenance points back to the loop
    # header `i = 1:N`. After `break`, the iterate-step is in an unreachable CFG block,
    # so without source-order filter `byte_range(child).start > terminator_end`,
    # `analyze_unreachable_code!` would emit a 2nd, baffling diagnostic pointing at the
    # loop header itself.
    let diagnostics = get_lowered_diagnostics("""
        function foo()
            for i = 1:10
                break
                println(i)
            end
        end
        """)
        unreachable = filter(d -> d.code == JETLS.LOWERING_UNREACHABLE_CODE, diagnostics)
        # Without the filter this would be 2 (println + the iterate-step whose provenance
        # is `i = 1:10`).
        @test length(unreachable) == 1
        d = only(unreachable)
        # The single diagnostic should point at println(i), not at the for-loop header.
        @test d.range.start.line == 3  # 0-indexed: line 4 (println(i))
    end

    # `@goto` nested inside a `return`'s expression keeps the matching `@label` reachable:
    # control transfers via the goto edge before the surrounding `return` would execute,
    # so post-label code stays live.
    let diagnostics = get_lowered_diagnostics("""
        function foo()
            return identity(@goto fallback)
            @label fallback
            println("Hit")
        end
        """)
        unreachable = filter(d -> d.code == JETLS.LOWERING_UNREACHABLE_CODE, diagnostics)
        @test isempty(unreachable)
    end
end

module soft_scope_module
    global x = 1
end

@testset "ambiguous soft scope detection" begin
    let diagnostics = get_lowered_diagnostics(soft_scope_module, """
        for _ = 1:10
            x = 2
        end
        """)
        ds = filter(d -> d.code == JETLS.LOWERING_AMBIGUOUS_SOFT_SCOPE_CODE, diagnostics)
        @test length(ds) == 1
        d = only(ds)
        @test d.severity == DiagnosticSeverity.Warning
        @test contains(d.message, "`x`")
        @test d.data isa AmbiguousSoftScopeData
        @test d.data.name == "x"
        # lowering/unused-local should also be reported
        unused = filter(
            d -> d.code == JETLS.LOWERING_UNUSED_LOCAL_CODE && contains(d.message, "`x`"),
            diagnostics)
        @test length(unused) == 1
    end

    # No diagnostic inside a function (hard scope)
    let diagnostics = get_lowered_diagnostics(soft_scope_module, """
        function f()
            for _ = 1:10
                x = 2
            end
        end
        """)
        ds = filter(d -> d.code == JETLS.LOWERING_AMBIGUOUS_SOFT_SCOPE_CODE, diagnostics)
        @test isempty(ds)
    end

    # No diagnostic when no global by that name exists
    let diagnostics = get_lowered_diagnostics(soft_scope_module, """
        for _ = 1:10
            y = 2
        end
        """)
        ds = filter(d -> d.code == JETLS.LOWERING_AMBIGUOUS_SOFT_SCOPE_CODE, diagnostics)
        @test isempty(ds)
    end

    # Explicit `global` suppresses the diagnostic
    let diagnostics = get_lowered_diagnostics(soft_scope_module, """
        for _ = 1:10
            global x = 2
        end
        """)
        ds = filter(d -> d.code == JETLS.LOWERING_AMBIGUOUS_SOFT_SCOPE_CODE, diagnostics)
        @test isempty(ds)
    end

    # while loop
    let diagnostics = get_lowered_diagnostics(soft_scope_module, """
        while true
            x = 2
            break
        end
        """)
        ds = filter(d -> d.code == JETLS.LOWERING_AMBIGUOUS_SOFT_SCOPE_CODE, diagnostics)
        @test length(ds) == 1
    end

    @testset "soft scope mode (notebook)" begin
        # With soft_scope=true, ambiguous soft scope diagnostic should not fire
        let diagnostics = get_lowered_diagnostics(soft_scope_module, """
            for _ = 1:10
                x = 2
            end
            """; soft_scope=true)
            ds = filter(d -> d.code == JETLS.LOWERING_AMBIGUOUS_SOFT_SCOPE_CODE, diagnostics)
            @test isempty(ds)
        end

        # Without soft_scope, the same code should produce the diagnostic
        let diagnostics = get_lowered_diagnostics(soft_scope_module, """
            for _ = 1:10
                x = 2
            end
            """; soft_scope=false)
            ds = filter(d -> d.code == JETLS.LOWERING_AMBIGUOUS_SOFT_SCOPE_CODE, diagnostics)
            @test length(ds) == 1
        end
    end
end

@testset "unresolved goto detection" begin
    # forward goto with matching label — no diagnostic
    let diagnostics = get_lowered_diagnostics("""
        begin
            @goto here
            println("dead")
            @label here
        end
        """)
        ds = filter(d -> d.code == JETLS.LOWERING_ERROR_CODE, diagnostics)
        @test isempty(ds)
    end

    # backward goto with matching label — no diagnostic
    let diagnostics = get_lowered_diagnostics("""
        function f()
            @label retry
            @goto retry
        end
        """)
        ds = filter(d -> d.code == JETLS.LOWERING_ERROR_CODE, diagnostics)
        @test isempty(ds)
    end

    let diagnostics = get_lowered_diagnostics("""
        begin
            @goto nonexist
            println("foo")
        end
        """)
        ds = filter(d -> d.code == JETLS.LOWERING_ERROR_CODE, diagnostics)
        @test length(ds) == 1
        d = only(ds)
        @test d.message == "label `nonexist` referenced but not defined"
        @test d.severity == LSP.DiagnosticSeverity.Error
        # range should cover the `nonexist` identifier
        @test d.range.start.line == 1
        @test d.range.start.character == sizeof("    @goto ")
        @test d.range.var"end".character == sizeof("    @goto nonexist")
    end

    # `@goto` cannot cross lambda boundaries — label in outer fn,
    # goto in inner closure should be reported as unresolved
    let diagnostics = get_lowered_diagnostics("""
        function f()
            @label outer
            g = () -> @goto outer
            g()
        end
        """)
        ds = filter(d -> d.code == JETLS.LOWERING_ERROR_CODE, diagnostics)
        @test length(ds) == 1
        @test only(ds).message == "label `outer` referenced but not defined"
    end

    # multiple unresolved gotos — each reported independently
    let diagnostics = get_lowered_diagnostics("""
        function f()
            @goto a
            @goto b
        end
        """)
        ds = filter(d -> d.code == JETLS.LOWERING_ERROR_CODE, diagnostics)
        @test length(ds) == 2
        msgs = sort([d.message for d in ds])
        @test msgs == [
            "label `a` referenced but not defined",
            "label `b` referenced but not defined",
        ]
    end
end

@testset "unused label detection" begin
    let diagnostics = get_lowered_diagnostics("""
        function f()
            @label unused
            return 1
        end
        """)
        ds = filter(d -> d.code == JETLS.LOWERING_UNUSED_LABEL_CODE, diagnostics)
        @test length(ds) == 1
        d = only(ds)
        @test d.message == "Unused label `unused`"
        @test d.severity == LSP.DiagnosticSeverity.Information
        @test !isnothing(d.tags) && LSP.DiagnosticTag.Unnecessary in d.tags
        @test d.range.start.line == 1
    end

    # referenced label — no diagnostic
    let diagnostics = get_lowered_diagnostics("""
        function f()
            @label loop
            @goto loop
        end
        """)
        ds = filter(d -> d.code == JETLS.LOWERING_UNUSED_LABEL_CODE, diagnostics)
        @test isempty(ds)
    end

    # mix — only the unreferenced one is reported
    let diagnostics = get_lowered_diagnostics("""
        function f()
            @label used
            @goto used
            @label spare
        end
        """)
        ds = filter(d -> d.code == JETLS.LOWERING_UNUSED_LABEL_CODE, diagnostics)
        @test length(ds) == 1
        @test only(ds).message == "Unused label `spare`"
    end

    # `@goto` cannot cross lambda boundaries — outer label is unused even
    # though an inner closure references the same name
    let diagnostics = get_lowered_diagnostics("""
        function f()
            @label outer
            g = () -> @goto outer
            g()
        end
        """)
        ds = filter(d -> d.code == JETLS.LOWERING_UNUSED_LABEL_CODE, diagnostics)
        @test length(ds) == 1
        @test only(ds).message == "Unused label `outer`"
    end
end

end # module test_lowering_diagnostics
