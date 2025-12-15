function find_loaded_module(module_name::String)
    for (pkgid, mod) in Base.loaded_modules
        if pkgid.name == module_name
            return mod
        end
    end
    return nothing
end

const JULIA_DIR = let
    p1 = normpath(Sys.BINDIR, "..", "..")
    p2 = normpath(Sys.BINDIR, Base.DATAROOTDIR, "julia")
    ispath(normpath(p1, "base")) ? p1 : p2
end

function find_analysis_env_path(state::ServerState, uri::URI)
    if uri.scheme == "file"
        filepath = uri2filepath(uri)::String
        analysis_overrides = state.init_options.analysis_overrides
        if analysis_overrides !== nothing
            if isdefined(state, :root_path) && startswith(filepath, state.root_path)
                path_for_glob = relpath(filepath, state.root_path)
            else
                path_for_glob = filepath
            end
            for override in analysis_overrides
                if occursin(override.path, path_for_glob)
                    module_name = override.module_name
                    if module_name === nothing
                        JETLS_DEV_MODE && @info "Analysis for this file is disabled" path=filepath
                        return OutOfScope()
                    elseif module_name == ""
                        env_path = @something find_env_path(filepath) begin
                            @warn "Analysis for this file is disabled, since Project.toml was not found" path=filepath
                            return OutOfScope()
                        end
                        pkg_name = @something find_pkg_name(env_path) begin
                            @warn "New analysis is not supported for non-package code" path=filepath
                            return OutOfScope()
                        end
                        pkg_uuid = @something find_pkg_uuid(env_path) begin
                            @warn "New analysis is not supported for non-package code" path=filepath
                            return OutOfScope()
                        end
                        return UserModule(env_path, pkg_name, pkg_uuid)
                    else
                        mod = @something find_loaded_module(module_name) begin
                            @warn "Analysis module override specified but module not found" module_name path=filepath
                            return OutOfScope()
                        end
                        JETLS_DEV_MODE && @info "Analysis module overridden" module_name path=filepath
                        return KnownModule(mod)
                    end
                end
            end
        end
        # HACK: we should support Base files properly
        if issubdir(filepath, joinpath(JULIA_DIR, "base"))
            return OutOfScope(Base)
        elseif issubdir(filepath, joinpath(JULIA_DIR, "Compiler", "src"))
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

find_pkg_name(env_path::AbstractString) =
    find_pkg_name(@something parse_project_toml(env_path) return nothing)

function find_pkg_name(project_toml_dict::Dict{String})
    pkg_name = get(project_toml_dict, "name", nothing)
    return pkg_name isa String ? pkg_name : nothing
end

find_pkg_uuid(env_path::AbstractString) =
    find_pkg_uuid(@something parse_project_toml(env_path) return nothing)

function find_pkg_uuid(project_toml_dict::Dict{String})
    pkg_uuid = get(project_toml_dict, "uuid", nothing)
    return pkg_uuid isa String ? pkg_uuid : nothing
end

function parse_project_toml(env_path::AbstractString)
    try
        return TOML.parsefile(env_path)
    catch err
        err isa TOML.ParserError || rethrow(err)
        return nothing
    end
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
