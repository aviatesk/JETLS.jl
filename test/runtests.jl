using Test

# test the basic server setup and lifecycle before running the tests
include("setup.jl")
@testset "basic lifecycle" begin
    @test withserver(Returns(true))
end

@testset "JETLS" begin
    @testset "utils" include("test_utils.jl")
    @testset "URIs2" include("test_URIs2.jl")
    @testset "registration" include("test_registration.jl")
    @testset "completions" include("test_completions.jl")
    @testset "signature help" include("test_signature_help.jl")
    @testset "definition" include("test_definition.jl")
    @testset "LSAnalyzer" include("test_LSAnalyzer.jl")
    @testset "diagnostics" include("test_diagnostics.jl")
    @testset "full lifecycle" include("test_full_lifecycle.jl")
end
