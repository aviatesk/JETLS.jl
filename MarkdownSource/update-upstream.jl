#!/usr/bin/env julia

using TOML
using Tar

const CONFIG_PATH = joinpath(@__DIR__, "upstream.toml")
const UPSTREAM_ROOT = joinpath(@__DIR__, "upstream")
const COMMIT_PATTERN = r"^[0-9a-f]{40}$"
const UPSTREAM_SRC = "stdlib/Markdown/src"
const FORK_ROOT = joinpath(@__DIR__, "src", "Markdown")
# The parser files of the Markdown stdlib, forked to `src/Markdown` with the same layout.
# The other upstream sources are `Markdown.jl`, whose role `src/Markdown.jl` takes, and the
# renderers in `render/`.
const FORKED_FILES = [
    "parse/config.jl",
    "parse/parse.jl",
    "parse/util.jl",
    "Common/Common.jl",
    "Common/block.jl",
    "Common/entities.jl",
    "Common/inline.jl",
    "GitHub/GitHub.jl",
    "GitHub/table.jl",
    "IPython/IPython.jl",
    "Julia/Julia.jl",
    "Julia/interp.jl",
]

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
    UPSTREAM_SRC in paths || error("`paths` in $CONFIG_PATH must include $UPSTREAM_SRC")
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

upstream_file(upstream::String, file::String) = joinpath(upstream, UPSTREAM_SRC, file)
fork_file(file::String) = joinpath(FORK_ROOT, file)

# Apply the upstream changes to `file` between `current` and `new` to the fork.
# Returns the number of conflicts left in the fork.
function merge_fork(current::String, new::String, file::String)
    current_file = upstream_file(current, file)
    new_file = upstream_file(new, file)
    isfile(new_file) || error("$UPSTREAM_SRC/$file was removed upstream")
    read(current_file) == read(new_file) && return 0
    fork = relpath(fork_file(file), @__DIR__)
    labels = ["-L", fork, "-L", "upstream (current)", "-L", "upstream (new)"]
    process = run(ignorestatus(`git merge-file $labels $(fork_file(file)) $current_file $new_file`))
    conflicts = process.exitcode
    0 ≤ conflicts ≤ 127 || error("`git merge-file` failed")
    if conflicts == 0
        println(stderr, "Merged the upstream changes to $UPSTREAM_SRC/$file into $fork")
    else
        println(stderr, "Merged the upstream changes to $UPSTREAM_SRC/$file into $fork with ",
            conflicts, " conflict(s); resolve them in $fork")
    end
    return conflicts
end

function source_files(upstream::String)
    root = joinpath(upstream, UPSTREAM_SRC)
    return Set(relpath(joinpath(directory, filename), root)
        for (directory, _, filenames) in walkdir(root) for filename in filenames)
end

# Files added upstream may be needed by the parser, so leave them to a human to triage.
function report_added_files(current::String, new::String)
    for file in sort!(collect(setdiff(source_files(new), source_files(current))))
        println(stderr, "$UPSTREAM_SRC/$file was added upstream; fork it if the parser uses it")
    end
end

function update_upstream(config::UpstreamConfig, commit::String)
    occursin(COMMIT_PATTERN, commit) || error("expected a full 40-character commit SHA: $commit")
    current = fetch_upstream(config, config.commit)
    new = fetch_upstream(config, commit)
    conflicts = sum(file -> merge_fork(current, new, file), FORKED_FILES)
    report_added_files(current, new)
    write(CONFIG_PATH, replace(read(CONFIG_PATH, String), config.commit => commit))
    println(stderr, "Updated upstream.toml to $commit")
    return conflicts == 0
end

function print_help()
    println("""
    Usage: julia MarkdownSource/update-upstream.jl COMMAND

    Commands:
      fetch          Fetch the upstream sources at the commit in upstream.toml into
                     MarkdownSource/upstream/ unless fetched before, and print their directory.
      diff           Show the local changes of src/Markdown to $UPSTREAM_SRC.
      update COMMIT  Merge the upstream changes to the forked files of $UPSTREAM_SRC up to
                     COMMIT into src/Markdown, and record COMMIT in upstream.toml.
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
        upstream = fetch_upstream(config, config.commit)
        for file in FORKED_FILES
            current = relpath(upstream_file(upstream, file), @__DIR__)
            fork = relpath(fork_file(file), @__DIR__)
            diff = `git --no-pager diff --no-index -- $current $fork`
            run(ignorestatus(Cmd(diff; dir=@__DIR__)))
        end
        return 0
    elseif command == "update" && length(args) == 2
        return update_upstream(config, args[2]) ? 0 : 1
    end
    print_help()
    return 1
end
