# Sort for dicts
import Base: sort, sort!

function sort!(d::OrderedDict; byvalue::Bool=false, args...)
    if d.ndel > 0
        rehash!(d)
    end

    data = byvalue ? d.vals : d.keys

    # Filter out the kwargs supported by issorted (notably, :alg needs to be removed)
    issorted_kw = NamedTuple(k => v for (k, v) in args if k in (:lt, :by, :rev, :order))
    issorted(data; issorted_kw...) && return d

    p = sortperm(data; args...)
    d.keys = d.keys[p]
    d.vals = d.vals[p]
    rehash!(d)
    return d
end

# Compared to just sorting the underlying OrderedDict, this method calls sort!
# directly on the keys (no need to sort d.vals::Vector{Nothing}). This saves
# the allocation of the permutation vector in sortperm, and subsequent
# allocations of new d.keys and d.vals vectors.
function sort!(s::OrderedSet; kwargs...)
    d = s.dict
    d.ndel > 0 && rehash!(d)
    sort!(d.keys; kwargs...)
    rehash!(d)
    return s
end

function sort!(d::UnfrozenLittleDict; byvalue::Bool=false, args...)
    if byvalue
        p = sortperm(d.vals; args...)
    else
        p = sortperm(d.keys; args...)
    end
    permute!(d.keys, p)
    permute!(d.vals, p)
    return d
end

sort(d::Union{OrderedDict,OrderedSet}; args...) = sort!(copy(d); args...)

@deprecate sort(d::Dict; args...) sort!(OrderedDict(d); args...)

function sort(d::LittleDict; byvalue::Bool=false, args...)
    if byvalue
        p = sortperm(d.vals; args...)
    else
        p = sortperm(d.keys; args...)
    end
    return LittleDict(d.keys[p], d.vals[p])
end

