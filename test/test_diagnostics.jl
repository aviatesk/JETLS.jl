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
            # `textDocument/publishDiagnostics` is notified, but the diagnostics of syntax errors wouldn't be published
            (; raw_res) = writereadmsg(
                make_DidOpenTextDocumentNotification(uri, script_code))

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
                    if diag.source == JETLS.DIAGNOSTIC_SOURCE
                        found_diagnostic = true
                        break
                    end
                end
                @test found_diagnostic
            end
        end
    end
end

@testset "lowering diagnostics" include("test_lowering_diagnostics.jl")

@testset "top-level error diagnostics" begin
    # Test with code that has syntax errors
    scriptcode = """
    include("nonexistent.jl")
    """

    # Use withscript to create a temporary file and run the test
    withscript(scriptcode) do script_path
        uri = filepath2uri(script_path)
        withserver() do (; writereadmsg)
            (; raw_res) = writereadmsg(make_DidOpenTextDocumentNotification(uri, scriptcode))

            @test raw_res isa PublishDiagnosticsNotification
            @test raw_res.params.uri == uri

            found_diagnostic = false
            for diag in raw_res.params.diagnostics
                if (diag.source == JETLS.DIAGNOSTIC_SOURCE &&
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
        withserver() do (; writereadmsg)
            (; raw_res) = writereadmsg(make_DidOpenTextDocumentNotification(uri, scriptcode))

            @test raw_res isa PublishDiagnosticsNotification
            @test raw_res.params.uri == uri

            found_diagnostic = false
            for diag in raw_res.params.diagnostics
                if diag.source == JETLS.DIAGNOSTIC_SOURCE
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
    withpackage("TestPackageAnalysis", """
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
        """) do pkg_path
        rootUri = filepath2uri(pkg_path)
        src_path = normpath(pkg_path, "src", "TestPackageAnalysis.jl")
        uri = filepath2uri(src_path)
        withserver(; rootUri) do (; writereadmsg)
            (; raw_res) = writereadmsg(make_DidOpenTextDocumentNotification(uri, read(src_path, String)))

            @test raw_res isa PublishDiagnosticsNotification
            @test raw_res.params.uri == uri

            found_diagnostic = false
            for diag in raw_res.params.diagnostics
                if (diag.source == JETLS.DIAGNOSTIC_SOURCE &&
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

@testset "Empty package analysis" begin
    withpackage("TestEmptyPackageAnalysis", "module TestEmptyPackageAnalysis end") do pkg_path
        rootUri = filepath2uri(pkg_path)
        src_path = normpath(pkg_path, "src", "TestEmptyPackageAnalysis.jl")
        uri = filepath2uri(src_path)
        withserver(; rootUri) do (; writereadmsg)
            (; raw_res) = writereadmsg(make_DidOpenTextDocumentNotification(uri, read(src_path, String)))
            @test raw_res isa PublishDiagnosticsNotification
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

using JETLS.Configurations: Configurations

@testset "diagnostic configuration" begin
    @testset "JETLS.parse_diagnostic_codes_config" begin
        let codes_raw = Dict{String,Any}("lowering/unused-argument" => Dict("severity" => 1))
            config = Configurations.from_dict(JETLS.DiagnosticCodesConfig, codes_raw)
            @test config.var"lowering/unused-argument".enabled === nothing
            @test config.var"lowering/unused-argument".severity == DiagnosticSeverity.Error
        end

        let codes_raw = Dict{String,Any}("lowering/*" => Dict("enabled" => true, "severity" => 3))
            config = Configurations.from_dict(JETLS.DiagnosticCodesConfig, codes_raw)
            @test config.var"lowering/unused-argument".enabled === true
            @test config.var"lowering/unused-argument".severity == DiagnosticSeverity.Information
            @test config.var"lowering/unused-local".enabled === true
            @test config.var"lowering/unused-local".severity == DiagnosticSeverity.Information
        end

        let codes_raw = Dict{String,Any}("lowering/*" => Dict("enabled" => false),
                             "lowering/unused-argument" => Dict("enabled" => true))
            config = Configurations.from_dict(JETLS.DiagnosticCodesConfig, codes_raw)
            @test config.var"lowering/unused-local".enabled === false
            @test config.var"lowering/unused-argument".enabled === true
        end

        let codes_raw = Dict{String,Any}()
            config = Configurations.from_dict(JETLS.DiagnosticCodesConfig, codes_raw)
            @test config == JETLS.default_config(JETLS.DiagnosticCodesConfig)
        end

        let codes_raw = Dict{String,Any}("unexisting/error" => Dict("severity" => 1))
            @test_throws JETLS.DiagnosticConfigError Configurations.from_dict(JETLS.DiagnosticCodesConfig, codes_raw)
        end
        let codes_raw = Dict{String,Any}("lowering/*" => "invalid")
            @test_throws JETLS.DiagnosticConfigError Configurations.from_dict(JETLS.DiagnosticCodesConfig, codes_raw)
        end
        let codes_raw = Dict{String,Any}("lowering/*" => Dict("invalid" => 1))
            @test_throws Configurations.InvalidKeyError Configurations.from_dict(JETLS.DiagnosticCodesConfig, codes_raw)
        end
        let codes_raw = Dict{String,Any}("lowering/*" => Dict("severity" => 0))
            @test_throws JETLS.DiagnosticConfigError Configurations.from_dict(JETLS.DiagnosticCodesConfig, codes_raw)
        end
        let codes_raw = Dict{String,Any}("lowering/*" => Dict("severity" => "unexisting"))
            @test_throws JETLS.DiagnosticConfigError Configurations.from_dict(JETLS.DiagnosticCodesConfig, codes_raw)
        end
        let codes_raw = Dict{String,Any}("unexisting/*" => "invalid")
            @test_throws JETLS.DiagnosticConfigError Configurations.from_dict(JETLS.DiagnosticCodesConfig, codes_raw)
        end
        let codes_raw = Dict{String,Any}("unexisting/error" => Dict("severity" => 1))
            @test_throws JETLS.DiagnosticConfigError Configurations.from_dict(JETLS.DiagnosticCodesConfig, codes_raw)
        end
        let codes_raw = Dict{String,Any}("inference/undef-local-var" => Dict("unexisting" => 1))
            @test_throws Configurations.InvalidKeyError Configurations.from_dict(JETLS.DiagnosticCodesConfig, codes_raw)
        end
    end
end

end # module test_diagnostics
