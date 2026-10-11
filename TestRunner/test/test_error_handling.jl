module test_error_handling

using Test
using TestRunner

# `sin_domain_error`/`cos_domain_error` were replaced by `throw_finite_domainerror`
# on Julia 1.14
const SIN_DOMAIN_ERROR = r"sin_domain_error|throw_finite_domainerror"
const COS_DOMAIN_ERROR = r"cos_domain_error|throw_finite_domainerror"

module ErrorTest end
@testset "Test failure handling" TestRunner.TestRunnerMetaTestSet begin
    testfile = joinpath(@__DIR__, "testfile_error_handling.jl")
    result = try
        @testset TestRunnerTestSet "Test failure testset" runtest(testfile, ["Test failure"]; topmodule=ErrorTest)
    catch e
        e
    end
    @test result isa Test.DefaultTestSet # testset for `TestRunnerMetaTestSet`
    counts = Test.get_test_counts(result)
    @test counts.cumulative_fails == 1
    @test counts.cumulative_passes == counts.cumulative_broken == counts.cumulative_errors == 0
    @test length(result.results) == 1
    results1 = only(result.results)
    @test results1 isa Test.DefaultTestSet # testset for `TestRunnerTestSet`
    @test length(results1.results) == 1
    results11 = only(results1.results)
    @test results11 isa Test.Fail
    @test results11.orig_expr == "sin(0) == π"
    @test results11.test_type === :test
end

module ExceptionTest1 end
@testset "Exception handling 1" TestRunner.TestRunnerMetaTestSet begin
    testfile = joinpath(@__DIR__, "testfile_error_handling.jl")
    result = try
        @testset TestRunnerTestSet "Exception handling testset 1" runtest(testfile, ["Exception inside of `@test` 1"]; topmodule=ExceptionTest1)
    catch e
        e
    end
    @test result isa Test.DefaultTestSet # testset for `TestRunnerMetaTestSet`
    counts = Test.get_test_counts(result)
    @test counts.cumulative_passes == counts.cumulative_errors == 1
    @test counts.cumulative_broken == counts.cumulative_fails == 0
    @test length(result.results) == 1
    results1 = only(result.results)
    @test results1 isa Test.DefaultTestSet # testset for `TestRunnerTestSet`
    @test length(results1.results) == 1
    results11 = only(results1.results)
    @test results11 isa Test.Error
    @test results11.orig_expr == "sin(Inf) == π"
    @test results11.test_type === :test_error
    @test occursin("DomainError with Inf", sprint(show, results11))
    @test occursin(SIN_DOMAIN_ERROR, results11.backtrace)
end

module ExceptionTest2 end
@testset "Exception handling 2" TestRunner.TestRunnerMetaTestSet begin
    testfile = joinpath(@__DIR__, "testfile_error_handling.jl")
    result = try
        @testset TestRunnerTestSet "Exception handling testset 2" runtest(testfile, ["Exception inside of `@test` 2"]; topmodule=ExceptionTest2)
    catch e
        e
    end
    @test result isa Test.DefaultTestSet # testset for `TestRunnerMetaTestSet`
    counts = Test.get_test_counts(result)
    @test counts.cumulative_passes == counts.cumulative_errors == 1
    @test counts.cumulative_broken == counts.cumulative_fails == 0
    @test length(result.results) == 1
    results1 = only(result.results)
    @test results1 isa Test.DefaultTestSet # testset for `TestRunnerTestSet`
    @test length(results1.results) == 1
    results11 = only(results1.results)
    @test results11 isa Test.Error
    @test results11.orig_expr == "funccall(cos, Inf) == π"
    @test results11.test_type === :test_error
    @test occursin("DomainError with Inf", sprint(show, results11))
    @test occursin(COS_DOMAIN_ERROR, results11.backtrace)
end

module ExceptionTest3 end
@testset "Exception handling 3" TestRunner.TestRunnerMetaTestSet begin
    testfile = joinpath(@__DIR__, "testfile_error_handling.jl")
    result = try
        @testset TestRunnerTestSet "Exception handling testset 3" runtest(testfile, ["Exception outside of `@test`"]; topmodule=ExceptionTest3)
    catch e
        e
    end
    @test result isa Test.DefaultTestSet # testset for `TestRunnerMetaTestSet`
    counts = Test.get_test_counts(result)
    @test counts.cumulative_errors == 1
    @test counts.cumulative_broken == counts.cumulative_passes == counts.cumulative_fails == 0
    @test length(result.results) == 1
    results1 = only(result.results)
    @test results1 isa Test.DefaultTestSet # testset for `TestRunnerTestSet`
    @test length(results1.results) == 1
    results11 = only(results1.results)
    @test results11 isa Test.Error
    @test results11.test_type === :nontest_error
    # the exception itself should be recorded, not the `rethrow` re-raising it
    @test startswith(results11.value, "DomainError")
    @test occursin("DomainError with Inf", sprint(show, results11))
    @test occursin(SIN_DOMAIN_ERROR, results11.backtrace)
    @test !occursin("caused by", results11.backtrace)
end

module ExceptionTest4 end
@testset "Exception handling 4" TestRunner.TestRunnerMetaTestSet begin
    testfile = joinpath(@__DIR__, "testfile_error_handling.jl")
    result = try
        @testset TestRunnerTestSet "Exception handling testset 4" runtest(testfile, ["Exception outside of `@testset`"]; topmodule=ExceptionTest4)
    catch e
        e
    end
    @test result isa Test.DefaultTestSet # testset for `TestRunnerMetaTestSet`
    counts = Test.get_test_counts(result)
    @test counts.cumulative_errors == 1
    @test counts.cumulative_broken == counts.cumulative_passes == counts.cumulative_fails == 0
    @test length(result.results) == 1
    results1 = only(result.results)
    @test results1 isa Test.DefaultTestSet # testset for `TestRunnerTestSet`
    @test length(results1.results) == 1
    results11 = only(results1.results)
    @test results11 isa Test.Error
    @test results11.test_type === :test_error
    @test occursin("DomainError with Inf", sprint(show, results11))
    @test occursin(SIN_DOMAIN_ERROR, results11.backtrace)
end

module ParseErrorTest end
@testset "Errors outside of the interpreter" TestRunner.TestRunnerMetaTestSet begin
    testfile = joinpath(@__DIR__, "testfile_syntax_error.jl")
    result = try
        @testset TestRunnerTestSet "Parse error testset" runtest(testfile, ["syntax error test"]; topmodule=ParseErrorTest)
    catch e
        e
    end
    @test result isa Test.DefaultTestSet # testset for `TestRunnerTestSet`
    counts = Test.get_test_counts(result)
    @test counts.errors == 1
    @test counts.broken == counts.passes == counts.fails == 0
    @test length(result.results) == 1
    results1 = only(result.results)
    @test results1 isa Test.Error
    @test results1.test_type === :nontest_error
    # the interpreter has not recorded any exception, so the original backtrace is kept
    @test occursin("ParseError", results1.backtrace)
    @test occursin("ParseError", sprint(show, results1))
end

end # module test_error_handling
