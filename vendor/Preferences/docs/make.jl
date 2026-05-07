using Documenter
using Preferences

# Copy files and modify them for the docs so that we do not maintain two
# versions manually.
open(joinpath(@__DIR__, "src", "index.md"), "w") do io
  # Point to source license file
  println(io, """
  ```@meta
  EditURL = "https://github.com/JuliaPackaging/Preferences.jl/blob/master/README.md"
  ```
  """)
  # Write the modified contents
  for line in eachline(joinpath(dirname(@__DIR__), "README.md"))
    line = replace(line, "[LICENSE.md](LICENSE.md)" => "[License](@ref)")
    println(io, line)
  end
end

open(joinpath(@__DIR__, "src", "license.md"), "w") do io
  # Point to source license file
  println(io, """
  ```@meta
  EditURL = "https://github.com/JuliaPackaging/Preferences.jl/blob/master/LICENSE.md"
  ```
  """)
  # Write the modified contents
  println(io, "# License")
  println(io, "")
  for line in eachline(joinpath(dirname(@__DIR__), "LICENSE.md"))
    println(io, line)
  end
end

# Build docs
makedocs(;
    sitename = "Preferences.jl",
    modules = [Preferences],
    format = Documenter.HTML(
        prettyurls=get(ENV, "CI", "false") == "true",
        canonical = "https://juliapackaging.github.io/Preferences.jl/stable"
    ),
    pages = [
        "Home" => "index.md",
        "Reference" => "reference.md",
        "License" => "license.md"
    ],
    warnonly = [:missing_docs], # we show all exported docstrings and are ok with omitting non-exported ones
)

# Deploy docs
deploydocs(;
    repo = "github.com/JuliaPackaging/Preferences.jl.git",
    devbranch = "master",
    push_preview = false,
)
