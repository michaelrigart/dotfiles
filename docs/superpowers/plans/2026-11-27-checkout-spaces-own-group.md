# Check 5's snapshot ps keeps out of the group it reads Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking. In this repository the controller loads the `plan-run` skill first; it overrides superpowers.

**Status:** Completed 2026-11-27 (branch `fix/checkout-spaces-own-group`, its PR against `main`).
Do not run it again; its execution notes bind that run only. Task 1 as written; the controller's
measurement on the final code: today's helper refused 10 in 10, the branch's passed 10 in 10 and
refused 3 in 3 with a setuid `top` in the group.

**Goal:** `checkout-spaces` check 5 stops refusing the caller's own terminal because its own setuid `ps` lists itself as uid 0 in the group it reads, so `wt-rm` and Retire run from a Herdr app terminal no longer refuse there.

**Architecture:** In `group_folders`, the one `ps -A -o uid=,pgid=` snapshot runs through `/usr/bin/perl -e 'setpgrp(0, 0) and exec @ARGV; exit 1'`, which puts it in a process group of its own before it runs. The uid test, its parsing and its refusal are unchanged. The suite's `ps` stub gains the row the real `ps` prints for itself.

**Tech Stack:** zsh (helper, suite), POSIX sh (stubs), `/usr/bin/perl`.

**Spec:** `docs/superpowers/specs/2026-11-27-checkout-spaces-own-group-design.md` (signed off 2026-11-27). Read it, and section "Amendment (2026-11-15)" of `docs/superpowers/specs/2026-11-15-wt-rm-app-spaces-design.md`, before the task.

## Global Constraints

- Work only in `/Users/michael/.local/share/chezmoi-fix-checkout-spaces-own-group` on `fix/checkout-spaces-own-group`; check `git branch --show-current` before each commit.
- Nothing runs against the live Herdr app, herdr-core or a real checkout: no unstubbed `herdr-app`, `hc` or `wt-rm`, no space close. Never edit a deployed file (`~/.config/...`, `~/.local/bin/...`).
- The helper's pinned PATH line stays verbatim; `ps` is still called by name, so the suite's stub in the scratch `$HOME/.local/bin` answers.
- The uid test (the `awk` program), the `lsof` read and every refusal's wording stay as they are. No exception for the caller's terminal or the helper's own group.
- Execute suites (`./tests/herdr-app.test.sh`, `./tests/run.sh <name>`), never `bash tests/x.test.sh`; it is zsh. Report totals as passed/total. Read `tests/AGENTS.md` before changing the suite. The sandbox denies the real setuid `/bin/ps`; nothing in the suite may need it.
- No new file, so no new `tests/subjects/herdr-app.tsv` row.
- Commits: imperative mood, no agent attribution, no comments beyond the surrounding style.

## Review Focus

- `perl` cannot `setpgrp` or cannot `exec` `ps` (not found, not executable): it exits 1, the snapshot fails, and the read refuses ("its foreground group could not be read"); never an empty snapshot read as "no other user".
- The snapshot `ps` now runs in a background group of the caller's terminal: it writes only to the `$(...)` pipe, stderr goes to `/dev/null` and it reads no input, so `stty tostop`, SIGTTOU and SIGTTIN cannot stop it; a Ctrl-C reaches the helper, which dies, and `wt-rm` then refuses.
- A caller with no controlling terminal (a Claude Code Bash command): the snapshot `ps` was never in the terminal's group; behaviour unchanged.
- The group read for a foreign terminal (not the caller's): the snapshot `ps` was never in it; behaviour unchanged, and another user's process there still refuses (existing case, group 100777).
- A fixed fixture group colliding with a real one: fixtures use 100777, above macOS's largest pid (99999).

---

### Task 1: The snapshot ps runs in its own process group

**Depends on:** none.

**Files:**
- Modify: `tests/fixtures/herdr-app/stubs/ps` (the `-A -o uid=,pgid=` branch and its header line)
- Modify: `tests/herdr-app.test.sh` (the `group` and `group-café` cases, about lines 199–224; one new case between them)
- Modify: `dot_config/herdr-app/bin/executable_checkout-spaces` (`group_folders`, the `procs=` line and the comment above it, about lines 97–99)
- Modify: `docs/superpowers/specs/2026-11-15-wt-rm-app-spaces-design.md` (one dated pointer in its `**Amended:**` header)

**Interfaces:**
- Consumes: `group_folders`, `cs`, `newworld`, `check`, the stubs' `$STUB_DIR` files (`get-<t>.json`, `tpgid-<pid>`, `uid-pgid`, `lsof-<group>`).
- Produces: the `ps` stub's `-A -o uid=,pgid=` answer is `$STUB_DIR/uid-pgid` followed by one line `0 <the stub's own process group>` (read with `/usr/bin/perl -e 'print getpgrp'`), as the setuid real one lists itself; it still fails without the file.

- [ ] **Step 1: Make the stub list itself, and move the fixture group**

In the stub's `-A -o uid=,pgid=` branch, after `cat "$STUB_DIR/uid-pgid"`, `echo "0 $(/usr/bin/perl -e 'print getpgrp')"` (the stub is POSIX sh). Its header line says the answer ends with the stub's own row, uid 0 in its own process group, as the setuid real `ps` lists itself.

In `tests/herdr-app.test.sh`, the `group` and `group-café` worlds read group 100777 instead of 777 everywhere (`tpgid-4242`, the `uid-pgid` rows, `lsof-<group>`, the added `0 <group>` row), so the stub's own row can never land in it.

- [ ] **Step 2: Write the failing case**

Between the `group` world's last check (`...and refuses when the group cannot be read`) and the `group-café` comment:

```zsh
# The real ps is setuid root, so it lists itself as uid 0. Read from the caller's own terminal,
# the group is the helper's own (here the suite's, which the helper inherits), and the snapshot
# must not count itself.
newworld own-group; g=$(/usr/bin/perl -e 'print getpgrp')
print '{"state":"live","pid":4242}' > $STUB_DIR/get-t9.json; print $g > $STUB_DIR/tpgid-4242
print -l "$UID $g" "-2 1" > $STUB_DIR/uid-pgid; print -l / $main > $STUB_DIR/lsof-$g
cs check $wt >$world/out 2>&1; rc=$?
check "the helper's own foreground group passes, though ps lists itself there as uid 0" test $rc -eq 0
print "0 $g" >> $STUB_DIR/uid-pgid
cs check $wt >$world/out 2>&1; rc=$?
check "...and refuses when another user's process is in that group" test $rc -eq 1
```

- [ ] **Step 3: Run it and see the one failure**

Run: `./tests/herdr-app.test.sh 2>&1 | grep -E 'FAIL|lists itself|is in that group'`
Expected: two lines. One FAIL, `the helper's own foreground group passes, though ps lists itself there as uid 0`; one PASS, `...and refuses when another user's process is in that group`. Then `./tests/herdr-app.test.sh | tail -3` shows 322/323 (the baseline is 321/321).

- [ ] **Step 4: Implement**

In `group_folders`, the snapshot line becomes exactly (spec, Design):

```zsh
  procs=$(/usr/bin/perl -e 'setpgrp(0, 0) and exec @ARGV; exit 1' ps -A -o uid=,pgid= 2>/dev/null) && [[ -n $procs ]] || return 1
```

Extend the comment above it by one sentence: `ps` is setuid root and lists itself as uid 0, so it runs in a process group of its own, never in the group it reads.

- [ ] **Step 5: Run the suite**

Run: `./tests/run.sh herdr-app xreview-app-pane` (the `ps` stub is also `xreview-app-pane`'s subject; `run.sh` judges each suite on its exit status)
Expected: every selected suite `ok`, herdr-app 323/323.

- [ ] **Step 6: Revert and mutation checks**

1. Revert check, first new assertion: restore the old `procs=$(ps -A -o uid=,pgid= 2>/dev/null)` line, run the suite: only `the helper's own foreground group passes…` fails. Restore Step 4's line.
2. Mutation check, second new assertion (it guards the declined alternative, spec Tests): in `group_folders`, run the `awk` uid test only when `$group` differs from `$(/usr/bin/perl -e 'print getpgrp')`. Run the suite: only `...and refuses when another user's process is in that group` fails, while `...and refuses when another user's process is in the group, whatever lsof listed` (group 100777) still passes. Remove the mutation.

`git diff` afterwards shows only Steps 1, 2 and 4.

- [ ] **Step 7: Point the 2026-11-15 spec at this one**

Append to its `**Amended:**` header one dated sentence: 2026-11-27, check 5's uid snapshot runs in a process group of its own, see `docs/superpowers/specs/2026-11-27-checkout-spaces-own-group-design.md`. Change nothing else in that spec.

- [ ] **Step 8: Commit**

```bash
git add tests/fixtures/herdr-app/stubs/ps tests/herdr-app.test.sh dot_config/herdr-app/bin/executable_checkout-spaces docs/superpowers/specs/2026-11-15-wt-rm-app-spaces-design.md
git commit -m "Run check 5's uid snapshot outside the group it reads"
```

---

## Controller, after Task 1

- Rerun the spec's measurement on the final commit, unsandboxed (it needs a pty), with the harness `.superpowers/sdd/2026-11-27-checkout-spaces-own-group/semilive.zsh` (git-ignored run state; it stubs `herdr-app` and `hc` and keeps the real `ps` and `lsof`). Today's helper is `git show main:dot_config/herdr-app/bin/executable_checkout-spaces`, saved to a scratch file with mode 755:
  - `zsh .superpowers/sdd/2026-11-27-checkout-spaces-own-group/semilive.zsh <today's helper> 10`: refuses 10 in 10;
  - `zsh .superpowers/sdd/2026-11-27-checkout-spaces-own-group/semilive.zsh <branch helper> 10`: passes 10 in 10;
  - `SEMILIVE_TOP=1 zsh .superpowers/sdd/2026-11-27-checkout-spaces-own-group/semilive.zsh <branch helper> 3`: refuses 3 in 3.
- `./tests/run.sh --changed`, then the pre-merge review (a cold Claude review in place of Codex, per the sign-off).
