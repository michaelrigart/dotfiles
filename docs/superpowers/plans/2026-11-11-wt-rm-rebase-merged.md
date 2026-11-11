# wt-rm: Delete Rebase-Merged Branches Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Status:** Implemented (branch `fix/wt-rm-rebase-merged`; no MR, a dotfiles line)

> **Completed 2026-11-11.** Executed on `fix/wt-rm-rebase-merged`; do not run it again. Its execution notes bind that run only.

**Goal:** `wt-rm` deletes a branch whose work reached the base by a rebase-merge or a squash-merge, however the base has moved since, and keeps every branch it cannot prove merged.

**Architecture:** Everything lives in `dot_config/zsh/functions`. `_wt_branch_content_merged` keeps its per-base loop and its no-net-change guard, and then asks three tests in order: a new rebase test, a new squash test, and today's merge-tree test. The two new tests nominate pairs by verbatim plumbing patch id, and accept a pair only when a `merge-tree --merge-base` replay reproduces the base commit's tree. `_wt_rm_branch` keeps `git branch -d` first and names the matching test and base in its deletion line.

**Tech Stack:** zsh, git 2.56 plumbing (`rev-list`, `diff-tree`, `patch-id`, `merge-tree`), the existing zsh suite `tests/wt-functions.test.sh`.

**Spec:** `docs/superpowers/specs/2026-11-11-wt-rm-rebase-merged-design.md`

## Global Constraints

- `git branch -d` stays first; the merge-tree test stays last and unchanged; the no-net-change guard stays before all three tests, unchanged.
- Every failure keeps the branch, for that test and that base: a failed command, an empty id list, output that is not lines of two hex object ids, a conflict, a git without `--merge-base` (before 2.40), any other tree.
- Patch ids come from plumbing only, exactly: `git rev-list --no-merges <range> | git diff-tree --stdin -p --full-index --no-renames | git patch-id --verbatim`, and for a whole change `git diff-tree -p --full-index --no-renames <from> <to> | git patch-id --verbatim`. Never `git cherry`, `git diff` or `git log -p`.
- A patch-id match only nominates. It counts once `git merge-tree --write-tree --merge-base=<F> <X^> <T>` prints `X^{tree}`.
- No decision uses commit metadata (author, date, message, PR number). The test is all or nothing.
- No fetching. Bases are today's, in today's order: the main checkout's `symbolic-ref HEAD`, then `refs/remotes/origin/HEAD`; a base equal to the branch is skipped.
- The "kept" message keeps every word: `wt-rm: branch <b> kept (not fully merged) — inspect or merge it before deleting it explicitly.` No message offers a copy-pasteable `-D`.
- `_wt_rm_branch` never fails the removal (always returns 0). The partial-removal advice lines (around line 1755) are not touched.
- Every git call goes through `_wt_git -C "$main"`.
- The existing cases (`h`, `i`, `sq1`–`sq4`, `q11`, `q12`, `q24`–`q26`) keep passing, with their assertions unchanged.
- Execute the suite, never prefix an interpreter: `./tests/wt-functions.test.sh` (zsh shebang, about 2 min). A direct execution takes no runner lock. `./tests/run.sh` does; never wrap it in `lockf`.

## Review Focus

Conditions the spec implies but its cases 1–8 do not exercise:

1. **The merge is visible only on `origin/HEAD`** (local `main` is stale). The second base must get the new tests too, and the message must name it. Test `rb9`.
2. **An empty commit among copied ones.** It has no patch id, so it neither blocks nor matches; the branch is still deleted. Test `rb10`.
3. **The replay command fails after printing a tree** (a git that exits non-zero). The exit status decides, not the output; the branch is kept. Test `rb11`.
4. **Repository configuration that changes porcelain diffs** (`diff.noprefix`, `color.diff=always`). The ids must not change. Case `rb1` sets both in its fixture.

No fifth one found: several merge-bases, a root commit on the base side and a pre-2.40 git all end in a failed command or an unmatched id, which Global Constraints already require to keep the branch.

---

### Task 1: the rebase and squash tests, with their cases

**Depends on:** none.

**Files:**
- Modify: `dot_config/zsh/functions`: `_wt_branch_content_merged` and its comment (lines 1320–1354), new helpers directly above it, `_wt_rm_branch` (lines 1395–1411).
- Test: `tests/wt-functions.test.sh`: the comment above `sq1` (lines 2871–2878), and a new block after `sq4` (after line 2935), before section `W`.

**Interfaces (all in `dot_config/zsh/functions`, all `emulate -L zsh`):**

- `_wt_patch_ids <main> <rev-list-arg>...`: prints one `<patch-id> <commit>` line per non-merge commit with a non-empty patch, in `rev-list` order, from the Global Constraints pipeline. Returns 0 only if all three commands exit 0 (check `pipestatus`) and the output is at least one line, each matching `^[0-9a-f]{40,64} [0-9a-f]{40,64}$`. Otherwise it prints nothing and returns 1.
- `_wt_change_patch_id <main> <from> <to>`: prints the patch id (first word only) of the whole change. Returns 1 on a failed command, an empty id or a non-hex id.
- `_wt_replays_as <main> <from> <to> <x>`: returns 0 only if `merge-tree --write-tree --merge-base=<from> <x>^ <to>` exits 0, `rev-parse <x>^{tree}` exits 0, and the first output line of the former is non-empty and equal to the latter.
- `_wt_rebase_merged <main> <base> <branch>`: the spec's "Rebase test". Returns 0 only if:
  - `rev-list --merges <base>..<branch>` exits 0 and prints nothing;
  - `_wt_patch_ids <main> --reverse <base>..<branch>` succeeds (branch order, oldest first);
  - `_wt_patch_ids <main> <branch>..<base>` succeeds;
  - every branch line, in order, finds a base line with the same id that is not yet used and for which `_wt_replays_as <main> <c>^ <c> <x>` holds. The first such base commit is marked used. A branch line with none returns 1 at once.
- `_wt_squash_merged <main> <base> <branch>`: the spec's "Squash test". Returns 0 only if:
  - `merge-base --all <base> <branch>` exits 0 and prints exactly one line, `<mb>`;
  - `_wt_change_patch_id <main> <mb> <branch>` succeeds, giving `<whole>`;
  - `_wt_patch_ids <main> <base>..<branch>` succeeds and no line has the id `<whole>`;
  - `_wt_patch_ids <main> <mb>..<base>` succeeds and some line with the id `<whole>` satisfies `_wt_replays_as <main> <mb> <branch> <x>`.
- `_wt_branch_content_merged <main> <branch>`: as today (bases, order, skip, merge-base, guard). After the guard, per base: `_wt_rebase_merged`, then `_wt_squash_merged`, then today's merge-tree lines. On the first yes it sets `typeset -g _WT_MERGED_HOW` to `rebase`, `squash` or `merge`, sets `_WT_MERGED_BASE` to the base's short name, and returns 0. It clears both on entry and returns 1 when no base says yes.
- `_wt_rm_branch <main> <branch> <qb>`: unchanged shape. The deletion line becomes, by `_WT_MERGED_HOW`, with `<base>` = `$(_wt_q "$_WT_MERGED_BASE")`:
  - `rebase`: `✓ deleted branch <qb> (rebase-merged — each commit has a copy in <base>)`
  - `squash`: `✓ deleted branch <qb> (squash-merged — one commit in <base> carries its whole change)`
  - `merge`: `✓ deleted branch <qb> (merged — its content is already in <base>)`

- [ ] **Step 1: Write the test block** after `sq4`, under the header `# --- rebase- and squash-merged branches, after the base has moved on ---`. A comment above each case names the behaviour it pins and the bug it catches, in the spec's words ("Tests", cases 1–8) or Review Focus's.

Fixture helpers, defined at the top of the block:

```zsh
rbc() {   # rbc <dir> <file> <msg> <line>... — write <file> as those lines, commit it
  local d="$1" f="$2" m="$3"; shift 3
  print -rl -- "$@" > "$d/$f"
  git -C "$d" add -A && git -C "$d" commit -q -m "$m"
}
rb_start() {   # rb_start <slug> — fresh repo with a seeded log.txt, and the worktree
  setup
  rbc "$REPO" log.txt seed l1 l2 l3
  run "$REPO" wt "$1"
  WT="$HOME/Code/Org/repo-$1"
}
rb_gone() {   # rb_gone <slug> <how> <base> <label> — after `run "$REPO" wt-rm <slug>`
  rc_is 0 "$4: the worktree is removed"
  has "deleted branch $1 ($2" "$4: the deletion line names the $2 test"
  has " in $3" "$4: the deletion line names the base $3"
  hasnt "not fully merged" "$4: no kept warning"
  run "$REPO" git branch --list --format='%(refname:short)' "$1"
  eq "$OUT" "" "$4: the branch is deleted"
}
rb_kept() {   # rb_kept <slug> <label> — after `run "$REPO" wt-rm <slug>`
  rc_is 0 "$2: the worktree is removed"
  has "branch $1 kept (not fully merged)" "$2: wt-rm says the branch is kept"
  run "$REPO" git branch --list --format='%(refname:short)' "$1"
  eq "$OUT" "$1" "$2: the branch still exists"
}
```

"Base moves" below is `rbc "$REPO" other.txt "base moves" o1`. Every git command of a fixture names its directory with `-C`; the suite never changes its own. "Copied" is `git -C "$REPO" cherry-pick <commits>` with output discarded, and each case asserts once that the copy has a new SHA where the case depends on it (`rb1`). Every case ends with `run "$REPO" wt-rm <slug>` and then `rb_gone` or `rb_kept`.

| Case | Fixture, after `rb_start <slug>` | Expect |
|---|---|---|
| `rb1` (spec 1) | `git -C "$REPO" config diff.noprefix true` and `config color.diff always`. Branch: `rbc "$WT" log.txt a l1 l2 l3 rb1-a`, then `rbc "$WT" feature.txt b f1`. Base moves. Copy `main..rb1`. Then `rbc "$REPO" log.txt later l1 l2 l3 "rb1-a CHANGED"`. | `rb_gone rb1 rebase-merged main` |
| `rb2` (spec 2) | Branch: the same two commits (`rb2-a`). Base moves. `SQ=$(git -C "$REPO" commit-tree "rb2^{tree}" -p "$(git -C "$REPO" merge-base main rb2)" -m squash)`, then `git -C "$REPO" merge -q --no-ff -m "merge rb2" "$SQ"`. Then the later commit changing the `rb2-a` line. | `rb_gone rb2 squash-merged main` |
| `rb3` (spec 3) | Branch: `rbc "$WT" a.txt a a1`, `rbc "$WT" b.txt b b1`. Base moves. Copy the first commit only (`rb3~1`). | `rb_kept` |
| `rb4` (spec 4) | Branch: `rbc "$WT" x.txt add x1`, then `git -C "$WT" revert --no-edit HEAD`. Base moves. Copy `main..rb4`. | `rb_kept` |
| `rb5` (spec 5) | Before `wt`, the seed also commits `dup.txt`: `A1 A2 A3 old A4 A5 A6 ---- A1 A2 A3 old A4 A5 A6` (one word per line; use `setup` and `rbc` directly instead of `rb_start`). Branch: one commit changing the first `old` to `new`. Base: one commit changing the second `old` to `new`. Assert the fixture: both commits have the same `git patch-id --verbatim`. | `rb_kept` |
| `rb6` (spec 6) | Branch: `rbc "$WT" a.txt c1 a1`. Side branch in the worktree: `git -C "$WT" switch -q -c rb6-side main`, `rbc "$WT" b.txt s b1`, `git -C "$WT" switch -q rb6`. Merge with content of its own: `git -C "$WT" merge -q --no-ff --no-commit rb6-side`, `print own > "$WT/c.txt"`, `git -C "$WT" add -A`, `git -C "$WT" commit -q -m merge`. Base moves. Copy `rb6~1` (c1) and `rb6-side`. | `rb_kept` |
| `rb7` (spec 7) | Branch: `rbc "$WT" x.txt apply x1`, `git -C "$WT" revert --no-edit HEAD`, `rbc "$WT" x.txt again x1`. Base moves. Copy the first two (`rb7~2 rb7~1`). | `rb_kept` |
| `rb8` (spec 8) | The `rb5` seed. Branch: first `old` to `mid`, then `mid` to `new`, in two commits. Base: one commit changing the second `old` to `new`. | `rb_kept` |
| `rb9` (focus 1) | Branch: `rbc "$WT" log.txt a l1 l2 l3 rb9-a`. `git -C "$REPO" switch -q -c up`, base moves, copy `rb9`, the later commit changing the `rb9-a` line, `git -C "$REPO" switch -q main`, then `git -C "$REPO" update-ref refs/remotes/origin/main up` and `git -C "$REPO" symbolic-ref refs/remotes/origin/HEAD refs/remotes/origin/main`. | `rb_gone rb9 rebase-merged origin/main` |
| `rb10` (focus 2) | Branch: `rbc "$WT" log.txt a l1 l2 l3 rb10-a`, `git -C "$WT" commit -q --allow-empty -m empty`, `rbc "$WT" feature.txt b f1`. Base moves. Copy `rb10~2` and `rb10`. Later commit changing the `rb10-a` line. | `rb_gone rb10 rebase-merged main` |
| `rb11` (focus 3) | The `rb1` fixture with one branch commit (the `log.txt` one), no config. Run `wt-rm` as `PATH="$FAILSTUBS:$PATH" WT_FAIL_MATCH='merge-tree --write-tree' WT_FAIL_NTH=1 WT_FAIL_LOG="$FLOG" run "$REPO" wt-rm rb11` (no `WT_FAIL_SKIP`: the real git prints its tree, then the stub exits 128). Assert the fixture: line 1 of `$FLOG` contains `--merge-base=`. | `rb_kept` |
| `rb12` (task review) | Seed `log.txt` = `l1`–`l5`. Branch: one commit turns `l3` into `A`, a second adds `feature.txt`. Base: one commit changes `l1` to `L1` (context drift, so no patch id matches), then one commit applies `l3` to `A` and adds `feature.txt`. Pins the merge-tree fallback (spec, Order 3). | `rb_gone rb12 merged main` |
| `rb13` (task review) | The `rb11` fixture. Run `wt-rm` as `PATH="$FAILSTUBS:$PATH" WT_FAIL_MATCH='rev-list --no-merges' WT_FAIL_NTH=1 WT_FAIL_LOG="$FLOG" run "$REPO" wt-rm rb13`. Assert the fixture: line 1 of `$FLOG` contains `rev-list --no-merges`. Pins that a patch-id pipeline whose first command fails after printing keeps the branch. | `rb_kept` |

Why `rb6` uses a merge with an added file instead of a resolved conflict: the spec's point is a merge commit with content of its own, and this fixture has it without making the copies conflict (a ruling inside the spec).

- [ ] **Step 2: Run the suite on the unchanged functions**

Run: `./tests/wt-functions.test.sh > "$TMPDIR/wtf-red.out" 2>&1; print "exit $?"; rg 'FAIL' "$TMPDIR/wtf-red.out"`

Expected: the only FAIL lines are the deletion assertions of `rb1`, `rb2`, `rb9`, `rb10` and the fixture assertion of `rb11`. Every assertion of `rb3`–`rb8` passes, and so does every case outside the new block. Any other failure is a fixture bug: fix the fixture, not the expectation. Keep the FAIL lines for the report.

- [ ] **Step 3: Implement** the six interfaces above. Update the comments:
  - above `_wt_branch_content_merged`: what the three tests ask and their order, that a patch-id match only nominates and the replay decides, that the guard runs first, and "fails closed" for the new failure modes. Point at the spec for the reasons; do not restate its measurements;
  - in `_wt_rm_branch`: the `-d first` comment says a squash- or rebase-merged branch fails `-d`;
  - above `sq1` in the suite: `wt-rm` asks three content questions after `-d`; the `sq` cases pin the merge-tree one and the `rb` cases the patch-id ones.

- [ ] **Step 4: Run the suite**

Run: `./tests/wt-functions.test.sh > "$TMPDIR/wtf-green.out" 2>&1; print "exit $?"; rg -c 'PASS' "$TMPDIR/wtf-green.out"; rg 'FAIL' "$TMPDIR/wtf-green.out"`

Expected: exit 0, no FAIL line. Report passed/total from the suite's summary line.

- [ ] **Step 5: Commit** (check `git branch --show-current` prints `fix/wt-rm-rebase-merged` first)

```bash
git add dot_config/zsh/functions tests/wt-functions.test.sh
git commit -m "Delete rebase- and squash-merged branches in wt-rm by patch id and replay"
```

### Task 2: each safety case against its broken variant

**Depends on:** Task 1.

**Files:**
- Modify temporarily, never committed: `dot_config/zsh/functions`.
- Modify: this plan, the table below.

One variant at a time: apply the edit, run `./tests/wt-functions.test.sh > "$TMPDIR/wtf-<variant>.out" 2>&1; print "exit $?"; rg 'FAIL' "$TMPDIR/wtf-<variant>.out"`, record the result, then `git checkout -- dot_config/zsh/functions` and confirm `git status --short` is empty before the next one. A variant passes its check when the suite exits non-zero and the named case's "the branch still exists" assertion is among the FAIL lines. If the named case does not fail, stop and report: the case or the code is wrong, and that is not fixed by adjusting the variant.

| Variant | Edit | Case that must fail |
|---|---|---|
| V3 | `_wt_rebase_merged`: a branch commit with no pair is skipped instead of returning 1 | `rb3` |
| V4 | `_wt_branch_content_merged`: remove the no-net-change guard line | `rb4` |
| V5 | `_wt_rebase_merged`: the replay check always succeeds | `rb5` |
| V6 | `_wt_rebase_merged`: remove the merge-commit refusal | `rb6` |
| V7a | `_wt_rebase_merged`: never mark a base commit used | `rb7` |
| V7b | `_wt_squash_merged`: remove the stand-aside for the branch's own commits | `rb7` |
| V8 | `_wt_squash_merged`: the replay check always succeeds | `rb8` |
| V11 | `_wt_replays_as`: ignore `merge-tree`'s exit status | `rb11` |
| V13 | `_wt_patch_ids`: judge by the pipeline's output alone, ignoring a failed `rev-list` | `rb13` |

- [ ] **Step 1: Run V3, V4, V5, V6, V7a, V7b, V8, V11 and V13**, in that order, as above.
- [ ] **Step 2: Record** each run in the table under "Mutation record" at the end of this plan: the date, the suite's exit status and the FAIL lines of the named case, verbatim.
- [ ] **Step 3: Confirm the functions are restored**: `git diff --stat -- dot_config/zsh/functions` prints nothing, then run the suite once more; expected exit 0 and no FAIL line.
- [ ] **Step 4: Commit**

```bash
git add docs/superpowers/plans/2026-11-11-wt-rm-rebase-merged.md
git commit -m "Record the broken-variant runs of the wt-rm safety cases"
```

### Task 3: records and close-out

**Depends on:** Task 2.

**Files:**
- Modify: `docs/superpowers/specs/2026-07-30-worktree-hook-protocol-design.md`: a banner after the 2026-10-13 one; the body is not rewritten.
- Modify: `docs/superpowers/specs/2026-11-11-wt-rm-rebase-merged-design.md`: the Status line only.
- Modify: this plan: Status, and the completion banner.

- [ ] **Step 1: Add the banner**, as its own blockquote directly below the 2026-10-13 one:

```markdown
> **2026-11-11 — amended.** §8 step 13 and §9.3's "Attempt `git branch -d`, never `-D`": when
> `-d` refuses, `wt-rm` now deletes a branch whose work reached the base by a squash- or
> rebase-merge, with `-D` after a content test that keeps every unclear case; see
> [wt-rm: delete rebase-merged branches](./2026-11-11-wt-rm-rebase-merged-design.md).
```

- [ ] **Step 2: Run the suites** (the runner may wait for its machine lock; let it):
  - `./tests/run.sh`
  - `./tests/run.sh xreview git-forge-guard wt-functions`

  Expected: every suite passes. Record passed/total per run, and any `????` or `INCONSISTENT` row with its reason.

- [ ] **Step 3: Set the statuses** in the final pre-merge commit:
  - the spec: `**Status:** Implemented (branch `fix/wt-rm-rebase-merged`; no MR, a dotfiles line)`;
  - this plan: the same Status, and below it `> **Completed 2026-11-11.** Executed on `fix/wt-rm-rebase-merged`; do not run it again. Its execution notes bind that run only.` (use the actual completion date).

```bash
git add docs/superpowers
git commit -m "Amend the worktree hook protocol spec and mark the wt-rm rebase-merged records implemented"
```

- [ ] **Step 4: Pre-merge review**: `xreview -C <checkout> dispatch --checkpoint pre-merge --diff main...fix/wt-rm-rebase-merged`. Fix every finding in its round; a round that changes code or tests reruns Step 2's suites for what changed, and the three heavy suites before the last review.
- [ ] **Step 5: Push**, as its own command: `git push -u origin fix/wt-rm-rebase-merged`. No MR and no merge.

## Mutation record

Filled in by Task 2.

| Variant | Date | Suite exit | FAIL lines of the named case |
|---|---|---|---|
| V3 | 2026-11-11 | 1 | FAIL: rb3 one commit not copied: wt-rm says the branch is kept<br>FAIL: rb3 one commit not copied: the branch still exists ('' != 'rb3') |
| V4 | 2026-11-11 | 1 | FAIL: rb4 no net change: wt-rm says the branch is kept<br>FAIL: rb4 no net change: the branch still exists ('' != 'rb4') |
| V5 | 2026-11-11 | 1 | FAIL: rb5 repeated block, one commit: wt-rm says the branch is kept<br>FAIL: rb5 repeated block, one commit: the branch still exists ('' != 'rb5') |
| V6 | 2026-11-11 | 1 | FAIL: rb6 merge commit with its own content: wt-rm says the branch is kept<br>FAIL: rb6 merge commit with its own content: the branch still exists ('' != 'rb6') |
| V7a | 2026-11-11 | 1 | FAIL: rb7 repeated patch: wt-rm says the branch is kept<br>FAIL: rb7 repeated patch: the branch still exists ('' != 'rb7') |
| V7b | 2026-11-11 | 1 | FAIL: rb7 repeated patch: wt-rm says the branch is kept<br>FAIL: rb7 repeated patch: the branch still exists ('' != 'rb7') |
| V8 | 2026-11-11 | 1 | FAIL: rb8 repeated block, whole change: wt-rm says the branch is kept<br>FAIL: rb8 repeated block, whole change: the branch still exists ('' != 'rb8') |
| V11 | 2026-11-11 | 1 | FAIL: rb11 failing replay: wt-rm says the branch is kept<br>FAIL: rb11 failing replay: the branch still exists ('' != 'rb11') |
| V13 | 2026-11-11 | 1 | FAIL: rb13 failing patch-id pipeline: wt-rm says the branch is kept<br>FAIL: rb13 failing patch-id pipeline: the branch still exists ('' != 'rb13') |

## Execution notes (2026-11-11)

- The variants ran on `git archive` copies of 04c7c96 under `$TMPDIR`, up to four at once, after an unmutated copy gave 1219/1219; the checkout's functions were never mutated. Each variant is a one-line edit, and each named case failed because its branch was deleted.
- Other cases fail under some variants, as the code predicts: V3 also deletes `sq4`, `rb5`, `rb7`, `rb8` and `rb11` and renames the `rb2` and `rb12` deletions; V4 deletes case `i`; V5 and V7b delete `rb11`, and V7b `rb13`. `rb11` and `rb13` keep their branch partly through the squash test standing aside; V11 and V13 show that the exit-status check and `pipefail` matter on their own.
- `X13b` ("every mise call wt makes has stdin from /dev/null") failed in two of the eleven parallel runs (under V4 and V7b). Neither variant is on the path of the calls it logged, and it passed in every single run in the checkout. It is an existing load-sensitive assertion, outside this change; it may turn a loaded run red.

## Rulings

- Cases 3–8 drive `wt-rm`, like the `sq` cases, so that each asserts the real outcome (the kept message and the surviving branch).
- `rb6` gives its merge commit content of its own with an added file instead of a resolved conflict (see Task 1).
- `rb12`, `rb13` and V13 were added after Task 1's review (2026-11-11): with the rebase test in front, `sq1` and `sq2` no longer reach the merge-tree test's yes, so `rb12` pins that fallback and its `merged` line; `rb13` pins that a failed patch-id pipeline keeps the branch. Every case also asserts that its fixture built.
- `rb9`–`rb11` and the configuration lines in `rb1` come from Review Focus, not from the spec's list. V11 is added so that `rb11` is shown to fail without the status check.
