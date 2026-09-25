# TestRunner integration
# ======================
#
# JETLS-specific protocol extensions for running tests with TestRunner.jl
# (https://github.com/aviatesk/TestRunner.jl).
#
# Code lenses and code actions run tests through the `jetls.testrunner.run@testset` and
# `jetls.testrunner.run@test` commands, which respond immediately and report the outcome
# via work done progress, messages, and diagnostics.
# The requests defined here instead let clients build their own test UI on top of the same
# integration (e.g. with VSCode's Testing API): `jetls/testsets` lists the runnable
# `@testset` blocks of a document, and `jetls/runTestsets` runs some of them and responds
# with the results of the individual `@testset`s once the run finishes.

@interface TestsetsParams begin
    """
    The document to list the `@testset` blocks of.
    """
    textDocument::TextDocumentIdentifier
end

"""
A `@testset` block that can be run with the `jetls/runTestsets` request.
"""
@interface TestsetItem begin
    "The 1-based index of this `@testset` within the document."
    index::Int

    """
    The source text of the `@testset` description, including the quotes of string
    literals (e.g. `"\\"foo\\""`).
    """
    name::String

    """
    The range of the whole `@testset` macro call.
    """
    range::Range
end

"""
The `jetls/testsets` request is sent from the client to the server to list the
`@testset` blocks of a text document that can be run with TestRunner.
Servers that support this request and `jetls/runTestsets` set `testsetsProvider` to
`true` in the `experimental` field of their server capabilities.
"""
@interface TestsetsRequest @extends RequestMessage begin
    method::String = "jetls/testsets"
    params::TestsetsParams
end

@interface TestsetsResponse @extends ResponseMessage begin
    result::Union{Vector{TestsetItem}, Null, Nothing}
end

@namespace TestRunnerRunStatus::String begin
    "TestRunner finished running the tests, although some of them may have failed."
    Completed = "completed"
    "The run was cancelled before TestRunner finished."
    Cancelled = "cancelled"
    "The tests could not be run, or TestRunner failed without reporting results."
    Errored = "errored"
end

@interface TestRunnerRunStats begin
    passed::Int
    failed::Int
    errored::Int
    broken::Int
    "The test execution time in seconds."
    duration::Float64
end

@interface TestRunnerRunFailure begin
    "The location of the failed or errored test."
    location::Location
    message::String
    relatedInformation::Union{Nothing, Vector{DiagnosticRelatedInformation}} = nothing
end

@interface TestsetRunResult begin
    "The `index` of the `TestsetItem` of the `@testset`."
    index::Int

    """
    The test counts of the `@testset`, including those of the `@testset`s nested in it.
    The counts are summed up when the `@testset` was executed multiple times (e.g. in a
    loop).
    """
    stats::TestRunnerRunStats

    "Failures and errors in the `@testset`, including those in the nested `@testset`s."
    failures::Vector{TestRunnerRunFailure}
end

@interface TestRunnerRunResult begin
    status::TestRunnerRunStatus.Ty

    """
    A human-readable summary of the run, e.g. the test counts for completed runs,
    or the reason why the run did not complete.
    """
    message::String

    "Set when `status` is `completed`."
    stats::Union{Nothing, TestRunnerRunStats} = nothing

    "Set when `status` is `completed`."
    failures::Union{Nothing, Vector{TestRunnerRunFailure}} = nothing

    "The output of the tests. Set when `status` is `completed`."
    logs::Union{Nothing, String} = nothing

    """
    The results of the individual `@testset`s executed in the run, including the ones
    nested in the requested `@testset`s. Set when `status` is `completed`.
    """
    testsets::Union{Nothing, Vector{TestsetRunResult}} = nothing
end

@interface TestsetIdentifier begin
    "The `index` of the `TestsetItem`."
    index::Int

    "The `name` of the `TestsetItem`."
    name::String
end

@interface RunTestsetsParams @extends WorkDoneProgressParams begin
    "The document containing the `@testset`s to run."
    textDocument::TextDocumentIdentifier

    "The `@testset`s to run."
    testsets::Vector{TestsetIdentifier}
end

"""
The `jetls/runTestsets` request is sent from the client to the server to run `@testset`
blocks listed by `jetls/testsets` with TestRunner, all in a single test run.

The server responds once the run finishes, and cancels the run on `\$/cancelRequest`.
When `workDoneToken` is given, the server reports the run progress on it.
Unlike the `jetls.testrunner.run@testset` command, the server does not show the result
in a message, since the client is expected to present the returned result itself.
"""
@interface RunTestsetsRequest @extends RequestMessage begin
    method::String = "jetls/runTestsets"
    params::RunTestsetsParams
end

@interface RunTestsetsResponse @extends ResponseMessage begin
    result::Union{TestRunnerRunResult, Nothing}
end
