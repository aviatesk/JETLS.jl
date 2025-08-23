module test_extra_diagnostics

using Test
using JETLS
using JETLS: JS
using JETLS.LSP

struct TestDiagnosticsKey <: JETLS.ExtraDiagnosticsKey
    file_info::JETLS.FileInfo
    id::Int
end
JETLS.to_file_info_impl(key::TestDiagnosticsKey) = key.file_info

function create_test_diagnostic(message::String, line::Int=0, char::Int=0)
    return LSP.Diagnostic(;
        range = LSP.Range(LSP.Position(line, char), LSP.Position(line, char + 5)),
        message = message)
end

@testset "ExtraDiagnostics" begin
    @testset "ExtraDiagnostics basic operations" begin
        let extra_diags = JETLS.ExtraDiagnostics()
            uri = LSP.URI("file:///test.jl")
            fi = JETLS.FileInfo(1, "", uri)
            key = TestDiagnosticsKey(fi, 1)
            diag = create_test_diagnostic("Test message")
            val = JETLS.URI2Diagnostics(uri => [diag])

            # Test empty state
            @test !haskey(extra_diags, key)
            @test length(extra_diags) == 0

            # Test setindex!
            extra_diags[key] = val
            @test haskey(extra_diags, key)
            @test extra_diags[key] == val
            @test length(extra_diags) == 1

            # Test getindex
            retrieved = extra_diags[key]
            @test retrieved == val
            @test retrieved[uri] == [diag]
        end
    end

    @testset "ExtraDiagnostics get methods" begin
        let extra_diags = JETLS.ExtraDiagnostics()
            uri = LSP.URI("file:///test.jl")
            fi = JETLS.FileInfo(1, "", uri)
            key1 = TestDiagnosticsKey(fi, 1)
            key2 = TestDiagnosticsKey(fi, 2)
            diag = create_test_diagnostic("Test message")
            val = JETLS.URI2Diagnostics(uri => [diag])
            default_val = JETLS.URI2Diagnostics()

            extra_diags[key1] = val

            # Test get with default
            @test get(extra_diags, key1, default_val) == val
            @test get(extra_diags, key2, default_val) == default_val

            # Test get with function
            @test get(extra_diags, key1) do
                error("Should not be called")
            end == val

            @test get(extra_diags, key2) do
                default_val
            end == default_val

            # Test get!
            @test get!(extra_diags, key1, default_val) == val
            @test !haskey(extra_diags, key2)
            @test get!(extra_diags, key2, default_val) == default_val
            @test haskey(extra_diags, key2)
            @test extra_diags[key2] == default_val

            # Test get! with function
            key3 = TestDiagnosticsKey(fi, 3)
            computed_val = get!(extra_diags, key3) do
                JETLS.URI2Diagnostics(uri => [create_test_diagnostic("Computed")])
            end
            @test haskey(extra_diags, key3)
            @test extra_diags[key3] == computed_val
        end
    end

    @testset "ExtraDiagnostics delete!" begin
        let extra_diags = JETLS.ExtraDiagnostics()
            uri = LSP.URI("file:///test.jl")
            fi = JETLS.FileInfo(1, "", uri)
            key = TestDiagnosticsKey(fi, 1)
            diag = create_test_diagnostic("Test message")
            val = JETLS.URI2Diagnostics(uri => [diag])

            extra_diags[key] = val
            @test haskey(extra_diags, key)
            @test length(extra_diags) == 1

            delete!(extra_diags, key)
            @test !haskey(extra_diags, key)
            @test length(extra_diags) == 0

            # Test delete! on non-existent key (should not error)
            delete!(extra_diags, key)
            @test !haskey(extra_diags, key)
        end
    end

    @testset "ExtraDiagnostics keys and values" begin
        let extra_diags = JETLS.ExtraDiagnostics()
            uri1 = LSP.URI("file:///test1.jl")
            uri2 = LSP.URI("file:///test2.jl")
            fi1 = JETLS.FileInfo(1, "", uri1)
            fi2 = JETLS.FileInfo(2, "", uri2)
            key1 = TestDiagnosticsKey(fi1, 1)
            key2 = TestDiagnosticsKey(fi2, 2)

            diag1 = create_test_diagnostic("Message 1")
            diag2 = create_test_diagnostic("Message 2")
            val1 = JETLS.URI2Diagnostics(uri1 => [diag1])
            val2 = JETLS.URI2Diagnostics(uri2 => [diag2])

            extra_diags[key1] = val1
            extra_diags[key2] = val2

            # Test keys()
            ks = collect(keys(extra_diags))
            @test length(ks) == 2
            @test key1 in ks
            @test key2 in ks

            # Test values()
            vs = collect(values(extra_diags))
            @test length(vs) == 2
            @test val1 in vs
            @test val2 in vs
        end
    end

    @testset "ExtraDiagnostics iteration" begin
        let extra_diags = JETLS.ExtraDiagnostics()
            # Test empty iteration
            @test length(extra_diags) == 0
            @test eltype(extra_diags) == Pair{JETLS.ExtraDiagnosticsKey,JETLS.URI2Diagnostics}
            @test eltype(JETLS.ExtraDiagnostics) == Pair{JETLS.ExtraDiagnosticsKey,JETLS.URI2Diagnostics}
            @test collect(extra_diags) == []

            # Add test data
            uri1 = LSP.URI("file:///test1.jl")
            uri2 = LSP.URI("file:///test2.jl")
            uri3 = LSP.URI("file:///test3.jl")

            fi1 = JETLS.FileInfo(1, "", uri1)
            fi2 = JETLS.FileInfo(2, "", uri2)
            fi3 = JETLS.FileInfo(3, "", uri3)

            key1 = TestDiagnosticsKey(fi1, 1)
            key2 = TestDiagnosticsKey(fi2, 2)
            key3 = TestDiagnosticsKey(fi3, 3)

            diag1 = create_test_diagnostic("Message 1")
            diag2 = create_test_diagnostic("Message 2")
            diag3 = create_test_diagnostic("Message 3")

            val1 = JETLS.URI2Diagnostics(uri1 => [diag1])
            val2 = JETLS.URI2Diagnostics(uri2 => [diag2])
            val3 = JETLS.URI2Diagnostics(uri3 => [diag3])

            extra_diags[key1] = val1
            extra_diags[key2] = val2
            extra_diags[key3] = val3

            # Test length
            @test length(extra_diags) == 3

            # Test collect
            collected = collect(extra_diags)
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
            for (k, v) in extra_diags
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
            collected2 = collect(extra_diags)
            @test length(collected2) == 3
            @test Set(collected) == Set(collected2)
        end
    end

    @testset "ExtraDiagnostics to_file_info" begin
        let fi = JETLS.FileInfo(42, "", @__FILE__)
            key = TestDiagnosticsKey(fi, 1)

            @test JETLS.to_file_info(key) === fi
            @test JETLS.to_file_info(key).version == 42
        end
    end

    @testset "ExtraDiagnostics with multiple diagnostics per URI" begin
        let extra_diags = JETLS.ExtraDiagnostics()
            uri = LSP.URI("file:///test1.jl")

            fi = JETLS.FileInfo(1, "", uri)
            key = TestDiagnosticsKey(fi, 1)

            another_uri = LSP.URI("file:///test2.jl")

            diag1 = create_test_diagnostic("Error 1", 0, 0)
            diag2 = create_test_diagnostic("Error 2", 1, 0)
            diag3 = create_test_diagnostic("Warning 1", 2, 0)

            val = JETLS.URI2Diagnostics(
                uri => [diag1, diag2],
                another_uri => [diag3]
            )

            extra_diags[key] = val
            retrieved = extra_diags[key]

            @test length(retrieved[uri]) == 2
            @test length(retrieved[another_uri]) == 1
            @test diag1 in retrieved[uri]
            @test diag2 in retrieved[uri]
            @test diag3 in retrieved[another_uri]
        end
    end

    @testset "ExtraDiagnostics type methods" begin
        @test Base.keytype(JETLS.ExtraDiagnostics) == JETLS.ExtraDiagnosticsKey
        @test Base.valtype(JETLS.ExtraDiagnostics) == JETLS.URI2Diagnostics
    end

    @testset "clear_extra_diagnostics! single key" begin
        let extra_diags = JETLS.ExtraDiagnostics()
            uri = LSP.URI("file:///test.jl")
            fi = JETLS.FileInfo(1, "", uri)
            key = TestDiagnosticsKey(fi, 1)
            diag = create_test_diagnostic("Test message")
            val = JETLS.URI2Diagnostics(uri => [diag])

            extra_diags[key] = val
            @test haskey(extra_diags, key)

            # Test clearing existing key
            @test JETLS.clear_extra_diagnostics!(extra_diags, key)
            @test !haskey(extra_diags, key)
            @test length(extra_diags) == 0

            # Test clearing non-existent key
            @test !JETLS.clear_extra_diagnostics!(extra_diags, key)
        end
    end

    @testset "clear_extra_diagnostics! bulk deletion by FileInfo" begin
        let extra_diags = JETLS.ExtraDiagnostics()

            uri1 = JETLS.LSP.URI("file:///test1.jl")
            uri2 = JETLS.LSP.URI("file:///test2.jl")

            fi1 = JETLS.FileInfo(1, "", uri1)
            fi2 = JETLS.FileInfo(2, "", uri2)

            # Create multiple keys for the same FileInfo
            key1 = TestDiagnosticsKey(fi1, 1)
            key2 = TestDiagnosticsKey(fi1, 2)
            key3 = TestDiagnosticsKey(fi1, 3)
            # And one key for a different FileInfo
            key4 = TestDiagnosticsKey(fi2, 4)

            val1 = JETLS.URI2Diagnostics(uri1 => [create_test_diagnostic("Message 1")])
            val2 = JETLS.URI2Diagnostics(uri1 => [create_test_diagnostic("Message 2")])
            val3 = JETLS.URI2Diagnostics(uri1 => [create_test_diagnostic("Message 3")])
            val4 = JETLS.URI2Diagnostics(uri2 => [create_test_diagnostic("Message 4")])

            extra_diags[key1] = val1
            extra_diags[key2] = val2
            extra_diags[key3] = val3
            extra_diags[key4] = val4

            @test length(extra_diags) == 4

            # Clear all keys associated with fi1
            @test JETLS.clear_extra_diagnostics!(extra_diags, fi1)

            # Check that only keys for fi1 were deleted
            @test !haskey(extra_diags, key1)
            @test !haskey(extra_diags, key2)
            @test !haskey(extra_diags, key3)
            @test haskey(extra_diags, key4)
            @test length(extra_diags) == 1

            # Verify the remaining key is for fi2
            remaining_keys = collect(keys(extra_diags))
            @test length(remaining_keys) == 1
            @test JETLS.to_file_info(remaining_keys[1]) === fi2
        end
    end
end # @testset "ExtraDiagnostics"

end # module test_extra_diagnostics
