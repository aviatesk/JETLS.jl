using Test, LoweredCodeUtils

# using LoweredCodeUtils
# @testset "Ambiguity" begin
#     @test isempty(detect_ambiguities(LoweredCodeUtils, LoweredCodeUtils.JuliaInterpreter, Base, Core))
# end

if isdefined(Test, :detect_closure_boxes)
    @test isempty(Test.detect_closure_boxes(LoweredCodeUtils))
end

@testset "LoweredCodeUtils.jl" begin
    @testset "signatures.jl" include("signatures.jl")
    @testset "codeedges.jl" include("codeedges.jl")
end
