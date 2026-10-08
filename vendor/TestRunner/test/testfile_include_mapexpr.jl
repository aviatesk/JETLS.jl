using Test

function define_answer(@nospecialize ex)
    Meta.isexpr(ex, :module) && pushfirst!(ex.args[end].args, :(const answer = 42))
    return ex
end

module IncludeIntoModule end

@testset "include with mapexpr" begin
    include(define_answer, "_testfile_include_mapexpr.jl")
    Base.include(define_answer, IncludeIntoModule, "_testfile_include_mapexpr.jl")
end
