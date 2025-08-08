module test_config

using Test
using JETLS

const TEST_DICT = Dict{String, Any}(
    "test_key1" => "test_value1",
    "test_key2" => Dict{String, Any}(
        "nested_key1" => "nested_value1",
        "nested_key2" => Dict{String, Any}(
            "deep_nested_key1" => "deep_nested_value1",
            "deep_nested_key2" => "deep_nested_value2"
        )
    )
)

const TEST_DICT_DIFFERENT_VALUE = Dict{String, Any}(
    "test_key1" => "newvalue_1",  # different value (reload required)
    "test_key2" => Dict{String, Any}(
        "nested_key1" => "nested_value1",
        "nested_key2" => Dict{String, Any}(
            "deep_nested_key1" => "newvalue_2", # different value (reload required)
            "deep_nested_key2" => "newvalue_3"  # different value (reload not required)
        )
    )
)

const TEST_DICT_DIFFERENT_KEY = Dict{String, Any}(
    "diffname_1" => "test_value1",  # different key name
    "test_key2" => Dict{String, Any}(
        "nested_key1" => "nested_value1",
        "diffname_2" => Dict{String, Any}(       # different key name
            "deep_nested_key1" => "deep_nested_value1",
            "diffname_3" => "deep_nested_value2" # different key under a different key
        )
    ),
)

const TEST_RELOAD_REQUIRED = Dict{String, Any}(
    "test_key1" => true,
    "test_key2" => Dict{String, Any}(
        "nested_key1" => false,
        "nested_key2" => Dict{String, Any}(
            "deep_nested_key1" => true,
            "deep_nested_key2" => false
        )
    )
)

@testset "WatchedConfigFiles" begin
    @testset "constructor and basic operations" begin
        watched = JETLS.WatchedConfigFiles()
        @test length(watched) == 0
        @test isempty(keys(watched))
        @test isempty(values(watched))
    end

    @testset "setindex! and getindex" begin
        watched = JETLS.WatchedConfigFiles()
        config1 = Dict{String,Any}("key1" => "value1")
        config2 = Dict{String,Any}("key2" => "value2")

        watched["__DEFAULT_CONFIG__"] = config1
        watched["/project/.JETLSConfig.toml"] = config2
        @test length(watched) == 2
        @test watched["__DEFAULT_CONFIG__"] == config1
        @test watched["/project/.JETLSConfig.toml"] == config2
        files = collect(keys(watched))
        @test issorted(files, order=JETLS.ConfigFileOrder())
    end

    @testset "haskey and get" begin
        watched = JETLS.WatchedConfigFiles()
        config = Dict{String,Any}("key" => "value")

        @test !haskey(watched, "___UNDEFINED___")
        @test get(watched, "___UNDEFINED___", "default") == "default"
        watched["/project/.JETLSConfig.toml"] = config
        @test haskey(watched, "/project/.JETLSConfig.toml")
        @test get(watched, "/project/.JETLSConfig.toml", "default") == config
        @test watched["/project/.JETLSConfig.toml"] == config
    end

    @testset "delete!" begin
        watched = JETLS.WatchedConfigFiles()
        config1 = Dict{String,Any}("key1" => "value1")
        config2 = Dict{String,Any}("key2" => "value2")
        watched["/project/.JETLSConfig.toml"] = config1
        watched["__DEFAULT_CONFIG__"] = config2

        @test length(watched) == 2
        delete!(watched, "/project/.JETLSConfig.toml")
        @test length(watched) == 1
        @test !haskey(watched, "/project/.JETLSConfig.toml")
        @test haskey(watched, "__DEFAULT_CONFIG__")
        @test collect(keys(watched)) == ["__DEFAULT_CONFIG__"]

        # "__DEFAULT_CONFIG__" should not be deleted
        delete!(watched, "__DEFAULT_CONFIG__")
        @test length(watched) == 1
        @test haskey(watched, "__DEFAULT_CONFIG__")
    end

    @testset "KeyError handling" begin
        watched = JETLS.WatchedConfigFiles()
        @test_throws KeyError watched["/nonexistent/.JETLSConfig.toml"]
    end

    @testset "priority with multiple config files" begin
        watched = JETLS.WatchedConfigFiles()
        # Add configs in reverse priority order
        watched["__DEFAULT_CONFIG__"] = Dict{String,Any}("source" => "default")
        watched["/home/user/.JETLSConfig.toml"] = Dict{String,Any}("source" => "home")
        files = collect(keys(watched))
        configs = collect(values(watched))

        # Should be sorted by ConfigFileOrder
        @test issorted(files, order=JETLS.ConfigFileOrder())
        # Higher priority config files come first in ConfigFileOrder
        @test files[1] == "/home/user/.JETLSConfig.toml"
        @test files[2] == "__DEFAULT_CONFIG__"
        @test configs[1]["source"] == "home"
        @test configs[2]["source"] == "default"
    end
end

@testset "`selective_merge!`" begin
    # basic overwrite with no filter (allow all)
    dict1 = Dict{String, Any}("a" => 1, "b" => 2)
    dict2 = Dict{String, Any}("b" => 3, "c" => 4)
    JETLS.selective_merge!(dict1, dict2)
    @test dict1 == Dict{String, Any}("a" => 1, "b" => 3, "c" => 4)
    @test dict2 == Dict{String, Any}("b" => 3, "c" => 4) # dict2 should remain unchanged

    # nested merge with no filter
    dict1 = Dict{String, Any}("a" => Dict{String, Any}("x" => 1))
    dict2 = Dict{String, Any}("a" => Dict{String, Any}("y" => 2))
    JETLS.selective_merge!(dict1, dict2)
    @test dict1 == Dict{String, Any}("a" => Dict{String, Any}("x" => 1, "y" => 2))
    @test dict2 == Dict{String, Any}("a" => Dict{String, Any}("y" => 2))

    # overwrite nested dict with value (no filter)
    dict1 = Dict{String, Any}("a" => Dict{String, Any}("x" => 1))
    dict2 = Dict{String, Any}("a" => "scalar")
    JETLS.selective_merge!(dict1, dict2)
    @test dict1 == Dict{String, Any}("a" => "scalar")
    @test dict2 == Dict{String, Any}("a" => "scalar")

    # overwrite value with nested dict (no filter)
    dict1 = Dict{String, Any}("a" => "scalar")
    dict2 = Dict{String, Any}("a" => Dict{String, Any}("x" => 1))
    JETLS.selective_merge!(dict1, dict2)
    @test dict1 == Dict{String, Any}("a" => Dict{String, Any}("x" => 1))
    @test dict2 == Dict{String, Any}("a" => Dict{String, Any}("x" => 1))

    # filtering: only allow specific keys
    dict1 = Dict{String, Any}("a" => 1, "b" => 2)
    dict2 = Dict{String, Any}("b" => 3, "c" => 4)
    JETLS.selective_merge!(dict1, dict2, path -> path[end] == "b")
    @test dict1 == Dict{String, Any}("a" => 1, "b" => 3) # only "b" was merged
    @test dict2 == Dict{String, Any}("b" => 3, "c" => 4)

    # filtering: block all keys
    dict1 = Dict{String, Any}("a" => 1, "b" => 2)
    dict2 = Dict{String, Any}("b" => 3, "c" => 4)
    JETLS.selective_merge!(dict1, dict2, Returns(false))
    @test dict1 == Dict{String, Any}("a" => 1, "b" => 2) # nothing merged
    @test dict2 == Dict{String, Any}("b" => 3, "c" => 4)

    # filtering with nested paths
    dict1 = Dict{String, Any}("performance" => Dict{String, Any}("full_analysis" => Dict{String, Any}("debounce" => 1.0)))
    dict2 = Dict{String, Any}("performance" => Dict{String, Any}("full_analysis" => Dict{String, Any}("throttle" => 5.0)))
    JETLS.selective_merge!(dict1, dict2, path -> path == ["performance", "full_analysis", "throttle"])
    @test dict1["performance"]["full_analysis"]["debounce"] == 1.0
    @test dict1["performance"]["full_analysis"]["throttle"] == 5.0

    # deeply nested merge (no filter)
    dict1 = Dict{String, Any}("a" => Dict{String, Any}("b" => Dict{String, Any}("c" => 1)))
    dict2 = Dict{String, Any}("a" => Dict{String, Any}("b" => Dict{String, Any}("d" => 2)))
    JETLS.selective_merge!(dict1, dict2)
    @test dict1 == Dict{String, Any}("a" => Dict{String, Any}("b" => Dict{String, Any}("c" => 1, "d" => 2)))
    @test dict2 == Dict{String, Any}("a" => Dict{String, Any}("b" => Dict{String, Any}("d" => 2)))

    # multiple top-level keys
    dict1 = Dict{String, Any}("a" => 1, "b" => Dict{String, Any}("x" => 10))
    dict2 = Dict{String, Any}("b" => Dict{String, Any}("y" => 20), "c" => 3)
    JETLS.selective_merge!(dict1, dict2)
    @test dict1 == Dict{String, Any}("a" => 1, "b" => Dict{String, Any}("x" => 10, "y" => 20), "c" => 3)

    # realistic deeply nested update
    dict1 = Dict{String, Any}(
        "config" => Dict{String, Any}(
            "editor" => Dict{String, Any}(
                "font" => Dict{String, Any}("size" => 12, "family" => "monospace"),
                "theme" => "light"
            ),
            "lint" => Dict{String, Any}("enabled" => true)
        )
    )

    dict2 = Dict{String, Any}(
        "config" => Dict{String, Any}(
            "editor" => Dict{String, Any}(
                "font" => Dict{String, Any}("size" => 14),  # update only size
                "theme" => "dark",             # overwrite theme
                "keymap" => "vim"              # new key added
            ),
            "lint" => false                   # overwrite entire value
        )
    )

    JETLS.selective_merge!(dict1, dict2)

    @test dict1 == Dict{String, Any}(
        "config" => Dict{String, Any}(
            "editor" => Dict{String, Any}(
                "font" => Dict{String, Any}("size" => 14, "family" => "monospace"),
                "theme" => "dark",
                "keymap" => "vim"
            ),
            "lint" => false
        )
    )
end

@testset "`merge_reload_required_keys!`" begin
    dict1 = Dict{String, Any}(
        "performance" => Dict{String, Any}("full_analysis" => Dict{String, Any}("debounce" => 1.0)))
    dict2 = Dict{String, Any}(
        "performance" => Dict{String, Any}("full_analysis" => Dict{String, Any}("throttle" => 5.0)),
        "testrunner" => Dict{String, Any}("executable" => "testrunner2"))

    JETLS.merge_reload_required_keys!(dict1, dict2)

    # Should merge reload-required keys only
    @test dict1["performance"]["full_analysis"]["debounce"] == 1.0
    @test dict1["performance"]["full_analysis"]["throttle"] == 5.0
    # testrunner.executable should NOT be merged (it's false in CONFIG_RELOAD_REQUIRED)
    @test !haskey(dict1, "testrunner")
end


@testset "configuration utilities" begin
    default_config_origin = deepcopy(JETLS.DEFAULT_CONFIG)
    is_reload_required_key_origin = deepcopy(JETLS.CONFIG_RELOAD_REQUIRED)
    try
        global JETLS.DEFAULT_CONFIG = TEST_DICT
        global JETLS.CONFIG_RELOAD_REQUIRED = TEST_RELOAD_REQUIRED

        @testset "access_nested_dict" begin
            @test JETLS.access_nested_dict(TEST_DICT, "test_key1") == "test_value1"
            @test JETLS.access_nested_dict(TEST_DICT, "test_key2", "nested_key1") == "nested_value1"
            @test JETLS.access_nested_dict(TEST_DICT, "test_key2", "nested_key2", "deep_nested_key1") == "deep_nested_value1"
            @test JETLS.access_nested_dict(TEST_DICT, "test_key2", "nested_key2", "deep_nested_key3") === nothing
            @test JETLS.access_nested_dict(TEST_DICT, "non_existent_key") === nothing

            let empty_dict = Dict{String, Any}()
                @test JETLS.access_nested_dict(empty_dict, "key") === nothing
            end

            let dict = Dict{String, Any}("scalar" => "value")
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
            JETLS.merge_config!(manager, "/foo/bar/.JETLSConfig.toml", TEST_DICT_DIFFERENT_VALUE) do _, _, _, path
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
        global JETLS.DEFAULT_CONFIG = default_config_origin
        global JETLS.CONFIG_RELOAD_REQUIRED = is_reload_required_key_origin
    end
end

@testset "`traverse_merge!`" begin
    # basic merge with custom on_leaf function
    let target = Dict{String, Any}("a" => 1)
        source = Dict{String, Any}("b" => 2)
        collected_calls = Tuple{Dict{String,Any}, String, Any, Vector{String}}[]
        JETLS.traverse_merge!(target, source, String[]) do t, k, v, path
            push!(collected_calls, (t, k, v, path))
            t[k] = v * 10
        end
        @test target == Dict{String, Any}("a" => 1, "b" => 20)
        @test length(collected_calls) == 1
        @test collected_calls[1][2] == "b"
        @test collected_calls[1][3] == 2
        @test collected_calls[1][4] == ["b"]
    end

    # nested merge with custom on_leaf
    let target = Dict{String, Any}("nested" => Dict{String, Any}("a" => 1))
        source = Dict{String, Any}("nested" => Dict{String, Any}("b" => 2))
        collected_paths = Vector{String}[]
        JETLS.traverse_merge!(target, source, String[]) do t, k, v, path
            push!(collected_paths, path)
            t[k] = v
        end
        @test target == Dict{String, Any}("nested" => Dict{String, Any}("a" => 1, "b" => 2))
        @test collected_paths == [["nested", "b"]]
    end

    # creating new nested structure
    let target = Dict{String, Any}()
        source = Dict{String, Any}("new" => Dict{String, Any}("deep" => "value"))
        JETLS.traverse_merge!(target, source, String[]) do t, k, v, path
            t[k] = v
        end
        @test target == Dict{String, Any}("new" => Dict{String, Any}("deep" => "value"))
    end

    # overwriting non-dict with dict
    let target = Dict{String, Any}("key" => "scalar")
        source = Dict{String, Any}("key" => Dict{String, Any}("nested" => "value"))
        JETLS.traverse_merge!(target, source, String[]) do t, k, v, path
            t[k] = v
        end
        @test target == Dict{String, Any}("key" => Dict{String, Any}("nested" => "value"))
    end
end

@testset "`is_reload_required_key`" begin
    default_config_origin = deepcopy(JETLS.CONFIG_RELOAD_REQUIRED)
    try
        global JETLS.CONFIG_RELOAD_REQUIRED = Dict{String,Any}(
            "performance" => Dict{String,Any}(
                "full_analysis" => Dict{String,Any}(
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
        global JETLS.CONFIG_RELOAD_REQUIRED = default_config_origin
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

        JETLS.register_config!(manager, filepath, Dict{String,Any}("key" => "value"))
        @test JETLS.is_watched_file(manager, filepath) === true
    end
end

@testset "`cleanup_empty_dicts!`" begin
    let dict = Dict{String, Any}(
        "keep" => "value",
        "empty_nested" => Dict{String, Any}(),
        "nested" => Dict{String, Any}(
            "keep_nested" => "value",
            "empty_deep" => Dict{String, Any}(
                "empty_deeper" => Dict{String, Any}()
            )
        )
    )
        JETLS.cleanup_empty_dicts!(dict)
        @test dict == Dict{String, Any}(
            "keep" => "value",
            "nested" => Dict{String, Any}("keep_nested" => "value")
        )
    end

    # completely empty dict should remain empty
    let dict = Dict{String, Any}()
        JETLS.cleanup_empty_dicts!(dict)
        @test dict == Dict{String, Any}()
    end

    # dict with only empty nested dicts should become empty
    let dict = Dict{String, Any}("empty" => Dict{String, Any}())
        JETLS.cleanup_empty_dicts!(dict)
        @test dict == Dict{String, Any}()
    end

    let dict = Dict{String, Any}(
        "nested" => Dict{String, Any}(
            "nested2 " => Dict{String, Any}(
                "deep_nested" => 1
                )
            )
        )
        JETLS.cleanup_empty_dicts!(dict)
        @test dict == Dict{String, Any}(
            "nested" => Dict{String, Any}(
                "nested2 " => Dict{String, Any}(
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
        JETLS.register_config!(manager, filepath, Dict{String,Any}("key" => "value"))
        @test length(manager.watched_files) == initial_count
    end

    # duplicate registration should be ignored
    let manager = JETLS.ConfigManager()
        filepath = ".JETLSConfig.toml"
        config1 = Dict{String,Any}("key1" => "value1")
        config2 = Dict{String,Any}("key2" => "value2")

        JETLS.register_config!(manager, filepath, config1)
        @test manager.watched_files[filepath] == config1

        # second registration should be ignored
        JETLS.register_config!(manager, filepath, config2)
        @test manager.watched_files[filepath] == config1  # unchanged
    end
end

@testset "`fix_reload_required_settings!` comprehensive" begin
    default_config_origin = deepcopy(JETLS.DEFAULT_CONFIG)
    is_reload_required_key_origin = deepcopy(JETLS.CONFIG_RELOAD_REQUIRED)
    try
        global JETLS.DEFAULT_CONFIG = Dict{String,Any}(
            "performance" => Dict{String,Any}(
                "full_analysis" => Dict{String,Any}(
                    "debounce" => 1.0,
                    "throttle" => 5.0
                )
            ),
            "testrunner" => Dict{String,Any}(
                "executable" => "testrunner"
            )
        )
        global JETLS.CONFIG_RELOAD_REQUIRED = Dict{String,Any}(
            "performance" => Dict{String,Any}(
                "full_analysis" => Dict{String,Any}(
                    "debounce" => true,
                    "throttle" => true
                )
            ),
            "testrunner" => Dict{String,Any}(
                "executable" => false
            )
        )

        # test priority handling
        let manager = JETLS.ConfigManager()
            high_priority_config = Dict{String,Any}(
                "performance" => Dict{String,Any}(
                    "full_analysis" => Dict{String,Any}("debounce" => 2.0)
                )
            )
            low_priority_config = Dict{String,Any}(
                "performance" => Dict{String,Any}(
                    "full_analysis" => Dict{String,Any}("debounce" => 999.0)
                ),
                "testrunner" => Dict{String,Any}("executable" => "custom")
            )

            JETLS.register_config!(manager, "__DEFAULT_CONFIG__", low_priority_config)
            JETLS.register_config!(manager, "/path/.JETLSConfig.toml", high_priority_config)
            JETLS.fix_reload_required_settings!(manager)

            # high priority should win for reload-required keys
            @test manager.reload_required_setting["performance"]["full_analysis"]["debounce"] == 2.0
            # testrunner.executable is not reload-required, so should not be in reload_required_setting
            @test !haskey(manager.reload_required_setting, "testrunner")
        end

        # test empty manager
        let manager = JETLS.ConfigManager()
            JETLS.fix_reload_required_settings!(manager)
            @test isempty(manager.reload_required_setting)
        end
    finally
        global JETLS.DEFAULT_CONFIG = default_config_origin
        global JETLS.CONFIG_RELOAD_REQUIRED = is_reload_required_key_origin
    end
end

end
