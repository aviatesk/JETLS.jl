using Test

# Custom test set that prints the full testset path on failure (e.g. `outer > middle > leaf:`)
# instead of just the innermost description that `DefaultTestSet` prints. Specify on the
# outermost `@testset` only; nested `@testset` invocations inherit the type via Test.jl's
# `testsettype` propagation.
struct HierarchicalTestSet <: Test.AbstractTestSet
    __hierarchical_testset_inner__::Test.DefaultTestSet
end
HierarchicalTestSet(desc::AbstractString; kws...) =
    HierarchicalTestSet(Test.DefaultTestSet(desc; kws...))

# Duck-typed description lookup for the failure path renderer.
# `Test.AbstractTestSet`'s public protocol is just `record` / `finish` —
# `description` is an internal detail of `DefaultTestSet`, so we can't assume it on
# arbitrary testsets (e.g. `TestRunner.TestRunnerTestSet`).
#
# `HierarchicalTestSet` is detected by the `:__hierarchical_testset_inner__` field name
# rather than by type, because `setup.jl` is included by both `runtests.jl` (in `Main`) and
# each `test_XXX.jl` (inside `module test_XXX`), so `HierarchicalTestSet` ends up defined as
# distinct types per each test module and a single dispatch wouldn't cover both.
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

function Test.record(ts::HierarchicalTestSet, t::Union{Test.Fail, Test.Error};
                     print_result::Bool = Test.TESTSET_PRINT_ENABLE[])
    if print_result
        stack = get(task_local_storage(), :__BASETESTNEXT__, Test.AbstractTestSet[])::Vector{Test.AbstractTestSet}
        printstyled(stdout, "[Testset Path] "; bold=true, color=:light_black)
        n = length(stack)
        for (i,s) in enumerate(stack)
            printstyled(stdout, ts_description(s); bold=true)
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
    push!(ts.__hierarchical_testset_inner__.results, t)
    (Test.FAIL_FAST[] || ts.__hierarchical_testset_inner__.failfast) && throw(Test.FailFastError())
    return t
end
Test.record(ts::HierarchicalTestSet, t) = Test.record(ts.__hierarchical_testset_inner__, t)
Test.finish(ts::HierarchicalTestSet) = Test.finish(ts.__hierarchical_testset_inner__)
