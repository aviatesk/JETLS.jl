using JuliaInterpreter
using Test
using Logging
using Aqua
using ExplicitImports

@test isempty(detect_ambiguities(JuliaInterpreter, Base, Core))
Aqua.test_all(JuliaInterpreter; deps_compat=(
    ignore=[:InteractiveUtils, :Random, :UUIDs],
    check_extras=(ignore=[:Dates, :Distributed, :LinearAlgebra, :Logging, :Mmap, :SHA, :SparseArrays, :Test],),
))

@testset "ExplicitImports" begin
    # #Internal is dynamically included and cannot be statically analyzed.
    # The package uses non-public Core/Base/Compiler internals throughout, so the
    # two public-ness checks are suppressed.
    # Four Core.Compiler.X accesses (Val, getindex, iterate, specialize_method) refer
    # to distinct objects on Julia 1.10 vs 1.12, so all_qualified_accesses_via_owners
    # is suppressed rather than scattering @static VERSION guards through the source.
    test_explicit_imports(JuliaInterpreter;
                          ignore                            = (JuliaInterpreter.var"#Internal",),
                          all_explicit_imports_are_public   = false,
                          all_qualified_accesses_are_public = false,
                          all_qualified_accesses_via_owners = false)
end

if isdefined(Test, :detect_closure_boxes)
    @test isempty(Test.detect_closure_boxes(JuliaInterpreter))
end

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
