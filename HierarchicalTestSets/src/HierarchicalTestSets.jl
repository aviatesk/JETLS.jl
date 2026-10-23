module HierarchicalTestSets

using Test

export HierarchicalTestSet

"""
    HierarchicalTestSet

Custom test set that prints the full testset path on failure (e.g. `outer > middle > leaf:`)
instead of just the innermost description that `DefaultTestSet` prints. Specify on the
outermost `@testset` only; nested `@testset` invocations inherit the type via Test.jl's
`testsettype` propagation.

With the `progress=true` option, e.g. `@testset HierarchicalTestSet "outer" progress=true`,
the path of each direct child testset is printed when it starts, and its result is appended
with its duration when it finishes: `passed` in green, or `failed` in red when it has
failures or errors.
"""
struct HierarchicalTestSet <: Test.AbstractTestSet
    inner::Test.DefaultTestSet
    path::Vector{String}
    progress::Bool
    reported::Bool
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

function HierarchicalTestSet(desc::AbstractString; progress::Bool = false, kws...)
    path = String[]
    reported = false
    if Test.get_testset_depth() != 0
        parent = Test.get_testset()
        append!(path, ts_path(parent))
        reported = parent isa HierarchicalTestSet && parent.progress
    end
    push!(path, String(desc))
    ts = HierarchicalTestSet(Test.DefaultTestSet(desc; kws...), path, progress, reported)
    if reported
        close_progress_line!()
        print_progress_path(ts)
        OPEN_PROGRESS_LINE[] = ts
    end
    return ts
end

# The reported testset whose path ends the current line, waiting for its result
const OPEN_PROGRESS_LINE = Ref{Union{Nothing,HierarchicalTestSet}}(nothing)

print_progress_path(ts::HierarchicalTestSet) =
    printstyled(stdout, "[", join(ts.path, " > "), "]"; color=:light_black)

function close_progress_line!()
    OPEN_PROGRESS_LINE[] === nothing && return
    println(stdout)
    OPEN_PROGRESS_LINE[] = nothing
end

function Test.record(ts::HierarchicalTestSet, t::Union{Test.Fail, Test.Error};
                     print_result::Bool = Test.TESTSET_PRINT_ENABLE[])
    if print_result
        close_progress_line!()
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
function Test.finish(ts::HierarchicalTestSet)
    if ts.reported
        duration = round(time() - ts.inner.time_start; digits=1)
        tc = Test.get_test_counts(ts.inner)
        failed = tc.fails + tc.errors + tc.cumulative_fails + tc.cumulative_errors > 0
        status, color = failed ? ("failed", :red) : ("passed", :green)
        if OPEN_PROGRESS_LINE[] !== ts
            close_progress_line!()
            print_progress_path(ts)
        end
        OPEN_PROGRESS_LINE[] = nothing
        print(stdout, ' ')
        printstyled(stdout, status, " ($(duration)s)"; color)
        println(stdout)
    end
    return Test.finish(ts.inner)
end

end # module HierarchicalTestSets
