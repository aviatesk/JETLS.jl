using Documenter, JSON3, StructTypes

makedocs(;
    modules=[JSON3],
    format=Documenter.HTML(edit_link="main"),
    pages=[
        "Home" => "index.md",
    ],
    repo=Remotes.GitHub("quinnj", "JSON3.jl"),
    sitename="JSON3.jl",
    authors="Jacob Quinn",
)

deploydocs(;
    repo="github.com/quinnj/JSON3.jl",
    devbranch = "main",
)
