"""
    @recompile_invalidations begin
        using PkgA
        ⋮
    end

Recompile any invalidations that occur within the given expression. This is generally intended to be used
by users in creating "Startup" packages to ensure that the code compiled by package authors is not invalidated.
"""
macro recompile_invalidations(expr)
    # use QuoteNode instead of esc(Expr(:quote)) so that $ is not permitted as usual (instead of having this macro work like `@eval`)
    return :(recompile_invalidations($__module__, $(QuoteNode(expr))))
end

const ReinferUtils = isdefined(Base, :ReinferUtils) ? Base.ReinferUtils :
                     isdefined(Base, :StaticData) ? Base.StaticData : nothing

function recompile_invalidations(__module__::Module, @nospecialize expr)
    if ReinferUtils === nothing
        @warn "@recompile_invalidations does not support this Julia build, so invalidations will not be recompiled" maxlog=1
        Core.eval(__module__, expr)
        return nothing
    end
    listi = ccall(:jl_debug_method_invalidation, Any, (Cint,), 1)
    liste = ReinferUtils.debug_method_invalidation(true)
    try
        Core.eval(__module__, expr)
    finally
        ccall(:jl_debug_method_invalidation, Any, (Cint,), 0)
        ReinferUtils.debug_method_invalidation(false)
    end
    if ccall(:jl_generating_output, Cint, ()) == 1
        for mi in invalidation_leaves(listi, liste)
            runs_in_frozen_world(mi) || precompile_mi(mi)
        end
    end
    nothing
end

# Compiler, lowering and code-loading code runs in a frozen world age. Code in a
# pkgimage is only valid from the world it is loaded into, so these callers could never use it.
const excluded_modules = Module[Core.Compiler]
isdefined(Base, :JuliaLowering) && push!(excluded_modules, Base.JuliaLowering)
# Code loading enters its frozen world through these methods
const excluded_methods = isdefined(Base, :__require) ? collect(Method, methods(Base.__require)) : Method[]

function runs_in_frozen_world(mi::Core.MethodInstance)
    m = mi.def
    isa(m, Method) && m in excluded_methods && return true
    mod = isa(m, Method) ? m.module : m::Module
    while true
        mod in excluded_modules && return true
        parent = parentmodule(mod)
        parent === mod && return false
        mod = parent
    end
end

function invalidation_leaves(listi, liste)
    umis = Set{Core.MethodInstance}()
    # `queued` is a queue of length 0 or 1 of invalidated MethodInstances.
    # We wait to read the `depth` to find out if it's a leaf.
    queued, depth = nothing, 0
    function cachequeued(item, nextdepth)
        if queued !== nothing && nextdepth <= depth
            push!(umis, queued)
        end
        queued, depth = item, nextdepth
    end

    # Process method insertion/deletion events
    i, ilast = firstindex(listi), lastindex(listi)
    while i <= ilast
        item = listi[i]
        if isa(item, Core.MethodInstance)
            if i < lastindex(listi)
                nextitem = listi[i+1]
                if nextitem == "invalidate_mt_cache"
                    cachequeued(nothing, 0)
                    i += 2
                    continue
                end
                if nextitem ∈ ("jl_method_table_disable", "jl_method_table_insert")
                    cachequeued(nothing, 0)
                    push!(umis, item)
                end
                if isa(nextitem, Integer)
                    cachequeued(item, nextitem)
                    i += 2
                    continue
                end
            end
        end
        if (isa(item, Method) || isa(item, Type)) && queued !== nothing
            push!(umis, queued)
            queued, depth = nothing, 0
        end
        i += 1
    end

    # Process edge-validation events
    # Recompiling only fills the native cache, so skip code cached by other interpreters
    pushci!(ci::Core.CodeInstance) = ci.owner === nothing && push!(umis, Core.Compiler.get_ci_mi(ci))
    i, ilast = firstindex(liste), lastindex(liste)
    while i <= ilast
        tag = liste[i + 1]   # the tag is always second
        if tag == "method_globalref"
            pushci!(liste[i + 2])
            i += 4
        elseif tag == "insert_backedges_callee"
            pushci!(liste[i + 2])
            i += 4
        elseif tag == "verify_methods"
            pushci!(liste[i])
            i += 3
        else
            error("Unknown tag found in invalidation list: ", tag)
        end
    end

    return umis
end
