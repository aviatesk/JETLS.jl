# Test sets record only their descriptions, not the lines of the `@testset`s they are
# executed from, so the executed test sets are mapped to the `@testset`s in the test file
# by their nesting and descriptions. This mapping is inherently heuristic: sibling
# `@testset`s with the same description are told apart only by their execution order, so
# selectively running a later one reports the line of an earlier one, and descriptions
# consisting only of interpolations (e.g. `@testset "$name"`) are never mapped.

struct SyntacticTestSet
    # `Regex` for descriptions with interpolations, `nothing` when it cannot be matched
    description::Union{Nothing,String,Regex}
    line::Int
    isloop::Bool
    children::Vector{SyntacticTestSet}
end

function syntactic_testsets(text::String, filename::String)
    stream = JS.ParseStream(text)
    JS.parse!(stream; rule=:all)
    isempty(stream.diagnostics) || return nothing
    ex = JS.build_tree(Expr, stream; filename)
    return collect_syntactic_testsets!(SyntacticTestSet[], ex)
end

function collect_syntactic_testsets!(testsets::Vector{SyntacticTestSet}, @nospecialize ex)
    ex isa Expr || return testsets
    if is_function_definition(ex)
        return testsets
    elseif is_testset_macrocall(ex)
        children = SyntacticTestSet[]
        for i = 3:length(ex.args)
            collect_syntactic_testsets!(children, ex.args[i])
        end
        line = (ex.args[2]::LineNumberNode).line
        isloop = Meta.isexpr(ex.args[end], :for)
        push!(testsets, SyntacticTestSet(testset_description(ex), line, isloop, children))
    else
        for arg in ex.args
            collect_syntactic_testsets!(testsets, arg)
        end
    end
    return testsets
end

function is_function_definition(ex::Expr)
    (ex.head === :function || ex.head === :macro) && return true
    ex.head === :(=) || return false
    sig = ex.args[1]
    while Meta.isexpr(sig, :where) || Meta.isexpr(sig, :(::))
        sig = sig.args[1]
    end
    return Meta.isexpr(sig, :call)
end

function is_testset_macrocall(ex::Expr)
    Meta.isexpr(ex, :macrocall) && length(ex.args) ≥ 3 && ex.args[2] isa LineNumberNode ||
        return false
    name = ex.args[1]
    return name === Symbol("@testset") ||
        Meta.isexpr(name, :.) && last(name.args) == QuoteNode(Symbol("@testset"))
end

# Mirrors how `Test.@testset` determines the description of a test set
function testset_description(ex::Expr)
    args = @view ex.args[3:end-1]
    for arg in args
        arg isa String && return arg
        Meta.isexpr(arg, :string) && return interpolated_description(arg)
    end
    body = ex.args[end]
    return Meta.isexpr(body, :call) ? string(body.args[1]) : "test set"
end

function interpolated_description(ex::Expr)
    all(arg -> !(arg isa String), ex.args) && return nothing
    pattern = join(arg isa String ? escape_regex(arg) : ".*" for arg in ex.args)
    return Regex("\\A" * pattern * "\\z")
end

escape_regex(s::String) = replace(s, r"[\\^$.|?*+()\[\]{}]" => s"\\\0")

matches_description(::Nothing, ::String) = false
matches_description(expected::String, description::String) = expected == description
matches_description(expected::Regex, description::String) = occursin(expected, description)

# Test sets are usually executed in their source order, but a test set can be executed
# repeatedly (e.g. in a loop), so search from where the last match was, wrapping around.
# Exact matches are preferred so that a literal description is not matched by the pattern
# of an interpolated description preceding it.
function find_syntactic_testset(
        syntactic::Vector{SyntacticTestSet}, description::String, cursor::Int
    )
    n = length(syntactic)
    for i = 0:n-1
        k = mod1(cursor + i, n)
        syntactic[k].description == description && return k
    end
    for i = 0:n-1
        k = mod1(cursor + i, n)
        matches_description(syntactic[k].description, description) && return k
    end
    return nothing
end

"""
    testset_results(filename::String, source::Union{Nothing,String})

Build the results of the test sets executed at the top level of the last test run with
`TestRunnerTestSet`, identifying the lines of their `@testset`s in `filename`, whose
content is `source` if given.
"""
function testset_results(filename::String, source::Union{Nothing,String})
    root = last_toplevel_testset[]
    root === nothing && return nothing
    text = source === nothing ? (isfile(filename) ? read(filename, String) : nothing) : source
    syntactic = text === nothing ? nothing : syntactic_testsets(text, filename)
    return testset_results(root, syntactic)
end

function testset_results(
        ts::Test.DefaultTestSet, syntactic::Union{Nothing,Vector{SyntacticTestSet}}
    )
    results = TestRunnerTestSetResult[]
    cursor = 1
    for child in ts.results
        child isa Test.DefaultTestSet || continue
        k = syntactic === nothing ? nothing :
            find_syntactic_testset(syntactic, child.description, cursor)
        if syntactic === nothing || k === nothing
            push!(results, testset_result(child, nothing))
        else
            matched = syntactic[k]
            cursor = matched.isloop ? k : k + 1
            push!(results, testset_result(child, matched))
        end
    end
    return results
end

function testset_result(ts::Test.DefaultTestSet, syntactic::Union{Nothing,SyntacticTestSet})
    diagnostics = TestRunnerDiagnostic[]
    for result in ts.results
        result isa Union{Test.Fail,Test.Error} || continue
        push!(diagnostics, testrunner_diagnostic(result))
    end
    return TestRunnerTestSetResult(;
        description = ts.description,
        line = syntactic === nothing ? nothing : syntactic.line,
        stats = testset_stats(ts),
        diagnostics,
        children = testset_results(ts, syntactic === nothing ? nothing : syntactic.children))
end

function testset_stats(ts::Test.DefaultTestSet)
    counts = Test.get_test_counts(ts)
    return TestRunnerStats(;
        n_passed = counts.passes + counts.cumulative_passes,
        n_failed = counts.fails + counts.cumulative_fails,
        n_errored = counts.errors + counts.cumulative_errors,
        n_broken = counts.broken + counts.cumulative_broken,
        duration = testset_duration(ts))
end

function testset_duration(ts::Test.DefaultTestSet)
    time_end = ts.time_end # `nothing` (Julia 1.12) or `0.0` (Julia 1.13+) until finished
    return time_end isa Float64 && time_end > 0 ? time_end - ts.time_start : 0.0
end
