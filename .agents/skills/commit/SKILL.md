---
name: commit
description: >-
  Use when writing a commit message, and MUST invoke before creating any git
  commit. Provides commit message format and safety rules.
---

# Message guideline

## Title format

Use "component: Brief summary" format and imperative mood for the commit
title.

Examples:
- "completions: Add support for keyword argument completion"
- "diagnostics: Fix false positive on unused variable"
- "ci: Update GitHub Actions workflow"

## Body

Write a body by default, including for small, self-contained changes. Do not
treat a descriptive title as a reason to omit the body. When little explanation
is needed, briefly state the motivation and implementation.

Organize body paragraphs in this order and omit any paragraph that is not
relevant:

1. Explain the concrete problem, limitation, or goal motivating the change.
   For user-facing work, describe the resulting capability or behavior. For
   internal work, explain the engineering reason without inventing a
   user-visible impact. Include a small code example when it adds clarity.
2. Explain the approach used to implement the change.
3. Mention important caveats, follow-up work, performance notes, or test
   coverage when relevant.

Write body paragraphs as explanatory prose with explicit subjects:

- Prefer a concrete subject such as the affected component or newly introduced
  type.
- Use `This change` or `This commit` when describing the patch as a whole.
- Use `The implementation` when explaining the mechanism.
- Do not omit a subject merely to avoid `we` or `I`.

Use backticks for code elements such as function names, variables, and paths.

## Line length

Ensure the maximum line length never exceeds 72 characters.
Never rely on Git or an editor to wrap the message automatically.

Before every commit, write the complete message to a uniquely named temporary
file with explicit line breaks, then commit with
`GIT_EDITOR=true git -c core.hooksPath=.githooks commit -F <message-file>`.
Do not use repeated `git commit -m` arguments for a multi-paragraph message.

The command-local `core.hooksPath` setting automatically runs the tracked
`commit-msg` hook and rejects lines longer than 72 characters.
Never use `--no-verify` to bypass it.

## GitHub references

When referencing external GitHub PRs or issues, use proper GitHub interlinking
format: "owner/repo#123".

## Co-author trailer

If you wrote code yourself, include a co-author trailer at the end of the
commit message, for example:

`Co-Authored-By: GPT-5.6 Sol <noreply@openai.com>`

Adjust the model name as appropriate. When simply asked to write a commit
message without having written the code, do not add the trailer.

## Examples

The examples below are from real history; co-author trailers and PR numbers
are omitted.

### Feature addition

Reference: `5bb517f1a7698916b7ea8055fdd595feb5625c7f`

```
type-definition: Implement `textDocument/typeDefinition`

Add server-side support for "Go to Type Definition". The handler runs
the `TypeAnnotation` pipeline (`get_inferrable_tree` →
`infer_toplevel_tree` → `get_type_for_range`) on the toplevel subtree
containing the cursor, then maps the inferred lattice element to a
concrete `Type` and returns the constructor method locations of that
type — falling back to the unwrapped wrapper for parametric types
(e.g. `Vector{Int}` → `Vector`) or to the parent module location when
no constructors are reachable. `Union` types fan out to one location
per constituent.

The feature is registered statically or dynamically based on the
client's `typeDefinition.dynamicRegistration` capability, and reports
back as `LocationLink[]` when `linkSupport` is advertised so the
origin selection range highlights only the cursor's identifier.
```

### Bug fix

Reference: `3465a1caf98a615ad05d40eb5744c8efd4282926`

```
diagnostic: Invalidate pull-diagnostic resultId on config changes

`compute_diagnostic_result_id` previously keyed the resultId only on
the file version (and dependency versions for files with explicit
imports). When `[diagnostic]` config changed, `handle_lsp_config_change!`
sent `workspace/diagnostic/refresh`, but the client's re-request with
the previous `previousResultId` matched the freshly-computed resultId
and the server returned `Unchanged`, so the refresh was effectively a
no-op and stale diagnostics persisted on the client.

Fold the current `DiagnosticConfig` value into the resultId so any
`[diagnostic]` config mutation flips the resultId and the refresh
takes effect.

Also defines `Base.hash(::DiagnosticConfig, ::UInt)` content-based.
`@option` from Configurations.jl generates `==` but not `hash`, so the
default `hash` fell back to `objectid` and broke the `==`/`hash`
contract — equal-valued `DiagnosticConfig` instances hashed
differently because of the embedded `patterns::Vector`. Without this,
the resultId fold above would spuriously invalidate the client cache
whenever `ConfigManagerData` was rebuilt with the same values.
```

# Safety guideline

See the ["Git operations" section in AGENTS.md][git-operations].

[git-operations]: ../../../AGENTS.md#git-operations
