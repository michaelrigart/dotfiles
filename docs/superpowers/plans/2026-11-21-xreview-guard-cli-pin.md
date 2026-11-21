# xreview-guard CLI pin Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: the `plan-run` skill (it overrides
> superpowers:subagent-driven-development). Steps use checkbox (`- [ ]`) syntax for tracking.

**Status:** Implemented (the pull request of branch `fix/xreview-guard-cli-pin`). Completed 2026-11-21: do not run this plan again.

**Goal:** Move the pre-merge gate's CLI pin to the installed CLIs, with `gh event` weighed and left
ungated, so `xreview-guard-cli` gives a verdict again.

**Architecture:** The pin is two shell variables in one suite. The gate and the settings do not
change: the spec's decision for `gh event` is "leave it".

**Tech Stack:** bash (the suite), `./tests/run.sh`.

**Spec:** `docs/superpowers/specs/2026-11-21-xreview-guard-cli-pin-design.md`

## Global Constraints

- Touch `tests/xreview-guard-cli.test.sh` only. Not `dot_claude/xreview-guard.py`,
  `dot_claude/executable_xreview-guard.sh`, the settings, `subjects.tsv`, `AGENTS.md` or any other
  suite.
- Read `tests/AGENTS.md` before editing the suite.
- Execute suites (`./tests/x.test.sh`), never `bash tests/x.test.sh`.
- Public repository: nothing private. No agent attribution in the commit.
- Never run a gated verb, with or without `--help`.

## Review Focus

- The pin must equal what the installed CLIs list, not what the spec says they list: if the suite
  still reports a difference after the edit (a CLI upgraded since 2026-11-21), stop and report the
  line; do not add the name.
- `event` goes in `PIN_GH_TOP` only; no other pin variable changes.
- `PIN_VERSIONS` keeps its three-line shape (`glab …`, `gh …`, `az …, azure-devops …`): the
  INCONCLUSIVE report prints it joined with `; `.

No further input class applies: the change adds no code path.

---

### Task 1: Move the pin

**Depends on:** nothing

**Files:**
- Modify: `tests/xreview-guard-cli.test.sh` (`PIN_VERSIONS`, lines 28-30; `PIN_GH_TOP`, lines 120-153)

- [x] **Step 1: See the suite inconclusive**

Run: `./tests/xreview-guard-cli.test.sh; echo "exit=$?"`
Expected: `INCONCLUSIVE: gh top level: added event; removed none`, no other `INCONCLUSIVE:` line,
`exit=2`. Anything else: stop and report it.

- [x] **Step 2: Edit the pin**

`PIN_VERSIONS` becomes:

```
PIN_VERSIONS='glab 1.131.0
gh 2.105.0
az 2.93.0, azure-devops 1.0.8'
```

In `PIN_GH_TOP`, add the line `event` between `discussion` and `extension`.

- [x] **Step 3: See it pass**

Run: `./tests/xreview-guard-cli.test.sh; echo "exit=$?"`
Expected: seven `  PASS: … matches the pin (N names)` lines (`gh top level` with 35 names),
`exit=0`.

- [x] **Step 4: Revert check**

Remove the `event` line, run the suite, see exit 2 with the Step 1 line; restore it, see exit 0.

- [x] **Step 5: Commit**

Check `git branch --show-current` prints `fix/xreview-guard-cli-pin`, then:

```bash
git add tests/xreview-guard-cli.test.sh
git commit -m "Move the pre-merge gate's CLI pin to gh 2.105.0, with gh event left ungated"
```

### Task 2: Full run

**Depends on:** Task 1

- [x] **Step 1:** Run `./tests/run.sh --changed`. Expected: no `FAIL`, no `INCONSISTENT`; the
  `xreview-guard-cli` row passes 7/7. Record the totals as passed/total, each `needs: heavy (…)`
  line verbatim, and every `????` row with the line under it.
- [x] **Step 2:** Report; no commit.
