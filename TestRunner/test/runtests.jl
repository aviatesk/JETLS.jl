using Test

@testset "TestRunner.jl" begin
    @testset "pattern matching" include("test_pattern_matching.jl")
    @testset "runtest" include("test_runtest.jl")
    # disable test failure printing from `TestRunnerTestSet`. On Julia 1.14+
    # `Test.TESTSET_PRINT_ENABLE` is a `ScopedValue` rather than a `Ref`, so
    # branch on the type to keep both forms supported.
    @static if Test.TESTSET_PRINT_ENABLE isa Base.ScopedValues.ScopedValue
        Base.ScopedValues.with(Test.TESTSET_PRINT_ENABLE => false) do
            @testset "error handling" include("test_error_handling.jl")
        end
    else
        let default_value = Test.TESTSET_PRINT_ENABLE[]
            Test.TESTSET_PRINT_ENABLE[] = false
            try
                @testset "error handling" include("test_error_handling.jl")
            finally
                Test.TESTSET_PRINT_ENABLE[] = default_value
            end
        end
    end
    @testset "json output" include("test_json_output.jl")
end
