# HierarchicalTestSets.jl

[![](https://github.com/aviatesk/JETLS.jl/actions/workflows/HierarchicalTestSets.jl.yml/badge.svg)](https://github.com/aviatesk/JETLS.jl/actions/workflows/HierarchicalTestSets.jl.yml)
[![](https://codecov.io/gh/aviatesk/JETLS.jl/branch/master/graph/badge.svg?flag=HierarchicalTestSets.jl)](https://codecov.io/gh/aviatesk/JETLS.jl&flags[0]=HierarchicalTestSets.jl)

This package provides `HierarchicalTestSet`, a `Test.AbstractTestSet` that
prints the full path of nested `@testset`s when a test fails or errors,
instead of just the innermost description that `Test.DefaultTestSet` prints.

It is not registered; the test suites of JETLS.jl and LSP.jl depend on it via
`[sources]` path entries.

## Usage

Specify `HierarchicalTestSet` on the outermost `@testset` only; nested
`@testset`s inherit it.

```julia
using HierarchicalTestSets
using Test

@testset HierarchicalTestSet "outer" begin
    @testset "middle" begin
        @testset "leaf" begin
            @test 1 == 2
        end
    end
end
```

The failure is then reported together with its testset path:

```
[Testset Path] outer > middle > leaf
  Test Failed at example.jl:4
    Expression: 1 == 2
  Stacktrace:
  ...
```

whereas `Test.DefaultTestSet` would only print
`leaf: Test Failed at example.jl:4`.

Test results are recorded by a wrapped `Test.DefaultTestSet`, so the test
summary is the same as with the default `@testset`.

## Progress output

With the `progress=true` option, the path of each direct child testset is
printed when it starts, and its result and duration are appended when it
finishes:

```julia
@testset HierarchicalTestSet "outer" progress=true begin
    @testset "a" include("test_a.jl")
    @testset "b" include("test_b.jl")
end
```

```
[outer > a] passed (1.2s)
[outer > b] failed (3.4s)
```

The testset path is dimmed, and the result is shown as `passed` in green, or
as `failed` in red when the child testset has failures or errors. When a
failure or the progress of a nested testset is printed in between, the result
is printed on a new line together with the path again.

Nested `@testset`s accept the option as well, which reports their own
children.

## Caveats

- When a `HierarchicalTestSet` is nested in another kind of testset, the path
  starts from the description of that testset (for `Test.DefaultTestSet`) or
  from its type name.
- Output that the tests print by themselves, e.g. with `println` or logging,
  is not coordinated with the progress output, so it may continue the line of
  a testset path, and the result then follows that output.
- This package relies on internals of the `Test` standard library, so it may
  need updates for new Julia versions.
