module HierarchicalTestSets

using Test

export HierarchicalTestSet

"""
    HierarchicalTestSet

Custom test set that prints the full testset path on failure (e.g. `outer > middle > leaf:`)
instead of just the innermost description that `DefaultTestSet` prints. Specify on the
outermost `@testset` only; nested `@testset` invocations inherit the type via Test.jl's
`testsettype` propagation.
"""
struct HierarchicalTestSet <: Test.AbstractTestSet
    inner::Test.DefaultTestSet
    path::Vector{String}
end

# `Test.AbstractTestSet`'s public protocol is just `record` / `finish` —
# `description` is an internal detail of `DefaultTestSet`, so we can't assume it on
# arbitrary testsets (e.g. `TestRunner.TestRunnerTestSet`).
# Anything else falls back to the type name so the renderer never crashes on an
# unrecognized wrapping testset.
function ts_path(ts::Test.AbstractTestSet)
    ts isa HierarchicalTestSet && return ts.path
    ts isa Test.DefaultTestSet && return String[ts.description]
    return String[string(typeof(ts))]
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
        path = ts.path
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
                    Test.scrub_backtrace(backtrace(), ts.inner.file, Test.extract_file(t.source)))
                println(io)
            end
            for l in split(s, '\n')
                println(stdout, "  ", l)
            end
        end
    end
    return Test.record(ts.inner, t; print_result=false)
end
Test.record(ts::HierarchicalTestSet, t) = Test.record(ts.inner, t)
Test.finish(ts::HierarchicalTestSet) = Test.finish(ts.inner)

end # module HierarchicalTestSets
