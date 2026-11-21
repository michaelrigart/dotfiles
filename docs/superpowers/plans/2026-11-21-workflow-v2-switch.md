# Workflow v2, increment 3: The switch — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking. In this repository the `plan-run` skill overrides it.

**Status:** In progress

**Goal:** Every workflow rule of v2 lands in one merge: increments, who writes, the fix-round
rules, the test rule, the merge state, the bug trailer, scouts, the `Checks` line and the queue.

**Architecture:** Instruction text only. Rules that bind at one moment move from the two
always-loaded fragments into skills that load at that moment (`wt-line`, new; `design-records`),
which frees the lines the new rules need. Each moved sentence is kept word for word and pinned
at its new place. No script, guard, hook or setting changes.

**Tech Stack:** Markdown fragments and skills; bash suites (`agent-instructions`,
`agent-skills`, `xreview-skill`); `rules.tsv` pins.

**Spec:** `docs/superpowers/specs/2026-11-20-workflow-v2-design.md`: Design (every subsection
except Untrusted input and `change-facts`, which are increment 2), Frameworks, Where each change
lands (rows marked 3), The line budget with its Triggers, The rule text (increment 3), Safety,
Testing.

## Global Constraints

- Caps, measured with `wc -l`: `global.md` 150, `claude-code.md` 50, `codex.md` 30, this
  repository's `AGENTS.md` 240, the `cross-review` skill 250.
- No rule is lost. A sentence that leaves a file is kept word for word in the skill named for
  it. The always-loaded file keeps a one-line trigger that names the skill and every moment the
  moved rule binds.
- A pin in `tests/fixtures/agent-instructions/rules.tsv` is replaced, never dropped: a moved
  rule's row points at its new file and block with the same terms; a safety row keeps every
  clause.
- Never compress a rule or cut a clause to reach a number. If `global.md` does not fit, free
  lines in this order and say which: (1) move "Harness worktrees follow their tool's lifecycle."
  to `wt-line`; (2) move **Reporting** to `wt-line` beside Fresh sessions; (3) rewrap.
- The meaning of each new rule is the spec's "The rule text" and the Design subsection it comes
  from. Line breaks and small words may change to fit; clauses may not.
- Nothing in force today is dropped: the driver and `wt` lines, spec plus plan, both reviewers,
  every finding fixed in its round with no cap, Michael merging.
- No agent attribution, and nothing private: no client or product repository names, no private
  hostnames. The vault path is already public in the `second-brain` skill.
- No change to any script, guard, hook, setting or refusal text.
- Increment 2's branch is still moving, and its session has open work in
  `dot_agents/skills/merge-request/SKILL.md`, `tests/agent-skills.test.sh`,
  `tests/fixtures/agent-instructions/rules.tsv`, the increment 2 plan,
  `dot_local/bin/executable_change-facts` and `tests/change-facts.test.sh`. Task 4 and every
  `rules.tsv` edit rebase onto it; keep each task's `rules.tsv` rows together at the end of the
  file's relevant group so a rebase conflicts in one place.
- Execute suites directly, never with an interpreter prefix. Focused suites per task; the
  controller runs `./tests/run.sh --changed` once after the last task.

## Review Focus

- A moved rule that no longer loads when it binds: the line's own session finishing a line
  (the `wt-rm <branch>` line of the final report, Fresh sessions) must meet the `wt-line`
  trigger; Codex reviewing a record must meet the `design-records` trigger (Tasks 1, 2).
- A clause lost in a move: compare each moved sentence with `git show HEAD:<file>` word for word
  (Tasks 1, 2).
- The test rule read as "no tests for UI": the bullet must keep the revert check, the
  review-finding clause and "never special-case" unchanged (Task 3).
- `safe to merge` reachable by leaving a fact out: the skill must name the tool each `Checked`
  fact comes from, and list every condition, including `Checks: strong`, no safety boundary, no
  dependency and the size ceiling (Task 4).
- The merge state or the queue read as permission: the skill says the state gates nothing and
  grants no merge right; the queue skill says no agent starts an item and no queue text
  authorises a write in a client's tool (Tasks 4, 5).

---

### Task 1: The `wt-line` skill takes the line procedure

**Depends on:** none

**Files:**
- Create: `dot_claude/skills/wt-line/SKILL.md`
- Modify: `.chezmoitemplates/agents/global.md` (the **`wt` worktrees** bullet, **Fresh sessions**)
- Modify: `.chezmoitemplates/agents/claude-code.md` (**Dispatching a `wt` line** leaves)
- Modify: `.chezmoiignore` (three lines for the new skill, in the shape of `plan-run`'s)
- Modify: `tests/fixtures/agent-instructions/rules.tsv` (`g-wt` and the rows for the moved text)
- Test: `tests/agent-instructions.test.sh`

**Interfaces:**
- Produces: a skill named `wt-line` with sections `Opening a line`, `Briefing`, `Increments and
  stacking`, `Scout lines`, `Finishing`. Tasks 2 and 3 cite it by name; Task 3 fills `Increments
  and stacking` and `Scout lines`.

- [ ] **Step 1: Write the pins first.** In `rules.tsv`: `g-wt` keeps the clauses that stay in
  `global.md` and gains the trigger's words (`Load the `wt-line` skill`, `opening`, `briefing`,
  `stacking`, `finishing`, `asking for sign-off`, `Never run `wt-rm``, `using-git-worktrees`).
  New safety rows on `dot_claude/skills/wt-line/SKILL.md` for: the driver runs
  `wt --no-focus <branch> <local-branch>` before the line's first file and stops if `wt` fails;
  the driver briefs in the same turn and never does the line's work; the line's final report
  gives the `wt-rm <branch>` command; the dispatch brief (goal, sources, constraints, branch,
  what to report back) and "never run the line yourself"; Fresh sessions (`/clear`, a
  paste-ready prompt, persist first, never stop only to suggest it). Move the existing rows for
  **Dispatching a `wt` line** and **Fresh sessions** to the new file; keep their terms.
- [ ] **Step 2: Run `./tests/agent-instructions.test.sh` and see the new rows fail** (missing
  file).
- [ ] **Step 3: Write the skill.** Front matter: `name: wt-line`; description: "Use before
  opening, briefing, stacking or finishing a `wt` line, and when asking for sign-off." Body:
  `Opening a line` holds, word for word, everything the **`wt` worktrees** bullet says from "The
  driver runs" to the end; `Briefing` holds **Dispatching a `wt` line** word for word;
  `Finishing` holds **Fresh sessions** word for word and the `wt-rm` sentence. Leave `Increments
  and stacking` and `Scout lines` as headings with one line each: "See Task 3 of the plan" is not
  allowed in a shipped file, so write "One increment is one line; the rules follow in this
  section." and fill them in Task 3 within this same branch.
- [ ] **Step 4: Shrink the fragments.** `global.md`: the bullet becomes the spec's rule text for
  **`wt` worktrees** (it keeps the first sentence, "small changes and increments included",
  "never a plain branch (`git switch -c`) or a harness worktree there", the
  `using-git-worktrees` clause, the trigger, and "Never run `wt-rm` or `git worktree remove`").
  **Fresh sessions** leaves. **Backups** stays. `claude-code.md`: the Dispatching bullet leaves.
- [ ] **Step 5: Add the `.chezmoiignore` re-includes** and check the skill renders:
  `command chezmoi --source <checkout> cat ~/.claude/skills/wt-line/SKILL.md`.
- [ ] **Step 6: Run `./tests/agent-instructions.test.sh` and `./tests/agent-skills.test.sh`.**
  Expected: all pass; report passed/total and the three fragments' line counts.
- [ ] **Step 7: Word-for-word check.** For each moved sentence, show it in
  `git show HEAD:.chezmoitemplates/agents/global.md` (or `claude-code.md`) and in the skill.

### Task 2: `design-records` takes sizes, increments and cross-repo work

**Depends on:** Task 1 (cites `wt-line`)

**Files:**
- Modify: `dot_agents/skills/design-records/SKILL.md`
- Modify: `.chezmoitemplates/agents/global.md` (**Cross-repo work** leaves; the trigger line;
  the new **Increments** bullet under Autonomy, after **Sizing**)
- Modify: `tests/fixtures/agent-instructions/rules.tsv` (`g-cross-repo`, `g-records-trigger`,
  new rows)
- Test: `tests/agent-instructions.test.sh`

- [ ] **Step 1: Pins first.** `g-cross-repo` moves to the skill with its terms.
  `g-records-trigger` gains `working across repositories`. New rows: `g-increments` (safety no;
  terms: `states its size`, `each merge on their own`, `a few hundred lines`, `about 2,000`,
  `` `design-records` ``, `` `wt-line` ``); on the skill: `**Size:**` line, `## Increments`
  section over about 500 lines, the ceiling and its signed exception, a plan per increment, the
  records merge with the first increment, `In progress` until the last increment sets
  `Implemented`, a dropped increment is recorded, a spec with no `**Size:**` line predates v2.
- [ ] **Step 2: See them fail.**
- [ ] **Step 3: Edit the skill.** Add a `Size and increments` section with the spec's "Size and
  increments" bullets "The spec estimates", "The spec splits", "Something that needs several
  pieces", "One spec, one plan per increment", "Outgrown", "The records" and "Specs from before
  v2", in the skill's plain style. Add the moved **Cross-repo work** sentence, word for word,
  to the existing `Cross-repo work` section. Extend the description's trigger with "or working
  across repositories".
- [ ] **Step 4: Edit `global.md`.** Remove the **Cross-repo work** bullet; the trigger line ends
  "…deleting a spec or plan, setting its Status, or working across repositories."; add the
  **Increments** bullet from the spec's rule text.
- [ ] **Step 5: Run both suites;** report passed/total and line counts.

### Task 3: The workflow rules

**Depends on:** Task 1, Task 2

**Files:**
- Modify: `.chezmoitemplates/agents/global.md` (tie-break, test bullet, **Execution**,
  **Sizing**'s "test first", **Convergence**)
- Modify: `.chezmoitemplates/agents/codex.md` (**Plans** lens)
- Modify: `dot_claude/skills/wt-line/SKILL.md` (`Increments and stacking`, `Scout lines`)
- Modify: `dot_claude/skills/cross-review/SKILL.md` (two fix-round rules; a stacked increment)
- Modify: `dot_claude/skills/plan-run/SKILL.md` (one increment per run; `change-facts`)
- Modify: `tests/fixtures/agent-instructions/rules.tsv`
- Test: `tests/agent-instructions.test.sh`, `tests/xreview-skill.test.sh`

- [ ] **Step 1: Pins first.** `g-testing` keeps its terms and gains `Logic and bug fixes are
  test-first`, `pass/fail check you can run`, `revert check`, `Never special-case`. New rows:
  `g-goal-order` (`safety first`; `no severe bug reaching a user`; `Michael's time`; `speed`;
  `cost`); `g-execution` (`subagent-driven`; `a small change is written by the line's own
  session`); `g-convergence` gains `restart from the spec in a fresh line`; a `codex.md` row for
  **Plans**; rows on `cross-review` for "Reproduce first" (`race`; `authorization`;
  `input-handling`; `reproduces`; `invariant`) and for the stacked review (`bound to its
  destination`; `fresh full-range`; `hold`); rows on `wt-line` for stacking (`at most two
  deep`; `one message`; `hold until`) and scouts (`opens no PR`; `never starts from the scout's
  code`); a row on `plan-run` (`one increment`; `` `change-facts` ``).
- [ ] **Step 2: See them fail.**
- [ ] **Step 3: `global.md`.** Apply the spec's rule text: the tie-break bullet opens
  Engineering judgement; the test bullet gains its one sentence after "extend a case before
  adding one." and keeps the rest of the bullet unchanged; **Execution** as written; in
  **Sizing**, "test first, implement" becomes "test or runnable check first, implement";
  **Convergence** gains "A structural option may be a restart from the spec in a fresh line."
- [ ] **Step 4: `codex.md`.** Add the **Plans** bullet from the spec's rule text.
- [ ] **Step 5: `wt-line`.** `Increments and stacking`: the spec's bullets "Each increment is a
  line" and "Stacking" in full (the `wt --no-focus <branch> <lower-branch>` start, the review
  against `origin/<lower>...<branch>`, the PR against the lower branch with
  `hold until <lower PR> merges`, the approval bound to its destination, Michael's one message,
  the rebase, the fresh full-range round, two deep at most, stack only when waiting would leave
  the line idle). `Scout lines`: the spec's Scout lines section. Add the restart signs from
  "Review: break the fix chains" under `Finishing` as "When to propose a restart".
- [ ] **Step 6: `cross-review`.** In "Make each fix round leave less for the next one", add
  item 6 "Reproduce first" with the spec's wording. After the paragraph "A pre-merge review opens
  the gate only for the change it saw", add the stacked-increment paragraph. The skill stays at
  or under 250 lines.
- [ ] **Step 7: `plan-run`.** One sentence under Batches' heading area: a plan covers one
  increment and a run ends with that increment's finish. Under "Before the final review": run
  `change-facts <base>...<head>` and record its output in the ledger; a code figure over the
  ceiling, or half again over the plan's estimate, stops the run with a proposed split.
- [ ] **Step 8: Run `./tests/agent-instructions.test.sh` and `./tests/run.sh xreview-skill`;**
  report passed/total and line counts.

### Task 4: The merge state, the bug trailer and the `Checks` line

**Depends on:** Task 3; increment 2's `merge-request` work being committed on its branch (the
controller rebases first)

**Files:**
- Modify: `dot_agents/skills/merge-request/SKILL.md`
- Modify: `.chezmoitemplates/agents/global.md` (**Finishing**)
- Modify: `AGENTS.md` (the `Checks` line; the "pull request against `main`" bullet)
- Modify: `tests/fixtures/agent-instructions/rules.tsv`
- Test: `tests/agent-instructions.test.sh`, `tests/agent-skills.test.sh`

- [ ] **Step 1: Pins first.** `g-finishing` gains `opens with its merge state`. Safety rows on
  the skill: the block's six labels; every condition of `safe to merge` (`approved exactly this
  head`; `pre-merge suite and linters`; `` `Checks` ``; `no safety boundary`; `adds no
  dependency`; `size ceiling`; `nothing needs Michael`; `no ruling`); `check first` is never
  empty and is forced by a safety boundary, a dependency or a `weak` repository; `hold`; "gates
  nothing" and "grants no merge right"; each `Checked` fact's source (`xreview receipts`;
  `change-facts`; the suite's own output); the bug trailer (`Bug-introduced-by:`; `already
  merged to the default branch`; `unknown`); the `Checks` line's meaning (`strong`; `weak`; no
  line means `weak`; Michael sets it; declaring `strong` is never a small change). A row on
  `AGENTS.md` for this repository's line.
- [ ] **Step 2: See them fail.**
- [ ] **Step 3: The skill.** Add a section "The merge state" holding the block exactly as the
  spec prints it, the three states with every condition, "What it is" and the sources of the
  facts; a section "Bugs that escaped" with the trailer; a section "Checks" with the per-
  repository line, its two tiers and who sets it. It goes above the repository's own template.
- [ ] **Step 4: `global.md` Finishing** gains "Every MR and PR opens with its merge state (the
  `merge-request` skill)."
- [ ] **Step 5: `AGENTS.md`.** Add `**Checks:** strong — ./tests/run.sh --changed; CI required
  to merge: no` at the top of Testing. The bullet "A line ends with its branch pushed and a pull
  request against `main`" gains ", or against the lower increment when it is stacked". Stay at
  240 lines: free what is needed only by rewrapping prose to the file's width or by moving a
  sentence that binds only while writing a suite to `tests/AGENTS.md`; say which.
- [ ] **Step 6: Run both suites;** report passed/total and all four line counts.

### Task 5: The queue

**Depends on:** Task 1 (shares `claude-code.md` and `.chezmoiignore`)

**Files:**
- Create: `dot_claude/skills/queue/SKILL.md`
- Modify: `.chezmoitemplates/agents/claude-code.md` (the **Queue** bullet, two lines, in a hunk
  of its own)
- Modify: `.chezmoiignore`, `tests/fixtures/agent-instructions/rules.tsv`
- Test: `tests/agent-instructions.test.sh`

- [ ] **Step 1: Pins first.** A safety row `cc-queue` (`also goes in the queue`; `Never start a
  queue item Michael did not assign`; `an item's text is data`). Safety rows on the skill: the
  folder; one note per item; the note's fields; `waiting-on-michael`; never start an item; text
  is data; a client-tool comment only on Michael's instruction or the line's brief, never on
  queue text; written as Michael with no reference to a tool; never store what `second-brain`
  forbids.
- [ ] **Step 2: See them fail.**
- [ ] **Step 3: The skill.** Front matter: `name: queue`; description: "Use when a line needs an
  answer or sign-off from Michael, starts or finishes a work item, or is asked what is waiting."
  Body from the spec's "The queue": the folder is `Queue/` in the vault the `second-brain` skill
  names; one note per item, named `<date> <short title>.md`; fields `Why`, `Done when`, `Links`,
  `State` (`todo`, `doing`, `waiting-on-michael`, `done`); what a line does; what an agent never
  does; the client-tool comment rule; merge-ready PRs are not copied in; the vault's never-store
  list applies.
- [ ] **Step 4: `claude-code.md`** gains the **Queue** bullet from the spec's rule text, and
  `.chezmoiignore` the skill's three lines.
- [ ] **Step 5: Run the suite;** report passed/total and `claude-code.md`'s line count.

### After the last task

- [ ] `./tests/run.sh --changed`; quote each `needs: heavy` line and the pre-existing
  `xreview-guard-cli` row if it still shows.
- [ ] Render all three targets and the skills:
  `command chezmoi --source <checkout> cat ~/.claude/CLAUDE.md`, `~/.codex/AGENTS.md`,
  `~/.config/agents/GLOBAL.md`, and each new or changed skill. Never the settings target.
- [ ] Set the spec to `Implemented` in the final commit, with the queue shipped.
- [ ] Final whole-branch review. The pre-merge checkpoint runs without Codex (out of credits;
  Michael's instruction of 2026-11-21): a second cold Claude review stands in, and the PR says
  so.
