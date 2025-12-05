function find_loaded_module(module_name::String)
    for (pkgid, mod) in Base.loaded_modules
        if pkgid.name == module_name
            return mod
        end
    end
    return nothing
end

function find_analysis_env_path(state::ServerState, uri::URI)
    if uri.scheme == "file"
        filepath = uri2filepath(uri)::String
        # HACK: we should support Base files properly
        if (issubdir(filepath, normpath(Sys.BUILD_ROOT_PATH, "base")) ||
            issubdir(filepath, normpath(Sys.BINDIR, "..", "share", "julia", "base")))
            return OutOfScope(Base)
        elseif (issubdir(filepath, normpath(Sys.BUILD_ROOT_PATH, "Compiler", "src")) ||
                issubdir(filepath, normpath(Sys.BINDIR, "..", "share", "julia", "Compiler", "src")))
            return OutOfScope(CC)
        end
        if isdefined(state, :root_path)
            if !issubdir(dirname(filepath), state.root_path)
                return OutOfScope()
            end
        end
        module_overrides = state.init_options.module_overrides
        if module_overrides !== nothing
            if isdefined(state, :root_path) && startswith(filepath, state.root_path)
                path_for_glob = relpath(filepath, state.root_path)
            else
                path_for_glob = filepath
            end
            for override in module_overrides
                if occursin(override.path, path_for_glob)
                    mod = find_loaded_module(override.module_name)
                    if mod !== nothing
                        JETLS_DEV_MODE && @info "Analysis module overridden" module_name=override.module_name path=filepath
                        return OutOfScope(mod)
                    else
                        @warn "Analysis module override specified but module not loaded" module_name=override.module_name path=filepath
                    end
                end
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

const PKG_ACTIVATION_LOCK = ReentrantLock()

"""
    activate_do(func, env_path::String)

Temporarily activate the environment at `env_path`, execute `func`, and restore the
previous environment. Uses a global lock to prevent concurrent environment switching.
"""
function activate_do(func, env_path::String)
    lock(PKG_ACTIVATION_LOCK)
    old_env = Pkg.project().path
    try
        Pkg.activate(env_path; io=devnull)
        return func()
    finally
        Pkg.activate(old_env; io=devnull)
        unlock(PKG_ACTIVATION_LOCK)
    end
end

"""
    activate_with_early_release(func, env_path::String)

Temporarily activate the environment at `env_path` and execute `func(activation_done)`.
Unlike [`activate_do`](@ref), this allows early release of `PKG_ACTIVATION_LOCK` before `func`
completes: the caller can `notify(activation_done)` to signal that the activated environment
is no longer needed, allowing the environment to be restored and the lock released while
`func` continues executing. `func` is allowed to return without notifying, in which case
the event is automatically notified in the `finally` block.
"""
function activate_with_early_release(func, env_path::String)
    activation_done = Base.Event()
    lock(PKG_ACTIVATION_LOCK)
    old_env = Pkg.project().path
    Pkg.activate(env_path; io=devnull)
    t = Threads.@spawn try
        func(activation_done)
    finally
        notify(activation_done)
    end
    wait(activation_done)
    Pkg.activate(old_env; io=devnull)
    unlock(PKG_ACTIVATION_LOCK)
    return fetch(t)
end

function find_package_directory(path::String, env_path::String)
    env_dir = dirname(env_path)
    src_dir = joinpath(env_dir, "src")
    test_dir = joinpath(env_dir, "test")
    docs_dir = joinpath(env_dir, "docs")
    ext_dir = joinpath(env_dir, "ext")
    dir = dirname(path)
    while dir != env_dir
        dir == src_dir && return :src, src_dir
        dir == test_dir && return :test, test_dir
        dir == docs_dir && return :docs, docs_dir
        dir == ext_dir && return :ext, ext_dir
        dir = dirname(dir)
    end
    return :script, path
end
