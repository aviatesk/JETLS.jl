# TestRunner.jl

A Julia package for selective test execution using pattern matching.
TestRunner allows you to run specific tests from a test file based on testset
names, test expressions, or line numbers, while ensuring all necessary
dependencies are executed.

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

Install from the `release` branch, which has vendored dependencies to avoid
conflicts with your project's packages:

```bash
julia -e 'using Pkg; Pkg.Apps.add(; url="https://github.com/aviatesk/TestRunner.jl", rev="release")'
```

This installs the `testrunner` executable. Make sure `~/.julia/bin` is in your
`PATH`. See <https://pkgdocs.julialang.org/dev/apps/> for details.

### As a package

For programmatic usage within Julia:

```julia-repl
pkg> add https://github.com/aviatesk/TestRunner.jl#release
```

## Quick start

```bash
$ testrunner demo.jl "basic tests"  # Run tests matching a specific testset name

$ testrunner demo.jl "basic tests" "struct tests"  # Run multiple testsets

$ testrunner demo.jl '(:(@test startswith(inner_func2(), "inner")))'  # Run standalone test case
```

Or equivalently via Julia REPL:
```julia-repl
julia> using TestRunner

julia> runtest("demo.jl", ["basic tests"])

julia> runtest("demo.jl", ["basic tests", "struct tests"])

julia> runtest("demo.jl", [:(@test startswith(inner_func2(), "inner"))])
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
  or ranges (line ranges)
- `filter_lines=nothing`: Optional line numbers to filter pattern matches. When provided, only
  pattern matches that overlap with these lines will be executed. This is particularly useful for
  IDE integration where clicking on a specific test should run only that test, even when multiple
  tests may match the same pattern
- `topmodule::Module=Main`: Module context for execution (default: `Main`)
- `source::Union{Nothing,AbstractString}=nothing`: When provided, use this source text for the
  entry file instead of reading it from disk. `filename` is still used for `@__FILE__`, error
  messages, and resolving paths of `include`d files. Useful for editor integrations that want
  to run tests against an unsaved buffer

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

`TestRunnerTestSet` is automatically used in the [`testrunner` app](#app-usage).

See the [Test failure/error handling](#test-failureerror-handling) section for
detailed comparisons showing how different types of failures are reported.

## Pattern types

### String patterns

Match testsets by exact name:
```julia
# Match a testset by name
runtest("demo.jl", ["struct tests"])  # matches any testset whose name is "struct tests"
```

### Regex patterns

Match testsets using regular expressions:
```julia
runtest("demo.jl", [r"foo"])  # matches any testset containing "foo"
```

### Expression patterns

Match arbitrary Julia expressions using MacroTools patterns:
```julia
runtest("demo.jl", [:(@test startswith(s_, prefix_))])  # matches e.g. `@test startswith(s, "Julia")`
runtest("demo.jl", [:(@test a_ > b_)])                  # matches e.g. `@test x > 0`
```

### Line number patterns

Directly specify line numbers or ranges to execute:
```julia
# Run code on specific lines
runtest("demo.jl", [10, 20, 30])

# Run code in a line range
runtest("demo.jl", [10:15])

# Combine with other patterns
runtest("demo.jl", ["basic tests", 42, 50:55])
```

## App usage

TestRunner can be installed as a CLI executable (see the [installation](#installation) section):

```bash
# Run specific testsets by name
testrunner mypkg/runtests.jl.jl "basic tests" "advanced tests"

# Run tests on specific lines
testrunner mypkg/runtests.jl.jl L10
testrunner mypkg/runtests.jl.jl L10:20

# Run tests matching expression patterns
testrunner mypkg/runtests.jl.jl ':(@test foo(x_) == y_)'

# Run tests matching regex patterns
testrunner mypkg/runtests.jl.jl r"^test.*basic"

# Run all tests in a file
testrunner mypkg/runtests.jl.jl

# Combine patterns with filter lines
testrunner mypkg/runtests.jl.jl "my tests" --filter-lines=10,15,20:25

# Use verbose output
testrunner -v mypkg/runtests.jl.jl L55:57

# Pass options to Julia before `--`, e.g. to run tests with multiple threads
testrunner --threads=4 -- mypkg/runtests.jl "my tests"

# Use a specific project environment
testrunner --project=/path/to/project -- mypkg/runtests.jl "my tests"

# Show help
testrunner --help

# Output results in JSON format
testrunner --json mypkg/runtests.jl "my tests"

# Read source from stdin (e.g. an unsaved editor buffer); the file path is
# still needed for `@__FILE__` and to resolve any `include`d files
cat my-edits.jl | testrunner --read-stdin --json mypkg/runtests.jl "my tests"
```

Pattern formats:
- `L10` - Run tests on line 10
- `L10:20` - Run tests on lines 10-20
- `:(expr)` - Match expression pattern
- `r"^test.*"` - Match testset names with regex
- `"my tests"` - Match testset by exact name (default)

Options:
- `--project[=<dir>]` - **Deprecated**: pass `--project` to Julia before `--`
  instead, e.g. `testrunner --project=test -- test/runtests.jl`
- `--filter-lines=1,5,10:20` or `-f=1,5,10:20` - Filter to specific lines
- `--verbose` or `-v` - Show verbose output
- `--json` - Output results in JSON format for machine-readable test results.
  When patterns are given, the results of the individual test sets are included
  as well, along with the lines of their `@testset`s
- `--read-stdin` - Read source for the given file path from stdin instead of disk.
  The path is still used for `@__FILE__`, error messages, and resolving `include`d files

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

```julia-repl
julia> using TestRunner
```

Run `@testset "basic tests"`:
```julia-repl
julia> @testset "Basic tests runner" verbose=true runtest("demo.jl", ["basic tests"]);
Test Summary:      | Pass  Broken  Total  Time
Basic tests runner |    2       1      3  0.0s
  basic tests      |    2       1      3  0.0s
```

`@testset` can be selected with regex:
```julia-repl
julia> @testset "Regex runner" verbose=true runtest("demo.jl", [r".*tests"]);
Test Summary:      | Pass  Broken  Total  Time
Regex runner       |   12       1     13  0.0s
  basic tests      |    2       1      3  0.0s
  struct tests     |    2              2  0.0s
  nested tests     |    5              5  0.0s
  calculator tests |    3              3  0.0s
```

Run individual `@test` cases that use the `process` function:
```julia-repl
julia> @testset "Standalone runner" verbose=true runtest("demo.jl", [:(@test process(s_) == n_)]);
Test Summary:     | Pass  Total  Time
Standalone runner |    2      2  0.0s
  struct tests    |    1      1  0.0s
```

Nested `@testset` can be selected:
```julia-repl
julia> @testset "Nested runner" verbose=true runtest("demo.jl", ["inner tests 1"]);
Test Summary:  | Pass  Total  Time
Nested runner  |    2      2  0.0s
  nested tests |    2      2  0.0s
```

Selected tests run within their enclosing `@testset`s, so their results are
recorded in the same test set hierarchy as when the whole file is run.
Other tests of the enclosing `@testset`s (e.g. the other tests of
`@testset "nested tests"` above) are not run.

Individual `@test` cases can be selectively matched using pattern expressions:
```julia-repl
julia> @testset "Pattern in nested" verbose=true runtest("demo.jl", [:(@test startswith(s_, prefix_))]);
Test Summary:     | Pass  Total  Time
Pattern in nested |    1      1  0.0s
  nested tests    |    1      1  0.0s
```

We can run tests by directly specifying line numbers:
```julia-repl
julia> @testset "Single line" verbose=true runtest("demo.jl", [56]); # Run only the test on line 56
Test Summary:      | Pass  Total  Time
Single line        |    1      1  0.0s
  calculator tests |    1      1  0.0s

julia> @testset "Line range" verbose=true runtest("demo.jl", [55:57]); # Run tests in lines 55-57
Test Summary:      | Pass  Total  Time
Line range         |    3      3  0.0s
  calculator tests |    3      3  0.0s

julia> @testset "Mixed patterns" verbose=true runtest("demo.jl", ["calculator tests", 61]); # Combine named testsets with line numbers
Test Summary:       | Pass  Total  Time
Mixed patterns      |    4      4  0.0s
  calculator tests  |    3      3  0.0s
```

> [!note]
> Note that the `@testset "xxx runner" verbose=true` part is used only to show
> the test results in an organized way and is not required for TestRunner
> functionality itself.

### Test failure/error handling

When tests fail or encounter errors, TestRunner provides enhanced debugging
capabilities through its custom `TestRunnerTestSet` type. This section explains
how different types of test failures are handled and reported.
Let's compare how different types of test failures are reported with and without
`TestRunnerTestSet`:

#### 1. Test failure

For simple assertion failures, there's no difference between the two approaches.
Both provide the full interpreter stacktrace.

**With `Test.DefaultTestSet`:**
```julia-repl
julia> @testset verbose=true runtest("demo.jl", ["Test failure"]);
Test failure: Test Failed at demo.jl:68
  Expression: sin(0) == π
   Evaluated: 0.0 == π

Stacktrace:
  [1] evaluate_call!(interp::TestRunner.TRInterpreter, frame::JuliaInterpreter.Frame, fargs::Vector{Any}, ::Bool)
    @ TestRunner ~/julia/packages/TestRunner/src/TestRunner.jl:515
  ...
```

**With `TestRunnerTestSet`:**
```julia-repl
julia> @testset TestRunnerTestSet verbose=true runtest("demo.jl", ["Test failure"]);
Test failure: Test Failed at demo.jl:68
  Expression: sin(0) == π
   Evaluated: 0.0 == π

Stacktrace:
  [1] evaluate_call!(interp::TestRunner.TRInterpreter, frame::JuliaInterpreter.Frame, fargs::Vector{Any}, ::Bool)
    @ TestRunner ~/julia/packages/TestRunner/src/TestRunner.jl:515
  ...
```

#### 2. Exception inside `@test`

When an exception occurs within a `@test` expression, full exception information
is only available with `TestRunnerTestSet`.

**With `Test.DefaultTestSet`:**
```julia-repl
julia> @testset verbose=true runtest("demo.jl", ["Exception inside of `@test`"]);
Exception inside of `@test`: Error During Test at demo.jl:72
  Test threw exception
  Expression: sin(Inf) == π

Exception inside of `@test`: Error During Test at demo.jl:74
  Test threw exception
  Expression: cos(Inf) == π
```

**With `TestRunnerTestSet`:**
```julia-repl
julia> @testset TestRunnerTestSet verbose=true runtest("demo.jl", ["Exception inside of `@test`"]);
Exception inside of `@test`: Error During Test at demo.jl:72
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

Exception inside of `@test`: Error During Test at demo.jl:74
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
```

#### 3. Exception outside `@test`

When an exception occurs outside of a `@test` macro (preventing subsequent tests
from running), full exception information is available only with `TestRunnerTestSet`:

**With `Test.DefaultTestSet`:**
```julia-repl
julia> @testset verbose=true runtest("demo.jl", ["Exception outside of `@test`"]);
Exception outside of `@test`: Error During Test at demo.jl:77
  Got exception outside of a @test
```

**With `TestRunnerTestSet`:**
```julia-repl
julia> @testset TestRunnerTestSet verbose=true runtest("demo.jl", ["Exception outside of `@test`"]);
Exception outside of `@test`: Error During Test at demo.jl:77
  Got exception outside of a @test
  DomainError with Inf:
  sin(x) is only defined for finite x.
  Stacktrace:
    [1] sin_domain_error(x::Float64)
      @ Base.Math ./special/trig.jl:28
    [2] sin(x::Float64)
      @ Base.Math ./special/trig.jl:39
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
   ```julia-repl
   julia> @testset "Limitation1 runner" verbose=true runtest("limitations/limitation1.jl", [:(@test isnothing(limitation1()))]);
   Test Summary:      | Pass  Total  Time
   Limitation1 runner |    2      2  0.0s
     limitation1      |    2      2  0.0s
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
   ```julia-repl
   julia> @testset "Workaround1 runner" verbose=true runtest("limitations/workaround1.jl", [:(@test isnothing(workaround1()))]);
   Test Summary:      | Pass  Total  Time
   Workaround1 runner |    1      1  0.0s
     workaround1      |    1      1  0.0s
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
   ```julia-repl
   julia> @testset "limitation2 demo" verbose=true runtest("limitations/limitation2.jl", ["selected test"]);
   Test Summary:     | Pass  Total  Time
   limitation2 demo  |    2      2  0.3s
     selected test   |    1      1  0.0s
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
       @test 1 + 1 == 2   # line 10: Can't match this with :(@test 1 + 1 == 2)
       @test 2 * 2 == 4   # line 11: Can't match this with :(@test 2 * 2 == 4)
   end
   ```

   When trying to match a specific `@test` pattern:
   ```julia-repl
   julia> @testset "limitation3 demo" verbose=true runtest("limitations/limitation3.jl", [:(@test 1 + 1 == 2)]);
   Test Summary:    | Total  Time
   limitation3 demo |     0  0.0s
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

### Release process

TestRunner avoids dependency conflicts by rewriting the UUIDs of its
dependencies and vendoring them. This allows the `testrunner` CLI to work
reliably in any user environment.

**Branch strategy:**
- `master`: Development branch where regular development happens
- `release`: Distribution branch for users with vendored dependencies

**Updating the release:**
```bash
./scripts/prepare-release.sh
```

This script:
1. Creates a `release-update` branch from `release` and merges `master`
2. Vendors dependencies with rewritten UUIDs
3. Creates a pull request to `release`

After CI passes, merge the PR using "Create a merge commit".

For local testing of vendored environment:
```bash
julia --startup-file=no --project=. scripts/vendor-deps.jl --source-branch=master --local
```
