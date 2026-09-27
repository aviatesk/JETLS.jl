using Test

funcsin(x) = sin(x[])

@inferred funcsin(Ref{Int}(42))
