# Workflow v2, increment 1: Measure — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking. In this repository the `plan-run` skill overrides it.

**Status:** In progress

**Goal:** Claude Code keeps transcripts for 90 days, and every v2 `xreview` receipt records when
its verdict was collected.

**Architecture:** Two independent, additive changes. The retention value is one owned key in the
settings modifier. The receipt gains one field, written by `record_receipts` in `xreview`; the
ledger module and the merge gate read nothing new and do not change.

**Tech Stack:** bash (`xreview`, the suites), jq, `/usr/bin/python3` (the ledger module, read
only here).

**Spec:** `docs/superpowers/specs/2026-11-20-workflow-v2-design.md` (Measurement and the verdict;
Where each change lands, increment 1; Safety, "The ledger change is in merge tooling"; Testing).

## Global Constraints

- `cleanupPeriodDays` is exactly `90`.
- The new receipt field is named `collected_at`, in UTC, in the format of `dispatched_at`
  (`YYYY-MM-DDTHH:MM:SS.ffffffZ`), taken when `record_receipts` builds the entry.
- Only v2 receipts get it. The v1 receipt (`record_receipt`) and pending entries do not change.
- `dot_claude/xreview-ledger.py` and `dot_claude/xreview-guard.py` do not change. The gate's
  decision reads no new field.
- A second `collect` of the same nonce stays idempotent: the ledger answers `present` and the
  first `collected_at` stands.
- `~/.claude/settings.json` holds the forge tokens. Never print that target whole: preview it
  through `jq 'del(.env.GH_TOKEN, .env.GITLAB_TOKEN)'`, and filter a dry-run diff that includes
  it the same way.
- The repository is public: no private hostnames, client or repository names.
- No change to any refusal text, guard, prompt or skill.

## Review Focus

- A receipt written before this change (no `collected_at`) still opens the gate (Task 2, ledger
  suite).
- A receipt with `collected_at` opens the gate exactly as one without it (Task 2, ledger suite).
- A re-collect of an already recorded nonce does not move `collected_at` (Task 2, `xreview`
  suite).
- A sliced review's receipt carries one `collected_at`, the time the receipt was built, not one
  per slice (Task 2, `xreview` suite, the existing sliced-collect case).
- A live `settings.json` that already holds another `cleanupPeriodDays` is overwritten with 90:
  the key is owned (Task 1; the existing case pins ownership, only its value changes).

---

### Task 1: Transcript retention is 90 days

**Depends on:** none

**Files:**
- Modify: `dot_claude/modify_private_settings.json:136` (`"cleanupPeriodDays": 30`)
- Test: `tests/claude-settings.test.sh:404`

- [ ] **Step 1: Change the test first.** Line 404 becomes
  `jq_is '.cleanupPeriodDays' 90 "cleanupPeriodDays is owned, and is 90"`.
- [ ] **Step 2: Run it and see it fail.** `./tests/claude-settings.test.sh`; expected: that one
  case fails with 30.
- [ ] **Step 3: Set the value to 90** in the modifier.
- [ ] **Step 4: Run the suite.** Expected: every case passes; report passed/total.
- [ ] **Step 5: Preview the target, filtered.**
  `command chezmoi --source ~/.local/share/chezmoi-feat-workflow-v2 cat ~/.claude/settings.json | jq 'del(.env.GH_TOKEN, .env.GITLAB_TOKEN) | .cleanupPeriodDays'`;
  expected: `90`.
- [ ] **Step 6: Revert check.** Set the value back to 30, see the Step 1 case fail, restore 90,
  see it pass.
- [ ] **Step 7: Commit.** `Keep Claude Code transcripts for 90 days`

### Task 2: A v2 receipt records when it was collected

**Depends on:** none

**Files:**
- Modify: `dot_local/bin/executable_xreview:825-860` (`record_receipts`)
- Test: `tests/xreview.test.sh` (case F1 near line 1254, the re-collect that follows it, and the
  sliced-collect case), `tests/xreview-ledger.test.sh` (after case F4, near line 514)

**Interfaces:**
- Produces: a v2 receipt entry with `collected_at: "<YYYY-MM-DDTHH:MM:SS.ffffffZ>"` beside
  `dispatched_at`. Nothing in this repository consumes it; the baseline scripts outside it will.

- [ ] **Step 1: Write the failing `xreview` cases.** After "F1 the receipt records the
  checkpoint named at dispatch": the receipt's `collected_at` matches
  `^[0-9-]+T[0-9:]+\.[0-9]{6}Z$`, and it is the time of collection, not of dispatch. Pin that
  with two clock readings in the ledger's format, one taken after the dispatch and just before
  the `collect` call (after a `sleep 1`, so it is later than `dispatched_at`) and one just after
  it: `before <= collected_at <= after` by string comparison, and `collected_at > dispatched_at`.
  A receipt that copies `dispatched_at` fails both. After the re-collect of the same nonce: the ledger still holds one receipt for
  the nonce, with the same `collected_at`. In the sliced-collect case: the receipt has exactly
  one `collected_at`.
- [ ] **Step 2: Write the ledger cases.** With `put`'s receipt shape plus
  `collected_at:"2026-11-20T10:00:00.000000Z"`, approved, full range: `gate` answers `allow`. The
  existing F4 already pins a receipt without the field; add a comment there naming it as the
  pre-change shape so it is not removed.
- [ ] **Step 3: Run both and see the new `xreview` cases fail.** `./tests/run.sh xreview-ledger`
  and `./tests/run.sh xreview` (the exact name lifts the heavy gate; about nine minutes).
  Expected: the ledger cases pass already (the module accepts unknown fields), the `xreview`
  cases fail on a missing field. If a ledger case fails, stop: the spec's claim that the module
  needs no change is wrong, and that goes back as a spec change.
- [ ] **Step 4: Add the field in `record_receipts`.** Take the time once, before the loop over
  repositories, from the ledger module's own clock (`ledger now`, the format `append`
  validates for `dispatched_at`), pass it to jq as `--arg at`, and add `collected_at:$at` to the
  object beside `dispatched_at`. One time for all of a review's repositories.
- [ ] **Step 5: Run the focused suites.** `./tests/run.sh xreview-ledger xreview-guard xreview-skill`
  then `./tests/run.sh xreview`. Expected: all pass; report passed/total per suite.
- [ ] **Step 6: Revert check.** Remove the field, see the Step 1 cases fail, restore it.
- [ ] **Step 7: Commit.** `Record when a review receipt was collected`

### After the last task

- [ ] `./tests/run.sh --changed` on the final commit; quote each `needs: heavy` line.
- [ ] `command chezmoi --source ~/.local/share/chezmoi-feat-workflow-v2 apply --dry-run --verbose`,
  with any diff of `~/.claude/settings.json` filtered for the two token lines before it is shown.
- [ ] Final whole-branch review, then Codex's pre-merge review, then the pull request, per the
  spec's finish. Michael's step after merge: `chezmoi apply`.
