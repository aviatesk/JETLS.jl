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

function make_test_diagnostic(; code::String, severity::DiagnosticSeverity.Ty)
    return Diagnostic(;
        range = Range(; start = Position(; line=0, character=0),
            var"end" = Position(; line=0, character=10)),
        severity,
        message = "Test diagnostic",
        source = JETLS.DIAGNOSTIC_SOURCE,
        code,
        codeDescription = JETLS.diagnostic_code_description(code))
end

@testset "diagnostic configuration" begin
    @testset "JETLS.DiagnosticCodesConfig" begin
        let codes_raw = Dict{String,Any}("lowering/unused-argument" => 1)
            config = Configurations.from_dict(JETLS.DiagnosticCodesConfig, codes_raw)
            @test config.var"lowering/unused-argument" == DiagnosticSeverity.Error
        end

        let codes_raw = Dict{String,Any}("lowering/*" => 3)
            config = Configurations.from_dict(JETLS.DiagnosticCodesConfig, codes_raw)
            @test config.var"lowering/unused-argument" == DiagnosticSeverity.Information
            @test config.var"lowering/unused-local" == DiagnosticSeverity.Information
        end

        let codes_raw = Dict{String,Any}(
                    "lowering/*" => 0,
                    "lowering/unused-argument" => "warning")
            config = Configurations.from_dict(JETLS.DiagnosticCodesConfig, codes_raw)
            @test config.var"lowering/unused-local" == 0
            @test config.var"lowering/unused-argument" == DiagnosticSeverity.Warning
        end

        let codes_raw = Dict{String,Any}(
                    "lowering/*" => "warn",
                    "lowering/unused-argument" => "info")
            config = Configurations.from_dict(JETLS.DiagnosticCodesConfig, codes_raw)
            @test config.var"lowering/unused-local" === DiagnosticSeverity.Warning
            @test config.var"lowering/unused-argument" == DiagnosticSeverity.Information
        end

        let codes_raw = Dict{String,Any}(
                    "*" => "hint",
                    "lowering/*" => "error",
                    "lowering/unused-argument" => "off")
            config = Configurations.from_dict(JETLS.DiagnosticCodesConfig, codes_raw)
            @test config.var"syntax/parse-error" == DiagnosticSeverity.Hint
            @test config.var"lowering/unused-local" == DiagnosticSeverity.Error
            @test config.var"lowering/unused-argument" == 0
            @test config.var"testrunner/test-failure" == DiagnosticSeverity.Hint
        end

        let codes_raw = Dict{String,Any}()
            config = Configurations.from_dict(JETLS.DiagnosticCodesConfig, codes_raw)
            @test config == JETLS.default_config(JETLS.DiagnosticCodesConfig)
        end

        let codes_raw = Dict{String,Any}("unexisting/error" => 1)
            @test_throws JETLS.DiagnosticConfigError Configurations.from_dict(JETLS.DiagnosticCodesConfig, codes_raw)
        end
        let codes_raw = Dict{String,Any}("lowering/*" => "invalid")
            @test_throws JETLS.DiagnosticConfigError Configurations.from_dict(JETLS.DiagnosticCodesConfig, codes_raw)
        end
        let codes_raw = Dict{String,Any}("lowering/*" => 5)
            @test_throws JETLS.DiagnosticConfigError Configurations.from_dict(JETLS.DiagnosticCodesConfig, codes_raw)
        end
        let codes_raw = Dict{String,Any}("lowering/*" => Dict("unexisting_key" => "unexisting_value"))
            @test_throws JETLS.DiagnosticConfigError Configurations.from_dict(JETLS.DiagnosticCodesConfig, codes_raw)
        end
        let codes_raw = Dict{String,Any}("unexisting/*" => "warning")
            @test_throws JETLS.DiagnosticConfigError Configurations.from_dict(JETLS.DiagnosticCodesConfig, codes_raw)
        end
    end

    @testset "JETLS.DiagnosticConfig" begin
        let raw = Dict{String,Any}("codes" =>
                Dict{String,Any}(
                    "*" => "hint",
                    "lowering/*" => "error",
                    "lowering/unused-argument" => "off"))
            config = Configurations.from_dict(JETLS.DiagnosticConfig, raw)
            @test config.enabled === nothing
            @test config.codes.var"syntax/parse-error" == DiagnosticSeverity.Hint
            @test config.codes.var"lowering/unused-local" == DiagnosticSeverity.Error
            @test config.codes.var"lowering/unused-argument" == 0
            @test config.codes.var"testrunner/test-failure" == DiagnosticSeverity.Hint
        end
    end

    @testset "apply_diagnostic_config!" begin
        diagnostics = [
            make_test_diagnostic(;
                code = JETLS.LOWERING_UNUSED_ARGUMENT_CODE,
                severity = DiagnosticSeverity.Information),
            make_test_diagnostic(;
                code = JETLS.LOWERING_UNUSED_LOCAL_CODE,
                severity = DiagnosticSeverity.Information),
            make_test_diagnostic(;
                code = JETLS.SYNTAX_DIAGNOSTIC_CODE,
                severity = DiagnosticSeverity.Error),
            make_test_diagnostic(;
                code = JETLS.TOPLEVEL_ERROR_CODE,
                severity = DiagnosticSeverity.Error),
            make_test_diagnostic(;
                code = JETLS.INFERENCE_UNDEF_GLOBAL_VAR_CODE,
                severity = DiagnosticSeverity.Error)
        ]
        config_dict = Dict{String,Any}(
            "diagnostics" => Dict{String,Any}(
                "codes" => Dict{String,Any}(
                    "*" => "hint",
                    "lowering/*" => "warning",
                    "lowering/unused-argument" => "off",
                    "inference/*" => "info")))
        manager = let
            lsp_config = JETLS.Configurations.from_dict(JETLS.JETLSConfig, config_dict)
            data = JETLS.ConfigManagerData(JETLS.DEFAULT_CONFIG, JETLS.EMPTY_CONFIG, lsp_config, nothing)
            JETLS.ConfigManager(data)
        end
        JETLS.apply_diagnostic_config!(diagnostics, manager)

        @test length(diagnostics) == 4
        let idx = findfirst(d -> d.code == JETLS.LOWERING_UNUSED_LOCAL_CODE, diagnostics)
            @test idx !== nothing
            @test diagnostics[idx].severity == DiagnosticSeverity.Warning
        end
        let idx = findfirst(d -> d.code == JETLS.SYNTAX_DIAGNOSTIC_CODE, diagnostics)
            @test idx !== nothing
            @test diagnostics[idx].severity == DiagnosticSeverity.Hint
        end
        let idx = findfirst(d -> d.code == JETLS.TOPLEVEL_ERROR_CODE, diagnostics)
            @test idx !== nothing
            @test diagnostics[idx].severity == DiagnosticSeverity.Hint
        end
        let idx = findfirst(d -> d.code == JETLS.INFERENCE_UNDEF_GLOBAL_VAR_CODE, diagnostics)
            @test idx !== nothing
            @test diagnostics[idx].severity == DiagnosticSeverity.Information
        end
        @test findfirst(d -> d.code == JETLS.LOWERING_UNUSED_ARGUMENT_CODE, diagnostics) === nothing
    end
end

end # module test_diagnostics
