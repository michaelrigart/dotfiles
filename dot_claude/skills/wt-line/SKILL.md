---
name: wt-line
description: Use before opening, briefing, stacking or finishing a `wt` line, when asking for sign-off, and before a final report.
---

# `wt` lines

## Opening a line

The driver runs `wt --no-focus <branch> <local-branch>` (a remote start point sets an upstream)
before the line's first file and names the checkout in its report; if `wt` fails, it stops and
tells Michael. In the same turn it briefs the checkout's session, which does the recon, writes the
spec, asks Michael for sign-off in its own pane and runs the line, taking spec changes to him; the
driver keeps only briefing and collecting the report, never the line's work.

## Briefing

In the turn that ran `wt`, find the checkout's session in `ListAgents` (named after it) and
`SendMessage` it the brief: goal, sources, constraints, branch, what to report back. If
`ListAgents` does not list it, tell Michael; never run the line yourself.

The brief also tells the session to load this skill and names its role: it does the recon, writes
the spec or plan, and takes sign-off and spec changes to Michael in its own pane, not to the
driver.

A scout's brief carries the scout rules in full, because the scout's own session does not load
this skill before it starts.

## Increments and stacking

- **Each increment is a line.** An increment has its own branch, so by the existing rule it has
  its own `wt` checkout, session and Codex pane. It goes through the full finish on its own: final
  review, Codex's pre-merge review, pull request. Whoever opened the first line opens the next one,
  with a brief that names the spec, the plan and the increment. No new mechanism: a fresh session
  that builds from the records is what the records are for.
- **Stacking.** The next increment may start before the one under it has merged. Its checkout is
  created from that branch (`wt --no-focus <branch> <lower-branch>`), its pre-merge review runs
  against that branch (`--diff origin/<lower>...<branch>`), and its PR targets that branch with the
  merge state `hold until <lower PR> merges`. An approval is bound to its destination: the review
  against the lower branch never approves the default branch, even when the diff is the same. So
  once the lower one has merged, Michael tells the line in one message; it rebases onto the
  default branch if needed, retargets the PR, runs a fresh full-range pre-merge round against the
  default branch, and only then replaces `hold` with `safe to merge` or `check first`. The gate
  and `xreview` do not change. A stack is at most two deep: a third increment waits until the
  first has merged. The cost is named: every stacked increment needs one message from Michael and
  one extra review round, so a line stacks only when waiting for the merge would leave it idle.

## Scout lines

A driver may brief a line as a scout. A scout attempts a hard task only to learn which files and
problems it touches. It opens no PR, asks for no review and writes no record; its report is a
brief for the real line (files, traps, a size estimate), and its checkout is thrown away. The
real line never starts from the scout's code. This costs tokens and none of Michael's review time.

## Finishing

Never run `wt-rm` or `git worktree remove`: the line's final report (the driver's, if dropped
before hand-off) gives Michael the `wt-rm <branch>` command to run once it is merged or abandoned.

**Fresh sessions.** When asking for spec sign-off and in a final report, end with one line
suggesting `/clear` plus a paste-ready prompt (checkout, branch, artifact paths, next step).
Persist anything not yet on disk first; never stop only to suggest it.
