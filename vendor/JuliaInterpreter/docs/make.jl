using Documenter, JuliaInterpreter, Test, CodeTracking

DocMeta.setdocmeta!(JuliaInterpreter, :DocTestSetup, :(
    begin
        using JuliaInterpreter
        JuliaInterpreter.clear_caches()
        JuliaInterpreter.remove()
    end); recursive=true)

makedocs(
    modules = [JuliaInterpreter],
    clean = false,
    format = Documenter.HTML(prettyurls = get(ENV, "CI", nothing) == "true"),
    sitename = "JuliaInterpreter.jl",
    authors = "Keno Fischer, Tim Holy, Kristoffer Carlsson, and others",
    linkcheck = !("skiplinks" in ARGS),
    pages = [
        "Home" => "index.md",
        "ast.md",
        "internals.md",
        "dev_reference.md",
    ],
)

deploydocs(
    repo = "github.com/JuliaDebug/JuliaInterpreter.jl.git",
    push_preview = true
)
