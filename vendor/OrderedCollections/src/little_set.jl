
"""
    LittleSet([itr]) <: AbstractSet

Constructs an ordered set optimized for a small number of elements, given the
iterable `itr`. The underlying data is stored as either an `AbstractVector` or
a `Tuple` and is optimal for 30-50 elements, similar to [`LittleDict`](@ref).
"""
struct LittleSet{T, D<:StoreType{T}} <: AbstractSet{T}
    data::D

    LittleSet{T, D}(data) where {T,D} = new{T, D}(data)
    function LittleSet{T, Tuple{Vararg{T}}}(@nospecialize(data)) where {T}
        new_data = isa(data, Tuple) ? data : Tuple(data)
        new{T, Tuple{Vararg{T}}}(new_data)
    end
    function (LittleSet{T, Tuple{Vararg{T}}} where {T})(@nospecialize(data))
        T2 = eltype(data)
        new{T2, Tuple{Vararg{T2}}}(data)
    end
    function LittleSet{T}(data::AbstractVector) where {T}
        if eltype(data) == T
            return new{T, typeof(data)}(data)
        else
            d = convert(AbstractVector{T}, data)
            return new{T, typeof(d)}(d)
        end
    end
    LittleSet{T}(data::Tuple{Vararg{T}}) where {T} = new{T, typeof(data)}(data)
    LittleSet{T}(itr) where {T} = union!(LittleSet{T}(), itr)
    LittleSet{T}() where {T} = new{T, Vector{T}}(Vector{T}())
    LittleSet() = LittleSet{Any}()
    function LittleSet(itr)
        IET = Base.IteratorEltype(itr)
        if isa(IET, Base.HasEltype)
            LittleSet{eltype(itr)}(itr)
        else
            T = Base.@default_eltype(itr)
            if (Base.isconcretetype(T) || T === Union{})
                return LittleSet{T}(itr)
            else
                return Base.grow_to!(LittleSet{T}(), itr)
            end
        end
    end

    function Base.empty(s::LittleSet{T, D}) where {T, D}
        if isa(s, LittleSet{T, Tuple{Vararg{T}}})
            return new{T, Tuple{Vararg{T}}}(())
        elseif D <: Tuple
            return new{T, Tuple{}}(())
        else
            return new{T, D}(empty(getfield(s, :data)))
        end
    end
    function Base.emptymutable(s::LittleSet{T, D}, ::Type{U}=T) where {T, D, U}
        if D <: Tuple
            new_data = U[]
        else
            new_data = Base.emptymutable(getfield(s, :data), U)
        end
        return new{U, typeof(new_data)}(new_data)
    end
end

const OpaqueLittleSet{T} = LittleSet{T, Tuple{Vararg{T}}}
const UnfrozenLittleSet{T} = LittleSet{T, <:AbstractVector{T}}
const FrozenLittleSet{T} = LittleSet{T, <:Tuple}

function Base.Tuple(s::LittleSet)
    data = getfield(s, :data)
    isa(data, Tuple) ? data : Tuple(data)
end

freeze(s::AbstractSet{T}) where {T} = LittleSet{T}(Tuple(s))

hash(s::LittleSet, h::UInt) = hash(getfield(s, :data), hash(orderedset_seed, h))

function Base.length(s::LittleSet)
    data = getfield(s, :data)
    isa(data, Tuple) ? nfields(data) : length(data)
end

function Base.isempty(s::LittleSet)
    data = getfield(s, :data)
    isa(data, Tuple) ? nfields(data) == 0 : isempty(data)
end

function Base.copy(s::LittleSet{T, D}) where {T, D}
    # since `Base.copy` is a shallow copy on collections, an immutable collection
    # like `Tuple` is treated the same
    if D <: Tuple
        return s
    else
        return LittleSet{T, D}(copy(getfield(s, :data)))
    end
end

function Base.copymutable(s::LittleSet{T}) where {T}
    data = getfield(s, :data)
    if isa(data, Tuple)
        i = nfields(data)
        new_data = Vector{T}(undef, n)
        while i != 0
            @inbounds new_data[i] = getfield(data, i)
            i -= 1
        end
    else
        new_data = Base.copymutable(data)
    end
    LittleSet{T}(new_data)
end

function Base.sizehint!(s::UnfrozenLittleSet, sz)
    sizehint!(getfield(s, :data), sz)
    return s
end
Base.iterate(s::LittleSet, state...) = iterate(getfield(s, :data), state...)

function Base.in(x, s::LittleSet)
    data = getfield(s, :data)
    if isa(data, Tuple)
        n = nfields(data)
        while n > 0
            isequal(x, getfield(data, n)) && return true
            n -= 1
        end
        return false
    else
        return in(x, data)
    end
end

# HACK: this is a temporary hack to get around the lack of `sort` available for tuples
function Base.sort(s::FrozenLittleSet{T}; ks...) where {T}
    LittleSet{T}(sort(T[getfield(s, :data)...]; ks...))
end
function Base.sort(s::UnfrozenLittleSet{T}; ks...) where {T}
    LittleSet{T}(sort(getfield(s, :data); ks...))
end

function Base.sort!(s::UnfrozenLittleSet; ks...)
    sort!(getfield(s, :data); ks...)
    return s
end

Base.first(s::UnfrozenLittleSet, n::Integer) = LittleSet(first(getfield(s, :data), n))
function Base.first(s::FrozenLittleSet{T}, n::Integer) where {T}
    N = Int(n)
    N < 0 && throw(ArgumentError("Number of elements must be nonnegative"))
    data = getfield(s, :data)
    stop = nfields(data)
    if stop <= N
        # max number of elements is everything so it's equivalent to `copy`
        return s
    elseif isa(s, LittleSet{T, Tuple{Vararg{T}}})
        return LittleSet{T, Tuple{Vararg{T}}}(Tuple(@inbounds(collect(data)[1:N])))
    else
        return LittleSet{T}(ntuple(i->getfield(data, i), min(nfields(data), n)))
    end
end

Base.last(s::UnfrozenLittleSet, n::Integer) = LittleSet(last(getfield(s, :data), n))
function Base.last(s::FrozenLittleSet{T}, n::Integer) where {T}
    N = Int(n)
    N < 0 && throw(ArgumentError("Number of elements must be nonnegative"))
    data = getfield(s, :data)
    stop = nfields(data)
    offset = stop - N
    if offset < 1
        # offset less than one means each element is returned so it's equivalent to `copy`
        return s
    elseif isa(s, LittleSet{T, Tuple{Vararg{T}}})
        return LittleSet{T, Tuple{Vararg{T}}}(Tuple(@inbounds(collect(data)[1:N])))
    else
        return LittleSet{T}(ntuple(i->getfield(data, offset + i), N))
    end
end

function Base.union(x::FrozenLittleSet{T1}, y::FrozenLittleSet{T2}) where {T1, T2}
    xdata = getfield(x, :data)
    nx = nfields(xdata)
    ydata = getfield(y, :data)
    ny = nfields(ydata)
    if isa(x, LittleSet{T1, Tuple{Vararg{T1}}}) || isa(y, LittleSet{T2, Tuple{Vararg{T2}}})
        if nx < ny # nx is smaller so search for x items in y
            newdata = (filter(!in(y), x)..., ydata...)
        else # ny is smaller so search for y items in x
            newdata = (xdata..., getfield(filter(!in(x), y), :data)...)
        end
        T = Union{T1, T2}
        return LittleSet{T, Tuple{Vararg{T}}}(newdata)
    else
        if nx < ny # nx is smaller so search for x items in y
            return LittleSet((filter(!in(ydata), xdata)..., ydata...))
        else # ny is smaller so search for y items in x
            return LittleSet((xdata..., filter(!in(xdata), ydata)...))
        end
    end
end

function Base.push!(s::UnfrozenLittleSet, val)
    data = getfield(s, :data)
    if !in(val, data)
        push!(data, val)
    end
    return s
end

Base.pop!(s::UnfrozenLittleSet) = pop!(getfield(s, :data))
function Base.pop!(s::UnfrozenLittleSet, key)
    data = getfield(s, :data)
    for i in eachindex(data)
        k = @inbounds(data[i])
        if (key ===  k || isequal(key, k))
            deleteat!(data, i)
            return k
        end
    end
    throw(KeyError(key))
end
function Base.pop!(s::UnfrozenLittleSet, key, default)
    data = getfield(s, :data)
    for i in eachindex(data)
        k = @inbounds(data[i])
        if (key ===  k || isequal(key, k))
            deleteat!(data, i)
            return k
        end
    end
    return default
end

Base.empty!(s::UnfrozenLittleSet) = (empty!(getfield(s, :data)); s)

function Base.delete!(s::UnfrozenLittleSet, key)
    data = getfield(s, :data)
    for i in eachindex(data)
        k = @inbounds(data[i])
        if (key ===  k || isequal(key, k))
            deleteat!(data, i)
            break
        end
    end
    return s
end

function Base.filter(f, s::LittleSet{T}) where {T}
    newdata = filter(f, getfield(s, :data))
    if isa(s, OpaqueLittleSet)
        return OpaqueLittleSet{T}(newdata)
    else
        return LittleSet(newdata)
    end
end
function Base.filter!(f, s::UnfrozenLittleSet)
    filter!(f, getfield(s, :data))
    return s
end

# these are copied from Julia's "base/set.jl" because tuple replace isn't
# supported before Julia v1.7
function check_count(count::Integer)
    count < 0 && throw(DomainError(count, "`count` must not be negative (got $count)"))
    return min(count, typemax(Int)) % Int
end

function Base.replace(
    s::LittleSet{T},
    old_new::Pair{F, S}...;
    count::Integer=typemax(Int)
) where {T, F, S}
    replace(s; count=count) do x
        for o_n in old_new
            isequal(first(o_n), x) && return last(o_n)
        end
        return x
    end
end
function Base.replace(
    f::Union{Function, Type},
    s::LittleSet{T, D};
    count::Integer=typemax(Int)
) where {T, D}
    old_data = getfield(s, :data)
    if isa(old_data, Tuple)
        c = check_count(count)
        n = nfields(old_data)
        v = Vector{Any}(undef, n)
        for i in Base.OneTo(n)
            old_item = @inbounds(getfield(old_data, i))
            if c > 0
                new_item = f(old_item)
                if new_item == old_item
                    c -= 1
                end
            else
                new_item = old_item
            end
            @inbounds(setindex!(v, new_item, i))
        end
        new_data = (v...,)
        T2 = eltype(new_data)
        if isa(s, LittleSet{T, Tuple{Vararg{T}}})
            return LittleSet{T2, Tuple{Vararg{T2}}}(new_data)
        else
            return LittleSet{T2, typeof(new_data)}(new_data)
        end
    else
        new_data = replace(f, old_data, count=count)
        return LittleSet(new_data)
    end
end
