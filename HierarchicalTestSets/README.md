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

## Caveats

- When a `HierarchicalTestSet` is nested in another kind of testset, the path
  starts from the description of that testset (for `Test.DefaultTestSet`) or
  from its type name.
- This package relies on internals of the `Test` standard library, so it may
  need updates for new Julia versions.
