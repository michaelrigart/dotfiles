# Workflow tuning Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Status:** In progress on `improvements` (the dotfiles have no MR)

**Goal:** Faster runs at the same quality bar. Process is sized to the change, loops that stop
converging are escalated, verification runs in parallel and only as often as needed, and cleanup
never blocks a run. In addition: engineering-judgement and review-lens rules, subagent routing,
fresh-session prompts, a context figure in the statusline, shared skills for two procedures, a
corrected path-guard message, a memory-index line check, and current Codex config seeds.

**Architecture:** instruction fragments, agent definitions, the cross-review skill, two new shared
skills, four small script changes (path guard, statusline, memory-health hook, Codex config
template), the reviewer prompt, and a parallel, self-locking `tests/run.sh`.

**Tech Stack:** bash (3.2-compatible where the file says so), jq, BSD `lockf(1)`, chezmoi
templates, Python 3 (xreview fixtures).

**Spec:** `docs/superpowers/specs/2026-10-30-workflow-tuning-design.md` (signed off 2026-10-31).
Read it whole before any task: it holds the exact instruction texts this plan applies.

## Global Constraints

- **Edit only the source.** Never a deployed file, and never `chezmoi apply`: that is Michael's.
- **Running suites:** execute them, never prefix an interpreter. Until this branch merges, another
  session runs full suites under `lockf -k /tmp/claude-$(id -u)/chezmoi-fullsuite.lock`. So wrap
  every run in the same lock, to keep its timing-sensitive suites off a loaded machine:
  `lockf -k /tmp/claude-$(id -u)/chezmoi-fullsuite.lock ./tests/run.sh <exact-suite-name>`.
  This is safe after Task 2 too, because the new runner locks a different file.
- **Implementers in a batch** do not commit. They run only their focused suites. The controller
  commits each task on its own and reviews it on exactly that commit.
- **Commits:**
  - imperative mood, with no agent attribution;
  - re-check `git branch --show-current` (`improvements`) right before each;
  - check `git diff --cached` before each.
- **Caps:** `global.md` at most 180 lines, `claude-code.md` at most 50.
- **Public repository.** Nothing private goes in any file.
- **Quality bar.** Every task obeys the spec's Engineering judgement section:
  - the simplest structure that holds;
  - one test per behaviour, naming the bug it catches;
  - no unrequested files.

## Review Focus

1. **`run.sh` must not change a verdict.** Parallel and sequential runs give byte-identical
   reports. Exit status, the `INCONSISTENT` cross-check and the kv idiom are untouched. Task 2.
2. **No deadlock:**
   - a nested runner, which `run.test.sh` drives;
   - the retired manual wrapper around the new runner;
   - a filtered run while a full run holds the lock.

   Task 2.
3. **No rule lost in the moves.** Every rule that leaves `global.md` lands in a skill. Every hard
   rule stays in `global.md`, verbatim where the spec says so. Tasks 4 and 5.
4. **Pinned fragments stay on one line.** For example, ``sdd-clean <workspace>`, never `rm -rf`.``
   is pinned by `agent-instructions`. Task 4.
5. **Golden fixtures** are regenerated only with the pinned reference dispatcher. Task 11.

## File map

| Task | Files |
|---|---|
| 1 | none (measurement after Batch A; results in the plan workspace) |
| 2 | `tests/run.sh`, `tests/run.test.sh` |
| 3 | headers of `tests/*.test.sh` chosen by the baseline |
| 4 | `.chezmoitemplates/agents/global.md`, `.chezmoitemplates/agents/claude-code.md`, `tests/agent-instructions.test.sh` |
| 5 | `dot_agents/skills/merge-request/SKILL.md`, `dot_agents/skills/second-brain/SKILL.md`, `dot_claude/skills/symlink_merge-request`, `dot_claude/skills/symlink_second-brain`, `.chezmoiignore`, `tests/agent-skills.test.sh` |
| 6 | `dot_claude/agents/sp-architect.md`, `sp-standard.md`, `sp-reviewer.md` |
| 7 | `dot_claude/skills/cross-review/SKILL.md` |
| 8 | `dot_claude/executable_path-resolution-guard.sh`, `tests/path-resolution-guard.test.sh` |
| 9 | `dot_claude/executable_statusline.sh`, `tests/statusline.test.sh` |
| 10 | `dot_claude/hooks/executable_memory-health.sh`, `tests/memory-health.test.sh` |
| 11 | `dot_config/xreview/reviewer.md`, `tests/fixtures/xreview-packet/*` |
| 12 | `dot_codex/modify_private_config.toml`, `tests/codex-config.test.sh` |
| 13 | `AGENTS.md` |
| 14 | `~/.claude/projects/-Users-michael--local-share-chezmoi/memory/MEMORY.md` and topic files (not in the repo) |

Batches:
- Batch A runs Tasks 2 and 4–12 together. Their files are disjoint, and none of their suites
  loads another task's files.
- Task 1 then times the suites on the code as it stands after Batch A. Both modes measure the
  same code, so its sequential total is the fair comparison for the parallel runner.
- Then Task 3, then Task 13.
- Task 14 runs in the main session at the end.

---

### Task 1: Timing baseline

**Depends on:** Batch A (2, 4–12). **Tier:** controller (no subagent).

- [ ] Under the other session's lock (Global Constraints), run every suite that has no
      `# test-requires:` line, one at a time. Record the seconds and exit status of each in
      `.superpowers/sdd/2026-10-31-workflow-tuning/baseline.txt`, along with the total.
- [ ] Note in the ledger every suite over 120 s (heavy candidates) and every suite that fails on
      the baseline (pre-existing red, not caused by this branch).

### Task 2: Parallel, self-locking runner

**Depends on:** none. **Tier:** sp-standard.

Spec §11. Behaviour:
- **Same selection as today:** filters, the `# test-requires:` gate, `# test-args:`.
- **Locking:**
  - Unless `RUN_SH_LOCKED=1` is set, the runner takes `lockf` on
    `${RUN_SH_LOCK:-/tmp/claude-$(id -u)/tests-run.lock}` (`mkdir -p` its directory first).
  - When the lock is busy it prints one line naming the lock and saying it is waiting, then
    waits.
  - It exports `RUN_SH_LOCKED=1` to its suites.
  - Re-executing itself under `lockf` is fine.
- **Jobs:** `RUN_JOBS` if set, otherwise half the online CPUs, at least 2. If the CPU count
  cannot be read in the sandbox, use 4.
- **Execution:**
  - Suites without `# test-serial` run concurrently, at most that many at once. Each one's
    combined output and exit status are captured to a work directory under `$TMPDIR`.
  - Then the `# test-serial` suites run one at a time.
  - No `wait -n`, which bash 3.2 lacks; an `xargs -P` driver with an internal per-suite mode is
    the expected shape.
- **Report:**
  - Suites are printed in name order through the existing judging code, unchanged.
  - The output of a parallel run is byte-identical to `RUN_JOBS=1` for the same suites.
- **Header comment:** document `RUN_JOBS`, `# test-serial`, the lock, `RUN_SH_LOCK` and
  `RUN_SH_LOCKED`.

Tests (`tests/run.test.sh`). Every fixture invocation sets `RUN_SH_LOCK` to a temp file.
- [ ] Write the failing tests first:
  1. A parallel run and `RUN_JOBS=1` print identical output for the existing fixtures plus
     two slow ones (`sleep 1`).
  2. A `# test-serial` fixture runs alone. Each fixture creates `$MARK/<name>.running` at start
     and removes it at the end. The serial fixture fails if it sees another marker during a
     1-second window.
  3. With `RUN_SH_LOCKED` unset and the lock held by `lockf -k "$L" sleep 3 &`:
     - an unfiltered run prints the waiting line and completes after the holder exits;
     - a filtered run does the same.
  4. With the lock held, a runner started with `RUN_SH_LOCKED=1` completes within 10 s. Use a
     background process and a kill timer, because macOS has no `timeout`.
- [ ] Implement. Run `run`, then a full parallel run of the real suites. Report both totals and
      the wall time against Task 1's baseline.
- **Commit:** `Run test suites in parallel under a per-machine lock`

### Task 3: Mark heavy and serial suites

**Depends on:** 1, 2. **Tier:** sp-standard.

- [ ] From the baseline, add `# test-requires: heavy  # <seconds> s on 2026-10-31; run by name when <subject> changes`
      to every suite over 120 s.
- [ ] Run the full suite in parallel three times. Mark `# test-serial` on a suite whose verdict
      differs from the baseline or between runs, or that uses a fixed port, a fixed path outside
      `mktemp`, or a timing assertion. Each marker gets a one-line reason. Add no marker without
      evidence.
- [ ] Two more parallel runs must agree with the baseline verdicts.
- **Commit:** `Mark heavy and serial test suites`

### Task 4: Instruction fragments

**Depends on:** none. **Tier:** sp-standard.

Apply the spec's texts exactly, adjusting only the line wrapping:
- [ ] `global.md`:
  - **§1:** the Fresh sessions bullet in Autonomy.
  - **§3:** the Engineering judgement section after "How to work", replacing the "Suggest
    improvements" bullet.
  - **§4:**
    - remove the Merge requests and Second brain sections;
    - add the two "How to work" bullets: the no-attribution rule in full, and the vault
      boundaries with every never-store category.
  - **§9:** the Sizing bullet in Autonomy, and the new first sentence of Design records.
  - **§10:** the Convergence bullet after "Fix now".
  - **§11:** the testing bullet in "How to work".
- [ ] `claude-code.md`:
  - **§2:** the table rows.
  - **§12:** the "Cleanup never blocks a run" bullet. Keep ``sdd-clean <workspace>`, never `rm -rf`.``
    on one line.
  - Tighten wording elsewhere so the file stays at most 50 lines, without dropping a rule.
- [ ] `tests/agent-instructions.test.sh` pins, per the spec's Testing:
  - the caps;
  - the Engineering judgement heading;
  - the Sizing and Convergence bullets;
  - the no-attribution sentence;
  - "write it only when asked" and each never-store category.

  Update any existing pin whose line moved. Run `agent-instructions`.
- **Commit:** `Size the process to the change and add engineering judgement rules`

### Task 5: Shared skills for merge requests and the vault

**Depends on:** none. **Tier:** sp-mechanical.

- [ ] `dot_agents/skills/merge-request/SKILL.md`:
  - **Frontmatter:** `name: merge-request`, plus a description that triggers before opening any
    MR or PR, with gh, glab or az.
  - **Body:** the Merge requests mechanics, verbatim from
    `git show main:.chezmoitemplates/agents/global.md`, never from the working tree, which Task 4
    is editing: template locations, filling them faithfully, and rendering the body. Also
    restate the no-attribution rule.
- [ ] `dot_agents/skills/second-brain/SKILL.md`:
  - **Frontmatter:** `name: second-brain`, plus a description that triggers when work produces
    durable knowledge or a vault note is asked for.
  - **Body:** the Second brain section verbatim, including the never-store list.
- [ ] `dot_claude/skills/symlink_merge-request` → `../../.agents/skills/merge-request`, and the
      same for `second-brain` (as `symlink_clarity`).
- [ ] Add `.chezmoiignore` re-includes for both symlinks, next to `!.claude/skills/clarity`.
- [ ] `tests/agent-skills.test.sh`: `command chezmoi --source <checkout> managed` lists both
      `.agents/skills/<name>/SKILL.md` files and both `.claude/skills/<name>` symlinks. Run
      `agent-skills`.
- **Commit:** `Move the merge-request and vault procedures into shared skills`

### Task 6: Agent definitions

**Depends on:** none. **Tier:** sp-mechanical.

- [ ] Spec §2:
  - `sp-architect.md` description: "Not for implementation, fix rounds, plan-run controllers or
    merges; those go to sp-standard."
  - `sp-architect.md`, plan-review bullet: "Every planned test must name the regression it
    catches; challenge the ones that don't."
  - `sp-standard.md` description: add fix rounds, plan-run controllers and merge-conflict
    resolution.
- [ ] Spec §3: `sp-reviewer.md` and `sp-architect.md` each gain the Engineering judgement line.
- [ ] Run `live-feedback-skill` (it checks the agent names).
- **Commit:** `Route fix rounds and controllers to sp-standard and sharpen review lenses`

### Task 7: Cross-review skill

**Depends on:** none. **Tier:** sp-mechanical.

- [ ] Spec §10: add the escalation trigger to the exhaustive list. The trigger is a loop that
      stops converging: two rounds in a row that mostly find problems in the last round's fixes,
      or a goal that can never be finished. Keep "no round limit".
- [ ] Spec §11: fix-round rule 3 gains "Run the focused tests before re-dispatching; the full
      suite runs once the review approves, and a red suite starts a new round."
- [ ] Run `xreview-skill`.
- **Commit:** `Escalate non-converging review loops and test focused per round`

### Task 8: Path-resolution guard message

**Depends on:** none. **Tier:** sp-mechanical.

- [ ] Spec §5: replace the second fix in rule 1's denial. The rules themselves do not change.
- [ ] `tests/path-resolution-guard.test.sh`: the "separate-call" expectation becomes one that
      the reason says a subagent's directory does not persist. Run `path-resolution-guard`.
- **Commit:** `Tell subagents that a cd does not persist between their calls`

### Task 9: Context figure in the statusline

**Depends on:** none. **Tier:** sp-standard.

- [ ] Spec §1: the model segment gains ` · <n>k` from `.context_window.total_input_tokens`.
  - **Colour:** muted below 200,000, yellow from 200,000, red from 400,000. Use the
    statusline's Tokyo Night palette, adding red `#f7768e` if it is missing.
  - **Omitted** when the field is absent, null or 0.
  - **Width:** the segment's width math must count the figure.
- [ ] Tests at 199,999, 200,000, 400,000 and null. Run `statusline`.
- **Commit:** `Show the context size in the statusline`

### Task 10: Memory index line check

**Depends on:** none. **Tier:** sp-mechanical.

- [ ] Spec §6: the hook also warns when an index line is longer than 200 characters, counted as
      the hook counts them. The warning names the entry and goes through the existing `add`
      path.
- [ ] Tests: 201 characters warns and 200 does not. Run `memory-health`.
- **Commit:** `Warn when a memory index line grows past 200 characters`

### Task 11: Codex reviewer lens

**Depends on:** none. **Tier:** sp-standard.

- [ ] Spec §7: replace the closing line of `dot_config/xreview/reviewer.md`.
- [ ] Run `tests/fixtures/xreview-packet/regenerate.sh`. It copies `reviewer.md` and rebuilds
      the golden packets with its pinned reference dispatcher. Never point it at a newer one.
      Check that the diff of the fixtures is only the new reviewer text.
- [ ] Run `xreview-packet`, `xreview-replay` and `xreview`.
- **Commit:** `Let Codex report quality problems with a concrete cost`

### Task 12: Codex config seeds

**Depends on:** none. **Tier:** sp-mechanical.

- [ ] Spec §8: the four seeds.
- [ ] Update the seeded-when-absent cases in `tests/codex-config.test.sh`. Run `codex-config`.
      It exits 2 (INCONCLUSIVE) on a cold external cache; then warm the cache as `AGENTS.md`
      says and rerun.
- **Commit:** `Seed Codex with the model, effort and tier in use`

### Task 13: AGENTS.md testing section

**Depends on:** 2, 3. **Tier:** sp-mechanical.

- [ ] Describe:
  - the parallel runner, `RUN_JOBS` and `# test-serial`;
  - the lock: the runner locks itself, so never wrap it in `lockf`;
  - the `heavy` row in the needs table, naming the suites Task 3 marked: run by name when its
    subject changes, and before pre-merge.
- [ ] Keep it concise; `AGENTS.md` has no cap, but every line costs context.
- **Commit:** `Document the parallel runner, its lock and heavy suites`

### Task 14: Memory index consolidation

**Depends on:** 10. **Tier:** controller, in the main session (the memory directory is not in
the repo).

- [ ] Re-read `MEMORY.md` right before editing; other sessions write to it.
- [ ] Rewrite each index line as `- [Title](file.md) — hook` in at most 200 characters.
- [ ] Move status history out of each index line into its topic file, unless the topic file
      already holds it. Delete nothing.

---

## Finish

1. Full suite in parallel, on the final commit. Report passed/total and the wall time against
   the baseline.
2. sp-architect final whole-branch review against the spec, then fix rounds.
3. Codex pre-merge review on `main...improvements`, iterated until it approves; the Convergence
   rule applies.
4. Set the spec and plan to `**Status:** Implemented`, and add a completion banner to the plan.
5. Push `improvements` to origin. For the dotfiles, the pushed branch is the end.
6. Once Michael merges `fix/push-guard-escaped-spellings`, rebase onto main. A clean rebase over
   other files keeps the approval. Then report.
