using Documenter, StructTypes

makedocs(;
    modules=[StructTypes],
    format=Documenter.HTML(),
    pages=[
        "Home" => "index.md",
    ],
    repo=Documenter.Remotes.GitHub("JuliaData", "StructTypes.jl"),
    sitename="StructTypes.jl",
    authors="Jacob Quinn",
)

deploydocs(;
    repo="github.com/JuliaData/StructTypes.jl",
    devbranch = "main"
)
