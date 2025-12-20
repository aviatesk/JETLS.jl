---
name: commit
description: MUST invoke before creating any git commit.
  Provides commit message format and safety rules.
---

# Message guideline

## Title format

Use "component: Brief summary" format for the commit title.

Examples:
- "completions: Add support for keyword argument completion"
- "diagnostics: Fix false positive on unused variable"
- "ci: Update GitHub Actions workflow"

## Body

Provide a brief prose summary of the purpose of the changes made.
Use backticks for code elements (function names, variables, file paths, etc.).

## Line length

Ensure the maximum line length never exceeds 72 characters.

## GitHub references

When referencing external GitHub PRs or issues, use proper GitHub interlinking
format: "owner/repo#123"

## Footer

If you wrote code yourself, include a "Written by Claude" footer at the end of
the commit message. No emoji.

However, when simply asked to write a commit message (without having written
the code), there's no need to add that footer.

## Example

```
analyzer: FieldError & BoundsError analysis

Add static analysis for field access errors by hooking into
`CC.builtin_tfunction` to intercept `getfield`, `setfield!`,
`fieldtype`, and `getglobal` calls.

Two new report types are introduced:
- `FieldErrorReport` (`inference/field-error`): reported when accessing
  a non-existent field by name
- `BoundsErrorReport` (`inference/bounds-error`): reported when
  accessing a field by an out-of-bounds integer index

Note that the `inference/bounds-error` diagnostic is reported when code
attempts to access a struct field using an integer index that is out of
bounds, such as `getfield(x, i)` or tuple indexing `tpl[i]`, and not
reported for arrays, since the compiler doesn't track array shape
information.

Reports from invalid `setfield!` and `fieldtype`, and general invalid
argument types are left as future TODO.

Also adjusts concrete evaluation logic to enable ad-hoc constant
propagation after failed concrete evaluation for better accuracy.

---

- Closes aviatesk/JETLS.jl#392
```

# Safety guideline

See the ["Git operations" section in CLAUDE.md](../../../CLAUDE.md#git-operations).
