using PrecompileTools

@compile_workload begin
    str = """{"a": 1, "b": "hello, world", "c": [1, 2], "d": true, "e": null, "f": 1.92, "g": {"a": {"a" : "b"}}}"""

    JSON3.read(IOBuffer(str))
    json = JSON3.read(str)
    for i in "abcdef"
        json[i]
    end
    json[:g][:a][:a]

    JSON3.read(
        str,
        NamedTuple{(:a, :b, :c, :d, :e, :f), Tuple{Int, String, Vector{Int}, Bool, Nothing, Float32}}
    )

    JSON3.write(IOBuffer(), json)
    JSON3.pretty(IOBuffer(), json)
end
