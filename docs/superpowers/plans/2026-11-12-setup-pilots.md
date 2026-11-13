# Setup pilots: `/goal`, deny instead of prompting, Sonnet per-task reviewer

**Status:** In progress (branch `chore/setup-pilots`; the dotfiles use no MR).

**Source:** items 21, 25 and 18 (pilot part) of the 2026-11-11 setup review (vault note
`1. Inbox/2026-11-11-agent-setup-full-review`), approved as pilots by Michael on 2026-11-12.
There is no spec: these are measurements, not features.

**Rules for all three.** One host run per pilot, so every result is a sample of one: report the
numbers and no conclusion beyond them. Nothing here changes the default setup; a change is a
proposal to Michael after the result. A switch in another line's session is that line's to make,
on Michael's word. No pilot may add permission prompts. Main-session effort stays xhigh.

## To paste (Michael)

**Pilot A**, in the `feat/review-loop` session, before it starts Task 0:

```
/goal Tasks 0-6 of docs/superpowers/plans/2026-11-12-review-loop.md are committed, the full suite and the pre-merge reviews are recorded, the branch is pushed and the final report is written; or the session is waiting on a decision only Michael can make; or stop after 40 turns
```

If it stops to ask something, answer and paste the same line again. Off: `/goal clear`.

**Pilot B**, in the suite-speed line's Claude pane, right after `wt` creates it: exit the
session, then

```
claude --continue --settings '{"permissions":{"denyInsteadOfPrompting":true}}'
```

Off: exit and start `claude --continue`. Never on the same line as Pilot A.

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
| 1 | Sonnet | Needs fixes | 0 | 1 | 5 | 12 | 97 s |

Opus findings and whether Sonnet raised them:

| Task | Opus finding | Sonnet | Host line |
|---|---|---|---|
| 7 | no behavioural match case for the two new rules (optional) | missed | not acted on yet |
| 1 | quadratic left-out count | raised, as Important, measured | fixed, uncommitted |
| 1 | `reviewed_files` matching diverges from coverage's predicate | **missed** | fixed, uncommitted |
| 1 | no row separates a total counted before cutting from after | raised | open |
| 1 | shown labels reach Claude unescaped (a path with U+202E) | **missed** | fixed, uncommitted |
| 1 | text-scan module loaded twice per render | raised | open |

Sonnet-only findings, hand-checked on the export of each commit:

| Task | Sonnet-only finding | Hand check |
|---|---|---|
| 7 | the implementer's report says "uncommitted" for committed work | not a defect: in a parallel batch the implementer does not commit, the controller does |
| 1 | no rows for the enum and type checks, the `line` boundaries or the exact notes sentences | true: the render section has none |
| 1 | a `line` over 4,300 digits takes the "not readable JSON" path | true: exit 4, `$: not readable JSON`, no value printed |
| 1 | deeply nested JSON raises an uncaught `RecursionError` | true: exit 1 with empty stdout, the code for a missing module; the answer is schema-checked upstream |
| 1 | the default sibling module lookup has no test | true: the suite exports `XREVIEW_TEXT_SCAN` for every row |

Four of Sonnet's five own findings are true and Opus raised none of them; all four are minor,
and none breaks the task's brief. One is not a defect.

Sonnet raised 3 of Opus's 6 findings and missed 3. Two of the misses are on Task 1, which is a
safety-boundary task, and the host line fixed both; one of them (unescaped labels) is the
property the task exists for. That meets this protocol's drop condition as far as two tasks
can, pending the final review and Codex. The verdicts disagree on Task 1 in the other
direction: Sonnet asked for fixes where Opus approved.

**Re-review of Task 1's fix round (`071b2a5`), same brief, clean export.** Both found all four
findings addressed and no Critical or Important breakage.

| Reviewer | New findings | Tool calls | Wall time |
|---|---|---|---|
| Opus | 1 minor: a test comment claims the 2,000-label row guards the quadratic rescan, which it does not | 9 | 71 s |
| Sonnet | none | 9 | 34 s |

Sonnet saw the same fact ("the row only pins correctness, not timing") and accepted it instead
of raising it: counted as a miss. Its two out-of-scope notes, hand-checked: the spec's line 212
still says "after the same strip" while the code follows coverage's wider predicate (true,
wording only); the spec's line 89 says "Printed as given" (not a defect: that table records the
state before the change). One explanation in its report is wrong (it derives 31,605 as
21 x (1,500 + 105)); the verdict it supports is right.

Running total, 3 reviews: Sonnet raised 3 of Opus's 7 findings and missed 4.

### Pilot C, interim: 9 reviews over Tasks 1, 2, 5, 6 and 7 (2026-11-13)

Six more reviews, each on a clean export of its head commit; for a first review the report
copy is cut before its "Fix round" section. Method note: these six briefs were handed to the
shadow as a file to read, text unchanged apart from paths; the first three were pasted.

| # | Review | Opus verdict | Sonnet verdict | Opus findings (C/I/M) | Sonnet raised | Opus tools, time | Sonnet tools, time |
|---|---|---|---|---|---|---|---|
| 1 | Task 7 | Approved | Approved | 0/0/1 | 0 | 9, 41 s | 7, 66 s |
| 2 | Task 1 | Approved | Needs fixes | 0/0/5 | 3 | 14, 156 s | 12, 97 s |
| 3 | Task 1 fix round | passed | passed | 0/0/1 | 0 | 9, 71 s | 9, 34 s |
| 4 | Task 6 (`28139d1`) | Needs fixes | **Approved** | 1/2/3 | 1 | 33, 451 s | 27, 250 s |
| 5 | Task 2 (`1e113a5`) | Needs fixes | Needs fixes | 2/0/4 | 3 | 27, 307 s | 25, 157 s |
| 6 | Task 6 fix round (`1da9bac`) | findings open | **passed** | 1/1/1 | 1 | 35, 362 s | 42, 294 s |
| 7 | Task 2 fix round (`c701084`) | findings open | **passed** | 0/1/0 | 1 | 24, 243 s | 22, 222 s |
| 8 | Task 5 (`0eb6815`) | Approved | Approved | 0/0/2 | 2 | 12, 68 s | 15, 41 s |
| 9 | Task 5 fix round (`6941b7a`) | passed | passed | 0/0/0 | 0 | 13, 48 s | 13, 35 s |
| | **Total** | | same verdict 5 of 9 | 4/4/17 = 25 | 11 | 176, 1,747 s | 172, 1,196 s |

Opus's Critical and Important findings, one by one:

| # | Opus finding | Severity | Sonnet |
|---|---|---|---|
| 4 | mixed-case `az Repos PR CREATE` / `UPDATE` passes the create gate and the update deny | Critical | **missed**, and approved the task |
| 4 | with none of the three named, az can create the PR on another remote | Important | **missed** |
| 4 | a harmless update in a pipe or chain is denied | Important | **missed**; it probed that shape and flagged only the message's wording |
| 5 | gitleaks skips binary-looking text, so the secret passes | Critical | raised as Critical, verified; start-of-text signatures only, not the ones at an offset |
| 5 | a secret both literal and base64-encoded keeps its encoded copy | Critical | **missed** |
| 6 | the fix lets a completing update through when the option arrives by variable, `$(…)`, `xargs` or `"$@"` | Critical | raised as **Minor**, round passed |
| 6 | plain form: a completing option that is not a literal word is allowed | Important | mentioned as a known blind spot, not as a finding |
| 7 | an empty field is rendered as a redacted secret, with a false count | Important | raised as **Minor**, round passed |

By severity: Critical 2 of 4 raised (1 at Opus's severity), Important 1 of 4 (as Minor), Minor
8 of 17. Where the verdicts differ, Sonnet was the looser one three times (reviews 4, 6, 7) and
the stricter one once (review 2). All three looser verdicts are on safety-boundary tasks, and
the host line acted on Opus's findings in reviews 4 and 5 (fix commits `1da9bac`, `c701084`).
Reviews 6 and 7 left findings open at the time of writing; whether they are real waits for the
host line's next rounds, its final review and Codex.

Sonnet-only findings in reviews 4 to 9, hand-checked where a static read settles it:

| # | Sonnet-only finding | Hand check |
|---|---|---|
| 4 | the non-plain deny message names no az form | true (`PLAIN`, `xreview-guard.py:68-72`) |
| 4 | no row uses az's short options (`-s`, `-t`, …) | true |
| 4 | over-long comment lines in the front | true, cosmetic |
| 4 | a create value starting with `-` and holding a space is denied as an unknown option | not checked (needs the guard fixture) |
| 6 | "remotes besides origin (none)" when `git remote` fails | not checked |
| 7 | `communicate()` after the timeout kill has no timeout | true (`xreview-rpc:2160`) |
| 7 | no row pins `CD001` at 32769 | true |

None of the checked ones changes an allow or a deny.

**Reviews 10 and 11: the round-2 re-reviews of Tasks 6 and 2.**

| # | Review | Opus verdict | Sonnet verdict | Opus findings (C/I/M) | Sonnet raised | Opus tools, time | Sonnet tools, time |
|---|---|---|---|---|---|---|---|
| 10 | Task 6 fix round 2 (`427a954`) | findings open | findings open | 1/1/1 | 1 | 13, 204 s | 26, 241 s |
| 11 | Task 2 fix round 2 (`9495a80`) | passed | passed | 0/0/1 | 1 | 13, 139 s | 18, 112 s |

- Review 10, Critical: a word mixing quoted and unquoted parts with a substitution splits into
  a completing option, through the whitespace exemption. Sonnet **missed** it and called the
  exemption sound. The host line's loop stopped on this finding after three rounds.
- Review 10, Important: globs led by `?` or `[` are not treated as unreadable. Sonnet raised
  it, with an extglob form (`@(--status)`) Opus did not list; that is what keeps its verdict
  open.
- Review 10, Minor: the row that pins the exemption. Sonnet missed it.
- Review 11, Minor: no row pins an empty-file skip claimed for a non-empty file. Sonnet raised
  the same gap.

Running total, 11 reviews: Sonnet raised 13 of Opus's 29 findings (Critical 2 of 5, Important
2 of 5, Minor 9 of 19); same verdict on 7 of 11; Opus 202 tool calls and 2,090 s, Sonnet 216
and 1,549 s.

**Reviews 12 and 13: Task 3.**

| # | Review | Opus verdict | Sonnet verdict | Opus findings (C/I/M) | Sonnet raised | Opus tools, time | Sonnet tools, time |
|---|---|---|---|---|---|---|---|
| 12 | Task 3 (`ca4ea6b`) | needs fixes | needs fixes | 0/1/2 | 1 | 16, 104 s | 19, 100 s |
| 13 | Task 3 fix round 1 (`995db99`) | passed | passed | 0/0/0 | 0 | 12, 47 s | 11, 38 s |

- Review 12, Important: an empty `--raw ""` falls through to stdout (`if raw:`). Sonnet raised
  it, reproduced it and proposed the same fix.
- Review 12, Minor: no row pins the write-failure path; `$: unexpected key` repeats per key.
  Sonnet missed both.
- Review 12, Sonnet only, four Minor, not hand-checked: mode 0400 from the umask, a test
  comment citing R9f for R2, U+2028/2029 not escaped (Opus lists it as a residual risk), a
  RecursionError on deep nesting (pre-existing).

Running total, 13 reviews: Sonnet raised 14 of Opus's 32 findings (Critical 2 of 5, Important
3 of 6, Minor 9 of 21); same verdict on 9 of 13; Opus 230 tool calls and 2,241 s, Sonnet 246
and 1,687 s.

**Reviews 14 and 15: Task 8.**

| # | Review | Opus verdict | Sonnet verdict | Opus findings (C/I/M) | Sonnet raised | Opus tools, time | Sonnet tools, time |
|---|---|---|---|---|---|---|---|
| 14 | Task 8 (`b2a51fc`) | needs fixes | approved with minor fixes | 1/1/4 | 3 | 32, 326 s | 14, 195 s |
| 15 | Task 8 fix round 1 (`24a2249`) | passed | passed | 0/0/0 | 0 | 8, 91 s | 12, 151 s |

- Review 14, Critical (pre-existing, outside the task's diff, verified by Opus against the
  guard): `glab api --placeholder seg=merge_requests` hides a merge from the gate. Sonnet
  **missed** it.
- Review 14, Important: the line-782 comment claims a check of the `api` options on the new
  CLI versions. Sonnet raised it as an unverified claim; Opus read the help output and showed
  the claim false (`--placeholder` is missing), which is what led to the Critical.
- Review 14, Minor: Sonnet raised the incomplete "sandboxed is fine" header and the
  `installed:` line without the extension version. It missed the possible hidden hang, and it
  stated that the pins are here-documents where Opus found assignments.
- Review 14, Sonnet only, two Minor, not hand-checked: a missing extension gets the generic
  "listed no commands" message; the AGENTS.md paragraph does not name the extension.

Running total, 15 reviews: Sonnet raised 17 of Opus's 38 findings (Critical 2 of 6, Important
4 of 7, Minor 11 of 25); same verdict on 10 of 15; Opus 270 tool calls and 2,658 s, Sonnet 272
and 2,033 s.

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
