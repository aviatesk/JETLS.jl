module TestReflection
using Test
using Configurations

@option struct OptionA{T}
    x::T = 2
end

@option struct OptionB
    x::Int = 2
end

@testset "field_default" begin
    @testset "error case" begin
        @test_throws ErrorException field_default(ComplexF32, :im)
        @test_throws ErrorException field_default(OptionA, :x)
        @test_throws ErrorException field_default(OptionB, :y)
    end
end

@testset "type_alias" begin
    @test_throws ErrorException type_alias(Complex)
end

end
