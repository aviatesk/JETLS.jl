module LSP

using StructTypes

const exports = Set{Symbol}()
const method_dispatcher = Dict{String,DataType}()

# ------------------------------------------------------------------------------------------
# Type aliases.

"""
A special object representing `null` value.
When used as a field specified as `StructTypes.omitempties`, the key-value pair is not
omitted in the serialized JSON but instead appears as `null`.
This special object is specifically intended for use in `ResponseMessage`.
"""
struct Null end
const null = Null()
StructTypes.StructType(::Type{Null}) = StructTypes.CustomStruct()
StructTypes.lower(::Null) = nothing
push!(exports, :Null, :null)

const boolean = Bool
# const null = Nothing
const string = String

"""
Defines an integer number in the range of -2^31 to 2^31 - 1.
"""
const integer = Int

"""
Defines an unsigned integer number in the range of 0 to 2^31 - 1.
"""
const uinteger = UInt

@doc """
Defines a decimal number.
Since decimal numbers are very rare in the language server specification we denote the exact
range with every decimal using the mathematics interval notation (e.g. `[0, 1]` denotes all
decimals `d` with `0 <= d <= 1`).
"""
const decimal = Float64

@doc """
The LSP any type

# Tags
- since – 3.17.0
"""
const LSPAny = Any

@doc """
LSP object definition.

# Tags
- since – 3.17.0
"""
const LSPObject = Dict{String,Any}

@doc """
LSP arrays.

# Tags
- since – 3.17.0
"""
const LSPArray = Vector{Any}

const URI = String

# ------------------------------------------------------------------------------------------
# LSP components.

include("utils/interface.jl")
include("utils/namespace.jl")
include("messages.jl")
include("documents.jl")
include("progress.jl")
include("diagnostics.jl")
include("capabilities/server.jl")
include("capabilities/client.jl")
include("initialize.jl")
include("shutdown.jl")

for name in exports
    Core.eval(@__MODULE__, Expr(:export, name))
end

export
    method_dispatcher

end # module LSP
