# Setup pilots: `/goal`, deny instead of prompting, Sonnet per-task reviewer

**Status:** In progress (branch `chore/setup-pilots`; the dotfiles use no MR).

**Source:** items 21, 25 and 18 (pilot part) of the 2026-11-11 setup review (vault note
`1. Inbox/2026-11-11-agent-setup-full-review`), approved as pilots by Michael on 2026-11-12.
There is no spec: these are measurements, not features.

**Rules for all three.** One host run per pilot, so every result is a sample of one: report the
numbers and no conclusion beyond them. Nothing here changes the default setup; a change is a
proposal to Michael after the result. A switch in another line's session is that line's to make,
on Michael's word. No pilot may add permission prompts. Main-session effort stays xhigh.

## Verified facts (Claude Code 2.1.322, 2026-11-12)

Checked against the installed binary and code.claude.com (`goal`, `settings-reference`,
`permission-modes`, `sub-agents`).

- **`/goal`** exists. It is a session-scoped prompt-based Stop hook: after each turn a small
  model judges the condition against the conversation, with no tools. Not met: Claude starts
  another turn, so a text-only turn end is re-prompted. Met or judged impossible: cleared.
  - **It has no turn, time or budget cap.** A bound is written into the condition ("or stop
    after 20 turns"). It also stops after several turns without a tool call, and after 3
    automatic retries or 3 idle check-ins per goal (check-ins after 30 minutes,
    `CLAUDE_CODE_GOAL_CHECKIN_MINUTES`).
  - Evaluation is skipped for a turn that ends while a subagent or background shell command is
    still running. What happens while the session waits on a person's decision is not
    documented; that is what this pilot measures.
  - `/goal clear` or `/clear` removes it. It does not change the permission mode.
- **`permissions.denyInsteadOfPrompting`** exists (boolean, 2.1.319 or later). A call that would
  prompt is denied at once and the turn carries on. Allow rules, the permission mode, the auto
  mode classifier and PermissionRequest hooks decide first; "it only ever denies, and allows
  nothing" (binary description).
  - **Scope: user settings, managed settings and `--settings` only.** Project and local settings
    are ignored, and `true` in any source wins. One checkout is therefore scoped by how its
    session is launched, never by a file in it.
  - Side effects: `AskUserQuestion` and the plan mode tools are not offered to the model, and an
    MCP request for input is cancelled. Subagents are covered.
  - A streak of consecutive refusals with no work in between ends the turn ("… actions were
    refused and no work went ahead in between, so … was not run and this turn is ending"). The
    threshold is a constant in the binary that was not read out, and the streak is not in the
    docs.
- **Subagent model.** `sp-reviewer` is `model: opus`, `effort: high`. Precedence: the Agent
  call's `model` parameter, then the definition, then `CLAUDE_CODE_SUBAGENT_MODEL`, then the
  session model. `model: "sonnet"` on one Agent call uses Sonnet for that call only, with the
  definition untouched.

## Baseline (14 days to 2026-11-12, all projects, `~/Code/.replay` excluded)

From `.scripts/measure-interventions.py --days 14`: 148 sessions; 1,387 human turns (1,276 after
a session's first, 89 queued); denials `classifier-deny` 52, `user-rejected` 5,
`builtin-safety-check` 25; autonomous stretch n=1,187, median 5 tool calls and 1.19 minutes,
p90 42.4 tool calls and 33.4 minutes.

Not counted by the script: permission prompts Michael approved (a transcript does not record
them), refusals under `denyInsteadOfPrompting`, and findings per review. From a one-off scan of
main-session transcripts: 1,297 `sp-reviewer` dispatches, 52 of them with `model: sonnet`, 24
with `model: opus`, the rest on the definition. From the review note (hand sample): 3 real
findings of 30 sampled.

Human turns per dotfiles line (the script's `is_human`, per project directory, main sessions):
21 lines in the window, median 3, range 0 to 42. Several of those lines are still running and
are briefed by a driver session rather than by Michael, so the median understates a finished
line.

## Pilot A: `/goal` on one plan run (item 21)

- **Question.** Does a goal carry a plan run to its end with fewer human turns, without
  re-prompting a session that is waiting on Michael?
- **Host run (proposed).** `feat/review-loop`, plan `2026-11-12-review-loop.md`, Tasks 0-6,
  starting after `chore/test-audit` merges.
- **Switch.** Michael types in that line's session, before it starts Task 0:

  ```
  /goal Tasks 0-6 of docs/superpowers/plans/2026-11-12-review-loop.md are committed, the full suite and the pre-merge reviews are recorded, the branch is pushed and the final report is written; or the session is waiting on a decision only Michael can make; or stop after 40 turns
  ```

  The "waiting on a decision" clause is deliberate: without it the evaluator has no way to tell
  a question from a stall. A goal that ends on that clause has **not** completed the plan:
  it is recorded as a decision wait, and Michael sets the same goal again with his answer. Each
  re-arm is counted. Off: `/goal clear`. Nothing is written to any settings file.
- **Counted.** From that session's transcript: human turns after the first, and for each one
  whether it answered a real question; goal evaluations by verdict; turns the goal started
  after a text-only turn end, each hand-labelled useful (work was left) or wrong (the session
  was waiting on Michael, a background task or a review); turns used of the 40, per arming; how each arming
  ended (plan complete, decision wait, impossible, cap, cleared, no-tool-use stop, check-in
  limit), each "met" hand-checked against the plan's task list; the number of re-arms.
- **Baseline.** The script numbers above, plus the same counts from the last plan run in the
  dotfiles that ran without a goal (`fix/xreview-trust`).
- **Stop.** Michael clears the goal at the first wrong re-prompt that costs him a turn, or when
  the session loops (two goal-started turns in a row with no new commit or dispatch).
- **Recommend adopting** if the last arming ends with the plan complete (all seven tasks, hand-
  checked), there is no wrong re-prompt, every decision wait was a real question, and Michael's
  turns, re-arms included, are fewer than in the baseline run. **Recommend dropping** on any
  wrong re-prompt while waiting on Michael, a decision wait with no real question, a loop, or an
  end by cap with work left.

**Unattended-run block.** Source: "Prompting Claude Opus 5.5", section "Unattended agentic
runs" (platform.claude.com, read 2026-11-12). Two corrections to item 21:

- "A text-only turn end is a report, not completion" is advice to the harness, not prompt
  text: keep a checklist, send a short continuation when items are open and no blocker is
  stated, optionally let a smaller model check a completion condition, and stop after two or
  three automatic continuations. `/goal` is that mechanism, so the pilot adds nothing for it.
- The system-prompt block ("A standing instruction from the user … about how your turns end")
  is meant for fully unattended agents, and the page says to leave it out where a person is in
  the loop. This session's own system prompt on 2.1.322 already carries a near-identical
  "Finishing work" section, so the kickoff does **not** add the block: a second copy would
  measure nothing. The host session confirms it has that section before the run; if it does
  not, Michael decides whether the kickoff carries the block.

## Pilot B: `denyInsteadOfPrompting` on one `wt` line (item 25)

- **Question.** With prompts turned into denials, does a line keep moving, or does it end turns
  on refusal streaks and need Michael more often?
- **Host run (proposed).** The next new `wt` line in the dotfiles that is not itself a change to
  permissions, the sandbox or the guards.
- **Switch.** Michael, in that line's Claude pane, right after `wt` creates it: exit the session
  and start it again with

  ```
  claude --continue --settings '{"permissions":{"denyInsteadOfPrompting":true}}'
  ```

  Off: exit and start plain `claude --continue`. The flag lives only in that process: no user,
  project, local or managed settings file is edited, so no other session sees it and nothing is
  left behind. It can only deny. It must never go in `~/.claude/settings.json`, where it would
  apply to every session.
- **Safety check before the run.** In a throwaway directory, one `claude -p` with the same
  `--settings` and a command that an `ask` rule covers: confirm it is denied, not run, and note
  the exact denial text.
- **Counted.** From the line's transcripts, main and subagents: refusals under the key (by the
  denial text from the safety check; the script does not count these yet); refusal streaks that
  ended a turn; what each refused call was, hand-labelled as would-have-approved or rightly
  refused; what the agent did next (another route, a report, a retry of the same call); human
  turns after the first; calls for `AskUserQuestion` that could not be made, seen as questions
  in prose instead. The script gives the classifier, guard and `user-rejected` counts.
- **Baseline.** The script numbers above; prompts Michael approved are not in transcripts, so
  the comparison is refusals in the pilot against his own count of prompts on a comparable
  line, if he has one, and otherwise none.
- **Stop.** Michael restarts the session plain at the second streak-ended turn, or at once if a
  refused call is one the line cannot finish without (a push, a commit, a review dispatch).
- **Recommend adopting** (for unattended lines only) if no turn ends on a streak, every refusal
  is either rightly refused or worked around without Michael, and no human turn in the line
  was caused by a refusal (hand-labelled). The line's human-turn total is reported beside the
  per-line baseline (median 3, range 0 to 42) but decides nothing: lines differ too much in
  size for one run to be compared with that median. **Recommend dropping** if a needed call is refused with no other route,
  or a streak ends a turn twice.
- **After the run.** If refusals are worth counting from then on, add their denial text to
  `DENIALS` in `measure-interventions.py` with a case in its suite; that is a proposal, not
  part of the pilot.

## Pilot C: per-task reviews on Sonnet (item 18)

- **Question.** On the same diff and the same brief, what does a Sonnet `sp-reviewer` find
  compared with the Opus one?
- **Design: a shadow review.** The host line keeps its Opus reviews and acts only on those.
  This session re-runs each per-task review with the brief that line's controller sent, copied
  from its transcript, on the same commit, as `Agent(subagent_type: "sp-reviewer",
  model: "sonnet")`. Nothing changes in the host line's session, and no decision rests on a
  Sonnet review. Amended 2026-11-12 after the first Task 1 shadow: each shadow reads a plain
  export of the reviewed commit (`git archive`) with the brief, report and diff copied beside
  it, and the brief's paths point there. The host checkout by then holds the uncommitted fixes
  for the Opus findings, and a shadow that reads it sees what Opus found.
- **Host run (proposed).** `fix/xreview-trust`, plan `2026-11-12-xreview-trust.md`, Tasks 1-8:
  code tasks with real per-task reviews, executing now. `feat/review-loop` is the weaker host:
  its tasks are instruction text and its spec narrows per-task review, so it yields few reviews.
- **Switch.** None outside this session. The `sp-reviewer` definition is not edited.
- **Counted.** Per task, for Sonnet and for Opus: findings by severity and the verdict. Per
  Sonnet finding: also raised by the Opus per-task review, by the final whole-branch review or
  by Codex pre-merge; contradicted by one of them; or raised by none (hand-checked real or
  not). Per Opus finding: missed by Sonnet. Tokens and wall time per review, from the subagent
  transcripts. A final-review or Codex finding counts for or against a shadow review only if
  the defect is present in the commit that review saw and inside its brief; a defect that a
  later commit or fix round introduced is recorded as out of scope.
- **Baseline.** The Opus reviews of the same tasks are the paired control. The 52 earlier
  Sonnet dispatches are unpaired and stay out.
- **Stop.** After the host line's pre-merge review, or after 8 shadow reviews.
- **Recommend a real (non-shadow) pilot** if Sonnet misses no in-scope finding that Opus, the
  final review or Codex showed to be real. **Recommend dropping** if it misses an in-scope one
  on a safety-boundary task. Anything between is reported as numbers only.

## Results

Michael approved all three pairings on 2026-11-12: A on `feat/review-loop`, B on the suite-speed
line (items 30, 29, 33) once `chore/test-audit` is on main, C as the shadow review of
`fix/xreview-trust`.

### Pilot C, interim: 2 of 8 tasks (2026-11-12)

Opus is the host line's own per-task review; Sonnet is the shadow on the same brief. Task 1's
Sonnet column is the clean-export run. Final review and Codex pre-merge have not run yet, so no
finding is confirmed or contradicted by them.

| Task | Reviewer | Verdict | Critical | Important | Minor | Tool calls | Wall time |
|---|---|---|---|---|---|---|---|
| 7, deny rules (`f7b9b5c`) | Opus | Approved | 0 | 0 | 1 | 9 | 41 s |
| 7 | Sonnet | Approved | 0 | 0 | 1 | 7 | 66 s |
| 1, render and escape (`f9ca4c7`) | Opus | Approved | 0 | 0 | 5 | 14 | 156 s |
| 1 | Sonnet | Needs fixes | 0 | 1 | 5 | not read out | not read out |

Opus findings and whether Sonnet raised them:

| Task | Opus finding | Sonnet | Host line |
|---|---|---|---|
| 7 | no behavioural match case for the two new rules (optional) | missed | not acted on yet |
| 1 | quadratic left-out count | raised, as Important, measured | fixed, uncommitted |
| 1 | `reviewed_files` matching diverges from coverage's predicate | **missed** | fixed, uncommitted |
| 1 | no row separates a total counted before cutting from after | raised | open |
| 1 | shown labels reach Claude unescaped (a path with U+202E) | **missed** | fixed, uncommitted |
| 1 | text-scan module loaded twice per render | raised | open |

Sonnet-only findings, none yet checked against the code by hand: Task 7, the implementer's
report says "uncommitted" for committed work; Task 1, no rows for the enum and type checks, the
`line` boundaries or the exact notes sentences; a `line` over 4,300 digits takes the
"not readable JSON" path; deeply nested JSON raises an uncaught `RecursionError` (exit 1, not
4); the default sibling module lookup has no test.

Sonnet raised 3 of Opus's 6 findings and missed 3. Two of the misses are on Task 1, which is a
safety-boundary task, and the host line fixed both; one of them (unescaped labels) is the
property the task exists for. That meets this protocol's drop condition as far as two tasks
can, pending the final review and Codex. The verdicts disagree on Task 1 in the other
direction: Sonnet asked for fixes where Opus approved.

A first Task 1 shadow, run in the host checkout, is discarded: it read the uncommitted fixes
and reported three of Opus's findings from them (see the amended design above).

### Pilot B safety check (2026-11-12, 2.1.322, `claude -p`, Haiku, throwaway directory)

One `touch probe.txt` under an `ask` rule for `Bash(touch:*)`, passed with `--settings`.

| Run | Outcome | File created | Tool result starts |
|---|---|---|---|
| key on (twice) | denied | no | `Permission for this tool use was denied. It requires approval, and this session has no approval surface` |
| key off (control) | denied | no | `Claude requested permissions to use Bash, but you haven't granted it yet.` |

The key never allowed the call. A `-p` run denies an `ask` either way, so this check shows the
key's own denial text and that it adds no allow; it does not show the interactive behaviour. The
first refusal in the real line confirms whether an interactive session prints the same text,
which is the string to count.
