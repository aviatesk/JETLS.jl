using Test

# test the basic server setup and lifecycle before running the tests
include("setup.jl")
@testset "basic lifecycle" begin
    @test withserver(Returns(true))
end

@testset "JETLS" begin
    @testset "utils" begin
        @testset "general" include("utils/test_general.jl")
        @testset "ast" include("utils/test_ast.jl")
        @testset "binding" include("utils/test_binding.jl")
        @testset "lsp" include("utils/test_lsp.jl")
        @testset "path" include("utils/test_path.jl")
        @testset "markdown" include("utils/test_markdown.jl")
    end
    @testset "types" include("test_types.jl")
    @testset "URIs2" include("test_URIs2.jl")
    @testset "registration" include("test_registration.jl")
    @testset "resolver" include("test_resolver.jl")
    @testset "completions" include("test_completions.jl")
    @testset "signature help" include("test_signature_help.jl")
    @testset "definition" include("test_definition.jl")
    @testset "hover" include("test_hover.jl")
    @testset "surface analysis" include("test_surface_analysis.jl")
    @testset "LSAnalyzer" include("test_LSAnalyzer.jl")
    @testset "diagnostics" include("test_diagnostics.jl")
    @testset "testrunner" include("test_testrunner.jl")
    @testset "full lifecycle" include("test_full_lifecycle.jl")
end
