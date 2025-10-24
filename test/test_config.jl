module test_config

using Test
using JETLS

@testset "Configuration utilities" begin
    @testset "`get_default_config`" begin
        @test JETLS.get_default_config(:testrunner, :executable) ==
            (@static Sys.iswindows() ? "testrunner.bat" : "testrunner")
        @test JETLS.get_default_config(:formatter, :runic, :executable) ==
            (@static Sys.iswindows() ? "runic.bat" : "runic")

        @test_throws FieldError JETLS.get_default_config(:nonexistent)
        @test_throws FieldError JETLS.get_default_config(:full_analysis, :nonexistent)
    end

    @testset "`is_static_setting`" begin
        @test !JETLS.is_static_setting(:internal, :dynamic_setting)
        @test JETLS.is_static_setting(:internal, :static_setting)
        @test !JETLS.is_static_setting(:testrunner, :executable)
        @test !JETLS.is_static_setting(:formatter, :runic, :executable)
    end

    @testset "`merge_setting`" begin
        base_config = JETLS.JETLSConfig(;
            full_analysis=JETLS.FullAnalysisConfig(1.0),
            testrunner=JETLS.TestRunnerConfig("base_runner"),
            internal=JETLS.InternalConfig(10, 20)
        )

        overlay_config = JETLS.JETLSConfig(;
            full_analysis=JETLS.FullAnalysisConfig(2.0),
            testrunner=nothing,
            internal=JETLS.InternalConfig(30, nothing)
        )

        merged = JETLS.merge_setting(base_config, overlay_config)

        @test JETLS.getobjpath(merged, :full_analysis, :debounce) == 2.0
        @test JETLS.getobjpath(merged, :testrunner, :executable) == "base_runner"
        @test JETLS.getobjpath(merged, :internal, :static_setting) == 30
        @test JETLS.getobjpath(merged, :internal, :dynamic_setting) == 20
    end

    @testset "`on_difference`" begin
        let config1 = JETLS.JETLSConfig(;
                full_analysis=JETLS.FullAnalysisConfig(1.0),
                testrunner=JETLS.TestRunnerConfig("runner1"),
                internal=JETLS.InternalConfig(1, 1)
            )
            config2 = JETLS.JETLSConfig(;
                full_analysis=JETLS.FullAnalysisConfig(2.0),
                testrunner=JETLS.TestRunnerConfig("runner2"),
                internal=nothing
            )
            paths_called = []
            JETLS.on_difference(config1, config2) do _, new_val, path
                push!(paths_called, path)
                new_val
            end
            @test Set(paths_called) == Set([
                (:full_analysis, :debounce),
                (:testrunner, :executable),
                (:internal, :static_setting),
                (:internal, :dynamic_setting) # even though new_val is nothing, track the path
            ])
        end
    end

    @testset "`is_config_file`" begin
        @test JETLS.is_config_file("/path/to/.JETLSConfig.toml")
        @test JETLS.is_config_file(".JETLSConfig.toml")
        @test !JETLS.is_config_file("/path/to/Non.JETLSConfig.toml")
        @test !JETLS.is_config_file("config.toml")
        @test !JETLS.is_config_file("/path/to/regular.txt")
    end
end

@testset "ConfigDict utilities" begin
    TEST_DICT = JETLS.ConfigDict(
        "test_key1" => "test_value1",
        "test_key2" => JETLS.ConfigDict(
            "nested_key1" => "nested_value1",
            "nested_key2" => JETLS.ConfigDict(
                "deep_nested_key1" => "deep_nested_value1",
                "deep_nested_key2" => "deep_nested_value2"
            )
        )
    )

    TEST_DICT_DIFFERENT_KEY = JETLS.ConfigDict(
        "diffname_1" => "test_value1",
        "test_key2" => JETLS.ConfigDict(
            "nested_key1" => "nested_value1",
            "diffname_2" => JETLS.ConfigDict(
                "deep_nested_key1" => "deep_nested_value1",
                "diffname_3" => "deep_nested_value2"
            )
        ),
    )

    @testset "collect_unmatched_keys" begin
        # It is correct that `test_key2.diffname_2.diffname_3` is not included,
        # because `collect_unmatched_keys` does not track deeper nested differences in key names.
        @test Set(JETLS.collect_unmatched_keys(TEST_DICT_DIFFERENT_KEY, TEST_DICT)) == Set([
            ["diffname_1"],
            ["test_key2", "diffname_2"],
        ])

        @test isempty(JETLS.collect_unmatched_keys(TEST_DICT, TEST_DICT))

        # single-arg version should use DEFAULT_CONFIG_DICT
        @test JETLS.collect_unmatched_keys(TEST_DICT_DIFFERENT_KEY) ==
              JETLS.collect_unmatched_keys(TEST_DICT_DIFFERENT_KEY, JETLS.DEFAULT_CONFIG_DICT)
    end
end

function store_project_config!(manager::JETLS.ConfigManager, filepath::AbstractString, new_config::JETLS.JETLSConfig)
    JETLS.store!(manager) do old_data
        new_data = JETLS.ConfigManagerData(old_data;
            project_config=new_config,
            project_config_path=filepath
        )
        return new_data, nothing
    end
end

function store_lsp_config!(manager::JETLS.ConfigManager, new_config::JETLS.JETLSConfig)
    JETLS.store!(manager) do old_data
        new_data = JETLS.ConfigManagerData(old_data; lsp_config=new_config)
        return new_data, nothing
    end
end

@testset "ConfigManager" begin
    manager = JETLS.ConfigManager(JETLS.ConfigManagerData())

    test_config = JETLS.JETLSConfig(;
        full_analysis=JETLS.FullAnalysisConfig(2.0),
        testrunner=JETLS.TestRunnerConfig("test_runner"),
        internal=JETLS.InternalConfig(5, nothing)
    )

    store_project_config!(manager, "/foo/bar/.JETLSConfig.toml", test_config)
    JETLS.fix_static_settings!(manager)

    @test JETLS.get_config(manager, :full_analysis, :debounce) === 2.0
    @test JETLS.get_config(manager, :testrunner, :executable) === "test_runner"
    @test JETLS.get_config(manager, :non_existent_key) === nothing

    @test Base.infer_return_type((typeof(manager),)) do manager
           JETLS.get_config(manager, :internal, :dynamic_setting)
    end == Union{Nothing, Int}

    @test Base.infer_return_type((typeof(manager),)) do manager
           JETLS.get_config(manager, :internal, :static_setting)
    end == Union{Nothing, Int}

    # Test priority: LSP config has lower priority than project config
    lsp_config = JETLS.JETLSConfig(;
        full_analysis=JETLS.FullAnalysisConfig(999.0),
        testrunner=JETLS.TestRunnerConfig("lsp_runner")
    )
    store_lsp_config!(manager, lsp_config)
    # High priority project config should still win
    @test JETLS.get_config(manager, :full_analysis, :debounce) === 2.0
    @test JETLS.get_config(manager, :testrunner, :executable) === "test_runner"

    # Test updating config
    changed_static_keys = Set{String}()
    updated_config = JETLS.JETLSConfig(;
        full_analysis=JETLS.FullAnalysisConfig(3.0),
        testrunner=JETLS.TestRunnerConfig("new_runner"),
        internal=JETLS.InternalConfig(10, nothing)
    )
    let data = JETLS.load(manager)
        current_config = data.project_config
        JETLS.on_difference(current_config, updated_config) do _, new_val, path
            if JETLS.is_static_setting(JETLS.JETLSConfig, path...)
                push!(changed_static_keys, join(path, "."))
            end
            return new_val
        end
    end
    store_project_config!(manager, "/foo/bar/.JETLSConfig.toml", updated_config)

    # `on_static_setting` should be called for static keys
    @test changed_static_keys == Set(["internal.static_setting"])
    # non static keys should be changed dynamically
    @test JETLS.get_config(manager, :testrunner, :executable) == "new_runner"
    @test JETLS.get_config(manager, :full_analysis, :debounce) == 3.0
    # static keys should NOT change (they stay at the fixed values)
    @test JETLS.get_config(manager, :internal, :static_setting) == 5
end

@testset "`fix_static_settings!`" begin
    manager = JETLS.ConfigManager(JETLS.ConfigManagerData())
    high_priority_config = JETLS.JETLSConfig(;
        internal=JETLS.InternalConfig(2, nothing)
    )
    low_priority_config = JETLS.JETLSConfig(;
        internal=JETLS.InternalConfig(999, nothing),
        testrunner=JETLS.TestRunnerConfig("custom")
    )

    store_lsp_config!(manager, low_priority_config)
    store_project_config!(manager, "/path/.JETLSConfig.toml", high_priority_config)
    JETLS.fix_static_settings!(manager)

    # high priority should win for the static keys
    data = JETLS.load(manager)
    @test JETLS.getobjpath(data.static_settings, :internal, :static_setting) == 2
end

@testset "LSP configuration priority and merging" begin
    manager = JETLS.ConfigManager(JETLS.ConfigManagerData())

    lsp_config = JETLS.JETLSConfig(;
        full_analysis=JETLS.FullAnalysisConfig(2.0),
        testrunner=nothing
    )
    project_config = JETLS.JETLSConfig(;
        testrunner=JETLS.TestRunnerConfig("project_runner"),
        full_analysis=nothing
    )

    store_lsp_config!(manager, lsp_config)
    store_project_config!(manager, "/project/.JETLSConfig.toml", project_config)

    @test JETLS.get_config(manager, :testrunner, :executable) == "project_runner"
    @test JETLS.get_config(manager, :full_analysis, :debounce) == 2.0
end

@testset "LSP configuration merging without project config" begin
    manager = JETLS.ConfigManager(JETLS.ConfigManagerData())

    lsp_config = JETLS.JETLSConfig(;
        full_analysis=JETLS.FullAnalysisConfig(3.0),
        testrunner=JETLS.TestRunnerConfig("lsp_runner")
    )

    store_lsp_config!(manager, lsp_config)

    @test JETLS.get_config(manager, :testrunner, :executable) == "lsp_runner"
    @test JETLS.get_config(manager, :full_analysis, :debounce) == 3.0
end

end # test_config
