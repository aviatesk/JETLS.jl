module test_diagnostics

include("setup.jl")
include("jsjl_utils.jl")

using Test
using JETLS
using JETLS: JL, JS
using JETLS.LSP
using JETLS.URIs2
using JETLS.Glob

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

@testset "lowering diagnostic" include("test_lowering_diagnostics.jl")

@testset "top-level error diagnostic" begin
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

@testset "inference diagnostic (script analysis)" begin
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

@testset "inference diagnostic (package analysis)" begin
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

@testset "File cache error handling" begin
    # Test requesting diagnostics for a file whose cache has not been populated yet
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

@testset "Delayed file cache handling" begin
    # Test requesting diagnostics for a file whose cache has not been populated yet
    withscript("# some code") do script_path
        uri = filepath2uri(script_path)
        withserver() do (; writereadmsg, id_counter)
            # Don't send DidOpenTextDocument notification, so no file cache is created
            event = Base.Event()
            local success::Bool = false
            let id = id_counter[] += 1
                Threads.@spawn try
                    (; raw_res) = writereadmsg(
                        DocumentDiagnosticRequest(;
                            id,
                            params = DocumentDiagnosticParams(;
                                textDocument = TextDocumentIdentifier(; uri)
                            ));
                        read = 2)
                    @test any(raw_res) do @nospecialize res
                        res isa DocumentDiagnosticResponse &&
                        res.result isa RelatedFullDocumentDiagnosticReport
                    end
                    @test any(raw_res) do @nospecialize res
                        res isa PublishDiagnosticsNotification
                    end
                    success = true
                catch e
                    Base.showerror(stderr, e, catch_backtrace())
                finally
                    notify(event)
                end
            end
            sleep(5.0)
            writereadmsg(make_DidOpenTextDocumentNotification(uri, read(script_path, String)); read=0, check=false)
            wait(event)
            @test success
        end
    end
end

using JETLS.Configurations: Configurations

function make_test_diagnostic(;
        code::String,
        severity::DiagnosticSeverity.Ty,
        message::String = "Test diagnostic"
    )
    return Diagnostic(;
        range = Range(;
            start = Position(; line=0, character=0),
            var"end" = Position(; line=0, character=10)),
        severity,
        message,
        source = JETLS.DIAGNOSTIC_SOURCE,
        code,
        codeDescription = JETLS.diagnostic_code_description(code))
end

function make_test_manager(config_dict::Dict{String,Any})
    lsp_config = JETLS.Configurations.from_dict(JETLS.JETLSConfig, config_dict)
    data = JETLS.ConfigManagerData(JETLS.EMPTY_CONFIG, lsp_config, nothing, true)
    return JETLS.ConfigManager(data)
end

@testset "diagnostic configuration" begin
    @testset "DiagnosticConfig parsing/validation" begin
        @testset "valid patterns" begin
            let config_raw = Dict{String,Any}()
                config = Configurations.from_dict(JETLS.DiagnosticConfig, config_raw)
                @test config.enabled === nothing
                @test config.patterns === nothing
            end
            let config_raw = Dict{String,Any}("enabled" => false)
                config = Configurations.from_dict(JETLS.DiagnosticConfig, config_raw)
                @test config.enabled === false
                @test config.patterns === nothing
            end

            let config_raw = Dict{String,Any}(
                    "patterns" => [
                        Dict{String,Any}(
                            "pattern" => "lowering/unused-argument",
                            "match_by" => "code",
                            "match_type" => "literal",
                            "severity" => "hint")
                    ])
                config = Configurations.from_dict(JETLS.DiagnosticConfig, config_raw)
                @test config.enabled === nothing
                @test config.patterns !== nothing
                @test length(config.patterns) == 1
                pattern = only(config.patterns)
                @test pattern.match_by == "code"
                @test pattern.pattern == "lowering/unused-argument"
                @test pattern.severity == DiagnosticSeverity.Hint
                @test pattern.match_type == "literal"
                @test pattern.path === nothing
            end
            let config_raw = Dict{String,Any}(
                    "patterns" => [
                        Dict{String,Any}(
                            "pattern" => "lowering/unused-argument",
                            "match_by" => "code",
                            "match_type" => "literal",
                            "severity" => 4)
                    ])
                config = Configurations.from_dict(JETLS.DiagnosticConfig, config_raw)
                pattern = only(config.patterns)
                @test pattern.severity == DiagnosticSeverity.Hint
            end

            let config_raw = Dict{String,Any}(
                    "patterns" => [
                        Dict{String,Any}(
                            "pattern" => "inference/.*",
                            "match_by" => "code",
                            "match_type" => "regex",
                            "severity" => "off")
                    ])
                config = Configurations.from_dict(JETLS.DiagnosticConfig, config_raw)
                pattern = only(config.patterns)
                @test pattern.match_type == "regex"
                @test pattern.pattern isa Regex
                @test pattern.pattern.pattern == "inference/.*"
                @test pattern.severity == 0
            end

            let config_raw = Dict{String,Any}(
                    "patterns" => [
                        Dict{String,Any}(
                            "pattern" => "Macro name `@namespace` not found",
                            "match_by" => "message",
                            "match_type" => "literal",
                            "severity" => "info")
                    ])
                config = Configurations.from_dict(JETLS.DiagnosticConfig, config_raw)
                pattern = only(config.patterns)
                @test pattern.match_by == "message"
                @test pattern.pattern == "Macro name `@namespace` not found"
                @test pattern.match_type == "literal"
            end

            let config_raw = Dict{String,Any}(
                    "patterns" => [
                        Dict{String,Any}(
                            "pattern" => "Macro name `.*` not found",
                            "match_by" => "message",
                            "match_type" => "regex",
                            "severity" => "hint")
                    ])
                config = Configurations.from_dict(JETLS.DiagnosticConfig, config_raw)
                pattern = only(config.patterns)
                @test pattern.match_by == "message"
                @test pattern.pattern isa Regex
                @test pattern.pattern.pattern == "Macro name `.*` not found"
                @test pattern.severity == DiagnosticSeverity.Hint
                @test pattern.match_type == "regex"
            end

            let config_raw = Dict{String,Any}(
                    "enabled" => true,
                    "patterns" => [
                        Dict{String,Any}(
                            "pattern" => "test1",
                            "match_by" => "code",
                            "match_type" => "literal",
                            "severity" => "info"),
                        Dict{String,Any}(
                            "pattern" => "test2",
                            "match_by" => "message",
                            "match_type" => "literal",
                            "severity" => "hint")
                    ])
                config = Configurations.from_dict(JETLS.DiagnosticConfig, config_raw)
                @test config.enabled === true
                @test config.patterns !== nothing
                @test length(config.patterns) == 2
            end

            let config_raw = Dict{String,Any}(
                    "patterns" => [
                        Dict{String,Any}(
                            "pattern" => "lowering/unused-argument",
                            "match_by" => "code",
                            "match_type" => "literal",
                            "severity" => "hint",
                            "path" => "test/**/*.jl")
                    ])
                config = Configurations.from_dict(JETLS.DiagnosticConfig, config_raw)
                pattern = only(config.patterns)
                @test pattern.path !== nothing
                @test pattern.path isa Glob.FilenameMatch
                @test occursin(pattern.path, "test/dir/testfile.jl")
                # `**` should also match empty path segments (requires the `d = PATHNAME` flag)
                @test occursin(pattern.path, "test/testfile.jl")
                # `*` and `**` should not match leading dots in path segments (requires the `p = PERIOD` flag)
                @test !occursin(pattern.path, "test/.hidden/testfile.jl")
            end
        end

        @testset "invalid patterns" begin
            let config_raw = Dict{String,Any}(
                    "invalid" => [])
                @test_throws Configurations.InvalidKeyError Configurations.from_dict(
                    JETLS.DiagnosticConfig, config_raw)
            end
            let config_raw = Dict{String,Any}(
                    "patterns" => [
                        Dict{String,Any}( # missing `pattern`
                            "match_by" => "code",
                            "match_type" => "literal",
                            "severity" => "info")
                    ])
                @test_throws JETLS.DiagnosticConfigError Configurations.from_dict(
                    JETLS.DiagnosticConfig, config_raw)
            end
            let config_raw = Dict{String,Any}(
                    "patterns" => [
                        Dict{String,Any}( # missing `match_by`
                            "pattern" => "test",
                            "match_type" => "literal",
                            "severity" => "info")
                    ])
                @test_throws JETLS.DiagnosticConfigError Configurations.from_dict(
                    JETLS.DiagnosticConfig, config_raw)
            end
            let config_raw = Dict{String,Any}(
                    "patterns" => [
                        Dict{String,Any}( # missing `match_type`
                            "pattern" => "test",
                            "match_by" => "code",
                            "severity" => "info")
                    ])
                @test_throws JETLS.DiagnosticConfigError Configurations.from_dict(
                    JETLS.DiagnosticConfig, config_raw)
            end
            let config_raw = Dict{String,Any}(
                    "patterns" => [
                        Dict{String,Any}( # missing `severity`
                            "pattern" => "test",
                            "match_by" => "code",
                            "match_type" => "literal",)
                    ])
                @test_throws JETLS.DiagnosticConfigError Configurations.from_dict(
                    JETLS.DiagnosticConfig, config_raw)
            end
            let config_raw = Dict{String,Any}(
                    "patterns" => [
                        Dict{String,Any}(
                            "pattern" => "test",
                            "match_by" => "invalid",
                            "severity" => "info",
                            "match_type" => "literal")
                    ])
                @test_throws JETLS.DiagnosticConfigError Configurations.from_dict(
                    JETLS.DiagnosticConfig, config_raw)
            end
            let config_raw = Dict{String,Any}(
                    "patterns" => [
                        Dict{String,Any}(
                            "pattern" => "test",
                            "match_by" => Dict{String,Any}(),
                            "severity" => "info",
                            "match_type" => "literal")
                    ])
                @test_throws JETLS.DiagnosticConfigError Configurations.from_dict(
                    JETLS.DiagnosticConfig, config_raw)
            end
            let config_raw = Dict{String,Any}(
                    "patterns" => [
                        Dict{String,Any}(
                            "pattern" => "test",
                            "match_by" => "code",
                            "severity" => "invalid",
                            "match_type" => "literal")
                    ])
                @test_throws JETLS.DiagnosticConfigError Configurations.from_dict(
                    JETLS.DiagnosticConfig, config_raw)
            end
            let config_raw = Dict{String,Any}(
                    "patterns" => [
                        Dict{String,Any}(
                            "pattern" => "test",
                            "match_by" => "code",
                            "severity" => 5,
                            "match_type" => "literal")
                    ])
                @test_throws JETLS.DiagnosticConfigError Configurations.from_dict(
                    JETLS.DiagnosticConfig, config_raw)
            end
            let config_raw = Dict{String,Any}(
                    "patterns" => [
                        Dict{String,Any}(
                            "pattern" => "test",
                            "match_by" => "code",
                            "severity" => Dict{String,Any}(),
                            "match_type" => "literal")
                    ])
                @test_throws JETLS.DiagnosticConfigError Configurations.from_dict(
                    JETLS.DiagnosticConfig, config_raw)
            end
            let config_raw = Dict{String,Any}(
                    "patterns" => [
                        Dict{String,Any}(
                            "pattern" => "test",
                            "match_by" => "code",
                            "match_type" => "invalid",
                            "severity" => "info")
                    ])
                @test_throws JETLS.DiagnosticConfigError Configurations.from_dict(
                    JETLS.DiagnosticConfig, config_raw)
            end
            let config_raw = Dict{String,Any}(
                    "patterns" => [
                        Dict{String,Any}(
                            "pattern" => "test",
                            "match_by" => "code",
                            "match_type" => Dict{String,Any}(),
                            "severity" => "info")
                    ])
                @test_throws JETLS.DiagnosticConfigError Configurations.from_dict(
                    JETLS.DiagnosticConfig, config_raw)
            end
            let config_raw = Dict{String,Any}(
                    "patterns" => [
                        Dict{String,Any}(
                            "pattern" => "[invalid", # regex parse failure
                            "match_by" => "code",
                            "match_type" => "regex",
                            "severity" => "info")
                    ])
                @test_throws JETLS.DiagnosticConfigError Configurations.from_dict(
                    JETLS.DiagnosticConfig, config_raw)
            end
            let config_raw = Dict{String,Any}(
                    "patterns" => [
                        Dict{String,Any}(
                            "pattern" => "test",
                            "match_by" => "code",
                            "match_type" => "literal",
                            "severity" => "info",
                            "invalid_key" => "value")
                    ])
                @test_throws JETLS.DiagnosticConfigError Configurations.from_dict(
                    JETLS.DiagnosticConfig, config_raw)
            end
            let config_raw = Dict{String,Any}(
                    "patterns" => [
                        Dict{String,Any}(
                            "pattern" => "test",
                            "match_by" => "code",
                            "match_type" => "literal",
                            "severity" => "hint",
                            "path" => 123)
                    ])
                @test_throws JETLS.DiagnosticConfigError Configurations.from_dict(
                    JETLS.DiagnosticConfig, config_raw)
            end
        end
    end

    @testset "apply_diagnostic_config!" begin
        let diagnostics = [
                make_test_diagnostic(;
                    code = JETLS.LOWERING_UNUSED_ARGUMENT_CODE,
                    severity = DiagnosticSeverity.Information),
                make_test_diagnostic(;
                    code = JETLS.INFERENCE_UNDEF_GLOBAL_VAR_CODE,
                    severity = DiagnosticSeverity.Warning),
            ]
            manager = make_test_manager(Dict{String,Any}(
                "diagnostic" => Dict{String,Any}(
                    "patterns" => [
                        Dict{String,Any}(
                            "pattern" => "lowering/unused-argument",
                            "match_by" => "code",
                            "match_type" => "literal",
                            "severity" => "hint"),
                        Dict{String,Any}(
                            "pattern" => "inference/.*",
                            "match_by" => "code",
                            "match_type" => "regex",
                            "severity" => "off"),
                    ])))
            uri = filepath2uri("/tmp/test.jl")
            JETLS.apply_diagnostic_config!(diagnostics, manager, uri, nothing)
            @test length(diagnostics) == 1
            @test only(diagnostics).code == JETLS.LOWERING_UNUSED_ARGUMENT_CODE
            @test only(diagnostics).severity == DiagnosticSeverity.Hint
        end

        let diagnostics = [
                make_test_diagnostic(;
                    code = JETLS.LOWERING_MACRO_EXPANSION_ERROR_CODE,
                    severity = DiagnosticSeverity.Error,
                    message = "Macro name `@namespace` not found")
            ]
            manager = make_test_manager(Dict{String,Any}(
                "diagnostic" => Dict{String,Any}(
                    "patterns" => [
                        Dict{String,Any}(
                            "pattern" => "Macro name `@namespace` not found",
                            "match_by" => "message",
                            "match_type" => "literal",
                            "severity" => "info"),
                    ])))
            uri = filepath2uri("/tmp/test.jl")
            JETLS.apply_diagnostic_config!(diagnostics, manager, uri, nothing)
            @test length(diagnostics) == 1
            @test only(diagnostics).severity == DiagnosticSeverity.Information
        end

        let diagnostics = [
                make_test_diagnostic(;
                    code = JETLS.LOWERING_MACRO_EXPANSION_ERROR_CODE,
                    severity = DiagnosticSeverity.Error,
                    message = "Macro name `@interface` not found")
            ]
            manager = make_test_manager(Dict{String,Any}(
                "diagnostic" => Dict{String,Any}(
                    "patterns" => [
                        Dict{String,Any}(
                            "pattern" => "Macro name `.*` not found",
                            "match_by" => "message",
                            "match_type" => "regex",
                            "severity" => "hint"),
                    ])))
            uri = filepath2uri("/tmp/test.jl")
            JETLS.apply_diagnostic_config!(diagnostics, manager, uri, nothing)
            @test length(diagnostics) == 1
            @test only(diagnostics).severity == DiagnosticSeverity.Hint
        end

        let diagnostics = [
                make_test_diagnostic(;
                    code = JETLS.LOWERING_UNUSED_ARGUMENT_CODE,
                    severity = DiagnosticSeverity.Information)
            ]
            manager = make_test_manager(Dict{String,Any}(
                "diagnostic" => Dict{String,Any}(
                    "enabled" => false)))
            uri = filepath2uri("/tmp/test.jl")
            JETLS.apply_diagnostic_config!(diagnostics, manager, uri, nothing)
            @test isempty(diagnostics)
        end

        # message-based patterns should have higher priority than code-based patterns
        let diagnostics = [
                make_test_diagnostic(;
                    code = JETLS.LOWERING_MACRO_EXPANSION_ERROR_CODE,
                    severity = DiagnosticSeverity.Error,
                    message = "Macro name `@interface` not found")
            ]
            manager = make_test_manager(Dict{String,Any}(
                "diagnostic" => Dict{String,Any}(
                    "patterns" => [
                        Dict{String,Any}(
                            "pattern" => "lowering/macro-expansion-error",
                            "match_by" => "code",
                            "match_type" => "literal",
                            "severity" => "hint"),
                        Dict{String,Any}(
                            "pattern" => "Macro name `@interface` not found",
                            "match_by" => "message",
                            "match_type" => "literal",
                            "severity" => "info"),
                    ])))
            uri = filepath2uri("/tmp/test.jl")
            JETLS.apply_diagnostic_config!(diagnostics, manager, uri, nothing)
            @test length(diagnostics) == 1
            @test only(diagnostics).severity == DiagnosticSeverity.Information
        end

        @testset "path matching" begin
            let diagnostics = [
                    make_test_diagnostic(;
                        code = JETLS.LOWERING_MACRO_EXPANSION_ERROR_CODE,
                        severity = DiagnosticSeverity.Error,
                        message = "Macro name `@namespace` not found")
                ]
                manager = make_test_manager(Dict{String,Any}(
                    "diagnostic" => Dict{String,Any}(
                        "patterns" => [
                            Dict{String,Any}(
                                "pattern" => "Macro name `@namespace` not found",
                                "match_by" => "message",
                                "match_type" => "literal",
                                "severity" => "info",
                                "path" => "LSP/src/**/*.jl")
                        ])))
                uri = filepath2uri("/path/to/LSP/src/subdir/protocol.jl")
                JETLS.apply_diagnostic_config!(diagnostics, manager, uri, "/path/to")
                @test length(diagnostics) == 1
                @test only(diagnostics).severity == DiagnosticSeverity.Information
            end

            let diagnostics = [
                    make_test_diagnostic(;
                        code = JETLS.LOWERING_MACRO_EXPANSION_ERROR_CODE,
                        severity = DiagnosticSeverity.Error,
                        message = "Macro name `@namespace` not found")
                ]
                manager = make_test_manager(Dict{String,Any}(
                    "diagnostic" => Dict{String,Any}(
                        "patterns" => [
                            Dict{String,Any}(
                                "pattern" => "Macro name `@namespace` not found",
                                "match_by" => "message",
                                "match_type" => "literal",
                                "severity" => "info",
                                "path" => "LSP/src/**/*.jl")
                        ])))
                uri = filepath2uri("/path/to/other/src/protocol.jl")
                JETLS.apply_diagnostic_config!(diagnostics, manager, uri, "/path/to")
                @test length(diagnostics) == 1
                @test only(diagnostics).severity == DiagnosticSeverity.Error
            end

            let diagnostics = [
                    make_test_diagnostic(;
                        code = JETLS.LOWERING_UNUSED_ARGUMENT_CODE,
                        severity = DiagnosticSeverity.Information)
                ]
                manager = make_test_manager(Dict{String,Any}(
                    "diagnostic" => Dict{String,Any}(
                        "patterns" => [
                            Dict{String,Any}(
                                "pattern" => ".*",
                                "match_by" => "code",
                                "match_type" => "regex",
                                "severity" => "off",
                                "path" => "test/**/*.jl")
                        ])))
                uri = filepath2uri("/path/to/test/foo/bar.jl")
                JETLS.apply_diagnostic_config!(diagnostics, manager, uri, "/path/to")
                @test isempty(diagnostics)
            end
        end
    end
end

end # module test_diagnostics
