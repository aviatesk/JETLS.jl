using Test

function (@main)(args)
    if length(args) < 2
        error("Usage: runtest.jl <testset_name> <testfile>")
    end
    @testset "$(args[1])" include(args[2])
    return 0
end
