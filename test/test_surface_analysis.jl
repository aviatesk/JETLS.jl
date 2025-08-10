module test_surface_analysis

using Test
using JETLS
using JETLS: JL, JS

include(normpath(pkgdir(JETLS), "test", "setup.jl"))
include(normpath(pkgdir(JETLS), "test", "jsjl_utils.jl"))

module lowering_module end
function get_lowered_diagnostics(text::AbstractString)
    ps = JETLS.ParseStream!(text)
    fi = JETLS.FileInfo(#=version=#0, ps)
    st0 = JETLS.build_tree!(JL.SyntaxTree, fi)
    @assert JS.kind(st0) === JS.K"toplevel"
    return JETLS.lowering_diagnostics(st0[1], lowering_module, fi)
end

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
            ys = [x for (i, x) in enumarate(x)]
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
            """)
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
                JETLS.cache_file_info!(server.state, uri, 1, script)
                JETLS.cache_saved_file_info!(server.state, uri, script)
                JETLS.initiate_analysis_unit!(server, uri)

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

    length_utf16(s::AbstractString) = sum(c::Char -> codepoint(c) < 0x10000 ? 1 : 2, collect(s); init=0)
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
end

end # module test_surface_analysis
