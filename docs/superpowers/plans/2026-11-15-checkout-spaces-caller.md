# Check 5 reads a foreground group Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking. In this repository the controller loads the `plan-run` skill first; it overrides superpowers.

**Status:** Completed 2026-11-15 (branch `fix/checkout-spaces-caller`, its PR against `main`).
Do not run it again; its execution notes bind that run only. The task review added one guard
beyond Task 1's text: `group_folders` also fails when the checkout's path holds a byte `lsof`
escapes under `LC_ALL=C` (spec, Amendment step 3); the final review moved the five-second bound
into one `bounded` helper.

**Goal:** `checkout-spaces` check 5 stops refusing a terminal that answers `hc get` without a folder when the folders of its foreground group can be read and none is in the checkout, so `wt-rm` and Retire run from an app terminal no longer refuse on their own terminal.

**Architecture:** In the helper's check-5 loop, a terminal with no `.foreground.cwd` in its answer gets its foreground group from `ps -o tpgid=` on hc's top-level `.pid`, and each member's folder from `lsof -a -g <group> -d cwd -Fn` (five-second bound, as `hc get` has). Any folder in the checkout refuses; an unreadable group refuses. The raw-or-resolved "in the checkout" test moves into one function both paths use.

**Tech Stack:** zsh (helper, suite), POSIX sh (stubs), jq, `ps`, `lsof`, `/usr/bin/perl` (the existing alarm wrapper).

**Spec:** `docs/superpowers/specs/2026-11-15-wt-rm-app-spaces-design.md`, section "Amendment (2026-11-15)" (signed off 2026-11-15) and §2 check 5. Read both before the task.

## Global Constraints

- Work only in `/Users/michael/.local/share/chezmoi-fix-checkout-spaces-caller` on `fix/checkout-spaces-caller`; check `git branch --show-current` before each commit.
- Nothing runs against the live Herdr app, herdr-core, the TUI or a real checkout: no unstubbed `herdr-app`, `hc`, `wt-rm`, `git worktree remove`, no space close.
- Never edit a deployed file (`~/.config/...`, `~/.local/bin/...`); edit the chezmoi source.
- The helper's pinned PATH line stays verbatim: `PATH=$HOME/.local/bin:/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin`. `ps` and `lsof` are called by name (so the suite's stubs in the scratch `$HOME/.local/bin` answer); `lsof` runs under the same `/usr/bin/perl -e 'alarm shift; exec @ARGV' 5 …` bound `hc_get` uses.
- Every `hc` call keeps running with `HC_TERMINAL_ID` and `HC_SCOPE` removed; the caller's `HC_TERMINAL_ID` stays read only for check 1.
- A terminal that answers with a folder, and one that does not answer at all, are judged exactly as today.
- The refusal for an unreadable answer keeps the words `hc get gave no folder` (the `nofolder` case greps `tNEW1.*gave no folder`).
- Execute suites (`./tests/x.test.sh` or `./tests/run.sh <name>`), never `bash tests/x.test.sh`. Report totals as passed/total. Read `tests/AGENTS.md` before changing the suite.
- Tests: Michael's rule, one case per new behaviour or plausible regression, extending existing cases first; no variant matrices. Each assertion passes the revert check.
- A new file the suite loads gets its `.scripts/test-audit/subjects.tsv` row in the same commit.
- Commits: small, imperative mood, no agent attribution, no explanatory comments beyond the surrounding style.

## Review Focus

- `lsof` that hangs (a stalled network mount): `-b -w` and the five-second alarm bound it; a timeout is a failed read, so it refuses.
- A root process with no controlling terminal (`ps` answers `tpgid` 0) or a pid that is gone: a failed read, so it refuses; never "no folders, so nothing inside".
- A folder with spaces, or one reached through a symlink: `lsof -Fn` gives one `n<path>` line per process; the in-checkout test checks the raw and the resolved path, as today.
- An answer that is not JSON, or whose `.pid` is not a number: a failed read, so it refuses.
- `lsof` listing processes but no `n` line (no cwd readable): no folder, so it refuses.

---

### Task 1: Check 5 reads the foreground group of a terminal without a folder

**Files:**
- Modify: `dot_config/herdr-app/bin/executable_checkout-spaces` (the check-5 loop in `do_check`, plus two new functions above `do_check`)
- Modify: `tests/fixtures/herdr-app/stubs/ps` (a `tpgid=` answer)
- Create: `tests/fixtures/herdr-app/stubs/lsof` (mode 755)
- Modify: `tests/herdr-app.test.sh` (`newworld`'s stub link list; one new case after `nofolder`)
- Modify: `.scripts/test-audit/subjects.tsv` (row `tests/fixtures/herdr-app/stubs/lsof	sh	-	herdr-app`, beside the other stub rows)

**Interfaces:**
- Consumes: the helper's `$folder` (the resolved checkout), `hc_get`, `where_is`, the `inside` array.
- Produces:
  - `in_checkout <path>`: status 0 when `<path>`, raw or resolved (`:A`), is `$folder` or lies under `$folder/`; replaces the inline test in check 5.
  - `group_folders <hc-get-answer>`: prints the folder of every process in the answering terminal's foreground group, one per line; status non-zero, printing nothing, when the answer has no numeric `.pid`, `ps -o tpgid= -p <pid>` fails or answers no number above 0, or bounded `lsof -b -w -a -g <group> -d cwd -Fn` fails or gives no `n` line.
  - The `ps` stub: `-o tpgid= -p <pid>` answers `$STUB_DIR/tpgid-<pid>` and fails without it, logged as its other answers are.
  - The `lsof` stub: any call with `-g <group>` answers, for each line of `$STUB_DIR/lsof-<group>`, the three lines `p<n>`, `fcwd`, `n<that line>` (as `-Fn` prints them), logs `lsof <args>` to `$STUB_LOG`, and fails without the file; any other call runs `/usr/sbin/lsof`.

- [x] **Step 1: Link the stubs the helper will reach, and extend the `ps` stub; add the `lsof` stub and its `subjects.tsv` row**

`newworld`'s line `for s in herdr-app hc fzf claude wt-rm` gains `ps lsof`: the helper's pinned PATH reaches stubs only through the scratch `$HOME/.local/bin`. The stubs' header comments say which suite uses which answer.

- [x] **Step 2: Write the failing case, after the `nofolder` case**

```zsh
# A terminal that answers without a folder is judged by its foreground group: ps gives the group
# in its root's terminal, lsof each member's folder. The caller's own terminal is the one seen
# (wt-rm runs the helper from it, and hc often cannot name that foreground).
newworld group; print '{"state":"live","pid":4242}' > $STUB_DIR/get-t9.json; print 777 > $STUB_DIR/tpgid-4242
print -l / $main > $STUB_DIR/lsof-777
cs check $wt >$world/out 2>&1; rc=$?
check "a terminal without a folder passes when its foreground group is outside the checkout" test $rc -eq 0
print -l / $wt/src > $STUB_DIR/lsof-777
cs check $wt >$world/out 2>&1; rc=$?
check "...refuses when one process of that group is inside" test $rc -eq 1
check "...and names the terminal and the folder" grep -qF -- "t9 (proj / retire) is in $wt/src" $world/out
rm $STUB_DIR/lsof-777
cs check $wt >$world/out 2>&1; rc=$?
check "...and refuses when the group cannot be read" test $rc -eq 1
```

- [x] **Step 3: Run it and see the first assertion fail**

Run: `./tests/herdr-app.test.sh 2>&1 | grep -E 'FAIL|foreground group'`
Expected: two FAIL lines: `a terminal without a folder passes when its foreground group is outside the checkout` (today's helper refuses every no-folder answer) and `...and names the terminal and the folder` (today's refusal names no folder). The two `rc -eq 1` assertions pass for today's reason.

- [x] **Step 4: Implement `in_checkout` and `group_folders`, and use them in check 5**

In the check-5 loop: a non-empty `.foreground.cwd` is the one folder tested, as today. Otherwise, a non-empty answer whose `group_folders` succeeds gives the folders tested. Otherwise the existing "cannot tell where terminal $t ($(where_is $t)) is: hc get gave no folder" refusal, which may add that its foreground group could not be read. The first folder in the checkout adds the existing "terminal $t ($(where_is $t)) is in <folder>; cd out of the checkout or close it" refusal and stops testing that terminal.

- [x] **Step 5: Run the suites and see them pass**

Run: `./tests/run.sh herdr-app`
Expected: `herdr-app`, `herdr-app-resume`, `herdr-app-xreview` all `ok`, `herdr-app` at 199/199 (195 on main plus these four).

- [x] **Step 6: Revert check**

Step 3 already showed assertions 1 and 3 failing without the change. Mutate the source temporarily, one mutation at a time, run `./tests/herdr-app.test.sh`, and confirm:
- the folders `group_folders` gives are not tested (any readable group passes): assertions 2 and 3 fail;
- `group_folders` failing is read as "no folders" (passes): assertion 4 fails.
Restore the source (`git diff` shows only the intended change) and rerun Step 5. Report each mutation and its result.

- [x] **Step 7: Commit**

```bash
git add dot_config/herdr-app/bin/executable_checkout-spaces tests/fixtures/herdr-app/stubs/ps tests/fixtures/herdr-app/stubs/lsof tests/herdr-app.test.sh .scripts/test-audit/subjects.tsv
git commit -m "Read the foreground group of a terminal that answers without a folder in checkout-spaces check 5"
```
