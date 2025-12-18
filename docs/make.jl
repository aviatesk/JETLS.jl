using Documenter
using JETLS

const devbranch = get(ENV, "DOCUMENTER_DEVBRANCH", "master")
const release_date = get(ENV, "DOCUMENTER_RELEASE_DATE", "")
const release_commit = get(ENV, "DOCUMENTER_RELEASE_COMMIT", "")

# Insert release info admonition into index.md for release builds
const index_md = joinpath(@__DIR__, "src", "index.md")
const index_md_original = read(index_md, String)
if devbranch == "release" && !isempty(release_date)
    short_commit = isempty(release_commit) ? "" : release_commit[1:7]
    release_info = """
        !!! info "Release version"
            This documentation is for the `$release_date` release ([`$short_commit`](https://github.com/aviatesk/JETLS.jl/commit/$release_commit)).
            See the [CHANGELOG](@ref $release_date) for details about this release.

        """
    # Insert after the title line
    modified = replace(index_md_original,
        r"^(# [^\n]+\n)"s => SubstitutionString("\\1\n" * release_info))
    write(index_md, modified)
end

let CHANGELOG_md = joinpath(@__DIR__, "..", "CHANGELOG.md")
    CHANGELOG_md_text = read(CHANGELOG_md, String)
    CHANGELOG_md_text = replace(CHANGELOG_md_text,
        "./DEVELOPMENT.md#profiling" => "https://github.com/aviatesk/JETLS.jl/blob/master/DEVELOPMENT.md#profiling")
    CHANGELOG_md_text = replace(CHANGELOG_md_text,
        r"> \[!(.+)\]" => s"!!! \1")
    CHANGELOG_md_text = replace(CHANGELOG_md_text,
        r"^\> (.+)$"m=>s"    \1")
    CHANGELOG_md_text = replace(CHANGELOG_md_text,
        r"^\>$"m=>s"")
    CHANGELOG_md_text = replace(CHANGELOG_md_text,
        r"(https://github\.com/aviatesk/JETLS\.jl/(?:issues|pull)/(\d+))" => s"[aviatesk/JETLS.jl#\2](\1)")
    write(joinpath(@__DIR__, "src", "CHANGELOG.md"), CHANGELOG_md_text)
end

makedocs(;
    modules = [JETLS],
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
        "Notebook support" => "notebook.md",
        "Configuration" => "configuration.md",
        "Launching" => "launching.md",
        "CHANGELOG" => "CHANGELOG.md"
    ],
    warnonly = [:missing_docs]
)

# Custom deploy configuration for `release` branch deployment
# Documenter.jl normally only deploys to versioned folders (like `v1.0.0/`) when
# triggered by a git tag. Since JETLS uses a `release` branch instead of tags,
# we need a custom DeployConfig that treats `release` branch pushes as releases.
struct ReleaseBranchConfig <: Documenter.DeployConfig end

function Documenter.deploy_folder(
        ::ReleaseBranchConfig;
        repo::String, branch::String, kwargs...
    )
    return Documenter.DeployDecision(; all_ok=true, branch, is_preview=false,
        repo, subfolder="release")
end
Documenter.authentication_method(::ReleaseBranchConfig) = Documenter.SSH
Documenter.authenticated_repo_url(::ReleaseBranchConfig) =
    "git@github.com:aviatesk/JETLS.jl.git"

deploydocs(;
    repo = "github.com/aviatesk/JETLS.jl",
    push_preview = true,
    devbranch,
    deploy_config = devbranch == "release" ? ReleaseBranchConfig() : Documenter.auto_detect_deploy_system(),
    versions = ["release" => "release", "dev" => "dev"],
)
