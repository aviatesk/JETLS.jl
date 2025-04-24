module LSP

using StructTypes

const exports = Set{Symbol}()
const method_dispatcher = Dict{String,DataType}()

include("base-types.jl")
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
