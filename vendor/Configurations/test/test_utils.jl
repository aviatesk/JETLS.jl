module TestUtils

using Test
using Configurations: tryparse_jltype, @option, alias_map

@option "option_a" struct OptionA
    x::Int = 1
end

@option "option_b" struct OptionB
    y::Int = 1
end

@testset "tryparse_jltype" begin
    @test tryparse_jltype("Int") === Int
    @test tryparse_jltype("Base.Int") === Int
    @test tryparse_jltype("Base.UInt3") === nothing

    @testset "alias_map" begin
        d = alias_map(Any[OptionA, OptionB])
        @test tryparse_jltype("option_a", d) === OptionA
        @test tryparse_jltype("option_b", d) === OptionB
        @test tryparse_jltype("option_c", d) === nothing
    end
end

end
