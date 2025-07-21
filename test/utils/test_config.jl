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

@testset "`recursive_merge!`" begin
    # basic overwrite
    dict1 = Dict{String, Any}("a" => 1, "b" => 2)
    dict2 = Dict{String, Any}("b" => 3, "c" => 4)
    JETLS.recursive_merge!(dict1, dict2)
    @test dict1 == Dict{String, Any}("a" => 1, "b" => 3, "c" => 4)
    @test dict2 == Dict{String, Any}("b" => 3, "c" => 4) # dict2 should remain unchanged

    # nested merge
    dict1 = Dict{String, Any}("a" => Dict{String, Any}("x" => 1))
    dict2 = Dict{String, Any}("a" => Dict{String, Any}("y" => 2))
    JETLS.recursive_merge!(dict1, dict2)
    @test dict1 == Dict{String, Any}("a" => Dict{String, Any}("x" => 1, "y" => 2))
    @test dict2 == Dict{String, Any}("a" => Dict{String, Any}("y" => 2))

    # overwrite nested dict with value
    dict1 = Dict{String, Any}("a" => Dict{String, Any}("x" => 1))
    dict2 = Dict{String, Any}("a" => "scalar")
    JETLS.recursive_merge!(dict1, dict2)
    @test dict1 == Dict{String, Any}("a" => "scalar")
    @test dict2 == Dict{String, Any}("a" => "scalar")

    # overwrite value with nested dict
    dict1 = Dict{String, Any}("a" => "scalar")
    dict2 = Dict{String, Any}("a" => Dict{String, Any}("x" => 1))
    JETLS.recursive_merge!(dict1, dict2)
    @test dict1 == Dict{String, Any}("a" => Dict{String, Any}("x" => 1))
    @test dict2 == Dict{String, Any}("a" => Dict{String, Any}("x" => 1))

    # deeply nested merge
    dict1 = Dict{String, Any}("a" => Dict{String, Any}("b" => Dict{String, Any}("c" => 1)))
    dict2 = Dict{String, Any}("a" => Dict{String, Any}("b" => Dict{String, Any}("d" => 2)))
    JETLS.recursive_merge!(dict1, dict2)
    @test dict1 == Dict{String, Any}("a" => Dict{String, Any}("b" => Dict{String, Any}("c" => 1, "d" => 2)))
    @test dict2 == Dict{String, Any}("a" => Dict{String, Any}("b" => Dict{String, Any}("d" => 2)))

    # multiple top-level keys
    dict1 = Dict{String, Any}("a" => 1, "b" => Dict{String, Any}("x" => 10))
    dict2 = Dict{String, Any}("b" => Dict{String, Any}("y" => 20), "c" => 3)
    JETLS.recursive_merge!(dict1, dict2)
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

    JETLS.recursive_merge!(dict1, dict2)

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

@testset "configuration utilities" begin
    default_config_origin = deepcopy(JETLS.DEFAULT_CONFIG)
    is_reload_required_key_origin = deepcopy(JETLS.CONFIG_RELOAD_REQUIRED)
    try
        global JETLS.DEFAULT_CONFIG = TEST_DICT
        global JETLS.CONFIG_RELOAD_REQUIRED = TEST_RELOAD_REQUIRED

        @testset "dictionary operations" begin
            @test JETLS.access_nested_dict(TEST_DICT, "test_key1") == "test_value1"
            @test JETLS.access_nested_dict(TEST_DICT, "test_key2", "nested_key1") == "nested_value1"
            @test JETLS.access_nested_dict(TEST_DICT, "test_key2", "nested_key2", "deep_nested_key1") == "deep_nested_value1"
            @test JETLS.access_nested_dict(TEST_DICT, "test_key2", "nested_key2", "deep_nested_key3") === nothing
            @test JETLS.access_nested_dict(TEST_DICT, "non_existent_key") === nothing

            # It is correct that `test_key2.diffname_2.diffname_3` is not included,
            # because `collect_unmatched_keys` does not track deeper nested differences in key names.
            @test Set(JETLS.collect_unmatched_keys(TEST_DICT_DIFFERENT_KEY, TEST_DICT)) == Set([
                ["diffname_1"],
                ["test_key2", "diffname_2"],
            ])

            @test isempty(JETLS.collect_unmatched_keys(TEST_DICT, TEST_DICT))
            @test isempty(JETLS.collect_unmatched_keys(TEST_DICT, TEST_DICT_DIFFERENT_VALUE))
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
            JETLS.register_config!(manager, "/foo/bar/.JETLSConfig.toml", TEST_DICT, TEST_DICT)
            JETLS.fix_reload_required_settings!(manager)

            @test JETLS.get_config(manager, "test_key1") === "test_value1"
            @test JETLS.get_config(manager, "test_key2", "nested_key1") === "nested_value1"
            @test JETLS.get_config(manager, "test_key2", "nested_key2", "deep_nested_key1") === "deep_nested_value1"
            @test JETLS.get_config(manager, "test_key2", "nested_key2", "deep_nested_key3") === nothing
            @test JETLS.get_config(manager, "non_existent_key") === nothing

            JETLS.register_config!(manager, "__DEFAULT_CONFIG__", TEST_DICT_DIFFERENT_VALUE, TEST_DICT_DIFFERENT_VALUE)
            # __DEFAULT_CONFIG__ has lower priority than the file, so it should not change
            @test JETLS.get_config(manager, "test_key1") === "test_value1"
            @test JETLS.get_config(manager, "test_key2", "nested_key1") === "nested_value1"
            @test JETLS.get_config(manager, "test_key2", "nested_key2", "deep_nested_key1") === "deep_nested_value1"
            @test JETLS.get_config(manager, "test_key2", "nested_key2", "deep_nested_key3") === nothing
            @test JETLS.get_config(manager, "non_existent_key") === nothing

            changed_reload_required = Set{String}()
            JETLS.merge_config!(manager, "/foo/bar/.JETLSConfig.toml", TEST_DICT_DIFFERENT_VALUE) do actual_config, latest_config, key_path, v
                push!(changed_reload_required, join(key_path, "."))
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

end
