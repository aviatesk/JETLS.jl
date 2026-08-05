using OrderedCollections
using Test
using Random, Serialization

@test isempty(detect_ambiguities(Base, Core, OrderedCollections))

tests = [
         "little_dict",
         "little_set",
         "ordered_dict",
         "ordered_set",
        ]

if length(ARGS) > 0
    tests = ARGS
end

@testset "OrderedCollections" begin

for t in tests
    fp = joinpath(dirname(@__FILE__), "test_$t.jl")
    println("$fp ...")
    include(fp)
end

end # @testset
