module LSP

using StructTypes

const exports = Set{Symbol}()
const method_dispatcher = Dict{String,DataType}()

include("utils/interface.jl")
include("utils/namespace.jl")

include("base-protocol.jl")
include("basic-json-structures.jl")
include("capabilities/server.jl")
include("capabilities/client.jl")
include("lifecycle-messages.jl")

include("documents.jl")
include("diagnostics.jl")

for name in exports
    Core.eval(@__MODULE__, Expr(:export, name))
end

export
    method_dispatcher

end # module LSP
