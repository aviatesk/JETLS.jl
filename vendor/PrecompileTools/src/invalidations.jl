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

const ReinferUtils = isdefined(Base, :ReinferUtils) ? Base.ReinferUtils : Base.StaticData

function recompile_invalidations(__module__::Module, @nospecialize expr)
    listi = ccall(:jl_debug_method_invalidation, Any, (Cint,), 1)
    liste = ReinferUtils.debug_method_invalidation(true)
    try
        Core.eval(__module__, expr)
    finally
        ccall(:jl_debug_method_invalidation, Any, (Cint,), 0)
        ReinferUtils.debug_method_invalidation(false)
    end
    if ccall(:jl_generating_output, Cint, ()) == 1
        foreach(precompile_mi, invalidation_leaves(listi, liste))
    end
    nothing
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
    i, ilast = firstindex(liste), lastindex(liste)
    while i <= ilast
        tag = liste[i + 1]   # the tag is always second
        if tag == "method_globalref"
            push!(umis, Core.Compiler.get_ci_mi(liste[i + 2]))
            i += 4
        elseif tag == "insert_backedges_callee"
            push!(umis, Core.Compiler.get_ci_mi(liste[i + 2]))
            i += 4
        elseif tag == "verify_methods"
            push!(umis, Core.Compiler.get_ci_mi(liste[i]))
            i += 3
        else
            error("Unknown tag found in invalidation list: ", tag)
        end
    end

    return umis
end
