"""
    OrderedSet

`OrderedSet`s are simply sets whose entries have a particular order. The order
refers to insertion order, which allows deterministic iteration over the set.

Note: To create an OrderedSet of a particular type, you must specify the type, such as,

```julia
os = OrderedSet{Int}(3)
push!(os, [1,2]...)
```
"""
struct OrderedSet{T}  <: AbstractSet{T}
    dict::OrderedDict{T,Nothing}

    OrderedSet{T}() where {T} = new{T}(OrderedDict{T,Nothing}())
    OrderedSet{T}(xs) where {T} = union!(OrderedSet{T}(), xs)
    function OrderedSet{T}(s::Base.KeySet{T, <:OrderedDict{T}}) where {T}
        d = s.dict
        slots = copy(d.slots)
        keys = copy(d.keys)
        vals = similar(d.vals, Nothing)
        live = copy(d.live)
        new{T}(OrderedDict{T,Nothing}(slots, keys, vals, live, d.ndel, d.maxprobe, d.dirty, d.firstlive, d.lastlive))
    end
end

OrderedSet() = OrderedSet{Any}()
OrderedSet(xs) = OrderedSet{eltype(xs)}(xs)

show(io::IO, s::OrderedSet) = (show(io, typeof(s)); print(io, "("); !isempty(s) && Base.show_vector(io, s,'[',']'); print(io, ")"))

isempty(s::OrderedSet) = isempty(s.dict)
length(s::OrderedSet)  = length(s.dict)

sizehint!(s::OrderedSet, sz::Integer) = (sizehint!(s.dict, sz); s)

in(x, s::OrderedSet) = haskey(s.dict, x)

push!(s::OrderedSet, x) = (s.dict[x] = nothing; s)
pop!(s::OrderedSet, x) = (pop!(s.dict, x); x)
pop!(s::OrderedSet, x, deflt) = pop!(s.dict, x, deflt) == deflt ? deflt : x
delete!(s::OrderedSet, x) = (delete!(s.dict, x); s)

empty(s::OrderedSet{T}) where {T} = OrderedSet{T}()
copy(s::OrderedSet) = union!(empty(s), s)

empty!(s::OrderedSet{T}) where {T} = (empty!(s.dict); s)

emptymutable(s::OrderedSet{T}, ::Type{U}=T) where {T,U} = OrderedSet{U}()
copymutable(s::OrderedSet) = copy(s)

# NOTE: manually optimized to take advantage of OrderedDict representation.
function iterate(s::OrderedSet, i::Int = 1)
    d = s.dict
    n = length(d.keys)
    @inbounds while i <= n
        d.live[i] && return (d.keys[i], i + 1)
        i += 1
    end
    return nothing
end

# lazy reverse iteration
function iterate(rs::Iterators.Reverse{<:OrderedSet}, i::Int = length(rs.itr.dict.keys))
    d = rs.itr.dict
    @inbounds while i >= 1
        d.live[i] && return (d.keys[i], i - 1)
        i -= 1
    end
    return nothing
end

pop!(s::OrderedSet) = pop!(s.dict)[1]
popfirst!(s::OrderedSet) = popfirst!(s.dict)[1]

==(l::OrderedSet, r::OrderedSet) = (length(l) == length(r)) && (l <= r)
<(l::OrderedSet, r::OrderedSet) = (length(l) < length(r)) && (l <= r)
<=(l::OrderedSet, r::OrderedSet) = issubset(l, r)

function filter!(f::Function, s::OrderedSet)
    for x in s
        if !f(x)
            delete!(s, x)
        end
    end
    return s
end

function hash(s::OrderedSet, h::UInt)
    hv = hash(orderedset_seed, h)
    d = s.dict
    @inbounds for i in 1:length(d.keys)
        d.live[i] || continue
        hv = hash(d.keys[i], hv)
    end
    return hv
end
