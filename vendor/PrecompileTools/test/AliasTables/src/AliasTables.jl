module AliasTables

using Random
using PrecompileTools

export AliasTable

struct AliasTable{T}
    x::T
end
Base.rand(x::AliasTable) = rand(x.x)

PrecompileTools.@compile_workload begin
    at = AliasTable([1.0, 2.0])
    rand(at)
end

end
