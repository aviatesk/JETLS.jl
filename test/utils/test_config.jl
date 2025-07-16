module test_config

using Test
using JETLS

const TEST_DICT = Dict(
    "test_key1" => "test_value1",
    "test_key2" =>  Dict(
        "nested_key1" => "nested_value1",
        "nested_key2" => Dict(
            "deep_nested_key1" => "deep_nested_value1",
            "deep_nested_key2" => "deep_nested_value2"
        )
    )
)

const TEST_DICT_DIFFERENT_VALUE = Dict(
    "test_key1" => "newvalue_1",  # different value (reload required)
    "test_key2" =>  Dict(
        "nested_key1" => "nested_value1",
        "nested_key2" => Dict(
            "deep_nested_key1" => "newvalue_2", # different value (reload required)
            "deep_nested_key2" => "newvalue_3"  # different value (reload not required)
        )
    )
)

const TEST_DICT_DIFFERENT_KEY = Dict(
    "diffname_1" => "test_value1",  # different key name
    "test_key2" =>  Dict(
        "nested_key1" => "nested_value1",
        "diffname_2" => Dict(       # different key name
            "deep_nested_key1" => "deep_nested_value1",
            "diffname_3" => "deep_nested_value2" # different key under a different key
        )
    ),
)

const TEST_RELOAD_REQUIRED = Dict(
    "test_key1" => true,
    "test_key2" => Dict(
        "nested_key1" => false,
        "nested_key2" => Dict(
            "deep_nested_key1" => true,
            "deep_nested_key2" => false
        )
    )
)

JETLS.is_reload_required_key(key_path::Vector{String}) =
    JETLS.access_nested_dict(TEST_RELOAD_REQUIRED, key_path)

function get_latest_config(manager::JETLS.ConfigManager, key_path::Vector{String})
    return JETLS.access_nested_dict(manager.latest_config, key_path)
end


@testset "configuration utilities" begin
    @testset "dictionary operations" begin
        @test JETLS.access_nested_dict(TEST_DICT, ["test_key1"]) == "test_value1"
        @test JETLS.access_nested_dict(TEST_DICT, ["test_key2", "nested_key1"]) == "nested_value1"
        @test JETLS.access_nested_dict(TEST_DICT, ["test_key2", "nested_key2", "deep_nested_key1"]) == "deep_nested_value1"
        @test JETLS.access_nested_dict(TEST_DICT, ["test_key2", "nested_key2", "deep_nested_key3"]) === nothing
        @test JETLS.access_nested_dict(TEST_DICT, ["non_existent_key"]) === nothing


        # It is correct that `test_key2.diffname_2.diffname_3` is not included,
        # because `collect_unmatched_keys` does not track deeper nested differences in key names.
        @test Set(JETLS.collect_unmatched_keys(TEST_DICT_DIFFERENT_KEY, TEST_DICT)) == Set([
            ["diffname_1"],
            ["test_key2", "diffname_2"],
        ])

        @test isempty(JETLS.collect_unmatched_keys(TEST_DICT, TEST_DICT))
        @test isempty(JETLS.collect_unmatched_keys(TEST_DICT, TEST_DICT_DIFFERENT_VALUE))
    end

    @testset "config manager" begin
        manager = JETLS.ConfigManager(deepcopy(TEST_DICT), deepcopy(TEST_DICT), Set(["dummy_path"]))

        @test JETLS.get_config(manager, ["test_key1"]) === "test_value1"
        @test JETLS.get_config(manager, ["test_key2", "nested_key1"]) === "nested_value1"
        @test JETLS.get_config(manager, ["test_key2", "nested_key2", "deep_nested_key1"]) === "deep_nested_value1"
        @test JETLS.get_config(manager, ["test_key2", "nested_key2", "deep_nested_key3"]) === nothing
        @test JETLS.get_config(manager, ["non_existent_key"]) === nothing

        changed_reload_required = Set{String}()
        JETLS.merge_config!(manager, TEST_DICT_DIFFERENT_VALUE, (key_path) ->
            push!(changed_reload_required, join(key_path, ".")))

        # all values should be changed
        @test get_latest_config(manager, ["test_key1"]) === "newvalue_1"
        @test get_latest_config(manager, ["test_key2", "nested_key1"]) === "nested_value1"
        @test get_latest_config(manager, ["test_key2", "nested_key2", "deep_nested_key1"]) === "newvalue_2"
        @test get_latest_config(manager, ["test_key2", "nested_key2", "deep_nested_key2"]) === "newvalue_3"
        @test get_latest_config(manager, ["test_key2", "nested_key2", "deep_nested_key3"]) === nothing

        # keys that require reload should not be changed
        @test JETLS.get_config(manager, ["test_key1"]) === "test_value1" # unchanged (reload required key)
        @test JETLS.get_config(manager, ["test_key2", "nested_key1"]) === "nested_value1"
        @test JETLS.get_config(manager, ["test_key2", "nested_key2", "deep_nested_key1"]) === "deep_nested_value1" # unchanged (reload required key)
        @test JETLS.get_config(manager, ["test_key2", "nested_key2", "deep_nested_key2"]) === "newvalue_3" # changed (reload not required)
        @test JETLS.get_config(manager, ["test_key2", "nested_key2", "deep_nested_key3"]) === nothing

        # `on_reload_required` should be called for changed keys
        @test changed_reload_required == Set(["test_key1", "test_key2.nested_key2.deep_nested_key1"])

        next_config = copy(TEST_DICT_DIFFERENT_VALUE)
        next_config["test_key1"] = "latest_value"

        changed_reload_required = Set{String}()
        JETLS.merge_config!(manager, next_config, (key_path) ->
            push!(changed_reload_required, join(key_path, ".")))

        # only `test_key1` is changed, so
        # - `latest_config` should be updated with it
        # - `actual_config` should not be changed, because it is not reload required key
        # - `on_reload_required` should be called only for it
        @test get_latest_config(manager, ["test_key1"]) === "latest_value"
        @test JETLS.get_config(manager, ["test_key1"]) === "test_value1" # unchanged (reload required key)
        @test changed_reload_required == Set(["test_key1"])
    end
end


end
