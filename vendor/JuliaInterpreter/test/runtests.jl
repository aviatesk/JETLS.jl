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

if isdefined(Test, :detect_closure_boxes)
    @test isempty(Test.detect_closure_boxes(JuliaInterpreter))
end

# ExplicitImports >= 1.15 emits `@warn "... reached recursion limit" leaf` for every identifier
# nested more than 100 syntax-tree levels deep, and the attached `leaf` cursor prints its whole
# ancestor chain (~2MB per warning). The generated `if/elseif` chain in src/builtins.jl is deep
# enough to trigger this dozens of times, flooding the test log
# (https://github.com/JuliaTesting/ExplicitImports.jl/issues/173). Drop just those warnings and
# forward everything else to the wrapped logger untouched.
struct DropRecursionLimitWarnings{Logger<:AbstractLogger} <: AbstractLogger
    logger::Logger
end
Logging.min_enabled_level(l::DropRecursionLimitWarnings) = Logging.min_enabled_level(l.logger)
Logging.shouldlog(l::DropRecursionLimitWarnings, args...) = Logging.shouldlog(l.logger, args...)
Logging.catch_exceptions(l::DropRecursionLimitWarnings) = Logging.catch_exceptions(l.logger)
function Logging.handle_message(l::DropRecursionLimitWarnings, level, message, _module, group, id, file, line; kwargs...)
    if _module === ExplicitImports && occursin("reached recursion limit", string(message))
        return nothing
    end
    return Logging.handle_message(l.logger, level, message, _module, group, id, file, line; kwargs...)
end

@testset "ExplicitImports" begin
    # #Internal is dynamically included and cannot be statically analyzed.
    # The package uses non-public Core/Base/Compiler internals throughout, so the
    # two public-ness checks are suppressed.
    # Four Core.Compiler.X accesses (Val, getindex, iterate, specialize_method) refer
    # to distinct objects on Julia 1.10 vs 1.12, so all_qualified_accesses_via_owners
    # is suppressed rather than scattering @static VERSION guards through the source.
    # On 1.14-DEV nightlies `Some(Core.TypeofBottom)` currently throws a MethodError
    # (fallout of the JuliaLang/julia#61915 `Type{}` refactor), which crashes
    # ExplicitImports' `trygetproperty` when it probes the `Core.TypeofBottom`
    # qualified access in src/optimize.jl. Skip until that upstream regression is fixed.
    @static if VERSION < v"1.14.0-DEV"
        with_logger(DropRecursionLimitWarnings(current_logger())) do
            test_explicit_imports(JuliaInterpreter;
                                  ignore                            = (JuliaInterpreter.var"#Internal",),
                                  all_explicit_imports_are_public   = false,
                                  all_qualified_accesses_are_public = false,
                                  all_qualified_accesses_via_owners = false)
        end
    end
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
