---
name: zed-agent-diagnostics
description: >
  When running as Zed's built-in coding agent in JETLS, prefer the faster
  built-in diagnostics tool for project instructions that require `jetls check`
  or `./scripts/selfcheck.sh`, with fallback to selfcheck when needed.
---

# Zed agent diagnostics

Use this skill when you are running as Zed's built-in coding agent in this
repository and need to satisfy project instructions that require `jetls check`
or `./scripts/selfcheck.sh`.

## Validation rule

When project instructions say to run `jetls check` or `./scripts/selfcheck.sh`
after modifying code, normally satisfy that requirement by using Zed's
diagnostics tool instead of running the terminal command. Prefer it when
available because it is usually faster than starting a separate selfcheck.

Use Zed diagnostics for the initial check. Run `./scripts/selfcheck.sh` only
when diagnostics cannot provide enough confidence.

## How to use diagnostics

- After code edits, call the diagnostics tool for the project.
- If the changed files are known and targeted diagnostics are useful, also call
  the diagnostics tool for those files.
- Treat diagnostics in files you edited as issues to fix when they are likely
  caused by your changes.
- Do not remove or simplify meaningful code only to silence diagnostics. If a
  natural fix is difficult to find, explain the situation and ask the user for
  help.
- If diagnostics appear unrelated to your changes, report them as pre-existing
  or unrelated instead of fixing them opportunistically.

## When diagnostics may be unreliable

JETLS analyzes itself through a Revise-based server session. This is efficient,
but changes to type definitions or global bindings may not be fully reflected in
the running session. Zed diagnostics can therefore be stale, incomplete, or fail.

Be especially conservative when changes affect type definitions, macros,
`include` structure, diagnostics infrastructure, or code that diagnostics
itself depends on. If diagnostics code was edited, diagnostics may be broken
by the current changes.

If diagnostics look stale, incomplete, or broken, do not spend time on server
restart loops. Explain that Zed diagnostics do not provide enough confidence and
run `./scripts/selfcheck.sh` to get a fresh check, unless the user has asked not
to run it.

## Relationship to tests

This skill only changes how self diagnostics are checked. It does not replace
relevant component-specific tests. When you modify testable code, still run the
most specific appropriate tests as described by the project instructions.

## Reporting

In the final response, say whether validation used Zed diagnostics, fell back
to `./scripts/selfcheck.sh`, or used both. Summarize whether diagnostics were
clean or what issues remained.
