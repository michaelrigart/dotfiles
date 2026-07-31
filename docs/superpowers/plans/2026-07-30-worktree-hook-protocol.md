# Worktree Hook Protocol Implementation Plan

**Status:** Implemented — merged in 0e5dde9
**Date:** 2026-07-30

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.
>
> **This plan is not re-runnable.** Once its tasks are complete, its status becomes `Implemented` and it must not be executed again. The `DO NOT COMMIT`-style instructions and task ordering below apply to one execution only; they are not repository policy.

**Goal:** Add a `.worktreehook` protocol plus a `wt-prepare` recovery command to the dotfiles worktree lifecycle, so repositories can prepare and reclaim their own per-worktree resources without any project knowledge entering `wt`.

**Architecture:** Small single-purpose zsh helpers (`_wt_*`) compose into three user commands (`wt`, `wt-prepare`, `wt-rm`). Every helper is independently testable against real Git repositories. All Git access goes through one routing-cleared wrapper; all cleanliness decisions go through one fail-closed helper; all lifecycle commands hold one kernel lock.

**Tech Stack:** zsh (functions sourced from `~/.zshrc`), Git ≥ 2.28, `zsh/system` module, `wtcp`, Zellij, chezmoi.

**Spec:** `docs/superpowers/specs/2026-07-30-worktree-hook-protocol-design.md` (committed `ab751b2`, Status: Approved). Section references below (`§4.2`, `§7.2`) point into it.

## Global Constraints

- **All files edited in the chezmoi source**, never the deployed copy: edit `~/.local/share/chezmoi/dot_config/zsh/functions`, then `chezmoi apply`. Never edit `~/.config/zsh/functions` directly.
- **Every Git invocation** in these functions goes through `_wt_git` (Task 1). A bare `git` call in lifecycle code is a defect.
- **Every cleanliness decision** goes through `_wt_clean` (Task 2). Never test `git status` output without its exit status.
- **Never** `git worktree remove --force`, **never** `git branch -D`, **never** `wtcp --force`.
- **Every branch name interpolated into a printed command** is quoted with `${(q-)…}` (§9.2).
- Existing behaviour committed in `6e0213e` must keep passing: the suite starts at 46 assertions and only grows.
- Test harness rules: root scratch dirs at `$TMPDIR` explicitly (bare `mktemp -d` is refused under sandbox); simulate an absent tool with a stripped `PATH`, never by moving a stub, because the real tool is installed.
- Verification after every task: `zsh -n dot_config/zsh/functions .scripts/test-wt-functions.sh && zsh .scripts/test-wt-functions.sh`.

---

## File Structure

- **Modify** `dot_config/zsh/functions` — all helpers and commands. Currently ~400 lines holding `op-edit`, `tsh`, `_wt_session_name`, `dev`, `wt`, `_wt_assert_worktree`, `wt-rm`. New `_wt_*` helpers are added as a contiguous block immediately before `wt`, keeping the worktree lifecycle together and away from the unrelated `op-edit`/`tsh` helpers.
- **Modify** `.scripts/test-wt-functions.sh` — one new labelled section per task, appended in task order so the file reads in the same sequence as this plan.

No new files. Splitting the lifecycle into a separate sourced file would change `~/.zshrc`, which is out of scope for this change.

---

### Task 1: Routing-cleared Git wrapper and primary-worktree resolution

**Files:**
- Modify: `dot_config/zsh/functions` (insert helpers before the `wt` function)
- Test: `.scripts/test-wt-functions.sh`

**Interfaces:**
- Consumes: nothing.
- Produces:
  - `_wt_git <git-args...>` — runs `git` with routing environment cleared. Same exit status and output as `git`.
  - `_wt_primary` — prints the absolute primary-worktree root on stdout, exit 0. Exit 1 with a message on stderr when not in a repository or when the repository is bare.

- [ ] **Step 1: Write the failing tests**

Append to `.scripts/test-wt-functions.sh`, before the final summary block:

```zsh
print -r -- "G. _wt_git / _wt_primary"
setup
run "$REPO" _wt_primary
eq "$OUT" "$REPO" "primary resolves to the main checkout"

run "$REPO" wt p1
run "$HOME/Code/Org/repo-p1" _wt_primary
eq "$OUT" "$REPO" "primary resolves to main from inside a linked worktree"

# An exported GIT_DIR must not redirect resolution to another repository.
setup
git init -q -b main "$ROOTTMP/decoy"
git -C "$ROOTTMP/decoy" commit -q --allow-empty -m init
OUT="$(cd "$REPO" && source "$FUNCS" && GIT_DIR="$ROOTTMP/decoy/.git" _wt_primary 2>&1)"; RC=$?
eq "$OUT" "$REPO" "exported GIT_DIR does not misroute primary resolution"

setup
git init -q --bare -b main "$ROOTTMP/bare.git"
# Tested from inside the bare repo itself, deliberately. Adding a worktree to a
# commitless bare repo happens to work on current Git (it infers --orphan), but
# relying on that is a version dependency this test does not need.
run "$ROOTTMP/bare.git" _wt_primary
rc_is 1 "bare repository is refused"
has "bare" "bare refusal says why"


# _wt_assert_worktree enumerates the same paths and must be equally protected.
setup
run "$REPO" wt p2
git init -q -b main "$ROOTTMP/decoy2"
git -C "$ROOTTMP/decoy2" commit -q --allow-empty -m init
OUT="$(cd "$REPO" && source "$FUNCS" && \
  GIT_DIR="$ROOTTMP/decoy2/.git" _wt_assert_worktree "$REPO" "$HOME/Code/Org/repo-p2" p2 2>&1)"; RC=$?
rc_is 0 "exported GIT_DIR does not misroute _wt_assert_worktree"
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `zsh .scripts/test-wt-functions.sh 2>&1 | rg 'G\.' -A6`
Expected: FAIL — `_wt_primary` is not a defined function, so `run` returns nonzero and `OUT` is a "command not found" message.

- [ ] **Step 3: Implement**

Insert into `dot_config/zsh/functions` immediately before the `# wt — spin up…` comment block:

```zsh
# _wt_git — git with its routing environment cleared. Every Git call in the
# worktree lifecycle goes through this. An exported GIT_DIR or GIT_WORK_TREE
# silently redirects git to another checkout: `status` then reports a dirty
# worktree as clean *with exit status 0*, and `worktree list`, `ls-files`,
# `worktree remove` and `branch -d` all act on the wrong repository.
_wt_git() {
  emulate -L zsh
  command env -u GIT_DIR -u GIT_WORK_TREE -u GIT_INDEX_FILE -u GIT_COMMON_DIR \
    -u GIT_OBJECT_DIRECTORY -u GIT_ALTERNATE_OBJECT_DIRECTORIES -u GIT_NAMESPACE \
    git "$@"
}

# _wt_primary — absolute path of the repository's primary worktree.
#
# Resolved from `worktree list`, never by path arithmetic on --git-common-dir:
# taking the parent of the common dir is correct for a standard repo
# (/…/repo/.git → /…/repo) but yields the *containing directory* for a bare one
# (/…/repo.git → /…/), which is not a worktree at all.
#
# -z is required: the line-based porcelain format gives no guarantee that a path
# is emitted raw, so a path needing quoting cannot be parsed unambiguously.
# Records are NUL-terminated; ${(0)} drops the empty separator records, leaving
# field 1 = "worktree <path>" and, for a bare repo, field 2 = "bare".
_wt_primary() {
  emulate -L zsh
  local -a f
  f=( ${(0)"$(_wt_git worktree list --porcelain -z 2>/dev/null)"} )
  [[ "${f[1]}" == 'worktree '* ]] || {
    print -ru2 -- "wt: not inside a git repository."; return 1 }
  [[ "${f[2]}" == bare ]] && {
    print -ru2 -- "wt: repository is bare — there is no primary worktree to run from."; return 1 }
  print -r -- "${f[1]#worktree }"
}
```

Then convert the two pre-existing Git call sites that enumerate or resolve
worktrees. In `_wt_assert_worktree`, replace the line-based enumeration:

```zsh
  # was: lines=( ${(f)"$(git -C "$root" worktree list --porcelain 2>/dev/null)"} )
  local -a recs paths; local p
  recs=( ${(0)"$(_wt_git -C "$root" worktree list --porcelain -z 2>/dev/null)"} )
  for p in ${${(M)recs:#worktree *}#worktree }; do paths+=( "${p:A}" ); done
```

and its branch lookup:

```zsh
  local have; have="$(_wt_git -C "$dest" symbolic-ref --quiet --short HEAD 2>/dev/null)"
```

In `dev`, route its one repository lookup through the wrapper too:

```zsh
    repo="$(_wt_git -C "${arg:-$PWD}" rev-parse --show-toplevel 2>/dev/null)" \
      || { print -ru2 -- "dev: '${arg:-$PWD}' is not inside a git repo."; return 1; }
```

Leave `git` calls inside `op-edit` and `tsh` alone — they are not part of the
worktree lifecycle.

Finally, repair the existing stripped-`PATH` fixture in the "missing wtcp" test
(`.scripts/test-wt-functions.sh`, section D). It currently exposes only `git`,
which was sufficient when `wt` shelled out to nothing else. `_wt_git` needs `env`,
and from Task 4 onward `_wt_hook_check` needs `awk`; `_wt_lock` needs `mkdir`.
Without these the test fails for the wrong reason — a missing dependency rather
than the missing `wtcp` it is meant to prove:

```zsh
CLEANP=$(mkd)
# Every external the lifecycle reaches before the wtcp check. wtcp is absent on
# purpose. If a helper later grows a new external dependency, add it here too, or
# this test starts failing for a reason that has nothing to do with wtcp.
for b in env git awk mkdir; do ln -s "$(command -v $b)" "$CLEANP/$b"; done
OUT="$(cd "$REPO" && source "$FUNCS" && export PATH="$CLEANP" && wt g 2>&1)"; RC=$?
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `zsh -n dot_config/zsh/functions && zsh .scripts/test-wt-functions.sh`
Expected: PASS, `failed: 0`, with six new assertions in section G. The repaired
stripped-`PATH` fixture means section D's "missing wtcp aborts" must still pass —
if it now fails, the clean `PATH` is missing a dependency, not the test's fault.

- [ ] **Step 5: Commit**

```bash
git add dot_config/zsh/functions .scripts/test-wt-functions.sh
git commit -m "feat(zsh): add routing-cleared git wrapper and primary-worktree resolution"
```

---

### Task 2: Fail-closed, config-resistant cleanliness helper

**Files:**
- Modify: `dot_config/zsh/functions` (after `_wt_primary`)
- Test: `.scripts/test-wt-functions.sh`

**Interfaces:**
- Consumes: `_wt_git` (Task 1).
- Produces: `_wt_clean <worktree-path>` — exit `0` clean, `1` dirty, `2` state could not be determined. Prints nothing.

- [ ] **Step 1: Write the failing tests**

```zsh
print -r -- "H. _wt_clean"
setup
run "$REPO" wt c1
D="$HOME/Code/Org/repo-c1"
run "$REPO" _wt_clean "$D"
rc_is 0 "clean worktree returns 0"

print -r -- "wip" > "$D/dirty.txt"
run "$REPO" _wt_clean "$D"
rc_is 1 "untracked file returns 1"

# Config must not be able to hide it.
git -C "$D" config status.showUntrackedFiles no
run "$REPO" _wt_clean "$D"
rc_is 1 "status.showUntrackedFiles=no still returns dirty"
git -C "$D" config --unset status.showUntrackedFiles

# An exported GIT_WORK_TREE pointing at a clean decoy must not read as clean.
mkdir -p "$ROOTTMP/decoy-clean"
OUT="$(cd "$REPO" && source "$FUNCS" && GIT_WORK_TREE="$ROOTTMP/decoy-clean" _wt_clean "$D" 2>&1)"; RC=$?
rc_is 1 "exported GIT_WORK_TREE does not make a dirty worktree read clean"

# GIT_INDEX_FILE is a routing variable too. Pin the result to 1 (dirty), not
# merely "nonzero": without the routing clearance git exits 128 on the empty
# alternate index, _wt_clean returns 2 (unknown), and a nonzero-accepting
# assertion would pass on exactly the failure it exists to catch.
: > "$ROOTTMP/empty-index"
OUT="$(cd "$REPO" && source "$FUNCS" && GIT_INDEX_FILE="$ROOTTMP/empty-index" _wt_clean "$D" 2>&1)"; RC=$?
rc_is 1 "exported GIT_INDEX_FILE does not make a dirty worktree read clean"

# Submodule config must not hide a dirty submodule.
setup
git init -q -b main "$ROOTTMP/sub"
git -C "$ROOTTMP/sub" commit -q --allow-empty -m init
git -C "$REPO" -c protocol.file.allow=always submodule add -q "$ROOTTMP/sub" sub 2>/dev/null
git -C "$REPO" commit -q -m addsub
run "$REPO" wt c2
D2="$HOME/Code/Org/repo-c2"
git -C "$D2" -c protocol.file.allow=always submodule update -q --init 2>/dev/null
print -r -- "wip" > "$D2/sub/dirty.txt"
git -C "$D2" config diff.ignoreSubmodules all
run "$REPO" _wt_clean "$D2"
rc_is 1 "diff.ignoreSubmodules=all does not hide a dirty submodule"

# Unreadable state is neither clean nor dirty.
setup
run "$REPO" wt c1
D="$HOME/Code/Org/repo-c1"
print -r -- "garbage" > "$REPO/.git/worktrees/repo-c1/index"
run "$REPO" _wt_clean "$D"
rc_is 2 "corrupt index returns 2 (unknown), not 0"
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `zsh .scripts/test-wt-functions.sh 2>&1 | rg 'H\.' -A8`
Expected: FAIL — `_wt_clean` undefined.

- [ ] **Step 3: Implement**

```zsh
# _wt_clean <worktree> — 0 clean, 1 dirty, 2 state unknown.
#
# Three-state on purpose. A failed `git status` (corrupt index, unreadable
# worktree) produces empty output, so testing output alone reads the case where
# we know least as "no changes" — the most dangerous possible misreading.
#
# Each flag closes a way a dirty tree can report clean:
#   --untracked-files=normal   defeats status.showUntrackedFiles=no
#   --ignore-submodules=none   defeats diff.ignoreSubmodules / submodule.*.ignore
#   --porcelain=v1             pins the format against a default change
# and _wt_git clears GIT_WORK_TREE/GIT_DIR, which otherwise redirect the check to
# a different checkout entirely and return empty output with exit status 0.
#
# The assignment is deliberately split from `local`: `local x="$(cmd)"` reports
# the *builtin's* status, not the command substitution's, hiding the failure this
# helper exists to catch.
_wt_clean() {
  emulate -L zsh
  local wt="$1" out rc
  out="$(_wt_git -C "$wt" status --porcelain=v1 --untracked-files=normal \
                 --ignore-submodules=none 2>/dev/null)"; rc=$?
  (( rc )) && return 2
  [[ -n "$out" ]] && return 1
  return 0
}
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `zsh -n dot_config/zsh/functions && zsh .scripts/test-wt-functions.sh`
Expected: PASS, `failed: 0`.

- [ ] **Step 5: Commit**

```bash
git add dot_config/zsh/functions .scripts/test-wt-functions.sh
git commit -m "feat(zsh): add fail-closed cleanliness helper"
```

---

### Task 3: Per-target lock

**Files:**
- Modify: `dot_config/zsh/functions` (after `_wt_clean`)
- Test: `.scripts/test-wt-functions.sh`

**Interfaces:**
- Consumes: nothing.
- Produces:
  - `_wt_lock <common-dir> <slug>` — exit 0 on acquire, 1 on contention or unavailable module. Sets global `_WT_LOCK_FD`.
  - `_wt_unlock` — releases `_WT_LOCK_FD` if set; always exit 0.

- [ ] **Step 1: Write the failing tests**

```zsh
print -r -- "I. locking"
setup
CD="$REPO/.git"
run "$REPO" _wt_lock "$CD" slug1
rc_is 0 "lock acquires"
[[ -f "$REPO/.git/wt-locks/slug1.lock" ]] && _pass "lock file is created" || _fail "lock file is created"

# Held by another process -> refused.
OUT="$(cd "$REPO" && source "$FUNCS" && _wt_lock "$CD" slug2 && \
        zsh -c "source '$FUNCS'; _wt_lock '$CD' slug2" 2>&1)"; RC=$?
has "another lifecycle command" "a lock held by another process is refused"

# Persistent-shell release: acquire and unlock in ONE shell, then have a SEPARATE
# process acquire. This is the regression test for the explicit-unlock rule —
# without `zsystem flock -u` the fd stays open here and the child is refused.
# It must cross a process boundary: fcntl locks are per-process, so a same-shell
# reacquisition succeeds whether or not the first was ever released.
OUT="$(cd "$REPO" && source "$FUNCS" && _wt_lock "$CD" slug3 && _wt_unlock && \
        zsh -c "source '$FUNCS'; _wt_lock '$CD' slug3 && print RELEASED")"
eq "$OUT" "RELEASED" "explicit unlock releases the lock for other processes"

# A holder killed with SIGKILL leaves nothing behind: the kernel releases it.
zsh -c "source '$FUNCS'; _wt_lock '$CD' slug5 && kill -9 \$\$" 2>/dev/null
OUT="$(cd "$REPO" && source "$FUNCS" && _wt_lock "$CD" slug5 && print OK)"; RC=$?
eq "$OUT" "OK" "a SIGKILLed holder's lock is acquirable with no manual cleanup"

# Module missing -> refuse rather than run unlocked.
OUT="$(cd "$REPO" && source "$FUNCS" && \
        zmodload() { return 1 } && _wt_lock "$CD" slug4 2>&1)"; RC=$?
rc_is 1 "missing zsh/system refuses instead of running unlocked"
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `zsh .scripts/test-wt-functions.sh 2>&1 | rg 'I\.' -A8`
Expected: FAIL — `_wt_lock` undefined.

- [ ] **Step 3: Implement**

```zsh
# _wt_lock <common-dir> <slug> / _wt_unlock — serialize lifecycle commands per
# target worktree, so `wt-prepare` cannot copy into a directory `wt-rm` is
# removing.
#
# `zsystem flock` is an fcntl(2) record lock despite the name, and its semantics
# drive three requirements:
#
#   1. The lock file must already exist — zsystem opens it and will not create it.
#   2. Release must be explicit. These are *sourced functions*: returning does not
#      close the descriptor, so without an unlock the fd stays open in the
#      interactive shell and every later run against that target refuses for the
#      rest of the session. Kernel release on process death is only a backstop.
#   3. Locks are per-process, not per-descriptor. A nested acquisition inside the
#      same shell SUCCEEDS, and unlocking any one descriptor drops the process's
#      lock on the file entirely — so a routine that took its own lock would
#      silently release its caller's. Only the outermost command locks; see the
#      command/routine split in wt-prepare.
#
# Consequently there is no intra-process exclusion. That is fine: one shell runs
# one lifecycle command at a time, and the case being defended is concurrent
# commands in different terminals.
_wt_lock() {
  emulate -L zsh
  zmodload zsh/system 2>/dev/null || {
    print -ru2 -- "wt: zsh/system unavailable — refusing to run unlocked."; return 1 }
  local dir="$1/wt-locks" lf="$1/wt-locks/$2.lock"
  mkdir -p "$dir" && : >> "$lf" || {
    print -ru2 -- "wt: cannot create lock file $lf."; return 1 }
  # _WT_LOCK_FD is intentionally global: the caller unlocks it.
  if ! zsystem flock -t 0 -f _WT_LOCK_FD "$lf" 2>/dev/null; then
    print -ru2 -- "wt: another lifecycle command is working on '$2' — retry when it finishes."
    return 1
  fi
}

_wt_unlock() {
  emulate -L zsh
  [[ -n "${_WT_LOCK_FD:-}" ]] || return 0
  zsystem flock -u $_WT_LOCK_FD 2>/dev/null
  unset _WT_LOCK_FD
  return 0
}
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `zsh -n dot_config/zsh/functions && zsh .scripts/test-wt-functions.sh`
Expected: PASS, `failed: 0`.

- [ ] **Step 5: Commit**

```bash
git add dot_config/zsh/functions .scripts/test-wt-functions.sh
git commit -m "feat(zsh): add per-target lifecycle lock"
```

---

### Task 4: Hook validation

**Files:**
- Modify: `dot_config/zsh/functions` (after `_wt_unlock`)
- Test: `.scripts/test-wt-functions.sh`

**Interfaces:**
- Consumes: `_wt_git` (Task 1).
- Produces: `_wt_hook_check <main>` — exit `0` valid hook present, `1` invalid (message on stderr), `2` absent (repository has not opted in).

- [ ] **Step 1: Write the failing tests**

```zsh
print -r -- "J. hook validation"
mkhook() {   # mkhook <repo> <body>  — tracked, executable, committed
  print -r -- "$2" > "$1/.worktreehook"
  chmod +x "$1/.worktreehook"
  git -C "$1" add --chmod=+x .worktreehook >/dev/null
  git -C "$1" commit -q -m hook
}

setup
run "$REPO" _wt_hook_check "$REPO"
rc_is 2 "absent hook reports not-opted-in"

setup
mkhook "$REPO" '#!/bin/sh
exit 0'
run "$REPO" _wt_hook_check "$REPO"
rc_is 0 "tracked 100755 regular executable is valid"

setup
print -r -- '#!/bin/sh' > "$REPO/.worktreehook"; chmod +x "$REPO/.worktreehook"
run "$REPO" _wt_hook_check "$REPO"
rc_is 1 "untracked hook is refused"

setup
print -r -- '#!/bin/sh' > "$REPO/.worktreehook"
git -C "$REPO" add .worktreehook >/dev/null; git -C "$REPO" commit -q -m h
run "$REPO" _wt_hook_check "$REPO"
rc_is 1 "100644 hook is refused"
has "chmod=+x" "100644 refusal gives the repair command"

setup
ln -s /bin/echo "$REPO/.worktreehook"
git -C "$REPO" add .worktreehook >/dev/null; git -C "$REPO" commit -q -m h
run "$REPO" _wt_hook_check "$REPO"
rc_is 1 "tracked symlink hook is refused"

setup
mkhook "$REPO" '#!/bin/sh
exit 0'
rm "$REPO/.worktreehook"; ln -s /bin/echo "$REPO/.worktreehook"
run "$REPO" _wt_hook_check "$REPO"
rc_is 1 "index-100755 replaced locally by a symlink is refused"

setup
mkhook "$REPO" '#!/bin/sh
exit 0'
chmod -x "$REPO/.worktreehook"
run "$REPO" _wt_hook_check "$REPO"
rc_is 1 "index-100755 without the working-tree exec bit is refused"

# Selecting stage 0 specifically is what rejects a conflicted hook, which has
# no stage-0 entry. Construct a real merge conflict rather than staging by
# hand, so the fixture depends on Git's own conflict semantics, not on this
# test's assumptions about them.
setup
mkhook "$REPO" '#!/bin/sh
exit 0'
git -C "$REPO" checkout -q -b feature
print -r -- '#!/bin/sh
exit 1' > "$REPO/.worktreehook"
git -C "$REPO" commit -q -am "feature change"
git -C "$REPO" checkout -q main
print -r -- '#!/bin/sh
exit 2' > "$REPO/.worktreehook"
git -C "$REPO" commit -q -am "main change"
git -C "$REPO" merge --no-edit feature >/dev/null 2>&1
run "$REPO" _wt_hook_check "$REPO"
rc_is 1 "conflicted hook (no stage-0 entry) is refused"
has "unresolved conflict" "conflicted-hook refusal names the conflict"
# Guard the guard: if Git ever stopped leaving this path with no stage-0 entry
# during a conflict, the assertions above would start testing nothing. Fail
# loudly instead of silently validating an already-resolved file.
STAGE0="$(git -C "$REPO" ls-files --stage -- .worktreehook | awk '$3 == 0 { print $1 }')"
eq "$STAGE0" "" "fixture genuinely leaves .worktreehook with no stage-0 entry"

# Fails CLOSED when the index cannot be read — two variants, because no single
# fixture proves both halves at once.
#
# Variant 1: the hook is absent from the working tree too. Without the `rc`
# gate, ls-files's failure leaves `raw` empty with nothing on disk to fall
# back on, so the function would misread this as "not opted in" (2) instead
# of refusing. This is the fixture where `rc_is 1` alone is meaningful:
# removing the gate flips this exact assertion.
setup
print -r -- "garbage" > "$REPO/.git/index"
run "$REPO" _wt_hook_check "$REPO"
rc_is 1 "unreadable index with no on-disk hook is refused, not read as not-opted-in"
has "cannot read the index" "the refusal says the index state is unknown"

# Variant 2: the hook is tracked, committed, and still present on disk when
# the index is corrupted. Here `rc_is 1` cannot discriminate on its own —
# without the gate the function still returns 1, just via the "untracked"
# fallback path, because the on-disk file survives the index corruption. What
# this fixture proves is the *message*: only the gate produces "cannot read
# the index"; the fallback path names the wrong reason.
setup
mkhook "$REPO" '#!/bin/sh
exit 0'
print -r -- "garbage" > "$REPO/.git/index"
run "$REPO" _wt_hook_check "$REPO"
rc_is 1 "unreadable index with a tracked hook on disk is still refused"
has "cannot read the index" "the refusal names the index as the reason, not 'untracked'"
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `zsh .scripts/test-wt-functions.sh 2>&1 | rg 'J\.' -A12`
Expected: FAIL — `_wt_hook_check` undefined.

- [ ] **Step 3: Implement**

```zsh
# _wt_hook_check <main> — 0 valid, 1 invalid, 2 absent (not opted in).
#
# Both the index entry and the working-tree path must be checked. A tracked
# symlink satisfies "tracked" and "executable" (test -x follows it) while the code
# that actually runs lives outside the repository; conversely the index mode alone
# cannot see an unstaged local swap.
#
# Requiring 100755 *in the index* — not merely on disk — makes opt-in
# reproducible: a hook tracked as 100644 arrives non-executable in every clone.
# Selecting stage 0 rejects a conflicted hook, which has no stage-0 entry.
_wt_hook_check() {
  emulate -L zsh
  local main="$1" hook="$1/.worktreehook" raw mode rc
  # Status captured separately, for the same reason as _wt_clean: a failed
  # ls-files also leaves `raw` empty, and falling through on that emptiness
  # would misread an unreadable index by whatever happens to be on disk —
  # "not opted in" (2) when no working-tree file exists, or a bogus "untracked"
  # refusal (1, wrong message) when one does. Either way the true index state
  # is unknown, so it is refused unconditionally, before `raw` is inspected.
  raw="$(_wt_git -C "$main" ls-files --stage -- .worktreehook 2>/dev/null)"; rc=$?
  if (( rc )); then
    print -ru2 -- "wt: cannot read the index of $main to validate .worktreehook — refusing."
    return 1
  fi
  mode="$(print -r -- "$raw" | awk '$3 == 0 { print $1 }')"

  if [[ -z "$raw" ]]; then
    [[ -e "$hook" || -L "$hook" ]] || return 2          # not opted in
    print -ru2 -- "wt: $hook exists but is not tracked — commit it or remove it."
    return 1
  fi
  if [[ -z "$mode" ]]; then
    print -ru2 -- "wt: .worktreehook has no stage-0 index entry (unresolved conflict) — resolve it first."
    return 1
  fi
  if [[ "$mode" != 100755 ]]; then
    print -ru2 -- "wt: .worktreehook is indexed as $mode, not 100755."
    [[ "$mode" == 100644 ]] && \
      print -ru2 -- "    Fix with: git add --chmod=+x .worktreehook"
    return 1
  fi
  if [[ -L "$hook" ]]; then
    print -ru2 -- "wt: .worktreehook is a symlink in the working tree — refusing."
    return 1
  fi
  [[ -f "$hook" ]] || { print -ru2 -- "wt: .worktreehook is not a regular file."; return 1 }
  [[ -x "$hook" ]] || { print -ru2 -- "wt: .worktreehook is not executable."; return 1 }
  return 0
}
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `zsh -n dot_config/zsh/functions && zsh .scripts/test-wt-functions.sh`
Expected: PASS, `failed: 0`.

- [ ] **Step 5: Commit**

```bash
git add dot_config/zsh/functions .scripts/test-wt-functions.sh
git commit -m "feat(zsh): validate .worktreehook index entry and working-tree path"
```

---

### Task 5: Hook execution

**Files:**
- Modify: `dot_config/zsh/functions` (after `_wt_hook_check`)
- Test: `.scripts/test-wt-functions.sh`

**Interfaces:**
- Consumes: `_wt_hook_check` (Task 4).
- Produces: `_wt_hook_run <main> <worktree> <branch> <slug> <verb>` — exit `0` on success or when no hook is present, `1` on invalid configuration or nonzero hook exit. Re-validates immediately before executing.

- [ ] **Step 1: Write the failing tests**

```zsh
print -r -- "K. hook execution"
setup
mkhook "$REPO" '#!/bin/sh
printf "%s|%s|%s|%s|%s|%s\n" "$1" "$(pwd)" "$WT_MAIN" "$WT_WORKTREE" "$WT_BRANCH" "$WT_SLUG" > "$WT_MAIN/hook.out"
read line || line="(no stdin)"
printf "stdin=%s\n" "$line" >> "$WT_MAIN/hook.out"
echo "to-stdout"; echo "to-stderr" >&2
exit 0'
run "$REPO" wt k1
OUT="$(cd "$REPO" && source "$FUNCS" && \
  print -r -- "fed" | _wt_hook_run "$REPO" "$HOME/Code/Org/repo-k1" "k1" "k1" setup 2>&1)"; RC=$?
rc_is 0 "successful hook returns 0"
has "to-stdout" "hook stdout reaches the caller"
has "to-stderr" "hook stderr reaches the caller"
REC="$(<"$REPO/hook.out")"
[[ "$REC" == "setup|$HOME/Code/Org/repo-k1|$REPO|$HOME/Code/Org/repo-k1|k1|k1"* ]] \
  && _pass "verb, cwd and WT_* are correct" || _fail "verb, cwd and WT_* are correct"
# The cwd check above proves `cd "$wt"` landed in the right place; it does not by
# itself prove WT_WORKTREE holds the right value — a bug that set WT_WORKTREE
# wrong while cd still worked would pass it undetected. Isolate the field and
# compare it exactly, independent of the cwd check.
FIELDS=( "${(@s:|:)${REC%%$'\n'*}}" )
eq "${FIELDS[4]}" "$HOME/Code/Org/repo-k1" "WT_WORKTREE holds the correct absolute worktree path"
[[ "$REC" == *"stdin=fed"* ]] && _pass "stdin is inherited" || _fail "stdin is inherited"

setup
mkhook "$REPO" '#!/bin/sh
exit 3'
run "$REPO" wt k2
run "$REPO" _wt_hook_run "$REPO" "$HOME/Code/Org/repo-k2" k2 k2 setup
rc_is 1 "hook exit 3 is normalized to 1"
has "exited 3" "the hook's real exit status is reported, not returned"

setup
run "$REPO" wt k3
run "$REPO" _wt_hook_run "$REPO" "$HOME/Code/Org/repo-k3" k3 k3 setup
rc_is 0 "absent hook is a successful no-op"

# The hook runs inside a subshell: a variable it sets must not leak into the
# caller. This proves subshell isolation — it does NOT by itself prove the hook
# is executed rather than sourced, since sourcing *inside* the same subshell
# would isolate LEAKED identically. See the shebang-honoring assertion below
# for the property that actually distinguishes execution from sourcing.
setup
mkhook "$REPO" '#!/bin/sh
LEAKED=yes
exit 0'
run "$REPO" wt k4
OUT="$(cd "$REPO" && source "$FUNCS" && \
  _wt_hook_run "$REPO" "$HOME/Code/Org/repo-k4" k4 k4 setup >/dev/null 2>&1; print -r -- "${LEAKED:-unset}")"
eq "$OUT" "unset" "hook's variables don't leak into the caller (subshell isolation)"

# The hook must be executed as a process, never sourced, so its own shebang
# selects the interpreter — the property spec §11.1 requires ("Shebang:
# honored; hook is not sourced"), and what makes the protocol stack-agnostic
# (a project's hook can be Python, .NET, anything with a shebang). A hook
# body zsh cannot parse is the only fixture that can tell "executed" and
# "sourced inside the isolating subshell" apart: `source` hands zsh's own
# parser this file, so non-zsh syntax either errors out or is silently
# misparsed, and the marker is never written; `exec` hands it to python3,
# which writes the marker normally.
if command -v python3 >/dev/null 2>&1; then
  setup
  mkhook "$REPO" '#!/usr/bin/env python3
open("py.marker", "w").close()'
  run "$REPO" wt k5
  run "$REPO" _wt_hook_run "$REPO" "$HOME/Code/Org/repo-k5" k5 k5 setup
  [[ -f "$HOME/Code/Org/repo-k5/py.marker" ]] \
    && _pass "shebang is honored: a python3 hook runs, it is not parsed as zsh" \
    || _fail "shebang is honored: a python3 hook runs, it is not parsed as zsh"
else
  print -r -- "  SKIP: shebang-honored assertion — python3 not found on PATH (not counted as pass or fail)"
fi

# The operative gate: `_wt_hook_run` re-validates immediately before executing,
# not merely at some earlier pre-flight (see the comment above its definition).
# Nothing above feeds it an invalid hook, so that re-validation is unproven on
# `_wt_hook_run` itself — a `case` arm swap that let an invalid result fall
# through to execution would go undetected by rc_is alone if the hook's exit
# code still happened to be nonzero. The marker-absence check is what actually
# proves the hook was never reached: `rc_is 1` alone is satisfied even by a bug
# that executes the hook and then returns 1 regardless.
#
# The invalid fixture must be executable on disk: a hook the kernel itself
# refuses to exec (e.g. missing the working-tree +x bit) would leave the marker
# absent even with the gate removed, proving nothing about the gate itself.
# Untracked-but-executable is invalid (section J) yet the kernel would happily
# run it, so only the gate stands between it and execution.
setup
print -r -- '#!/bin/sh
: > "$WT_MAIN/should-not-run.marker"
exit 0' > "$REPO/.worktreehook"
chmod +x "$REPO/.worktreehook"          # executable on disk, but untracked: invalid
run "$REPO" wt k6
run "$REPO" _wt_hook_run "$REPO" "$HOME/Code/Org/repo-k6" k6 k6 setup
rc_is 1 "invalid hook (untracked, though executable on disk) is refused"
[[ -f "$REPO/should-not-run.marker" ]] \
  && _fail "the operative gate blocks execution, not just the return code" \
  || _pass "the operative gate blocks execution, not just the return code"
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `zsh .scripts/test-wt-functions.sh 2>&1 | rg 'K\.' -A10`
Expected: FAIL — `_wt_hook_run` undefined.

- [ ] **Step 3: Implement**

```zsh
# _wt_hook_run <main> <worktree> <branch> <slug> <verb> — run the project hook.
#
# Validation happens here, immediately before execution, not only at the earlier
# pre-flight. Validation checks a pathname while execution happens later, so the
# early check in `wt` is a usability guard that avoids creating a worktree for a
# misconfigured repository — it does not substitute for this one. Concurrent
# mutation of the primary hook during a command remains unsupported (see the spec,
# §5.1 "Validation is point-in-time").
#
# Executed as a process so its shebang picks the interpreter, in a subshell so cwd
# and WT_* never leak back into the caller.
_wt_hook_run() {
  emulate -L zsh
  local main="$1" wt="$2" branch="$3" slug="$4" verb="$5"
  _wt_hook_check "$main"
  case $? in
    2) return 0 ;;   # repository has not opted in
    1) return 1 ;;
  esac
  ( cd "$wt" \
    && WT_MAIN="$main" WT_WORKTREE="$wt" WT_BRANCH="$branch" WT_SLUG="$slug" \
       "$main/.worktreehook" "$verb" )
  local hrc=$?
  (( hrc == 0 )) && return 0
  # Normalized to 1: the documented interface is 0/1, and callers branch on
  # success or failure only. The hook's own status is surfaced in the message
  # rather than returned, so `exit 130` and `exit 3` are handled identically.
  print -ru2 -- "wt: .worktreehook $verb exited $hrc."
  return 1
}
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `zsh -n dot_config/zsh/functions && zsh .scripts/test-wt-functions.sh`
Expected: PASS, `failed: 0`.

- [ ] **Step 5: Commit**

```bash
git add dot_config/zsh/functions .scripts/test-wt-functions.sh
git commit -m "feat(zsh): execute .worktreehook with the WT_* interface"
```

---

### Task 6: Manifest validation and destination filtering

**Files:**
- Modify: `dot_config/zsh/functions` (after `_wt_hook_run`)
- Test: `.scripts/test-wt-functions.sh`

**Interfaces:**
- Consumes: nothing.
- Produces: `_wt_manifest <main> <dest>` — exit `0` on success (fills global array `_WT_CARRY` with entries still needing a copy), `1` on an unsafe entry. Warns on stderr for listed-but-missing sources and continues.

- [ ] **Step 1: Write the failing tests**

```zsh
print -r -- "L. manifest validation"
setup
run "$REPO" wt m1
D="$HOME/Code/Org/repo-m1"
print -r -- "a.env" > "$REPO/.worktreeinclude"; print -r -- "A" > "$REPO/a.env"
OUT="$(cd "$REPO" && source "$FUNCS" && _wt_manifest "$REPO" "$D" && print -r -- "${_WT_CARRY[*]}")"
eq "$OUT" "a.env" "a missing destination is carried"

print -r -- "A" > "$D/a.env"
OUT="$(cd "$REPO" && source "$FUNCS" && _wt_manifest "$REPO" "$D" && print -r -- "${#_WT_CARRY[@]}")"
eq "$OUT" "0" "an existing destination is filtered out"

for bad in "/etc/passwd" "~/x" "../outside" "a/../../b"; do
  print -r -- "$bad" > "$REPO/.worktreeinclude"
  run "$REPO" _wt_manifest "$REPO" "$D"
  rc_is 1 "unsafe entry '$bad' is refused"
done

# Symlinked SOURCE parent.
setup
run "$REPO" wt m2; D="$HOME/Code/Org/repo-m2"
mkdir -p "$ROOTTMP/outside"; print -r -- "S" > "$ROOTTMP/outside/s.env"
ln -s "$ROOTTMP/outside" "$REPO/linked"
print -r -- "linked/s.env" > "$REPO/.worktreeinclude"
run "$REPO" _wt_manifest "$REPO" "$D"
rc_is 1 "symlinked source parent is refused"

# Symlinked FINAL source component: dereferenced on read, so it escapes too.
setup
run "$REPO" wt m3; D="$HOME/Code/Org/repo-m3"
mkdir -p "$ROOTTMP/outdir"; print -r -- "X" > "$ROOTTMP/outdir/x"
ln -s "$ROOTTMP/outdir" "$REPO/final"
print -r -- "final" > "$REPO/.worktreeinclude"
run "$REPO" _wt_manifest "$REPO" "$D"
rc_is 1 "symlinked final source component is refused"

# Symlinked DESTINATION parent.
setup
run "$REPO" wt m4; D="$HOME/Code/Org/repo-m4"
mkdir -p "$ROOTTMP/dst"; mkdir -p "$REPO/cfg"; print -r -- "C" > "$REPO/cfg/c.env"
ln -s "$ROOTTMP/dst" "$D/cfg"
print -r -- "cfg/c.env" > "$REPO/.worktreeinclude"
run "$REPO" _wt_manifest "$REPO" "$D"
rc_is 1 "symlinked destination parent is refused"

# A final DESTINATION symlink is allowed — but only because it is filtered out as
# already-present, never followed and never written through.
setup
run "$REPO" wt m6; D="$HOME/Code/Org/repo-m6"
mkdir -p "$ROOTTMP/elsewhere"; print -r -- "UNTOUCHED" > "$ROOTTMP/elsewhere/t.env"
print -r -- "SOURCE" > "$REPO/t.env"
ln -s "$ROOTTMP/elsewhere/t.env" "$D/t.env"
print -r -- "t.env" > "$REPO/.worktreeinclude"
OUT="$(cd "$REPO" && source "$FUNCS" && _wt_manifest "$REPO" "$D" && print -r -- "${#_WT_CARRY[@]}")"
eq "$OUT" "0" "an existing final destination symlink is filtered, not carried"
# No separate write-through assertion: the property is pinned entirely by
# _WT_CARRY being empty above. _wt_manifest performs no writes under any code
# path, so a direct "the target file is unchanged" check would pass whether
# filtering works, is broken, or the function doesn't exist at all — it was
# tried and proven vacuous. An end-to-end version (through wtcp) wouldn't
# discriminate either: wtcp refuses an existing destination (a symlink counts
# as existing) and returns nonzero before writing anything, so a broken filter
# would surface as a nonzero wt-prepare, never as a modified external file.

# Missing source warns and continues.
setup
run "$REPO" wt m5; D="$HOME/Code/Org/repo-m5"
printf 'gone.env\nthere.env\n' > "$REPO/.worktreeinclude"; print -r -- "T" > "$REPO/there.env"
OUT="$(cd "$REPO" && source "$FUNCS" && _wt_manifest "$REPO" "$D" 2>&1 && print -r -- "carry=${_WT_CARRY[*]}")"
has "gone.env" "missing source is reported"
has "carry=there.env" "the remaining entry is still carried"
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `zsh .scripts/test-wt-functions.sh 2>&1 | rg 'L\.' -A16`
Expected: FAIL — `_wt_manifest` undefined.

- [ ] **Step 3: Implement**

```zsh
# _wt_manifest <main> <dest> — validate .worktreeinclude and fill _WT_CARRY with
# the entries whose destination is still missing.
#
# Filtering is required for correctness, not tidiness: wtcp refuses existing
# destinations and returns NONZERO while still copying the missing ones, so
# passing the whole manifest on a retry fails every second run by construction.
#
# Containment is checked lexically *and* through the filesystem. A path with no
# ".." still escapes if a directory component is a symlink — the target worktree's
# tree comes from the feature branch, so a branch committing `config` as a symlink
# redirects `config/master.key` on write. The rule is asymmetric:
#
#   source:      no component may be a symlink, INCLUDING the final one. A final
#                source symlink is dereferenced on read, so pointing it at an
#                external directory copies that directory's contents in.
#   destination: no PARENT component may be a symlink. An existing final symlink
#                is fine precisely because it is filtered out below as "already
#                present" — skipped, never followed, never written through.
_wt_manifest() {
  emulate -L zsh
  setopt local_options extended_glob
  local main="$1" dest="$2" line p comp
  local -a parts
  _WT_CARRY=()
  [[ -f "$main/.worktreeinclude" ]] || return 0

  # `|| [[ -n "$line" ]]` so a final line with no trailing newline still counts.
  while IFS= read -r line || [[ -n "$line" ]]; do
    line="${${line##[[:space:]]##}%%[[:space:]]##}"
    [[ -z "$line" || "$line" == '#'* ]] && continue

    if [[ "$line" == /* || "$line" == '~'* ]]; then
      print -ru2 -- "wt: .worktreeinclude entry '$line' is not repo-relative — refusing."
      return 1
    fi
    parts=( ${(s:/:)line} )
    if (( ${parts[(I)..]} )); then
      print -ru2 -- "wt: .worktreeinclude entry '$line' contains '..' — refusing."
      return 1
    fi

    if [[ ! -e "$main/$line" && ! -L "$main/$line" ]]; then
      print -ru2 -- "wt: .worktreeinclude lists '$line', not found in $main — skipping."
      continue
    fi

    p="$main"
    for comp in $parts; do
      p="$p/$comp"
      if [[ -L "$p" ]]; then
        print -ru2 -- "wt: .worktreeinclude entry '$line' resolves through a symlink in $main — refusing."
        return 1
      fi
    done

    p="$dest"
    for comp in ${parts[1,-2]}; do
      p="$p/$comp"
      if [[ -L "$p" ]]; then
        print -ru2 -- "wt: .worktreeinclude entry '$line' resolves through a symlink in $dest — refusing."
        return 1
      fi
    done

    [[ -e "$dest/$line" || -L "$dest/$line" ]] && continue   # already present: done
    _WT_CARRY+=( "$line" )
  done < "$main/.worktreeinclude"
  return 0
}
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `zsh -n dot_config/zsh/functions && zsh .scripts/test-wt-functions.sh`
Expected: PASS, `failed: 0`.

- [ ] **Step 5: Commit**

```bash
git add dot_config/zsh/functions .scripts/test-wt-functions.sh
git commit -m "feat(zsh): validate .worktreeinclude containment and filter destinations"
```

---

### Task 7: Preparation routine and `wt-prepare`

**Files:**
- Modify: `dot_config/zsh/functions` (add `_wt_do_prepare` and `wt-prepare` after `_wt_manifest`). `wt`'s existing inline copy block is **left untouched here** and removed in Task 8; see Step 4.
- Test: `.scripts/test-wt-functions.sh` (replace the `wtcp` stub, then add section M)

**Interfaces:**
- Consumes: `_wt_assert_worktree`, `_wt_hook_check`, `_wt_hook_run`, `_wt_manifest`, `_wt_lock`, `_wt_unlock`. Tests also use the `mkhook <repo> <body>` fixture helper defined in Task 4's test section (tracked, executable, committed) — if implementing out of order, add it first.
- Produces:
  - `_wt_do_prepare <main> <dest> <branch> <slug>` — the unlocked routine. Exit 0 on success, 1 on failure. **Never locks.**
  - `wt-prepare <branch>` — the locked public command wrapping it.

- [ ] **Step 1: Replace the `wtcp` stub with a faithful one**

The committed stub only logs and exits, so any assertion that a file was actually
copied passes or fails for the wrong reason, and an `--`-handling test is vacuous.
Replace it in `.scripts/test-wt-functions.sh`:

```bash
cat > "$STUBS/wtcp" <<'STUB'
#!/usr/bin/env bash
# Faithful enough for the properties the protocol depends on: honors --from,
# treats `--` as end-of-options (so an entry named -h is copied rather than
# parsed), refuses an existing destination with a NONZERO exit while still
# copying the missing ones — the behaviour that makes destination filtering a
# correctness requirement — and can still be forced to fail via MOCK_WTCP_RC.
printf '%s\n' "$*" >> "$WLOG"
[ "${MOCK_WTCP_RC:-0}" -ne 0 ] && exit "$MOCK_WTCP_RC"
from="."; rc=0; endopts=0; paths=()
while [ $# -gt 0 ]; do
  if [ "$endopts" -eq 0 ]; then
    case "$1" in
      --from) from="$2"; shift 2; continue ;;
      --)     endopts=1; shift; continue ;;
      -h|--help) echo "wtcp: usage"; exit 1 ;;
      -*)     echo "wtcp: unknown option $1" >&2; exit 1 ;;
    esac
  fi
  paths+=("$1"); shift
done
for p in "${paths[@]}"; do
  if [ -e "$PWD/$p" ]; then
    echo "wtcp: destination exists (use --force): $p" >&2; rc=1; continue
  fi
  mkdir -p "$(dirname "$PWD/$p")"
  cp -R "$from/$p" "$PWD/$p" && echo "copied: $p"
done
exit $rc
STUB
chmod +x "$STUBS/wtcp"
```

Run the suite now: the pre-existing assertions must still pass against the
faithful stub before any new behaviour is added — `failed: 0`.

Run: `zsh .scripts/test-wt-functions.sh`
Expected: PASS, `failed: 0`.

- [ ] **Step 2: Write the failing tests**

```zsh
print -r -- "M. wt-prepare"
setup
run "$REPO" wt-prepare nope
rc_is 1 "absent target is refused"
has "does not exist" "absent target error is specific"

setup
run "$REPO" wt n1
print -r -- "a.env" > "$REPO/.worktreeinclude"; print -r -- "A" > "$REPO/a.env"
: > "$ZLOG"
run "$REPO" wt-prepare n1
rc_is 0 "prepare succeeds"
[[ -f "$HOME/Code/Org/repo-n1/a.env" ]] && _pass "missing file is copied" || _fail "missing file is copied"
# Assert the log is EMPTY. `unlogged "zellij"` would be vacuous: the stub logs its
# arguments, which never contain the word "zellij".
[[ -s "$ZLOG" ]] && _fail "prepare makes no Zellij calls" || _pass "prepare makes no Zellij calls"

print -r -- "LOCAL" > "$HOME/Code/Org/repo-n1/a.env"
run "$REPO" wt-prepare n1
rc_is 0 "repeat prepare succeeds"
eq "$(<"$HOME/Code/Org/repo-n1/a.env")" "LOCAL" "existing destination is left byte-identical"

# An entry named -h must be copied, not parsed as an option.
setup
run "$REPO" wt n2
print -r -- "-h" > "$REPO/.worktreeinclude"; print -r -- "DASH" > "$REPO/-h"
run "$REPO" wt-prepare n2
rc_is 0 "an entry named -h is copied, not parsed as an option"
eq "$(<"$HOME/Code/Org/repo-n2/-h")" "DASH" "the -h entry's contents actually arrived"

# wtcp failure aborts before setup.
setup
run "$REPO" wt n3
print -r -- "a.env" > "$REPO/.worktreeinclude"; print -r -- "A" > "$REPO/a.env"
mkhook "$REPO" '#!/bin/sh
touch "$WT_MAIN/setup-ran"; exit 0'
MOCK_WTCP_RC=1 run "$REPO" wt-prepare n3
rc_is 1 "wtcp failure fails prepare"
[[ -f "$REPO/setup-ran" ]] && _fail "setup is skipped after a copy failure" || _pass "setup is skipped after a copy failure"

# Setup failure is reported with both recovery steps, branch name quoted.
setup
run "$REPO" 'wt' 'x&y'
mkhook "$REPO" '#!/bin/sh
exit 7'
run "$REPO" wt-prepare 'x&y'
rc_is 1 "setup failure fails prepare"
has "wt-prepare 'x&y'" "recovery message quotes a hostile branch name"
has "wt 'x&y'" "recovery message includes the reopening step"

# The hook-invalid bail-out must actually block copying, not just return
# nonzero: section J already proves _wt_hook_check rejects an untracked-but-
# executable hook; this proves _wt_do_prepare acts on that rejection instead
# of copying first, so a misconfigured repository changes nothing. Untracked-
# but-executable, not chmod -x: a non-executable hook would be refused by the
# kernel regardless, which would mask whether the software gate did the work
# — the same trap called out in section K's operative-gate comment.
setup
run "$REPO" wt n4
print -r -- "a.env" > "$REPO/.worktreeinclude"; print -r -- "A" > "$REPO/a.env"
print -r -- '#!/bin/sh
exit 0' > "$REPO/.worktreehook"
chmod +x "$REPO/.worktreehook"          # executable on disk, but untracked: invalid
run "$REPO" wt-prepare n4
rc_is 1 "invalid hook aborts prepare before copying"
[[ -f "$HOME/Code/Org/repo-n4/a.env" ]] \
  && _fail "manifest file is not copied when the hook is invalid" \
  || _pass "manifest file is not copied when the hook is invalid"
has "wt-prepare n4 && wt n4" "recovery message names both steps"

# The wtcp-presence guard (`if (( ${#_WT_CARRY} ))`) is scoped to when a copy
# is actually needed: a repository whose destinations are already fully
# populated must not require wtcp to be installed. Discriminating: with that
# guard removed, the presence check fires unconditionally and this fails
# even though nothing needs copying. Stripped PATH, not a moved stub — wtcp
# is really installed on this machine, so hiding the stub just falls through
# to the real binary (same rationale as section D's CLEANP).
setup
run "$REPO" wt n5
print -r -- "a.env" > "$REPO/.worktreeinclude"; print -r -- "A" > "$REPO/a.env"
print -r -- "A" > "$HOME/Code/Org/repo-n5/a.env"   # already present at the destination
CLEANP=$(mkd)
# Every external the lifecycle reaches before the wtcp check. wtcp is absent
# on purpose. If a helper later grows a new external dependency, add it here
# too, or this test starts failing for a reason that has nothing to do with
# wtcp.
for b in env git awk mkdir; do ln -s "$(command -v $b)" "$CLEANP/$b"; done
OUT="$(cd "$REPO" && source "$FUNCS" && export PATH="$CLEANP" && wt-prepare n5 2>&1)"; RC=$?
rc_is 0 "already-populated destinations don't require wtcp"

# Mirrors section D's coverage of a missing wtcp during copy, for
# wt-prepare's own path (D only exercises this through `wt`).
setup
run "$REPO" wt n6
print -r -- "a.env" > "$REPO/.worktreeinclude"; print -r -- "A" > "$REPO/a.env"
CLEANP=$(mkd)
for b in env git awk mkdir; do ln -s "$(command -v $b)" "$CLEANP/$b"; done
OUT="$(cd "$REPO" && source "$FUNCS" && export PATH="$CLEANP" && wt-prepare n6 2>&1)"; RC=$?
rc_is 1 "missing destination with wtcp absent aborts instead of silently skipping"
has "wtcp is missing" "abort names the missing tool"
```

- [ ] **Step 3: Run the tests to verify they fail**

Run: `zsh .scripts/test-wt-functions.sh 2>&1 | rg 'M\.' -A14`
Expected: FAIL — `wt-prepare` undefined.

- [ ] **Step 4: Implement**

Add both functions. **Leave `wt`'s existing copy block exactly as it is** — it is
removed in Task 8, at the moment `wt` starts calling `_wt_do_prepare` instead.
Deleting it here would strip `wt` of its copy step while nothing has replaced it,
breaking the committed section-D assertions (wtcp failure propagates, missing
entry warns, missing wtcp aborts) for the duration of one task.

The duplication between the old block and `_wt_do_prepare` is intentional and
lasts exactly one task.

```zsh
# _wt_do_prepare <main> <dest> <branch> <slug> — copy missing manifest entries,
# then run the project setup hook. The UNLOCKED routine: `wt` calls it under the
# lock it already holds, and `wt-prepare` is the thin locked wrapper. It must not
# lock itself — fcntl locks are per-process, so a nested acquire/release here
# would silently drop the caller's lock (see _wt_lock).
_wt_do_prepare() {
  emulate -L zsh
  local main="$1" dest="$2" branch="$3" slug="$4" qb="${(q-)branch}"

  # Validate the hook before copying, so a misconfigured repository changes
  # nothing. This mirrors wt-rm, which validates before disrupting the session.
  _wt_hook_check "$main" >/dev/null 2>&1
  local hrc=$?
  if (( hrc == 1 )); then
    _wt_hook_check "$main"          # re-run for the message
    print -ru2 -- "    The worktree exists — fix the hook, then: wt-prepare $qb && wt $qb"
    return 1
  fi

  _wt_manifest "$main" "$dest" || {
    print -ru2 -- "    The worktree exists — fix .worktreeinclude, then: wt-prepare $qb && wt $qb"
    return 1
  }

  if (( ${#_WT_CARRY} )); then
    if (( ! $+commands[wtcp] )); then
      print -ru2 -- "wt: files need copying but wtcp is missing (brew install satococoa/tap/wtcp)."
      print -ru2 -- "    The worktree exists — install wtcp, then: wt-prepare $qb && wt $qb"
      return 1
    fi
    # `--` is mandatory: manifest entries are arbitrary strings, and one named
    # "-h" is otherwise parsed as an option and prints usage instead of copying.
    if ! ( cd "$dest" && wtcp --from "$main" -- "${_WT_CARRY[@]}" ); then
      print -ru2 -- "wt: copying .worktreeinclude files into $dest failed."
      print -ru2 -- "    The worktree exists — fix the copy, then: wt-prepare $qb && wt $qb"
      return 1
    fi
  fi

  if ! _wt_hook_run "$main" "$dest" "$branch" "$slug" setup; then
    print -ru2 -- "wt: .worktreehook setup failed for $dest."
    print -ru2 -- "    The worktree exists — fix it, then: wt-prepare $qb && wt $qb"
    return 1
  fi
  return 0
}

# wt-prepare <branch> — re-run preparation against an existing worktree.
#
# The named recovery path for a partial copy or a failed setup hook. Re-running
# `wt` cannot do this: on an existing worktree `wt` takes the reopen path, which
# deliberately skips preparation.
#
# It never creates, stops, attaches or switches a Zellij session, so it may run
# while the target session and application are live. Project hooks must tolerate
# that or document their own restriction.
wt-prepare() {
  emulate -L zsh
  local branch="$1"
  [[ -n "$branch" ]] || { print -ru2 -- "usage: wt-prepare <branch>"; return 1; }
  local slug="${branch//\//-}" main common dest
  main="$(_wt_primary)" || return 1
  common="$(_wt_git rev-parse --path-format=absolute --git-common-dir 2>/dev/null)" || return 1
  dest="${main:h}/${main:t}-${slug}"

  [[ -d "$dest" ]] || { print -ru2 -- "wt-prepare: $dest does not exist."; return 1; }
  _wt_lock "$common" "$slug" || return 1
  {
    _wt_assert_worktree "$main" "$dest" "$branch" || return 1
    _wt_do_prepare "$main" "$dest" "$branch" "$slug" || return 1
    print -r -- "✓ prepared $dest"
  } always {
    _wt_unlock
  }
}
```

- [ ] **Step 5: Run the tests to verify they pass**

Run: `zsh -n dot_config/zsh/functions && zsh .scripts/test-wt-functions.sh`
Expected: PASS, `failed: 0`.

- [ ] **Step 6: Commit**

```bash
git add dot_config/zsh/functions .scripts/test-wt-functions.sh
git commit -m "feat(zsh): add wt-prepare and the shared preparation routine"
```

---

### Task 8: Rework `wt` onto the lock, pre-validation, and the shared routine

**Files:**
- Modify: `dot_config/zsh/functions` (the `wt` function)
- Test: `.scripts/test-wt-functions.sh`

**Interfaces:**
- Consumes: `_wt_primary`, `_wt_lock`, `_wt_unlock`, `_wt_hook_check`, `_wt_assert_worktree`, `_wt_do_prepare`, `dev`.
- Produces: `wt <branch> [start-point]` — unchanged signature.

- [ ] **Step 1: Write the failing tests**

```zsh
print -r -- "N. wt creation paths"
# Invalid hook must leave NOTHING behind.
setup
print -r -- '#!/bin/sh' > "$REPO/.worktreehook"; chmod +x "$REPO/.worktreehook"   # untracked
run "$REPO" wt o1
rc_is 1 "invalid hook refuses creation"
[[ -d "$HOME/Code/Org/repo-o1" ]] && _fail "no worktree is created" || _pass "no worktree is created"
run "$REPO" git branch --list o1
eq "$OUT" "" "no branch is created"

# Existing local branch, no worktree: same pre-validation, prepare and dev gating.
setup
git -C "$REPO" branch o2
mkhook "$REPO" '#!/bin/sh
touch "$WT_MAIN/setup-$WT_BRANCH"; exit 0'
: > "$ZLOG"
run "$REPO" wt o2
rc_is 0 "creating a worktree for an existing branch succeeds"
[[ -f "$REPO/setup-o2" ]] && _pass "setup runs on the existing-branch path" || _fail "setup runs on the existing-branch path"
logged "--session org--repo-o2" "dev is launched after preparation"

setup
git -C "$REPO" branch o3
run "$REPO" wt o3 main
rc_is 1 "start-point with an existing branch is refused"

# Setup failure gates dev.
setup
mkhook "$REPO" '#!/bin/sh
exit 5'
: > "$ZLOG"
run "$REPO" wt o4
rc_is 1 "setup failure fails wt"
unlogged "--session" "dev is not launched after a setup failure"
[[ -d "$HOME/Code/Org/repo-o4" ]] && _pass "worktree is preserved" || _fail "worktree is preserved"
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `zsh .scripts/test-wt-functions.sh 2>&1 | rg 'N\.' -A12`
Expected: FAIL — `wt` does not yet pre-validate or run hooks.

- [ ] **Step 3: Implement**

Replace the body of `wt` (keep the comment header, extending it per the spec).
This is where the old inline copy block is **deleted** — `_wt_do_prepare` from
Task 7 replaces it, so the one-task duplication ends here:

```zsh
wt() {
  emulate -L zsh
  local branch="$1" start="${2-}"
  [[ -n "$branch" ]] || { print -ru2 -- "usage: wt <branch> [start-point]"; return 1; }
  local slug="${branch//\//-}" qb="${(q-)branch}" main common dest
  main="$(_wt_primary)" || return 1
  common="$(_wt_git rev-parse --path-format=absolute --git-common-dir 2>/dev/null)" || return 1
  dest="${main:h}/${main:t}-${slug}"

  _wt_lock "$common" "$slug" || return 1
  {
    local created=1
    if [[ -d "$dest" ]]; then
      _wt_assert_worktree "$main" "$dest" "$branch" || return 1
      print -ru2 -- "wt: reopening $dest"; created=
    else
      # Pre-validate before creating anything: a misconfigured repository should
      # leave no worktree and no branch behind. This does NOT replace the check
      # inside _wt_hook_run immediately before execution.
      _wt_hook_check "$main" >/dev/null 2>&1
      (( $? == 1 )) && { _wt_hook_check "$main"; return 1 }

      if _wt_git -C "$main" show-ref --quiet --verify "refs/heads/$branch"; then
        [[ -z "$start" ]] || {
          print -ru2 -- "wt: branch $qb already exists — drop the start point."; return 1 }
        _wt_git worktree add "$dest" "$branch" || return 1
      else
        local base
        if [[ -n "$start" ]]; then
          base="$start"
        else
          base="$(_wt_git symbolic-ref --quiet --short HEAD 2>/dev/null)" \
            || base="detached@$(_wt_git rev-parse --short HEAD 2>/dev/null)"
        fi
        print -r -- "wt: branching $qb from $base"
        _wt_git worktree add "$dest" -b "$branch" ${start:+"$start"} || return 1
      fi
    fi

    [[ -n "$created" ]] && { _wt_do_prepare "$main" "$dest" "$branch" "$slug" || return 1 }
  } always {
    _wt_unlock
  }

  dev "$dest"
}
```

Two things make this correct, both verified:

- **`dev` is outside the `always` block**, so the lock is released before a
  long-lived session attaches. Holding it across `dev` would block every later
  lifecycle command on that target for as long as the session lives.
- **`return N` inside the try block runs the `always` block and then returns from
  the function** — the code after the block is not reached. So every `return 1`
  above both releases the lock and skips `dev`; no explicit status re-check is
  needed, and adding one would be dead code.

- [ ] **Step 4: Run the tests to verify they pass**

Run: `zsh -n dot_config/zsh/functions && zsh .scripts/test-wt-functions.sh`
Expected: PASS, `failed: 0`. All pre-existing creation, reopen and collision tests still pass.

- [ ] **Step 5: Commit**

```bash
git add dot_config/zsh/functions .scripts/test-wt-functions.sh
git commit -m "feat(zsh): pre-validate hooks and share the preparation routine in wt"
```

---

### Task 9: Rework `wt-rm` onto the lock, three cleanliness checks, and teardown

**Files:**
- Modify: `dot_config/zsh/functions` (the `wt-rm` function)
- Test: `.scripts/test-wt-functions.sh`

**Interfaces:**
- Consumes: `_wt_primary`, `_wt_lock`, `_wt_unlock`, `_wt_clean`, `_wt_assert_worktree`, `_wt_hook_check`, `_wt_hook_run`, `_wt_session_name`.
- Produces: `wt-rm <branch>` — unchanged signature.

- [ ] **Step 1: Write the failing tests**

```zsh
print -r -- "O. wt-rm teardown"
setup
mkhook "$REPO" '#!/bin/sh
[ "$1" = teardown ] && touch "$WT_MAIN/torn-$WT_SLUG"
exit 0'
run "$REPO" wt q1
export MOCK_ZJ_SESSIONS="org--repo-q1"
run "$REPO" wt-rm q1
rc_is 0 "teardown path removes the worktree"
[[ -f "$REPO/torn-q1" ]] && _pass "teardown hook ran" || _fail "teardown hook ran"

# Teardown failure preserves the worktree with its session stopped.
setup
mkhook "$REPO" '#!/bin/sh
[ "$1" = teardown ] && exit 4
exit 0'
run "$REPO" wt q2
export MOCK_ZJ_SESSIONS="org--repo-q2"
run "$REPO" wt-rm q2
rc_is 1 "teardown failure fails wt-rm"
[[ -d "$HOME/Code/Org/repo-q2" ]] && _pass "worktree preserved after teardown failure" || _fail "worktree preserved after teardown failure"

# Hook exit 130 is the interruption proxy.
setup
mkhook "$REPO" '#!/bin/sh
[ "$1" = teardown ] && exit 130
exit 0'
run "$REPO" wt q3; export MOCK_ZJ_SESSIONS="org--repo-q3"
run "$REPO" wt-rm q3
rc_is 1 "hook exit 130 preserves the stopped worktree"
[[ -d "$HOME/Code/Org/repo-q3" ]] && _pass "worktree preserved on interruption proxy" || _fail "worktree preserved on interruption proxy"

# Non-ignored teardown output is caught by check 3.
setup
mkhook "$REPO" '#!/bin/sh
[ "$1" = teardown ] && echo report > "$WT_WORKTREE/teardown-report.txt"
exit 0'
run "$REPO" wt q4; export MOCK_ZJ_SESSIONS="org--repo-q4"
run "$REPO" wt-rm q4
rc_is 1 "non-ignored teardown output aborts removal"
has "teardown" "the refusal ties the state to teardown"
[[ -d "$HOME/Code/Org/repo-q4" ]] && _pass "worktree preserved" || _fail "worktree preserved"

# Git-ignored teardown output is fine.
setup
print -r -- "teardown.log" > "$REPO/.gitignore"
git -C "$REPO" add .gitignore >/dev/null; git -C "$REPO" commit -q -m ignore
mkhook "$REPO" '#!/bin/sh
[ "$1" = teardown ] && echo x > "$WT_WORKTREE/teardown.log"
exit 0'
run "$REPO" wt q5; export MOCK_ZJ_SESSIONS="org--repo-q5"
run "$REPO" wt-rm q5
rc_is 0 "git-ignored teardown output still allows removal"

# Check 3 fails closed when teardown makes status unreadable.
setup
mkhook "$REPO" '#!/bin/sh
[ "$1" = teardown ] && echo garbage > "$WT_MAIN/.git/worktrees/repo-q6/index"
exit 0'
run "$REPO" wt q6; export MOCK_ZJ_SESSIONS="org--repo-q6"
run "$REPO" wt-rm q6
rc_is 1 "unreadable status after teardown fails closed"
[[ -d "$HOME/Code/Org/repo-q6" ]] && _pass "worktree preserved when state is unknown" || _fail "worktree preserved when state is unknown"

# An absent session counts as successful shutdown, so retry works.
setup
run "$REPO" wt q7
export MOCK_ZJ_SESSIONS=""
run "$REPO" wt-rm q7
rc_is 0 "absent session counts as successful shutdown"

# Check 2: dirt introduced BY session shutdown is caught before teardown runs.
# The zellij stub writes a non-ignored file when asked to delete the session.
setup
mkhook "$REPO" '#!/bin/sh
[ "$1" = teardown ] && touch "$WT_MAIN/teardown-ran-$WT_SLUG"
exit 0'
run "$REPO" wt q8
export MOCK_ZJ_SESSIONS="org--repo-q8" MOCK_ZJ_DELETE_TOUCH="$HOME/Code/Org/repo-q8/flushed.txt"
run "$REPO" wt-rm q8
rc_is 1 "dirt from session shutdown is caught at check 2"
[[ -f "$REPO/teardown-ran-q8" ]] && _fail "teardown does not run after check 2 fails" \
                                 || _pass "teardown does not run after check 2 fails"
unset MOCK_ZJ_DELETE_TOUCH

# Hook validation happens BEFORE the session is stopped.
setup
run "$REPO" wt q9
print -r -- '#!/bin/sh' > "$REPO/.worktreehook"; chmod +x "$REPO/.worktreehook"   # untracked
export MOCK_ZJ_SESSIONS="org--repo-q9"
: > "$ZLOG"
run "$REPO" wt-rm q9
rc_is 1 "invalid hook refuses wt-rm"
unlogged "delete-session" "the session is not stopped when hook config is invalid"

# Hostile-but-valid branch names are quoted in every recovery message.
setup
mkhook "$REPO" '#!/bin/sh
[ "$1" = teardown ] && exit 4
exit 0'
for b in 'x|y' "x'q"; do
  run "$REPO" wt "$b"
  run "$REPO" wt-rm "$b"
  OUTQ="$OUT"
  run "$REPO" print -r -- "${(q-)b}"
  [[ "$OUTQ" == *"$OUT"* ]] && _pass "branch '$b' is quoted in recovery output" \
                            || _fail "branch '$b' is quoted in recovery output"
done
```

The check-2 test needs the zellij stub to be able to dirty the worktree on
shutdown. Add to the `delete-session` branch of the stub:

```bash
  "delete-session"*)
    [ -n "${MOCK_ZJ_DELETE_TOUCH:-}" ] && : > "$MOCK_ZJ_DELETE_TOUCH"
    exit "$MOCK_ZJ_DELETE_RC" ;;
```

and add `MOCK_ZJ_DELETE_TOUCH=""` to the defaults exported by `setup`.

- [ ] **Step 2: Run the tests to verify they fail**

Run: `zsh .scripts/test-wt-functions.sh 2>&1 | rg 'O\.' -A16`
Expected: FAIL — `wt-rm` runs no hook and performs only one cleanliness check.

- [ ] **Step 3: Implement**

Replace the body of `wt-rm`:

```zsh
wt-rm() {
  emulate -L zsh
  local branch="$1"
  [[ -n "$branch" ]] || { print -ru2 -- "usage: wt-rm <branch>"; return 1; }
  local slug="${branch//\//-}" qb="${(q-)branch}" main common dest
  main="$(_wt_primary)" || return 1
  common="$(_wt_git rev-parse --path-format=absolute --git-common-dir 2>/dev/null)" || return 1
  dest="${main:h}/${main:t}-${slug}"

  [[ -d "$dest" ]] || { print -ru2 -- "wt-rm: $dest does not exist."; return 1; }
  _wt_lock "$common" "$slug" || return 1
  {
    _wt_assert_worktree "$main" "$dest" "$branch" || return 1

    local here; here="$(_wt_git rev-parse --path-format=absolute --show-toplevel 2>/dev/null)"
    [[ "${here:A}" == "${dest:A}" ]] && {
      print -ru2 -- "wt-rm: you're inside $dest — run this from another checkout."; return 1 }

    # Check 1 — before anything is disrupted.
    _wt_clean "$dest"
    case $? in
      1) print -ru2 -- "wt-rm: $dest has uncommitted changes — commit, stash or discard them first."; return 1 ;;
      2) print -ru2 -- "wt-rm: cannot determine whether $dest is clean — refusing."
         _wt_git -C "$dest" status --porcelain >/dev/null; return 1 ;;
    esac

    # Hook configuration, still before anything is disrupted.
    _wt_hook_check "$main" >/dev/null 2>&1
    (( $? == 1 )) && { _wt_hook_check "$main"; return 1 }

    # Stop the session. An absent session IS successful shutdown — that is the
    # normal state on a retry. Stopping first is an invariant: a live process
    # holding the directory open is what leaves an empty tmp/ husk behind.
    local name; name="$(_wt_session_name "$dest")"
    if zellij list-sessions -s 2>/dev/null | grep -Fqx -- "$name"; then
      zellij delete-session --force "$name" >/dev/null 2>&1 || {
        print -ru2 -- "wt-rm: could not stop session '$name' — refusing to remove $dest."
        print -ru2 -- "    Close it by hand (zellij delete-session --force $name), then retry."
        return 1 }
    fi

    # Check 2 — shutdown can flush files; that is how the Bootsnap husks arose.
    _wt_clean "$dest"
    case $? in
      1) print -ru2 -- "wt-rm: stopping the session left changes in $dest — inspect it, then retry."; return 1 ;;
      2) print -ru2 -- "wt-rm: cannot determine whether $dest is clean after session shutdown — refusing."; return 1 ;;
    esac

    if ! _wt_hook_run "$main" "$dest" "$branch" "$slug" teardown; then
      print -ru2 -- "wt-rm: .worktreehook teardown failed — $dest kept, session stopped."
      print -ru2 -- "    Fix it and retry: wt-rm $qb    (teardown is idempotent)"
      print -ru2 -- "    Or resume work with: wt-prepare $qb && wt $qb"
      return 1
    fi

    # Check 3 — ties non-ignored hook output to its cause, before Git's more
    # generic removal refusal appears one step later.
    _wt_clean "$dest"
    case $? in
      1) print -ru2 -- "wt-rm: teardown left changes in $dest — removal aborted. Resources may already be reclaimed."
         print -ru2 -- "    Hook output must be git-ignored or written outside the worktree."
         return 1 ;;
      2) print -ru2 -- "wt-rm: cannot determine whether $dest is clean after teardown — refusing. Resources may already be reclaimed."
         return 1 ;;
    esac

    _wt_git worktree remove "$dest" || return 1
    print -r -- "✓ removed worktree $dest"

    _wt_git -C "$main" branch -d "$branch" \
      || print -ru2 -- "wt-rm: branch $qb kept (not fully merged) — inspect or merge it before deleting it explicitly."

    [[ -d "$dest" ]] \
      && print -ru2 -- "wt-rm: $dest still exists (files recreated during removal) — remove it manually."
    return 0
  } always {
    _wt_unlock
  }
}
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `zsh -n dot_config/zsh/functions && zsh .scripts/test-wt-functions.sh`
Expected: PASS, `failed: 0`. All pre-existing `wt-rm` tests still pass.

- [ ] **Step 5: Deploy and verify end to end**

```bash
chezmoi apply ~/.config/zsh/functions
cmp dot_config/zsh/functions ~/.config/zsh/functions && echo "deployed == source"
git diff --check
```

- [ ] **Step 6: Commit**

```bash
git add dot_config/zsh/functions .scripts/test-wt-functions.sh
git commit -m "feat(zsh): run teardown hooks and gate removal on three cleanliness checks"
```

---

## Post-implementation

- [ ] Set the spec's status line to `**Status:** Implemented`, citing the MR and, once known, the merge SHA. Commit that change on its own.
- [ ] Set this plan's status line to `**Status:** Implemented` so it is not re-executed.

Both use the records vocabulary exactly: `Approved`, `In progress`, `Implemented`, `Superseded — see <link>`, `Abandoned — <brief reason>`. Nothing else. While the work is underway and before merge, both documents read `**Status:** In progress` with the MR reference added.

Curato's own `.worktreehook` — database, queue, cable and test database naming, plus the web port — is explicitly **not** part of this plan. It needs its own design record per §13 of the spec.
