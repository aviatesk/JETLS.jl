---
name: write-test
description: >
  Use when adding or modifying JETLS tests. Covers test file and module
  structure, `@testset` organization, `let` blocks, `withserver` usage, and
  when subroutine tests are sufficient for language-server features.
---

# Write JETLS tests

Use this skill when you add new tests or modify existing JETLS test code.

## Test file structure

Test code for new language server features should be written in files that
define independent module spaces with a `test_` prefix. Include those files
from `test/runtests.jl`.

This lets each test file run independently from the REPL.

For example, `test/test_completions.jl` should look like:

```julia
module test_completions
using Test
...
end # module test_completions
```

Then include it from `test/runtests.jl` like this:

```julia
@testset "JETLS.jl" begin
    ...
    @testset "completions" include("test_completions.jl")
    ...
end
```

## Organizing test code

Use `@testset "testset name"` to organize tests cleanly.

For code clarity, avoid placing `using`, `import`, or `struct` definitions
inside `@testset` blocks unless it is specifically necessary.
Prefer top-level definitions.

Use `let` blocks to avoid unintentionally reusing names across test cases,
unless a helper function or `do` block already provides local scope.

Example:

```julia
module test_completions

using Test
using JETLS: some_completion_func

function testcase_util(s::AbstractString)
    ...
end
function with_testcase(s::AbstractString)
    ...
end

@testset "some_completion_func" begin
    let s = "..."
        ret = some_completion_func(testcase_util(s))
        @test test_with(ret)
    end
    let s = "..."
        ret = some_completion_func(testcase_util(s))
        @test test_with(ret)
    end

    with_testcase(s) do case
        ret = some_completion_func(case)
        @test test_with(ret)
    end
end

end # module test_completions
```

## Language-server feature tests

Testing language server functionality is challenging. To fully test such
functionality, you need to start a server loop and send requests that mimic
realistic user interactions.

For those tests, use `withserver` from
[`test/setup.jl`](../../../test/setup.jl).
Refer to [`test/test_full_lifecycle.jl`](../../../test/test_full_lifecycle.jl)
as an example.

A good pattern is [`test/test_definition.jl`](../../../test/test_definition.jl):
it keeps the full `withserver` coverage to one `request/response sanity` test
for the `DidOpen` → analysis → `DefinitionRequest` path, while most cases use
`definition_test` to call `find_definition` directly and assert on returned
locations. Prefer this split for LSP handlers.

## After writing tests

When you add or modify tests, use the [`run-test`](../run-test/SKILL.md)
workflow to run the most specific relevant test command.
