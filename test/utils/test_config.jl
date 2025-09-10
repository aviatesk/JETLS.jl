module test_config

using Test
using JETLS

const TEST_DICT = JETLS.ConfigDict(
    "test_key1" => "test_value1",
    "test_key2" => JETLS.ConfigDict(
        "nested_key1" => "nested_value1",
        "nested_key2" => JETLS.ConfigDict(
            "deep_nested_key1" => "deep_nested_value1",
            "deep_nested_key2" => "deep_nested_value2"
        )
    )
)

const TEST_DICT_DIFFERENT_VALUE = JETLS.ConfigDict(
    "test_key1" => "newvalue_1",  # different value (reload required)
    "test_key2" => JETLS.ConfigDict(
        "nested_key1" => "nested_value1",
        "nested_key2" => JETLS.ConfigDict(
            "deep_nested_key1" => "newvalue_2", # different value (reload required)
            "deep_nested_key2" => "newvalue_3"  # different value (reload not required)
        )
    )
)

const TEST_DICT_DIFFERENT_KEY = JETLS.ConfigDict(
    "diffname_1" => "test_value1",  # different key name
    "test_key2" => JETLS.ConfigDict(
        "nested_key1" => "nested_value1",
        "diffname_2" => JETLS.ConfigDict(       # different key name
            "deep_nested_key1" => "deep_nested_value1",
            "diffname_3" => "deep_nested_value2" # different key under a different key
        )
    ),
)

const TEST_RELOAD_REQUIRED = JETLS.ConfigDict(
    "test_key1" => true,
    "test_key2" => JETLS.ConfigDict(
        "nested_key1" => false,
        "nested_key2" => JETLS.ConfigDict(
            "deep_nested_key1" => true,
            "deep_nested_key2" => false
        )
    )
)

@testset "WatchedConfigFiles" begin
    @testset "constructor and basic operations" begin
        watched = JETLS.WatchedConfigFiles()
        @test length(watched) == 1
        @test keys(watched) == ["__DEFAULT_CONFIG__"]
        @test watched["__DEFAULT_CONFIG__"] == JETLS.DEFAULT_CONFIG
    end

    @testset "setindex! and getindex" begin
        watched = JETLS.WatchedConfigFiles()
        config = JETLS.ConfigDict("key1" => "value1")

        watched["/project/.JETLSConfig.toml"] = config
        @test length(watched) == 2
        @test watched["__DEFAULT_CONFIG__"] == JETLS.DEFAULT_CONFIG
        @test watched["/project/.JETLSConfig.toml"] == config
        files = collect(keys(watched))
        @test issorted(files, order=JETLS.ConfigFileOrder())
    end

    @testset "haskey and get" begin
        watched = JETLS.WatchedConfigFiles()
        config = JETLS.ConfigDict("key" => "value")

        @test !haskey(watched, "___UNDEFINED___")
        @test get(watched, "___UNDEFINED___", "default") == "default"
        watched["/project/.JETLSConfig.toml"] = config
        @test haskey(watched, "/project/.JETLSConfig.toml")
        @test get(watched, "/project/.JETLSConfig.toml", "default") == config
        @test watched["/project/.JETLSConfig.toml"] == config
    end

    @testset "delete!" begin
        watched = JETLS.WatchedConfigFiles()
        config = JETLS.ConfigDict("key1" => "value1")
        watched["/project/.JETLSConfig.toml"] = config

        @test length(watched) == 2
        delete!(watched, "/project/.JETLSConfig.toml")
        @test length(watched) == 1
        @test !haskey(watched, "/project/.JETLSConfig.toml")
        @test haskey(watched, "__DEFAULT_CONFIG__")
        @test collect(keys(watched)) == ["__DEFAULT_CONFIG__"]

        # "__DEFAULT_CONFIG__" should not be deleted
        @test_throws ArgumentError delete!(watched, "__DEFAULT_CONFIG__")
        @test length(watched) == 1
        @test haskey(watched, "__DEFAULT_CONFIG__")
    end

    @testset "KeyError handling" begin
        watched = JETLS.WatchedConfigFiles()
        @test_throws KeyError watched["/nonexistent/.JETLSConfig.toml"]
    end

    @testset "priority with multiple config files" begin
        watched = JETLS.WatchedConfigFiles()
        watched["/home/user/.JETLSConfig.toml"] = JETLS.ConfigDict("source" => "home")
        files = collect(keys(watched))

        # Should be sorted by ConfigFileOrder
        @test issorted(files, order=JETLS.ConfigFileOrder())
        # Higher priority config files come first in ConfigFileOrder
        @test files[1] == "/home/user/.JETLSConfig.toml"
        @test files[2] == "__DEFAULT_CONFIG__"
    end
end

@testset "`merge_reload_required_keys`" begin
    dict1 = JETLS.ConfigDict(
        "performance" => JETLS.ConfigDict("full_analysis" => JETLS.ConfigDict("debounce" => 1.0)))
    dict2 = JETLS.ConfigDict(
        "performance" => JETLS.ConfigDict("full_analysis" => JETLS.ConfigDict("throttle" => 5.0)),
        "testrunner" => JETLS.ConfigDict("executable" => "testrunner2"))

    result = JETLS.merge_reload_required_keys(dict1, dict2)

    # Should merge reload-required keys only
    @test result["performance"]["full_analysis"]["debounce"] == 1.0
    @test result["performance"]["full_analysis"]["throttle"] == 5.0
    # testrunner.executable should NOT be merged (it's false in CONFIG_RELOAD_REQUIRED)
    @test !haskey(result, "testrunner")
end

@testset "configuration utilities" begin
    default_config_origin = JETLS.DEFAULT_CONFIG
    is_reload_required_key_origin = JETLS.CONFIG_RELOAD_REQUIRED
    try
        JETLS.DEFAULT_CONFIG = TEST_DICT
        JETLS.CONFIG_RELOAD_REQUIRED = TEST_RELOAD_REQUIRED

        @testset "access_nested_dict" begin
            @test JETLS.access_nested_dict(TEST_DICT, "test_key1") == "test_value1"
            @test JETLS.access_nested_dict(TEST_DICT, "test_key2", "nested_key1") == "nested_value1"
            @test JETLS.access_nested_dict(TEST_DICT, "test_key2", "nested_key2", "deep_nested_key1") == "deep_nested_value1"
            @test JETLS.access_nested_dict(TEST_DICT, "test_key2", "nested_key2", "deep_nested_key3") === nothing
            @test JETLS.access_nested_dict(TEST_DICT, "non_existent_key") === nothing

            let empty_dict = JETLS.ConfigDict()
                @test JETLS.access_nested_dict(empty_dict, "key") === nothing
            end

            let dict = JETLS.ConfigDict("scalar" => "value")
                @test JETLS.access_nested_dict(dict, "scalar", "unknown") === nothing
                @test JETLS.access_nested_dict(dict, "scalar") == "value"
            end
        end

        @testset "collect_unmatched_keys" begin
            # It is correct that `test_key2.diffname_2.diffname_3` is not included,
            # because `collect_unmatched_keys` does not track deeper nested differences in key names.
            @test Set(JETLS.collect_unmatched_keys(TEST_DICT_DIFFERENT_KEY, TEST_DICT)) == Set([
                ["diffname_1"],
                ["test_key2", "diffname_2"],
            ])

            @test isempty(JETLS.collect_unmatched_keys(TEST_DICT, TEST_DICT))
            @test isempty(JETLS.collect_unmatched_keys(TEST_DICT, TEST_DICT_DIFFERENT_VALUE))

            # single-arg version should use DEFAULT_CONFIG
            @test JETLS.collect_unmatched_keys(TEST_DICT_DIFFERENT_KEY) ==
                  JETLS.collect_unmatched_keys(TEST_DICT_DIFFERENT_KEY, JETLS.DEFAULT_CONFIG)
        end

        @testset "config files priority" begin
            files = ["/foo/bar/.JETLSConfig.toml", "__DEFAULT_CONFIG__"]
            @test sort!(files, order=JETLS.ConfigFileOrder()) == [
                "/foo/bar/.JETLSConfig.toml",       # highest priority
                "__DEFAULT_CONFIG__"                # lowest priority
            ]
        end

        @testset "config manager" begin
            manager = JETLS.ConfigManager()
            JETLS.register_config!(manager, "/foo/bar/.JETLSConfig.toml", TEST_DICT)
            JETLS.fix_reload_required_settings!(manager)

            @test JETLS.get_config(manager, "test_key1") === "test_value1"
            @test JETLS.get_config(manager, "test_key2", "nested_key1") === "nested_value1"
            @test JETLS.get_config(manager, "test_key2", "nested_key2", "deep_nested_key1") === "deep_nested_value1"
            @test JETLS.get_config(manager, "test_key2", "nested_key2", "deep_nested_key3") === nothing
            @test JETLS.get_config(manager, "non_existent_key") === nothing

            JETLS.register_config!(manager, "__DEFAULT_CONFIG__", TEST_DICT_DIFFERENT_VALUE)
            # __DEFAULT_CONFIG__ has lower priority than the file, so it should not change
            @test JETLS.get_config(manager, "test_key1") === "test_value1"
            @test JETLS.get_config(manager, "test_key2", "nested_key1") === "nested_value1"
            @test JETLS.get_config(manager, "test_key2", "nested_key2", "deep_nested_key1") === "deep_nested_value1"
            @test JETLS.get_config(manager, "test_key2", "nested_key2", "deep_nested_key3") === nothing
            @test JETLS.get_config(manager, "non_existent_key") === nothing

            changed_reload_required = Set{String}()
            JETLS.merge_config!(manager, "/foo/bar/.JETLSConfig.toml", TEST_DICT_DIFFERENT_VALUE) do _, path, _
                push!(changed_reload_required, join(path, "."))
            end
            # `on_reload_required` should be called for changed keys that require reload
            @test changed_reload_required == Set(["test_key1", "test_key2.nested_key2.deep_nested_key1"])
            # non reload_required keys should be changed dynamically
            @test JETLS.get_config(manager,  "test_key2", "nested_key2", "deep_nested_key2") == "newvalue_3"
            # reload_required keys should not be changed dynamically without explicit update
            @test JETLS.get_config(manager, "test_key1") == "test_value1"
            @test JETLS.get_config(manager, "test_key2", "nested_key2", "deep_nested_key1") == "deep_nested_value1"
        end
    finally
        JETLS.DEFAULT_CONFIG = default_config_origin
        JETLS.CONFIG_RELOAD_REQUIRED = is_reload_required_key_origin
    end
end

@testset "`traverse_merge`" begin
    # basic merge with custom on_leaf function
    let target = JETLS.ConfigDict("a" => 1)
        source = JETLS.ConfigDict("b" => 2)
        collected_calls = Tuple{Vector{String},Any}[]
        result = JETLS.traverse_merge(target, source) do path, v
            push!(collected_calls, (path, v))
            v * 10
        end
        @test result == JETLS.ConfigDict("a" => 1, "b" => 20)
        @test length(collected_calls) == 1
        @test collected_calls[1][1] == ["b"]
        @test collected_calls[1][2] == 2
    end

    # nested merge with custom on_leaf
    let target = JETLS.ConfigDict("nested" => JETLS.ConfigDict("a" => 1))
        source = JETLS.ConfigDict("nested" => JETLS.ConfigDict("b" => 2))
        collected_paths = Vector{String}[]
        result = JETLS.traverse_merge(target, source) do path, v
            push!(collected_paths, path)
            v
        end
        @test result == JETLS.ConfigDict("nested" => JETLS.ConfigDict("a" => 1, "b" => 2))
        @test collected_paths == [["nested", "b"]]
    end

    # creating new nested structure
    let target = JETLS.ConfigDict()
        source = JETLS.ConfigDict("new" => JETLS.ConfigDict("deep" => "value"))
        result = JETLS.traverse_merge(target, source) do _, v
            v
        end
        @test result == JETLS.ConfigDict("new" => JETLS.ConfigDict("deep" => "value"))
    end

    # overwriting non-dict with dict
    let target = JETLS.ConfigDict("key" => "scalar")
        source = JETLS.ConfigDict("key" => JETLS.ConfigDict("nested" => "value"))
        result = JETLS.traverse_merge(target, source) do _, v
            v
        end
        @test result == JETLS.ConfigDict("key" => JETLS.ConfigDict("nested" => "value"))
    end

    # filtering with on_leaf returning nothing
    let base = JETLS.ConfigDict("a" => 1, "b" => 2)
        overlay = JETLS.ConfigDict("b" => 3, "c" => 4)
        result = JETLS.traverse_merge(base, overlay) do path, v
            path[end] == "b" ? v : nothing  # only merge keys ending with "b"
        end
        @test result == JETLS.ConfigDict("a" => 1, "b" => 3)  # only "b" was merged
    end

    # filtering with nested paths
    let base = JETLS.ConfigDict("performance" => JETLS.ConfigDict("full_analysis" => JETLS.ConfigDict("debounce" => 1.0)))
        overlay = JETLS.ConfigDict("performance" => JETLS.ConfigDict("full_analysis" => JETLS.ConfigDict("throttle" => 5.0)))
        result = JETLS.traverse_merge(base, overlay) do path, v
            path == ["performance", "full_analysis", "throttle"] ? v : nothing
        end
        @test result["performance"]["full_analysis"]["debounce"] == 1.0
        @test result["performance"]["full_analysis"]["throttle"] == 5.0
    end
end

@testset "`is_reload_required_key`" begin
    default_config_origin = JETLS.CONFIG_RELOAD_REQUIRED
    try
        JETLS.CONFIG_RELOAD_REQUIRED = JETLS.ConfigDict(
            "performance" => JETLS.ConfigDict(
                "full_analysis" => JETLS.ConfigDict(
                    "debounce" => true,
                    "throttle" => false
                )
            ),
            "simple_key" => true
        )

        @test JETLS.is_reload_required_key("performance", "full_analysis", "debounce") === true
        @test JETLS.is_reload_required_key("performance", "full_analysis", "throttle") === false
        @test JETLS.is_reload_required_key("simple_key") === true
        @test JETLS.is_reload_required_key("nonexistent") === false
        @test JETLS.is_reload_required_key("performance", "nonexistent") === false
    finally
        JETLS.CONFIG_RELOAD_REQUIRED = default_config_origin
    end
end

@testset "`is_config_file`" begin
    @test JETLS.is_config_file("__DEFAULT_CONFIG__") === true
    @test JETLS.is_config_file("/path/to/.JETLSConfig.toml") === true
    @test JETLS.is_config_file(".JETLSConfig.toml") === true
    @test JETLS.is_config_file("config.toml") === false
    @test JETLS.is_config_file("/path/to/regular.txt") === false
    @test JETLS.is_config_file("") === false
end

@testset "`is_watched_file`" begin
    let manager = JETLS.ConfigManager()
        filepath = "/path/to/.JETLSConfig.toml"
        @test JETLS.is_watched_file(manager, filepath) === false

        JETLS.register_config!(manager, filepath, JETLS.ConfigDict("key" => "value"))
        @test JETLS.is_watched_file(manager, filepath) === true
    end
end

@testset "`cleanup_empty_dicts`" begin
    let dict = JETLS.ConfigDict(
            "keep" => "value",
            "empty_nested" => JETLS.ConfigDict(),
            "nested" => JETLS.ConfigDict(
                "keep_nested" => "value",
                "empty_deep" => JETLS.ConfigDict(
                    "empty_deeper" => JETLS.ConfigDict()
                )
            )
        )
        result = JETLS.cleanup_empty_dicts(dict)
        @test result == JETLS.ConfigDict(
            "keep" => "value",
            "nested" => JETLS.ConfigDict("keep_nested" => "value")
        )
    end

    # completely empty dict should remain empty
    let dict = JETLS.ConfigDict()
        result = JETLS.cleanup_empty_dicts(dict)
        @test result == JETLS.ConfigDict()
    end

    # dict with only empty nested dicts should become empty
    let dict = JETLS.ConfigDict("empty" => JETLS.ConfigDict())
        result = JETLS.cleanup_empty_dicts(dict)
        @test result == JETLS.ConfigDict()
    end

    let dict = JETLS.ConfigDict(
        "nested" => JETLS.ConfigDict(
            "nested2 " => JETLS.ConfigDict(
                "deep_nested" => 1
                )
            )
        )
        result = JETLS.cleanup_empty_dicts(dict)
        @test result == JETLS.ConfigDict(
            "nested" => JETLS.ConfigDict(
                "nested2 " => JETLS.ConfigDict(
                    "deep_nested" => 1
                )
            )
        )
    end
end

@testset "`register_config!` edge cases" begin
    # non-config file should be rejected
    let manager = JETLS.ConfigManager()
        filepath = "regular.txt"
        initial_count = length(manager.watched_files)
        JETLS.register_config!(manager, filepath, JETLS.ConfigDict("key" => "value"))
        @test length(manager.watched_files) == initial_count
    end

    # duplicate registration should be ignored
    let manager = JETLS.ConfigManager()
        filepath = ".JETLSConfig.toml"
        config1 = JETLS.ConfigDict("key1" => "value1")
        config2 = JETLS.ConfigDict("key2" => "value2")

        JETLS.register_config!(manager, filepath, config1)
        @test manager.watched_files[filepath] == config1

        # second registration should be ignored
        JETLS.register_config!(manager, filepath, config2)
        @test manager.watched_files[filepath] == config1  # unchanged
    end
end

@testset "`fix_reload_required_settings!` comprehensive" begin
    default_config_origin = JETLS.DEFAULT_CONFIG
    is_reload_required_key_origin = JETLS.CONFIG_RELOAD_REQUIRED
    try
        JETLS.DEFAULT_CONFIG = JETLS.ConfigDict(
            "performance" => JETLS.ConfigDict(
                "full_analysis" => JETLS.ConfigDict(
                    "debounce" => 1.0,
                    "throttle" => 5.0
                )
            ),
            "testrunner" => JETLS.ConfigDict(
                "executable" => "testrunner"
            )
        )
        JETLS.CONFIG_RELOAD_REQUIRED = JETLS.ConfigDict(
            "performance" => JETLS.ConfigDict(
                "full_analysis" => JETLS.ConfigDict(
                    "debounce" => true,
                    "throttle" => true
                )
            ),
            "testrunner" => JETLS.ConfigDict(
                "executable" => false
            )
        )

        # test priority handling
        let manager = JETLS.ConfigManager()
            high_priority_config = JETLS.ConfigDict(
                "performance" => JETLS.ConfigDict(
                    "full_analysis" => JETLS.ConfigDict("debounce" => 2.0)
                )
            )
            low_priority_config = JETLS.ConfigDict(
                "performance" => JETLS.ConfigDict(
                    "full_analysis" => JETLS.ConfigDict("debounce" => 999.0)
                ),
                "testrunner" => JETLS.ConfigDict("executable" => "custom")
            )

            JETLS.register_config!(manager, "__DEFAULT_CONFIG__", low_priority_config)
            JETLS.register_config!(manager, "/path/.JETLSConfig.toml", high_priority_config)
            JETLS.fix_reload_required_settings!(manager)

            # high priority should win for reload-required keys
            @test manager.reload_required_setting["performance"]["full_analysis"]["debounce"] == 2.0
            # testrunner.executable is not reload-required, so should not be in reload_required_setting
            @test !haskey(manager.reload_required_setting, "testrunner")
        end
    finally
        JETLS.DEFAULT_CONFIG = default_config_origin
        JETLS.CONFIG_RELOAD_REQUIRED = is_reload_required_key_origin
    end
end

end
