const max_methods = 4  # maximum number of MethodInstances tracked for a particular :call statement

"""
    framecode, lenv = get_call_framecode(fargs, parentframe::FrameCode, idx::Int)

Return the framecode and environment for a call specified by `fargs = [f, args...]` (see [`prepare_args`](@ref)).
`parentframecode` is the caller, and `idx` is the program-counter index.
If possible, `framecode` will be looked up from the local method tables of `parentframe`.
"""
function get_call_framecode(fargs::Vector{Any}, parentframe::FrameCode, idx::Int;
                            enter_generated::Bool=false,
                            method_table::Union{Nothing,MethodTable}=nothing)
    nargs = length(fargs)  # includes f as the first "argument"
    # Determine whether we can look up the appropriate framecode in the local method table
    if isassigned(parentframe.methodtables, idx)  # if this is the first call, this may not yet be set
        # The case where `methodtables[idx]` is a `Compiled` has already been handled in `bypass_builtins`
        d_meth = d_meth1 = parentframe.methodtables[idx]::DispatchableMethod
        local d_methprev
        depth = 1
        while true
            # TODO: consider using world age bounds to handle cache invalidation
            # Determine whether the argument types match the signature
            sig = d_meth.sig.parameters::SimpleVector
            if length(sig) == nargs
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
    # We haven't yet encountered this argtype combination and need to look it up by dispatch
    fargs[1] = f = to_function(fargs[1])
    ret = prepare_call(f, fargs; enter_generated, method_table)
    ret === nothing && return invokelatest(f, fargs[2:end]...), nothing
    is_compiled = isa(ret[1], Compiled)
    local framecode
    if is_compiled
        d_meth = DispatchableMethod(nothing, Compiled(), ret[2])
    else
        framecode, args, env, argtypes = ret
        # Store the results of the method lookup in the local method table
        fi = FrameInstance(framecode, env, is_generated(scopeof(framecode::FrameCode)::Method) && enter_generated)
        d_meth = DispatchableMethod(nothing, fi, argtypes)
    end
    if isassigned(parentframe.methodtables, idx)
        # Drop the oldest d_meth, if necessary
        d_methtmp = d_meth.next = parentframe.methodtables[idx]::DispatchableMethod
        depth = 2
        while d_methtmp.next !== nothing
            depth += 1
            depth >= max_methods && break
            d_methtmp = d_methtmp.next::DispatchableMethod
        end
        if depth >= max_methods
            d_methtmp.next = nothing
        end
    else
        d_meth.next = nothing
    end
    parentframe.methodtables[idx] = d_meth
    if is_compiled
        return Compiled(), nothing
    else
        return framecode, env
    end
end
