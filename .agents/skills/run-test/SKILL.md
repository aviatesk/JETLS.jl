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
julia --startup-file=no --project=JETLSCore/test -e 'using Test; @testset "test_XXX" include("JETLSCore/test/test_XXX.jl")'
```

Notes:

- `--startup-file=no` avoids loading unnecessary startup utilities.
- `--project=JETLSCore/test` enables `JETLS_TEST_MODE` for proper test
  execution.

The tests of the `jetls` app commands are in `test/` instead, e.g.:

```bash
julia --startup-file=no --project=test test/test_jetls_check.jl
```

## Focused iteration with TestRunner.jl

For faster iteration on a specific `@testset`, use
[TestRunner.jl](../../../TestRunner/), which the test environment depends on:

```bash
julia --startup-file=no --project=JETLSCore/test -m TestRunner --verbose JETLSCore/test/test_XXX.jl "testset_name"
```

`--project=JETLSCore/test` before `-m` keeps `JETLS_TEST_MODE` enabled and
resolves `TestRunner` through the shared workspace manifest, so the tests run
with the TestRunner bundled in JETLS. Do not use the `testrunner` app shim: it
loads its own TestRunner, which conflicts with the one JETLS imports.

TestRunner.jl is still experimental, but it is reliable enough to try first
when the target `@testset` is clear. If it fails in a way that looks specific
to TestRunner.jl, fall back to running the test file standalone.

## Avoid the full suite by default

The full suite takes about 3.5 minutes as of June 2026:

```bash
julia --startup-file=no --project=JETLSCore -e 'using Pkg; Pkg.test()'
```

Avoid it unless:

- Changes affect multiple components.
- The user explicitly requests the full test suite.
- You are unsure which narrower tests are relevant.

## Reporting

In the final response, report the exact test command you ran and whether it
passed, failed, or timed out. If you skipped tests, explain why.
