module LSP

using StructTypes
using ..URIs2: URI

const exports = Set{Symbol}()
const method_dispatcher = Dict{String,DataType}()

include("utils/interface.jl")
include("utils/namespace.jl")

include("base-protocol.jl")
include("basic-json-structures.jl")
include("lifecycle-messages/register-capability.jl")
include("lifecycle-messages/unregister-capability.jl")
include("lifecycle-messages/shutdown.jl")
include("lifecycle-messages/exit.jl")
include("document-synchronization.jl")
include("language-features/diagnostics.jl")
include("language-features/completions.jl")
include("workspace-features/workspace-folders.jl")
include("workspace-features/files.jl")
include("capabilities.jl")
include("lifecycle-messages/initialize.jl") # requires capabilities.jl

for name in exports
    Core.eval(@__MODULE__, Expr(:export, name))
end

export
    method_dispatcher

end # module LSP
