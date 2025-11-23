module Issue50
using Test
using Configurations

@option struct OptionA
    name::Maybe{String} = nothing
    int::Int = 1
end

@option struct OptionB
    name::Maybe{OptionA} = nothing
    int::Int = 1
end

@testset "to_dict style" begin
    option = OptionB()
    @test to_dict(option, TOMLStyle) ==
          to_dict(option; include_defaults=true, exclude_nothing=true)
    @test to_dict(option, YAMLStyle) ==
          to_dict(option; include_defaults=true, exclude_nothing=false)
    @test to_dict(option, JSONStyle) ==
          to_dict(option; include_defaults=true, exclude_nothing=false)
end

@testset "#50" begin
    @test from_dict(Issue50.OptionB, Dict{String,Any}("name" => nothing)) == OptionB()
end

end
