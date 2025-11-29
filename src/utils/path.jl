find_env_path(path::AbstractString) = search_up_file(path, "Project.toml")

function search_up_file(path::AbstractString, basename::AbstractString)
    traverse_dir(dirname(path)) do dir
        project_file = joinpath(dir, basename)
        if isfile(project_file)
            return project_file
        end
        return nothing
    end
end

function traverse_dir(f, dir::AbstractString)
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
function issubdir(dir1::AbstractString, dir2::AbstractString)
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
begin
    local build_dir, share_path, build_path
    global fix_build_path
    build_dir = normpath(Sys.BINDIR, "..", "..") # with path separator at the end
    share_path = normpath(Sys.BINDIR, Base.DATAROOTDIR, "julia") # without path separator at the end
    if ispath(normpath(build_dir), "base")
        build_path = splitdir(build_dir)[1] # remove the path separator
        fix_build_path(path::AbstractString) = replace(path, share_path => build_path)
    else
        fix_build_path(path::AbstractString) = path
    end
end

"""
    to_full_path(file::AbstractString) -> String
    to_full_path(file::Symbol) -> String

Convert a file path to its full, normalized form suitable for the language server.

This function:
1. Attempts to find the actual source file location, i.e. converts Base function paths
   retrieved with `methods` to absolute path
2. Applies `fix_build_path` to convert from Julia's share directory to build directory if applicable
3. Returns a normalized absolute path

# Arguments
- `file`: An absolute file path (preferred), though the function can handle relative paths,
  stdlib paths, and symbols that may be retrieved with Julia's internal APIs

# Notes
- While the function can handle relative paths, callers should provide absolute paths when possible
- For built Julia installations, paths under `/usr/share/julia` are converted to their
  corresponding paths in the build directory
- The function always returns an absolute path
"""
to_full_path(file::Symbol) = to_full_path(String(file))
function to_full_path(file::AbstractString)
    file = Base.fixup_stdlib_path(file)
    file = something(Base.find_source_file(file), file)
    # TODO we should probably make this configurable
    return fix_build_path(abspath(file))
end
