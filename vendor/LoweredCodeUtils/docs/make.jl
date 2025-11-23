using Documenter
using LoweredCodeUtils

makedocs(
    sitename = "LoweredCodeUtils",
    format = Documenter.HTML(prettyurls = get(ENV, "CI", nothing) == "true"),
    modules = [LoweredCodeUtils],
    pages = ["Home" => "index.md", "signatures.md", "edges.md", "api.md"]
)

deploydocs(
    repo = "github.com/JuliaDebug/LoweredCodeUtils.jl.git",
    push_preview = true
)
