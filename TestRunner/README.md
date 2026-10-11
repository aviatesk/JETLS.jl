# TestRunner.jl

[![](https://github.com/aviatesk/JETLS.jl/actions/workflows/TestRunner.jl.yml/badge.svg)](https://github.com/aviatesk/JETLS.jl/actions/workflows/TestRunner.jl.yml)
[![](https://codecov.io/gh/aviatesk/JETLS.jl/branch/master/graph/badge.svg?flag=TestRunner.jl)](https://codecov.io/gh/aviatesk/JETLS.jl&flags[0]=TestRunner.jl)

A Julia package for selective test execution using pattern matching.
TestRunner allows you to run specific tests from a test file based on testset
names, test expressions, or line numbers, while ensuring all necessary
dependencies are executed.

TestRunner is developed as a subpackage of
[JETLS.jl](https://github.com/aviatesk/JETLS.jl), which bundles it for its
[TestRunner integration](https://aviatesk.github.io/JETLS.jl/release/testrunner/).

## Features

- **Pattern-based test selection**: Run only the tests that match your
  specified patterns
- **Multiple pattern types**: String matching, regex patterns, expression,
   and line number patterns.
- **Fast execution**: Test code is interpreted only at top-level; function
  calls within tests are compiled normally while avoiding execution of unrelated
  test code
- **JSON output**: Machine-readable test results with diagnostics for integration
  with editors and CI systems

## Requirements

- Julia 1.12 or higher

## Installation

### As a CLI application (recommended)

Install from the `release` branch of JETLS.jl, which has vendored dependencies
to avoid conflicts with your project's packages:

```bash
julia -e 'using Pkg; Pkg.Apps.add(; url="https://github.com/aviatesk/JETLS.jl", subdir="TestRunner", rev="release")'
```

This installs the `testrunner` executable. Make sure `~/.julia/bin` is in your
`PATH`. See <https://pkgdocs.julialang.org/dev/apps/> for details.

Only the dependencies of TestRunner are vendored, and TestRunner itself keeps
its package identity. To run the tests of an environment that depends on
TestRunner, e.g. JETLS itself, use the TestRunner of that environment with
[`julia -m TestRunner`](#running-via-julia--m-testrunner) instead of the
`testrunner` executable, since they would conflict with each other.

### As a package

For [programmatic usage](#programmatic-usage) within Julia:

```julia
using Pkg
Pkg.add(; url="https://github.com/aviatesk/JETLS.jl", subdir="TestRunner")
```

## Quick start

With the [demo.jl](./demo.jl) file shown in the [examples](#examples):

```bash
# Run the testset named "basic tests"
testrunner demo.jl "basic tests"

# Run multiple testsets
testrunner demo.jl "basic tests" "struct tests"

# Run the tests matching an expression pattern
testrunner demo.jl ':(@test startswith(inner_func2(), "inner"))'

# Run the tests on lines 55-57
testrunner demo.jl L55:57
```

## Usage

```
testrunner [options] <path> [patterns...]
testrunner [julia options] -- [options] <path> [patterns...]
```

TestRunner runs the tests in `<path>` that match any of the given patterns,
along with the other code they need (see [How it works](#how-it-works)).
Without patterns, it runs all the tests in `<path>`.
It exits with status 1 when any test fails or errors.

### Patterns

| Pattern     | Runs                                                                  |
|-------------|-----------------------------------------------------------------------|
| `my tests`  | the `@testset`s named exactly `my tests` (the default)                |
| `r"regex"`  | the `@testset`s whose names match the regex                           |
| `:(expr)`   | the code matching `expr` as a [MacroTools.jl](https://github.com/FluxML/MacroTools.jl) pattern |
| `L10`       | the code on line 10                                                   |
| `L10:20`    | the code on lines 10-20                                               |

Quote patterns so that the shell passes them to TestRunner as they are,
including the quotes of regex patterns:

```bash
# Run the testsets whose names contain "basic"
testrunner test/runtests.jl 'r"basic"'

# Run the tests comparing a call to `foo` with something,
# e.g. `@test foo(x) == 1`
testrunner test/runtests.jl ':(@test foo(x_) == y_)'
```

### Options

- `--filter-lines=1,5,10:20`, `-f=1,5,10:20`: Run only the matches of the
  patterns that overlap the given lines. This is useful for editor
  integrations, where running a specific test should run only that test even
  when other tests match the same pattern
- `--verbose`, `-v`: Show the Julia version, the parsed patterns, and the
  results of each test set
- `--json`: Output results in JSON format for machine-readable test results.
  When patterns are given, the results of the individual test sets are included
  as well, along with the lines of their `@testset`s
- `--read-stdin`: Read source for the given file path from stdin instead of disk.
  The path is still used for `@__FILE__`, error messages, and resolving `include`d files
- `--root-path=<dir>`: Base directory for relative `include` paths when the
  given path has no directory, e.g. when it names an unsaved editor buffer
  read with `--read-stdin`
- `--project[=<dir>]`: **Deprecated**: pass `--project` to Julia before `--`
  instead, e.g. `testrunner --project=test -- test/runtests.jl`
- `--help`, `-h`: Show the help message

```bash
# Combine patterns with filter lines
testrunner test/runtests.jl "my tests" --filter-lines=10,15,20:25

# Output results in JSON format
testrunner --json test/runtests.jl "my tests"

# Read source from stdin (e.g. an unsaved editor buffer); the file path is
# still needed for `@__FILE__` and to resolve any `include`d files
cat my-edits.jl | testrunner --read-stdin --json test/runtests.jl "my tests"
```

### Julia options

Arguments before `--` go to Julia, e.g. to select the project environment of
the tests or to run them with multiple threads:

```bash
testrunner --project=test -- test/runtests.jl "my tests"
testrunner --threads=4 -- test/runtests.jl "my tests"
```

Without `--`, all arguments go to TestRunner.

### Running via `julia -m TestRunner`

The `testrunner` executable is a thin shim around `julia -m TestRunner`, so
TestRunner can also run from any environment that has it as a dependency:

```bash
julia --project=test -m TestRunner test/runtests.jl "my tests"
```

Julia options such as `--project` go before `-m`, and everything after the
module name goes to TestRunner. `-m` resolves `TestRunner` by name from the
load path, so when TestRunner lives in a different environment from the tests,
add that environment to `JULIA_LOAD_PATH`:

```bash
JULIA_LOAD_PATH=/path/to/env julia --project=test -m TestRunner test/runtests.jl "my tests"
```

TestRunner resets `LOAD_PATH` to Julia's defaults before running the tests, so
the extra entry only affects how TestRunner itself is loaded.

## Examples

Given this [demo.jl](./demo.jl) file:

> demo.jl
```julia
using Test

struct MyStruct
    value::Int
end

function process(s::MyStruct)
    return s.value * 2
end

@testset "basic tests" begin
    @test 1 + 1 == 2
    @test 2 * 2 == 4
    @test_broken 1 + 1 == 3  # This is expected to fail
end

@testset "struct tests" begin
    s = MyStruct(5)
    @test process(s) == 10
    @test s.value == 5
end

# Standalone test
@test process(MyStruct(3)) == 6

@testset "nested tests" begin
    outer_func() = "outer"
    @test outer_func() == "outer"

    @testset "inner tests 1" begin
        inner_func1() = "inner1"
        @test inner_func1() == "inner1"
        @test length(inner_func1()) == 6
    end

    @testset "inner tests 2" begin
        inner_func2() = "inner2"
        @test inner_func2() == "inner2"
        @test startswith(inner_func2(), "inner")
    end
end

@testset "calculator tests" begin
    add(a, b) = a + b
    mul(a, b) = a * b

    @test add(2, 3) == 5    # line 55
    @test mul(3, 4) == 12   # line 56
    @test add(10, 20) == 30 # line 57
end

# More standalone tests
@test 100 - 50 == 50  # line 61
@test sqrt(16) == 4    # line 62

@testset "Test failure" begin
    @test sin(0) == π
end

@testset "Exception inside of `@test`" begin
    @test sin(Inf) == π
    @test sin(0) == 0
    @test cos(Inf) == π
end

@testset "Exception outside of `@test`" begin
    v = sin(Inf)
    @test v == π
    @test @isdefined v # not executed
end
```

The examples below use `-v` to show the results of each test set, and omit
the Julia version and the parsed patterns that it also shows.

Run `@testset "basic tests"`:
```console
$ testrunner -v demo.jl "basic tests"
Test Summary: | Pass  Broken  Total  Time
demo.jl       |    2       1      3  0.2s
  basic tests |    2       1      3  0.0s
```

`@testset` can be selected with regex:
```console
$ testrunner -v demo.jl 'r".*tests"'
Test Summary:      | Pass  Broken  Total  Time
demo.jl            |   12       1     13  0.2s
  basic tests      |    2       1      3  0.0s
  struct tests     |    2              2  0.0s
  nested tests     |    5              5  0.0s
  calculator tests |    3              3  0.0s
```

Run individual `@test` cases that use the `process` function:
```console
$ testrunner -v demo.jl ':(@test process(s_) == n_)'
Test Summary:  | Pass  Total  Time
demo.jl        |    2      2  0.2s
  struct tests |    1      1  0.0s
```

Nested `@testset` can be selected:
```console
$ testrunner -v demo.jl "inner tests 1"
Test Summary:  | Pass  Total  Time
demo.jl        |    2      2  0.2s
  nested tests |    2      2  0.0s
```

Selected tests run within their enclosing `@testset`s, so their results are
recorded in the same test set hierarchy as when the whole file is run.
Other tests of the enclosing `@testset`s (e.g. the other tests of
`@testset "nested tests"` above) are not run.

Individual `@test` cases can be selectively matched using pattern expressions:
```console
$ testrunner -v demo.jl ':(@test startswith(s_, prefix_))'
Test Summary:  | Pass  Total  Time
demo.jl        |    1      1  0.2s
  nested tests |    1      1  0.0s
```

We can run tests by directly specifying line numbers:
```console
$ testrunner -v demo.jl L56 # Run only the test on line 56
Test Summary:      | Pass  Total  Time
demo.jl            |    1      1  0.2s
  calculator tests |    1      1  0.0s

$ testrunner -v demo.jl L55:57 # Run tests in lines 55-57
Test Summary:      | Pass  Total  Time
demo.jl            |    3      3  0.2s
  calculator tests |    3      3  0.0s

$ testrunner -v demo.jl "calculator tests" L61 # Combine named testsets with line numbers
Test Summary:      | Pass  Total  Time
demo.jl            |    4      4  0.2s
  calculator tests |    3      3  0.0s
```

### Test failures and errors

When tests fail or error, TestRunner reports them with the full exception
information and exits with status 1:

```console
$ testrunner demo.jl "Test failure"
ERROR: Some tests did not pass: 0 passed, 1 failed, 0 errored, 0 broken.

Test failure: Test Failed at /path/to/demo.jl:68
  Expression: sin(0) == π
   Evaluated: 0.0 == π
  Stacktrace:
  ...
Test Summary:  | Fail  Total  Time
demo.jl        |    1      1  1.1s
  Test failure |    1      1  1.0s
```

```console
$ testrunner demo.jl 'Exception inside of `@test`'
ERROR: Some tests did not pass: 1 passed, 0 failed, 2 errored, 0 broken.

Exception inside of `@test`: Error During Test at /path/to/demo.jl:72
  Test threw exception
  Expression: sin(Inf) == π
  DomainError with Inf:
  sin(x) is only defined for finite x.
  Stacktrace:
   [1] sin_domain_error(x::Float64)
     @ Base.Math ./special/trig.jl:28
   [2] sin(x::Float64)
     @ Base.Math ./special/trig.jl:39
  ...

Exception inside of `@test`: Error During Test at /path/to/demo.jl:74
  Test threw exception
  Expression: cos(Inf) == π
  DomainError with Inf:
  cos(x) is only defined for finite x.
  Stacktrace:
   [1] cos_domain_error(x::Float64)
     @ Base.Math ./special/trig.jl:97
   [2] cos(x::Float64)
     @ Base.Math ./special/trig.jl:108
  ...
Test Summary:                 | Pass  Error  Total  Time
demo.jl                       |    1      2      3  0.9s
  Exception inside of `@test` |    1      2      3  0.8s
```

An exception outside of a `@test` stops the rest of its `@testset`:
```console
$ testrunner demo.jl 'Exception outside of `@test`'
ERROR: Some tests did not pass: 0 passed, 0 failed, 1 errored, 0 broken.

Exception outside of `@test`: Error During Test at /path/to/demo.jl:77
  Got exception outside of a @test
  DomainError with Inf:
  sin(x) is only defined for finite x.
  Stacktrace:
   [1] sin_domain_error(x::Float64)
     @ Base.Math ./special/trig.jl:28
   [2] sin(x::Float64)
     @ Base.Math ./special/trig.jl:39
  ...
Test Summary:                  | Error  Total  Time
demo.jl                        |     1      1  0.9s
  Exception outside of `@test` |     1      1  0.7s
```

## Programmatic usage

### `runtest`

```julia
runtest(filename::AbstractString, patterns;
        filter_lines=nothing, topmodule::Module=Main, source=nothing)
```

Run tests from a file that match the given patterns and/or are on the
specified lines.

**Arguments:**
- `filename::AbstractString`: Path to the test file
- `patterns`: Patterns to match. Can be strings, regexes, expressions, integers (line numbers),
  or ranges (line ranges); see [Pattern values](#pattern-values)
- `filter_lines=nothing`: Optional line numbers to filter pattern matches. When provided, only
  pattern matches that overlap with these lines will be executed, like `--filter-lines`
- `topmodule::Module=Main`: Module context for execution (default: `Main`)
- `source::Union{Nothing,AbstractString}=nothing`: When provided, use this source text for the
  entry file instead of reading it from disk, like `--read-stdin`. `filename` is still used for
  `@__FILE__`, error messages, and resolving paths of `include`d files

**Returns:**
- Test results from the selectively executed tests

### `runtests`

```julia
runtests(entryfilename::AbstractString, patterns;
         filter_lines=nothing, topmodule::Module=Main, source=nothing)
```

The package also provides a `runtests` function for advanced use cases like
selectively running package test cases from `test/runtests.jl`, where
you need to specify different patterns for different files in a test suite
that includes multiple files via `include` statements.
See its docstring for detailed usage.

### Pattern values

The patterns of `runtest` and `runtests` are the Julia values that the
[patterns of the CLI](#patterns) represent:

| CLI         | Julia value     |
|-------------|-----------------|
| `my tests`  | `"my tests"`    |
| `r"regex"`  | `r"regex"`      |
| `:(expr)`   | `:(expr)`       |
| `L10`       | `10`            |
| `L10:20`    | `10:20`         |

```julia
runtest("demo.jl", ["basic tests", "struct tests"])
runtest("demo.jl", [r".*tests"])
runtest("demo.jl", [:(@test startswith(s_, prefix_))])
runtest("demo.jl", ["calculator tests", 61])
```

### `TestRunnerTestSet`

Since `runtest` and `runtests` execute Test.jl code using JuliaInterpreter,
they cannot directly utilize the test failure handling provided by Test.jl.

Therefore, this package implements a custom `@testset` type called `TestRunnerTestSet`.
When `runtest[s]` is executed within `@testset TestRunnerTestSet`,
you get equivalent test failure handling to Test.jl.
For programmatic usage, it can be used specifically in the following way:
```julia
using Test, TestRunner
@testset TestRunnerTestSet runtest("mytest.jl", ["my tests"])
```

**It is recommended to always use `runtest[s]` together with `@testset TestRunnerTestSet` as shown above.**

`TestRunnerTestSet` is automatically used in the [`testrunner` app](#usage),
which shows the [full exception information](#test-failures-and-errors).
With `Test.DefaultTestSet`, the exceptions thrown inside and outside of `@test`
are reported without it:

```julia-repl
julia> @testset verbose=true runtest("demo.jl", ["Exception inside of `@test`"]);
Exception inside of `@test`: Error During Test at /path/to/demo.jl:72
  Test threw exception
  Expression: sin(Inf) == π

Exception inside of `@test`: Error During Test at /path/to/demo.jl:74
  Test threw exception
  Expression: cos(Inf) == π
...

julia> @testset verbose=true runtest("demo.jl", ["Exception outside of `@test`"]);
Exception outside of `@test`: Error During Test at /path/to/demo.jl:77
  Got exception outside of a @test
...
```

## How it works

TestRunner leverages JuliaInterpreter and LoweredCodeUtils to selectively
execute test code:

1. Pattern Matching on AST: Uses JuliaSyntax to parse code and MacroTools
   to match patterns against the syntax tree
2. Line-based Selection: Maps matched AST nodes to source line numbers,
   which serve as the bridge to lowered code
3. Selective Interpretation: Only top-level code is interpreted;
   function calls within tests are compiled and run at normal speed
4. Conservative Dependency Execution: Executes _all_ code except unmatched
   tests (`@test`, `@testset`, etc.) to ensure tests don't fail due to
   missing dependencies. This covers top-level code as well as the code
   around tests nested in other code, e.g. in `let` blocks and in the
   testsets enclosing matched code, since the effects of such code, e.g.
   definitions loaded by `include` or changes to global state, can't be
   tracked. Only the code using what unmatched tests compute, e.g. their
   results, is skipped along with them:
   ```julia
   @testset "outer" begin
       setup()                  # runs
       @testset "a" begin       # skipped when only "b" is matched
           @test f() == 1
       end
       @testset "b" begin       # matched
           @test g() == 2
       end
       result = @testset "c" begin  # skipped
           @test h() == 3
       end
       report(result)           # skipped, since it uses the result of "c"
   end
   ```
5. Recursive Inclusion: Files included by matched code, e.g. by
   `@testset "name" include("file.jl")`, are executed entirely. Files
   included by the other executed code, including `include` calls in the
   testsets enclosing matched code, only have their non-test top-level code
   executed, like the conservative dependency execution above

The key insight is that in reasonably-organized test code, the conservative
dependency execution would only run the function and type definitions necessary
for tests, without actual test code executed. Since test execution bottlenecks
are often in the test cases themselves (not in defining functions), TestRunner
allows efficient execution of test cases in interest by skipping execution of
unrelated tests while still ensuring all code dependencies are available.

## Limitations

1. **Source Provenance**: Pattern matching occurs at the surface AST level and
   results are converted to line numbers. However, lowered code representation
   lacks proper source provenance (especially for macro expansions), causing
   surface-level pattern match information to be incorrectly mapped to lowered
   code.

   Example (from [limitation1.jl](./limitations/limitation1.jl)):
   ```julia
   @testset "limitation1" begin
       limitation1() = nothing
       @test isnothing(limitation1()) #=want to run only this=#; @test isnothing(identity(limitation1())) #=but this runs too=#
   end
   ```

   When trying to run only the first test:
   ```console
   $ testrunner -v limitations/limitation1.jl ':(@test isnothing(limitation1()))'
   Test Summary:  | Pass  Total  Time
   limitation1.jl |    2      2  0.1s
     limitation1  |    2      2  0.0s
   ```

   Both tests are executed (2 tests pass) because they are on the same line. The
   line-based selection mechanism cannot distinguish between multiple expressions
   on the same line.

   **Workaround** (see [workaround1.jl](./limitations/workaround1.jl)): Place
   each `@test` on a separate line:
   ```julia
   @testset "workaround1" begin
       workaround1() = nothing
       @test isnothing(workaround1())             # want to run only this
       @test isnothing(identity(workaround1()))   # now this test is skipped
   end
   ```

   With this workaround:
   ```console
   $ testrunner -v limitations/workaround1.jl ':(@test isnothing(workaround1()))'
   Test Summary:  | Pass  Total  Time
   workaround1.jl |    1      1  0.1s
     workaround1  |    1      1  0.0s
   ```

   Now only the matched test is executed (1 test passes).

   This limitation will be resolved with JuliaLowering.jl integration, which will
   eliminate the need for crude line number conversion from surface AST pattern
   matches.

2. **Conservative Dependency Execution**: Due to the conservative approach,
   ALL top-level code except `@test` and `@testset` expressions is executed.
   This means individual `@test` cases within function calls cannot be
   selectively executed.

   Example (from [limitation2.jl](./limitations/limitation2.jl)):
   ```julia
   using Test

   function limitation2()
       @test String(nameof(Test)) == "Test"
   end

   limitation2()  # This executes during dependency execution

   @testset "selected test" limitation2()  # This also executes when selected
   ```

   When trying to match the `@testset` pattern, both the direct function call
   and the testset run:
   ```console
   $ testrunner -v limitations/limitation2.jl "selected test"
   Test Summary:   | Pass  Total  Time
   limitation2.jl  |    2      2  0.1s
     selected test |    1      1  0.0s
   ```

   The test inside `limitation2()` executes twice: once from the top-level
   `limitation2()` call (which executes as part of conservative dependency
   execution) and once from the matched `@testset "selected test"`.

   **Workaround** (see [workaround2.jl](./limitations/workaround2.jl)): Wrap test
   execution code in `@testset` blocks instead of functions, or avoid top-level
   function calls that contain tests.

3. **Tests Within Function Bodies**: Individual `@test` cases within function
   bodies cannot be selectively executed using expression patterns.

   Example (from [limitation3.jl](./limitations/limitation3.jl)):
   ```julia
   function test_arithmetic()
       @test 1 + 1 == 2   # Can't match this with :(@test 1 + 1 == 2)
       @test 2 * 2 == 4   # Can't match this with :(@test 2 * 2 == 4)
   end
   ```

   When trying to match a specific `@test` pattern:
   ```console
   $ testrunner -v limitations/limitation3.jl ':(@test 1 + 1 == 2)'
   Test Summary:  | Total  Time
   limitation3.jl |     0  0.0s
   ```

   No tests execute because the pattern matching doesn't look inside function
   bodies. This happens because:
   - Pattern matching occurs at the AST level where the `@test` is inside
     a function definition
   - Function bodies are not executed during pattern matching
   - Only top-level `@test` expressions or those within `@testset` blocks can
     be matched

   **Workarounds** (see [workaround3.jl](./limitations/workaround3.jl)):

   1. Move tests into `@testset` blocks:
   ```julia
   @testset "arithmetic tests" begin
       @test 1 + 1 == 2   # This CAN be matched with :(@test 1 + 1 == 2)
       @test 2 * 2 == 4
   end
   ```

   2. Call test functions inside `@testset` blocks to make them selectable:
   ```julia
   @testset "function calls" begin
       test_arithmetic()  # Now these tests execute when this testset is selected
   end
   ```

4. **`include` with `mapexpr`**: Files included with `mapexpr`, e.g. via
   `include(mapexpr, path)` or `Base.include(mapexpr, mod, path)`, are
   executed natively as a whole. `mapexpr` takes each top-level expression as
   a whole, including `module` expressions whose contents TestRunner would
   otherwise execute one by one, so they cannot be executed selectively.
   As a result, the tests in such files are executed even when the `include`
   call is not matched, and patterns given to `runtests` for such files are
   ignored.

## Development

TestRunner is built on top of:
- [JuliaInterpreter.jl](https://github.com/JuliaDebug/JuliaInterpreter.jl)
  and [LoweredCodeUtils.jl](https://github.com/JuliaDebug/LoweredCodeUtils.jl)
  for selective code execution
- [JuliaSyntax.jl](https://github.com/JuliaLang/JuliaSyntax.jl) for parsing
- [MacroTools.jl](https://github.com/FluxML/MacroTools.jl) for pattern
  matching

TestRunner is released together with JETLS, whose release process vendors the
dependencies of TestRunner; see the
[JETLS development guide](https://github.com/aviatesk/JETLS.jl/blob/master/DEVELOPMENT.md#release-process).
