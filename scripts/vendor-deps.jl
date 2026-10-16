#!/usr/bin/env julia

const DEVELOPMENT_PREFERENCE_KEYS = (
    "JETLSCore" => "JETLS_DEV_MODE",
)

# Dependencies loaded only in development mode, which installed releases never enable
const DEVELOPMENT_DEPENDENCIES = (
    "JETLSCore" => "Revise",
)

using Pkg
using TOML
using UUIDs

const CURRENT_DIR = pwd()

const VENDOR_DIR = joinpath(CURRENT_DIR, "vendor")
const VENDOR_NAMESPACE = "JETLS-vendor"
const COVERAGE_OUTPUT_REGEX = r"\.jl\.\d+\.(?:cov|mem)$"

struct Config
    source_branch::String
    use_local_path::Bool
    rev::Union{String, Nothing}
end

function is_jll_package(name::AbstractString)
    return endswith(name, "_jll")
end

function should_vendor(uuid::UUID, name::AbstractString)
    Pkg.Types.is_stdlib(uuid) && return false
    is_jll_package(name) && return false
    name == "JETLS" && return false
    return true
end

function is_extension_module(pkgid::Base.PkgId, mod::Module)
    pkg_dir = pkgdir(mod)
    pkg_dir === nothing && return true

    project_path = joinpath(pkg_dir, "Project.toml")
    isfile(project_path) || return true

    project = TOML.parsefile(project_path)
    pkg_name = get(project, "name", nothing)
    pkg_name === nothing && return true

    return pkg_name != pkgid.name
end

# Loading JETLSCore alone misses dependencies that it does not load unconditionally,
# which releases still need to vendor to resolve them.
function load_release_dependencies()
    dependencies = Pkg.dependencies()
    queue = collect(values(Pkg.project().dependencies))
    seen = Set{UUID}()
    while !isempty(queue)
        uuid = pop!(queue)
        uuid in seen && continue
        push!(seen, uuid)
        info = dependencies[uuid]
        pkgid = Base.PkgId(uuid, info.name)
        if should_vendor(uuid, info.name) && !haskey(Base.loaded_modules, pkgid)
            @info "Loading $(info.name), which loading JETLSCore does not load"
            Base.require(pkgid)
        end
        append!(queue, values(info.dependencies))
    end
end

function collect_packages_to_vendor()
    packages = Pair{String, UUID}[]
    for (pkgid, mod) in Base.loaded_modules
        pkgid.uuid === nothing && continue
        should_vendor(pkgid.uuid, pkgid.name) || continue
        is_extension_module(pkgid, mod) && continue
        push!(packages, pkgid.name => pkgid.uuid)
    end
    sort!(packages, by = first)
    return packages
end

function generate_new_uuid(original_uuid::UUID)
    return uuid5(original_uuid, VENDOR_NAMESPACE)
end

function remove_stale_vendored_packages(packages::Vector{Pair{String, UUID}})
    isdir(VENDOR_DIR) || return

    expected = Set{String}(name for (name, _) in packages)

    for entry in readdir(VENDOR_DIR)
        entry_path = joinpath(VENDOR_DIR, entry)
        isdir(entry_path) || continue
        entry in expected && continue
        @info "Removing stale vendored package: $entry_path"
        rm(entry_path; recursive=true)
    end
end

function copy_package_source(mod::Module, pkg_name::AbstractString)
    src_dir = pkgdir(mod)
    src_dir === nothing && error("Could not find source directory for $pkg_name")

    dest_dir = joinpath(VENDOR_DIR, pkg_name)

    if isdir(dest_dir)
        @info "Removing existing vendor directory: $dest_dir"
        rm(dest_dir; recursive = true)
    end

    @info "Copying $pkg_name from $src_dir to $dest_dir"
    cp(src_dir, dest_dir)

    for (root, _, files) in walkdir(dest_dir)
        for file in files
            filepath = joinpath(root, file)
            if occursin(COVERAGE_OUTPUT_REGEX, file)
                rm(filepath)
                continue
            end
            chmod(filepath, 0o644)
        end
    end

    return dest_dir
end

function uuid_to_jl_hex_tuple(uuid::UUID)
    s = string(uuid)
    parts = split(s, '-')
    hi = "0x$(parts[1])_$(parts[2])_$(parts[3])"
    lo = "0x$(parts[4])_$(parts[5])"
    return "($hi, $lo)"
end

function compiler_snapshot_sources(vendor_pkg_dir::AbstractString)
    config_path = joinpath(vendor_pkg_dir, "snapshots.toml")
    isfile(config_path) ||
        error("Compiler snapshot config not found: $config_path")

    config = TOML.parsefile(config_path)
    snapshots = get(config, "snapshots", nothing)
    snapshots isa Dict{String,Any} ||
        error("Compiler snapshot config must define a `snapshots` table")

    source_files = String[]
    for (label, snapshot) in snapshots
        snapshot isa Dict{String,Any} ||
            error("Compiler snapshot `$label` must be a table")
        destination = get(snapshot, "destination", nothing)
        destination isa String ||
            error("Compiler snapshot `$label` must define `destination`")

        source_file = normpath(
            joinpath(vendor_pkg_dir, destination, "src", "Compiler.jl"))
        relative_path = relpath(source_file, vendor_pkg_dir)
        any(==(".."), splitpath(relative_path)) &&
            error("Compiler snapshot `$label` escapes the package directory")
        isfile(source_file) ||
            error("Compiler snapshot `$label` is missing `src/Compiler.jl`")
        push!(source_files, source_file)
    end
    isempty(source_files) && error("Compiler sources must define a snapshot")
    sort!(source_files)
    return source_files
end

function rewrite_compiler_module_uuid!(
        vendor_pkg_dir::AbstractString,
        original_uuid::UUID,
        new_uuid::UUID
    )
    old_hex = uuid_to_jl_hex_tuple(original_uuid)
    new_hex = uuid_to_jl_hex_tuple(new_uuid)

    for source_file in compiler_snapshot_sources(vendor_pkg_dir)
        content = read(source_file, String)
        contains(content, old_hex) ||
            error("Expected Compiler UUID $old_hex in $source_file")
        write(source_file, replace(content, old_hex => new_hex))
        @info "Rewrote jl_set_module_uuid in $source_file: $old_hex => $new_hex"
    end
end

function rewrite_package_uuid(vendor_pkg_dir::AbstractString, new_uuid::UUID)
    project_path = joinpath(vendor_pkg_dir, "Project.toml")
    isfile(project_path) || error("Project.toml not found in $vendor_pkg_dir")

    project = TOML.parsefile(project_path)
    old_uuid = project["uuid"]
    project["uuid"] = string(new_uuid)

    @info "Rewriting UUID in $project_path: $old_uuid => $(project["uuid"])"

    open(project_path, "w") do io
        TOML.print(io, project)
    end

    return project
end

function collect_loaded_package_uuids()
    uuids = Set{UUID}()
    for (pkgid, _) in Base.loaded_modules
        pkgid.uuid === nothing && continue
        push!(uuids, pkgid.uuid)
    end
    return uuids
end

# Drop extensions JETLS does not load so analyzed environments cannot activate them
# and interfere with vendored dependency isolation.
function remove_unused_weakdeps_and_extensions!(
        vendor_pkg_dir::AbstractString,
        loaded_uuids::Set{UUID},
        uuid_mapping::Dict{UUID,UUID}
    )
    project_path = joinpath(vendor_pkg_dir, "Project.toml")
    isfile(project_path) || return

    project = TOML.parsefile(project_path)
    modified = false

    weakdeps = get(project, "weakdeps", Dict{String,Any}())
    extensions = get(project, "extensions", Dict{String,Any}())

    isempty(weakdeps) && isempty(extensions) && return

    weakdeps_to_keep = Set{String}()
    extensions_to_keep = Set{String}()

    for (ext_name, triggers) in extensions
        trigger_list = triggers isa String ? [triggers] : triggers
        trigger_uuids = [UUID(weakdeps[t]) for t in trigger_list if haskey(weakdeps, t)]
        if any(uuid -> uuid in loaded_uuids, trigger_uuids)
            push!(extensions_to_keep, ext_name)
            for t in trigger_list
                push!(weakdeps_to_keep, t)
            end
        end
    end

    weakdeps_to_remove = setdiff(keys(weakdeps), weakdeps_to_keep)
    extensions_to_remove = setdiff(keys(extensions), extensions_to_keep)

    if !isempty(weakdeps_to_remove)
        @info "Removing unused weakdeps from $(basename(vendor_pkg_dir)): $weakdeps_to_remove"
        for name in weakdeps_to_remove
            delete!(weakdeps, name)
        end
        if isempty(weakdeps)
            delete!(project, "weakdeps")
        end
        compat = get(project, "compat", nothing)
        if compat isa Dict{String,Any}
            deps = get(project, "deps", Dict{String,Any}())
            extras = get(project, "extras", Dict{String,Any}())
            for name in weakdeps_to_remove
                haskey(deps, name) || haskey(extras, name) || delete!(compat, name)
            end
        end
        modified = true
    end

    if !isempty(weakdeps_to_keep)
        for name in weakdeps_to_keep
            original_uuid = UUID(weakdeps[name])
            if haskey(uuid_mapping, original_uuid)
                new_uuid = uuid_mapping[original_uuid]
                weakdeps[name] = string(new_uuid)
                @info "Updated weakdep UUID in $(basename(vendor_pkg_dir)): $name $original_uuid => $new_uuid"
                modified = true
            end
        end
    end

    if !isempty(extensions_to_remove)
        @info "Removing unused extensions from $(basename(vendor_pkg_dir)): $extensions_to_remove"
        for name in extensions_to_remove
            delete!(extensions, name)
        end
        if isempty(extensions)
            delete!(project, "extensions")
        end
        modified = true

        ext_dir = joinpath(vendor_pkg_dir, "ext")
        if isdir(ext_dir)
            for ext_name in extensions_to_remove
                ext_file = joinpath(ext_dir, "$ext_name.jl")
                ext_subdir = joinpath(ext_dir, ext_name)
                if isfile(ext_file)
                    @info "Removing $ext_file"
                    rm(ext_file)
                end
                if isdir(ext_subdir)
                    @info "Removing $ext_subdir"
                    rm(ext_subdir; recursive=true)
                end
            end
            if isempty(readdir(ext_dir))
                rm(ext_dir)
            end
        end
    end

    if modified
        open(project_path, "w") do io
            TOML.print(io, project)
        end
    end
end

function update_vendored_dependencies!(
        vendor_pkg_dir::AbstractString,
        uuid_mapping::Dict{UUID, UUID},
        use_local_path::Bool,
        rev::Union{String, Nothing}
    )
    project_path = joinpath(vendor_pkg_dir, "Project.toml")
    project = TOML.parsefile(project_path)

    haskey(project, "deps") || return

    deps_updated = false
    vendored_deps = String[]

    for (dep_name, dep_uuid_str) in project["deps"]
        dep_uuid = UUID(dep_uuid_str)
        if haskey(uuid_mapping, dep_uuid)
            new_uuid = uuid_mapping[dep_uuid]
            project["deps"][dep_name] = string(new_uuid)
            @info "Updated dependency in $(basename(vendor_pkg_dir)): $dep_name $dep_uuid => $new_uuid"
            deps_updated = true
            push!(vendored_deps, dep_name)
        end
    end

    if !isempty(vendored_deps)
        if !haskey(project, "sources")
            project["sources"] = Dict{String, Any}()
        end

        if use_local_path
            for dep_name in vendored_deps
                project["sources"][dep_name] = Dict{String, Any}(
                    "path" => joinpath("..", dep_name)
                )
                @info "Added source entry in $(basename(vendor_pkg_dir)) for $dep_name with path"
            end
        else
            jetls_url = "https://github.com/aviatesk/JETLS.jl"
            for dep_name in vendored_deps
                project["sources"][dep_name] = Dict{String, Any}(
                    "url" => jetls_url,
                    "subdir" => joinpath("vendor", dep_name),
                    "rev" => rev
                )
                @info "Added source entry in $(basename(vendor_pkg_dir)) for $dep_name with rev=$rev"
            end
        end
        deps_updated = true
    end

    return if deps_updated
        open(project_path, "w") do io
            TOML.print(io, project)
        end
    end
end

function collect_transitive_vendored_deps(
        vendor_dir::AbstractString,
        direct_deps::Set{String},
        vendored_uuids::Set{UUID}
    )
    transitive_deps = Dict{String, UUID}()
    queue = collect(direct_deps)
    while !isempty(queue)
        pkg_name = pop!(queue)
        project = TOML.parsefile(joinpath(vendor_dir, pkg_name, "Project.toml"))
        for (dep_name, dep_uuid_str) in get(project, "deps", Dict{String, Any}())
            dep_uuid = UUID(dep_uuid_str)
            dep_uuid in vendored_uuids || continue
            dep_name in direct_deps && continue
            haskey(transitive_deps, dep_name) && continue
            transitive_deps[dep_name] = dep_uuid
            push!(queue, dep_name)
        end
    end
    return transitive_deps
end

function update_workspace_project!(
        workspace_path::AbstractString,
        uuid_mapping::Dict{UUID, UUID},
        vendor_dir::AbstractString,
        use_local_path::Bool,
        rev::Union{String, Nothing}
    )
    project_path = joinpath(workspace_path, "Project.toml")
    isfile(project_path) || return

    project = TOML.parsefile(project_path)
    haskey(project, "deps") || return

    vendored_deps = Set{String}()
    deps_updated = false

    for (dep_name, dep_uuid_str) in project["deps"]
        dep_uuid = UUID(dep_uuid_str)
        if haskey(uuid_mapping, dep_uuid)
            new_uuid = uuid_mapping[dep_uuid]
            project["deps"][dep_name] = string(new_uuid)
            @info "  Updated dependency in $(basename(workspace_path))/Project.toml: $dep_name"
            push!(vendored_deps, dep_name)
            deps_updated = true
        end
    end

    # `Pkg.add(; url, subdir)` resolves the transitive vendored dependencies of a package
    # project through the `[sources]` of the vendored packages at `rev`, whose relative
    # paths from the local vendoring step do not exist outside a repository checkout,
    # so list the whole closure directly like the root project does.
    if haskey(project, "uuid") && !isempty(vendored_deps)
        vendored_uuids = Set{UUID}(values(uuid_mapping))
        transitive_deps = collect_transitive_vendored_deps(vendor_dir, vendored_deps, vendored_uuids)
        for (dep_name, dep_uuid) in transitive_deps
            project["deps"][dep_name] = string(dep_uuid)
            @info "  Added transitive vendored dependency in $(basename(workspace_path))/Project.toml: $dep_name"
            push!(vendored_deps, dep_name)
        end
    end

    if !isempty(vendored_deps)
        if !haskey(project, "sources")
            project["sources"] = Dict{String, Any}()
        end

        for dep_name in vendored_deps
            if use_local_path
                vendor_base_path = relpath(vendor_dir, workspace_path)
                project["sources"][dep_name] = Dict{String, Any}(
                    "path" => joinpath(vendor_base_path, dep_name)
                )
                @info "  Added local source for $dep_name in $(basename(workspace_path))"
            else
                rev isa String || error("A revision is required for remote vendored sources")
                project["sources"][dep_name] = Dict{String, Any}(
                    "url" => "https://github.com/aviatesk/JETLS.jl",
                    "subdir" => joinpath("vendor", dep_name),
                    "rev" => rev
                )
                @info "  Added remote source for $dep_name in $(basename(workspace_path))"
            end
        end
    end

    if deps_updated
        open(project_path, "w") do io
            TOML.print(io, project)
        end
    end
end

function remove_development_preferences!(project::Dict{String, Any})::Bool
    preferences = get(project, "preferences", nothing)
    preferences isa Dict{String, Any} || return false

    modified = false
    for (package_name, preference_key) in DEVELOPMENT_PREFERENCE_KEYS
        package_preferences = get(preferences, package_name, nothing)
        package_preferences isa Dict{String, Any} || continue
        if haskey(package_preferences, preference_key)
            delete!(package_preferences, preference_key)
            isempty(package_preferences) && delete!(preferences, package_name)
            modified = true
        end
    end
    modified && isempty(preferences) && delete!(project, "preferences")
    return modified
end

function remove_development_dependencies!(project::Dict{String, Any})::Bool
    modified = false
    for (package_name, dep_name) in DEVELOPMENT_DEPENDENCIES
        get(project, "name", nothing) == package_name || continue
        for section in ("deps", "compat", "sources")
            entries = get(project, section, nothing)
            if entries isa Dict{String, Any} && haskey(entries, dep_name)
                delete!(entries, dep_name)
                modified = true
            end
        end
    end
    return modified
end

function validate_no_development_preferences(project::Dict{String, Any})
    preferences = get(project, "preferences", nothing)
    preferences isa Dict{String, Any} || return nothing

    for (package_name, preference_key) in DEVELOPMENT_PREFERENCE_KEYS
        package_preferences = get(preferences, package_name, nothing)
        package_preferences isa Dict{String, Any} || continue
        if haskey(package_preferences, preference_key)
            error("Development preference $package_name.$preference_key leaked into release Project.toml")
        end
    end
    return nothing
end

# `Pkg.Apps.add` on Julia 1.12 and 1.13.0 resolves the app environment before it installs
# any registry, so every package that a release resolves must be vendored or a stdlib.
function validate_no_unvendored_dependencies(
        vendored_packages::Vector{Pair{String, UUID}},
        uuid_mapping::Dict{UUID, UUID}
    )
    vendored_uuids = Set{UUID}(values(uuid_mapping))
    project_paths = [joinpath(CURRENT_DIR, "Project.toml")]
    for (pkg_name, original_uuid) in vendored_packages
        haskey(uuid_mapping, original_uuid) || continue
        push!(project_paths, joinpath(VENDOR_DIR, pkg_name, "Project.toml"))
    end
    for project_path in project_paths
        project = TOML.parsefile(project_path)
        for (dep_name, dep_uuid_str) in get(project, "deps", Dict{String, Any}())
            dep_uuid = UUID(dep_uuid_str)
            Pkg.Types.is_stdlib(dep_uuid) && continue
            dep_uuid in vendored_uuids && continue
            error("Dependency $dep_name [$dep_uuid] of $(relpath(project_path, CURRENT_DIR)) is not vendored, so installing the release would require a registry")
        end
    end
    return nothing
end

function update_project_with_vendored_deps(
        uuid_mapping::Dict{UUID, UUID},
        all_vendored_packages::Vector{Pair{String, UUID}},
        use_local_path::Bool,
        rev::Union{String, Nothing}
    )
    project_path = joinpath(CURRENT_DIR, "Project.toml")
    project = TOML.parsefile(project_path)
    remove_development_preferences!(project)

    for (dep_name, dep_uuid_str) in project["deps"]
        dep_uuid = UUID(dep_uuid_str)
        if haskey(uuid_mapping, dep_uuid)
            new_uuid = uuid_mapping[dep_uuid]
            project["deps"][dep_name] = string(new_uuid)
            @info "Updated dependency in Project.toml: $dep_name $dep_uuid => $new_uuid"
        end
    end

    for (pkg_name, original_uuid) in all_vendored_packages
        if haskey(uuid_mapping, original_uuid)
            new_uuid = uuid_mapping[original_uuid]
            if !haskey(project["deps"], pkg_name)
                project["deps"][pkg_name] = string(new_uuid)
                @info "Added vendored dependency to Project.toml: $pkg_name => $new_uuid"
            end
        end
    end

    if !haskey(project, "sources")
        project["sources"] = Dict{String, Any}()
    end

    if use_local_path
        for (pkg_name, original_uuid) in all_vendored_packages
            if haskey(uuid_mapping, original_uuid)
                project["sources"][pkg_name] = Dict{String, Any}(
                    "path" => joinpath("vendor", pkg_name)
                )
                @info "Added source entry for $pkg_name with path"
            end
        end
    else
        jetls_url = "https://github.com/aviatesk/JETLS.jl"
        for (pkg_name, original_uuid) in all_vendored_packages
            if haskey(uuid_mapping, original_uuid)
                new_source = Dict{String, Any}()
                new_source["url"] = jetls_url
                new_source["subdir"] = joinpath("vendor", pkg_name)
                new_source["rev"] = rev

                project["sources"][pkg_name] = new_source
                @info "Added source entry for $pkg_name with rev=$rev"
            end
        end
    end

    main_path = joinpath(CURRENT_DIR, "Project.toml")
    @info "Writing vendored Project.toml to $main_path"
    open(main_path, "w") do io
        TOML.print(io, project)
    end

    if haskey(project, "workspace") && haskey(project["workspace"], "projects")
        @info "Updating workspace projects..."
        for workspace_name in project["workspace"]["projects"]
            workspace_path = joinpath(CURRENT_DIR, workspace_name)
            if isdir(workspace_path)
                @info "Processing workspace: $workspace_name"
                update_workspace_project!(workspace_path, uuid_mapping, VENDOR_DIR, use_local_path, rev)
            end
        end
    end
end

function fetch_project_from_branch(
        source_branch::AbstractString,
        project_path::AbstractString
    )::String
    result = read(`git show $(source_branch):$(project_path)`, String)
    return result
end

function get_workspace_projects()::Vector{String}
    project_path = joinpath(CURRENT_DIR, "Project.toml")
    isfile(project_path) || return String[]

    project = TOML.parsefile(project_path)
    if haskey(project, "workspace") && haskey(project["workspace"], "projects")
        return collect(project["workspace"]["projects"])
    end
    return String[]
end

function clean_manifests()
    @info "Cleaning manifest files..."
    for file in readdir(CURRENT_DIR)
        if file == "Manifest.toml" || startswith(file, "Manifest-v") && endswith(file, ".toml")
            manifest_path = joinpath(CURRENT_DIR, file)
            @info "Removing $manifest_path"
            rm(manifest_path)
        end
    end
end

function vendor_dependencies_from_branch(config::Config)
    @info "=== JETLS Vendoring Script ==="
    @info "Source branch: $(config.source_branch)"
    @info "Use local path: $(config.use_local_path)"
    @info "Rev: $(something(config.rev, "(not set)"))"

    @info "\n[Step 1/5] Fetching Project.toml files from $(config.source_branch)..."

    main_project = fetch_project_from_branch(config.source_branch, "Project.toml")
    main_path = joinpath(CURRENT_DIR, "Project.toml")
    write(main_path, main_project)
    @info "Fetched Project.toml from $(config.source_branch)"

    # Preserve source-branch projects before vendoring rewrites their metadata.
    backup_path = main_path * ".bak"
    cp(main_path, backup_path; force=true)
    @info "Backed up Project.toml to $(basename(backup_path))"

    project = TOML.parsefile(main_path)
    if remove_development_preferences!(project)
        open(main_path, "w") do io
            TOML.print(io, project)
        end
        @info "Removed development-only preferences from release Project.toml"
    end

    workspace_projects = get_workspace_projects()
    for workspace_name in workspace_projects
        workspace_path = joinpath(CURRENT_DIR, workspace_name)
        workspace_project_path = joinpath(workspace_name, "Project.toml")

        try
            workspace_project = fetch_project_from_branch(config.source_branch, workspace_project_path)
            write(joinpath(workspace_path, "Project.toml"), workspace_project)
            @info "Fetched $workspace_project_path from $(config.source_branch)"

            workspace_backup = joinpath(workspace_path, "Project.toml.bak")
            cp(joinpath(workspace_path, "Project.toml"), workspace_backup; force=true)
            @info "Backed up $workspace_project_path to $(basename(workspace_backup))"
        catch e
            @warn "Could not fetch $workspace_project_path from $(config.source_branch): $e"
        end

        workspace_project_file = joinpath(workspace_path, "Project.toml")
        isfile(workspace_project_file) || continue
        workspace_project_data = TOML.parsefile(workspace_project_file)
        if remove_development_dependencies!(workspace_project_data)
            open(workspace_project_file, "w") do io
                TOML.print(io, workspace_project_data)
            end
            @info "Removed development-only dependencies from $workspace_project_path"
        end
    end

    @info "\n[Step 2/5] Cleaning manifest files..."
    clean_manifests()

    @info "\n[Step 3/5] Updating dependencies..."
    Pkg.update()

    @info "\n[Step 4/5] Running vendor isolation..."
    vendor_loaded_packages(config.use_local_path, config.rev)

    @info "\n[Step 5/5] Cleaning manifest..."
    clean_manifests()
    if config.use_local_path
        @info "Reinstantiating with local paths..."
        Pkg.instantiate()
    else
        @info "Skipping Pkg.instantiate() - run manually after pushing the branch"
    end

    @info "\nRelease preparation complete!"
    @info "Vendored package directory: $(VENDOR_DIR)"
end

function print_help()
    println("""Usage: julia --project=. scripts/vendor-deps.jl
           --source-branch=BRANCH (--local | --rev=REV)

    Fetch project files from BRANCH and vendor non-stdlib, non-JLL dependencies
    for a JETLS release.

    Effects:
      - Replace Project.toml files with versions from BRANCH when available,
        then rewrite their vendored dependency metadata
      - Remove development-only preferences from the root Project.toml
      - Remove development-only dependencies, e.g. Revise, from the subpackage
        Project.toml files
      - Save fetched project files as Project.toml.bak before rewriting them
      - Run Pkg.update() before rebuilding the vendored dependency set
      - Replace package directories in vendor/ and remove stale directories
      - Remove root Manifest.toml and Manifest-v*.toml files; --local then
        reinstantiates the project

    Options:
      -h, --help                 Show this help message and exit
      --source-branch=BRANCH     Branch to fetch Project.toml files from (required)
      --local                    Use local paths in [sources]
      --rev=REV                  Use a Git revision in [sources]

    Example:
      julia --project=. scripts/vendor-deps.jl --source-branch=master --local""")
end

function parse_args(args::Vector{String})
    source_branch = nothing
    use_local_path = false
    rev = nothing

    for arg in args
        if arg == "--help" || arg == "-h"
            print_help()
            exit(0)
        elseif startswith(arg, "--source-branch=")
            source_branch = split(arg, "="; limit=2)[2]
        elseif arg == "--local"
            use_local_path = true
        elseif startswith(arg, "--rev=")
            rev = split(arg, "="; limit=2)[2]
        else
            @warn "Unknown argument: $arg"
            println("\nRun with --help for usage information")
            exit(1)
        end
    end

    if source_branch === nothing
        error("--source-branch argument is required\nRun with --help for usage information")
    end

    if use_local_path && rev !== nothing
        error("--local and --rev are mutually exclusive\nRun with --help for usage information")
    end

    if !use_local_path && rev === nothing
        error("Either --local or --rev must be specified\nRun with --help for usage information")
    end

    return Config(source_branch, use_local_path, rev)
end

function vendor_loaded_packages(use_local_path::Bool, rev::Union{String, Nothing})
    @info "Loading JETLSCore to populate Base.loaded_modules..."
    @eval using JETLSCore
    load_release_dependencies()

    @info "Identifying packages to vendor..."
    packages = collect_packages_to_vendor()
    @info "Found $(length(packages)) packages to vendor:"
    for (name, uuid) in packages
        println("  $name => $uuid")
    end

    mkpath(VENDOR_DIR)

    uuid_mapping = Dict{UUID, UUID}()

    @info "Step 1: Removing stale vendored packages..."
    remove_stale_vendored_packages(packages)

    @info "Step 2: Copying packages and rewriting UUIDs..."
    for (pkg_name, original_uuid) in packages
        pkgid = Base.PkgId(original_uuid, pkg_name)
        mod = get(Base.loaded_modules, pkgid, nothing)

        if mod === nothing
            @warn "Module $pkg_name not found in Base.loaded_modules, skipping"
            continue
        end

        new_uuid = generate_new_uuid(original_uuid)
        uuid_mapping[original_uuid] = new_uuid

        vendor_pkg_dir = copy_package_source(mod, pkg_name)
        rewrite_package_uuid(vendor_pkg_dir, new_uuid)
        if pkg_name == "Compiler"
            rewrite_compiler_module_uuid!(vendor_pkg_dir, original_uuid, new_uuid)
        end
    end

    @info "Step 3: Removing unused weakdeps and extensions..."
    loaded_uuids = collect_loaded_package_uuids()
    for (pkg_name, _) in packages
        vendor_pkg_dir = joinpath(VENDOR_DIR, pkg_name)
        remove_unused_weakdeps_and_extensions!(vendor_pkg_dir, loaded_uuids, uuid_mapping)
    end

    @info "Step 4: Updating inter-package dependencies..."
    for (pkg_name, _) in packages
        vendor_pkg_dir = joinpath(VENDOR_DIR, pkg_name)
        update_vendored_dependencies!(vendor_pkg_dir, uuid_mapping, use_local_path, rev)
    end

    @info "Step 5: Updating Project.toml with vendored dependencies..."
    update_project_with_vendored_deps(uuid_mapping, packages, use_local_path, rev)

    @info "Step 6: Tidying up Project.toml format..."
    project_path = joinpath(CURRENT_DIR, "Project.toml")
    project = Pkg.Types.read_project(project_path)
    Pkg.Types.write_project(project, project_path)
    validate_no_development_preferences(TOML.parsefile(project_path))
    validate_no_unvendored_dependencies(packages, uuid_mapping)

    @info "Vendor isolation complete!"
    @info "Vendored packages are in: $VENDOR_DIR"
end

function (@main)(args::Vector{String})
    vendor_dependencies_from_branch(parse_args(args))
end
