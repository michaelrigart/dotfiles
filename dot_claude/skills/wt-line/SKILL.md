---
name: wt-line
description: Use before opening, briefing, stacking or finishing a `wt` line, and when asking for sign-off.
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

## Finishing

Never run `wt-rm` or `git worktree remove`: the line's final report (the driver's, if dropped
before hand-off) gives Michael the `wt-rm <branch>` command to run once it is merged or abandoned.

**Fresh sessions.** When asking for spec sign-off and in a final report, end with one line
suggesting `/clear` plus a paste-ready prompt (checkout, branch, artifact paths, next step).
Persist anything not yet on disk first; never stop only to suggest it.
