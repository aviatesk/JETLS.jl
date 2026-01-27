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
    st0 = JETLS.build_syntax_tree(fi)
    @assert JS.kind(st0) === JS.K"toplevel"
    return JETLS.lowering_diagnostics(uri, fi, mod, st0[1]; kwargs...)
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
                JETLS.request_analysis!(server, uri, #=onsave=#false; wait=true, notify_diagnostics=false)

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
end

macro m_throw(x)
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
        @test diagnostic.message == "`\$` expression outside string or quote block"
    end

    @testset "toplevel lowering error diagnostics" begin
        server = JETLS.Server()
        uri = URI("file://$(@__FILE__)")
        text = """
        macro foo(x, y) \$(x) end
        macro bar(x, y) \$(x) end
        """
        fi = JETLS.cache_file_info!(server, uri, #=version=#0, text)
        diagnostics = JETLS.toplevel_lowering_diagnostics(server, uri, fi)
        @test length(diagnostics) == 2
        @test count(diagnostics) do diagnostic
            diagnostic.source == JETLS.DIAGNOSTIC_SOURCE_LIVE &&
            diagnostic.message == "`\$` expression outside string or quote block" &&
            diagnostic.range.start.line == 0 &&
            diagnostic.range.var"end".line == 0
        end == 1
        @test count(diagnostics) do diagnostic
            diagnostic.source == JETLS.DIAGNOSTIC_SOURCE_LIVE &&
            diagnostic.message == "`\$` expression outside string or quote block" &&
            diagnostic.range.start.line == 1 &&
            diagnostic.range.var"end".line == 1
        end == 1
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

    @test_broken isempty(get_lowered_diagnostics(@__MODULE__, """
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
            @test length(diagnostics) == 1
            diagnostic = only(diagnostics)
            @test diagnostic.code == JETLS.LOWERING_UNDEF_LOCAL_VAR_CODE
            @test diagnostic.severity == DiagnosticSeverity.Warning
            @test diagnostic.message == "Variable `y` is used before it is defined"
            @test diagnostic.range.start.line == 1
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

end # module test_lowering_diagnostics
