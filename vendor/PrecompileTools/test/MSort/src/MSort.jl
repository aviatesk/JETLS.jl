module MSort

# issue #26

using PrecompileTools

function quicksort(
    v::Vector{T};
    lo::Int = 1,
    hi::Int = length(v),
) where {T <: Union{Int64, Float64}}
    x = copy(v)
    quick!(x, lo, hi)
    x
end

function partition(
    xp::Vector{T},
    pivot::T,
    left::Int,
    right::Int,
) where {T <: Union{Int64, Float64}}
    while left <= right
        while xp[left] < pivot
            left += 1
        end
        while pivot < xp[right]
            right -= 1
        end
        if left <= right
            xp[left], xp[right] = xp[right], xp[left]
            left += 1
            right -= 1
        end
    end
    left, right
end

function quick!(
    xp::Vector{T},
    i::Int,
    j::Int,
) where {T <: Union{Int64, Float64}}
    if j > i
        left, right = partition(xp, xp[(j+i)>>>1], i, j)
        quick!(xp, i, right)
        quick!(xp, left, j)
    end
end

@setup_workload begin
    @compile_workload begin
        quicksort(rand(64))
    end
end

end
