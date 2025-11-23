using PrecompileTools
using Test
using InteractiveUtils

@testset "No-coverage tests" begin
    @assert Base.JLOptions().code_coverage == 0 "These tests should be run with coverage disabled"

    push!(LOAD_PATH, @__DIR__)

    using MSort
    using AliasTables
    x = rand(64)
    pipe = Pipe()
    oldstderr = stderr
    redirect_stderr(pipe)
    @trace_compile begin
        @eval begin
            MSort.quicksort($x)
            at = AliasTable([1.0, 2.0])
            rand(at)
        end
    end
    close(pipe.in)
    redirect_stderr(oldstderr)
    str = read(pipe.out, String)
    @test isempty(str)

    pop!(LOAD_PATH)
end
