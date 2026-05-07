using JSON3, StructTypes, BenchmarkTools

mutable struct T
    a::Int
    b::Float64
    c::String
    null::Nothing
    maybe::Union{Int, Nothing}
    T() = new()
end

JSON3.StructType(::Type{T}) = JSON3.Mutable()
StructTypes.StructType(::Type{T}) = StructTypes.Mutable()

@btime JSON3.read("{}", T)

@btime JSON3.read(b"""
{
    "a": 1,
    "b": 3.14,
    "c": "hey",
    "null": null,
    "maybe": 10
}""", T)

# master:   4.114 μs (62 allocations: 6.70 KiB)
# 0.1.13:    3.784 μs (16 allocations: 400 bytes)
# new:   950.759 ns (11 allocations: 432 bytes)