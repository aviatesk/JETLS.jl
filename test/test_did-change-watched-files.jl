module test_didchangewatchedfiles

using Test
using JETLS
using JETLS: ClientCapabilities, DidChangeWatchedFilesClientCapabilities
using JETLS.LSP: DidChangeWatchedFilesNotification, DidChangeWatchedFilesParams, FileEvent, FileChangeType
using TOML

include("setup.jl")

# `workspace/didChangeWatchedFiles` does not support static registration,
# so we need to allow dynamic registration here test it
const CLIENT_CAPABILITIES = ClientCapabilities(
    workspace = (;
        didChangeWatchedFiles = DidChangeWatchedFilesClientCapabilities(
            dynamicRegistration = true
        )
    )
)

@testset "DidChangeWatchedFilesNotification full-cycle" begin
    mktempdir() do tmpdir
        config_path = joinpath(tmpdir, "JETLSConfig.toml")
        open(config_path, "w") do io
            write(io, "[performance.full_analysis]\ndebounce = 2.0\n[testrunner]\nexecutable = \"mytestrunner\"\n")
        end
        rootUri = filepath2uri(tmpdir)
        withserver(; rootUri, capabilities=CLIENT_CAPABILITIES) do (; writereadmsg, readmsg, id_counter, server)
            @test server.state.config_manager.actual_config["performance"]["full_analysis"]["debounce"] == 2.0
            @test server.state.config_manager.latest_config["performance"]["full_analysis"]["debounce"] == 2.0

            @test server.state.config_manager.actual_config["testrunner"]["executable"] == "mytestrunner"
            @test server.state.config_manager.latest_config["testrunner"]["executable"] == "mytestrunner"

            open(config_path, "w") do io
                write(io, "[performance.full_analysis]\ndebounce = 3.0\n[testrunner]\nexecutable = \"mytestrunner\"\n")
            end

            change_notification = DidChangeWatchedFilesNotification(;
                params=DidChangeWatchedFilesParams(;
                    changes=[FileEvent(; uri=filepath2uri(config_path), type=FileChangeType.Changed)]
                )
            )
            (; raw_res) = writereadmsg(change_notification)

            @test raw_res isa ShowMessageNotification
            @test raw_res.method == "window/showMessage"
            @test raw_res.params.type == MessageType.Warning
            @test occursin("performance.full_analysis.debounce", raw_res.params.message)
            @test occursin("Restart", raw_res.params.message)

            # Config should not be changed in actual_config (reload required)
            @test server.state.config_manager.actual_config["performance"]["full_analysis"]["debounce"] == 2.0
            # But latest_config should be updated
            @test server.state.config_manager.latest_config["performance"]["full_analysis"]["debounce"] == 3.0

            open(config_path, "w") do io
                write(io, "[performance.full_analysis]\ndebounce = 3.0\n[testrunner]\nexecutable = \"newtest\"\n")
            end

            change_notification2 = DidChangeWatchedFilesNotification(;
                params=DidChangeWatchedFilesParams(;
                    changes=[FileEvent(; uri=filepath2uri(config_path), type=FileChangeType.Changed)]
                )
            )
            writereadmsg(change_notification2; read=0)

            # testrunner.executable should be updated in both configs (no reload required)
            @test server.state.config_manager.actual_config["testrunner"]["executable"] == "newtest"
            @test server.state.config_manager.latest_config["testrunner"]["executable"] == "newtest"

            # unknown keys should be reported
            open(config_path, "w") do io
                write(io, "[performance]\n___unknown_key___ = \"value\"\n")
            end

            change_notification3 = DidChangeWatchedFilesNotification(;
                params=DidChangeWatchedFilesParams(;
                    changes=[FileEvent(; uri=filepath2uri(config_path), type=FileChangeType.Changed)]
                )
            )
            (; raw_res) = writereadmsg(change_notification3)
            @test raw_res isa ShowMessageNotification
            @test raw_res.method == "window/showMessage"
            @test raw_res.params.type == MessageType.Error
            @test occursin("unknown keys", raw_res.params.message)
            @test occursin("performance.___unknown_key___", raw_res.params.message)

            rm(config_path)

            deletion_notification = DidChangeWatchedFilesNotification(;
                params=DidChangeWatchedFilesParams(;
                    changes=[FileEvent(; uri=filepath2uri(config_path), type=FileChangeType.Deleted)]
                )
            )
            (; raw_res) = writereadmsg(deletion_notification)
            @test raw_res isa ShowMessageNotification
            @test raw_res.method == "window/showMessage"
            @test raw_res.params.type == MessageType.Warning
            @test occursin("deleted", raw_res.params.message)
            @test occursin("Restart", raw_res.params.message)

            actual_config_before = deepcopy(server.state.config_manager.actual_config)
            latest_config_before = deepcopy(server.state.config_manager.latest_config)

            # Non-config file change (should be ignored)
            other_file = joinpath(tmpdir, "other.txt")
            touch(other_file)

            other_change_notification = DidChangeWatchedFilesNotification(;
                params=DidChangeWatchedFilesParams(;
                    changes=[FileEvent(; uri=filepath2uri(other_file), type=FileChangeType.Changed)]
                )
            )

            writereadmsg(other_change_notification; read=0)

            # Actual and latest configs should remain unchanged
            @test server.state.config_manager.actual_config == actual_config_before
            @test server.state.config_manager.latest_config == latest_config_before
        end
    end
end

@testset "DidChangeWatchedFilesNotification without config file" begin
    mktempdir() do tmpdir
        rootUri = filepath2uri(tmpdir)

        withserver(; rootUri, capabilities=CLIENT_CAPABILITIES) do (; writereadmsg, readmsg, id_counter, server)
            @test server.state.config_manager.actual_config == JETLS.DEFAULT_CONFIG
            @test server.state.config_manager.latest_config == JETLS.DEFAULT_CONFIG

            # Create a JETLSConfig.toml file should be handled
            # as a config file update
            config_path = joinpath(tmpdir, "JETLSConfig.toml")
            open(config_path, "w") do io
                write(io, "[performance.full_analysis]\ndebounce = 100.0\n[testrunner]\nexecutable = \"mytestrunner\"\n")
            end
            creation_notification = DidChangeWatchedFilesNotification(;
                params=DidChangeWatchedFilesParams(;
                    changes=[FileEvent(; uri=filepath2uri(config_path), type=FileChangeType.Created)]
                )
            )
            (; raw_res) = writereadmsg(creation_notification)
            @test raw_res isa ShowMessageNotification
            @test raw_res.method == "window/showMessage"
            @test raw_res.params.type == MessageType.Warning
            @test occursin("performance.full_analysis.debounce", raw_res.params.message)
            @test occursin("Restart", raw_res.params.message)
            @test server.state.config_manager.actual_config["performance"]["full_analysis"]["debounce"] == JETLS.DEFAULT_CONFIG["performance"]["full_analysis"]["debounce"]
            @test server.state.config_manager.latest_config["performance"]["full_analysis"]["debounce"] == 100.0
            @test server.state.config_manager.actual_config["testrunner"]["executable"] == "mytestrunner"
            @test server.state.config_manager.latest_config["testrunner"]["executable"] == "mytestrunner"

            # New config file change should be watched
            open(config_path, "w") do io
                write(io, "[performance.full_analysis]\ndebounce = 200.0\n[testrunner]\nexecutable = \"mynewtest\"\n")
            end
            change_notification = DidChangeWatchedFilesNotification(;
                params=DidChangeWatchedFilesParams(;
                    changes=[FileEvent(; uri=filepath2uri(config_path), type=FileChangeType.Changed)]
                )
            )
            (; raw_res) = writereadmsg(change_notification)

            @test raw_res isa ShowMessageNotification
            @test raw_res.method == "window/showMessage"
            @test raw_res.params.type == MessageType.Warning
            @test occursin("performance.full_analysis.debounce", raw_res.params.message)
            @test occursin("Restart", raw_res.params.message)
            @test server.state.config_manager.actual_config["performance"]["full_analysis"]["debounce"] == JETLS.DEFAULT_CONFIG["performance"]["full_analysis"]["debounce"]
            @test server.state.config_manager.latest_config["performance"]["full_analysis"]["debounce"] == 200.0
            @test server.state.config_manager.actual_config["testrunner"]["executable"] == "mynewtest"
            @test server.state.config_manager.latest_config["testrunner"]["executable"] == "mynewtest"
        end
    end
end



end
