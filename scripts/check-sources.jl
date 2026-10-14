#!/usr/bin/env julia

# Checks the `[sources]` of the projects in this workspace, which declare some of them in
# multiple projects: when Pkg merges the `[sources]` of a package across the workspace, it
# keeps those of the first project it visits, in an order that depends on the checkout path,
# and drops the `subdir` of the others. So the declarations of a package must agree, and
# every project that depends on a package with a `subdir` source must declare it as well.

using TOML

const Declarations = Vector{Pair{String,Dict{String,Any}}}

function collect_project_files!(project_files::Vector{String}, project_file::String)
    push!(project_files, project_file)
    workspace = get(TOML.parsefile(project_file), "workspace", Dict{String,Any}())
    for member in get(workspace, "projects", String[])
        member_file = joinpath(dirname(project_file), member, "Project.toml")
        isfile(member_file) && collect_project_files!(project_files, member_file)
    end
    return project_files
end

function normalize_source(root_dir::String, file::String, source::Dict{String,Any})
    haskey(source, "path") || return source
    path = relpath(normpath(root_dir, dirname(file), source["path"]), root_dir)
    return merge(source, Dict{String,Any}("path" => path))
end

function show_source(source::Dict{String,Any})
    entries = ("$key = $(repr(source[key]))" for key in sort!(collect(keys(source))))
    return "{" * join(entries, ", ") * "}"
end

function check_sources(root_dir::String)
    projects = Dict{String,Dict{String,Any}}(
        relpath(file, root_dir) => TOML.parsefile(file)
        for file in collect_project_files!(String[], joinpath(root_dir, "Project.toml")))
    declarations = Dict{String,Declarations}()
    for (file, project) in projects
        for (name, source) in get(project, "sources", Dict{String,Any}())
            push!(get!(Declarations, declarations, name),
                file => normalize_source(root_dir, file, source))
        end
    end
    errors = String[]
    for (name, decls) in sort!(collect(declarations); by=first)
        if !allequal(last.(decls))
            lines = (
                "  $file: $(show_source(source))" for (file, source) in sort(decls; by=first))
            push!(errors, "Conflicting `[sources]` of $name:\n" * join(lines, '\n'))
        end
        any(((_, source),) -> haskey(source, "subdir"), decls) || continue
        for (file, project) in sort!(collect(projects); by=first)
            haskey(get(project, "deps", Dict{String,Any}()), name) || continue
            file in first.(decls) && continue
            push!(errors, "$file depends on $name without declaring its `[sources]`, " *
                "which has a `subdir`")
        end
    end
    return errors
end

function (@main)(::Vector{String})
    errors = check_sources(dirname(@__DIR__))
    foreach(error -> println(stderr, error), errors)
    isempty(errors) || return 1
    println("The `[sources]` of the workspace projects are consistent")
    return 0
end
