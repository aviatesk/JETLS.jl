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

When writing Markdown text, use _2 whitespaces_ for indentation and try to
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

When writing commit messages, follow the format "component: Brief summary" for
the title. In the body of the commit message, provide a brief prose summary of
the purpose of the changes made.
Use backticks for code elements (function names, variables, file paths, etc.)
to improve readability.
Also, ensure that the maximum line length never exceeds 72 characters.
When referencing external GitHub PRs or issues, use proper GitHub interlinking
format (e.g., "owner/repo#123" for PRs/issues).
Finally, if you write code yourself, include a co-author trailer at the end
of the commit message, e.g.:　`Co-Authored-By: GPT-5.5 noreply@openai.com`
(adjust the model name as appropriate). However, when simply asked to write
a commit message, there's no need to add that trailer.

# File names

For file names, use `-` (hyphen) as the word separator by default.
However, if the file name corresponds directly to Julia code (e.g., a module
name), use `_` (underscore) instead, since Julia identifiers cannot contain
hyphens (unless we use `var"..."`). For example, test files like
`test_completions.jl` define a module `module test_completions`,
so they use underscores.

# Coding rules

- When writing functions, use the most restrictive signature type practical so
  JET can catch unintended errors. Loose signatures are fine while prototyping,
  but committed code should specify expected argument types unless generic
  behavior is intentional. When unsure, prefer the more restrictive signature.

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

Default to no comments. Add comments only when they explain non-obvious
behavior, constraints, invariants, rationale, or genuine hacks. Do not restate
implementation flow.

Docstrings are fine for general utilities when they clarify behavior.

The same applies to tests: concise `@testset` descriptions and behavior-level
comments are fine when they clarify what is being tested. Explain test setup
only when it encodes a non-obvious constraint or hack.

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

If the user manually changes work you previously produced, respect those
changes. Do not reintroduce deleted code or revert user edits without explicit
permission. If you think a user edit is problematic, explain your concern and
ask for clarification.

# Git operations

Only perform Git operations when the user explicitly requests them. After any
Git operation, wait for explicit follow-up instructions before doing more.

If the user provides feedback on a commit, do not automatically amend it or
create a fixup commit. Explain what could change and wait for explicit
instruction.
