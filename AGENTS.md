# Formatting
- When writing Julia code, use _4 whitespaces_ for indentation and try to keep
  the maximum line length under _92 characters_.
- When writing Markdown text, use _2 whitespaces_ for indentation and try to
  keep the maximum line length under _80 characters_.
  - Additionally, prioritize simple text style and limit unnecessary decorations
    (e.g. `**`) to only truly necessary locations. This is a style that should
    generally be aimed for, but pay particular attention when writing Markdown.
  - Headers should use sentence case (only the first word capitalized), not
    title case. For example:
    - Good: `## Conclusion and alternative approaches`
    - Bad: `## Conclusion And Alternative Approaches`
- When writing commit messages, follow the format "component: Brief summary" for
  the title. In the body of the commit message, provide a brief prose summary of
  the purpose of the changes made.
  Use backticks for code elements (function names, variables, file paths, etc.)
  to improve readability.
  Also, ensure that the maximum line length never exceeds 72 characters.
  When referencing external GitHub PRs or issues, use proper GitHub interlinking
  format (e.g., "owner/repo#123" for PRs/issues).
  Finally, if you write code yourself, include a "Written by Claude" footer at
  the end of the commit message (no emoji nonsense). However, when simply asked
  to write a commit message, there's no need to add that footer.
- For file names, use `-` (hyphen) as the word separator by default.
  However, if the file name corresponds directly to Julia code (e.g., a module
  name), use `_` (underscore) instead, since Julia identifiers cannot contain
  hyphens (unless we use `var"..."`). For example, test files like
  `test_completions.jl` define a module `module test_completions`,
  so they use underscores.

# Coding rules
- When writing functions, use the most restrictive signature type possible.
  This allows JET to easily catch unintended errors.
  Of course, when prototyping, it's perfectly fine to start with loose type
  declarations, but for the functions you ultimately commit, it's desirable to
  use type declarations as much as possible.
  Especially when AI agents suggest code, please make sure to clearly specify
  the argument types that functions expect.
  In situations where there's no particular need to make a function generic, or
  if you're unsure what to do, submit the function with the most restrictive
  signature type you can think of.

- For function calls with keyword arguments, use an explicit `;` for clarity.
  For example, code like this:
  ```julia
  ...
  Position(; line=i-1, character=m.match.offset-1)
  ...
  ```
  is preferred over:
  ```julia
  ...
  Position(line=i-1, character=m.match.offset-1)
  ...
  ```

- For AI agents: **ONLY INCLUDE COMMENTS WHERE TRULY NECESSARY**.
  When the function name or implementation clearly indicates its purpose or
  behavior, redundant comments are unnecessary.

- On the other hand, for general utilities that expected to be used in multiple
  places in the language server, it's fine to use docstrings to clarify their
  behavior. However, even in these cases, if the function name and behavior are
  self-explanatory, no special docstring is needed.

- Avoid unnecessary logs:
  Don't clutter the language server log with excessive information.
  If you must use print debugging, generally use `@info`/`@warn` behind the
  `JETLS_DEV_MODE` flag, like this:
  ```julia
  if JETLS_DEV_MODE
      @info ...
  end
  ```

# Running test code
Please make sure to test new code when you wrote.

When working on a specific component (e.g., completions, diagnostics),
run the component-specific test instead of the full test suite:
```bash
julia --startup-file=no --project=test -e 'using Test; @testset "test_XXX" include("test/test_XXX.jl")'
```
Note:
- `--startup-file=no` avoids loading unnecessary startup utilities
- `--project=test` enables `JETLS_TEST_MODE` for proper test execution

For even faster iteration on a specific `@testset`, use
[TestRunner.jl](#using-testrunnerjl):
```bash
testrunner --project=test test/test_XXX.jl "testset_name"
```

Running `Pkg.test()` takes about 8 minutes (as of December 2025), so avoid it unless:
- Changes affect multiple components
- The user explicitly requests the full test suite
- You're unsure which tests are relevant

# Test code structure
Testing language server functionality is challenging.
To fully test such functionality, you need to start a server loop,
and send several requests to that server that mimic realistic user interactions.
To write such tests, we've provided `withserver` implemented in
[`test/setup.jl`](./test/setup.jl), and you can refer to
[`test/test_full_lifecycle.jl`](./test/test_full_lifecycle.jl)
as an example of its use.

However, writing such tests is still somewhat tricky.
Therefore, unless explicitly requested by the core developers, you don't need
to write test code to fully test newly implemented language server features.
It's generally sufficient to test important subroutines that are easy to test
in the implementation of that language server feature.

Test code for new language server features should be written in files that
define independent module spaces with a `test_` prefix.
Then include these files from [`test/runtests.jl`](./test/runtests.jl).
This ensures that these files can be run independently from the REPL.
For example, test code for the "completion" feature would be in a file like
this:
> test/test_completions.jl
```julia
module test_completions
using Test # Each module space needs to explicitly declare the code needed for execution
...
end # module test_completions
```
And `test/test_completions.jl` is included from `test/runtests.jl` like this:
> test/runtests.jl
```julia
@testset "JETLS.jl" begin
    ...
    @testset "completions" include("test_completions.jl")
    ...
end
```

In each test file, you are encouraged to use `@testset "testset name"` to
organize our tests cleanly. For code clarity, unless specifically necessary,
avoid using `using`, `import`, and `struct` definitions  inside `@testset`
blocks, and instead place them at the top level.

Also, you are encouraged to use `let`-blocks to ensure that names aren't
unintentionally reused between multiple test cases.
For example, here is what good test code looks like:
> test/test_completions.jl
```julia
module test_completions

using Test # Each module space needs to explicitly declare the code needed for execution
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

    # or `let` is unnecessary when testing with function scope
    with_testcase(s) do case
        ret = some_completion_func(case)
        @test test_with(ret)
    end
end

end # module test_completions
```

## Using TestRunner.jl

Additionally, by using `@testset` as shown above, not only are tests hierarchized,
but through integration with [TestRunner.jl](https://github.com/aviatesk/TestRunner.jl),
you can also selectively execute specific `@testset`s, without executing the
entire test file or test suite.
If you're using this language server for development as well, you can run tests
from code lenses or code actions within test files. If you need to run them from
the command line, you can use commands like the following
(assuming the `testrunner` executable is installed):
```bash
testrunner --project=test --verbose test/test_completions "some_completion_func"
```
Note that TestRunner.jl is still experimental.
The most reliable way to run tests is still to execute test files standalone.

# Environment-related issues
For AI agents: **NEVER MODIFY [Project.toml](./Project.toml) OR  [test/Project.toml](./test/Project.toml) BY YOURSELF**.
If you encounter errors that seem to be environment-related when running tests,
in most cases this is due to working directory issues, so first `cd` to the root directory of this project
and re-run the tests. Never attempt to fix environment-related issues yourself.
If you cannot resolve the problem, inform the human engineer and ask for instructions.

# About modifications to code you've written
If you, as an AI agent, add or modify code, and the user appears to have made
further manual changes to that code after your response, please respect those
modifications as much as possible.
For example, if the user has deleted a function you wrote, do not reintroduce
that function in subsequent code generation.
If you believe that changes made by the user are potentially problematic,
please clearly explain your concerns and ask the user for clarification.

# Git operations
Only perform Git operations when the user explicitly requests them.
After completing a Git operation, do not perform additional operations based on
conversational context alone. Wait for explicit instructions.

When the user provides feedback or points out issues with a commit:
- Do NOT automatically amend the commit or create a fixup commit
- Explain what could be changed, then wait for explicit instruction
