module TestParametric

using Test
using Configurations

@option struct OptionC{T}
    type::Reflect
    x::T
end

@option struct OptionB{T}
    type::Reflect
    x::T
end

@option struct OptionA{T}
    type::Reflect
    y::T
end

@option struct Composite
    field::Union{OptionA, OptionC}
end

@type_alias OptionA{Float32} "option_a_float32"
@type_alias OptionA{Float64} "option_a_float64"

@type_alias OptionC{Float32} "option_c_float32"
@type_alias OptionC{Float64} "option_c_float64"

@testset "parametric type" begin
    @testset "from_dict with alias" begin
        opt = Composite(OptionC(x=2.0))
        d = to_dict(opt)
        @test from_dict(Composite, d) == opt
    end
end

end
