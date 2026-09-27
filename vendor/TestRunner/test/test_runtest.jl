module test_runtest

using Test
using TestRunner
using TestRunner: JS

const TESTFILE = normpath(pkgdir(TestRunner), "test", "testfile.jl")
@test isfile(TESTFILE)

module SimpleRunnerModule end
@testset "simple" begin
    result = @testset "simple runner" runtest(TESTFILE, ("simple",); topmodule=SimpleRunnerModule)
    @test length(result.results) == 1
    @test only(result.results).n_passed == 2
    @test only(only(result.results).results) isa Test.Broken
end

module StandaloneRunnerModule end
@testset "standalone" begin
    result = @testset "standalone runner" runtest(TESTFILE, (:(@test standalone_test_func(π) ≈ 0),); topmodule=StandaloneRunnerModule)
    @test length(result.results) == 0
    @test result.n_passed == 1
end

module IncludeRunnerModule end
@testset "automatic `include` execution" begin
    result = @testset "automatic `include` execution runner" runtest(TESTFILE, (:(@test included_test_func(π) ≈ 0),); topmodule=IncludeRunnerModule)
    @test length(result.results) == 0
    @test result.n_passed == 1
end

module DependencyRunnerModule end
@testset "top-level dependency execution" begin
    # Test that top-level code (const, push!, etc.) is executed even when running specific tests
    result = @testset "dependency execution runner" runtest(TESTFILE, ("dependency execution",); topmodule=DependencyRunnerModule)
    @test length(result.results) == 1
    @test only(result.results).n_passed == 2
end

module ModuleHandlingModule end
let testmodule_file = normpath(pkgdir(TestRunner), "test", "testfile_module.jl")
    @test isfile(testmodule_file)
    result = @testset "module test runner" runtest(testmodule_file, (:(@test sin(0) == 0),); topmodule=ModuleHandlingModule)
    @test result.n_passed == 1
end

module ComplexRunnerModule end
module Nested1RunnerModule end
module Nested2RunnerModule end
module NestedFirst1RunnerModule end
module NestedFirst2RunnerModule end
@testset "nested testsets" begin
    # Test that tests are recorded into the testsets enclosing them
    let result = @testset "complex runner" runtest(TESTFILE, ("complex",); topmodule=ComplexRunnerModule)
        complex = only(result.results)
        @test complex.n_passed == 2
        @test Test.Broken in map(typeof, complex.results)
        nested = filter(r -> r isa Test.DefaultTestSet, complex.results)
        @test [ts.description for ts in nested] == ["nested1", "nested2"]
        @test [ts.n_passed for ts in nested] == [2, 2]
    end

    # Test running a specific nested testset by name:
    # the enclosing testset is run as well, but without its other tests
    let result = @testset "nested1 runner" runtest(TESTFILE, ("nested1",); topmodule=Nested1RunnerModule)
        complex = only(result.results)
        @test complex.description == "complex"
        @test complex.n_passed == 0
        nested1 = only(complex.results)
        @test nested1.description == "nested1"
        @test nested1.n_passed == 2
        @test only(nested1.results) isa Test.Broken
    end

    # Test running another nested testset
    let result = @testset "nested2 runner" runtest(TESTFILE, ("nested2",); topmodule=Nested2RunnerModule)
        complex = only(result.results)
        @test complex.n_passed == 0
        nested2 = only(complex.results)
        @test nested2.description == "nested2"
        @test nested2.n_passed == 2
    end

    # Test running a nested testset that is the first statement of the enclosing testset:
    # `Test.@testset` attributes the code of the enclosing testset to the line of that
    # statement, which must not select the other nested testsets
    let result = @testset "nested first1 runner" runtest(TESTFILE, ("nested first1",); topmodule=NestedFirst1RunnerModule)
        nested_first = only(result.results)
        @test nested_first.description == "nested first"
        @test nested_first.n_passed == 0
        nested_first1 = only(nested_first.results)
        @test nested_first1.description == "nested first1"
        @test nested_first1.n_passed == 1
    end
    let result = @testset "nested first2 runner" runtest(TESTFILE, ("nested first2",); topmodule=NestedFirst2RunnerModule)
        nested_first = only(result.results)
        @test nested_first.n_passed == 0
        nested_first2 = only(nested_first.results)
        @test nested_first2.description == "nested first2"
        @test nested_first2.n_passed == 1
    end
end

module LazyScopedValueRunnerModule end
@static if isdefined(Base.ScopedValues, :LazyScopedValue)
    const LAZY_SCOPED_VALUE = Base.ScopedValues.LazyScopedValue{Bool}(Base.OncePerProcess{Bool}(() -> false))
    @testset "lazy scoped value in scope" begin
        result = Base.ScopedValues.with(LAZY_SCOPED_VALUE => true) do
            @testset "lazy scoped value runner" runtest(TESTFILE, ("nested1",); topmodule=LazyScopedValueRunnerModule)
        end
        nested1 = only(only(result.results).results)
        @test nested1.description == "nested1"
        @test nested1.n_passed == 2
    end
end

module PatternNestedRunnerModule end
@testset "pattern matching in nested" begin
    # Test expression pattern matching within nested testsets
    result = @testset "pattern in nested1 runner" runtest(TESTFILE, (:(@test nestedfunc1(x_) ≈ y_),); topmodule=PatternNestedRunnerModule)
    @test result.n_passed == 0
    nested1 = only(only(result.results).results)
    @test nested1.description == "nested1"
    @test nested1.n_passed == 1
end

module BrokenTestsRunnerModule end
@testset "@test_broken handling" begin
    # Test that @test_broken is properly handled
    result = @testset "broken tests runner" runtest(TESTFILE, ("simple",); topmodule=BrokenTestsRunnerModule)
    @test length(result.results) == 1
    @test only(result.results).n_passed == 2
    @test only(only(result.results).results) isa Test.Broken
end

module SyntaxErrorModule end
@testset "syntax error handling" begin
    # Test that syntax errors in user files are properly reported
    syntax_error_file = normpath(pkgdir(TestRunner), "test", "testfile_syntax_error.jl")
    @test isfile(syntax_error_file)

    @test_throws JS.ParseError runtest(syntax_error_file, ["syntax error test"]; topmodule=SyntaxErrorModule)

    # Verify the error is properly formatted
    io = IOBuffer()
    try
        runtest(syntax_error_file, ["syntax error test"]; topmodule=SyntaxErrorModule)
    catch err
        Base.showerror(io, err)
    end
    s = String(take!(io))
    @test occursin("ParseError", s)
    @test occursin("Expected `]` or `,`", s)
end

module LineFilterModule1 end
module LineFilterModule2 end
@testset "line number based filtering" begin
    # Test that lines argument filters pattern matches correctly
    line_filter_file = normpath(pkgdir(TestRunner), "test", "testfile_line_filter.jl")
    @test isfile(line_filter_file)
    # Without line filter, both tests should match
    let result = @testset "without line filter" runtest(line_filter_file, [:(@test startswith(s, "julia"))]; topmodule=LineFilterModule1)
        @test result.n_passed == 2
    end

    # With line filter specifying line 5, only the first test should run
    let result = @testset "with line filter" runtest(line_filter_file, [:(@test startswith(s, "julia"))]; filter_lines=[5], topmodule=LineFilterModule2)
        @test result.n_passed == 1
    end
end

module LinePatternModule1 end
module LinePatternModule2 end
module LinePatternModule3 end
@testset "line number patterns" begin
    # Test that integer and range patterns work
    line_pattern_file = normpath(pkgdir(TestRunner), "test", "testfile_line_patterns.jl")
    @test isfile(line_pattern_file)

    # Test single line number
    let result = @testset "single line" runtest(line_pattern_file, [4]; topmodule=LinePatternModule1)
        @test result.n_passed == 1  # Only line 4 test
    end

    # Test line range - when selecting lines inside a testset, the whole testset runs
    let result = @testset "line range" runtest(line_pattern_file, [9:15]; topmodule=LinePatternModule2)
        @test length(result.results) == 1
        @test only(result.results).n_passed == 2
    end

    # Test single line number within test set
    let result = @testset "line range" runtest(line_pattern_file, [12]; topmodule=LinePatternModule2)
        @test result.n_passed == 0
        @test only(result.results).n_passed == 1  # The test on line 12 in "math tests"
    end

    # Test combining line numbers with other patterns
    let result = @testset "mixed patterns" runtest(line_pattern_file, ["math tests", 18]; topmodule=LinePatternModule3)
        # "math tests" testset (2 tests) + line 17 standalone test (1 test)
        @test result.n_passed == 1  # The standalone test on line 18
        @test length(result.results) == 1  # The "math tests" testset
        @test only(result.results).n_passed == 2  # Tests in "math tests"
    end
end

# Test local dependency tracking
module DependencyModule1 end
module DependencyModule2 end
let dependency_file = joinpath(@__DIR__, "testfile_dependency_tracking.jl")
    let result = @testset "dependency tracking 1" runtest(dependency_file, [:(@test length(xs1) == 1)]; topmodule=DependencyModule1)
        @test only(result.results).n_passed == 1
    end
    let result = @testset "dependency tracking 2" runtest(dependency_file, [:(@test length(xs2) == 2)]; topmodule=DependencyModule2)
        @test only(result.results).n_passed == 1
    end
end

module IncludedTests1 end
module IncludedTests2 end
let testfile = joinpath(@__DIR__, "testfile_included_tests.jl")
    let result = @testset "included tests 1" runtest(testfile, ["included1"]; topmodule=IncludedTests1)
        included1 = only(only(result.results).results)
        @test included1.description == "included1"
        @test included1.n_passed == 2
    end
    let result = @testset "included tests 2" runtest(testfile, [:(include("_testfile_included2.jl"))]; topmodule=IncludedTests2)
        testset2 = only(only(result.results).results)
        @test testset2.description == "testset 2"
        @test testset2.n_passed == 2
    end
end

module RunTestsModule1 end
module RunTestsModule2 end
module RunTestsModule3 end
@testset "runtests function" begin
    # Test runtests with specific patterns for different files
    let testfile = joinpath(@__DIR__, "testfile_included_tests.jl")
        included1 = joinpath(@__DIR__, "_testfile_included1.jl")
        included2 = joinpath(@__DIR__, "_testfile_included2.jl")

        # Run specific pattern in main file and included file 1
        let result = @testset "runtests specific patterns" runtests(testfile, [
            testfile => ["included1"],
            included1 => [:(@test 1 > 0)]
        ]; topmodule=RunTestsModule1)
            # Should run "included1" testset with one specific test from included1
            @test result.n_passed == 0
            included1_testset = only(only(result.results).results)
            @test included1_testset.description == "included1"
            @test included1_testset.n_passed == 1  # The specific test from included1
        end

        # Run with empty patterns for entry file (no tests) but specific pattern in included file
        let result = @testset "runtests empty entry patterns" runtests(testfile, [
            testfile => [:(include("_testfile_included2.jl"))],
            included2 => ["testset 2"]
        ]; topmodule=RunTestsModule2)
            # Should only run "testset 2" from included2
            testset2 = only(only(result.results).results)
            @test testset2.description == "testset 2"
            @test testset2.n_passed == 2
        end

        # Test with line-based filtering
        let result = @testset "runtests with filter lines" runtests(testfile, [
            testfile => ["included1"]
            included1 => [:(@test 0 == 0.)]
        ], filter_lines_for_files=[
            included1 => [6]  # Only line 6
        ]; topmodule=RunTestsModule3)
            # Should only run the test on line 6
            @test result.n_passed == 0
            included1_testset = only(only(result.results).results)
            @test included1_testset.description == "included1"
            @test included1_testset.n_passed == 1  # The specific test from included1
        end
    end
end

module WorldAgeTest end
@testset "world age issue" begin
    testfile = joinpath(@__DIR__, "testfile_world_age.jl")
    result = @testset "test world age" runtest(testfile, [":(@inferred funcsin(Ref{Any}(42)))"]; topmodule=WorldAgeTest)
    @test true # no exception should be thrown
end

end # module test_runtest
