module Interpreter

export LSInterpreter

using JuliaSyntax: JuliaSyntax as JS
using JET: CC, JET
using ..JETLS:
    AnalysisEntry, FullAnalysisInfo, SavedFileInfo, Server,
    JETLS_DEV_MODE, get_saved_file_info, yield_to_endpoint, send
using ..JETLS.URIs2
using ..JETLS.LSP
using ..JETLS.Analyzer

mutable struct Counter
    count::Int
end
Counter() = Counter(0)
increment!(counter::Counter) = counter.count += 1
Base.getindex(counter::Counter) = counter.count

struct LSInterpreter{S<:Server, I<:FullAnalysisInfo} <: JET.ConcreteInterpreter
    server::S
    info::I
    analyzer::LSAnalyzer
    counter::Counter
    state::JET.InterpretationState
    function LSInterpreter(server::S, info::I, analyzer::LSAnalyzer, counter::Counter) where S<:Server where I<:FullAnalysisInfo
        return new{S,I}(server, info, analyzer, counter)
    end
    function LSInterpreter(server::S, info::I, analyzer::LSAnalyzer, counter::Counter, state::JET.InterpretationState) where S<:Server where I<:FullAnalysisInfo
        return new{S,I}(server, info, analyzer, counter, state)
    end
end

# The main constructor
LSInterpreter(server::Server, info::FullAnalysisInfo) = LSInterpreter(server, info, LSAnalyzer(info.entry), Counter())

# `JET.ConcreteInterpreter` interface
JET.InterpretationState(interp::LSInterpreter) = interp.state
function JET.ConcreteInterpreter(interp::LSInterpreter, state::JET.InterpretationState)
    # add `state` to `interp`, and update `interp.analyzer.cache`
    initialize_cache!(interp.analyzer, state.res.analyzed_files)
    return LSInterpreter(interp.server, interp.info, interp.analyzer, interp.counter, state)
end
JET.ToplevelAbstractAnalyzer(interp::LSInterpreter) = interp.analyzer

# overloads
# =========

function compute_percentage(count, total, max=100)
    return min(round(Int, (count / total) * max), max)
end

function JET.analyze_from_definitions!(interp::LSInterpreter, config::JET.ToplevelConfig)
    analyzer = JET.ToplevelAbstractAnalyzer(interp, JET.non_toplevel_concretized; refresh_local_cache = false)
    entrypoint = config.analyze_from_definitions
    res = JET.InterpretationState(interp).res
    n = length(res.toplevel_signatures)
    n == 0 && return
    next_interval = interval = 10 ^ max(round(Int, log10(n)) - 1, 0)
    token = interp.info.token
    if token !== nothing
        send(interp.server, ProgressNotification(;
            params = ProgressParams(;
                token,
                value = WorkDoneProgressReport(;
                    message = "0 / $n [signature analysis]",
                    percentage = 50))))
        yield_to_endpoint()
    end
    for i = 1:n
        if token !== nothing && i == next_interval
            percentage = compute_percentage(i, n, 50) + 50
            send(interp.server, ProgressNotification(;
                params = ProgressParams(;
                    token,
                    value = WorkDoneProgressReport(;
                        message = "$i / $n [signature analysis]",
                        percentage))))
            yield_to_endpoint(0.01)
            next_interval += interval
        end
        tt = res.toplevel_signatures[i]
        match = Base._which(tt;
            # NOTE use the latest world counter with `method_table(analyzer)` unwrapped,
            # otherwise it may use a world counter when this method isn't defined yet
            method_table=JET.unwrap_method_table(CC.method_table(analyzer)),
            world=CC.get_inference_world(analyzer),
            raise=false)
        if (match !== nothing &&
            (!(entrypoint isa Symbol) || # implies `analyze_from_definitions===true`
             match.method.name === entrypoint))
            analyzer, result = JET.analyze_method_signature!(analyzer,
                match.method, match.spec_types, match.sparams)
            reports = JET.get_reports(analyzer, result)
            append!(res.inference_error_reports, reports)
        else
            # something went wrong
            if JETLS_DEV_MODE
                @warn "Couldn't find a single method matching the signature `", tt, "`"
            end
        end
    end
end

function JET.virtual_process!(interp::LSInterpreter,
                              x::Union{AbstractString,JS.SyntaxNode},
                              overrideex::Union{Nothing,Expr};
                              on_module_creation=Returns(nothing))
    # XXX: we want to register new module during execute `x`...
    # but now, we can't detect that which module is newly loaded,
    # maybe use some customizable function to execute expr which head is `:module`
    # instead of just `Core.eval` in JET.jl? (see `JET._virtual_process!`)
    token = interp.info.token
    if token !== nothing
        filename = JET.InterpretationState(interp).filename
        shortpath = let state = interp.server.state
            isdefined(state, :root_path) ? relpath(filename, state.root_path) : basename(filename)
        end
        percentage = let total = interp.info.n_files
            iszero(total) ? 0 : compute_percentage(interp.counter[], total,
                JET.InterpretationState(interp).config.analyze_from_definitions ? 50 : 100)
        end
        send(interp.server, ProgressNotification(;
            params = ProgressParams(;
                token,
                value = WorkDoneProgressReport(;
                    message = shortpath * "[file analysis]",
                    percentage))))
        yield_to_endpoint()
    end

    res = @invoke JET.virtual_process!(interp::JET.ConcreteInterpreter,
                                       x::Union{AbstractString,JS.SyntaxNode},
                                       overrideex::Union{Nothing,Expr},
                                       on_module_creation=on_module_creation)
    increment!(interp.counter)
    return res
end

function JET.try_read_file(interp::LSInterpreter, include_context::Module, filename::AbstractString)
    uri = filename2uri(filename)
    fi = get_saved_file_info(interp.server.state, uri)
    if !isnothing(fi)
        parsed_stream = fi.parsed_stream
        if isempty(parsed_stream.diagnostics)
            return fi.syntax_node
        else
            return String(JS.sourcetext(parsed_stream))
        end
    end
    # fallback to the default file-system-based include
    return read(filename, String)
end


function should_recursive_analyze(interp::LSInterpreter, dep::Symbol)
    server = interp.server
    server_state = server.state
    interp_state = JET.InterpretationState(interp)
    depth = interp_state.pkg_mod_depth

    max_depth = get_config(server_state.config_manager, "recursive_analysis", "max_depth")
    max_depth < depth && return false

    exclude = get_config(server_state.config_manager, "recursive_analysis", "exclude")
    depstr = String(dep)
    # XXX: This is temporary implementation.
    #      In the future, this method support `Regex` or `Glob` like object.
    depstr in exclude && return false

    return true
end

"""
    maybe_introduce_mod(required_pkgid::Base.PkgId, caller_mod::Module, dep::Symbol)

If the module is already loaded (i.e. `dep` in `loaded_modules_in_vp`), just
introduce it to `caller_mod` as `const dep = maybe_mod`.

If the module is not loaded or failed to introduce, return `false`.
(If failed to introduce, error reports will be added to `state`.)

If succeeded, return `true`.
"""
function maybe_introduce_mod!(required_pkgid::Base.PkgId, caller_mod::Module, dep::Symbol, state::JET.InterpretationState)
    maybe_mod = maybe_load_modules_in_vp(required_pkgid)
    maybe_mod === nothing && return false
    @assert maybe_mod isa Module
    res = JET.with_err_handling(JET.general_err_handler, state; scrub_offset=1) do
        Core.eval(caller_mod, :(const $dep = $maybe_mod))
    end
    return res !== nothing
end

loaded_modules_in_vp = Dict{Base.PkgId, Module}()

function register_module_for_vp(pkgid::Base.PkgId, mod::Module)
    @info "Registering module $mod for package $pkgid in virtual process"
    # lock loaded_module_in_vp_oplock
    loaded_modules_in_vp[pkgid] = mod

    @info keys(loaded_modules_in_vp)
    # unlock loaded_module_in_vp_oplock
end

function maybe_load_modules_in_vp(pkgid::Base.PkgId)::Union{Module, Nothing}
    # lock loaded_module_in_vp_oplock
    mod = get(loaded_modules_in_vp, pkgid, nothing)
    # unlock loaded_module_in_vp_oplock
    return mod
end

is_loaded_in_vp(pkgid::Base.PkgId) = haskey(loaded_modules_in_vp, pkgid)

"""
    include_on___toplevel__(required_pkgid::Base.PkgId, required_env::AbstractString, interp::LSInterpreter) -> Union{Module, Nothing}

Load the package identified by `required_pkgid` in the environment `required_env` following process:
1. Locate the package path using `Base.locate_package`.
  - If not found, return `nothing`. (This typically happens when the `instantiate` step is not done.)
2. Load the package into `Base.__toplevel__` using `Base.include`.
    - Set the module UUID to `required_pkgid.uuid` temporarily during the include to set uuid for the new module.
    - Register the newly created module using `register_module_for_vp`.
3. Return the loaded module using `maybe_load_modules_in_vp`.
  - If failed, return `nothing`.
"""
function include_on___toplevel__(required_pkgid::Base.PkgId, required_env::AbstractString, interp::LSInterpreter)
    path = Base.locate_package(required_pkgid, required_env)
    if path === nothing
        return nothing
    end
    required_uuid = required_pkgid.uuid
    required_uuid = (required_uuid === nothing ? (UInt64(0), UInt64(0)) : convert(NTuple{2, UInt64}, required_uuid))
    old_uuid = ccall(:jl_module_uuid, NTuple{2, UInt64}, (Any,), Base.__toplevel__)
    if required_uuid !== old_uuid
        ccall(:jl_set_module_uuid, Cvoid, (Any, NTuple{2, UInt64}), Base.__toplevel__, required_uuid)
    end
    old_pkgid = interp.current_pkgid
    interp.current_pkgid = required_pkgid
    on_module_creation(mod) = register_module_for_vp(required_pkgid, mod)
    try
        JET.handle_include(
            interp,
            Base.include,
            [Base.__toplevel__, path],
            on_module_creation = on_module_creation)
        @info "finish handle_include for $required_pkgid"
        @info is_loaded_in_vp(required_pkgid) ? "succeeded to load $required_pkgid" : "failed to load $required_pkgid"
    finally
        interp.current_pkgid = old_pkgid
        loaded_mod = maybe_load_modules_in_vp(required_pkgid)
        if required_uuid !== old_uuid
            ccall(:jl_set_module_uuid, Cvoid, (Any, NTuple{2, UInt64}), Base.__toplevel__, old_uuid)
        end
        if loaded_mod === nothing
            @warn "Failed to load module $required_pkgid from $path"
            return nothing
        end
        return loaded_mod
    end
end

function JET.usemodule_with_err_handling(interp::LSInterpreter, ex::Expr)
    @info "========================== $ex ================================"
    # In 1.13, lowerd form of `using`/`import` is changed
    # TODO: support 1.13 and later
    @static if VERSION >= v"1.13.0"
        return @invoke JET.usemodule_with_err_handling(interp::JET.ConcreteInterpreter, ex::Expr)
    end

    state = JET.InterpretationState(interp)
    caller_mod = state.context
    Meta.isexpr(ex, (:export, :public)) && @goto eval_usemodule
    current_pkgid = interp.current_pkgid
    if current_pkgid !== nothing
        module_usage = JET.pattern_match_module_usage(ex)
        (; modpath) = module_usage
        dep = first(modpath)::Symbol
        if !(dep === :. || # relative module doesn't need to be fixed
             dep === :Base || dep === :Core) # modules available by default
            if dep === Symbol(current_pkgid.name)
                # it's somehow allowed to use the package itself without the relative module path,
                # so we need to special case it and fix it to use the relative module path
                for _ = 1:state.pkg_mod_depth
                    pushfirst!(modpath, :.)
                end
            else
                dependencies = interp.server.state.dependencies
                depstr = String(dep)
                required_pkgenv = Base.identify_package_env(caller_mod, depstr)
                if required_pkgenv === nothing
                    local report = JET.DependencyError(current_pkgid.name, depstr, state.filename, state.curline)
                    JET.add_toplevel_error_report!(state, report)
                    return nothing
                end
                required_pkgid, required_env = required_pkgenv
                if required_pkgid ∉ dependencies
                    if !should_recursive_analyze(interp, dep)
                        # TODO: refactor JET to avoid code duplication
                        res = JET.with_err_handling(JET.general_err_handler, state; scrub_offset=1) do
                            Core.eval(caller_mod, :(const $dep = Base.require($required_pkgid)))
                        end
                        if res === nothing
                            @warn "Failed to set module to $dep in $caller_mod"
                            return nothing
                        end
                    else
                        maybe_mod = include_on___toplevel__(required_pkgid, required_env, interp)
                        if maybe_mod === nothing
                            local report = JET.DependencyError(current_pkgid.name, depstr, state.filename, state.curline)
                            JET.add_toplevel_error_report!(state, report)
                            return nothing
                        end

                        res = JET.with_err_handling(JET.general_err_handler, state; scrub_offset=1) do
                            Core.eval(caller_mod, :(const $dep = $maybe_mod))
                        end
                        if res === nothing
                            @warn "Failed to set module to $dep in $caller_mod"
                            return nothing
                        end
                    end
                    push!(interp.server.state.dependencies, required_pkgid)
                else
                    introduced = maybe_introduce_mod!(required_pkgid, caller_mod, dep, state)
                    if !introduced
                        @warn "Failed to introduce module $dep in $caller_mod in spite of being already seen"
                        return nothing
                    end
                end
                pushfirst!(modpath, :.)
            end
            fixed_module_usage = JET.ModuleUsage(module_usage; modpath)
            ex = JET.form_module_usage(fixed_module_usage)
        elseif dep === :.
            # The syntax `import ..Submod` refers to the name that is available within
            # a parent module specified by the number of `.` dots, indicating how many
            # levels up the module hierarchy to go. However, when it comes to package
            # loading, it seems to work regardless of the number of dots. For now, in
            # `report_package`, adjust `modpath` here to mimic the package loading behavior.
            topmodidx = findfirst(@nospecialize(mp)->mp!==:., modpath)::Int
            topmodsym = modpath[topmodidx]
            curmod = caller_mod
            for i = 1:(topmodidx-1)
                if topmodsym isa Symbol && isdefined(curmod, topmodsym)
                    modpath = modpath[topmodidx:end]
                    for j = 1:i
                        pushfirst!(modpath, :.)
                    end
                    fixed_module_usage = JET.ModuleUsage(module_usage; modpath)
                    ex = JET.form_module_usage(fixed_module_usage)
                    break
                else
                    curmod = parentmodule(curmod)
                end
            end
        end
    end

    @label eval_usemodule

    # # `scrub_offset = 1`: `Core.eval`
    # Executing `using/import` is somewhat redundant, since the module is already loaded
    # and the remaining work is only to introduce names, but this doesn't affect results.
    # TODO: Refactor using `Core._import` or similar.
    JET.with_err_handling(JET.general_err_handler, state; scrub_offset=1) do
        Core.eval(caller_mod, ex)
        true
    end

    end
end # module Interpreter
