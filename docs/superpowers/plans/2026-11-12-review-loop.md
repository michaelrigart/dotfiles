# Review Loop Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development to
> implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Status:** Approved

**Goal:** Ship the signed-off review-loop rules: triage of Claude-side findings, a narrowed per-task
review, the full suite once per plan run, the routing cells, one Codex lens sentence, and
dispatch of a `wt` line in the turn its checkout opens.

**Architecture:** Instruction text only. A new tracked skill `plan-run` holds the controller
procedure; two bullets in `claude-code.md` make it load and bind the triage; one-line edits reach
`sp-mechanical`, `sp-reviewer`, `sp-architect`, Codex's `reviewer.md` and `global.md`. Each rule is
checked by a row in `tests/fixtures/agent-instructions/rules.tsv`.

**Tech Stack:** Markdown fragments rendered by chezmoi; bash suites under `tests/` run through
`./tests/run.sh`.

**Spec:** `docs/superpowers/specs/2026-11-12-review-loop-design.md`. Every fenced block the tasks
name is copied from it verbatim.

## Global Constraints

- **Base.** The run starts only after `chore/test-audit` is on `main` and this branch is rebased
  onto it (Task 0). `tests/fixtures/agent-instructions/rules.tsv` must exist.
- **Caps.** `.chezmoitemplates/agents/global.md` at most 150 lines and no line over 100 columns;
  `claude-code.md` at most 50 lines, prose lines at most 100 columns (table rows may exceed);
  `codex.md` untouched.
- **Scope.** No edit to `xreview` code, the findings schema, `codex.md`, `cross-review/SKILL.md`,
  the superpowers plugin, or the testing rule the test-audit rewrote.
- **Public repository:** nothing private in any tracked file.
- **Row format.** `rules.tsv` rows are tab-separated: id, file, anchor, safety (`yes`/`no`), terms,
  note. Terms are separated by `;`; a literal semicolon is `\;`. The anchor must occur in exactly
  one block of the file, and that block must hold every term.
- **Test first, and the revert check.** Each task adds or changes its rows first and watches
  `./tests/run.sh agent-instructions` fail on them, then edits the text. After it passes, delete
  one key clause the row names from the text, watch the row fail, restore it. Report both outputs.
- **Suites.** Implementers run only the suites their task names, executed through `./tests/run.sh`
  (never with an interpreter prefix), and never the full suite. The controller runs the full suite
  once, in Task 6.
- **This run follows the spec's own rules** (signed off 2026-11-12, not yet deployed):
  - per-task review on `sp-reviewer` for Tasks 1 and 2 only (Task 2 extends Task 1's skill; Task 2
    carries the quality-bar rule); Tasks 3, 4 and 5 get the controller's check: re-run the task's
    suites, compare the commit's files with the task's, read lines removed from test files;
  - a reviewer finding gets code only when it names an Engineering judgement cost or a real caller;
    unsure counts as real; any other finding is a ledger line
    `Ruling: no code — <finding> — <theoretical|style>: <why>`;
  - dispatch the `sp-*` type and never pass `model`.
- **Commits.** One commit per task, imperative mood, no agent attribution. Check
  `git branch --show-current` prints `feat/review-loop` before each commit.

## Review Focus

- A row's anchor appearing in two blocks of its file (the checker then fails with "anchor in 2
  blocks"): each new anchor is checked for uniqueness by the suite itself.
- `claude-code.md` passing 50 lines after Task 2 or Task 5: the cap test in `agent-instructions`
  covers it; each task reports `wc -l`.
- A reworded `wt` bullet that drops the unchanged `wt-rm` sentence: the `g-wt` row keeps that term.
- The skill not reaching `$HOME` because its `.chezmoiignore` re-include is missing:
  `claude-settings` loops over every `dot_claude/skills/*/SKILL.md`, and Task 6 checks
  `chezmoi managed`.
- The golden packets going stale after `reviewer.md` changes: Task 4 runs `xreview-packet`, and
  Task 6 runs the heavy `xreview` suite by exact name.

---

### Task 0: Rebase onto the merged test-audit (controller)

**Depends on:** `chore/test-audit` merged to `main` by Michael.

- [ ] **Step 1:** `git -C ~/.local/share/chezmoi-feat-review-loop fetch origin`, then confirm
  `git cat-file -e origin/main:tests/fixtures/agent-instructions/rules.tsv` succeeds. If it fails,
  stop: the run is blocked on the test-audit merge.
- [ ] **Step 2:** `git rebase origin/main` (the branch is unpublished). Confirm
  `./tests/run.sh agent-instructions` passes before any task starts and record passed/total.

### Task 1: The `plan-run` skill, the Plan runs bullet and the implementer suite line

**Depends on:** Task 0.

**Files:**
- Create: `dot_claude/skills/plan-run/SKILL.md`
- Modify: `.chezmoiignore` (after the `cross-review` re-include), `.chezmoitemplates/agents/claude-code.md`
  (the Parallel tasks bullet), `dot_claude/agents/sp-mechanical.md` (the "Run the project's tests"
  bullet), `tests/fixtures/agent-instructions/rules.tsv`

**Interfaces:**
- Produces: the skill file with sections Batches, Which tasks get a per-task review, Tests,
  Routing, Before the final review. Task 2 adds a `## Triage` section between "Which tasks get a
  per-task review" and "Tests".

- [ ] **Step 1: rows.** In `rules.tsv`, replace the `cc-parallel` row and add four rows
  (`SK` = `dot_claude/skills/plan-run/SKILL.md`, `CC` = `.chezmoitemplates/agents/claude-code.md`):

| id | file | anchor | safety | terms | note |
|---|---|---|---|---|---|
| `cc-plan-runs` | CC | `**Plan runs.**` | no | `` `Depends on:` ``;`never in a worktree per task`;`` first load the `plan-run` skill ``;`it overrides superpowers` | plans declare dependencies and run in the line's checkout; the plan-run skill loads first |
| `pr-review-set` | SK | `A task gets the task review` | yes | `` on `sp-reviewer`) when it touches a safety boundary as global Sizing lists it, or when a later task calls, extends or reads what it creates ``;`does not count` | which tasks keep a per-task review |
| `pr-check` | SK | `Every other task gets your check` | no | `no reviewer`;`run its focused tests yourself`;`compare its commit's files with the brief's`;`removes from test files`;`fix round`;`still read every task` | unreviewed tasks get the controller's check |
| `pr-tests` | SK | `never the full suite` | no | `suites for what you changed`;`You run the full suite once, after the last task`;`before dispatching the final review` | the full suite runs once per plan run |
| `pr-real-run` | SK | `Run the change once the way its user will` | yes | `inside the sandbox`;`Record the command and what it showed in the ledger.`;`What needs Michael (an apply, an unsandboxed or live suite) goes in the final report as his step.` | a sandboxed real-system run before the final review |

- [ ] **Step 2:** run `./tests/run.sh agent-instructions`; expected: FAIL on the five rows
  (anchor not found, or file missing).
- [ ] **Step 3: the skill.** Create `SKILL.md` from the spec's §6 fenced block, **without** its
  `## Triage` section (Task 2 adds it), with the review-set paragraph as §6 has it.
- [ ] **Step 4:** add the skill's three-line re-include to `.chezmoiignore`, shaped like the
  `cross-review` one (`!.claude/skills/plan-run/`, `.claude/skills/plan-run/*`,
  `!.claude/skills/plan-run/SKILL.md`).
- [ ] **Step 5:** in `claude-code.md`, replace the six-line **Parallel tasks.** bullet with the
  two-line **Plan runs.** bullet from the spec's §7. Expected `wc -l`: 46.
- [ ] **Step 6:** in `sp-mechanical.md`, replace the "Run the project's tests and linters" bullet
  with the two-line bullet from the spec's §3.
- [ ] **Step 7:** run `./tests/run.sh agent-instructions claude-settings test-audit`; expected:
  all pass. Do the revert check on `pr-review-set` twice (delete "when it touches a safety
  boundary as global Sizing lists it, or"; then delete "A task gets the task review" through
  "`sp-reviewer`)") and on `cc-plan-runs` (delete "first load the `plan-run` skill").
- [ ] **Step 8:** commit: `Add the plan-run skill and run the full suite once per plan run`.

### Task 2: Triage of Claude-side findings

**Depends on:** Task 1.

**Files:**
- Modify: `.chezmoitemplates/agents/claude-code.md`, `dot_claude/skills/plan-run/SKILL.md`,
  `dot_claude/agents/sp-reviewer.md`, `dot_claude/agents/sp-architect.md`,
  `tests/fixtures/agent-instructions/rules.tsv`

**Interfaces:**
- Consumes: Task 1's skill file and its section order.

- [ ] **Step 1: rows.** Add:

| id | file | anchor | safety | terms | note |
|---|---|---|---|---|---|
| `cc-review-findings` | CC | `**Claude review findings.**` | yes | `` For `sp-reviewer` and `sp-architect`, Fix now narrows: a finding gets code only when it names an Engineering judgement cost or a real caller reaching its failure (a code path, an input the system accepts, an attacker its threat model names\; unsure counts as real). ``;`Any other finding gets one line under Rulings.`;`` Codex findings: the `cross-review` skill. `` | Claude-side findings get code only with a real caller or a named cost; Codex findings are untouched |
| `sp-reviewer-caller` | `dot_claude/agents/sp-reviewer.md` | `Every finding carries` | no | `the caller that produces it`;`or none` | sp-reviewer reports each finding's caller |

- [ ] **Step 2:** run `./tests/run.sh agent-instructions`; expected: FAIL on both rows.
- [ ] **Step 3:** add the four-line **Claude review findings.** bullet from the spec's §1 to
  `claude-code.md`, directly after the **Plan runs.** bullet. Expected `wc -l`: 50.
- [ ] **Step 4:** add the `## Triage` section from the spec's §6 to the skill, between "Which
  tasks get a per-task review" and "Tests".
- [ ] **Step 5:** in `sp-reviewer.md`, replace the "Every finding carries" bullet with the spec's
  §1 three-line version; in `sp-architect.md`, add the spec's §1 two-line caller bullet after the
  Engineering judgement bullet.
- [ ] **Step 6:** run `./tests/run.sh agent-instructions claude-settings test-audit`; expected:
  all pass. Revert check on `cc-review-findings` three times (delete "only"; delete "unsure counts
  as real"; delete the Codex sentence) and on `sp-reviewer-caller` (delete the caller clause).
- [ ] **Step 7:** commit: `Triage findings from Claude's own reviewers`.

### Task 3: Routing cells

**Depends on:** Task 2 (same file).

**Files:**
- Modify: `.chezmoitemplates/agents/claude-code.md` (the `sp-reviewer` and `sp-architect` table rows)

- [ ] **Step 1:** replace the two rows with the two from the spec's §4. No other row changes.
- [ ] **Step 2:** run `./tests/run.sh agent-instructions`; expected: all pass, `wc -l` 50, and
  the existing `cc-table-standard` row still passes.
- [ ] **Step 3:** commit: `Route per-task reviews to sp-reviewer and fixes away from sp-architect`.

### Task 4: Codex lens sentence

**Depends on:** Task 3 (shares `rules.tsv`).

**Files:**
- Modify: `dot_config/xreview/reviewer.md`, `tests/fixtures/agent-instructions/rules.tsv`, and the
  golden packets under `tests/fixtures/xreview-packet/` only through `regenerate.sh`

- [ ] **Step 1: row.** Add: `xr-lens`, `dot_config/xreview/reviewer.md`, anchor
  `A finding is a defect`, safety `no`, terms `code the change could delete without losing
  behaviour`;`pins wording`;`repeats an existing case`, note "Codex's lens names deletable code and
  surplus tests".
- [ ] **Step 2:** run `./tests/run.sh agent-instructions`; expected: FAIL on `xr-lens`.
- [ ] **Step 3:** replace the first sentence of the "A finding is a defect" paragraph (through
  "the bug back.") with the spec's §5 sentence; the paragraph's remaining sentences stay.
- [ ] **Step 4:** run `./tests/run.sh agent-instructions xreview-packet`. If `xreview-packet` is
  red only on golden packets, run `tests/fixtures/xreview-packet/regenerate.sh`, read its diff
  (only the lens sentence may differ) and re-run. Expected: all pass. Revert check on `xr-lens`
  (delete "code the change could delete without losing behaviour,").
- [ ] **Step 5:** commit: `Give Codex's lens the deletion and surplus-test clauses`.

### Task 5: Dispatch a `wt` line at once

**Depends on:** Task 4 (shares `rules.tsv`).

**Files:**
- Modify: `.chezmoitemplates/agents/global.md` (the `wt` worktrees bullet),
  `.chezmoitemplates/agents/claude-code.md` (the Dispatching bullet),
  `tests/fixtures/agent-instructions/rules.tsv`

- [ ] **Step 1: rows.**
  - In `g-wt`, replace the term that starts "It writes and commits the spec in that checkout" with:
    `In the same turn it briefs the checkout's session, which does the recon, writes the spec, asks
    Michael for sign-off in its own pane and runs the line, taking spec changes to him\; the driver
    keeps only briefing and collecting the report, never the line's work.` Every other term stays.
  - Replace `cc-dispatch-wt`'s terms with: `` In the turn that ran `wt` ``;`goal, sources,
    constraints, branch,`;`what to report back`;`runs the line itself, spec included`;`never run
    the line`.
- [ ] **Step 2:** run `./tests/run.sh agent-instructions`; expected: FAIL on both rows.
- [ ] **Step 3:** reword both bullets as the spec's §9 gives them, fitting each line to 100
  columns. Expected `wc -l`: `global.md` 150 or fewer, `claude-code.md` 50.
- [ ] **Step 4:** run `./tests/run.sh agent-instructions test-audit`; expected: all pass. Revert
  check on `g-wt` (delete "In the same turn") and `cc-dispatch-wt` (delete "spec included").
- [ ] **Step 5:** commit: `Brief a wt line's session in the turn its checkout opens`.

### Task 6: Full suite, real-system run, final review (controller)

**Depends on:** Task 5.

- [ ] **Step 1:** `./tests/run.sh`, then
  `./tests/run.sh xreview git-forge-guard wt-functions`; record passed/total per run. A red suite
  is a fix round before the final review.
- [ ] **Step 2: real-system run, sandboxed.**
  `command chezmoi --source ~/.local/share/chezmoi-feat-review-loop cat ~/.claude/CLAUDE.md` shows
  the Plan runs and Claude review findings bullets and the reworded dispatch text;
  `command chezmoi --source ~/.local/share/chezmoi-feat-review-loop managed` lists
  `.claude/skills/plan-run/SKILL.md`. Record both in the ledger.
- [ ] **Step 3:** final whole-branch review on `sp-architect`, handed the ledger's rulings; one fix
  wave on `sp-standard`; one scoped re-review.
- [ ] **Step 4:** set the spec's and this plan's `**Status:** Implemented` in the final commit, then
  Codex's pre-merge review (`xreview dispatch --checkpoint pre-merge --diff origin/main...feat/review-loop`),
  to approval. Push `feat/review-loop`. The final report gives Michael passed/total, the Codex
  receipts, the apply step, the 14-day measurement date and `wt-rm feat/review-loop`.
