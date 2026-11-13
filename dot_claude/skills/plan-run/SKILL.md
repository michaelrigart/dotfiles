---
name: plan-run
description: Use when running an implementation plan as its controller, under superpowers:subagent-driven-development. Says which tasks get a per-task review, how review findings are triaged, which suites run when, and which agent type takes each dispatch; these rules take precedence over that skill and its templates.
---

# Plan runs

Where this skill and superpowers' subagent-driven-development disagree, this skill wins
(`claude-code.md`, Plan runs). What it does not mention runs as that skill says.

## Batches

A batch is tasks with no pending dependency, disjoint files (neither one's tests load the
other's), and no shared test resource such as a database, server or port. Dispatch a batch's
implementers together in the line's checkout; they do not commit. Then commit the tasks one at a
time, check or review each on exactly its commit, and run the batch's focused suites together once.

## Which tasks get a per-task review

This replaces "Never skip the task review". A task gets the task review
(`task-reviewer-prompt.md`, on `sp-reviewer`) when it touches a safety boundary as global Sizing
lists it, or when a later task calls, extends or reads what it creates (a function, a command, a
file format, a schema), as that task's `Depends on:` line says. Running after a task, or sharing a
file or a suite with it, does not count.

Every other task gets your check instead, and no reviewer: run its focused tests yourself and read
the result; compare its commit's files with the brief's; and read the lines its commit removes from
test files, so that no assertion is dropped or weakened and no test is skipped. A failed check goes
back to the implementer as a fix round. The final whole-branch review and Codex's pre-merge review
still read every task.

## Tests

This replaces `implementer-prompt.md`'s "run the full suite once before committing". Every
implementer and fixer dispatch says: run the suites for what you changed and the linters, never the
full suite. You run the full suite once, after the last task, and fix a red run before dispatching
the final review. global.md's rule for the final commit still holds.

## Routing

This replaces Model Selection's reviewer and escalation choices.

- Dispatch the `sp-*` type and never pass `model`: the type carries it.
- Task reviews and re-reviews: `sp-reviewer`. The final whole-branch review: `sp-architect`.
- Fix rounds 1–3 resume the implementer. Rounds 4–5 and the final fix wave go to `sp-standard`, and
  to `sp-architect` only after an `sp-standard` round on the same findings failed.

## Before the final review

Run the change once the way its user will, inside the sandbox: the `run` skill for an app;
`command chezmoi --source <checkout> cat <target>` or `apply --dry-run --verbose` for the dotfiles;
a CLI against a scratch home. Record the command and what it showed in the ledger. Anything
unexpected is a finding for the final review's fix wave. What needs Michael (an apply, an
unsandboxed or live suite) goes in the final report as his step.
