module test_config_deprecation

using Test
using JETLS
using JETLS: TS
using JETLS.LSP
using JETLS.LSP.URIs2

include(normpath(pkgdir(JETLS), "test", "setup.jl"))

const DEPRECATIONS = JETLS.DeprecatedConfigurations([
    ["testrunner", "executable"] => nothing,
    ["inlay_hint", "block_end_min_lines"] => ["inlay_hint", "block_end", "min_lines"],
])
const VALUE_DEPRECATIONS = JETLS.DeprecatedConfigurationValues([
    ["full_analysis", "auto_instantiate"] => (true => "always"),
])

function fix_deprecated(text::String, path::Vector{String})
    doc = TS.parse(text)
    deprecated = only(
        d for d in JETLS.find_deprecated_configs(doc, DEPRECATIONS, VALUE_DEPRECATIONS)
        if (d isa JETLS.DeprecatedConfigKey ? d.old_path : d.path) == path)
    edit = JETLS.deprecated_config_fix(doc, deprecated)::TS.SourceEdit
    return TS.apply(text, edit), JETLS.deprecated_config_fix_title(doc, deprecated)
end

@testset "fixes of deprecated keys and values" begin
    removal = ["testrunner", "executable"]
    rename = ["inlay_hint", "block_end_min_lines"]
    value = ["full_analysis", "auto_instantiate"]
    cases = [
        ("[testrunner]\nexecutable = \"x\" # unused\njulia_args = []\n", removal) =>
            "[testrunner]\njulia_args = []\n",
        ("formatter = \"Runic\"\n\n[testrunner]\nexecutable = \"x\"\n", removal) =>
            "formatter = \"Runic\"\n",
        ("testrunner.executable = \"x\"\n", removal) => "",
        ("testrunner = { executable = \"x\", julia_args = [] }\n", removal) =>
            "testrunner = { julia_args = [] }\n",
        ("[inlay_hint]\nblock_end_min_lines = 7 # lines\n", rename) =>
            "[inlay_hint]\nblock_end.min_lines = 7 # lines\n",
        ("inlay_hint.block_end_min_lines = 7\n", rename) =>
            "inlay_hint.block_end.min_lines = 7\n",
        ("[inlay_hint]\nblock_end_min_lines = 7\nblock_end.min_lines = 9\n", rename) =>
            "[inlay_hint]\nblock_end.min_lines = 9\n",
        ("[inlay_hint]\nblock_end_min_lines = 7\n\n[inlay_hint.block_end]\nenabled = false\n",
            rename) =>
            "[inlay_hint]\n\n[inlay_hint.block_end]\nenabled = false\nmin_lines = 7\n",
        ("[full_analysis]\nauto_instantiate = true # old\n", value) =>
            "[full_analysis]\nauto_instantiate = \"always\" # old\n",
        ("full_analysis = { auto_instantiate = true }\n", value) =>
            "full_analysis = { auto_instantiate = \"always\" }\n",
    ]
    for ((text, path), expected) in cases
        fixed, _ = fix_deprecated(text, path)
        @test fixed == expected
    end
    @test last(fix_deprecated("testrunner.executable = \"x\"\n", removal)) ==
        "Remove deprecated `testrunner.executable`"
    @test last(fix_deprecated("inlay_hint.block_end_min_lines = 7\n", rename)) ==
        "Replace `inlay_hint.block_end_min_lines` with `inlay_hint.block_end.min_lines`"
    @test last(fix_deprecated(
        "[inlay_hint]\nblock_end_min_lines = 7\nblock_end.min_lines = 9\n", rename)) ==
        "Remove deprecated `inlay_hint.block_end_min_lines`"
    @test last(fix_deprecated("full_analysis.auto_instantiate = true\n", value)) ==
        "Replace `true` with `\"always\"`"
    let doc = TS.parse("full_analysis.auto_instantiate = 1\n")
        @test isempty(JETLS.find_deprecated_configs(doc, DEPRECATIONS, VALUE_DEPRECATIONS))
    end
end

@testset "`fix_deprecated_configs`" begin
    let text = """
            # JETLS configuration
            [full_analysis]
            auto_instantiate = true

            [testrunner]
            executable = "x"

            [inlay_hint]
            block_end_min_lines = 7
            """
        @test JETLS.fix_deprecated_configs(text, DEPRECATIONS, VALUE_DEPRECATIONS) == """
            # JETLS configuration
            [full_analysis]
            auto_instantiate = "always"

            [inlay_hint]
            block_end.min_lines = 7
            """
    end
    @test JETLS.fix_deprecated_configs(
        "[testrunner]\njulia_args = []\n", DEPRECATIONS, VALUE_DEPRECATIONS) === nothing
    @test JETLS.fix_deprecated_configs(
        "[testrunner\nexecutable = 1\n", DEPRECATIONS, VALUE_DEPRECATIONS) === nothing
end

@testset "deprecated setting diagnostics" begin
    let diagnostic = only(JETLS.deprecated_config_diagnostics(
            "testrunner.executable = \"x\"\n", PositionEncodingKind.UTF16))
        @test diagnostic.range == Range(;
            start = Position(; line = 0, character = 0),
            var"end" = Position(; line = 0, character = 21))
        @test diagnostic.code == JETLS.CONFIG_DEPRECATED_KEY_CODE
        @test diagnostic.severity == DiagnosticSeverity.Warning
        @test diagnostic.source == JETLS.DIAGNOSTIC_SOURCE_EXTRA
        @test diagnostic.tags == [DiagnosticTag.Deprecated]
        @test diagnostic.message ==
            JETLS.deprecated_config_key_message(["testrunner", "executable"], nothing)
    end
    let diagnostic = only(JETLS.deprecated_config_diagnostics(
            "[full_analysis]\nauto_instantiate = false\n", PositionEncodingKind.UTF16))
        @test diagnostic.range == Range(;
            start = Position(; line = 1, character = 19),
            var"end" = Position(; line = 1, character = 24))
        @test diagnostic.code == JETLS.CONFIG_DEPRECATED_VALUE_CODE
        @test diagnostic.tags == [DiagnosticTag.Deprecated]
        @test diagnostic.message == JETLS.deprecated_config_value_message(
            ["full_analysis", "auto_instantiate"], false, "never")
    end
    let prefix = "testrunner = { env = { \"😀\" = \"1\" }, "
        diagnostic = only(JETLS.deprecated_config_diagnostics(
            "# 雪\n" * prefix * "executable = \"x\" }\n", PositionEncodingKind.UTF16))
        character = length(transcode(UInt16, prefix))
        @test diagnostic.range == Range(;
            start = Position(; line = 1, character),
            var"end" = Position(; line = 1, character = character + 10))
    end
    @test isempty(JETLS.deprecated_config_diagnostics(
        "[full_analysis]\nauto_instantiate = \"always\"\n", PositionEncodingKind.UTF16))
    @test isempty(JETLS.deprecated_config_diagnostics(
        "[testrunner\n", PositionEncodingKind.UTF16))
end

function nested_config(path::Vector{String}, @nospecialize(value))
    config = Dict{String,Any}(path[end] => value)
    for key in Iterators.reverse(path[1:end-1])
        config = Dict{String,Any}(key => config)
    end
    return config
end

function config_parse_error(config::Dict{String,Any})
    try
        JETLS.parse_config_from_dict(JETLS.JETLSConfig, config)
    catch err
        return err
    end
    return nothing
end

# Registered deprecations are kept until their names are reused, which this guards.
@testset "registered deprecations do not name current settings" begin
    for (old_path, new_path) in JETLS.deprecated_configurations
        err = config_parse_error(nested_config(old_path, "value"))
        @test err isa JETLS.InvalidKeyError && err.path == old_path[1:length(err.path)]
        new_path === nothing && continue
        # A replacement is a current setting, though the dummy value may not fit it
        err = config_parse_error(nested_config(new_path, Dict{String,Any}()))
        @test !(err isa JETLS.InvalidKeyError)
    end
    for (path, (old_value, new_value)) in JETLS.deprecated_configuration_values
        err = config_parse_error(nested_config(path, old_value))
        @test err isa ErrorException &&
            occursin("Invalid value at `$(join(path, "."))`", err.msg)
        @test config_parse_error(nested_config(path, new_value)) === nothing
    end
end

const DEPRECATED_CONFIG = "[testrunner]\nexecutable = \"x\"\njulia_args = []\n"

@testset "deprecated settings in an open config document" begin
    mktempdir() do dir
        config_uri = filepath2uri(joinpath(dir, ".JETLSConfig.toml"))
        capabilities = ClientCapabilities(;
            workspace = WorkspaceClientCapabilities(;
                workspaceEdit = WorkspaceEditClientCapabilities(; documentChanges = true)))
        text = "[full_analysis]\nauto_instantiate = true\n" * DEPRECATED_CONFIG
        withserver(; rootUri = filepath2uri(dir), capabilities) do (;
                writereadmsg, id_counter, server)
            (; raw_res) = writereadmsg(make_DidOpenTextDocumentNotification(
                config_uri, text; languageId = "toml", version = 1))
            @test raw_res isa PublishDiagnosticsNotification
            @test raw_res.params.uri == config_uri
            diagnostics = raw_res.params.diagnostics
            @test Set(d.code for d in diagnostics) ==
                Set((JETLS.CONFIG_DEPRECATED_KEY_CODE, JETLS.CONFIG_DEPRECATED_VALUE_CODE))

            (; raw_res) = writereadmsg(CodeActionRequest(;
                id = id_counter[] += 1,
                params = CodeActionParams(;
                    textDocument = TextDocumentIdentifier(; uri = config_uri),
                    range = Range(;
                        start = Position(; line = 0, character = 0),
                        var"end" = Position(; line = 5, character = 0)),
                    context = CodeActionContext(; diagnostics))))
            actions = raw_res.result
            @test Set(action.title for action in actions) == Set((
                "Remove deprecated `testrunner.executable`",
                "Replace `true` with `\"always\"`",
                "Fix all deprecated settings"))
            fix_all = only(action for action in actions
                if action.title == "Fix all deprecated settings")
            @test fix_all.kind == CodeActionKind.QuickFix
            document_edit = only(fix_all.edit.documentChanges)::TextDocumentEdit
            @test document_edit.textDocument.version == 1
            text_edit = only(document_edit.edits)
            fixed = JETLS.apply_text_change(text,
                text_edit.range, text_edit.newText, server.state.encoding)
            @test fixed == "[full_analysis]\nauto_instantiate = \"always\"\n" *
                "[testrunner]\njulia_args = []\n"

            (; raw_res) = writereadmsg(
                make_DidChangeTextDocumentNotification(config_uri, fixed, 2))
            @test raw_res isa PublishDiagnosticsNotification
            @test raw_res.params.uri == config_uri
            @test isempty(raw_res.params.diagnostics)

            # Nothing on disk to diagnose, and nothing published before to clear
            writereadmsg(DidCloseTextDocumentNotification(;
                params = DidCloseTextDocumentParams(;
                    textDocument = TextDocumentIdentifier(; uri = config_uri))); read = 0)
        end
    end
end

const WATCHED_FILES_CAPABILITIES = WorkspaceClientCapabilities(;
    didChangeWatchedFiles = DidChangeWatchedFilesClientCapabilities(;
        dynamicRegistration = true))

function config_created_notification(config_path::String)
    return DidChangeWatchedFilesNotification(;
        params = DidChangeWatchedFilesParams(;
            changes = [FileEvent(;
                uri = filepath2uri(config_path), type = FileChangeType.Created)]))
end

@testset "loading deprecated settings offers to fix them all" begin
    mktempdir() do dir
        config_path = joinpath(dir, ".JETLSConfig.toml")
        config_uri = filepath2uri(config_path)
        capabilities = ClientCapabilities(;
            workspace = WorkspaceClientCapabilities(;
                applyEdit = true,
                didChangeWatchedFiles = WATCHED_FILES_CAPABILITIES.didChangeWatchedFiles))
        withserver(; rootUri = filepath2uri(dir), capabilities) do (;
                writereadmsg, server)
            write(config_path, DEPRECATED_CONFIG)
            (; raw_res) = writereadmsg(config_created_notification(config_path); read = 3)
            @test raw_res[1] isa ShowMessageNotification
            prompt = raw_res[2]::ShowMessageRequest
            @test prompt.params.type == MessageType.Warning
            @test occursin("`testrunner.executable` is deprecated", prompt.params.message)
            @test [action.title for action in prompt.params.actions] ==
                [JETLS.FIX_DEPRECATED_CONFIGS_TITLE]
            @test raw_res[3] isa PublishDiagnosticsNotification
            @test raw_res[3].params.uri == config_uri

            (; raw_res) = writereadmsg(ResponseMessage(;
                id = prompt.id,
                result = Dict{String,Any}("title" => JETLS.FIX_DEPRECATED_CONFIGS_TITLE)))
            apply_request = raw_res::ApplyWorkspaceEditRequest
            text_edit = only(apply_request.params.edit.changes[config_uri])
            fixed = JETLS.apply_text_change(DEPRECATED_CONFIG,
                text_edit.range, text_edit.newText, server.state.encoding)
            @test fixed == "[testrunner]\njulia_args = []\n"

            writereadmsg(ResponseMessage(;
                id = apply_request.id, result = Dict{String,Any}("applied" => true)); read = 0)
        end
    end
end

@testset "deprecated settings are shown as warnings without `workspace/applyEdit`" begin
    mktempdir() do dir
        config_path = joinpath(dir, ".JETLSConfig.toml")
        config_uri = filepath2uri(config_path)
        capabilities = ClientCapabilities(; workspace = WATCHED_FILES_CAPABILITIES)
        withserver(; rootUri = filepath2uri(dir), capabilities) do (; writereadmsg)
            write(config_path, DEPRECATED_CONFIG)
            (; raw_res) = writereadmsg(config_created_notification(config_path); read = 3)
            warning = raw_res[2]::ShowMessageNotification
            @test warning.params.type == MessageType.Warning
            @test warning.params.message ==
                JETLS.deprecated_config_key_message(["testrunner", "executable"], nothing)
            @test raw_res[3] isa PublishDiagnosticsNotification

            (; raw_res) = writereadmsg(make_DidOpenTextDocumentNotification(
                config_uri, DEPRECATED_CONFIG; languageId = "toml", version = 1))
            @test raw_res isa PublishDiagnosticsNotification

            # Saving an open config file loads its settings without diagnosing it again
            (; raw_res) = writereadmsg(DidChangeWatchedFilesNotification(;
                params = DidChangeWatchedFilesParams(;
                    changes = [FileEvent(;
                        uri = config_uri, type = FileChangeType.Changed)])))
            @test raw_res isa ShowMessageNotification
            @test raw_res.params.message == warning.params.message
        end
    end
end

end # module test_config_deprecation
