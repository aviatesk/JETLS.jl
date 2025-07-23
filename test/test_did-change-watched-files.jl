module test_did_change_watched_files

using Test
using JETLS

include("setup.jl")

# `workspace/didChangeWatchedFiles` does not support static registration,
# so we need to allow dynamic registration here to test it
const CLIENT_CAPABILITIES = ClientCapabilities(
    workspace = (;
        didChangeWatchedFiles = DidChangeWatchedFilesClientCapabilities(
            dynamicRegistration = true
        )
    )
)

const DEBOUNCE_DEFAULT = JETLS.access_nested_dict(JETLS.DEFAULT_CONFIG,
    "performance", "full_analysis", "debounce")

const THROTTLE_DEFAULT = JETLS.access_nested_dict(JETLS.DEFAULT_CONFIG,
    "performance", "full_analysis", "throttle")

const TESTRUNNER_DEFAULT = JETLS.access_nested_dict(JETLS.DEFAULT_CONFIG,
    "testrunner", "executable")

# Test the full cycle of `DidChangeWatchedFilesNotification`:
# 1. Initialize with `.JETLSConfig.toml` file.
# 2. Change the keys that require reload
# 3. Add new keys
# 4. Change the keys that do not require reload
# 5. Delete `.JETLSConfig.toml` file
# 6. Re-create `.JETLSConfig.toml` file
# 7. Create a new file that is not a config file
@testset "DidChangeWatchedFilesNotification full-cycle" begin
    mktempdir() do tmpdir
        config_path = joinpath(tmpdir, ".JETLSConfig.toml")
        DEBOUNCE_STARTUP = 100.0
        TESTRUNNER_STARTUP = "testrunner_startup"
        open(config_path, "w") do io
            write(io, """
                [performance.full_analysis]
                debounce = $DEBOUNCE_STARTUP
                [testrunner]
                executable = \"$TESTRUNNER_STARTUP\"
                """)
        end
        rootUri = filepath2uri(tmpdir)
        withserver(; rootUri, capabilities=CLIENT_CAPABILITIES) do (; writereadmsg, readmsg, id_counter, server)
            manager = server.state.config_manager

            # after initialization, manager should have the fixed config for reload required keys
            @test JETLS.access_nested_dict(manager.reload_required_setting,
                "performance", "full_analysis", "debounce") == DEBOUNCE_STARTUP
            @test JETLS.access_nested_dict(manager.reload_required_setting,
                "performance", "full_analysis", "throttle") == THROTTLE_DEFAULT

            @test haskey(manager.watched_files, config_path)
            @test collect(keys(manager.watched_files)) == [config_path, "__DEFAULT_CONFIG__"]
            @test manager.watched_files["__DEFAULT_CONFIG__"] == JETLS.DEFAULT_CONFIG

            jetlstoml_config_state = manager.watched_files[config_path]
            @test jetlstoml_config_state["performance"]["full_analysis"]["debounce"] == DEBOUNCE_STARTUP
            @test jetlstoml_config_state["testrunner"]["executable"] == TESTRUNNER_STARTUP
            @test JETLS.get_config(manager, "performance", "full_analysis", "debounce") == DEBOUNCE_STARTUP
            @test JETLS.get_config(manager, "testrunner", "executable") == TESTRUNNER_STARTUP

            # change `performance.full_analysis.debounce` to `DEBOUNCE_V2`
            DEBOUNCE_V2 = 200.0
            open(config_path, "w") do io
                write(io, """
                    [performance.full_analysis]
                    debounce = $DEBOUNCE_V2
                    [testrunner]
                    executable = \"$TESTRUNNER_STARTUP\"
                    """)
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
            @test occursin("restart", raw_res.params.message)

            # Config should not be changed (reload required)
            @test JETLS.get_config(manager, "performance", "full_analysis", "debounce") == DEBOUNCE_STARTUP
            # But config dict should be updated to avoid showing the same message again
            @test jetlstoml_config_state["performance"]["full_analysis"]["debounce"] == DEBOUNCE_V2

            THROTTLE_V2 = 300.0
            # Add a new key `performance.full_analysis.throttle`
            open(config_path, "w") do io
                write(io, """
                    [performance.full_analysis]
                    debounce = $DEBOUNCE_V2
                    throttle = $THROTTLE_V2
                    [testrunner]
                    executable = \"$TESTRUNNER_STARTUP\"
                    """)
            end

            change_notification1 = DidChangeWatchedFilesNotification(;
                params=DidChangeWatchedFilesParams(;
                    changes=[FileEvent(; uri=filepath2uri(config_path), type=FileChangeType.Changed)]
                )
            )
            (; raw_res) = writereadmsg(change_notification1)
            @test raw_res isa ShowMessageNotification
            @test raw_res.method == "window/showMessage"
            @test raw_res.params.type == MessageType.Warning
            # only changed keys should be reported
            @test occursin("throttle", raw_res.params.message)
            @test !occursin("debounce", raw_res.params.message)
            @test occursin("restart", raw_res.params.message)

            # `performance.full_analysis.throttle` should not be changed (reload required)
            @test JETLS.get_config(manager, "performance", "full_analysis", "throttle") == THROTTLE_DEFAULT

            # Change `testrunner.executable` to "newtestrunner"
            TESTRUNNER_V2 = "testrunner_v2"
            open(config_path, "w") do io
                write(io, """
                    [performance.full_analysis]
                    debounce = $DEBOUNCE_V2
                    [testrunner]
                    executable = \"$TESTRUNNER_V2\"
                    """)
            end

            change_notification2 = DidChangeWatchedFilesNotification(;
                params=DidChangeWatchedFilesParams(;
                    changes=[FileEvent(; uri=filepath2uri(config_path), type=FileChangeType.Changed)]
                )
            )
            writereadmsg(change_notification2; read=0)

            # testrunner.executable should be updated in both configs (no reload required)
            @test jetlstoml_config_state["testrunner"]["executable"] == TESTRUNNER_V2
            @test JETLS.get_config(manager, "testrunner", "executable") == TESTRUNNER_V2

            # unknown keys should be reported
            open(config_path, "w") do io
                write(io, """
                    [performance]
                    ___unknown_key___ = \"value\"
                    """)
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

            # Delete the config file
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
            @test occursin("restart", raw_res.params.message)

            # After deletion,
            # - for reload required keys, `get_config` should remain unchanged
            @test JETLS.get_config(manager, "performance", "full_analysis", "debounce") == DEBOUNCE_STARTUP
            # -  For non-reload required keys, replace with value from the next highest-priority config file. (`__DEFAULT_CONFIG__`)
            @test JETLS.get_config(manager, "testrunner", "executable") == TESTRUNNER_DEFAULT

            # remove the config file from watched files
            @test !haskey(manager.watched_files, config_path)
            @test collect(keys(manager.watched_files)) == ["__DEFAULT_CONFIG__"]

            # re-create the config file
            DEBOUNCE_RECREATE = 400.0
            TESTRUNNER_RECREATE = "testrunner_recreate"
            open(config_path, "w") do io
                write(io, """
                    [performance.full_analysis]
                    debounce = $DEBOUNCE_RECREATE
                    [testrunner]
                    executable = \"$TESTRUNNER_RECREATE\"
                    """)
            end

            re_creation_notification = DidChangeWatchedFilesNotification(;
                params=DidChangeWatchedFilesParams(;
                    changes=[FileEvent(; uri=filepath2uri(config_path), type=FileChangeType.Created)]
                )
            )
            (; raw_res) = writereadmsg(re_creation_notification)
            @test raw_res isa ShowMessageNotification
            @test raw_res.method == "window/showMessage"
            @test raw_res.params.type == MessageType.Warning
            @test occursin("create", raw_res.params.message)
            @test occursin("restart", raw_res.params.message)

            # `config_path` should be registered again
            @test haskey(manager.watched_files, config_path)
            # reload required keys should not be changed even if higher priority config file is re-created
            @test JETLS.get_config(manager, "performance", "full_analysis", "debounce") == DEBOUNCE_STARTUP
            @test JETLS.access_nested_dict(manager.watched_files[config_path],
                "performance", "full_analysis", "debounce") == DEBOUNCE_RECREATE
            # non-reload required keys should be updated
            @test JETLS.get_config(manager, "testrunner", "executable") == TESTRUNNER_RECREATE

            # non-config file change (should be ignored)
            other_file = joinpath(tmpdir, "other.txt")
            touch(other_file)
            other_change_notification = DidChangeWatchedFilesNotification(;
                params=DidChangeWatchedFilesParams(;
                    changes=[FileEvent(; uri=filepath2uri(other_file), type=FileChangeType.Changed)]
                )
            )
            writereadmsg(other_change_notification; read=0)
            # no effect on config
            @test JETLS.get_config(manager, "performance", "full_analysis", "debounce") == DEBOUNCE_STARTUP
            @test JETLS.get_config(manager, "testrunner", "executable") == TESTRUNNER_RECREATE
        end
    end
end

@testset "DidChangeWatchedFilesNotification without config file" begin
    mktempdir() do tmpdir
        rootUri = filepath2uri(tmpdir)

        withserver(; rootUri, capabilities=CLIENT_CAPABILITIES) do (; writereadmsg, readmsg, id_counter, server)
            manager = server.state.config_manager

            @test collect(keys(manager.watched_files)) == ["__DEFAULT_CONFIG__"]
            @test manager.watched_files["__DEFAULT_CONFIG__"] == JETLS.DEFAULT_CONFIG

            config_path = joinpath(tmpdir, ".JETLSConfig.toml")
            DEBOUNCE_RECREATE = 500.0
            TESTRUNNER_RECREATE = "testrunner_recreate"
            open(config_path, "w") do io
                write(io, """
                    [performance.full_analysis]
                    debounce = $DEBOUNCE_RECREATE
                    [testrunner]
                    executable = \"$TESTRUNNER_RECREATE\"
                    """)
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
            @test occursin("create", raw_res.params.message)
            @test occursin("restart", raw_res.params.message)
            @test haskey(manager.watched_files, config_path)

            # If higher priority config file is created,
            # - reload required keys should not be changed
            @test JETLS.get_config(manager, "performance", "full_analysis", "debounce") == DEBOUNCE_DEFAULT
            # - non-reload required keys should be updated
            @test JETLS.get_config(manager, "testrunner", "executable") == TESTRUNNER_RECREATE

            # New config file change also should be watched
            DEBOUNCE_V2 = 600.0
            TESTRUNNER_V2 = "testrunner_v2"
            open(config_path, "w") do io
                write(io, """
                    [performance.full_analysis]
                    debounce = $DEBOUNCE_V2
                    [testrunner]
                    executable = \"$TESTRUNNER_V2\"
                    """)
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
            @test occursin("restart", raw_res.params.message)
            @test JETLS.get_config(manager, "performance", "full_analysis", "debounce") == DEBOUNCE_DEFAULT
            @test JETLS.get_config(manager, "testrunner", "executable") == TESTRUNNER_V2
        end
    end
end

end
