# Shrink wt's mise-trust carry Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Cut the `_wt_mise_*` code in `dot_config/zsh/functions` from 333 to about 245 lines
without changing any trust check.

**Architecture:** Two passes over the same functions: first remove the base branch (the only
behaviour change, with its tests), then fold `_wt_mise_withdraw` into `_wt_mise_trust` and trim
comments with every test unchanged.

**Tech Stack:** zsh functions, `tests/wt-functions.test.sh` (zsh, heavy, ~2–3 min).

**Spec:** `docs/superpowers/specs/2026-11-14-wt-mise-trust-shrink-design.md`

## Global Constraints

- No trust check is removed or loosened: plainness on both sides, the candidate listed
  `trusted`, `cmp`, the identity pins, the post-trust re-check bound to the voucher, every
  fail-closed read, the common-dir check, the `<dest>`-is-a-symlink refusal.
- Every message line keeps its exact text, except the two the spec changes (the voucher named,
  the `review` baseline).
- Comments keep the non-obvious why; no comment cites a review round, a task or a case ID.
- Run the suite only as `./tests/run.sh wt-functions` (the exact name lifts the heavy gate).
  The test lock is shared: never wrap `run.sh` in `lockf`, never run it twice at once, and do
  not loop on it. The suite runs twice in Task 1 (red, then green) and once in Task 2.
- Line count, the spec's way (prints each function and the total):

  ```
  awk '/^# _wt_mise_[a-z_]+ /{ if(!n){ n=1; s=NR } } /^_wt_mise_[a-z_]+\(\) \{/{ f=$1 } /^\}/{ if(f){ printf "%-24s %4d\n", f, NR-s+1; t+=NR-s+1; f=""; n=0 } } END{ print "total", t }' dot_config/zsh/functions
  ```

## Review Focus

- `wt` run from inside a sibling checkout with no start point: the candidates are still `<main>`
  then Git's order (X36 pins it after Task 1).
- `wt-prepare` and `wt-rm` call `_wt_mise_trust` with two arguments; a leftover third one must
  not shift anything (X30's `wt-prepare` half and the X/Y `wt-rm` cases cover it).
- Every withdraw outcome keeps its lines and their order after the fold: X11b, X11c, X11d,
  X11e, X14d, X19 and Y15 pin them, unchanged.
- A refusal whose main copy is untrusted or a symlink still gets `cat` (X25c, X25d, unchanged).
- The reopen carry still prints the opening-anyway and never-prepared lines (Y cases,
  unchanged).

---

### Task 1: Drop the base branch

**Depends on:** none

**Files:**
- Modify: `dot_config/zsh/functions` — `_wt_mise_candidates` (577–635), `_wt_mise_trust_report`
  (677–714), `_wt_mise_withdraw` (716–733), `_wt_mise_trust` (747–884), `_wt_do_prepare`
  (886–932), `_wt_mise_reopen_carry`'s comment (934–940), `_wt_create_or_prepare` (1001–1049)
- Modify: `tests/wt-functions.test.sh` — XC block (3555–3622), X29 (~4078), X30 (~4092),
  X35 (~4190), X36 (~4195)
- Modify: `docs/superpowers/specs/2026-10-27-mise-trust-worktrees-design.md` — one line under
  its intro: `Changed on 2026-11-14 by [Shrink wt's mise-trust carry](2026-11-14-wt-mise-trust-shrink-design.md), which drops the base branch (§2, §4).`

**Interfaces:**
- Produces: `_wt_mise_candidates <main> <dest>` (sets `_WT_MISE_CANDS`: `<main>`, then the
  others in Git's order; `_WT_MISE_BASEDIR` no longer exists); `_wt_mise_trust <main> <dest>`;
  `_wt_mise_trust_report <main> <dest> <reason<TAB>rel>...`;
  `_wt_mise_withdraw <main> <dest> <rel> <stop-message> <reason<TAB>rel>...`;
  `_wt_do_prepare <main> <dest> <branch> <slug>`.

- [ ] **Step 1: Change the tests to the no-base behaviour**

  - `xc_list` prints only `$_WT_MISE_CANDS` (no `base=` line); every `xc_list` call drops its
    third argument.
  - XC1: `xc_list "$REPO" "$HOME/Code/Org/repo-d"` equals
    `$REPO`, `$HOME/Code/Org/sib-a`, `$HOME/Code/Org/sib-b` —
    "XC1 main, then Git's order; the destination is absent".
  - XC5: keep only the first run, expecting `$REPO`, `sib-a`, `sib-det`; delete the
    `origin/main` and `main` runs.
  - XC6: delete (XC2 pins a gone checkout).
  - X29: expects `(trusted in ~/Code/Org/sib-a)` and
    `mlog_no_line "-C $HOME/Code/Org/sib-z trust --show"`; descriptions say "the first
    sibling in Git's order vouches".
  - X30: the first run expects
    `review: diff ~/Code/Org/repo/mise.toml ~/Code/Org/repo-x30/mise.toml`; the `wt-prepare`
    half is unchanged.
  - X35 second half: expects
    `review: diff ~/Code/Org/repo/mise.toml ~/Code/Org/repo-x35/mise.toml` and
    `hasnt "sib: x35/mise.toml ~"`.
  - X36: expects `(trusted in ~/Code/Org/sib-a)` and
    `mlog_no_line "-C $HOME/Code/Org/sib-c trust --show"`; its comment says the caller's
    checkout gets no preference.
  - Comments in the XC block and above X29/X30/X36 stop describing a base checkout.

- [ ] **Step 2: Run the suite and see exactly those cases fail**

  Run: `./tests/run.sh wt-functions`
  Expected: FAIL; the failures are X29, X30, X35 and X36 assertions only (with no base
  argument the old code already lists `<main>` then Git's order, so XC1 and XC5 pass). This is
  the revert check for the changed expectations.

- [ ] **Step 3: Remove the base from the code**

  `_wt_create_or_prepare` keeps its `wt: branching <branch> from <from>` line (`from` is the
  start point, else the current branch, else `detached@<short sha>`) but computes no `base` and
  calls `_wt_do_prepare` with four arguments. Every function in the Interfaces block loses its
  base or basedir parameter; the report's baseline loop tries `<main>` only. Comments that
  describe the base go.

- [ ] **Step 4: Run the suite**

  Run: `./tests/run.sh wt-functions`
  Expected: PASS, `passed/total` equal; note the total.

- [ ] **Step 5: Commit**

  ```bash
  git add dot_config/zsh/functions tests/wt-functions.test.sh docs/superpowers/specs/2026-10-27-mise-trust-worktrees-design.md
  git commit -m "Drop the base branch from wt's mise-trust carry"
  ```

### Task 2: Fold the withdraw helper and trim comments

**Depends on:** Task 1

**Files:**
- Modify: `dot_config/zsh/functions` — the seven remaining `_wt_mise_*` functions
- Test: `tests/wt-functions.test.sh` — unchanged

**Interfaces:**
- Consumes: Task 1's signatures.
- Produces: `_wt_mise_withdraw` no longer exists; all other signatures as Task 1.

- [ ] **Step 1: Fold `_wt_mise_withdraw` into `_wt_mise_trust`**

  Its three call sites (a failed post-trust read of `<dest>`, of the voucher, and a failed
  re-check) become one path in `_wt_mise_trust` after the re-check: untrust `<dest>/<rel>`
  (`command mise trust --untrust … >/dev/null 2>&1 </dev/null`); if that fails, print the
  collected refusals, the `could not withdraw … may still be trusted; check with: …` line, then
  the stop line (the read's `cannot read … — trusting nothing.` or
  `… changed while wt was trusting it — trusting nothing more.`) and return 1; if it worked
  and a read failed, print the refusals and the read's stop line and return 1; otherwise add
  the changed reason to the refusals and go on. Same lines, same order, same return values as
  today.

- [ ] **Step 2: Trim the comments**

  Each function's leading comment: what it returns or sets, and the non-obvious why of each
  rule (why mise's output is parsed as it is, why the pins exist and what they cannot see,
  why a failed candidate read skips while a failed `<dest>` read stops), pointing at the
  10-19, 10-27 and 2026-11-14 specs instead of retelling them. Inline comments only where the
  code alone would mislead.

- [ ] **Step 3: Run the suite unchanged**

  Run: `./tests/run.sh wt-functions`
  Expected: PASS with Task 1's total.

- [ ] **Step 4: Measure**

  Run the Global Constraints line count. Expected: total about 245 or fewer; report the
  per-function numbers.

- [ ] **Step 5: Commit**

  ```bash
  git add dot_config/zsh/functions
  git commit -m "Fold the withdraw helper into the carry and trim its comments"
  ```
