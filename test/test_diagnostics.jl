module test_diagnostics

include("setup.jl")
include("jsjl_utils.jl")

using Test
using JETLS
using JETLS: JL, JS
using JETLS.LSP
using JETLS.URIs2

@testset "syntax error diagnostics" begin
    # Test with code that has syntax errors
    script_code = """
    function foo()
        x = 1
        if x > 0
            println("Positive")
        # Missing end
    end
    """

    withscript(script_code) do script_path
        uri = filepath2uri(script_path)
        withserver() do (; writereadmsg, id_counter)
            (; raw_res) = writereadmsg(
                make_DidOpenTextDocumentNotification(uri, script_code);
                read = 0) # `textDocument/publishDiagnostics` is not notified by the server due to the existence of syntax errors

            let id = id_counter[] += 1
                (; raw_res) = writereadmsg(DocumentDiagnosticRequest(;
                    id,
                    params = DocumentDiagnosticParams(;
                        textDocument = TextDocumentIdentifier(; uri)
                    )))
                @test raw_res isa DocumentDiagnosticResponse
                @test raw_res.result isa RelatedFullDocumentDiagnosticReport

                found_diagnostic = false
                for diag in raw_res.result.items
                    if diag.source == JETLS.SYNTAX_DIAGNOSTIC_SOURCE
                        found_diagnostic = true
                        break
                    end
                end
                @test found_diagnostic
            end
        end
    end
end

macro m_throw(x)
    throw("show this error message")
end
macro m_gen_invalid(n)
    :([return i for i in 1:$n])
end
@testset "JuliaLowering error diagnostics" begin
    @testset "lowering error diagnostics" begin
        ps = parsedstream("macro foo(x, y) \$(x) end")
        st = jlparse(ps)
        fi = JETLS.FileInfo(#=version=#0, ps)
        diagnostics = JETLS.lowering_diagnostics(st[1], @__MODULE__, fi)
        @test length(diagnostics) == 1
        diagnostic = only(diagnostics)
        @test diagnostic.source == JETLS.LOWERING_DIAGNOSTIC_SOURCE
        @test diagnostic.message == "`\$` expression outside string or quote block"
    end

    @testset "macro not found error diagnostics" begin
        ps = parsedstream("x = @notexisting 42")
        st = jlparse(ps)
        fi = JETLS.FileInfo(#=version=#0, ps)
        diagnostics = JETLS.lowering_diagnostics(st[1], @__MODULE__, fi)
        @test length(diagnostics) == 1
        diagnostic = only(diagnostics)
        @test diagnostic.source == JETLS.LOWERING_DIAGNOSTIC_SOURCE
        @test diagnostic.message == "Macro name `@notexisting` not found"
        @test diagnostic.range.start.line == 0
        @test diagnostic.range.start.character == sizeof("x = @")
        @test diagnostic.range.var"end".line == 0
        @test diagnostic.range.var"end".character == sizeof("x = @notexisting")
    end

    @testset "string macro not found error diagnostics" begin
        ps = parsedstream("x = notexisting\"string\"")
        st = jlparse(ps)
        fi = JETLS.FileInfo(#=version=#0, ps)
        diagnostics = JETLS.lowering_diagnostics(st[1], @__MODULE__, fi)
        @test length(diagnostics) == 1
        diagnostic = only(diagnostics)
        @test diagnostic.source == JETLS.LOWERING_DIAGNOSTIC_SOURCE
        @test diagnostic.message == "Macro name `@notexisting_str` not found"
        @test diagnostic.range.start.line == 0
        @test diagnostic.range.start.character == sizeof("x = ")
        @test diagnostic.range.var"end".line == 0
        @test diagnostic.range.var"end".character == sizeof("x = notexisting")
    end

    @testset "macro expansion error diagnostics" begin
        ps = parsedstream("x = @m_throw 42")
        st = jlparse(ps)
        fi = JETLS.FileInfo(#=version=#0, ps)
        diagnostics = JETLS.lowering_diagnostics(st[1], @__MODULE__, fi)
        @test length(diagnostics) == 1
        diagnostic = only(diagnostics)
        @test diagnostic.source == JETLS.LOWERING_DIAGNOSTIC_SOURCE
        @test diagnostic.message == "Error expanding macro\n\"show this error message\""
        @test diagnostic.range.start.line == 0
        @test diagnostic.range.start.character == sizeof("x = ")
        @test diagnostic.range.var"end".line == 0
        @test diagnostic.range.var"end".character == sizeof("x = @m_throw 42")
    end

    @testset "lowering error within macro expanded code" begin
        ps = parsedstream("""let x = 42
            println(x)
            @m_gen_invalid x
        end""")
        st = jlparse(ps)
        fi = JETLS.FileInfo(#=version=#0, ps)
        diagnostics = JETLS.lowering_diagnostics(st[1], @__MODULE__, fi)
        @test length(diagnostics) == 1
        diagnostic = only(diagnostics)
        @test diagnostic.source == JETLS.LOWERING_DIAGNOSTIC_SOURCE
        @test diagnostic.message == "`return` not allowed inside comprehension or generator"
        @test diagnostic.range.start.line == 2
        @test diagnostic.range.var"end".line == 2
    end
end

@testset "top-level error diagnostics" begin
    # Test with code that has syntax errors
    scriptcode = """
    include("nonexistent.jl")
    """

    # Use withscript to create a temporary file and run the test
    withscript(scriptcode) do script_path
        uri = filepath2uri(script_path)
        withserver() do (; writereadmsg, id_counter)
            (; raw_res) = writereadmsg(make_DidOpenTextDocumentNotification(uri, scriptcode))

            @test raw_res isa PublishDiagnosticsNotification
            @test raw_res.params.uri == uri

            found_diagnostic = false
            for diag in raw_res.params.diagnostics
                if (diag.source == JETLS.TOPLEVEL_DIAGNOSTIC_SOURCE &&
                    diag.range.start.line == 0)
                    found_diagnostic = true
                    break
                end
            end
            @test found_diagnostic
        end
    end
end

@testset "inference diagnostics (script analysis)" begin
    # Test with code that has syntax errors
    scriptcode = """
    struct Hello
        who::String
    end
    function hello(x::Hello)
        return "Hello, \$(x.who)!"
    end
    """

    # Use withscript to create a temporary file and run the test
    withscript(scriptcode) do script_path
        uri = filepath2uri(script_path)
        withserver() do (; writereadmsg, id_counter)
            (; raw_res) = writereadmsg(make_DidOpenTextDocumentNotification(uri, scriptcode))

            @test raw_res isa PublishDiagnosticsNotification
            @test raw_res.params.uri == uri

            found_diagnostic = false
            for diag in raw_res.params.diagnostics
                if diag.source == JETLS.INFERENCE_DIAGNOSTIC_SOURCE
                    found_diagnostic = true
                    break
                end
            end
            # NOTE Currently the script analysis doesn't set `analyze_from_definitions=true`
            @test_broken found_diagnostic
        end
    end
end

@testset "inference diagnostics (package analysis)" begin
    pkg_code = """
    module TestPackageAnalysis
    export hello

    struct Hello
        who::String
    end
    function hello(x::Hello)
        return "Hello, \$(x.who)!"
    end

    module BadModule
        using ..TestPackageAnalysis: Hello
        function badhello(x::Hello)
            # Undefined variable 'y'
            return "Hello, \$(y.who)"
        end
    end

    end # module TestPackageAnalysis
    """
    withpackage("TestPackageAnalysis", pkg_code) do pkg_path
        rootUri = filepath2uri(pkg_path)
        src_path = normpath(pkg_path, "src", "TestPackageAnalysis.jl")
        uri = filepath2uri(src_path)
        withserver(; rootUri) do (; writereadmsg, id_counter)
            (; raw_res) = writereadmsg(make_DidOpenTextDocumentNotification(uri, read(src_path, String)))

            @test raw_res isa PublishDiagnosticsNotification
            @test raw_res.params.uri == uri
            # @test raw_res.params.version == 1

            found_diagnostic = false
            for diag in raw_res.params.diagnostics
                if (diag.source == JETLS.INFERENCE_DIAGNOSTIC_SOURCE &&
                    # this also tests that JETLS doesn't show the nonsensical `var"..."`
                    # string caused by JET's internal details
                    occursin("`TestPackageAnalysis.BadModule.y` is not defined", diag.message))
                    found_diagnostic = true
                    break
                end
            end
            @test found_diagnostic
        end
    end
end

@testset "file cache error handling" begin
    # Test requesting diagnostics for a file that hasn't been opened
    # (i.e., no file cache exists)
    withscript("# some code") do script_path
        uri = filepath2uri(script_path)
        withserver() do (; writereadmsg, id_counter)
            # Don't send DidOpenTextDocument notification, so no file cache is created
            let id = id_counter[] += 1
                (; raw_res) = writereadmsg(DocumentDiagnosticRequest(;
                    id,
                    params = DocumentDiagnosticParams(;
                        textDocument = TextDocumentIdentifier(; uri)
                    )))
                @test raw_res isa DocumentDiagnosticResponse
                @test raw_res.result === nothing
                @test raw_res.error isa ResponseError
                @test raw_res.error.code == ErrorCodes.RequestFailed
                @test occursin("File cache for $uri is not found", raw_res.error.message)
                @test raw_res.error.data isa DiagnosticServerCancellationData
                @test raw_res.error.data.retriggerRequest === true
            end
        end
    end
end

end # module test_diagnostics
