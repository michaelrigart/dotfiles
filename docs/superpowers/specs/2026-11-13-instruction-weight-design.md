# Instruction weight: move workflow detail out of the always-loaded text

**Status:** Approved
**Date:** 2026-11-13. Signed off by Michael on 2026-11-13 ("I follow your recommendations", relayed
by the driver session). Codex approved round 2 (xr-1794595820-5f42cbbc).
**Branch:** `chore/instruction-weight`, in the `wt` checkout
`~/.local/share/chezmoi-chore-instruction-weight`
**Source:** item 41 of the 2026-11-11 setup review; Michael approved it on 2026-11-12 to run
after `feat/review-loop` (on main since 21a2116).
**Depends on:** `fix/xreview-trust` merging before part C starts (see Order).

## Problem

Every dotfiles session, every `sp-*` dispatch and every Codex review loads text that binds
only in one workflow. Measured on main at 21a2116 (tokens are an estimate, bytes ÷ 4):

| Text | Loads | Lines | Bytes | Tokens (est.) |
|---|---|---|---|---|
| `~/.claude/CLAUDE.md` (`global.md` + `claude-code.md`) | every Claude session and `sp-*` dispatch, any repository | 201 | 14,888 | 3,700 |
| `~/.codex/AGENTS.md` (`global.md` + `codex.md`) | every Codex thread | 165 | 11,546 | 2,900 |
| dotfiles `AGENTS.md` | every dotfiles session, `sp-*` dispatch and Codex review | 248 | 18,676 | 4,700 |
| of which its Testing section | | 130 | 10,191 | 2,500 |
| `cross-review` skill | each load: three checkpoints per line, again after a compaction | 370 | 22,299 | 5,600 |
| of which Dispatching | | 157 | 10,301 | 2,600 |
| `sp-*` bodies | one per dispatch | 17–30 | 1,068–2,089 | 270–520 |
| skill and agent descriptions (12) | every session | | 2,855 | 700 |

The fragments were trimmed on 2026-11-02 (instruction-layer spec: `global.md` 180 to 150
lines). What is left there is small. The weight is in the dotfiles `AGENTS.md` and in the
`cross-review` skill, which is what item 41 names.

## Goals, non-goals, anti-goals

- **Goals:**
  - dotfiles `AGENTS.md` at most 150 lines (amended while planning, 2026-11-13: at most 190.
    The move test tightened at spec review keeps the runner lock, the gate rule, the map-row
    rule and the herdr rule in the root, and the plan's sentence table then measures about
    186 once the plan review also kept what reads a run's result. Raised rather than cut a rule to reach a number; decided by the driver session on
    Michael's delegation, 2026-11-13);
  - `cross-review` skill at most 150 lines;
  - `claude-code.md` below its 50-line cap, so the next rule has room;
  - no rule lost: every sentence that leaves a file is kept elsewhere, or is named as dropped
    with its reason.
- **Non-goals:**
  - changing what any rule means, the review loop, effort levels, any guard's behaviour, or
    Superpowers (Michael's rulings stand);
  - memories (item 41: delete 15, shrink 41). They are unversioned and outside the repository,
    so no diff or review covers them, and deleting one needs Michael's word. A separate pass
    can bring him a list;
  - curato's `AGENTS.md`, and new ones for tagteam and home-assistant: each is a line in its own
    repository.
- **Anti-goals:**
  - a rule that silently stops applying because the file that holds it never loads;
  - a safety pin in `tests/fixtures/agent-instructions/rules.tsv` dropped instead of replaced;
  - compressed wording that loses a clause.

## Approaches

1. **Move each detail to where it is used** (chosen). A sentence that binds only while writing a
   suite goes to `tests/AGENTS.md`; a refusal's next step goes into the refusal; a procedure for
   one file goes into that file. The always-loaded text keeps the rule and a one-line trigger.
   This is the instruction-layer spec's method, applied to the two files it left alone.
2. **Compress in place.** Rejected: it shortens every sentence a little, breaks the exact-term
   pins and loses clauses, which is how a rule changes meaning unnoticed.
3. **Path-scoped `.claude/rules/`.** Rejected: Codex does not read them, the checkout's `.claude/`
   is write-denied to agents, and the documentation does not state that they load in `sp-*`
   subagents.

## Design

### Rule for every move

The plan carries a table that maps every sentence leaving a file to one of: kept (where),
moved (where), dropped (why). Michael reviews it with the diff. A sentence stays in the
always-loaded file when it binds at a moment its new home would not be loaded.

### A. Dotfiles `AGENTS.md` (248 to at most 150 lines)

**New file `tests/AGENTS.md`.** Claude Code loads a nested `AGENTS.md` when it reads a file in
that directory (documented for the Read tool, version 2.1.277 and later). Running a suite
through Bash does not load it, and Codex does not load it, so the root file keeps a pointer:
"before adding or changing a suite or the runner, read `tests/AGENTS.md`". `tests/` is already
ignored by chezmoi.

The test for each Testing sentence: does it bind only while a file under `tests/` is being
written or changed? Only then does it move. A sentence that binds while running suites,
reading a run's result, or changing a file outside `tests/` stays in the root.

- **Stays in the root:** the command block; execute suites, never prefix an interpreter; never
  brace expansion; the gated-suite table and that only an exact suite name lifts a gate; never
  run the four `live-*` sandbox suites unsandboxed; control for sandbox mode before calling a
  regression; the pre-merge `--changed` run and the lines to quote; report passed/total; one
  runner per machine, which waits and says who holds the lock, and is never wrapped in `lockf`;
  that a load-sensitive suite's assertion count can differ between runs; a new or moved file a
  suite loads gets its subject-map row in the same commit; and the `HERDR_SESSION` rule (no
  bare `command herdr` in `layout.sh`, `tab-goto.sh` or `phase.sh`), which binds when those
  scripts change and moves from Testing to Rules, shortened to the rule and its one-line reason.
- **Moves to `tests/AGENTS.md`:** the lock's environment variables and exit codes; how suites
  are scheduled (`RUN_JOBS`, `# test-serial`); how to write a `# test-requires:` line; the
  missing-subject guard a new suite must carry and its `missing-subject` row; the two output
  idioms and `failed_keys`; `write-boundary-probe`'s seams; the `codex-config` and
  `herdr-phase` suite gotchas; the history behind the `HERDR_SESSION` rule.
- **Nothing in Testing is dropped** (amended at plan review): what a `????` row, an
  `INCONCLUSIVE:` line, a cold external cache and a `KEY=VALUE` suite's result mean is read
  from a run, so it stays in the root, as do the prerequisites for running a gated suite.

The same test applies to Rules:

- The skill-bump procedure (about 14 lines) moves into a comment block at the top of
  `.chezmoiexternal.toml`, the file a bump edits. The root keeps what binds before that file
  is open: externals are pinned, each with its `symlink_` and `.chezmoiignore` re-include;
  closing a `skill-update` issue without a bump declines that release; and "to bump one, follow
  the procedure at the top of that file".
- The `.scripts/` bullet keeps the rules (not `run_once_`; the managed-settings installer is
  Michael's and agents run it in test mode only; mode 755) and loses the inventory of replay
  harnesses, which Layout and the files state.
- Every other Rules bullet stays as it is.

`fix/xreview-trust` adds six lines to Testing (`xreview-guard-cli`). Whichever branch rebases
second places them by the same test (they describe one suite's exit 2: `tests/AGENTS.md`).

### B. Fragments, agents and descriptions

- **`claude-code.md`, Subagents table (decision 3).** Its five rows restate the agents'
  `description` fields, which every session already loads in the Agent tool's list. Remove the
  table; keep "Use the named types…", "Go up a tier…" and "Reviews never run as forks". The
  plan compares each row with its description clause by clause, and a clause the description
  lacks is added to it. Two are known: `web-researcher` takes "all web research, a skill's
  researchers included", and `sp-architect`'s "after a lower tier failed" becomes "a fix only
  after an `sp-standard` attempt at it failed". Saves 8 lines in every session and every
  dispatch. Pins `cc-table-standard` and `cc-table-web` move to the agent files, and a new row
  pins the `sp-architect` clause.
- **`claude-code.md`, Cleanup.** The `sdd-clean` sentence binds only in a plan run and moves to
  the `plan-run` skill. "Other deletions … wait until the run's work is done" stays. The safety
  pin `cc-cleanup` becomes two rows, one per file, each with its full sentence.
- **`plan-run` description** shrinks from 320 to about 150 characters, keeping the trigger
  ("running an implementation plan as its controller") and that it overrides superpowers.
- **`global.md` and `codex.md`: no change.** Every remaining block is pinned, binds outside a
  single workflow, or was placed there on purpose by the instruction-layer spec (the three
  design-record rules Codex must read).
- **`sp-*` bodies: no change.** The path-guard paragraph repeats `claude-code.md`, but it is
  measured: 0.03 denials per dispatch with it, 0.67–0.84 without. The Engineering judgement
  bullets came with the review-loop line.

Result: `claude-code.md` at about 41 lines. The caps in `agent-instructions` stay as they are.

### C. `cross-review` skill (370 to at most 150 lines)

1. **Refusals carry their own next step.** Today the skill lists every `xreview` refusal twice:
   once under Dispatching (what it means) and once under Iterating (escalate or not). Each
   refusal in `xreview` gets a closing clause from a fixed set: the action the agent takes
   (`wait for it, then dispatch again`, `run codex-daemon ensure, then collect again`), or
   `Michael's call: report this and stop.` Many already carry the first kind. The skill keeps
   three rules: follow what the refusal says; one marked as Michael's call is an escalation;
   never work around a refusal (no environment prefix, no re-dispatch of an ambiguous turn).
   The skill's "exhaustive" escalation list becomes: the four judgement triggers (a re-raised
   finding, a spec change, an unverifiable claim, a loop that stops converging) plus "any
   refusal marked Michael's call". Which refusals are marked is exactly today's list; the plan
   maps each one.
2. **The guard describes itself.** "What is enforced rather than trusted" keeps: the gate
   opens only for the latest full-range `pre-merge` approval of exactly that change; spec, plan
   and partial reviews never open it; the apply window commands; the bypass is Michael's and
   goes in the command and the MR. The list of gated verbs and the quoting advice move to the
   guard's deny message where it does not already say them.
3. **Rationale goes.** How the pane is quit and resumed, why `--expect` was removed, the
   measurements behind inline artifacts, the repeated statements of the thread-rotation rule
   (three places, kept once), and the Herdr notification prose are explanation, not rules.
   Each is listed as dropped in the plan's table. The rules they justify stay.
4. **Unchanged in meaning:** the cold-ask rule, the dispatch and collect commands and exit
   codes, `-C` for a `wt` line, the 300000 ms timeout, full-range pre-merge, landing through
   the gate, acting on findings, the five fix-round rules, no round limit, consultation, and
   the pinned sentences `cr-plan-review`, `cr-show-plan`, `cr-plan-path`, `cr-no-consensus`
   and `cr-fix-rule`.

This is not a change to the review loop: no trigger, round rule or verdict rule changes.

### Order

A and B do not touch what `fix/xreview-trust` changes, apart from the six lines above. C edits
`dot_local/bin/executable_xreview`, the skill and `tests/xreview-skill.test.sh`, all of which
that branch rewrites (147, 33 and 26 lines). So the plan runs A and B first, and C starts only
once `fix/xreview-trust` is on main and this branch is rebased on it (decision 2).

## Testing

- **`rules.tsv`:** a moved rule's row follows it to its new file with the same terms; a split
  rule gets one row per part. No safety row is removed.
- **Caps** in `agent-instructions`: dotfiles `AGENTS.md` at most 150 lines, `cross-review`
  skill at most 150. They stop the regrowth this spec removes.
- **Pointers:** rows pin the root's pointer to `tests/AGENTS.md` and to the bump procedure,
  and that the procedure's steps (`agent-text-scan --diff`, the warm-up, `Closes #`) are in
  `.chezmoiexternal.toml`.
- **Refusals** (`xreview` suite): each refusal on today's escalation list ends with the
  Michael's-call clause, and none of the wait-and-retry ones does. This tests the tool's
  output, which is now the only place the rule lives.
- **`xreview-skill`:** its checks tie skill sentences to the implementation. A check whose
  sentence moved to a tool message is replaced by a check on that message; one whose sentence
  was rationale goes with it, listed in the plan's table.
- **Pre-merge:** `./tests/run.sh --changed`; C changes `xreview`'s subject, so the heavy
  `xreview` suite runs. Renders previewed with
  `command chezmoi --source <checkout> cat ~/.claude/CLAUDE.md`.
- **Report:** the table above, measured again on the final commit.

## Decisions (Michael, 2026-11-13)

1. **Scope:** as written. Item 41 for the dotfiles: `AGENTS.md` and the `cross-review` skill;
   `global.md`, `codex.md` and the `sp-*` bodies unchanged.
2. **C stays in this line** as its last tasks. It starts only once `fix/xreview-trust` is on
   main, on the driver's word, after a rebase onto main.
3. **The Subagents table is removed.** Routing is stated in the agent descriptions and pinned
   there.
4. **No memory pass:** the memory cleanup approved on 2026-11-12 covered it.

## Out of scope

- The superpowers SessionStart injection (no supported switch).
- `live-feedback` (266 lines) and `api-review`: they load only when used and are not repeated
  elsewhere.
- The Pushing bullet in `claude-code.md`: `feat/forge-push-protection` rewrites it.
