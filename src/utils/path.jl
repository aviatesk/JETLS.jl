find_env_path(path) = search_up_file(path, "Project.toml")

function search_up_file(path, basename)
    traverse_dir(dirname(path)) do dir
        project_file = joinpath(dir, basename)
        if isfile(project_file)
            return project_file
        end
        return nothing
    end
end

function traverse_dir(f, dir)
    while !isempty(dir)
        res = f(dir)
        if res !== nothing
            return res
        end
        parent = dirname(dir)
        if parent == dir
            break
        end
        dir = parent
    end
    return nothing
end

# check if `dir1` is a subdirectory of `dir2`
function issubdir(dir1, dir2)
    dir1 = rstrip(dir1, '/')
    dir2 = rstrip(dir2, '/')
    something(traverse_dir(dir1) do dir
        if dir == dir2
            return true
        end
        return nothing
    end, false)
end

"""
    fix_build_path(path::AbstractString) -> fixed_path::AbstractString

If this Julia is a built one, convert `path` to `fixed_path`, which is a path to the main
files that are editable (or tracked by git).
"""
function fix_build_path end
let build_dir = normpath(Sys.BINDIR, "..", ".."),
    share_dir = normpath(Sys.BINDIR, Base.DATAROOTDIR, "julia")
    global fix_build_path
    if ispath(normpath(build_dir), "base")
        fix_build_path(path::AbstractString) = replace(path, share_dir => build_dir)
    else
        fix_build_path(path::AbstractString) = path
    end
end

to_full_path(file::Symbol) = to_full_path(String(file))
function to_full_path(file::AbstractString)
    file = Base.fixup_stdlib_path(file)
    file = something(Base.find_source_file(file), file)
    # TODO we should probably make this configurable
    return fix_build_path(abspath(file))
end
