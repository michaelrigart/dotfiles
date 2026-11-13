# Review loop: triage Claude's own findings, review per task only where it pays

**Status:** Approved
**Date:** 2026-11-12
**Branch:** `feat/review-loop`, in the `wt` checkout `~/.local/share/chezmoi-feat-review-loop`
**Depends on:** `chore/test-audit` merging first (see Merge order)
**Reopens, for Claude-side reviews only:** "fix every finding, no classification" (2026-10-06),
"no lighter review process" (2026-10-27), "keep the per-task reviewer" (2026-10-30, workflow-tuning
spec, Declined), "keep the review loop as is" (2026-11-01) and "reviewer lens unchanged"
(2026-11-02, instruction-layer spec §3). Michael reopened the review loop and the per-task
reviewer on 2026-11-11, with evidence, per item. The Codex loop keeps no round cap and no held
findings; nothing here changes either.

*Labels as in the 2026-11-11 review note: **V** verified (files, git, transcripts), **I** inferred,
**S** from a hand-classified sample. Numbers marked "note" come from
`MSB/1. Inbox/2026-11-11-agent-setup-full-review.md` and were not re-derived here; the rest were
measured for this spec on 2026-11-12.*

## Why

Over-complication and test volume come from Claude-side review rounds, not from plans, first
implementations or Codex:

- Of 30 sampled Claude-side findings, 3 were real, 14 theoretical and 13 style; 26 were fixed,
  mostly with a test (S, note). On two project lines, 218 of 352 and 65 of 101 commits came after
  the first pass (V, note).
- 24 per-task review rounds yielded about one firm defect (S, note). `sp-reviewer` returns no
  finding on 29% of first reviews and 60% of re-reviews (V, note). Since 2026-11-01, 309 dispatches
  were a per-task review or re-review (289 on `sp-reviewer`, 20 on `sp-architect`; V, dispatch
  descriptions starting "Review Task", "Re-review Task" or "Task review of").
- The reviewer-side filters already exist and did not stop it: `sp-reviewer` says "No style nits"
  and Codex's `reviewer.md` says "Skip style preferences" (V). The lever is the side that acts on a
  finding.
- Test runs: 6,638 in 14 days, 60 h, about 90% inside subagents (V, note). The default suite takes
  445 s on a loaded machine (V, test-audit findings §1.2), and the runner allows one run per
  machine, so a full run per task queues behind every other line.
- Codex converges: 216 of 236 branches approved within 3 rounds (V, note). It stays as it is.

## Goals, non-goals, anti-goals

- **Goals:**
  - a finding from Claude's own reviewers gets code only when a real caller can reach it or it
    names a concrete quality cost;
  - per-task review where an error would spread (a consumed interface, a safety boundary), and a
    cheap mechanical check everywhere else;
  - the full suite once per plan run, not per task or per batch;
  - `sp-architect` only for design, plan review and the final review;
  - one Codex lens sentence that matches the test bar the test-audit gives Claude's reviewers;
  - a `wt` line is briefed in the turn its checkout opens, and its own session writes the spec.
- **Non-goals:** the Codex loop's rounds, cap and fix rules; replacing superpowers (note item 17);
  effort levels; a Sonnet per-task reviewer pilot; `run.sh --changed` (item 29); mutation at
  pre-merge (item 34); slimming the cross-review skill (item 41); the KISS and test rules of items
  14 and 15 beyond what the test-audit ships; any change to `xreview` code or the findings schema.
- **Anti-goals:**
  - code that reaches merge without two independent reviews: every task is still read by the final
    whole-branch review and by Codex's pre-merge review;
  - a triage that reaches Codex's findings;
  - a new permission prompt, a round cap, or held findings in the Codex loop;
  - a rule that silently stops applying because its skill never loads;
  - new measurement tooling.

## Current state (main `b77ff57`, `chore/test-audit` `ac9d59c`, superpowers 7.0.2)

Superpowers updated itself from 7.0.0 to 7.0.2 on 2026-11-12; 7.0.2 is the installed version
(`~/.claude/plugins/installed_plugins.json`). Its file paths below are under
`~/.claude/plugins/cache/claude-plugins-official/superpowers/7.0.2/skills/`.

| Item | Today | Where | Changes here |
|---|---|---|---|
| 11 Triage | "Fix in-scope findings on this branch" binds every review, Claude's own included (instruction-layer §1). Superpowers lets the controller rule on a finding only at the round-5 cap; it already defers Minor findings out of the loop. One plan used the triage as a local constraint. Reviewer-side "skip style" is in place. | `global.md:114`; `subagent-driven-development/references/fix-loop.md:9-13, 75-77`; `…/SKILL.md:335`; `plans/2026-11-11-security-locks-2.md:19`; `sp-reviewer.md:17`; `reviewer.md:16-17` | Controller-side triage (§1) |
| 12 Structure | Every task gets a task review and every fix round a scoped re-review; parallel batches review each commit. A final whole-branch review and Codex pre-merge follow. No step runs the change against the real system. | `…/SKILL.md:255-259, 336`; `claude-code.md:36`; `…/references/final-review.md` | Per-task review narrowed, a controller check, a real-system run (§2) |
| 13 Codex charter | Severity runs P0 (cannot work) to P3 (minor); every finding has a failure scenario; the quality lens names abstraction, workaround, duplication and a test that passes with the bug back. The packet does not name the checkpoint. In 46 Codex findings sampled from 14 days of transcripts: 7 P1, 38 P2, 1 P3; 1 mentions pre-existing code (V, small sample). | `reviewer.md:10-17`; `codex.md:11-12`; `findings.schema.json`; `xreview-packet.py:569, 951` | One lens sentence (§5) |
| 16 Cadence | The driver already iterates on focused suites and runs the full suite on the final commit; Codex fix rounds likewise. Plan runs run more: the implementer template runs the full suite before each task commit, and batches run it once each. | `global.md:66-67`; `cross-review/SKILL.md:224-227`; `subagent-driven-development/implementer-prompt.md:47-48`; `claude-code.md:36`; `sp-mechanical.md:13` | Full suite once per run (§3) |
| 18 Routing | Fix rounds and controllers go to `sp-standard`; `sp-architect` only for design, plan review and the final review (since `a48e989`, 2026-10-31). Not followed: since 2026-11-01, 33 of 141 `sp-architect` dispatches were per-task reviews or re-reviews (20) or fixes and implementation (13), three of them superpowers' round-4 escalation (V, descriptions). 128 of 3,356 `sp-*` dispatches in 14 days passed a `model` override, which ranks above the type's own (V). | `claude-code.md:24-29`; `sp-architect.md:3`; `…/SKILL.md:152-162`; `…/references/fix-loop.md:29-34` | Two table cells and the skill's routing (§4) |
| Dispatch | The driver opens the checkout, then writes and commits the spec there itself, and only then hands the line to its session. Michael, 2026-11-12: "it takes too long before you truly dispatch … It might be better that you dispatch immediately so all work happens in the wt tree." | `global.md:25-30`; `claude-code.md:37-40` | Brief in the same turn; the line's session owns the spec (§9) |

## Design

### 1. Triage of Claude-side findings (item 11)

The controller, not the reviewer, decides what gets code, because the reviewer-side filters
already exist and 26 of 30 findings were still fixed. The reviewer keeps reporting everything,
which also keeps superpowers' rule against pre-judging a reviewer (`…/SKILL.md:285-290`).

The rule goes in `claude-code.md`, not `global.md`. It concerns Claude Code's own `sp-*` reviewers,
and Codex must never read it as permission. It also has to sit in the always-loaded layer: a skill
saying "no code for theoretical findings" would lose to `global.md`'s "Fix in-scope findings", since
CLAUDE.md ranks above skills. The bullet names Fix now, so the narrowing is explicit:

```
- **Claude review findings.** For `sp-reviewer` and `sp-architect`, Fix now narrows: a finding gets
  code only when it names an Engineering judgement cost or a real caller reaching its failure (a
  code path, an input the system accepts, an attacker its threat model names; unsure counts as
  real). Any other finding gets one line under Rulings. Codex findings: the `cross-review` skill.
```

- **Real** covers network and user input to a public surface ("an input the system accepts"), so
  ordinary security findings stay real. **Theoretical** means a state no code path produces, a
  caller that does not exist yet, or an attacker outside the stated threat model (for a guard, the
  exotic spellings beyond the plain forms its header covers). **Style** means a preference with no
  named cost. "Unsure counts as real" holds the quality bar.
- A real finding still gets a test only if its bug could plausibly return; that rule is the
  test-audit's, and this spec does not restate it.
- A ruled finding that Codex raises later is a Codex finding and follows the cross-review skill:
  fixed, ruled as an in-spec trade-off, or taken to Michael. So every theoretical finding Claude
  rules on still meets one untriaged cross-model review before merge.
- The plan-run controller is an `sp-standard` (Sonnet) session, so the triage is a Sonnet
  judgement. Three things bound it: "unsure counts as real"; every no-code ruling is a ledger line;
  and the final review on `sp-architect` is handed those lines and may reopen any of them by naming
  the caller, after which the finding gets code.
- Both reviewers report the caller, so the controller can triage. In `sp-reviewer.md:16-17`:

```
- Every finding carries a file, a line, what breaks, a concrete input or sequence that
  triggers it, the caller that produces it (as Claude review findings defines one, or none),
  and a severity. No style nits unless the repo's linter would fail on them.
```

  `sp-architect.md` gains one bullet after its Engineering judgement bullet:

```
- Give each finding the caller that reaches it, as Claude review findings defines one, or say
  there is none.
```

### 2. Review structure (item 12)

The plan-run controller follows a new skill, `plan-run` (§6). In summary:

- **Per-task review** (superpowers' task reviewer, on `sp-reviewer`) only for a task whose output a
  later task calls, extends or reads, or a task that touches a safety boundary as `global.md`
  Sizing lists it. Running after a task, or sharing a file or suite with it, is not consumption.
  These are the tasks where an error spreads or where the bar is highest.
- **Every other task** gets the controller's check and no reviewer: re-run its focused tests and
  read the result, compare the commit's files with the brief's, read the lines it removes from test
  files. This targets Sonnet 5.5's measured weak points, false completion claims and ignored
  constraints (Sonnet 5.5 card, via the 2026-11-01 note), without a 50k-token review. A failed check
  is a fix round.
- **Unchanged:** the fix loop and its scoped re-reviews inside the review set, the final
  whole-branch review on `sp-architect`, its single fix wave, and Codex's pre-merge review.
- **A real-system run** before the final review, inside the sandbox; steps that need Michael go in
  the final report. Basis: on one line the worst bugs were found by running, not by a reviewer (S,
  note, one line).

Expected effect: in the `~/Code` feature lines the note measured, many tasks drop their review. In
the dotfiles, most tasks consume an earlier interface or touch a guard, deletion or the merge
tooling, so most keep it (I, from the `Depends on:` lines of five recent plans).

### 3. Suite cadence (item 16)

Implementers and fixers run the suites for what they changed, plus the linters; the controller runs
the full suite once, after the last task and before the final review. `global.md`'s full suite on
the final commit and `AGENTS.md`'s heavy-suite rule stay. A batch runs its tasks' focused suites
together once, which catches interference inside the batch. The cost is that a cross-task break
outside a batch surfaces at the end of the run instead of at the task that caused it.
`sp-mechanical.md:13` becomes:

```
- Run the tests the task names and the linters before reporting done, and paste the output.
  The full suite is the controller's.
```

### 4. Routing (item 18)

The rule exists; the gaps are superpowers' escalation ("one tier above", `…/SKILL.md:157-158`), its
"always specify the model" (`:160-162`), and the absence of a named reviewer type for task reviews.
Two cells of the `claude-code.md` table change, and the skill (§6) carries the rest. The
`sp-standard` cell is shown as amended: the final review found its "scoped review" overlapping the
`sp-reviewer` cell.

```
  | `sp-standard` | integration, debugging, fix rounds, plan-run controllers, merges |
  | `sp-reviewer` | cold diff review, every per-task review and re-review |
  | `sp-architect` | design, plan review, the final whole-branch review; a fix only after an `sp-standard` attempt at it failed |
```

### 5. Codex reviewer lens (item 13)

Only one change has a measured problem behind it. The 177 tests the test-audit cut had passed the
pre-merge gate (I: every merge needs an approved pre-merge review). The test-audit also tightens the
test lens of `sp-reviewer` and `sp-architect`, but not of `reviewer.md`, which would leave the two
reviewers on different test bars. The sentence at `reviewer.md:13-15` becomes:

```
A finding is a defect, or a quality problem with a concrete cost: a speculative abstraction, a
workaround where a refactor belongs, duplicated logic, code the change could delete without losing
behaviour, or a test that pins wording, repeats an existing case or would still pass with the bug
back.
```

It is phrased by what the artifact contains, so it needs no checkpoint name in the packet. The rest
of item 13 is not adopted (see Not adopted).

### 6. The `plan-run` skill

New file `dot_claude/skills/plan-run/SKILL.md`, with its `.chezmoiignore` re-include (three lines,
like `cross-review`'s). Close to final:

```
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

## Triage

This replaces "adjudicate only at the cap". Apply Claude review findings (`claude-code.md`) to every
finding of a task review, re-review or final review as it arrives, before any fix round. A finding
without code is a ledger line, `Ruling: no code — <finding> — <theoretical|style>: <why>`, and
reaches the final report's rulings with the others. Every finding that gets code enters the fix loop
in its round, whatever its severity; nothing else does. A spec-compliance gap is never triaged: fix
it, or take it to Michael as a spec change. The reviewer's prompt never carries the triage: it
reports everything, and you triage. Hand the final review your no-code rulings with the other ledger
lines; one it reopens by naming a real caller gets code. A finding you ruled on that Codex raises
later is a Codex finding, handled by the `cross-review` skill.

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
```

### 7. Line budget

Measured on `chore/test-audit`'s fragments, which this line builds on: `global.md` 150/150,
`claude-code.md` 50/50, `codex.md` 14/30.

- **`global.md`:** no added line. No bullet there reflows into fewer lines, so any addition would
  displace a rule; the triage lives in `claude-code.md` instead.
- **`claude-code.md`:** the Parallel tasks bullet (`:31-36`, 6 lines) moves into the skill's
  Batches section, a controller procedure used at one moment. Two bullets take its place: Plan runs
  (2 lines, below) and Claude review findings (4 lines, §1). The two table cells grow. The
  100-column check binds `global.md` only (`agent-instructions.test.sh:133`); `claude-code.md` has
  no width check, and its `web-researcher` row is already about 180 columns, since a table row cannot
  wrap. Total: 50 lines, every prose line at most 100 columns (checked on a scratch render).

```
- **Plan runs.** Plans give each task a `Depends on:` line and run in the line's checkout, never in
  a worktree per task. To run one, first load the `plan-run` skill: it overrides superpowers.
```

  The `Depends on:` and no-worktree rules stay always loaded because they bind whoever writes the
  plan, before the skill is loaded.
- **`global.md` and `claude-code.md`, dispatch (§9):** both rewordings keep their bullets' line
  counts (8 of the `wt` bullet's lines, 4 of Dispatching), so the totals stay 150 and 50.
- **`codex.md`, `cross-review/SKILL.md`:** unchanged.

### 8. How the overrides bind without editing superpowers

- `using-superpowers/SKILL.md:65`: "User instructions (CLAUDE.md, AGENTS.md …) take precedence over
  skills". The Plan runs bullet is in CLAUDE.md, and it gives `plan-run` precedence. The existing
  Parallel tasks bullet already overrides `…/SKILL.md:235` ("Never dispatch multiple implementation
  subagents in parallel") the same way.
- The controller writes every dispatch (`…/SKILL.md:203-215` invites "your resolution of any
  ambiguity"), so the focused-suites line reaches the implementer in its own prompt, and
  `sp-mechanical`'s body says the same.
- The reviewer templates are not edited and not pre-judged: the triage runs after the review.
- Each section of the skill quotes the superpowers rule it replaces, so after a superpowers update
  the next plan run can check that the quoted rule still exists. If it is gone, the override still
  binds by precedence; only the pointer is stale.

### 9. Dispatch a `wt` line at once (Michael, 2026-11-12)

Not a note item. Michael asked for it on 2026-11-12: "it takes too long before you truly dispatch …
It might be better that you dispatch immediately so all work happens in the wt tree." Today the
driver does the recon and writes and commits the spec before the line's session hears of it, so the
longest stretch of a line runs outside its checkout and its pane.

The driver runs `wt` and briefs the checkout's session in the same turn. That session does the
recon, writes the spec, runs Codex's spec review, asks Michael for sign-off in its own pane, and
runs the line. A spec change after sign-off goes to Michael from the line's session, no longer
through the driver. The driver keeps briefing and collecting the report. In `global.md`'s `wt`
bullet, the sentences from "if `wt` fails" on become (close to final; the plan fits each line to
100 columns):

```
  if `wt` fails, it stops and tells Michael. In the same turn it briefs the checkout's session,
  which does the recon, writes the spec, asks Michael for sign-off in its own pane and runs the
  line, taking spec changes to him; the driver keeps only briefing and collecting the report,
  never the line's work. Never run `wt-rm` or `git worktree remove`: the line's final report
```

`claude-code.md`'s bullet becomes:

```
- **Dispatching a `wt` line.** In the turn that ran `wt`, find the checkout's session in
  `ListAgents` (named after it) and `SendMessage` it the brief: goal, sources, constraints, branch,
  what to report back. That session runs the line itself, spec included, with its own subagents and
  `xreview`. If `ListAgents` does not list it, tell Michael; never run the line in the main session.
```

A small change is briefed the same way; it has no spec. The dotfiles `AGENTS.md` already says each
checkout is "run by its own session", so it needs no change.

## Not adopted

- **Item 13's severity definitions, `confidence`, `evidence`, "introduced by this change", and a
  non-blocking P3.** Every Codex finding is fixed or escalated, so severity drives no action. P3 is
  1 of 46 sampled findings, and pre-existing code appears in 1 of 46. `failure_scenario` already
  carries the evidence. Each field would change the findings schema and the heavy `xreview`
  fixtures to solve no measured problem. A non-blocking P3 is the classification Michael rejected on
  2026-10-06.
- **A lens per checkpoint.** The packet does not name the checkpoint, and no checkpoint other than
  pre-merge has a measured lens problem.
- **Skipping the re-review after a trivial fix.** Re-reviews now run only inside the review set,
  and 40% of re-reviews find something (V, note).
- **Per-task reviews on Sonnet.** Unmeasured. Note: 60 `sp-reviewer` dispatches already ran with
  `model: sonnet` through the override this spec removes. That data exists for a later comparison.

## Testing

The test-audit's rule check is the precedent. Rows in `tests/fixtures/agent-instructions/rules.tsv`
(id, file, anchor, safety, terms) check that a rule's block still holds its terms, so a reword
passes and a dropped clause fails. One row per rule whose loss would matter; each names its
regression:

| Row | File, anchor | Safety | Catches |
|---|---|---|---|
| `cc-plan-runs` (replaces `cc-parallel`) | `claude-code.md`, `**Plan runs.**` | no | the trigger losing `plan-run` or its precedence, so the skill never loads and per-task gates and per-task full runs return silently; the no-worktree clause dropped |
| `cc-review-findings` | `claude-code.md`, `**Claude review findings.**` | yes | the caller condition, "only" or "unsure counts as real" dropped or weakened (fix-everything again, or a looser triage); the Codex clause dropped (triage creeping into the Codex loop) |
| `pr-review-set` | `plan-run/SKILL.md`, `A task gets the task review` | yes | a safety-boundary or consumed task losing its per-task review: the obligation and both conditions sit in the one checked paragraph, and the revert check deletes each in turn; its terms are every sentence of the paragraph, verbatim |
| `pr-check` | `plan-run/SKILL.md`, `Every other task gets your check` | no | unreviewed tasks also losing the mechanical check |
| `pr-tests` | `plan-run/SKILL.md`, `never the full suite` | no | per-task full runs returning, or no full run before the final review |
| `pr-real-run` | `plan-run/SKILL.md`, `Run the change once the way its user will` | yes | the run leaving the sandbox (escapes, prompts) or what needs Michael being run by the agent; its terms are every sentence of the block |
| `pr-triage` | `plan-run/SKILL.md`, `A spec-compliance gap is never triaged` | yes | a finding that gets code skipping the fix loop, or a spec-compliance gap being triaged instead of fixed or taken to Michael as a spec change; the terms are the two sentences |
| `cc-table-standard` (terms updated) | `claude-code.md`, the `sp-standard` table row | no | "scoped review" back in the `sp-standard` cell, so two types take the same dispatch |
| `sp-reviewer-caller` | `sp-reviewer.md`, `Every finding carries` | no | findings arriving without a caller, so the controller cannot triage |
| `g-wt` (terms updated) | `global.md`, `` **`wt` worktrees.** `` | yes | the same-turn briefing or the session's ownership of the spec dropped, so the driver writes specs again; the `wt-rm` clause is kept as it is |
| `cc-dispatch-wt` (terms updated) | `claude-code.md`, `` **Dispatching a `wt` line.** `` | no | "In the turn that ran `wt`" or "spec included" dropped |
| `xr-lens` | `dot_config/xreview/reviewer.md`, `A finding is a defect` | no | the deletion and test-surplus clauses dropped |

- **Each row passes the revert check.** Run the audit harness's rule mutants on the new rows if it
  is on `main` by then; otherwise delete each row's key clause by hand, watch the row fail, and
  restore it.
- **Reused coverage, no new tests:**
  - the caps and renders (`agent-instructions`);
  - the skill's `.chezmoiignore` re-include (`claude-settings.test.sh`, its loop over every
    `dot_claude/skills/*/SKILL.md`);
  - the packet carrying the shipped `reviewer.md` (`xreview-packet`, after
    `tests/fixtures/xreview-packet/regenerate.sh`). Because `reviewer.md` changes, the `xreview`
    suites run by exact name.
- **Rendered behaviour:** `command chezmoi --source <checkout> cat ~/.claude/CLAUDE.md` shows both
  new bullets, and `command chezmoi --source <checkout> managed` lists
  `.claude/skills/plan-run/SKILL.md`.
- The real test is the first plan run after the apply, and the measurement below. Neither is a gate.

## Measurement after 14 days

The driver measures 14 days after Michael's `chezmoi apply`, read-only, with the methods that
produced the baseline. No new tooling.

| # | Metric | Method | Baseline | Expected |
|---|---|---|---|---|
| M1 | Disposition of Claude-side findings | the note's: hand-classify 30 findings (real, theoretical, style; fixed or ruled) from lines started after the apply | 26 of 30 fixed, 27 of them theoretical or style (S) | real ones all fixed; at most 1 in 10 theoretical or style ones gets code |
| M1b | Escaped defects | each ruled finding later shown reachable (Codex raised it as real, or a bug) | none recorded | 0 in safety-boundary code; at most 1 elsewhere |
| M2 | Work after the first pass | the note's: commits and test lines after each task's first commit, per merged branch | 218 of 352, 65 of 101 commits (V) | down, per branch |
| M3 | Per-task reviews | `Agent` dispatch descriptions, as here | 309 since 11-01, about one per task (V) | only for tasks in the review set |
| M4 | Codex rounds to approval (guard) | `xreview` ledgers, receipts per branch and checkpoint | 216 of 236 within 3 (V) | at least 85% within 3; lower means Claude's rulings are moving work to Codex |
| M5 | Test runs | the note's: runs and hours, main session against subagents | 6,638 runs, 60 h, about 90% in subagents (V) | no full-suite run inside an implementer |
| M6 | `sp-architect` mix and `model` overrides | dispatch descriptions and `Agent` inputs, as here | 33 of 141 off-role; 128 of 3,356 overrides (V) | under 5% off-role; no overrides in plan runs |
| M7 | Stalls (guard) | `.scripts/measure-interventions.py --days 14`: `human_turns.after_first`, `interrupts`, `xreview.dispatch_failure_rate` | the 14 days before the apply | not up |

`measure-interventions.py` counts no review findings, rounds or test runs, so M7 is its only
part. M1 and M1b decide item 11; M3 and M2 decide item 12; M5 decides item 16; M6 decides item 18;
M4 and M7 guard all four.

## Rollback

Each item lands as its own commit, so one `git revert` plus Michael's `chezmoi apply` undoes it:

1. the skill, the Plan runs bullet and the moved Batches text, the `sp-mechanical` line, and the
   skill's re-include;
2. the triage: the `claude-code.md` bullet, the skill's Triage section, both reviewer lines and
   their rows (it lands after commit 1, so reverting it leaves the skill whole);
3. the two table cells;
4. `reviewer.md` and the regenerated golden packets;
5. the two dispatch rewordings and their rows.

Triggers:
- an escaped defect in safety-boundary code (M1b) reverts commit 2 at once, and Michael is told;
- M4 below 85%, or two escaped defects elsewhere, go to Michael with the data, not straight to a
  revert.

## Merge order

1. **`chore/test-audit` first** (in phase 3). It replaces the sentence pins with `rules.tsv`, which
   this spec edits (it replaces `cc-parallel` and adds rows). It also rewrites the testing line and
   the `sp-architect` and `sp-reviewer` bullets this spec builds on. This line's plan runs on a
   rebase onto `main` after that merge. Landing this line first would mean editing `main`'s
   `need_flat` pins and then conflicting with the audit's replacement of them.
2. **`fix/xreview-trust`** (fresh, no commits on 2026-11-12) is likely to change how `reviewer.md`
   reaches Codex (note item 1). The content change here does not conflict with that, so either order
   works; whichever merges second regenerates the golden packets.
3. **Superpowers** stays as installed (7.0.2). Item 17 is out of scope.

## Decisions for Michael

**Signed off by Michael on 2026-11-12, after Codex's spec review approved in round 2:** all four
adopted as recommended (1: adopt; 2: both parts; 3: once per run; 4: adopt). The text below is the
record of what was put to him.

1. **Triage of Claude-side findings (§1): the decision of this spec.**
   - What it reverses: for `sp-reviewer` and `sp-architect` only, "fix every finding, no
     classification" (2026-10-06) and "keep the review loop as is" (2026-11-01).
   - Recommendation: adopt.
   - Evidence: 26 of 30 sampled findings were fixed, though 27 were theoretical or style (S). The
     reviewer-side "no style" filters were already in place and did not prevent it (V). Every ruled
     finding still faces Codex's untriaged pre-merge review, which converges (216 of 236, V).
   - Risk: the triage is made by the Sonnet controller. It is bounded by "unsure counts as real",
     a ledger line per ruling, the `sp-architect` final review that may reopen any ruling, and
     Codex's review (§1). M1b measures what escapes.
   - Alternatives: triage style findings only; or keep fixing everything.
2. **Review structure (§2).** Per-task review only for consumed and safety-boundary tasks, a
   controller check for the rest, and a real-system run before the final review.
   - What it reverses: it narrows, and does not drop, the per-task reviewer Michael kept on
     2026-10-30.
   - Recommendation: adopt both parts.
   - Evidence: about one firm defect in 24 per-task rounds (S); 309 per-task review dispatches since
     2026-11-01 (V); the check targets Sonnet 5.5's measured weak points.
   - The real-system run has the thinnest basis (one line, S). It costs minutes and no prompts.
     Michael may take it separately or decline it.
   - Alternative: keep every per-task review and add only the triage. This saves less, because
     per-task rounds stay.
3. **Suite cadence (§3).** The full suite once per plan run, instead of before every task commit and
   once per batch.
   - What it reverses: workflow-tuning §11's "plan runs keep the full suite once per batch".
   - Recommendation: adopt.
   - Evidence: 6,638 runs and 60 h in 14 days, about 90% in subagents (V); a 445 s suite under one
     machine-wide lock (V).
   - Cost: a cross-task break outside a batch shows at the end of the run.
   - Alternative: keep the per-batch run and drop only the per-task one.
4. **One Codex lens sentence (§5).**
   - What it reverses: "reviewer lens unchanged" (2026-11-02).
   - Recommendation: adopt this sentence and nothing else from item 13.
   - Evidence: the 177 tests the audit cut had passed the pre-merge gate (I). After the test-audit,
     Claude's reviewers carry the tighter test bar and Codex's would not.
   - Risk: more pre-merge findings, which M4 watches.

Not a decision: the dispatch change (§9) is Michael's instruction of 2026-11-12. Its one consequence
to confirm at sign-off is that a line's spec changes now reach him from the line's session, not
through the driver.

## Amended during execution (2026-11-13, final review)

Three text changes after the final whole-branch review; none reopens a Decision.

- **§6, Triage:** "Only findings that get code enter the fix loop." became "Every finding that gets
  code enters the fix loop in its round, whatever its severity; nothing else does. A spec-compliance
  gap is never triaged: fix it, or take it to Michael as a spec change." Row `pr-triage` pins it.
- **§4, routing:** the `sp-standard` cell lost "scoped review", which overlapped the `sp-reviewer`
  cell (one type per dispatch). Row `cc-table-standard` lost the term.
- **Testing:** `pr-review-set` and `pr-real-run` pin every sentence of their block, verbatim,
  after three rounds of finding them short of the contract one clause at a time.
