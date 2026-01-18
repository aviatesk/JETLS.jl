"""
JETLS plugin system
===================

JETLS is built on JET's analysis framework and already uses JET's internal plugin system,
but historically it has not provided an officially supported way for *users* to extend the
analysis/diagnostics pipeline.

This file defines a small, server-side plugin interface that can be enabled via the
existing LSP configuration mechanism (e.g. VSCode's `settings.json`).

The intended workflow is:
1. A user configures `jetls-client.settings.plugins` with package names (and optionally
   UUIDs).
2. JETLS loads those packages in the analysis environment.
3. Loaded packages register plugin instances via [`register_plugin!`](@ref).
4. JETLS calls plugin hooks to customize analysis configuration and diagnostics.

The interface is intentionally narrow and focused on LSP diagnostics.
"""

# Plugin interface
# ----------------

"""Base type for JETLS plugins."""
abstract type AbstractJETLSPlugin end

"""Unwrap nested `LoadError`s to reach the underlying exception."""
function unwrap_loaderror(@nospecialize(err))
    while err isa LoadError
        err = err.error
    end
    return err
end

"""Register an additional diagnostic code so users can configure it via patterns."""
register_diagnostic_code!(code::AbstractString) = push!(ALL_DIAGNOSTIC_CODES, String(code))

const _PLUGIN_REGISTRY_LOCK = ReentrantLock()
const _PLUGIN_REGISTRY = Dict{Base.PkgId, Vector{AbstractJETLSPlugin}}()

function _plugin_owner_pkgid(plugin::AbstractJETLSPlugin, owner)
    if owner isa Base.PkgId
        return owner
    elseif owner isa Module
        try
            return Base.PkgId(owner)
        catch
            return Base.PkgId(nothing, String(nameof(owner)))
        end
    elseif owner === nothing
        mod = parentmodule(typeof(plugin))
        try
            return Base.PkgId(mod)
        catch
            return Base.PkgId(nothing, String(nameof(mod)))
        end
    else
        throw(ArgumentError("Invalid `owner` argument for register_plugin!: $(typeof(owner))"))
    end
end

"""
    register_plugin!(plugin::AbstractJETLSPlugin; owner=nothing) -> plugin

Registers a plugin instance.

`owner` is used to associate the plugin instance with a package, so that enabling/disabling
plugins via the LSP configuration can be implemented as a pure filter step.

- If `owner` is omitted, JETLS will attempt to infer it from `parentmodule(typeof(plugin))`.
- If `owner` is a `Module`, it will be converted to a `Base.PkgId`.
- If `owner` is a `Base.PkgId`, it will be used directly.

Downstream packages are encouraged to register plugins from a package extension
(`ext/*.jl`) so that registration only happens when both the plugin package and JETLS are
loaded.
"""
function register_plugin!(plugin::AbstractJETLSPlugin; owner=nothing)
    pkgid = _plugin_owner_pkgid(plugin, owner)
    @lock _PLUGIN_REGISTRY_LOCK begin
        plugins = get!(_PLUGIN_REGISTRY, pkgid) do
            AbstractJETLSPlugin[]
        end
        any(p -> p === plugin, plugins) || push!(plugins, plugin)
    end
    return plugin
end

function _registered_plugins_for_pkgid(pkgid::Base.PkgId)
    @lock _PLUGIN_REGISTRY_LOCK begin
        return get(_PLUGIN_REGISTRY, pkgid, AbstractJETLSPlugin[])
    end
end

# Plugin hooks
# ------------

"""Allow a plugin to tweak JET configurations before running analysis."""
plugin_modify_jetconfigs!(::AbstractJETLSPlugin, ::AnalysisEntry, ::Dict{Symbol,Any}) = nothing

"""Allow a plugin to treat a report as "displayable" for additional URIs."""
plugin_additional_report_uris(::AbstractJETLSPlugin, ::JET.InferenceErrorReport) = URI[]

"""Override report stack used for diagnostic locations/related information."""
plugin_inference_error_report_stack(::AbstractJETLSPlugin, ::JET.InferenceErrorReport) = nothing

"""Override severity of an inference report."""
plugin_inference_error_report_severity(::AbstractJETLSPlugin, ::JET.InferenceErrorReport) = nothing

"""Override diagnostic code associated with an inference report."""
plugin_inference_error_report_code(::AbstractJETLSPlugin, ::JET.InferenceErrorReport) = nothing

"""
    plugin_expand_inference_error_report!(plugin, uri2diagnostics, report, postprocessor) -> Bool

If this hook returns `true`, the plugin has fully handled `report` and the default
JETLS expansion should be skipped.
"""
plugin_expand_inference_error_report!(::AbstractJETLSPlugin, ::URI2Diagnostics, ::JET.InferenceErrorReport, ::JET.PostProcessor) = false


# Plugin configuration parsing
# ----------------------------

struct PluginConfigError <: Exception
    msg::AbstractString
end
Base.showerror(io::IO, e::PluginConfigError) = print(io, "PluginConfigError: ", e.msg)

function parse_plugin_spec(x::AbstractDict{String})
    for key in keys(x)
        if key ∉ ("name", "uuid", "version", "url", "path", "subdir", "rev", "mode", "level", "entry", "entries", "enabled")
            throw(PluginConfigError(
                lazy"Unknown field \"$key\" in plugin spec. Valid fields are: name, uuid, version, url, path, subdir, rev, entry, enabled"))
        end
    end

    name = get(x, "name", nothing)
    name isa String || throw(PluginConfigError(lazy"Missing or invalid `name` in plugin spec"))
    isempty(name) && throw(PluginConfigError("Plugin `name` must not be empty"))

    uuid = get(x, "uuid", nothing)
    uuid_parsed = if uuid === nothing
        nothing
    elseif uuid isa String
        isempty(uuid) ? nothing : try
            Base.UUID(uuid)
        catch
            throw(PluginConfigError(lazy"Invalid `uuid` value for plugin \"$name\": $uuid"))
        end
    else
        throw(PluginConfigError(lazy"Invalid `uuid` value for plugin \"$name\". Must be a UUID string"))
    end

    version = get(x, "version", nothing)
    version_parsed = if version === nothing
        nothing
    elseif version isa String
        isempty(version) ? nothing : try
            VersionNumber(version)
        catch
            throw(PluginConfigError(lazy"Invalid `version` value for plugin \"$name\": $version"))
        end
    else
        throw(PluginConfigError(lazy"Invalid `version` value for plugin \"$name\". Must be a version string"))
    end

    url = get(x, "url", nothing)
    url_parsed = if url === nothing
        nothing
    elseif url isa String
        isempty(url) ? nothing : url
    else
        throw(PluginConfigError(lazy"Invalid `url` value for plugin \"$name\". Must be a string"))
    end

    path = get(x, "path", nothing)
    path_parsed = if path === nothing
        nothing
    elseif path isa String
        isempty(path) ? nothing : path
    else
        throw(PluginConfigError(lazy"Invalid `path` value for plugin \"$name\". Must be a string"))
    end

    subdir = get(x, "subdir", nothing)
    subdir_parsed = if subdir === nothing
        nothing
    elseif subdir isa String
        isempty(subdir) ? nothing : subdir
    else
        throw(PluginConfigError(lazy"Invalid `subdir` value for plugin \"$name\". Must be a string"))
    end

    rev = get(x, "rev", nothing)
    rev_parsed = if rev === nothing
        nothing
    elseif rev isa String
        isempty(rev) ? nothing : rev
    else
        throw(PluginConfigError(lazy"Invalid `rev` value for plugin \"$name\". Must be a string"))
    end

    entry_value = get(x, "entry", get(x, "entries", nothing))
    entry = if entry_value === nothing
        String[]
    elseif entry_value isa String
        String[entry_value]
    elseif entry_value isa AbstractVector
        entries = String[]
        for v in entry_value
            v isa String || throw(PluginConfigError(lazy"Invalid `entry` value for plugin \"$name\". Expected strings"))
            push!(entries, v)
        end
        entries
    else
        throw(PluginConfigError(lazy"Invalid `entry` value for plugin \"$name\". Must be a string or list of strings"))
    end

    enabled = get(x, "enabled", true)
    enabled isa Bool || throw(PluginConfigError(lazy"Invalid `enabled` value for plugin \"$name\". Must be a boolean"))

    return PluginSpec(
        name,
        uuid_parsed,
        version_parsed,
        url_parsed,
        path_parsed,
        subdir_parsed,
        rev_parsed,
        entry,
        enabled,
    )
end


# Plugin loading / activation
# ---------------------------

const _PLUGIN_LOAD_ERROR_ONCE_LOCK = ReentrantLock()
const _PLUGIN_LOAD_ERROR_ONCE = Set{Tuple{UInt,String}}() # (server_state_id, plugin_name)
const _PLUGIN_PKG_OP_LOCK = ReentrantLock()

function _maybe_show_plugin_load_error!(server::Server, plugin_name::String, msg::String)
    sid = objectid(server.state)
    key = (sid, plugin_name)
    show = false
    @lock _PLUGIN_LOAD_ERROR_ONCE_LOCK begin
        if key ∉ _PLUGIN_LOAD_ERROR_ONCE
            push!(_PLUGIN_LOAD_ERROR_ONCE, key)
            show = true
        end
    end
    show || return nothing
    try
        show_error_message(server, msg)
    catch
        # ignore notification errors in early init/tests
    end
    return nothing
end

function _server_root_path(server::Server)
    if isdefined(server.state, :root_path)
        root_path = server.state.root_path
        isempty(root_path) && return nothing
        return root_path
    end
    return nothing
end

function _resolve_plugin_path(server::Server, path::String)
    isabspath(path) && return path
    root_path = _server_root_path(server)
    root_path === nothing && return abspath(path)
    return abspath(joinpath(root_path, path))
end

function _plugin_packagespec(server::Server, spec::PluginSpec)
    kwargs = Pair{Symbol,Any}[]
    push!(kwargs, :name => spec.name)
    spec.uuid === nothing || push!(kwargs, :uuid => spec.uuid)
    spec.version === nothing || push!(kwargs, :version => spec.version)
    spec.url === nothing || push!(kwargs, :url => spec.url)
    if spec.path !== nothing
        push!(kwargs, :path => _resolve_plugin_path(server, spec.path))
    end
    spec.subdir === nothing || push!(kwargs, :subdir => spec.subdir)
    spec.rev === nothing || push!(kwargs, :rev => spec.rev)
    return Pkg.PackageSpec(; kwargs...)
end

function _plugin_has_pkg_spec(spec::PluginSpec)
    return spec.uuid !== nothing ||
        spec.version !== nothing ||
        spec.url !== nothing ||
        spec.path !== nothing ||
        spec.subdir !== nothing ||
        spec.rev !== nothing
end

"""Resolve a `PluginSpec` to a concrete `Base.PkgId`, if possible."""
function _resolve_plugin_pkgid(spec::PluginSpec)
    if spec.uuid !== nothing
        return Base.PkgId(spec.uuid, spec.name)
    end
    pkgenv = @lock Base.require_lock Base.identify_package_env(spec.name)
    pkgenv === nothing && return nothing
    pkgid, _ = pkgenv
    return pkgid
end

function _require_plugin_package(server::Server, spec::PluginSpec)
    @lock _PLUGIN_PKG_OP_LOCK begin
        if _plugin_has_pkg_spec(spec) && (
                spec.path !== nothing ||
                spec.url !== nothing ||
                spec.version !== nothing ||
                spec.subdir !== nothing ||
                spec.rev !== nothing
            )
            pspec = _plugin_packagespec(server, spec)
            try
                if spec.path !== nothing
                    Pkg.develop(pspec)
                else
                    Pkg.add(pspec)
                end
            catch err
                msg = "Failed to install plugin package $(spec.name): $(sprint(Base.showerror, err))"
                _maybe_show_plugin_load_error!(server, spec.name, msg)
                @warn msg exception=(err, catch_backtrace())
                return nothing
            end
        end

        pkgid = _resolve_plugin_pkgid(spec)
        pkgid === nothing && return nothing
        try
            Base.require(pkgid)
        catch err
            # If the user provided a package spec but the package isn't installed yet, try once.
            if _plugin_has_pkg_spec(spec)
                pspec = _plugin_packagespec(server, spec)
                try
                    if spec.path !== nothing
                        Pkg.develop(pspec)
                    else
                        Pkg.add(pspec)
                    end
                    Base.require(pkgid)
                    return pkgid
                catch err2
                    msg = "Failed to load plugin package $(spec.name): $(sprint(Base.showerror, err2))"
                    _maybe_show_plugin_load_error!(server, spec.name, msg)
                    @warn msg exception=(err2, catch_backtrace())
                    return nothing
                end
            end

            msg = "Failed to load plugin package $(spec.name): $(sprint(Base.showerror, err))"
            _maybe_show_plugin_load_error!(server, spec.name, msg)
            @warn msg exception=(err, catch_backtrace())
            return nothing
        end
        return pkgid
    end
end

function _plugins_from_entrypoints(mod::Module, spec::PluginSpec)
    isempty(spec.entry) && return AbstractJETLSPlugin[]
    plugins = AbstractJETLSPlugin[]
    for entry in spec.entry
        sym = Symbol(entry)
        isdefined(mod, sym) || begin
            @warn "JETLS plugin entry not found" plugin=spec.name entry
            continue
        end
        obj = getfield(mod, sym)
        if obj isa AbstractJETLSPlugin
            push!(plugins, obj)
        elseif obj isa Function
            val = obj()
            if val isa AbstractJETLSPlugin
                push!(plugins, val)
            elseif val isa AbstractVector
                for p in val
                    p isa AbstractJETLSPlugin || continue
                    push!(plugins, p)
                end
            elseif val === nothing
                # allow entry points that register plugins via `register_plugin!`
            else
                @warn "JETLS plugin entry returned unexpected value" plugin=spec.name entry returned=typeof(val)
            end
        else
            @warn "JETLS plugin entry has unexpected type" plugin=spec.name entry ty=typeof(obj)
        end
    end
    return plugins
end

const _ACTIVE_PLUGIN_CACHE_LOCK = ReentrantLock()
const _ACTIVE_PLUGIN_CACHE = Dict{UInt, Dict{String, Tuple{UInt, Vector{AbstractJETLSPlugin}}}}()

function _plugin_env_key(@nospecialize(entry::AnalysisEntry))
    if hasproperty(entry, :env_path)
        env_path = getproperty(entry, :env_path)
        env_path isa String && return env_path
    end
    return "__noenv__"
end

"""Return currently active plugins for the given analysis entry."""
function active_plugins(server::Server, entry::AnalysisEntry)
    specs = get_config(server.state.config_manager, :plugins)
    isempty(specs) && return AbstractJETLSPlugin[]
    specs = filter(spec -> spec.enabled, specs)
    isempty(specs) && return AbstractJETLSPlugin[]

    env_key = _plugin_env_key(entry)
    sig = hash(specs, UInt(0))
    sid = objectid(server.state)

    cached = nothing
    @lock _ACTIVE_PLUGIN_CACHE_LOCK begin
        env_cache = get!(_ACTIVE_PLUGIN_CACHE, sid) do
            Dict{String, Tuple{UInt, Vector{AbstractJETLSPlugin}}}()
        end
        cached = get(env_cache, env_key, nothing)
        if cached !== nothing && first(cached) == sig
            return last(cached)
        end
    end

    # Cache miss (or changed settings) – build a fresh active plugin list.
    plugins = AbstractJETLSPlugin[]
    for spec in specs
        pkgid = _require_plugin_package(server, spec)
        pkgid === nothing && continue
        mod = get(Base.loaded_modules, pkgid, nothing)
        mod === nothing && continue

        entry_plugins = _plugins_from_entrypoints(mod, spec)
        if !isempty(entry_plugins)
            append!(plugins, entry_plugins)
        else
            # Default behavior: use plugins registered by the package.
            append!(plugins, _registered_plugins_for_pkgid(pkgid))
        end
    end

    # Deduplicate by identity (plugins are usually singleton objects).
    unique_plugins = AbstractJETLSPlugin[]
    for p in plugins
        any(q -> q === p, unique_plugins) || push!(unique_plugins, p)
    end

    @lock _ACTIVE_PLUGIN_CACHE_LOCK begin
        env_cache = get!(_ACTIVE_PLUGIN_CACHE, sid) do
            Dict{String, Tuple{UInt, Vector{AbstractJETLSPlugin}}}()
        end
        env_cache[env_key] = (sig, unique_plugins)
    end

    return unique_plugins
end
