---
name: review
description: >
  Use when reviewing JETLS code changes (a diff, commit, branch, or PR),
  whether asked directly or through `codex-review-loop`. Require realistic
  inputs for behavior findings, not for concrete findings about project
  rules, missing tests, or design. Weigh severity and scope reviews to the
  change.
---

# Review JETLS changes

Every finding costs the author a triage round. Fewer findings with high
confidence beat a long list of edge cases. Reporting no findings is a valid
result.

## Decide what to report

The criteria below apply to findings about behavior. Findings about project
rules in `AGENTS.md`, missing tests for the changed behavior, or design
problems need no triggering input, but they must be concrete.

Report a behavior finding only when its triggering input is realistic and
its consequence matters. For every such finding, name the concrete input and
explain why it is realistic. Use evidence appropriate to the input:

- Julia code: name the common idiom. If you are unsure people write the
  pattern, look for it in Julia's `base/`, `stdlib/`, or `test/`, or in
  packages under `~/.julia/packages`. Drop the finding if you find no use.
- Code in the middle of an edit: describe an ordinary editing sequence that
  produces it, such as typing `f(` before completing a call. The fragment
  need not appear in checked-in code.
- LSP requests: cite the specification that permits the request or show
  that a mainstream client (VS Code, Zed, Neovim, ...) sends it. For
  example, the specification defines a `Position` whose `character` exceeds
  the line length as referring to the end of the line.
- Other inputs, such as project layouts, configuration files, `jetls`
  command line arguments, or the timing of concurrent requests: describe a
  setup or sequence that users plausibly have.

Evaluate inputs under the default configuration or settings users are
likely to choose. Shrinking a threshold such as `min_lines` to keep a
reproduction short is fine.

Then weigh the consequence against how common the input is:

- Report serious results on any realistic input: lost or corrupted code,
  edits that break parsing or change semantics, crashes, hangs, wrong
  results such as false diagnostics or wrong definition targets, and
  noticeable performance regressions in time or memory.
- Report cosmetic issues, such as a duplicated or missing hint or a code
  action that is not offered, only when they occur on common inputs.

Code in the middle of an edit needs its own judgment. A language server
constantly sees incomplete code, which can take arbitrary forms, so its edge
cases never end. With agentic coding, more edits also arrive in batches,
which makes those edge cases matter less than before. Report a finding that
only occurs on incomplete code when it causes lasting harm, such as lost
code, a crash, or a hang, or when the fix looks cheap. Drop the rest,
including diagnostics or hints that are wrong only until the edit is
complete, since complicating the implementation only for incomplete code is
not worth it.

Focus on what the change introduces or makes noticeably more likely or
severe. Mention an issue that predates the change only if it has a serious
result on a realistic input, and label it as pre-existing.

## Suggesting fixes

- Except for incomplete code as described above, the cost of a fix is not a
  reason to drop a finding. When the fix looks likely to add implementation
  complexity, say so in the finding and leave the trade-off to the author.
- When suggesting defensive handling for an input that any feature can
  receive, such as an out-of-range position, prefer handling it in a shared
  helper over special-casing a single feature.
- Make sure a suggested fix does not penalize common inputs to handle a rare
  one.

## Verify before reporting

Reproduce each behavior finding, e.g. by running the relevant function on
the triggering input, and report only what you reproduced or traced through
the code. State how you verified it.

## Output

Follow the output format the requester specifies, but in any format give
the triggering input, why it is realistic, and how you verified it for each
behavior finding.
Without a specified format, list the findings most severe first, each with
its location, the problem and its consequence, and a suggested fix along
with its expected complexity when notable. Say explicitly when there are no
findings.
