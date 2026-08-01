using Test

# Custom test set that prints the full testset path on failure (e.g. `outer > middle > leaf:`)
# instead of just the innermost description that `DefaultTestSet` prints. Specify on the
# outermost `@testset` only; nested `@testset` invocations inherit the type via Test.jl's
# `testsettype` propagation.
struct HierarchicalTestSet <: Test.AbstractTestSet
    __hierarchical_testset_inner__::Test.DefaultTestSet
    __hierarchical_testset_path__::Vector{String}
end

# Duck-typed description lookup for the failure path renderer.
# `Test.AbstractTestSet`'s public protocol is just `record` / `finish` —
# `description` is an internal detail of `DefaultTestSet`, so we can't assume it on
# arbitrary testsets (e.g. `TestRunner.TestRunnerTestSet`).
#
# `HierarchicalTestSet` is detected by its field names rather than by type, because
# `setup.jl` is included by both `runtests.jl` (in `Main`) and each `test_XXX.jl`
# (inside `module test_XXX`), so it ends up defined as distinct types per test module.
# Anything else falls back to the type name so the renderer never crashes on an
# unrecognized wrapping testset.
function ts_description(ts::Test.AbstractTestSet)
    if hasfield(typeof(ts), :__hierarchical_testset_inner__) && isdefined(ts, :__hierarchical_testset_inner__)
        inner = ts.__hierarchical_testset_inner__
        inner isa Test.DefaultTestSet && return inner.description
    end
    ts isa Test.DefaultTestSet && return ts.description
    return string(typeof(ts))
end

function ts_path(ts::Test.AbstractTestSet)
    if hasfield(typeof(ts), :__hierarchical_testset_path__) && isdefined(ts, :__hierarchical_testset_path__)
        path = getfield(ts, :__hierarchical_testset_path__)
        path isa Vector{String} && return path
    end
    return String[ts_description(ts)]
end

function HierarchicalTestSet(desc::AbstractString; kws...)
    path = String[]
    if Test.get_testset_depth() != 0
        append!(path, ts_path(Test.get_testset()))
    end
    push!(path, String(desc))
    return HierarchicalTestSet(Test.DefaultTestSet(desc; kws...), path)
end

function Test.record(ts::HierarchicalTestSet, t::Union{Test.Fail, Test.Error};
                     print_result::Bool = Test.TESTSET_PRINT_ENABLE[])
    if print_result
        path = ts.__hierarchical_testset_path__
        printstyled(stdout, "[Testset Path] "; bold=true, color=:light_black)
        n = length(path)
        for (i, desc) in enumerate(path)
            printstyled(stdout, desc; bold=true)
            i == n || printstyled(stdout, " > "; color=:light_black)
        end
        println(stdout)
        if !(t isa Test.Error) || t.test_type !== :test_interrupted
            s = sprint(; context=IOContext(stdout)) do io
                print(io, t)
                t isa Test.Error || Base.show_backtrace(io,
                    Test.scrub_backtrace(backtrace(), ts.__hierarchical_testset_inner__.file, Test.extract_file(t.source)))
                println(io)
            end
            for l in split(s, '\n')
                println(stdout, "  ", l)
            end
        end
    end
    return Test.record(ts.__hierarchical_testset_inner__, t; print_result=false)
end
Test.record(ts::HierarchicalTestSet, t) = Test.record(ts.__hierarchical_testset_inner__, t)
Test.finish(ts::HierarchicalTestSet) = Test.finish(ts.__hierarchical_testset_inner__)
