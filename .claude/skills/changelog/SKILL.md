---
name: changelog
description: >-
  Invoke before committing user-facing changes (new features, bug fixes,
  behavior changes) to update CHANGELOG.md. Skip for internal refactors,
  CI, docs-only, or minor dependency bumps.
---

# Updating CHANGELOG.md

## Format

This project follows [Keep a Changelog](https://keepachangelog.com/en/1.0.0/).

## Line length

CHANGELOG.md is exempt from the 80-character Markdown line length rule
because it is used for GitHub release notes, where hard line breaks
disrupt rendering.

That said, do not put everything on a single line unconditionally.
Break lines at natural points (sentence boundaries, after colons, etc.)
when an entry is long enough to benefit from it.
Short, single-sentence entries are fine as one line.

## Section structure

New entries go under the `## Unreleased` section.
Use the following subsections as needed (in this order):

- `### Announcement` -- important notices (always first if present)
- `### Added` -- new features
- `### Changed` -- changes to existing functionality
- `### Fixed` -- bug fixes

## Entry style

- Start Added entries with "Added ..." and Fixed entries with "Fixed ...".
- Changed entries typically start with the component name
  (e.g. "`lowering/undef-local-var` now ...").
- When closing a GitHub issue, append
  `(Closed https://github.com/aviatesk/JETLS.jl/issues/NNN)`.
- Use backticks for diagnostic names, function names, and code elements.
