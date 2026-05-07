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
        new{T}(OrderedDict{T,Nothing}(slots, keys, vals, d.ndel, d.maxprobe, d.dirty))
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

# NOTE: manually optimized to take advantage of OrderedDict representation
function iterate(s::OrderedSet)
    s.dict.ndel > 0 && rehash!(s.dict)
    length(s.dict.keys) < 1 && return nothing
    return (s.dict.keys[1], 2)
end
function iterate(s::OrderedSet, i)
    length(s.dict.keys) < i && return nothing
    return (s.dict.keys[i], i+1)
end

# lazy reverse iteration
function iterate(rs::Iterators.Reverse{<:OrderedSet}, i = length(rs.itr))
    s = rs.itr
    i < 1 && return nothing
    return (s.dict.keys[i], i-1)
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
    h = hash(orderedset_seed, h)
    s.dict.ndel > 0 && rehash!(s.dict)
    hash(s.dict.keys, h)
end

# Deprecated functionality, see
# https://github.com/JuliaCollections/DataStructures.jl/pull/180#issuecomment-400269803

function getindex(s::OrderedSet, i::Int)
    Base.depwarn("indexing is deprecated for OrderedSet, please rewrite your code to use iteration", :getindex)
    s.dict.ndel > 0 && rehash!(s.dict)
    return s.dict.keys[i]
end

function lastindex(s::OrderedSet)
    Base.depwarn("indexing is deprecated for OrderedSet, please rewrite your code to use iteration", :lastindex)
    s.dict.ndel > 0 && rehash!(s.dict)
    return lastindex(s.dict.keys)
end

function nextind(::OrderedSet, i::Int)
    Base.depwarn("indexing is deprecated for OrderedSet, please rewrite your code to use iteration", :lastindex)
    return i + 1  # Needed on 0.7 to mimic array indexing.
end

function keys(s::OrderedSet)
    Base.depwarn("indexing is deprecated for OrderedSet, please rewrite your code to use iteration", :lastindex)
    s.dict.ndel > 0 && rehash!(s.dict)
    return 1:length(s)
end
