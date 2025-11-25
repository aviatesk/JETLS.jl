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

const devbranch = get(ENV, "DOCUMENTER_DEVBRANCH", "master")
const release_date = get(ENV, "DOCUMENTER_RELEASE_DATE", "")

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
    # Only set versions from release branch to preserve the release date label
    versions = devbranch == "release" ?
        ["release ($release_date)" => "release", "dev" => "dev"] : nothing,
)
