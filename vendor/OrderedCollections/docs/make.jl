using Documenter
using OrderedCollections

makedocs(
	modules = [OrderedCollections],
	sitename = "OrderedCollections.jl",
    pages = [
        "index.md",
    ]
)

deploydocs(
    repo = "github.com/JuliaCollections/OrderedCollections.jl.git",
    push_preview = true,
)
