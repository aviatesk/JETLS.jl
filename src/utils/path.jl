find_env_path(path::AbstractString) = search_up_file(path, "Project.toml")

function search_up_file(path::AbstractString, basename::AbstractString)
    startpath = isdir(path) ? path : dirname(path)
    traverse_dir(startpath) do dir
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

"""
    issubdir(dir1::AbstractString, dir2::AbstractString) -> Bool

Return whether `dir1` is lexically equal to or contained within `dir2`. Both paths must
be absolute or both relative; mixed paths return `false`. Comparisons are case-insensitive
on Windows. This function does not access the file system or resolve symbolic links.
"""
function issubdir(dir1::AbstractString, dir2::AbstractString)
    return _matching_path_ancestor(dir1, dir2) !== nothing
end

"""
    glob_candidate_path(
            filepath::AbstractString, root_path::Union{Nothing,AbstractString}
        ) -> String

Return a normalized path suitable for matching with `Glob.FilenameMatch`. When `filepath`
is contained by `root_path`, return a path relative to that root. On Windows, use `/` as
the path separator expected by Glob path matching.
"""
function glob_candidate_path(filepath::AbstractString, root_path::Union{Nothing,AbstractString})
    filepath = _normalize_path(filepath)
    if root_path !== nothing
        root = _matching_path_ancestor(filepath, root_path)
        if root !== nothing
            filepath = relpath(filepath, root)
        end
    end
    @static if Sys.iswindows()
        filepath = replace(filepath, '\\' => '/')
    end
    return filepath
end

# Return the ancestor of `path` that lexically matches `root`, or `nothing` when
# `path` is outside `root`. Both paths must either be absolute or relative. On
# Windows, comparison is case-insensitive, while the returned ancestor preserves
# its spelling from `path` so it can be passed safely to `relpath`.
function _matching_path_ancestor(path::AbstractString, root::AbstractString)
    path = _normalize_path(path)
    root = _normalize_path(root)
    isabspath(path) == isabspath(root) || return nothing
    return traverse_dir(path) do candidate
        return _paths_equal(candidate, root) ? candidate : nothing
    end
end

function _normalize_path(path::AbstractString)
    path = normpath(path)
    dir, name = splitdir(path)
    return isempty(name) && dir != path ? dir : path
end

_paths_equal(a::AbstractString, b::AbstractString) =
    @static Sys.iswindows() ? lowercase(a) == lowercase(b) : a == b

function escape_path_for_glob(path::AbstractString)
    io = IOBuffer()
    for c in glob_candidate_path(path, nothing)
        c in ('\\', '*', '?', '[', ']') && write(io, '\\')
        write(io, c)
    end
    return String(take!(io))
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
