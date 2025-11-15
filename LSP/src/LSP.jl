module LSP

using StructTypes: StructTypes

include("URIs2/URIs2.jl")
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
include("language-features/signature-help.jl")
include("language-features/definition.jl")
include("language-features/document-highlight.jl")
include("language-features/hover.jl")
include("language-features/code-lens.jl")
include("language-features/code-action.jl")
include("language-features/inlay-hint.jl")
include("language-features/formatting.jl")
include("language-features/rename.jl")
include("language-features/folding-range.jl")
include("language-features/selection-range.jl")
include("workspace-features/workspace-folders.jl")
include("workspace-features/files.jl")
include("workspace-features/did-change-watched-files.jl")
include("workspace-features/configuration.jl")
include("workspace-features/execute-command.jl")
include("workspace-features/apply-edit.jl")
include("window-features.jl")
include("lifecycle-messages/initialize.jl")

for name in exports
    Core.eval(@__MODULE__, Expr(:export, name))
end

export
    method_dispatcher

end # module LSP
