module test_diagnostics

include("setup.jl")
include("jsjl-utils.jl")

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
            writereadmsg(make_DidOpenTextDocumentNotification(uri, script_code))

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
                    if diag.source == JETLS.DIAGNOSTIC_SOURCE_LIVE
                        found_diagnostic = true
                        break
                    end
                end
                @test found_diagnostic
            end
        end
    end
end

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
                if (diag.source == JETLS.DIAGNOSTIC_SOURCE_SAVE &&
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
    scriptcode = """
    struct MyStruct
        property::Int
    end
    function field_error()
        x = MyStruct(42)
        return x.propert  # FieldError: type MyStruct has no field `propert`, available fields: `property` (JETLS inference/field-error)
    end

    f32(x::Float32) = sin(x) + cos(x)
    let x = rand()
        @show f32(x) # no matching method found `f32(::Float64)` (JETLS inference/method-error)
    end
    """

    # Use withscript to create a temporary file and run the test
    withscript(scriptcode) do script_path
        uri = filepath2uri(script_path)
        withserver() do (; writereadmsg)
            (; raw_res) = writereadmsg(make_DidOpenTextDocumentNotification(uri, scriptcode))

            @test raw_res isa PublishDiagnosticsNotification
            @test raw_res.params.uri == uri

            found_diagnostic1 = found_diagnostic2 = false
            for diag in raw_res.params.diagnostics
                if diag.source == JETLS.DIAGNOSTIC_SOURCE_SAVE
                    if diag.code == JETLS.INFERENCE_FIELD_ERROR_CODE && occursin("type MyStruct has no field `propert`, available fields: `property`", diag.message)
                        found_diagnostic1 = true
                    elseif diag.code == JETLS.INFERENCE_METHOD_ERROR_CODE && occursin("no matching method found `f32(::Float64)`", diag.message)
                        found_diagnostic2 = true
                    end
                end
            end
            @test found_diagnostic1
            @test found_diagnostic2
        end
    end
end

@testset "inference diagnostic (package analysis)" begin
    withpackage("TestPackageAnalysis", """
        module TestPackageAnalysis

        struct Hello
            who::String
        end
        function hello(x::Hello)
            return "Hello, \$(x.who)!"
        end

        module BadModule
            using ..TestPackageAnalysis: Hello
            function badhello1(x::Hello)
                return "Hello, \$(y.who)"  # `TestPackageAnalysis.BadModule.y` is not defined (JETLS inference/undef-global-var)
            end
            function badhello2(x::Hello)
                return _badhello2(x.who)  # no matching method found `_badhello2(::String)` (JETLS inference/method-error)
            end
            _badhello2(x::Hello) = "Hello, \$(x.who)"
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

            found_diagnostic1 = found_diagnostic2 = false
            for diag in raw_res.params.diagnostics
                if diag.source == JETLS.DIAGNOSTIC_SOURCE_SAVE
                    if diag.code == JETLS.INFERENCE_UNDEF_GLOBAL_VAR_CODE &&
                        occursin("`TestPackageAnalysis.BadModule.y` is not defined", diag.message)
                        # this also tests that JETLS doesn't show the nonsensical `var"..."`
                        # string caused by JET's internal details
                        found_diagnostic1 = true
                    end
                    if diag.code == JETLS.INFERENCE_METHOD_ERROR_CODE &&
                        occursin("no matching method found `_badhello2(::String)`", diag.message)
                        found_diagnostic2 = true
                    end
                end
            end
            @test found_diagnostic1
            @test found_diagnostic2
        end
    end
end

@testset "method overwrite diagnostic" begin
    withpackage("TestMethodOverwrite", """
        module TestMethodOverwrite

        function duplicate(x::Int)
            return x + 1
        end

        function duplicate(x::Int, y::Int=2)
            return x + y
        end

        end # module TestMethodOverwrite
        """) do pkg_path
        rootUri = filepath2uri(pkg_path)
        src_path = normpath(pkg_path, "src", "TestMethodOverwrite.jl")
        uri = filepath2uri(src_path)
        withserver(; rootUri) do (; writereadmsg)
            (; raw_res) = writereadmsg(make_DidOpenTextDocumentNotification(uri, read(src_path, String)))

            @test raw_res isa PublishDiagnosticsNotification
            @test raw_res.params.uri == uri

            found_diagnostic = false
            for diag in raw_res.params.diagnostics
                if (diag.source == JETLS.DIAGNOSTIC_SOURCE_SAVE &&
                    diag.code == JETLS.TOPLEVEL_METHOD_OVERWRITE_CODE &&
                    occursin("duplicate(::$Int)", diag.message) &&
                    occursin("overwritten", diag.message))
                    found_diagnostic = true
                    @test !isempty(diag.relatedInformation)
                    if !isempty(diag.relatedInformation)
                        related = first(diag.relatedInformation)
                        @test related.location.uri == uri
                        @test occursin("first method definition", related.message)
                    end
                    break
                end
            end
            @test found_diagnostic
        end
    end
end

@testset "abstract field diagnostic" begin
    withpackage("TestAbstractField", """
        module TestAbstractField

        struct BadStruct1
            xs::Vector{Integer}
        end

        struct BadStruct2
            xs::Vector{<:Integer}
        end

        end # module TestAbstractField
        """) do pkg_path
        rootUri = filepath2uri(pkg_path)
        src_path = normpath(pkg_path, "src", "TestAbstractField.jl")
        uri = filepath2uri(src_path)
        withserver(; rootUri) do (; writereadmsg)
            (; raw_res) = writereadmsg(make_DidOpenTextDocumentNotification(uri, read(src_path, String)))

            @test raw_res isa PublishDiagnosticsNotification
            @test raw_res.params.uri == uri

            found_diagnostic1 = false
            for diag in raw_res.params.diagnostics
                if (diag.source == JETLS.DIAGNOSTIC_SOURCE_SAVE &&
                    diag.code == JETLS.TOPLEVEL_ABSTRACT_FIELD_CODE &&
                    occursin("BadStruct1", diag.message) &&
                    occursin("xs::Vector{Integer}", diag.message))
                    found_diagnostic1 = true
                    break
                end
            end
            @test found_diagnostic1

            found_diagnostic2 = false
            for diag in raw_res.params.diagnostics
                if (diag.source == JETLS.DIAGNOSTIC_SOURCE_SAVE &&
                    diag.code == JETLS.TOPLEVEL_ABSTRACT_FIELD_CODE &&
                    occursin("BadStruct2", diag.message) &&
                    occursin("xs::Vector{<:Integer}", diag.message))
                    found_diagnostic2 = true
                    break
                end
            end
            @test found_diagnostic2
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
                @test raw_res.result isa RelatedFullDocumentDiagnosticReport
                @test isempty(raw_res.result.items)
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
                    # `check=false`: this call races with the main thread's
                    # `writereadmsg(DidOpen; ...)` below on `received_queue` drain.
                    # Checking here would spuriously see `DidOpen` still queued
                    # (CI flake). Emptiness is still verified at shutdown via
                    # `withserver`'s own `writereadmsg` calls.
                    (; raw_res) = writereadmsg(
                        DocumentDiagnosticRequest(;
                            id,
                            params = DocumentDiagnosticParams(;
                                textDocument = TextDocumentIdentifier(; uri)
                            ));
                        read = 2, check = false)
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
            # Send `DidOpen` after the handler has started polling but before
            # `get_file_info`'s `JETLS_TEST_MODE` timeout (1.0s) fires, so the
            # test exercises the "cache arrives during polling" path.
            sleep(0.5)
            writereadmsg(make_DidOpenTextDocumentNotification(uri, read(script_path, String)); read=0, check=false)
            wait(event)
            @test success
        end
    end
end

@testset "textDocument/diagnostic message cycle" begin
    script_code = "x = 1\n"
    withscript(script_code) do script_path
        uri = filepath2uri(script_path)
        withserver() do (; server, writemsg, writereadmsg, id_counter)
            (; raw_res) = writereadmsg(make_DidOpenTextDocumentNotification(uri, script_code))
            @test raw_res isa PublishDiagnosticsNotification

            # initial pull: no `previousResultId` → full report carrying a `resultId`
            local first_result_id::String
            let id = id_counter[] += 1
                (; raw_res) = writereadmsg(DocumentDiagnosticRequest(;
                    id,
                    params = DocumentDiagnosticParams(;
                        textDocument = TextDocumentIdentifier(; uri))))
                @test raw_res isa DocumentDiagnosticResponse
                @test raw_res.result isa RelatedFullDocumentDiagnosticReport
                @test raw_res.result.resultId isa String
                first_result_id = raw_res.result.resultId
            end

            # repeat pull with matching `previousResultId` → unchanged report
            let id = id_counter[] += 1
                (; raw_res) = writereadmsg(DocumentDiagnosticRequest(;
                    id,
                    params = DocumentDiagnosticParams(;
                        textDocument = TextDocumentIdentifier(; uri),
                        previousResultId = first_result_id)))
                @test raw_res isa DocumentDiagnosticResponse
                @test raw_res.result isa RelatedUnchangedDocumentDiagnosticReport
                @test raw_res.result.resultId == first_result_id
            end

            # editing the document bumps the version → `resultId` changes
            writemsg(make_DidChangeTextDocumentNotification(uri, "x = 2\n", #=version=#2))
            wait_for_file_cache_version(server.state, uri, 2)

            local second_result_id::String
            let id = id_counter[] += 1
                (; raw_res) = writereadmsg(DocumentDiagnosticRequest(;
                    id,
                    params = DocumentDiagnosticParams(;
                        textDocument = TextDocumentIdentifier(; uri),
                        previousResultId = first_result_id)))
                @test raw_res isa DocumentDiagnosticResponse
                @test raw_res.result isa RelatedFullDocumentDiagnosticReport
                @test raw_res.result.resultId isa String
                @test raw_res.result.resultId != first_result_id
                second_result_id = raw_res.result.resultId
            end

            # repeat pull after edit with new `resultId` → unchanged
            let id = id_counter[] += 1
                (; raw_res) = writereadmsg(DocumentDiagnosticRequest(;
                    id,
                    params = DocumentDiagnosticParams(;
                        textDocument = TextDocumentIdentifier(; uri),
                        previousResultId = second_result_id)))
                @test raw_res isa DocumentDiagnosticResponse
                @test raw_res.result isa RelatedUnchangedDocumentDiagnosticReport
                @test raw_res.result.resultId == second_result_id
            end

            # mismatched `previousResultId` → full report (does not crash)
            let id = id_counter[] += 1
                (; raw_res) = writereadmsg(DocumentDiagnosticRequest(;
                    id,
                    params = DocumentDiagnosticParams(;
                        textDocument = TextDocumentIdentifier(; uri),
                        previousResultId = "not-a-real-id")))
                @test raw_res isa DocumentDiagnosticResponse
                @test raw_res.result isa RelatedFullDocumentDiagnosticReport
                @test raw_res.result.resultId == second_result_id
            end

            # `:diagnostic` config change → `resultId` changes so the client-side cached
            # `Unchanged` response is invalidated when the server's `request_diagnostic_refresh!`
            # prompts the client to re-pull.
            let settings = Dict{String,Any}(
                    "diagnostic" => Dict{String,Any}("allow_unused_underscore" => false))
                (; raw_res) = writereadmsg(DidChangeConfigurationNotification(;
                        params = DidChangeConfigurationParams(; settings));
                    read = 2)
                @test count(msg -> msg isa ShowMessageNotification, raw_res) == 1
                @test count(msg -> msg isa PublishDiagnosticsNotification, raw_res) == 1
            end

            local third_result_id::String
            let id = id_counter[] += 1
                (; raw_res) = writereadmsg(DocumentDiagnosticRequest(;
                    id,
                    params = DocumentDiagnosticParams(;
                        textDocument = TextDocumentIdentifier(; uri),
                        previousResultId = second_result_id)))
                @test raw_res isa DocumentDiagnosticResponse
                @test raw_res.result isa RelatedFullDocumentDiagnosticReport
                @test raw_res.result.resultId != second_result_id
                third_result_id = raw_res.result.resultId
            end
            let id = id_counter[] += 1
                (; raw_res) = writereadmsg(DocumentDiagnosticRequest(;
                    id,
                    params = DocumentDiagnosticParams(;
                        textDocument = TextDocumentIdentifier(; uri),
                        previousResultId = third_result_id)))
                @test raw_res isa DocumentDiagnosticResponse
                @test raw_res.result isa RelatedUnchangedDocumentDiagnosticReport
                @test raw_res.result.resultId == third_result_id
            end
        end
    end
end

@testset "workspace/diagnostic message cycle" begin
    pkg_code = """
    module TestWorkspaceDiagnostic
    using Base: sum
    include("util.jl")
    end # module TestWorkspaceDiagnostic
    """
    util_code_initial = ""

    pkg_setup = function ()
        pkg_dir = dirname(Pkg.project().path)
        write(normpath(pkg_dir, "src", "util.jl"), util_code_initial)
    end
    withpackage("TestWorkspaceDiagnostic", pkg_code; pkg_setup) do pkg_path
        util_path = normpath(pkg_path, "src", "util.jl")
        util_uri = filepath2uri(util_path)
        rootUri = filepath2uri(pkg_path)
        main_path = normpath(pkg_path, "src", "TestWorkspaceDiagnostic.jl")
        main_uri = filepath2uri(main_path)
        # The lifecycle below relies on `diagnostic.all_files = true` (the schema default),
        # which is why no initial `settings` are passed. The final step flips it to `false`
        # to verify that workspace/diagnostic suppresses unsynced files.
        withserver(; rootUri) do (; server, writemsg, writereadmsg, id_counter)
            # Open util.jl (NOT main.jl) → triggers package analysis from main.jl entry.
            # With `diagnostic.all_files = true` (default), publishes happen for both files.
            let (; raw_res) = writereadmsg(
                    make_DidOpenTextDocumentNotification(util_uri, util_code_initial);
                    read = 2)
                @test all(msg -> msg isa PublishDiagnosticsNotification, raw_res)
                @test Set(msg.params.uri for msg in raw_res) == Set([main_uri, util_uri])
            end

            # Initial workspace pull → main.jl carries unused-import on `sum`;
            # util.jl is skipped (synced).
            local first_main_id::String
            let id = id_counter[] += 1
                (; raw_res) = writereadmsg(WorkspaceDiagnosticRequest(;
                    id,
                    params = WorkspaceDiagnosticParams(;
                        previousResultIds = PreviousResultId[])))
                @test raw_res isa WorkspaceDiagnosticResponse
                @test raw_res.result isa WorkspaceDiagnosticReport
                items = raw_res.result.items
                @test !any(item -> item.uri == util_uri, items)
                main_idx = findfirst(item -> item.uri == main_uri, items)
                @test main_idx !== nothing
                main_item = items[main_idx]
                @test main_item isa WorkspaceFullDocumentDiagnosticReport
                @test any(d -> d.code == JETLS.LOWERING_UNUSED_IMPORT_CODE, main_item.items)
                first_main_id = main_item.resultId
            end

            # Repeat pull with matching `previousResultIds` → unchanged report
            let id = id_counter[] += 1
                (; raw_res) = writereadmsg(WorkspaceDiagnosticRequest(;
                    id,
                    params = WorkspaceDiagnosticParams(;
                        previousResultIds = PreviousResultId[
                            PreviousResultId(; uri = main_uri, value = first_main_id)])))
                @test raw_res isa WorkspaceDiagnosticResponse
                items = raw_res.result.items
                main_idx = findfirst(item -> item.uri == main_uri, items)
                @test main_idx !== nothing
                main_item = items[main_idx]
                @test main_item isa WorkspaceUnchangedDocumentDiagnosticReport
                @test main_item.resultId == first_main_id
            end

            # Edit util.jl to use `sum`. `analyze_unused_imports!` reads the latest
            # `FileInfo` of every unit member each pull, so the next `workspace/diagnostic`
            # picks up the change without needing to re-trigger full-analysis.
            util_code_updated = "y = sum([1, 2, 3])\n"
            writemsg(make_DidChangeTextDocumentNotification(util_uri, util_code_updated, #=version=#2))
            wait_for_file_cache_version(server.state, util_uri, 2)

            # Workspace pull again → main.jl's `resultId` changed (because util.jl's
            # version is folded into main.jl's hash) and the unused-import is gone.
            let id = id_counter[] += 1
                (; raw_res) = writereadmsg(WorkspaceDiagnosticRequest(;
                    id,
                    params = WorkspaceDiagnosticParams(;
                        previousResultIds = PreviousResultId[
                            PreviousResultId(; uri = main_uri, value = first_main_id)])))
                @test raw_res isa WorkspaceDiagnosticResponse
                items = raw_res.result.items
                main_idx = findfirst(item -> item.uri == main_uri, items)
                @test main_idx !== nothing
                main_item = items[main_idx]
                @test main_item isa WorkspaceFullDocumentDiagnosticReport
                @test main_item.resultId != first_main_id
                @test !any(d -> d.code == JETLS.LOWERING_UNUSED_IMPORT_CODE, main_item.items)
            end

            # Disable `diagnostic.all_files` → workspace/diagnostic suppresses unsynced files.
            # Expect: 1 `ShowMessageNotification` for the config change + 1
            # `PublishDiagnosticsNotification` for the synced util.jl (sent by
            # `notify_diagnostics!`). main.jl's only diagnostic is the lowering
            # `unused-import` which is computed on demand and not stored in the analysis
            # cache, so the `ensure_cleared` branch does not emit a clearing publish for it.
            settings_off = Dict{String,Any}(
                "diagnostic" => Dict{String,Any}("all_files" => false),
            )
            let (; raw_res) = writereadmsg(DidChangeConfigurationNotification(;
                    params = DidChangeConfigurationParams(; settings = settings_off));
                    read = 2)
                @test count(msg -> msg isa ShowMessageNotification, raw_res) == 1
                util_publish = findfirst(msg -> msg isa PublishDiagnosticsNotification, raw_res)
                @test util_publish !== nothing
                @test raw_res[util_publish].params.uri == util_uri
            end

            # Workspace pull → main.jl is returned but with empty items.
            let id = id_counter[] += 1
                (; raw_res) = writereadmsg(WorkspaceDiagnosticRequest(;
                    id,
                    params = WorkspaceDiagnosticParams(;
                        previousResultIds = PreviousResultId[])))
                @test raw_res isa WorkspaceDiagnosticResponse
                items = raw_res.result.items
                main_idx = findfirst(item -> item.uri == main_uri, items)
                @test main_idx !== nothing
                main_item = items[main_idx]
                @test main_item isa WorkspaceFullDocumentDiagnosticReport
                @test isempty(main_item.items)
            end
        end
    end
end

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
        source = JETLS.DIAGNOSTIC_SOURCE_LIVE,
        code,
        codeDescription = JETLS.diagnostic_code_description(code))
end

function make_test_manager(config_dict::Dict{String,Any})
    lsp_config = JETLS.parse_config_from_dict(JETLS.JETLSConfig, config_dict)
    data = JETLS.ConfigManagerData(JETLS.EMPTY_CONFIG, lsp_config, nothing, true)
    return JETLS.ConfigManager(data)
end

@testset HierarchicalTestSet "diagnostic configuration" begin
    @testset "DiagnosticConfig parsing/validation" begin
        @testset "valid patterns" begin
            let config_raw = Dict{String,Any}()
                config = JETLS.parse_config_from_dict(JETLS.DiagnosticConfig, config_raw)
                @test config.enabled === nothing
                @test config.patterns === nothing
            end
            let config_raw = Dict{String,Any}("enabled" => false)
                config = JETLS.parse_config_from_dict(JETLS.DiagnosticConfig, config_raw)
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
                config = JETLS.parse_config_from_dict(JETLS.DiagnosticConfig, config_raw)
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
                config = JETLS.parse_config_from_dict(JETLS.DiagnosticConfig, config_raw)
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
                config = JETLS.parse_config_from_dict(JETLS.DiagnosticConfig, config_raw)
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
                config = JETLS.parse_config_from_dict(JETLS.DiagnosticConfig, config_raw)
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
                config = JETLS.parse_config_from_dict(JETLS.DiagnosticConfig, config_raw)
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
                config = JETLS.parse_config_from_dict(JETLS.DiagnosticConfig, config_raw)
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
                config = JETLS.parse_config_from_dict(JETLS.DiagnosticConfig, config_raw)
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
                @test_throws JETLS.InvalidKeyError JETLS.parse_config_from_dict(
                    JETLS.DiagnosticConfig, config_raw)
            end
            let config_raw = Dict{String,Any}(
                    "patterns" => [
                        Dict{String,Any}( # missing `pattern`
                            "match_by" => "code",
                            "match_type" => "literal",
                            "severity" => "info")
                    ])
                @test_throws JETLS.DiagnosticConfigError JETLS.parse_config_from_dict(
                    JETLS.DiagnosticConfig, config_raw)
            end
            let config_raw = Dict{String,Any}(
                    "patterns" => [
                        Dict{String,Any}( # missing `match_by`
                            "pattern" => "test",
                            "match_type" => "literal",
                            "severity" => "info")
                    ])
                @test_throws JETLS.DiagnosticConfigError JETLS.parse_config_from_dict(
                    JETLS.DiagnosticConfig, config_raw)
            end
            let config_raw = Dict{String,Any}(
                    "patterns" => [
                        Dict{String,Any}( # missing `match_type`
                            "pattern" => "test",
                            "match_by" => "code",
                            "severity" => "info")
                    ])
                @test_throws JETLS.DiagnosticConfigError JETLS.parse_config_from_dict(
                    JETLS.DiagnosticConfig, config_raw)
            end
            let config_raw = Dict{String,Any}(
                    "patterns" => [
                        Dict{String,Any}( # missing `severity`
                            "pattern" => "test",
                            "match_by" => "code",
                            "match_type" => "literal",)
                    ])
                @test_throws JETLS.DiagnosticConfigError JETLS.parse_config_from_dict(
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
                @test_throws JETLS.DiagnosticConfigError JETLS.parse_config_from_dict(
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
                @test_throws JETLS.DiagnosticConfigError JETLS.parse_config_from_dict(
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
                @test_throws JETLS.DiagnosticConfigError JETLS.parse_config_from_dict(
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
                @test_throws JETLS.DiagnosticConfigError JETLS.parse_config_from_dict(
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
                @test_throws JETLS.DiagnosticConfigError JETLS.parse_config_from_dict(
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
                @test_throws JETLS.DiagnosticConfigError JETLS.parse_config_from_dict(
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
                @test_throws JETLS.DiagnosticConfigError JETLS.parse_config_from_dict(
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
                @test_throws JETLS.DiagnosticConfigError JETLS.parse_config_from_dict(
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
                @test_throws JETLS.DiagnosticConfigError JETLS.parse_config_from_dict(
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
                @test_throws JETLS.DiagnosticConfigError JETLS.parse_config_from_dict(
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

        # diagnostics with severity=0 are filtered out when no pattern enables them
        let diagnostics = [
                make_test_diagnostic(;
                    code = JETLS.LOWERING_UNSORTED_IMPORT_NAMES_CODE,
                    severity = 0)
            ]
            manager = make_test_manager(Dict{String,Any}())
            uri = filepath2uri("/tmp/test.jl")
            JETLS.apply_diagnostic_config!(diagnostics, manager, uri, nothing)
            @test isempty(diagnostics)
        end

        # diagnostics with severity=0 can be enabled via patterns
        let diagnostics = [
                make_test_diagnostic(;
                    code = JETLS.LOWERING_UNSORTED_IMPORT_NAMES_CODE,
                    severity = 0)
            ]
            manager = make_test_manager(Dict{String,Any}(
                "diagnostic" => Dict{String,Any}(
                    "patterns" => [
                        Dict{String,Any}(
                            "pattern" => "lowering/unsorted-import-names",
                            "match_by" => "code",
                            "match_type" => "literal",
                            "severity" => "hint")
                    ])))
            uri = filepath2uri("/tmp/test.jl")
            JETLS.apply_diagnostic_config!(diagnostics, manager, uri, nothing)
            @test length(diagnostics) == 1
            @test only(diagnostics).severity == DiagnosticSeverity.Hint
        end
    end
end

end # module test_diagnostics
