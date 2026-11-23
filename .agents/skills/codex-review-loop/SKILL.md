---
name: codex-review-loop
description: >
  When running as Claude Code in JETLS, have Codex review your work at
  implementation milestones and iterate on its findings. Use after finishing a
  coherent unit of a multi-step change (and its tests pass), before reporting a
  non-trivial change as complete, or when the user asks for a Codex review.
  Skip for trivial edits.
argument-hint: "[extra review focus]"
---

# Codex review loop

Get an independent review from Codex (OpenAI's coding agent CLI), judge
its findings yourself, fix what is valid, and let the same Codex session
re-check until it approves or the round limit is hit.

Extra review focus from the user, if any: $ARGUMENTS

## When to run

- At milestones: a coherent unit of the task is done and its relevant
  tests and self diagnostics pass. Not after every edit.
- Before reporting a non-trivial change as complete.
- When the user asks for it.

## Rules

- Codex runs read-only. Never let it edit files.
- Codex can be wrong. Verify every finding against the code before acting on it.
  Reject findings that are incorrect or conflict with the user's instructions
  or project rules, and say why.
- Codex tends to flag edge cases that are possible only in theory. Judge each
  finding by the criteria of the [`review`](../review/SKILL.md) skill, and
  accept an edge case only after confirming that its triggering input is
  realistic by those criteria and actually reaches the code in question.
  Reject findings whose input is not realistic instead of complicating
  the implementation for them.
- Do not edit files while a Codex run is in progress.
- No git write operations as part of this loop.
- At most 3 rounds per milestone. If Codex and you still disagree after that,
  stop and leave the decision to the user.
- A run counts as a completed review only if it exits with 0 and the first
  line of its output is a `VERDICT:` line. If `codex` is not found, fails,
  or gives no verdict, stop and tell the user instead of working around it.

## Round 1

Run in the foreground with the Bash tool's maximum timeout (600000 ms).
Pass the prompt on stdin via a heredoc. Stdout is only Codex's final
message; the full log goes to a file.

```bash
log=$(mktemp "${TMPDIR:-/tmp}/codex-review.XXXXXX") || exit 1
codex exec -s read-only - 2> "$log" <<'EOF'
<prompt>
EOF
rc=$?
echo "exit=$rc session=$(sed -n 's/^session id: //p' "$log") log=$log"
exit "$rc"
```

Keep the printed session id; later rounds resume that session.

The prompt must be self-contained, since Codex has none of your context.
Codex reads `AGENTS.md` itself, so do not restate project rules.

- Goal of the overall task and of this milestone.
- What changed in this milestone (files, key functions) and what was
  verified (tests and self diagnostics run, with results).
- Review target: the uncommitted changes (`git diff HEAD` and untracked
  files), or the commits the user asked to review, focusing on this
  milestone's files; the rest of the diff is context only.
- What to look for: correctness bugs, design problems, and missing tests,
  following the criteria of the [`review`](../review/SKILL.md) skill.
  No style nits unless they matter. Do not modify any files.
- Any extra focus from the user.
- This output contract:

```text
First line exactly one of:
VERDICT: LGTM
VERDICT: CHANGES_REQUESTED
Then numbered findings, each as:
<n>. [high|medium|low] <path>:<line> — <problem> — <suggested fix>
   Input: <triggering input and why it is realistic> (behavior findings only)
   Verified: <how it was reproduced or traced> (behavior findings only)
```

If the run hits the timeout, the review scope was too large: narrow it to
fewer files and run once more, keeping track of the files left out. If it
times out again, stop and report.

## Evaluate and fix

For each finding, decide one of:

- accept: the finding is valid, so fix it.
- reject: the finding is invalid; give a concrete reason.
- defer: the finding is valid but out of scope for this change, e.g. a
  pre-existing issue whose fix would widen the change. Leave it unfixed and
  report it to the user.

Fix the accepted ones, then validate as `AGENTS.md` requires (relevant
tests and self diagnostics). Fix an accepted finding in the current working
tree only when the issue still exists there; if it does not, report it as
confirmed in the reviewed commit but already resolved. For commits outside
the current branch's history, report the findings and ask the user where to
apply fixes before making any.

## Round 2 and later

Resume the same session so Codex keeps its context. `resume` does not
inherit the read-only sandbox, so pass it explicitly.

```bash
codex exec resume -c sandbox_mode=read-only <session-id> - 2>> <log> <<'EOF'
<prompt>
EOF
rc=$?
echo "exit=$rc"
exit "$rc"
```

The prompt lists each finding by number with your disposition (fixed and
how, rejected and why, or deferred and why) and the validation you ran.
Ask Codex to verify the fixes, reconsider the rejections, and answer with
the same output contract. Do not repeat the round-1 context.

Stop when Codex returns `VERDICT: LGTM`, when the remaining findings are
only ones you rejected with solid reasons or deferred, or at the round limit.

## Report to the user

Briefly:

- Rounds run and the final verdict.
- The scope the final verdict covers, and any files left unreviewed, e.g.
  after narrowing the scope on a timeout.
- Findings fixed.
- Findings rejected, with reasons, and any unresolved disagreement.
- Findings deferred, for the user to decide on.
- The Codex session id, so the user can continue it with
  `codex resume <session-id>`.
