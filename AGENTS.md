# Formatting

## Code formatting
- When writing Julia code, use _4 whitespaces_ for indentation and try to keep
  the maximum line length under _92 characters_.
- AI agents must not run automated formatters unless explicitly requested by a
  human in the current conversation.
  This includes file-wide or project-wide formatting commands and
  editor-integrated formatting tools.
  When editing code, preserve the surrounding formatting and make only minimal
  local edits. If formatting seems necessary, ask before applying it.

## Markdown formatting
- When writing Markdown text, use _2 whitespaces_ for indentation and try to
  keep the maximum line length under _80 characters_.
  - Exception: `CHANGELOG.md` is exempt from line length rules since it is
    used for GitHub release notes, where hard line breaks disrupt rendering.
  - Additionally, prioritize simple text style and limit unnecessary decorations
    (e.g. `**`) to only truly necessary locations. This is a style that should
    generally be aimed for, but pay particular attention when writing Markdown.
  - Headers should use sentence case (only the first word capitalized), not
    title case. For example:
    - Good: `## Conclusion and alternative approaches`
    - Bad: `## Conclusion And Alternative Approaches`

## Commit message formatting
- When writing commit messages, follow the format "component: Brief summary" for
  the title. In the body of the commit message, provide a brief prose summary of
  the purpose of the changes made.
  Use backticks for code elements (function names, variables, file paths, etc.)
  to improve readability.
  Also, ensure that the maximum line length never exceeds 72 characters.
  When referencing external GitHub PRs or issues, use proper GitHub interlinking
  format (e.g., "owner/repo#123" for PRs/issues).
  Finally, if you write code yourself, include a co-author trailer at the end
  of the commit message, e.g.:
  `Co-Authored-By: Claude Opus 4.6 <noreply@anthropic.com>`
  (adjust the model name as appropriate). However, when simply asked to write
  a commit message, there's no need to add that trailer.

# File names
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

- When modifying config structs in `src/types.jl`, follow the schema
  regeneration procedure in [DEVELOPMENT.md](./DEVELOPMENT.md#configuration-schema).

- Avoid unnecessary logs:
  Don't clutter the language server log with excessive information.
  If you must use print debugging, generally use `@info`/`@warn` behind the
  `JETLS_DEV_MODE` flag, like this:
  ```julia
  if JETLS_DEV_MODE
      @info ...
  end
  ```

## Comments guideline
Default to writing no comments. The general rule is
**ONLY INCLUDE COMMENTS WHERE TRULY NECESSARY**: when the function name
or implementation already makes the intent clear, comments are noise.

When a comment is warranted:
- Focus on what/why — the behavior contract, hidden constraints,
  non-obvious invariants, or rationale.
- Do not merely restate what the code does or walk the reader through
  the implementation flow; a reader can derive that from the code itself.

Exception: if the code is a genuine hack or encodes a surprising
invariant, keep the detail and flag the hack explicitly — a future
reader needs that context.

For general utilities used across the language server, docstrings are
fine when they clarify behavior. Even here, if the function name and
behavior are self-explanatory, no docstring is needed.

### Comments in test code
The same principles apply to tests. In particular, don't explain the
implementation flow of the code under test in order to justify the
expected value — keep the comment at the behavior level
(e.g. "cursor on X should resolve to Y"). If the test setup itself is
a genuine hack, flag that explicitly.

# Running `jetls check` for self diagnostics

Please make sure to check self diagnostics after writing or modifying code.

The standard command is:

```bash
./scripts/selfcheck.sh
```

This is run in CI and will cause failures if new warnings are introduced.

# Running test

Please make sure to test new code when you wrote.

Run the most specific relevant tests when practical. Prefer component-specific
tests over the full test suite. Avoid `Pkg.test()` unless changes affect
multiple components, the user explicitly requests the full test suite,
or no narrower validation is appropriate.

For detailed test-running workflows,
use the [`run-test`](./.agents/skills/run-test/SKILL.md) skill.

# Writing test

When adding or modifying tests, keep test files independently runnable and
follow the project's test file structure. For new language server features,
prefer focused subroutine tests unless the core developers explicitly request
full language-server interaction coverage.

For detailed test-writing workflows,
use the [`write-test`](./.agents/skills/write-test/SKILL.md) skill.

# Environment-related issues

For AI agents: never modify [`Project.toml`](./Project.toml) or
[`test/Project.toml`](./test/Project.toml) by yourself.

If test failures look environment-related, first ensure the test was run from
the root directory of this project. Never attempt dependency or project-file
fixes yourself. If the problem remains, inform the human engineer and ask for
instructions.

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
