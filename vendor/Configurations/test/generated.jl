module SameReflect

using Test
using Configurations
using Configurations: has_same_reflect_field

@option struct OptionA
    type::Reflect
end

@option struct OptionB
    type::Reflect
end

@option struct OptionC
    type::Reflect
end

@option struct OptionD
    name::Reflect
end

@option struct OptionE end

@option struct Composite
    data::Union{OptionA,OptionB,OptionC}
end

@testset "has_same_reflect_field" begin
    @test has_same_reflect_field([OptionA, OptionB, OptionC]) == true
    @test has_same_reflect_field([OptionA, OptionB, OptionC, OptionD]) == false
    @test has_same_reflect_field([OptionA, OptionB, OptionC, OptionE]) == false
end

end

using Configurations
using Configurations: from_dict_specialize, from_dict_generated

d = Dict{String,Any}("data" => Dict{String,Any}("type" => "Main.SameReflect.OptionA"))
from_dict(SameReflect.Composite, d)

d = Dict{String,Any}("data" => Dict{String,Any}("type" => "Main.SameReflect.OptionB"))
from_dict(SameReflect.Composite, d)

@time from_dict(SameReflect.Composite, d)

@time from_dict_specialize(SameReflect.Composite, d)

Configurations.field_default(SameReflect.Composite, :data)

from_dict_generated(SameReflect.Composite, :d)
from_dict_generated(SameReflect.OptionA, :d)

@generated function goo(::Type{T}) where {T}
    quote
        println("hello")
    end
end

@generated function foo()
    quote
        goo()
    end
end

foo()
