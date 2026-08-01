#!/usr/bin/env julia

using TOML
using Tar

const DEFAULT_CONFIG_PATH = joinpath(@__DIR__, "snapshots.toml")
const COMMIT_PATTERN = r"^[0-9a-f]{40}$"
const VERSION_PATTERN = r"^\d+\.\d+(?:\.\d+)?$"

struct Upstream
    repository::String
    subdir::String
end

struct VersionRange
    lower::VersionNumber
    upper::VersionNumber
end

struct Snapshot
    label::String
    commit::String
    source_branch::String
    destination::String
    runtime_range::VersionRange
end

struct SnapshotConfig
    upstream::Upstream
    snapshots::Vector{Snapshot}
end

struct Options
    check::Bool
    config_path::String
end

function required_table(
        data::Dict{String,Any}, key::String, context::String
    )
    value = get(data, key, nothing)
    value isa Dict{String,Any} || error("$context must define a `$key` table")
    return value
end

function required_string(
        data::Dict{String,Any}, key::String, context::String
    )
    value = get(data, key, nothing)
    value isa String || error("$context must define `$key` as a string")
    isempty(value) && error("$context must define a non-empty `$key`")
    return value
end

function validate_relative_path(path::String, context::String)
    isabspath(path) && error("$context must be a relative path: $path")
    normalized = normpath(path)
    normalized == "." && error("$context must not refer to the current directory")
    any(==(".."), splitpath(normalized)) &&
        error("$context must not escape the Compiler directory: $path")
    return normalized
end

function parse_version(label::String)
    occursin(VERSION_PATTERN, label) ||
        error("snapshot version must be a minor or patch release: `$label`")
    try
        return VersionNumber(label)
    catch err
        err isa ArgumentError || rethrow()
        error("invalid snapshot version `$label`")
    end
end

function parse_version_bound(value::String, context::String)
    try
        return VersionNumber(value)
    catch err
        err isa ArgumentError || rethrow()
        error("$context must be a valid Julia version: `$value`")
    end
end

function load_snapshot_config(path::AbstractString)
    data = TOML.parsefile(path)
    upstream_data = required_table(data, "upstream", "snapshot config")
    repository = required_string(upstream_data, "repository", "upstream")
    subdir = validate_relative_path(
        required_string(upstream_data, "subdir", "upstream"), "upstream.subdir")

    snapshots_data = required_table(data, "snapshots", "snapshot config")
    isempty(snapshots_data) &&
        error("snapshot config must define at least one snapshot")

    snapshots = Snapshot[]
    destinations = Set{String}()
    versions = Set{VersionNumber}()
    for (label, value) in snapshots_data
        value isa Dict{String,Any} || error("snapshot `$label` must be a table")
        context = "snapshot `$label`"
        version = parse_version(label)
        version in versions && error("duplicate normalized snapshot version `$label`")
        push!(versions, version)

        commit = required_string(value, "commit", context)
        occursin(COMMIT_PATTERN, commit) ||
            error("$context must use a full lowercase 40-character commit SHA")
        source_branch = required_string(value, "source-branch", context)
        runtime_data = required_table(value, "runtime", context)
        lower = parse_version_bound(
            required_string(runtime_data, "lower", "$context runtime range"),
            "$context runtime.lower")
        upper = parse_version_bound(
            required_string(runtime_data, "upper", "$context runtime range"),
            "$context runtime.upper")
        lower < upper || error(
            "$context must define a non-empty Julia version range")

        destination = validate_relative_path(
            required_string(value, "destination", context), "$context destination")
        destination in destinations && error("duplicate snapshot destination `$destination`")
        push!(destinations, destination)

        push!(snapshots, Snapshot(
            label, commit, source_branch, destination, VersionRange(lower, upper)))
    end
    sort!(snapshots; by=snapshot -> snapshot.runtime_range.lower)
    for index in 2:length(snapshots)
        previous = snapshots[index-1]
        current = snapshots[index]
        previous.runtime_range.upper > current.runtime_range.lower || continue
        error("Julia version ranges for snapshots `$(previous.label)` and " *
            "`$(current.label)` overlap")
    end
    return SnapshotConfig(Upstream(repository, subdir), snapshots)
end

function fetch_commit(repository_path::String, snapshot::Snapshot)
    println("Fetching Compiler snapshot $(snapshot.label) at $(snapshot.commit)")
    run(`git -C $repository_path fetch --quiet --depth=1 origin $(snapshot.commit)`)
    commit_expression = "$(snapshot.commit)^{commit}"
    resolved = readchomp(`git -C $repository_path rev-parse $commit_expression`)
    resolved == snapshot.commit || error(
        "snapshot $(snapshot.label) resolved to $resolved instead of $(snapshot.commit)")
    return nothing
end

function extract_snapshot(
        repository_path::String,
        upstream::Upstream,
        snapshot::Snapshot,
        output_root::String
    )
    snapshot_root = joinpath(output_root, snapshot.label)
    extract_root = joinpath(snapshot_root, "archive")
    archive_path = joinpath(snapshot_root, "snapshot.tar")
    mkpath(extract_root)

    open(archive_path, "w") do io
        command = `git -C $repository_path archive $(snapshot.commit) -- $(upstream.subdir)`
        run(pipeline(command; stdout=io))
    end
    Tar.extract(archive_path, extract_root)

    source_path = joinpath(extract_root, upstream.subdir)
    isdir(source_path) || error(
        "snapshot $(snapshot.label) does not contain $(upstream.subdir)")
    isfile(joinpath(source_path, "src", "Compiler.jl")) || error(
        "snapshot $(snapshot.label) does not contain src/Compiler.jl")
    return source_path
end

function range_display(range::VersionRange)
    return "[$(range.lower), $(range.upper))"
end

function generate_entrypoint(config::SnapshotConfig)
    io = IOBuffer()
    for (index, snapshot) in enumerate(config.snapshots)
        keyword = index == 1 ? "@static if" : "elseif"
        lower = snapshot.runtime_range.lower
        upper = snapshot.runtime_range.upper
        include_path = replace(
            joinpath("..", snapshot.destination, "src", "Compiler.jl"), '\\' => '/')
        println(io, "$keyword v\"$lower\" ≤ VERSION < v\"$upper\"")
        println(io, "    Base.include(Base.__toplevel__, $(repr(include_path)))")
    end
    ranges = range_display.(getfield.(config.snapshots, :runtime_range))
    println(io, "else")
    println(io, "    error(")
    println(io, "        \"Unsupported Julia version \$(VERSION); supported ranges: \" *")
    for (index, range) in enumerate(ranges)
        text = index < length(ranges) ? "$range, " : range
        suffix = index < length(ranges) ? " *" : ","
        println(io, "        $(repr(text))$suffix")
    end
    println(io, "    )")
    println(io, "end")
    return String(take!(io))
end

function collect_files(root::String)
    isdir(root) || return String[]
    files = String[]
    for (directory, subdirectories, filenames) in walkdir(root)
        sort!(subdirectories)
        sort!(filenames)
        for filename in filenames
            push!(files, relpath(joinpath(directory, filename), root))
        end
    end
    sort!(files)
    return files
end

function compare_directories(expected::String, actual::String)
    expected_files = collect_files(expected)
    actual_files = collect_files(actual)
    differences = String[]

    for path in setdiff(expected_files, actual_files)
        push!(differences, "missing: $path")
    end
    for path in setdiff(actual_files, expected_files)
        push!(differences, "unexpected: $path")
    end
    for path in intersect(expected_files, actual_files)
        read(joinpath(expected, path)) == read(joinpath(actual, path)) ||
            push!(differences, "modified: $path")
    end
    return differences
end

function replace_directory(source::String, destination::String)
    parent = dirname(destination)
    mkpath(parent)
    staging_root = mktempdir(parent)
    staged_destination = joinpath(staging_root, basename(destination))
    try
        cp(source, staged_destination)
        (ispath(destination) || islink(destination)) &&
            rm(destination; force=true, recursive=true)
        mv(staged_destination, destination)
    finally
        rm(staging_root; force=true, recursive=true)
    end
    return nothing
end

function materialize_snapshots(config::SnapshotConfig, compiler_root::String; check::Bool)
    mktempdir() do temporary_root
        repository_path = joinpath(temporary_root, "repository.git")
        generated_root = joinpath(temporary_root, "generated")
        run(`git init --bare --quiet $repository_path`)
        run(`git -C $repository_path remote add origin $(config.upstream.repository)`)

        generated = Dict{String,String}()
        for snapshot in config.snapshots
            fetch_commit(repository_path, snapshot)
            generated[snapshot.label] = extract_snapshot(
                repository_path, config.upstream, snapshot, generated_root)
        end

        success = true
        for snapshot in config.snapshots
            destination = normpath(joinpath(compiler_root, snapshot.destination))
            if check
                differences = compare_directories(generated[snapshot.label], destination)
                if isempty(differences)
                    println("Compiler snapshot $(snapshot.label) is up to date")
                else
                    success = false
                    println("Compiler snapshot $(snapshot.label) is out of date:")
                    for difference in differences
                        println("  $difference")
                    end
                end
            else
                replace_directory(generated[snapshot.label], destination)
                println("Updated Compiler snapshot $(snapshot.label) in $(snapshot.destination)")
            end
        end

        entrypoint_path = joinpath(compiler_root, "src", "Compiler.jl")
        entrypoint = generate_entrypoint(config)
        if check
            if isfile(entrypoint_path) && read(entrypoint_path, String) == entrypoint
                println("Compiler entrypoint is up to date")
            else
                success = false
                println("Compiler entrypoint is out of date")
            end
        else
            write(entrypoint_path, entrypoint)
            println("Updated Compiler entrypoint")
        end
        return success
    end
end

function print_help()
    println("""
    Usage: julia Compiler/update-snapshots.jl [--check] [--config=PATH]

    Update the Compiler snapshots specified in Compiler/snapshots.toml.

      --check        Check generated sources without modifying them.
      --config=PATH  Read a different snapshot config file.
      -h, --help     Show this help.
    """)
    return nothing
end

function parse_options(args::Vector{String})
    check = false
    config_path = DEFAULT_CONFIG_PATH
    for arg in args
        if arg == "--check"
            check = true
        elseif startswith(arg, "--config=")
            config_path = abspath(split(arg, "="; limit=2)[2])
        elseif arg == "-h" || arg == "--help"
            print_help()
            return nothing
        else
            error("unknown argument: $arg")
        end
    end
    return Options(check, config_path)
end

function (@main)(args::Vector{String})
    options = parse_options(args)
    options === nothing && return 0
    config = load_snapshot_config(options.config_path)
    compiler_root = dirname(options.config_path)
    success = materialize_snapshots(config, compiler_root; check=options.check)
    return success ? 0 : 1
end
