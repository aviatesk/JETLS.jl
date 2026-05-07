module TestError

using Test
using Configurations

Base.@kwdef struct OptionA
    x::Int = 1
end

Configurations.is_option(::Type{OptionA}) = true
Configurations.is_option(::OptionA) = true

@testset "error" begin
    @test_throws ErrorException from_dict(OptionA, Dict{String, Any}("x" => 1))
    @test_throws ErrorException Configurations.type_alias(Float32)
    @test_throws ErrorException Configurations.type_alias(OptionA)
    @test_throws ErrorException Configurations.get_type_alias_map(Float32)
end

end
