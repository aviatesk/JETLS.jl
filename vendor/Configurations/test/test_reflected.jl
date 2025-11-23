module Reflected

using Test
using ExproniconLite
using Configurations
using OrderedCollections
using Configurations: @option, Reflect, has_duplicated_reflect_type

@option struct OptionA
    type::Reflect
    name::String
    age::Int
end

@option struct OptionB
    type::Reflect
    name::String
end

@option struct OptionC{T}
    type::Reflect
    typevar::T
end

# NOTE: this is not supported yet
# @option "aaa" struct OptionD{T}
#     type::Reflect
#     typevar::T
# end

@option "bbb" struct OptionE
    type::Reflect
    name::String
end

@option struct Composite
    person::Union{OptionA,OptionB,OptionC,OptionE}
end

@option struct VectorOfUnion
    data::Vector{Union{OptionA,OptionB}}
end

@testset "Reflect Type" begin
    @testset "OptionA" begin
        opt = OptionA(Reflect(), "Sam", 2)
        @test opt == OptionA(; name="Sam", age=2)
        d = to_dict(opt)
        @test from_dict(OptionA, d) == opt
    end

    @testset "OptionC{T}" begin
        opt = OptionC(Reflect(), 2)
        @test opt == OptionC(; typevar=2)
        d = to_dict(opt)

        @test_throws ArgumentError from_dict(OptionC, d)
        @test_throws ArgumentError from_dict(OptionC{Float32}, d)
        @test from_dict(OptionC{Int}, d) == OptionC(Reflect(), 2)
    end

    @testset "Composite" begin
        opt = Composite(OptionA(Reflect(), "Sam", 2))

        d = to_dict(opt)
        @test from_dict(Composite, d) == opt

        opt = Composite(OptionB(Reflect(), "Sam"))
        d = to_dict(opt)
        @test from_dict(Composite, d) == opt

        opt = Composite(OptionC(Reflect(), "Sam"))
        d = to_dict(opt)
        @test from_dict(Composite, d) == opt

        d = Dict(
            "person" => Dict{String,Any}(
                "type" => "Main.Reflected.OptionC{Float32}", "typevar" => 2
            ),
        )
        opt = from_dict(Reflected.Composite, d)
        @test typeof(opt.person) <: Reflected.OptionC{Float32}
    end

    @testset "duplicated Reflect" begin
        ex = @expr struct OptionError
            type_a::Reflect
            type_b::Reflect
            age::Int
        end

        @test_throws ArgumentError Configurations.option_m(Reflected, ex)

        ex = @expr JLKwStruct struct OptionError
            type_a::Reflect
            type_b::Reflect
            age::Int
        end
        @test has_duplicated_reflect_type(Reflected, ex)

        ex = @expr JLKwStruct struct OptionB end
        @test !has_duplicated_reflect_type(Reflected, ex)
    end

    @testset "type_alias as reflection" begin
        opt = Reflected.Composite(Reflected.OptionE(; name="aaa"))
        d = to_dict(opt)
        @test d == OrderedDict{String,Any}(
            "person" => OrderedDict{String,Any}("type" => "bbb", "name" => "aaa")
        )
        @test from_dict(Reflected.Composite, d) == opt
    end

    @testset "vector of union" begin
        d = Dict{String,Any}(
            "data" => [
                Dict{String,Any}(
                    "type" => "Main.Reflected.OptionA", "name" => "A", "age" => 1
                ),
                Dict{String,Any}(
                    "type" => "Main.Reflected.OptionA", "name" => "B", "age" => 2
                ),
                Dict{String,Any}("type" => "Main.Reflected.OptionB", "name" => "C"),
                Dict{String,Any}("type" => "Main.Reflected.OptionB", "name" => "D"),
            ],
        )

        @test from_dict(Reflected.VectorOfUnion, d) == Reflected.VectorOfUnion(
            Union{Reflected.OptionA,Reflected.OptionB}[
                Reflected.OptionA(Reflect(), "A", 1),
                Reflected.OptionA(Reflect(), "B", 2),
                Reflected.OptionB(Reflect(), "C"),
                Reflected.OptionB(Reflect(), "D"),
            ],
        )

        opt = Reflected.VectorOfUnion(;
            data=[
                Reflected.OptionA(; name="A", age=1),
                Reflected.OptionA(; name="B", age=2),
                Reflected.OptionB(; name="C"),
                Reflected.OptionB(; name="D"),
            ],
        )
        @test from_dict(Reflected.VectorOfUnion, to_dict(opt)) == opt
    end
end

end # Reflected
