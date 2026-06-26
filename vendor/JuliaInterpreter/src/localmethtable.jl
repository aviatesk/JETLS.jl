const max_methods = 4  # maximum number of MethodInstances tracked for a particular :call statement

"""
    framecode, lenv = get_call_framecode(fargs, parentframe::FrameCode, idx::Int)

Return the framecode and environment for a call specified by `fargs = [f, args...]` (see [`prepare_args`](@ref)).
`parentframecode` is the caller, and `idx` is the program-counter index.
If possible, `framecode` will be looked up from the local method tables of `parentframe`.
"""
function get_call_framecode(fargs::Vector{Any}, parentframe::FrameCode, idx::Int;
                            enter_generated::Bool=false,
                            world::UInt=default_world(),
                            method_table::Union{Nothing,MethodTable}=nothing)
    nargs = length(fargs)  # includes f as the first "argument"
    # Determine whether we can look up the appropriate framecode in the local method table
    if isassigned(parentframe.methodtables, idx)  # if this is the first call, this may not yet be set
        # The case where `methodtables[idx]` is a `Compiled` has already been handled in `bypass_builtins`
        d_meth = d_meth1 = parentframe.methodtables[idx]::DispatchableMethod
        local d_methprev
        depth = 1
        while true
            # Reuse a cached dispatch only if it was resolved in the current world and with the same
            # method table. A world advance can change which method applies (e.g. a newly defined,
            # more-specific method), so an entry stamped at an older world must be re-resolved rather
            # than trusted by argument type alone. Method lookup reports no usable upper world bound
            # for a live match (it returns `typemax`), so the resolution world itself is the
            # invalidation key. The method table is part of the dispatch context — the same call
            # resolves differently under an overlay table — so it too must match.
            # Determine whether the argument types match the signature
            sig = d_meth.sig.parameters::SimpleVector
            if d_meth.world == world && d_meth.mt === method_table && length(sig) == nargs
                # If this is generated, match only if `enter_generated` also matches
                fi = d_meth.frameinstance
                if fi isa FrameInstance
                    matches = !is_generated(scopeof(fi.framecode)::Method) || enter_generated == fi.enter_generated
                else
                    matches = !enter_generated
                end
                if matches
                    for i = 1:nargs
                        if !isa(fargs[i], sig[i])
                            matches = false
                            break
                        end
                    end
                end
                if matches
                    # Rearrange the list to place this method first
                    # (if we're in a loop, we'll likely match this one again on the next iteration)
                    if depth > 1
                        parentframe.methodtables[idx] = d_meth
                        d_methprev.next = d_meth.next
                        d_meth.next = d_meth1
                    end
                    if fi isa Compiled
                        return Compiled(), nothing
                    else
                        fi = fi::FrameInstance
                        return fi.framecode, fi.sparam_vals
                    end
                end
            end
            depth += 1
            d_methprev = d_meth
            d_meth = d_meth.next
            d_meth === nothing && break
            d_meth = d_meth::DispatchableMethod
        end
    end
    # We haven't yet encountered this argtype combination (or a world advance invalidated the
    # cached entry) and need to look it up by dispatch.
    fargs[1] = f = to_function(fargs[1], world)
    ret = prepare_call(f, fargs; enter_generated, world, method_table)
    ret === nothing && return invoke_in_world(world, f, fargs[2:end]...), nothing
    is_compiled = isa(ret[1], Compiled)
    local framecode, env
    if is_compiled
        fi = Compiled()
        argtypes = ret[2]
    else
        framecode, args, env, argtypes = ret
        fi = FrameInstance(framecode, env, is_generated(scopeof(framecode::FrameCode)::Method) && enter_generated)
    end
    # Store the result of the method lookup in the local method table, stamped with the world in
    # which it was resolved (see the cache lookup above). If an entry with this exact key — the
    # signature plus the generator/body flavor — already exists (typically one just rejected as
    # stale after a world advance), refresh it in place so the chain does not accumulate
    # superseded entries; otherwise prepend a new entry, dropping the oldest once the chain
    # exceeds `max_methods`.
    if isassigned(parentframe.methodtables, idx)
        existing = find_dispatchable(parentframe.methodtables[idx]::DispatchableMethod, argtypes, fi, method_table)
        if existing !== nothing
            existing.frameinstance = fi
            existing.world = world
        else
            d_meth = DispatchableMethod(parentframe.methodtables[idx]::DispatchableMethod, fi, argtypes, world, method_table)
            d_methtmp = d_meth.next::DispatchableMethod
            depth = 2
            while d_methtmp.next !== nothing
                depth += 1
                depth >= max_methods && break
                d_methtmp = d_methtmp.next::DispatchableMethod
            end
            if depth >= max_methods
                d_methtmp.next = nothing
            end
            parentframe.methodtables[idx] = d_meth
        end
    else
        parentframe.methodtables[idx] = DispatchableMethod(nothing, fi, argtypes, world, method_table)
    end
    if is_compiled
        return Compiled(), nothing
    else
        return framecode, env
    end
end

# Return the cached entry that stores the same kind of dispatch as `fi`: the (concrete) signature
# must be `argtypes`, the entry's generator/body flavor must match (since for a `@generated`
# method the generator and the specialized body are distinct entries that coexist in the chain;
# see the `enter_generated` check in the cache-hit loop), and the method table must match (an
# overlay table is a distinct resolution context that coexists in the chain). Returns `nothing`
# if there is no such entry. Types are interned, so an identity comparison of signatures suffices
# and is cheap.
function find_dispatchable(d::DispatchableMethod, @nospecialize(argtypes), fi::Union{Compiled,FrameInstance}, mt::Union{Nothing,MethodTable})
    wants_generator = fi isa FrameInstance && fi.enter_generated
    dd = d
    while true
        if dd.sig === argtypes && dd.mt === mt
            dfi = dd.frameinstance
            (dfi isa FrameInstance && dfi.enter_generated) == wants_generator && return dd
        end
        next = dd.next
        next === nothing && return nothing
        dd = next::DispatchableMethod
    end
end
