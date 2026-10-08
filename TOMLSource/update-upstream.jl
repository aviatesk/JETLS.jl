#!/usr/bin/env julia

using TOML
using Tar

const CONFIG_PATH = joinpath(@__DIR__, "upstream.toml")
const UPSTREAM_ROOT = joinpath(@__DIR__, "upstream")
const COMMIT_PATTERN = r"^[0-9a-f]{40}$"
const FORKED_PATH = "base/toml/parser.jl"
const FORK_PATH = joinpath(@__DIR__, "src", "parser.jl")

struct UpstreamConfig
    repository::String
    commit::String
    paths::Vector{String}
end

function load_config()
    data = TOML.parsefile(CONFIG_PATH)
    repository = get(data, "repository", nothing)
    (repository isa String && !isempty(repository)) ||
        error("$CONFIG_PATH must define `repository` as a non-empty string")
    commit = get(data, "commit", nothing)
    (commit isa String && occursin(COMMIT_PATTERN, commit)) ||
        error("$CONFIG_PATH must define `commit` as a full 40-character commit SHA")
    paths = get(data, "paths", nothing)
    (paths isa Vector && !isempty(paths) && all(p -> p isa String, paths)) ||
        error("$CONFIG_PATH must define `paths` as a non-empty array of strings")
    FORKED_PATH in paths || error("`paths` in $CONFIG_PATH must include $FORKED_PATH")
    return UpstreamConfig(repository, commit, String[paths...])
end

# Return the directory holding `config.paths` at `commit`, fetching them unless done before.
function fetch_upstream(config::UpstreamConfig, commit::String)
    paths = IOBuffer(join(sort(config.paths), '\n'))
    paths_hash = readchomp(pipeline(`git hash-object --stdin`; stdin=paths))[1:12]
    destination = joinpath(UPSTREAM_ROOT, "$commit-$paths_hash")
    isdir(destination) && return destination
    println(stderr, "Fetching $(join(config.paths, ", ")) at $commit")
    mkpath(UPSTREAM_ROOT)
    mktempdir(UPSTREAM_ROOT) do temporary_root
        repository_path = joinpath(temporary_root, "repository.git")
        run(`git init --bare --quiet $repository_path`)
        run(`git -C $repository_path remote add origin $(config.repository)`)
        # `git archive` fetches the blobs it needs, so only the listed files are downloaded.
        run(`git -C $repository_path fetch --quiet --depth=1 --filter=blob:none origin $commit`)
        commit_expression = "$commit^{commit}"
        resolved = readchomp(`git -C $repository_path rev-parse $commit_expression`)
        resolved == commit || error("$commit resolved to $resolved")
        archive_path = joinpath(temporary_root, "upstream.tar")
        open(archive_path, "w") do io
            run(pipeline(`git -C $repository_path archive $commit -- $(config.paths)`; stdout=io))
        end
        extracted = joinpath(temporary_root, "upstream")
        Tar.extract(archive_path, extracted)
        # Another process may have fetched the same commit in the meantime.
        isdir(destination) || mv(extracted, destination)
    end
    return destination
end

# Apply the upstream changes to the forked file between `current` and `new` to the fork.
# Returns the number of conflicts left in the fork.
function merge_fork(current::String, new::String)
    current_file = joinpath(current, FORKED_PATH)
    new_file = joinpath(new, FORKED_PATH)
    if read(current_file) == read(new_file)
        println(stderr, "$FORKED_PATH is unchanged upstream")
        return 0
    end
    labels = ["-L", "src/parser.jl", "-L", "upstream (current)", "-L", "upstream (new)"]
    process = run(ignorestatus(`git merge-file $labels $FORK_PATH $current_file $new_file`))
    conflicts = process.exitcode
    0 ≤ conflicts ≤ 127 || error("`git merge-file` failed")
    if conflicts == 0
        println(stderr, "Merged the upstream changes to $FORKED_PATH into src/parser.jl")
    else
        println(stderr, "Merged the upstream changes to $FORKED_PATH into src/parser.jl with ",
            conflicts, " conflict(s); resolve them in src/parser.jl")
    end
    return conflicts
end

function update_upstream(config::UpstreamConfig, commit::String)
    occursin(COMMIT_PATTERN, commit) || error("expected a full 40-character commit SHA: $commit")
    current = fetch_upstream(config, config.commit)
    new = fetch_upstream(config, commit)
    conflicts = merge_fork(current, new)
    write(CONFIG_PATH, replace(read(CONFIG_PATH, String), config.commit => commit))
    println(stderr, "Updated upstream.toml to $commit")
    return conflicts == 0
end

function print_help()
    println("""
    Usage: julia TOMLSource/update-upstream.jl COMMAND

    Commands:
      fetch          Fetch the upstream sources at the commit in upstream.toml into
                     TOMLSource/upstream/ unless fetched before, and print their directory.
      diff           Show the local changes of src/parser.jl to $FORKED_PATH.
      update COMMIT  Merge the upstream changes to $FORKED_PATH up to COMMIT into
                     src/parser.jl, and record COMMIT in upstream.toml.
      -h, --help     Show this help.
    """)
    return nothing
end

function (@main)(args::Vector{String})
    if isempty(args) || args[1] in ("-h", "--help")
        print_help()
        return isempty(args) ? 1 : 0
    end
    config = load_config()
    command = args[1]
    if command == "fetch" && length(args) == 1
        println(fetch_upstream(config, config.commit))
        return 0
    elseif command == "diff" && length(args) == 1
        current = relpath(joinpath(fetch_upstream(config, config.commit), FORKED_PATH), @__DIR__)
        fork = relpath(FORK_PATH, @__DIR__)
        diff = `git --no-pager diff --no-index -- $current $fork`
        run(ignorestatus(Cmd(diff; dir=@__DIR__)))
        return 0
    elseif command == "update" && length(args) == 2
        return update_upstream(config, args[2]) ? 0 : 1
    end
    print_help()
    return 1
end
