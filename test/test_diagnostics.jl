module test_diagnostics

include("setup.jl")

using Test
using JETLS
using JETLS: JL, JS
using JETLS.LSP

function make_DidOpenTextDocumentNotification(uri, text;
                                              languageId = "julia",
                                              version = 1)
    return DidOpenTextDocumentNotification(;
        params = DidOpenTextDocumentParams(;
            textDocument = TextDocumentItem(;
                uri, text, languageId, version)))
end

@testset "syntax error diagnostics" begin
    # Test with code that has syntax errors
    scriptcode = """
    function foo()
        x = 1
        if x > 0
            println("Positive")
        # Missing end for the if statement
    end
    """

    withscript(scriptcode) do script_path
        uri = string(JETLS.URIs2.filepath2uri(script_path))
        withserver() do in, _, _, sent_queue, id_counter
            writemsg(in, make_DidOpenTextDocumentNotification(uri, scriptcode))

            out = take_with_timeout!(sent_queue)
            @test out isa PublishDiagnosticsNotification
            @test out.params.uri == uri

            found_diagnostic = false
            for diag in out.params.diagnostics
                if diag.source == JETLS.SYNTAX_DIAGNOSTIC_SOURCE
                    found_diagnostic = true
                    break
                end
            end
            @test found_diagnostic
        end
    end
end

@testset "top-level error diagnostics" begin
    # Test with code that has syntax errors
    scriptcode = """
    include("nonexistent.jl")
    """

    # Use withscript to create a temporary file and run the test
    withscript(scriptcode) do script_path
        uri = string(JETLS.URIs2.filepath2uri(script_path))
        withserver() do in, _, _, sent_queue, id_counter
            writemsg(in, make_DidOpenTextDocumentNotification(uri, scriptcode))

            out = take_with_timeout!(sent_queue)
            @test out isa PublishDiagnosticsNotification
            @test out.params.uri == uri

            found_diagnostic = false
            for diag in out.params.diagnostics
                if diag.source == JETLS.TOPLEVEL_DIAGNOSTIC_SOURCE
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
        uri = string(JETLS.URIs2.filepath2uri(script_path))
        withserver() do in, _, _, sent_queue, id_counter
            writemsg(in, make_DidOpenTextDocumentNotification(uri, scriptcode))

            out = take_with_timeout!(sent_queue)
            @test out isa PublishDiagnosticsNotification
            @test out.params.uri == uri

            found_diagnostic = false
            for diag in out.params.diagnostics
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
        rootUri = string(JETLS.URIs2.filepath2uri(pkg_path))
        src_path = normpath(pkg_path, "src", "TestPackageAnalysis.jl")
        uri = string(JETLS.URIs2.filepath2uri(src_path))
        withserver(; rootUri) do in, _, _, sent_queue, id_counter
            writemsg(in, make_DidOpenTextDocumentNotification(uri, read(src_path, String)))

            out = take_with_timeout!(sent_queue; limit=300) # wait for 5 minutes
            @test out isa PublishDiagnosticsNotification
            @test out.params.uri == uri
            # @test out.params.version == 1

            found_diagnostic = false
            for diag in out.params.diagnostics
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

end # module test_diagnostics
