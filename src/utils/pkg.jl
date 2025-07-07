function find_analysis_env_path(state::ServerState, uri::URI)
    if uri.scheme == "file"
        filepath = uri2filepath(uri)::String
        # HACK: we should support Base files properly
        if issubdir(filepath, normpath(Sys.BUILD_ROOT_PATH, "base"))
            return OutOfScope(Base)
        elseif issubdir(filepath, normpath(Sys.BUILD_ROOT_PATH, "Compiler", "src"))
            return OutOfScope(CC)
        end
        if isdefined(state, :root_path)
            if !issubdir(dirname(filepath), state.root_path)
                return OutOfScope()
            end
        end
        return find_env_path(filepath)
    elseif uri.scheme == "untitled"
        # try to analyze untitled editors using the root environment
        return isdefined(state, :root_env_path) ? state.root_env_path : nothing
    end
    error(lazy"Unsupported URI: $uri")
end

function find_uri_env_path(state::ServerState, uri::URI)
    if uri.scheme == "file"
        filepath = uri2filepath(uri)::String
        return find_env_path(filepath)
    elseif uri.scheme == "untitled"
        # try to analyze untitled editors using the root environment
        return isdefined(state, :root_env_path) ? state.root_env_path : nothing
    end
    error(lazy"Unsupported URI: $uri")
end

function find_pkg_name(env_path::AbstractString)
    env_toml = try
        Pkg.TOML.parsefile(env_path)
    catch err
        err isa Base.TOML.ParseError || rethrow(err)
        return nothing
    end
    pkg_name = get(env_toml, "name", nothing)
    return pkg_name isa String ? pkg_name : nothing
end

function activate_do(func, env_path::String)
    old_env = Pkg.project().path
    try
        Pkg.activate(env_path; io=devnull)
        func()
    finally
        Pkg.activate(old_env; io=devnull)
    end
end

function find_package_directory(path::String, env_path::String)
    dir = dirname(path)
    env_dir = dirname(env_path)
    src_dir = joinpath(env_dir, "src")
    test_dir = joinpath(env_dir, "test")
    docs_dir = joinpath(env_dir, "docs")
    ext_dir = joinpath(env_dir, "ext")
    while dir != env_dir
        dir == src_dir && return :src, src_dir
        dir == test_dir && return :test, test_dir
        dir == docs_dir && return :docs, docs_dir
        dir == ext_dir && return :ext, ext_dir
        dir = dirname(dir)
    end
    return :script, path
end
