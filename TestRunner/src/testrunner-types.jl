struct TestRunnerDiagnosticRelatedInformation
    filename::String
    line::Int
    message::String
end

"""
    TestRunnerDiagnostic

Represents a single test diagnostic (failure or error) with minimal information
needed for language server integration.

# Fields
- `filename::String`: Full path to the test file
- `line::Int`: Line number where the test failed/errored (1-based)
- `message::String`: Descriptive message including the original expression and error details
"""
struct TestRunnerDiagnostic
    filename::String
    line::Int
    message::String
    relatedInformation::Union{Nothing,Vector{TestRunnerDiagnosticRelatedInformation}}
end

"""
    TestRunnerStats

Represents the statistical summary of a test run, including counts of different
test outcomes and execution timing information.
"""
@kwdef struct TestRunnerStats
    "Number of tests that passed"
    n_passed::Int = 0
    "Number of tests that failed"
    n_failed::Int = 0
    "Number of tests that errored"
    n_errored::Int = 0
    "Number of tests marked as broken"
    n_broken::Int = 0
    "Test execution time in seconds"
    duration::Float64 = 0.0
end

"""
    TestRunnerTestSetResult

Represents the result of a test set executed in a test run, along with the results of
the test sets nested in it.
"""
@kwdef struct TestRunnerTestSetResult
    "Description of the test set"
    description::String
    """
    Line of the `@testset` in the test file that the test set was executed from (1-based),
    or `nothing` when it cannot be identified (e.g. for test sets in `include`d files)
    """
    line::Union{Nothing,Int} = nothing
    "Test counts, including those of the nested test sets"
    stats::TestRunnerStats
    "Test failures and errors recorded directly in this test set"
    diagnostics::Vector{TestRunnerDiagnostic} = TestRunnerDiagnostic[]
    "Results of the test sets nested in this test set, in the order of execution"
    children::Vector{TestRunnerTestSetResult} = TestRunnerTestSetResult[]
end

"""
    TestRunnerResult

Represents the complete result of a test run in JSON format.
`testsets` holds the results of the test sets executed at the top level of the test file,
and is reported only for test runs with patterns.
"""
@kwdef struct TestRunnerResult
    filename::String
    patterns::Union{Vector{Any}, Nothing} = nothing
    stats::TestRunnerStats
    logs::String = ""
    diagnostics::Vector{TestRunnerDiagnostic} = TestRunnerDiagnostic[]
    testsets::Union{Nothing,Vector{TestRunnerTestSetResult}} = nothing
end
