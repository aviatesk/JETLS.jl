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
    base::String
    base_branch::String
    patches::Union{Nothing,String}
    destination::String
    runtime_range::VersionRange
end

struct SnapshotConfig
    upstream::Upstream
    snapshots::Vector{Snapshot}
end

abstract type Command end

struct UpdateCommand <: Command
    check::Bool
end

struct CheckoutCommand <: Command
    label::String
    repository::String
end

struct ExportCommand <: Command
    label::String
    repository::String
    ref::String
end

struct Options{C<:Command}
    command::C
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

function is_within(path::String, root::String)
    path_parts = splitpath(path)
    root_parts = splitpath(root)
    length(path_parts) ≥ length(root_parts) || return false
    return path_parts[1:length(root_parts)] == root_parts
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
    patch_directories = Set{String}()
    versions = Set{VersionNumber}()
    for (label, value) in snapshots_data
        value isa Dict{String,Any} || error("snapshot `$label` must be a table")
        context = "snapshot `$label`"
        version = parse_version(label)
        version in versions && error("duplicate normalized snapshot version `$label`")
        push!(versions, version)

        base = required_string(value, "base", context)
        occursin(COMMIT_PATTERN, base) ||
            error("$context must use a full lowercase 40-character commit SHA for `base`")
        base_branch = required_string(value, "base-branch", context)
        patches = if haskey(value, "patches")
            validate_relative_path(
                required_string(value, "patches", context), "$context patches")
        else
            nothing
        end
        if patches !== nothing
            patches in patch_directories &&
                error("duplicate snapshot patch directory `$patches`")
            push!(patch_directories, patches)
        end
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
            label, base, base_branch, patches, destination, VersionRange(lower, upper)))
    end
    for patches in patch_directories, destination in destinations
        (is_within(patches, destination) || is_within(destination, patches)) &&
            error("snapshot patch directory `$patches` overlaps destination `$destination`")
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

function find_snapshot(config::SnapshotConfig, label::String)
    for snapshot in config.snapshots
        snapshot.label == label && return snapshot
    end
    labels = join(getfield.(config.snapshots, :label), ", ")
    error("unknown snapshot `$label` (expected one of: $labels)")
end

function patch_files(compiler_root::String, snapshot::Snapshot)
    patches = snapshot.patches
    patches === nothing && return String[]
    directory = joinpath(compiler_root, patches)
    isdir(directory) || error(
        "patch directory of snapshot $(snapshot.label) does not exist: $patches")
    files = String[]
    for name in readdir(directory)
        startswith(name, '.') && continue
        path = joinpath(directory, name)
        isfile(path) && endswith(name, ".patch") ||
            error("unexpected entry in patch directory $patches: $name")
        push!(files, path)
    end
    isempty(files) && error(
        "patch directory of snapshot $(snapshot.label) contains no patches: $patches")
    return files
end

function fetch_commit(repository_path::String, snapshot::Snapshot)
    println("Fetching base of Compiler snapshot $(snapshot.label) at $(snapshot.base)")
    run(`git -C $repository_path fetch --quiet --depth=1 origin $(snapshot.base)`)
    commit_expression = "$(snapshot.base)^{commit}"
    resolved = readchomp(`git -C $repository_path rev-parse $commit_expression`)
    resolved == snapshot.base || error(
        "snapshot $(snapshot.label) resolved to $resolved instead of $(snapshot.base)")
    return nothing
end

function apply_patch(
        repository_path::String, extract_root::String, snapshot::Snapshot, patch::String
    )
    # `git apply` resolves patch paths against the work tree only when it runs inside it.
    command = Cmd(`git --git-dir=$repository_path --work-tree=$extract_root
        apply --whitespace=nowarn $patch`; dir=extract_root)
    try
        run(command)
    catch err
        err isa ProcessFailedException || rethrow()
        error("failed to apply $(basename(patch)) to Compiler snapshot $(snapshot.label)")
    end
    return nothing
end

function extract_snapshot(
        repository_path::String,
        upstream::Upstream,
        snapshot::Snapshot,
        patches::Vector{String},
        output_root::String
    )
    snapshot_root = joinpath(output_root, snapshot.label)
    extract_root = joinpath(snapshot_root, "archive")
    archive_path = joinpath(snapshot_root, "snapshot.tar")
    mkpath(extract_root)

    open(archive_path, "w") do io
        command = `git -C $repository_path archive $(snapshot.base) -- $(upstream.subdir)`
        run(pipeline(command; stdout=io))
    end
    Tar.extract(archive_path, extract_root)

    for patch in patches
        apply_patch(repository_path, extract_root, snapshot, patch)
    end
    for path in collect_files(extract_root)
        is_within(path, upstream.subdir) || error(
            "patches of snapshot $(snapshot.label) create $path outside $(upstream.subdir)")
    end

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
    println(io, "    # outside the snapshot ranges: ", join(ranges, ", "))
    println(io, "    Base.include(Base.__toplevel__, \"fallback.jl\")")
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
    patches = Dict{String,Vector{String}}(
        snapshot.label => patch_files(compiler_root, snapshot)
        for snapshot in config.snapshots)
    mktempdir() do temporary_root
        repository_path = joinpath(temporary_root, "repository.git")
        generated_root = joinpath(temporary_root, "generated")
        run(`git init --bare --quiet $repository_path`)
        run(`git -C $repository_path config maintenance.auto false`)
        run(`git -C $repository_path remote add origin $(config.upstream.repository)`)

        generated = Dict{String,String}()
        for snapshot in config.snapshots
            fetch_commit(repository_path, snapshot)
            generated[snapshot.label] = extract_snapshot(
                repository_path, config.upstream, snapshot, patches[snapshot.label],
                generated_root)
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

        fallback_source = joinpath(@__DIR__, "src", "fallback.jl")
        fallback_path = joinpath(compiler_root, "src", "fallback.jl")
        if check
            if isfile(fallback_path) && read(fallback_path) == read(fallback_source)
                println("Compiler fallback is up to date")
            else
                success = false
                println("Compiler fallback is out of date")
            end
        elseif fallback_path != fallback_source
            cp(fallback_source, fallback_path; force=true)
            println("Updated Compiler fallback")
        end
        return success
    end
end

function has_commit(repository::String, commit::String)
    commit_expression = "$commit^{commit}"
    command = `git -C $repository cat-file -e $commit_expression`
    return success(pipeline(command; stderr=devnull))
end

function checkout_snapshot(
        config::SnapshotConfig, compiler_root::String, snapshot::Snapshot,
        repository::String
    )
    patches = patch_files(compiler_root, snapshot)
    status = readchomp(`git -C $repository status --porcelain --untracked-files=no`)
    isempty(status) || error("$repository has uncommitted changes")
    if !has_commit(repository, snapshot.base)
        println("Fetching base of Compiler snapshot $(snapshot.label) at $(snapshot.base)")
        run(`git -C $repository fetch --quiet $(config.upstream.repository) $(snapshot.base)`)
        has_commit(repository, snapshot.base) ||
            error("failed to fetch $(snapshot.base) into $repository")
    end
    run(`git -C $repository switch --quiet --detach $(snapshot.base)`)
    isempty(patches) || run(`git -C $repository am --quiet --3way $patches`)
    println("Checked out Compiler snapshot $(snapshot.label) in $repository: ",
        "$(length(patches)) patches on top of $(snapshot.base)")
    return nothing
end

function export_patches(
        config::SnapshotConfig, compiler_root::String, snapshot::Snapshot,
        repository::String, ref::String
    )
    patches = snapshot.patches
    patches === nothing &&
        error("snapshot $(snapshot.label) does not define a `patches` directory")
    base = snapshot.base
    has_commit(repository, base) || error(
        "$repository does not contain the base of snapshot $(snapshot.label): $base")
    success(`git -C $repository merge-base --is-ancestor $base $ref`) || error(
        "$ref is not based on $base; update `base` of snapshot $(snapshot.label) first")
    range = "$base..$ref"
    isempty(readchomp(`git -C $repository rev-list --merges $range`)) ||
        error("$range contains merge commits")

    mktempdir() do output
        pathspec = ":(top)$(config.upstream.subdir)"
        # Pin the options that user configuration could otherwise change so that exported
        # patches stay stable across maintainers and keep applying with `git apply`.
        run(`git -C $repository
            format-patch --quiet --zero-commit --no-signature --no-numbered --no-thread
            --no-cover-letter --no-attach --no-signoff --no-base --no-relative
            --unified=3 --src-prefix=a/ --dst-prefix=b/ --suffix=.patch
            --output-directory=$output $range -- $pathspec`)
        exported = readdir(output)
        isempty(exported) &&
            error("no commits in $range touch $(config.upstream.subdir)")

        directory = joinpath(compiler_root, patches)
        mkpath(directory)
        for name in readdir(directory)
            endswith(name, ".patch") && rm(joinpath(directory, name))
        end
        for name in exported
            cp(joinpath(output, name), joinpath(directory, name))
        end
        println("Exported $(length(exported)) patches of Compiler snapshot ",
            "$(snapshot.label) to $patches")
    end
    return nothing
end

function print_help()
    println("""
    Usage: julia Compiler/update-snapshots.jl [--check] [--config=PATH]
           julia Compiler/update-snapshots.jl --checkout=VERSION --repo=PATH [--config=PATH]
           julia Compiler/update-snapshots.jl --export=VERSION --repo=PATH [--ref=REF]
                                              [--config=PATH]

    Update the Compiler snapshots specified in Compiler/snapshots.toml.

      --check             Check generated sources without modifying them.
      --checkout=VERSION  Detach the Julia work tree at PATH at the base of snapshot
                          VERSION and apply its patches as commits.
      --export=VERSION    Replace the patches of snapshot VERSION with the commits
                          between its base and REF in the Julia repository at PATH.
      --repo=PATH         Julia repository used by --checkout and --export.
      --ref=REF           Revision exported by --export (default: HEAD).
      --config=PATH       Read a different snapshot config file.
      -h, --help          Show this help.
    """)
    return nothing
end

function option_value(arg::String)
    value = split(arg, "="; limit=2)[2]
    isempty(value) && error("missing value: $arg")
    return String(value)
end

function parse_options(args::Vector{String})
    check = false
    checkout_label = export_label = repository = ref = nothing
    config_path = DEFAULT_CONFIG_PATH
    for arg in args
        if arg == "--check"
            check = true
        elseif startswith(arg, "--checkout=")
            checkout_label = option_value(arg)
        elseif startswith(arg, "--export=")
            export_label = option_value(arg)
        elseif startswith(arg, "--repo=")
            repository = abspath(option_value(arg))
        elseif startswith(arg, "--ref=")
            ref = option_value(arg)
        elseif startswith(arg, "--config=")
            config_path = abspath(option_value(arg))
        elseif arg == "-h" || arg == "--help"
            print_help()
            return nothing
        else
            error("unknown argument: $arg")
        end
    end

    checkout_label === nothing || export_label === nothing ||
        error("--checkout and --export cannot be combined")
    label = checkout_label === nothing ? export_label : checkout_label
    if label === nothing
        repository === nothing || error("--repo requires --checkout or --export")
        ref === nothing || error("--ref requires --export")
        return Options(UpdateCommand(check), config_path)
    end
    check && error("--check cannot be combined with --checkout or --export")
    repository === nothing && error("--checkout and --export require --repo")
    if checkout_label !== nothing
        ref === nothing || error("--ref requires --export")
        return Options(CheckoutCommand(label, repository), config_path)
    end
    return Options(ExportCommand(label, repository, something(ref, "HEAD")), config_path)
end

function run_command(command::UpdateCommand, config::SnapshotConfig, compiler_root::String)
    return materialize_snapshots(config, compiler_root; check=command.check)
end

function run_command(command::CheckoutCommand, config::SnapshotConfig, compiler_root::String)
    snapshot = find_snapshot(config, command.label)
    checkout_snapshot(config, compiler_root, snapshot, command.repository)
    return true
end

function run_command(command::ExportCommand, config::SnapshotConfig, compiler_root::String)
    snapshot = find_snapshot(config, command.label)
    export_patches(config, compiler_root, snapshot, command.repository, command.ref)
    return true
end

function (@main)(args::Vector{String})
    options = parse_options(args)
    options === nothing && return 0
    config = load_snapshot_config(options.config_path)
    compiler_root = dirname(options.config_path)
    success = run_command(options.command, config, compiler_root)
    return success ? 0 : 1
end
