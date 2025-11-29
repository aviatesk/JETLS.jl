module test_config

using Test
using JETLS

@testset "Configuration utilities" begin
    @testset "`get_default_config`" begin
        @test JETLS.get_default_config(:testrunner, :executable) ==
            (@static Sys.iswindows() ? "testrunner.bat" : "testrunner")
        @test JETLS.get_default_config(:formatter) == "Runic"
        @test_throws FieldError JETLS.get_default_config(:nonexistent)
        @test_throws FieldError JETLS.get_default_config(:full_analysis, :nonexistent)
    end

    @testset "`merge_setting`" begin
        base_config = JETLS.JETLSConfig(;
            full_analysis=JETLS.FullAnalysisConfig(; debounce=1.0),
            testrunner=JETLS.TestRunnerConfig("base_runner"),
        )
        overlay_config = JETLS.JETLSConfig(;
            full_analysis=JETLS.FullAnalysisConfig(; debounce=2.0),
        )
        merged = JETLS.merge_setting(base_config, overlay_config)

        @test JETLS.getobjpath(merged, :full_analysis, :debounce) == 2.0
        @test JETLS.getobjpath(merged, :testrunner, :executable) == "base_runner"
    end

    @testset "`on_difference`" begin
        let config1 = JETLS.JETLSConfig(;
                full_analysis=JETLS.FullAnalysisConfig(; debounce=1.0),
                testrunner=JETLS.TestRunnerConfig("runner1"),
            )
            config2 = JETLS.JETLSConfig(;
                full_analysis=JETLS.FullAnalysisConfig(; debounce=2.0),
                testrunner=JETLS.TestRunnerConfig("runner2")
            )
            paths_called = []
            JETLS.on_difference(config1, config2) do _, new_val, path
                push!(paths_called, path)
                new_val
            end
            @test Set(paths_called) == Set([
                (:full_analysis, :debounce),
                (:testrunner, :executable),
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

@testset "UntypedConfigDict utilities" begin
    TEST_DICT = JETLS.UntypedConfigDict(
        "test_key1" => "test_value1",
        "test_key2" => JETLS.UntypedConfigDict(
            "nested_key1" => "nested_value1",
            "nested_key2" => JETLS.UntypedConfigDict(
                "deep_nested_key1" => "deep_nested_value1",
                "deep_nested_key2" => "deep_nested_value2"
            )
        )
    )

    TEST_DICT_DIFFERENT_KEY = JETLS.UntypedConfigDict(
        "diffname_1" => "test_value1",
        "test_key2" => JETLS.UntypedConfigDict(
            "nested_key1" => "nested_value1",
            "diffname_2" => JETLS.UntypedConfigDict(
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

        # single-arg version should use DEFAULT_UNTYPED_CONFIG_DICT
        @test JETLS.collect_unmatched_keys(TEST_DICT_DIFFERENT_KEY) ==
              JETLS.collect_unmatched_keys(TEST_DICT_DIFFERENT_KEY, JETLS.DEFAULT_UNTYPED_CONFIG_DICT)
    end
end

function store_file_config!(manager::JETLS.ConfigManager, filepath::AbstractString, new_config::JETLS.JETLSConfig)
    JETLS.store!(manager) do old_data
        new_data = JETLS.ConfigManagerData(old_data;
            file_config=new_config,
            file_config_path=filepath
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
        full_analysis=JETLS.FullAnalysisConfig(; debounce=2.0),
        testrunner=JETLS.TestRunnerConfig("test_runner"),
    )

    store_file_config!(manager, "/foo/bar/.JETLSConfig.toml", test_config)

    @test JETLS.get_config(manager, :full_analysis, :debounce) === 2.0
    @test JETLS.get_config(manager, :testrunner, :executable) === "test_runner"
    @test_throws FieldError JETLS.get_config(manager, :nonexistent)

    # Type stability check (N.B: Nothing is not allowed)
    @test Base.infer_return_type((typeof(manager),)) do manager
           JETLS.get_config(manager, :full_analysis, :debounce)
    end == Float64
    @test Base.infer_return_type((typeof(manager),)) do manager
           JETLS.get_config(manager, :formatter)
    end == JETLS.FormatterConfig

    # Test priority: file config has higher priority than LSP config
    lsp_config = JETLS.JETLSConfig(;
        full_analysis=JETLS.FullAnalysisConfig(; debounce=999.0),
        testrunner=JETLS.TestRunnerConfig("lsp_runner")
    )
    store_lsp_config!(manager, lsp_config)
    # High priority file config should win
    @test JETLS.get_config(manager, :full_analysis, :debounce) === 2.0
    @test JETLS.get_config(manager, :testrunner, :executable) === "test_runner"

    # Test updating config
    store_lsp_config!(manager, JETLS.EMPTY_CONFIG)
    updated_config = JETLS.JETLSConfig(;
        full_analysis=JETLS.FullAnalysisConfig(; debounce=3.0),
        testrunner=JETLS.TestRunnerConfig("new_runner"),
    )
    store_file_config!(manager, "/foo/bar/.JETLSConfig.toml", updated_config)
    @test JETLS.get_config(manager, :full_analysis, :debounce) == 3.0
    @test JETLS.get_config(manager, :testrunner, :executable) == "new_runner"
end

@testset "LSP configuration priority and merging" begin
    manager = JETLS.ConfigManager(JETLS.ConfigManagerData())

    lsp_config = JETLS.JETLSConfig(;
        full_analysis=JETLS.FullAnalysisConfig(; debounce=2.0),
        testrunner=nothing
    )
    file_config = JETLS.JETLSConfig(;
        testrunner=JETLS.TestRunnerConfig("file_runner"),
        full_analysis=nothing
    )

    store_lsp_config!(manager, lsp_config)
    store_file_config!(manager, "/project/.JETLSConfig.toml", file_config)

    # File config has higher priority, so it wins when both are set
    @test JETLS.get_config(manager, :testrunner, :executable) == "file_runner"
    # When file config doesn't set a value, LSP config is used
    @test JETLS.get_config(manager, :full_analysis, :debounce) == 2.0
end

@testset "LSP configuration merging without file config" begin
    manager = JETLS.ConfigManager(JETLS.ConfigManagerData())
    lsp_config = JETLS.JETLSConfig(;
        full_analysis=JETLS.FullAnalysisConfig(; debounce=3.0),
        testrunner=JETLS.TestRunnerConfig("lsp_runner")
    )
    store_lsp_config!(manager, lsp_config)
    @test JETLS.get_config(manager, :testrunner, :executable) == "lsp_runner"
    @test JETLS.get_config(manager, :full_analysis, :debounce) == 3.0
end

@testset "Formatter configuration" begin
    @testset "preset formatter: Runic" begin
        manager = JETLS.ConfigManager(JETLS.ConfigManagerData())
        config = JETLS.JETLSConfig(; formatter="Runic")
        store_file_config!(manager, "/path/.JETLSConfig.toml", config)
        @test JETLS.get_config(manager, :formatter) == "Runic"
    end

    @testset "preset formatter: JuliaFormatter" begin
        manager = JETLS.ConfigManager(JETLS.ConfigManagerData())
        config = JETLS.JETLSConfig(; formatter="JuliaFormatter")
        store_file_config!(manager, "/path/.JETLSConfig.toml", config)
        @test JETLS.get_config(manager, :formatter) == "JuliaFormatter"
    end

    @testset "custom formatter" begin
        manager = JETLS.ConfigManager(JETLS.ConfigManagerData())
        custom = JETLS.CustomFormatterConfig("my-formatter", "my-range-formatter")
        config = JETLS.JETLSConfig(; formatter=custom)
        store_file_config!(manager, "/path/.JETLSConfig.toml", config)
        formatter = JETLS.get_config(manager, :formatter)
        @test formatter isa JETLS.CustomFormatterConfig
        @test formatter.executable == "my-formatter"
        @test formatter.executable_range == "my-range-formatter"
    end

    @testset "custom formatter without executable_range" begin
        manager = JETLS.ConfigManager(JETLS.ConfigManagerData())
        custom = JETLS.CustomFormatterConfig("my-formatter", nothing)
        config = JETLS.JETLSConfig(; formatter=custom)
        store_file_config!(manager, "/path/.JETLSConfig.toml", config)
        formatter = JETLS.get_config(manager, :formatter)
        @test formatter isa JETLS.CustomFormatterConfig
        @test formatter.executable == "my-formatter"
        @test formatter.executable_range === nothing
    end
end

end # test_config
