module Issue82

using Test
using Configurations

@option struct SymOpts
    x::Symbol = :x
    y::Symbol = :y
end

@test from_dict(SymOpts, Dict("x" => :xc)) == SymOpts(:xc, :y)

end # Issue82
