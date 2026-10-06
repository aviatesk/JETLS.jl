---
name: write-test
description: >
  Use when adding or modifying JETLS tests. Covers test file and module
  structure, `@testset` organization, `let` blocks, `withserver` usage,
  cached syntax trees in helpers that call features directly, and when
  subroutine tests are sufficient for language-server features.
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

### Cached syntax trees

Requests on a synchronized document share the cached syntax tree of its
`FileInfo` without copying it, so no feature may mutate that tree. Under
`JETLS_TEST_MODE`, JETLS records a fingerprint of each cached tree and
`JETLS.check_syntax_tree0(fi)` throws if the tree has changed since.
`withserver` runs this check for every open document when the test finishes.

Helpers that construct their own `FileInfo` and call a feature directly
should construct it with `cache_tree0 = true`, as `cache_file_info!` does for
synchronized documents, and call `JETLS.check_syntax_tree0(fi)` after the
feature call:

```julia
function find_definition(text::AbstractString, pos::Position)
    server = JETLS.Server()
    filename = joinpath(@__DIR__, "testfile_$(gensym(:definition)).jl")
    fi = JETLS.FileInfo(#=version=#0, text, filename; cache_tree0 = true)
    furi = filename2uri(filename)
    JETLS.store!(server.state.file_cache) do cache
        Base.PersistentDict(cache, furi => fi), nothing
    end
    result = JETLS.find_definition(server, furi, fi, pos)
    JETLS.check_syntax_tree0(fi)
    return result
end
```

Leave `cache_tree0` unset when the `FileInfo` is only used to convert
positions or stands for a file that is not open in the editor, since JETLS
doesn't cache a tree for such files in production either.

## After writing tests

When you add or modify tests, use the [`run-test`](../run-test/SKILL.md)
workflow to run the most specific relevant test command.
