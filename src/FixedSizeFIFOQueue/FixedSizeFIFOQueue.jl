mutable struct FixedSizeFIFOQueue{T}
    const data::Vector{T}
    head::Int
    tail::Int
    size::Int
    const capacity::Int
    const items::Set{T}

    function FixedSizeFIFOQueue{T}(capacity::Int) where T
        capacity > 0 || throw(ArgumentError("Capacity must be positive"))
        data = Vector{T}(undef, capacity)
        new{T}(data, 1, 1, 0, capacity, Set{T}())
    end
    FixedSizeFIFOQueue(capacity::Int) = FixedSizeFIFOQueue{Any}(capacity)
end

function Base.push!(queue::FixedSizeFIFOQueue{T}, item::T) where T
    if queue.size == queue.capacity
        # Queue is full, overwrite oldest element
        old_item = queue.data[queue.head]
        delete!(queue.items, old_item)
        queue.data[queue.tail] = item
        push!(queue.items, item)
        queue.head = mod1(queue.head + 1, queue.capacity)
        queue.tail = mod1(queue.tail + 1, queue.capacity)
    else
        # Queue has space
        queue.data[queue.tail] = item
        push!(queue.items, item)
        queue.tail = mod1(queue.tail + 1, queue.capacity)
        queue.size += 1
    end
    return queue
end

Base.in(item::T, queue::FixedSizeFIFOQueue{T}) where T = item in queue.items

Base.isempty(queue::FixedSizeFIFOQueue) = queue.size == 0

isfull(queue::FixedSizeFIFOQueue) = queue.size == queue.capacity

Base.length(queue::FixedSizeFIFOQueue) = queue.size

capacity(queue::FixedSizeFIFOQueue) = queue.capacity

function Base.collect(queue::FixedSizeFIFOQueue{T}) where T
    result = Vector{T}(undef, queue.size)
    idx = queue.head
    for i in 1:queue.size
        result[i] = queue.data[idx]
        idx = mod1(idx + 1, queue.capacity)
    end
    return result
end

function Base.show(io::IO, queue::FixedSizeFIFOQueue{T}) where T
    items = collect(queue)
    print(io, "FixedSizeFIFOQueue{$T}(capacity=$(queue.capacity), items=$items)")
end
