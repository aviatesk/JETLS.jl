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
        "Diagnostic" => "diagnostic.md",
        "Formatter integration" => "formatting.md",
        "TestRunner integration" => "testrunner.md",
        "Configuration" => "configuration.md",
        "Launching" => "launching.md",
    ],
)

deploydocs(;
    repo = "github.com/aviatesk/JETLS.jl",
    push_preview = true,
    devbranch = get(ENV, "DOCUMENTER_DEVBRANCH", "master"),
    devurl = get(ENV, "DOCUMENTER_DEVBRANCH", "dev"),
)
