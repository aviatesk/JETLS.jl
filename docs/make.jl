using Documenter
# using JETLS

makedocs(;
    # modules = [JETLS],
    sitename = "JETLS.jl",
    format = Documenter.HTML(;
        prettyurls = get(ENV, "CI", "false") == "true",
        canonical = "https://aviatesk.github.io/JETLS.jl",
        assets = ["assets/extras.css"],
    ),
    pages = Any[
        "Index" => "index.md",
        "Configuration" => "configuration.md",
        "Formatter integration" => "formatting.md",
        "TestRunner integration" => "testrunner.md",
        "Communication channels" => "communication-channels.md",
    ],
)

deploydocs(;
    repo = "github.com/aviatesk/JETLS.jl",
    push_preview = true,
    devbranch = "master",
)
