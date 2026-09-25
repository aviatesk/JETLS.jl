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
# `@testset` blocks of a document, and `jetls/runTestset` runs one of them and responds
# with the result once the run finishes.

@interface TestsetsParams begin
    """
    The document to list the `@testset` blocks of.
    """
    textDocument::TextDocumentIdentifier
end

"""
A `@testset` block that can be run with the `jetls/runTestset` request.
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
Servers that support this request and `jetls/runTestset` set `testsetsProvider` to
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
end

@interface RunTestsetParams @extends WorkDoneProgressParams begin
    "The document containing the `@testset` to run."
    textDocument::TextDocumentIdentifier

    "The `index` of the `TestsetItem` to run."
    index::Int

    "The `name` of the `TestsetItem` to run."
    name::String
end

"""
The `jetls/runTestset` request is sent from the client to the server to run a
`@testset` block listed by `jetls/testsets` with TestRunner.

The server responds once the run finishes, and cancels the run on `\$/cancelRequest`.
When `workDoneToken` is given, the server reports the run progress on it.
Unlike the `jetls.testrunner.run@testset` command, the server does not show the result
in a message, since the client is expected to present the returned result itself.
"""
@interface RunTestsetRequest @extends RequestMessage begin
    method::String = "jetls/runTestset"
    params::RunTestsetParams
end

@interface RunTestsetResponse @extends ResponseMessage begin
    result::Union{TestRunnerRunResult, Nothing}
end
