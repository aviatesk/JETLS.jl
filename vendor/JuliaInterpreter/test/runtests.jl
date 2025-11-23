using JuliaInterpreter
using Test
using Logging

@test isempty(detect_ambiguities(JuliaInterpreter, Base, Core))

if !JuliaInterpreter.isdefinedglobal(@__MODULE__, :read_and_parse)
    include("utils.jl")
end

Core.eval(JuliaInterpreter, :(debug_mode() = true))

@testset "Main tests" begin
    @testset "check_bulitins.jl" begin include("check_builtins.jl") end
    @testset "core.jl" begin include("core.jl") end
    @testset "interpret.jl" begin include("interpret.jl") end
    @testset "toplevel.jl" begin include("toplevel.jl") end
    @testset "limits.jl" begin include("limits.jl") end
    @testset "eval_code.jl" begin include("eval_code.jl") end
    @testset "breakpoints.jl" begin include("breakpoints.jl") end
    @testset "code_coverage/code_coverage.jl" begin include("code_coverage/code_coverage.jl") end
    remove()
    @testset "debug.jl" begin include("debug.jl") end
end
