using Preferences, Test

if VERSION < v"1.6.0-DEV"
    @testset "No-op before Julia 1.6" begin
        @test !isdefined(Preferences, :load_preference)
    end
else
    include("impl.jl")
end
