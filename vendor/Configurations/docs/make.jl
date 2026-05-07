using Documenter
using Configurations
using DocThemeIndigo

indigo = DocThemeIndigo.install(Configurations)

makedocs(;
    modules = [Configurations],
    format = Documenter.HTML(
        prettyurls = !("local" in ARGS),
        canonical="https://Roger-luo.github.io/Configurations.jl",
        assets=String[indigo],
    ),
    pages = [
        "Home" => "index.md",
        "Quick Start" => "quick-start.md",
        "Type Conversion" => "convert.md",
        "Option Type Alias" => "type_alias.md",
        "Meta Programming" => "meta.md",
        "References" => "ref.md",
    ],
    repo = "https://github.com/Roger-luo/Configurations.jl",
    sitename = "Configurations.jl",
)

deploydocs(; repo = "github.com/Roger-luo/Configurations.jl")
