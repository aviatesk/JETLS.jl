module test_did_change_watched_files

using Test
using JETLS

include(normpath(pkgdir(JETLS), "test", "setup.jl"))

# `workspace/didChangeWatchedFiles` does not support static registration,
# so we need to allow dynamic registration here to test it
const CLIENT_CAPABILITIES = ClientCapabilities(
    workspace = (;
        didChangeWatchedFiles = DidChangeWatchedFilesClientCapabilities(
            dynamicRegistration = true
        )
    )
)

const DEBOUNCE_DEFAULT = JETLS.getobjpath(JETLS.DEFAULT_CONFIG,
    :full_analysis, :debounce)

const STATIC_SETTING_DEFAULT = JETLS.getobjpath(JETLS.DEFAULT_CONFIG,
    :internal, :static_setting)

const TESTRUNNER_DEFAULT = JETLS.getobjpath(JETLS.DEFAULT_CONFIG,
    :testrunner, :executable)

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
        STATIC_SETTING_STARTUP = 100
        TESTRUNNER_STARTUP = "testrunner_startup"
        write(config_path, """
            [internal]
            static_setting = $STATIC_SETTING_STARTUP
            [testrunner]
            executable = \"$TESTRUNNER_STARTUP\"
            """)
        rootUri = filepath2uri(tmpdir)
        withserver(; rootUri, capabilities=CLIENT_CAPABILITIES) do (; writereadmsg, server)
            manager = server.state.config_manager

            @test JETLS.get_config(manager, :internal, :static_setting) == STATIC_SETTING_STARTUP
            @test JETLS.get_config(manager, :testrunner, :executable) == TESTRUNNER_STARTUP

            # change `internal.static_setting` to `STATIC_SETTING_V2`
            STATIC_SETTING_V2 = 200
            write(config_path, """
                [internal]
                static_setting = $STATIC_SETTING_V2
                [testrunner]
                executable = \"$TESTRUNNER_STARTUP\"
                """)

            let msg = DidChangeWatchedFilesNotification(;
                    params=DidChangeWatchedFilesParams(;
                        changes=[FileEvent(; uri=filepath2uri(config_path), type=FileChangeType.Changed)]
                    )
                )
                (; raw_res) = writereadmsg(msg)
                @test raw_res isa ShowMessageNotification
                @test raw_res.params.type == MessageType.Warning
                expected_static_msg = JETLS.changed_static_settings_message([
                    JETLS.ConfigChange("internal.static_setting", STATIC_SETTING_STARTUP, STATIC_SETTING_V2)
                ])
                @test occursin(expected_static_msg, raw_res.params.message)
            end

            # Static setting should not be changed
            @test JETLS.get_config(manager, :internal, :static_setting) == STATIC_SETTING_STARTUP

            DEBOUNCE_V2 = 300.0
            # Add a new key `full_analysis.debounce` (now dynamic)
            write(config_path, """
                [internal]
                static_setting = $STATIC_SETTING_V2
                [full_analysis]
                debounce = $DEBOUNCE_V2
                [testrunner]
                executable = \"$TESTRUNNER_STARTUP\"
                """)

            let msg = DidChangeWatchedFilesNotification(;
                    params=DidChangeWatchedFilesParams(;
                        changes=[FileEvent(; uri=filepath2uri(config_path), type=FileChangeType.Changed)]
                    )
                )
                (; raw_res) = writereadmsg(msg)
                @test raw_res isa ShowMessageNotification
                @test raw_res.params.type == MessageType.Info
                expected_changes_msg = JETLS.changed_settings_message([
                    JETLS.ConfigChange("full_analysis.debounce", DEBOUNCE_DEFAULT, DEBOUNCE_V2)
                ])
                @test occursin(expected_changes_msg, raw_res.params.message)
                @test !occursin("internal.static_setting", raw_res.params.message)
            end

            # `full_analysis.debounce` should be changed (dynamic)
            @test JETLS.get_config(manager, :full_analysis, :debounce) == DEBOUNCE_V2

            # Change `testrunner.executable` to "newtestrunner"
            TESTRUNNER_V2 = "testrunner_v2"
            write(config_path, """
                [internal]
                static_setting = $STATIC_SETTING_V2
                [full_analysis]
                debounce = $DEBOUNCE_V2
                [testrunner]
                executable = \"$TESTRUNNER_V2\"
                """)

            let msg = DidChangeWatchedFilesNotification(;
                    params=DidChangeWatchedFilesParams(;
                        changes=[FileEvent(; uri=filepath2uri(config_path), type=FileChangeType.Changed)]
                    )
                )
                (; raw_res) = writereadmsg(msg)
                @test raw_res isa ShowMessageNotification
                @test raw_res.params.type == MessageType.Info
                expected_changes_msg = JETLS.changed_settings_message([
                    JETLS.ConfigChange("testrunner.executable", TESTRUNNER_STARTUP, TESTRUNNER_V2)
                ])
                @test occursin(expected_changes_msg, raw_res.params.message)
                @test !occursin("full_analysis.debounce", raw_res.params.message)
                @test !occursin("internal.static_setting", raw_res.params.message)
            end

            # testrunner.executable should be updated in both configs (dynamic)
            @test JETLS.get_config(manager, :testrunner, :executable) == TESTRUNNER_V2

            # unknown keys should be reported
            write(config_path, """
                [full_analysis]
                ___unknown_key___ = \"value\"
                """)
            let msg = DidChangeWatchedFilesNotification(;
                    params=DidChangeWatchedFilesParams(;
                        changes=[FileEvent(; uri=filepath2uri(config_path), type=FileChangeType.Changed)]
                    )
                )
                (; raw_res) = writereadmsg(msg)
                @test raw_res isa ShowMessageNotification
                @test raw_res.params.type == MessageType.Error
                expected_error_msg = JETLS.unmatched_keys_in_config_file_msg(config_path, [["full_analysis", "___unknown_key___"]])
                @test occursin(expected_error_msg, raw_res.params.message)
            end

            # Delete the config file
            rm(config_path)
            let msg = DidChangeWatchedFilesNotification(;
                    params=DidChangeWatchedFilesParams(;
                        changes=[FileEvent(; uri=filepath2uri(config_path), type=FileChangeType.Deleted)]
                    )
                )
                (; raw_res) = writereadmsg(msg; read=2)
                @test any(raw_res) do r
                    r isa ShowMessageNotification &&
                    r.params.type == MessageType.Info &&
                    occursin(JETLS.config_file_deleted_msg(config_path), r.params.message)
                end
                @test any(raw_res) do r
                    if r isa ShowMessageNotification && r.params.type == MessageType.Warning
                        expected_changes = JETLS.changed_settings_message([
                            JETLS.ConfigChange("full_analysis.debounce", DEBOUNCE_V2, DEBOUNCE_DEFAULT),
                            JETLS.ConfigChange("testrunner.executable", TESTRUNNER_V2, TESTRUNNER_DEFAULT)
                        ])
                        expected_static = JETLS.changed_static_settings_message([
                            JETLS.ConfigChange("internal.static_setting", STATIC_SETTING_V2, STATIC_SETTING_DEFAULT)
                        ])
                        return occursin(expected_changes, r.params.message) &&
                               occursin(expected_static, r.params.message)
                    end
                    return false
                end
            end

            # After deletion,
            # - For static keys, `get_config` should remain unchanged
            @test JETLS.get_config(manager, :internal, :static_setting) == STATIC_SETTING_STARTUP
            # - For non-static keys, replace with value from the next highest-priority config file. (`__DEFAULT_CONFIG__`)
            @test JETLS.get_config(manager, :full_analysis, :debounce) == DEBOUNCE_DEFAULT

            # re-create the config file
            STATIC_SETTING_RECREATE = 400
            TESTRUNNER_RECREATE = "testrunner_recreate"
            write(config_path, """
                [internal]
                static_setting = $STATIC_SETTING_RECREATE
                [testrunner]
                executable = \"$TESTRUNNER_RECREATE\"
                """)

            let msg = DidChangeWatchedFilesNotification(;
                    params=DidChangeWatchedFilesParams(;
                        changes=[FileEvent(; uri=filepath2uri(config_path), type=FileChangeType.Created)]
                    )
                )
                (; raw_res) = writereadmsg(msg; read=2)
                @test any(raw_res) do r
                    r isa ShowMessageNotification &&
                    r.params.type == MessageType.Info &&
                    occursin(JETLS.config_file_created_msg(config_path), r.params.message)
                end
                @test any(raw_res) do r
                    if r isa ShowMessageNotification && r.params.type == MessageType.Warning
                        expected_changes = JETLS.changed_settings_message([
                            JETLS.ConfigChange("testrunner.executable", TESTRUNNER_DEFAULT, TESTRUNNER_RECREATE)
                        ])
                        expected_static = JETLS.changed_static_settings_message([
                            JETLS.ConfigChange("internal.static_setting", STATIC_SETTING_DEFAULT, STATIC_SETTING_RECREATE)
                        ])
                        return occursin(expected_changes, r.params.message) &&
                               occursin(expected_static, r.params.message)
                    end
                    return false
                end
            end

            # static keys should not be changed even if higher priority config file is re-created
            @test JETLS.get_config(manager, :internal, :static_setting) == STATIC_SETTING_STARTUP

            # non-config file change (should be ignored)
            other_file = joinpath(tmpdir, "other.txt")
            touch(other_file)
            let msg = DidChangeWatchedFilesNotification(;
                    params=DidChangeWatchedFilesParams(;
                        changes=[FileEvent(; uri=filepath2uri(other_file), type=FileChangeType.Changed)]))
                writereadmsg(msg; read=0)
            end
            # no effect on config
            @test JETLS.get_config(manager, :internal, :static_setting) == STATIC_SETTING_STARTUP
            @test JETLS.get_config(manager, :testrunner, :executable) == TESTRUNNER_RECREATE
        end
    end
end

@testset "DidChangeWatchedFilesNotification without config file" begin
    mktempdir() do tmpdir
        rootUri = filepath2uri(tmpdir)

        withserver(; rootUri, capabilities=CLIENT_CAPABILITIES) do (; writereadmsg, server)
            manager = server.state.config_manager

            config_path = joinpath(tmpdir, ".JETLSConfig.toml")
            STATIC_SETTING_RECREATE = 500
            TESTRUNNER_RECREATE = "testrunner_recreate"
            write(config_path, """
                [internal]
                static_setting = $STATIC_SETTING_RECREATE
                [testrunner]
                executable = \"$TESTRUNNER_RECREATE\"
                """)
            creation_notification = DidChangeWatchedFilesNotification(;
                params=DidChangeWatchedFilesParams(;
                    changes=[FileEvent(; uri=filepath2uri(config_path), type=FileChangeType.Created)]
                )
            )
            (; raw_res) = writereadmsg(creation_notification; read=2)
            @test any(raw_res) do r
                r isa ShowMessageNotification &&
                r.params.type == MessageType.Info &&
                occursin(JETLS.config_file_created_msg(config_path), r.params.message)
            end
            @test any(raw_res) do r
                if r isa ShowMessageNotification && r.params.type == MessageType.Warning
                    expected_changes = JETLS.changed_settings_message([
                        JETLS.ConfigChange("testrunner.executable", TESTRUNNER_DEFAULT, TESTRUNNER_RECREATE)
                    ])
                    expected_static = JETLS.changed_static_settings_message([
                        JETLS.ConfigChange("internal.static_setting", STATIC_SETTING_DEFAULT, STATIC_SETTING_RECREATE)
                    ])
                    return occursin(expected_changes, r.params.message) &&
                           occursin(expected_static, r.params.message)
                end
                return false
            end

            # If higher priority config file is created,
            # - static keys should not be changed
            @test JETLS.get_config(manager, :internal, :static_setting) == STATIC_SETTING_DEFAULT
            # - non-static keys should be updated
            @test JETLS.get_config(manager, :testrunner, :executable) == TESTRUNNER_RECREATE

            # New config file change also should be watched
            STATIC_SETTING_V2 = 600
            TESTRUNNER_V2 = "testrunner_v2"
            write(config_path, """
                [internal]
                static_setting = $STATIC_SETTING_V2
                [testrunner]
                executable = \"$TESTRUNNER_V2\"
                """)
            change_notification = DidChangeWatchedFilesNotification(;
                params=DidChangeWatchedFilesParams(;
                    changes=[FileEvent(; uri=filepath2uri(config_path), type=FileChangeType.Changed)]
                )
            )
            (; raw_res) = writereadmsg(change_notification)

            @test raw_res isa ShowMessageNotification
            @test raw_res.params.type == MessageType.Warning
            expected_static_msg = JETLS.changed_static_settings_message([
                JETLS.ConfigChange("internal.static_setting", STATIC_SETTING_RECREATE, STATIC_SETTING_V2)
            ])
            @test occursin(expected_static_msg, raw_res.params.message)

            @test JETLS.get_config(manager, :internal, :static_setting) == STATIC_SETTING_DEFAULT
            @test JETLS.get_config(manager, :testrunner, :executable) == TESTRUNNER_V2
        end
    end
end

end # module test_did_change_watched_files
