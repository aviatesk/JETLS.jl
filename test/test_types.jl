module test_extra_diagnostics

using Test
using JETLS
using JETLS: JS
using JETLS.LSP
using JETLS.URIs2

struct TestDiagnosticsKey <: JETLS.ExtraDiagnosticsKey
    uri::URI
    id::Int
end
JETLS.to_uri_impl(key::TestDiagnosticsKey) = key.uri

function create_test_diagnostic(message::String, line::Int=0, char::Int=0)
    return LSP.Diagnostic(;
        range = LSP.Range(LSP.Position(line, char), LSP.Position(line, char + 5)),
        message = message)
end

@testset "ExtraDiagnosticsData" begin
    @testset "ExtraDiagnosticsData basic operations" begin
        let data = JETLS.ExtraDiagnosticsData()
            uri = URI("file:///test.jl")
            key = TestDiagnosticsKey(uri, 1)
            diag = create_test_diagnostic("Test message")
            val = JETLS.URI2Diagnostics(uri => [diag])

            # Test empty state
            @test !haskey(data, key)
            @test length(data) == 0

            # Test setindex!
            data[key] = val
            @test haskey(data, key)
            @test data[key] == val
            @test length(data) == 1

            # Test getindex
            retrieved = data[key]
            @test retrieved == val
            @test retrieved[uri] == [diag]
        end
    end

    @testset "ExtraDiagnosticsData get methods" begin
        let data = JETLS.ExtraDiagnosticsData()
            uri = URI("file:///test.jl")
            key1 = TestDiagnosticsKey(uri, 1)
            key2 = TestDiagnosticsKey(uri, 2)
            diag = create_test_diagnostic("Test message")
            val = JETLS.URI2Diagnostics(uri => [diag])
            default_val = JETLS.URI2Diagnostics()

            data[key1] = val

            # Test get with default
            @test get(data, key1, default_val) == val
            @test get(data, key2, default_val) == default_val

            # Test get with function
            @test get(data, key1) do
                error("Should not be called")
            end == val

            @test get(data, key2) do
                default_val
            end == default_val

            # Test get!
            @test get!(data, key1, default_val) == val
            @test !haskey(data, key2)
            @test get!(data, key2, default_val) == default_val
            @test haskey(data, key2)
            @test data[key2] == default_val

            # Test get! with function
            key3 = TestDiagnosticsKey(uri, 3)
            computed_val = get!(data, key3) do
                JETLS.URI2Diagnostics(uri => [create_test_diagnostic("Computed")])
            end
            @test haskey(data, key3)
            @test data[key3] == computed_val
        end
    end

    @testset "ExtraDiagnosticsData delete!" begin
        let data = JETLS.ExtraDiagnosticsData()
            uri = URI("file:///test.jl")
            key = TestDiagnosticsKey(uri, 1)
            diag = create_test_diagnostic("Test message")
            val = JETLS.URI2Diagnostics(uri => [diag])

            data[key] = val
            @test haskey(data, key)
            @test length(data) == 1

            delete!(data, key)
            @test !haskey(data, key)
            @test length(data) == 0

            # Test delete! on non-existent key (should not error)
            delete!(data, key)
            @test !haskey(data, key)
        end
    end

    @testset "ExtraDiagnosticsData keys and values" begin
        let data = JETLS.ExtraDiagnosticsData()
            uri1 = URI("file:///test1.jl")
            uri2 = URI("file:///test2.jl")
            key1 = TestDiagnosticsKey(uri1, 1)
            key2 = TestDiagnosticsKey(uri2, 2)

            diag1 = create_test_diagnostic("Message 1")
            diag2 = create_test_diagnostic("Message 2")
            val1 = JETLS.URI2Diagnostics(uri1 => [diag1])
            val2 = JETLS.URI2Diagnostics(uri2 => [diag2])

            data[key1] = val1
            data[key2] = val2

            # Test keys()
            ks = collect(keys(data))
            @test length(ks) == 2
            @test key1 in ks
            @test key2 in ks

            # Test values()
            vs = collect(values(data))
            @test length(vs) == 2
            @test val1 in vs
            @test val2 in vs
        end
    end

    @testset "ExtraDiagnosticsData iteration" begin
        let data = JETLS.ExtraDiagnosticsData()
            # Test empty iteration
            @test length(data) == 0
            @test eltype(data) == Pair{JETLS.ExtraDiagnosticsKey,JETLS.URI2Diagnostics}
            @test eltype(JETLS.ExtraDiagnosticsData) == Pair{JETLS.ExtraDiagnosticsKey,JETLS.URI2Diagnostics}
            @test collect(data) == []

            # Add test data
            uri1 = URI("file:///test1.jl")
            uri2 = URI("file:///test2.jl")
            uri3 = URI("file:///test3.jl")

            key1 = TestDiagnosticsKey(uri1, 1)
            key2 = TestDiagnosticsKey(uri2, 2)
            key3 = TestDiagnosticsKey(uri3, 3)

            diag1 = create_test_diagnostic("Message 1")
            diag2 = create_test_diagnostic("Message 2")
            diag3 = create_test_diagnostic("Message 3")

            val1 = JETLS.URI2Diagnostics(uri1 => [diag1])
            val2 = JETLS.URI2Diagnostics(uri2 => [diag2])
            val3 = JETLS.URI2Diagnostics(uri3 => [diag3])

            data[key1] = val1
            data[key2] = val2
            data[key3] = val3

            # Test length
            @test length(data) == 3

            # Test collect
            collected = collect(data)
            @test length(collected) == 3
            @test all(p -> p isa Pair{JETLS.ExtraDiagnosticsKey,JETLS.URI2Diagnostics}, collected)

            # Verify all pairs are present
            collected_dict = Dict(collected)
            @test haskey(collected_dict, key1) && collected_dict[key1] == val1
            @test haskey(collected_dict, key2) && collected_dict[key2] == val2
            @test haskey(collected_dict, key3) && collected_dict[key3] == val3

            # Test for loop iteration
            count = 0
            seen_keys = JETLS.ExtraDiagnosticsKey[]
            seen_vals = JETLS.URI2Diagnostics[]
            for (k, v) in data
                count += 1
                push!(seen_keys, k)
                push!(seen_vals, v)
                @test k isa JETLS.ExtraDiagnosticsKey
                @test v isa JETLS.URI2Diagnostics
            end
            @test count == 3
            @test key1 in seen_keys
            @test key2 in seen_keys
            @test key3 in seen_keys
            @test val1 in seen_vals
            @test val2 in seen_vals
            @test val3 in seen_vals

            # Test that iteration works multiple times
            collected2 = collect(data)
            @test length(collected2) == 3
            @test Set(collected) == Set(collected2)
        end
    end


    @testset "ExtraDiagnosticsData with multiple diagnostics per URI" begin
        let data = JETLS.ExtraDiagnosticsData()
            uri = URI("file:///test1.jl")

            key = TestDiagnosticsKey(uri, 1)

            another_uri = URI("file:///test2.jl")

            diag1 = create_test_diagnostic("Error 1", 0, 0)
            diag2 = create_test_diagnostic("Error 2", 1, 0)
            diag3 = create_test_diagnostic("Warning 1", 2, 0)

            val = JETLS.URI2Diagnostics(
                uri => [diag1, diag2],
                another_uri => [diag3]
            )

            data[key] = val
            retrieved = data[key]

            @test length(retrieved[uri]) == 2
            @test length(retrieved[another_uri]) == 1
            @test diag1 in retrieved[uri]
            @test diag2 in retrieved[uri]
            @test diag3 in retrieved[another_uri]
        end
    end

    @testset "ExtraDiagnosticsData type methods" begin
        @test Base.keytype(JETLS.ExtraDiagnosticsData) == JETLS.ExtraDiagnosticsKey
        @test Base.valtype(JETLS.ExtraDiagnosticsData) == JETLS.URI2Diagnostics
    end

    @testset "clear_extra_diagnostics! single key" begin
        let data = JETLS.ExtraDiagnosticsData()
            extra_diagnostics = JETLS.ExtraDiagnostics(data)

            uri = URI("file:///test.jl")
            key = TestDiagnosticsKey(uri, 1)
            diag = create_test_diagnostic("Test message")
            val = JETLS.URI2Diagnostics(uri => [diag])
            JETLS.store!(extra_diagnostics) do data
                new_data = copy(data)
                new_data[key] = val
                new_data, nothing
            end
            @test haskey(JETLS.load(extra_diagnostics), key)

            # Test clearing existing key
            @test JETLS.clear_extra_diagnostics!(extra_diagnostics, key)
            @test !haskey(JETLS.load(extra_diagnostics), key)
            @test length(JETLS.load(extra_diagnostics)) == 0

            # Test clearing non-existent key
            @test !JETLS.clear_extra_diagnostics!(extra_diagnostics, key)
        end
    end
end # @testset "ExtraDiagnosticsData"

@testset "ExtraDiagnostics" begin
    @testset "clear_extra_diagnostics! bulk deletion by URI" begin
        let data = JETLS.ExtraDiagnosticsData()
            extra_diagnostics = JETLS.ExtraDiagnostics(data)

            uri1 = URI("file:///test1.jl")
            uri2 = URI("file:///test2.jl")

            # Create multiple keys for the same URI
            key1 = TestDiagnosticsKey(uri1, 1)
            key2 = TestDiagnosticsKey(uri1, 2)
            key3 = TestDiagnosticsKey(uri1, 3)
            # And one key for a different URI
            key4 = TestDiagnosticsKey(uri2, 4)

            val1 = JETLS.URI2Diagnostics(uri1 => [create_test_diagnostic("Message 1")])
            val2 = JETLS.URI2Diagnostics(uri1 => [create_test_diagnostic("Message 2")])
            val3 = JETLS.URI2Diagnostics(uri1 => [create_test_diagnostic("Message 3")])
            val4 = JETLS.URI2Diagnostics(uri2 => [create_test_diagnostic("Message 4")])

            JETLS.store!(extra_diagnostics) do data
                new_data = copy(data)
                new_data[key1] = val1
                new_data[key2] = val2
                new_data[key3] = val3
                new_data[key4] = val4
                new_data, nothing
            end

            @test length(JETLS.load(extra_diagnostics)) == 4

            # Clear all keys associated with uri1
            @test JETLS.clear_extra_diagnostics!(extra_diagnostics, uri1)

            let loaded_data = JETLS.load(extra_diagnostics)
                # Check that only keys for uri1 were deleted
                @test !haskey(loaded_data, key1)
                @test !haskey(loaded_data, key2)
                @test !haskey(loaded_data, key3)
                @test haskey(loaded_data, key4)
                @test length(loaded_data) == 1

                # Verify the remaining key is for uri2
                remaining_keys = collect(keys(loaded_data))
                @test length(remaining_keys) == 1
                @test JETLS.to_uri(remaining_keys[1]) === uri2
            end

            # Clear non-existent URI - should return false
            @test !JETLS.clear_extra_diagnostics!(extra_diagnostics, URI("file:///nonexistent.jl"))
        end
    end
end # @testset "ExtraDiagnostics"

end # module test_extra_diagnostics
