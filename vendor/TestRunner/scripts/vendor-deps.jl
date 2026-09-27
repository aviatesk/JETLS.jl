#!/usr/bin/env julia

using Pkg
using TOML
using UUIDs

const CURRENT_DIR = pwd()

const VENDOR_DIR = joinpath(CURRENT_DIR, "vendor")
const VENDOR_NAMESPACE = "TestRunner-vendor"

struct Config
    source_branch::String
    use_local_path::Bool
    rev::Union{String,Nothing}
end

function is_jll_package(name::AbstractString)
    return endswith(name, "_jll")
end

function should_vendor(uuid::UUID, name::AbstractString)
    Pkg.Types.is_stdlib(uuid) && return false
    is_jll_package(name) && return false
    name == "TestRunner" && return false
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

function collect_packages_to_vendor()
    packages = Pair{String,UUID}[]
    for (pkgid, mod) in Base.loaded_modules
        pkgid.uuid === nothing && continue
        should_vendor(pkgid.uuid, pkgid.name) || continue
        is_extension_module(pkgid, mod) && continue
        push!(packages, pkgid.name => pkgid.uuid)
    end
    sort!(packages; by=first)
    return packages
end

function generate_new_uuid(original_uuid::UUID)
    return uuid5(original_uuid, VENDOR_NAMESPACE)
end

function remove_stale_vendor_packages!(vendor_dir::AbstractString,
                                       packages::Vector{Pair{String,UUID}})
    isdir(vendor_dir) || return
    package_names = Set(first.(packages))
    for name in readdir(vendor_dir)
        path = joinpath(vendor_dir, name)
        isfile(joinpath(path, "Project.toml")) || continue
        name in package_names && continue
        @info "Removing stale vendor package: $path"
        rm(path; recursive=true)
    end
end

function copy_package_source(mod::Module, pkg_name::AbstractString)
    src_dir = pkgdir(mod)
    src_dir === nothing && error("Could not find source directory for $pkg_name")

    dest_dir = joinpath(VENDOR_DIR, pkg_name)

    if isdir(dest_dir)
        @info "Removing existing vendor directory: $dest_dir"
        rm(dest_dir; recursive=true)
    end

    @info "Copying $pkg_name from $src_dir to $dest_dir"
    cp(src_dir, dest_dir)

    for (root, _, files) in walkdir(dest_dir)
        for file in files
            filepath = joinpath(root, file)
            chmod(filepath, 0o644)
        end
    end

    return dest_dir
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

function remove_unused_weakdeps_and_extensions!(
        vendor_pkg_dir::AbstractString,
        loaded_uuids::Set{UUID},
        uuid_mapping::Dict{UUID,UUID})
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
        modified = true
    end

    if !isempty(weakdeps_to_keep)
        for name in weakdeps_to_keep
            original_uuid = UUID(weakdeps[name])
            if haskey(uuid_mapping, original_uuid)
                new_uuid = uuid_mapping[original_uuid]
                weakdeps[name] = string(new_uuid)
                @info "Updated weakdep UUID in $(basename(vendor_pkg_dir)): " *
                      "$name $original_uuid => $new_uuid"
                modified = true
            end
        end
    end

    if !isempty(extensions_to_remove)
        @info "Removing unused extensions from $(basename(vendor_pkg_dir)): " *
              "$extensions_to_remove"
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
        uuid_mapping::Dict{UUID,UUID},
        use_local_path::Bool,
        rev::Union{String,Nothing})
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
            @info "Updated dependency in $(basename(vendor_pkg_dir)): " *
                  "$dep_name $dep_uuid => $new_uuid"
            deps_updated = true
            push!(vendored_deps, dep_name)
        end
    end

    if !isempty(vendored_deps)
        if !haskey(project, "sources")
            project["sources"] = Dict{String,Any}()
        end

        if use_local_path
            for dep_name in vendored_deps
                project["sources"][dep_name] = Dict{String,Any}(
                    "path" => joinpath("..", dep_name)
                )
                @info "Added source entry in $(basename(vendor_pkg_dir)) for " *
                      "$dep_name with path"
            end
        else
            testrunner_url = "https://github.com/aviatesk/TestRunner.jl"
            for dep_name in vendored_deps
                project["sources"][dep_name] = Dict{String,Any}(
                    "url" => testrunner_url,
                    "subdir" => joinpath("vendor", dep_name),
                    "rev" => rev
                )
                @info "Added source entry in $(basename(vendor_pkg_dir)) for " *
                      "$dep_name with rev=$rev"
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

function update_project_with_vendored_deps(
        uuid_mapping::Dict{UUID,UUID},
        all_vendored_packages::Vector{Pair{String,UUID}},
        use_local_path::Bool,
        rev::Union{String,Nothing})
    project_path = joinpath(CURRENT_DIR, "Project.toml")
    project = TOML.parsefile(project_path)

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

    project["sources"] = Dict{String,Any}()

    if use_local_path
        for (pkg_name, original_uuid) in all_vendored_packages
            if haskey(uuid_mapping, original_uuid)
                project["sources"][pkg_name] = Dict{String,Any}(
                    "path" => joinpath("vendor", pkg_name)
                )
                @info "Added source entry for $pkg_name with path"
            end
        end
    else
        testrunner_url = "https://github.com/aviatesk/TestRunner.jl"
        for (pkg_name, original_uuid) in all_vendored_packages
            if haskey(uuid_mapping, original_uuid)
                new_source = Dict{String,Any}()
                new_source["url"] = testrunner_url
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
end

function fetch_project_from_branch(source_branch::AbstractString,
                                   project_path::AbstractString)::String
    result = read(`git show $(source_branch):$(project_path)`, String)
    return result
end

function clean_manifests()
    @info "Cleaning manifest files..."
    for file in readdir(CURRENT_DIR)
        if file == "Manifest.toml" ||
           startswith(file, "Manifest-v") && endswith(file, ".toml")
            manifest_path = joinpath(CURRENT_DIR, file)
            @info "Removing $manifest_path"
            rm(manifest_path)
        end
    end
end

function vendor_dependencies_from_branch(config::Config)
    @info "=== TestRunner Vendoring Script ==="
    @info "Source branch: $(config.source_branch)"
    @info "Use local path: $(config.use_local_path)"
    @info "Rev: $(something(config.rev, "(not set)"))"

    @info "\n[Step 1/5] Fetching Project.toml from $(config.source_branch)..."

    main_project = fetch_project_from_branch(config.source_branch, "Project.toml")
    main_path = joinpath(CURRENT_DIR, "Project.toml")
    write(main_path, main_project)
    @info "Fetched Project.toml from $(config.source_branch)"

    backup_path = main_path * ".bak"
    cp(main_path, backup_path; force=true)
    @info "Backed up Project.toml to $(basename(backup_path))"

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
    println("""
    scripts/vendor-deps.jl - TestRunner Dependency Vendoring Script

    USAGE:
        julia scripts/vendor-deps.jl --source-branch=<branch> [--local | --rev=<rev>]

    DESCRIPTION:
        Vendors all non-stdlib, non-JLL dependencies with rewritten UUIDs
        to avoid conflicts with packages in user environments.

    PROCESS:
        1. Fetch Project.toml from source branch
        2. Backup existing Project.toml (*.bak)
        3. Clean manifest files
        4. Update dependencies with Pkg.update()
        5. Vendor packages:
           - Copy package sources to vendor/ directory
           - Rewrite UUIDs deterministically
           - Remove unused weakdeps/extensions
           - Update inter-package references
        6. Replace Project.toml with vendored versions

    OPTIONS:
        --help, -h
            Show this help message and exit

        --source-branch=<branch>
            Branch to fetch Project.toml from (required)
            Example: --source-branch=master

        --local
            Use local path references in [sources].
            For local testing before committing vendor/.

        --rev=<rev>
            Git revision to use in [sources].
            For release builds after vendor/ is committed.

    EXAMPLE:
        # Local testing
        julia scripts/vendor-deps.jl --source-branch=master --local

        # After committing vendor/, update [sources] with commit SHA
        julia scripts/vendor-deps.jl --source-branch=master --rev=abc1234

    OUTPUT:
        vendor/         Vendored package sources with rewritten UUIDs
        Project.toml    Updated with vendored dependency UUIDs and [sources]
        *.bak           Backup of original Project.toml

    """)
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
        error("--source-branch argument is required\n" *
              "Run with --help for usage information")
    end

    if use_local_path && rev !== nothing
        error("--local and --rev are mutually exclusive\n" *
              "Run with --help for usage information")
    end

    if !use_local_path && rev === nothing
        error("Either --local or --rev must be specified\n" *
              "Run with --help for usage information")
    end

    return Config(source_branch, use_local_path, rev)
end

function vendor_loaded_packages(use_local_path::Bool, rev::Union{String,Nothing})
    @info "Loading TestRunner to populate Base.loaded_modules..."
    @eval using TestRunner

    @info "Identifying packages to vendor..."
    packages = collect_packages_to_vendor()
    @info "Found $(length(packages)) packages to vendor:"
    for (name, uuid) in packages
        println("  $name => $uuid")
    end

    remove_stale_vendor_packages!(VENDOR_DIR, packages)
    mkpath(VENDOR_DIR)

    uuid_mapping = Dict{UUID,UUID}()

    @info "Step 1: Copying packages and rewriting UUIDs..."
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
    end

    @info "Step 2: Removing unused weakdeps and extensions..."
    loaded_uuids = collect_loaded_package_uuids()
    for (pkg_name, _) in packages
        vendor_pkg_dir = joinpath(VENDOR_DIR, pkg_name)
        remove_unused_weakdeps_and_extensions!(vendor_pkg_dir, loaded_uuids, uuid_mapping)
    end

    @info "Step 3: Updating inter-package dependencies..."
    for (pkg_name, _) in packages
        vendor_pkg_dir = joinpath(VENDOR_DIR, pkg_name)
        update_vendored_dependencies!(vendor_pkg_dir, uuid_mapping, use_local_path, rev)
    end

    @info "Step 4: Updating Project.toml with vendored dependencies..."
    update_project_with_vendored_deps(uuid_mapping, packages, use_local_path, rev)

    @info "Step 5: Tidying up Project.toml format..."
    project_path = joinpath(CURRENT_DIR, "Project.toml")
    project = Pkg.Types.read_project(project_path)
    Pkg.Types.write_project(project, project_path)

    @info "Vendor isolation complete!"
    @info "Vendored packages are in: $VENDOR_DIR"
end

function (@main)(args::Vector{String})
    vendor_dependencies_from_branch(parse_args(args))
end
