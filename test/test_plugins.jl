module test_plugins

include("setup.jl")
include("jsjl-utils.jl")

using Test
using JETLS
using JETLS.LSP
using JETLS.URIs2

function drain_server_messages!(;
        try_readmsg,
        writemsg,
        max_reads::Int = 200,
    )
    for _ = 1:max_reads
        msg = try_readmsg().raw_msg
        msg === nothing && break
        if msg isa WorkspaceDiagnosticRefreshRequest
            writemsg(WorkspaceDiagnosticRefreshResponse(; id=msg.id, result=nothing); check=false)
            continue
        end
        if msg isa WorkDoneProgressCreateRequest
            writemsg(WorkDoneProgressCreateResponse(; id=msg.id, result=nothing); check=false)
        end
    end
    return nothing
end

function wait_for_diagnostics_until!(;
        try_readmsg,
        writemsg,
        uri::URI,
        timeout_s::Real = 60,
        predicate::Function = Returns(true),
    )
    deadline = time() + timeout_s
    last = nothing
    while time() < deadline
        msg = try_readmsg().raw_msg
        if msg === nothing
            sleep(0.05)
            continue
        end
        if msg isa WorkspaceDiagnosticRefreshRequest
            writemsg(WorkspaceDiagnosticRefreshResponse(; id=msg.id, result=nothing); check=false)
            continue
        end
        if msg isa WorkDoneProgressCreateRequest
            writemsg(WorkDoneProgressCreateResponse(; id=msg.id, result=nothing); check=false)
            continue
        end
        msg isa PublishDiagnosticsNotification || continue
        msg.params.uri == uri || continue
        last = msg
        if predicate(msg)
            break
        end
    end

    last === nothing && error("Timeout waiting for PublishDiagnosticsNotification for $(uri)")
    return last
end

function read_until_diagnostics!(;
        readmsg,
        writemsg,
        uri::URI,
        max_reads::Int = 10,
    )
    for _ = 1:max_reads
        msg = readmsg(; read=1, check=false).raw_msg
        if msg isa WorkspaceDiagnosticRefreshRequest
            writemsg(WorkspaceDiagnosticRefreshResponse(; id=msg.id, result=nothing); check=false)
            continue
        end
        if msg isa WorkDoneProgressCreateRequest
            writemsg(WorkDoneProgressCreateResponse(; id=msg.id, result=nothing); check=false)
            continue
        end
        msg isa PublishDiagnosticsNotification || continue
        msg.params.uri == uri || continue
        return msg
    end
    error("Timeout waiting for PublishDiagnosticsNotification for $(uri)")
end

function diagnostic_codes(diags)
    codes = Set{String}()
    for d in diags
        d.code isa String || continue
        push!(codes, d.code)
    end
    return codes
end

@testset "PluginSpec parsing accepts PackageSpec-like fields" begin
    uuid_str = "f72c67d0-14ab-4d0b-9fc9-3ebf3a7d7d2b"
    dict = Dict{String,Any}(
        "plugins" => Any[
            Dict{String,Any}(
                "name" => "TestPlugin",
                "uuid" => uuid_str,
                "version" => "1.2.3",
                "url" => "https://example.invalid/repo.git",
                "path" => "./local/path",
                "subdir" => "subdir",
                "rev" => "main",
                "entry" => Any["entry1", "entry2"],
                "enabled" => true,
                # Accepted but ignored (Pkg.PackageSpec supports these).
                "mode" => "ignored",
                "level" => "ignored",
            ),
        ],
    )

    parsed = JETLS.parse_config_dict(dict)
    @test parsed isa JETLS.JETLSConfig

    plugins = JETLS.getobjpath(parsed, :plugins)
    @test plugins isa Vector{JETLS.PluginSpec}
    @test length(plugins) == 1
    spec = plugins[1]
    @test spec.name == "TestPlugin"
    @test spec.uuid == Base.UUID(uuid_str)
    @test spec.version == VersionNumber("1.2.3")
    @test spec.url == "https://example.invalid/repo.git"
    @test spec.path == "./local/path"
    @test spec.subdir == "subdir"
    @test spec.rev == "main"
    @test spec.entry == ["entry1", "entry2"]
    @test spec.enabled == true
end

@testset "Plugin vector merge preserves overlay ordering" begin
    a = JETLS.PluginSpec("A", nothing, nothing, nothing, nothing, nothing, nothing, String[], true)
    b = JETLS.PluginSpec("B", nothing, nothing, nothing, nothing, nothing, nothing, String[], true)
    base = JETLS.JETLSConfig(; plugins=[a, b])
    overlay = JETLS.JETLSConfig(; plugins=[b, a])
    merged = JETLS.merge_settings(base, overlay)
    plugins = JETLS.getobjpath(merged, :plugins)
    @test [p.name for p in plugins] == ["B", "A"]
end

@testset "Plugin hooks run without restart (world-age safe)" begin
    withpackage("TestPluginTarget", """
        module TestPluginTarget
        function ok(x::Int)
            return x + 1
        end
        module Bad
            function boom(x::Int)
                return not_defined + x
            end
        end
        end
        """) do pkg_path

        # Create a local plugin package next to the target package.
        tmp_root = dirname(pkg_path)
        plugin_name = "TestJETLSPluginMock"
        plugin_uuid = "3f48f4c2-3a63-4e8e-99f3-8b3a3b6dbd2a"
        plugin_path = normpath(tmp_root, plugin_name)
        mkpath(normpath(plugin_path, "src"))
        write(normpath(plugin_path, "Project.toml"), """
            name = "$plugin_name"
            uuid = "$plugin_uuid"
            version = "0.1.0"
            """)
        write(normpath(plugin_path, "src", "$plugin_name.jl"), """
            __precompile__(false)

            module $plugin_name

            const _JETLS_PKGID = Base.PkgId(Base.UUID("a3b70258-0602-4ee2-b5a6-54c2470400db"), "JETLS")
            const _JETLS = get(Base.loaded_modules, _JETLS_PKGID, nothing)
            _JETLS === nothing && error("$plugin_name requires JETLS to be loaded")
            const JETLS = _JETLS

            const CODE = "inference/test-plugin"

            struct Plugin <: JETLS.AbstractJETLSPlugin end
            const PLUGIN = Plugin()

            function __init__()
                JETLS.register_diagnostic_code!(CODE)
                JETLS.register_plugin!(PLUGIN; owner=$(plugin_name))
                return nothing
            end

            function _frame_uri(frame)
                frame.file === :none && return nothing
                filename = String(frame.file)
                if startswith(filename, "Untitled")
                    return JETLS.filename2uri(filename)
                end
                return JETLS.filepath2uri(JETLS.to_full_path(filename))
            end

            function JETLS.plugin_expand_inference_error_report!(
                    ::Plugin,
                    uri2diagnostics::JETLS.URI2Diagnostics,
                    report::JETLS.JET.InferenceErrorReport,
                    ::JETLS.JET.PostProcessor,
                )::Bool
                for i in JETLS.Analyzer.inference_error_report_stack(report)
                    frame = report.vst[i]
                    uri = _frame_uri(frame)
                    uri === nothing && continue
                    haskey(uri2diagnostics, uri) || continue
                    line = JETLS.JET.fixed_line_number(frame)
                    line0 = max(line - 1, 0)
                    pos = JETLS.LSP.Position(line0, 0)
                    range = JETLS.LSP.Range(pos, pos)
                    diag = JETLS.LSP.Diagnostic(;
                        range,
                        severity = JETLS.LSP.DiagnosticSeverity.Information,
                        code = CODE,
                        source = "$plugin_name",
                        message = "test plugin active",
                    )
                    push!(uri2diagnostics[uri], diag)
                    break
                end
                return false
            end

            end # module
            """)

        rootUri = filepath2uri(pkg_path)
        src_path = normpath(pkg_path, "src", "TestPluginTarget.jl")
        uri = filepath2uri(src_path)
        code = read(src_path, String)

        withserver(; rootUri) do (; writemsg, readmsg, try_readmsg, writereadmsg)
            # Open once with no plugins enabled.
            (; raw_res) = writereadmsg(make_DidOpenTextDocumentNotification(uri, code); check=false)
            @test raw_res isa PublishDiagnosticsNotification
            pub1 = raw_res::PublishDiagnosticsNotification
            codes1 = diagnostic_codes(pub1.params.diagnostics)
            @test "inference/test-plugin" ∉ codes1
            drain_server_messages!(; try_readmsg, writemsg)

            # Enable the plugin after the server has started (this is where world-age matters).
            settings = Dict{String,Any}(
                "plugins" => Any[
                    Dict{String,Any}(
                        "name" => plugin_name,
                        "uuid" => plugin_uuid,
                        "path" => "../$plugin_name",
                        "enabled" => true,
                    ),
                ],
            )
            writemsg(
                DidChangeConfigurationNotification(;
                    params = DidChangeConfigurationParams(; settings)
                );
                check=false,
            )

            # Drain server requests/notifications triggered by config change (e.g. refresh).
            drain_server_messages!(; try_readmsg, writemsg)

            # Trigger a re-analysis so plugins are applied.
            writemsg(
                DidSaveTextDocumentNotification(;
                    params = DidSaveTextDocumentParams(;
                        textDocument = TextDocumentIdentifier(; uri),
                        text = code,
                    )
                );
                check=false,
            )
            pub2 = read_until_diagnostics!(;
                readmsg,
                writemsg,
                uri,
            )
            codes2 = diagnostic_codes(pub2.params.diagnostics)
            @test "inference/test-plugin" in codes2

            # Drain any remaining server->client traffic to keep the test harness clean.
            drain_server_messages!(; try_readmsg, writemsg)
            sleep(0.05)
            drain_server_messages!(; try_readmsg, writemsg)
            return true
        end
    end
end

end # module test_plugins
