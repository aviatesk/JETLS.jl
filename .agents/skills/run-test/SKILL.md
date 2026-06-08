---
name: run-test
description: >
  Use when choosing or running JETLS tests after code changes. Prefer
  component-specific tests, avoid the full suite unless needed, and use
  TestRunner for focused iteration.
---

# Run JETLS tests

Use this skill when you need to validate JETLS changes with tests or decide
which test command to run.

## Choose the narrowest useful test

When you changed a specific component, run the component-specific test instead
of the full test suite.

Use this standard form:

```bash
julia --startup-file=no --project=test -e 'using Test; @testset "test_XXX" include("test/test_XXX.jl")'
```

Notes:

- `--startup-file=no` avoids loading unnecessary startup utilities.
- `--project=test` enables `JETLS_TEST_MODE` for proper test execution.

## Focused iteration with TestRunner.jl

For faster iteration on a specific `@testset`,
use [TestRunner.jl](https://github.com/aviatesk/TestRunner.jl)
when `testrunner --help` succeeds:

```bash
testrunner --project=test test/test_XXX.jl "testset_name"
```

TestRunner.jl is still experimental, but it is reliable enough to try first
when the target `@testset` is clear. If it fails in a way that looks specific
to TestRunner.jl, fall back to running the test file standalone.

## Avoid the full suite by default

`Pkg.test()` takes about 4.5 minutes as of June 2026. Avoid it unless:

- Changes affect multiple components.
- The user explicitly requests the full test suite.
- You are unsure which narrower tests are relevant.

## Reporting

In the final response, report the exact test command you ran and whether it
passed, failed, or timed out. If you skipped tests, explain why.
