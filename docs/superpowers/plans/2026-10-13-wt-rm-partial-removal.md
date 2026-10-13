# wt-rm partial-removal recovery — implementation plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** When `git worktree remove` deletes a checkout but not Git's registration, `wt-rm`
describes that state truthfully and a retry finishes the removal. Check 4 also waits up to
5 s for processes that are exiting on their own.

**Architecture:** All code is in the zsh function file. `wt-rm` takes its per-target lock
first, then picks the normal path (the checkout is a directory) or a new recovery helper
(the checkout is gone). Two blocks the paths share move into helpers: the Git-lock
classification and the branch deletion. Check 4 becomes a bounded polling loop. All tests
are in the existing zsh suite, which uses real Git repositories and stubs on PATH.

**Tech stack:** zsh 5.9 (`emulate -L zsh`), git 2.56, bash test stubs.

**Spec:** `docs/superpowers/specs/2026-10-13-wt-rm-partial-removal-design.md`

## Global constraints

- Every `wt-rm` check fails closed. It never deletes a checkout, registration or branch it
  cannot account for, and never crosses a Git lock whose reason is not
  `wt-managed; remove with command wt-rm`.
- The Herdr refusal rules (`_wt_stop_herdr_workspaces`) are reused unchanged.
- No `git worktree prune` anywhere.
- The other hook-protocol §9.3 failure modes keep their messages and recovery routes,
  byte for byte.
- Grace period: re-scan every `0.5` s, at most 10 times (5 s). There is no setting for it,
  and the suite stubs `sleep`.
- Execute suites, never prefix an interpreter: `./tests/wt-functions.test.sh`, or
  `./tests/run.sh wt-functions` for the passed/total line. Baseline: 385/385, sandboxed.
- This checkout is shared. Run `git branch --show-current` right before every commit; it
  must print `fix/wt-rm-partial-removal`.
- Branch assertions use `git branch --list --format='%(refname:short)' <b>`. A plain listing
  prefixes `+ ` to a branch held by a registered worktree, even one whose checkout is gone.
- Match the file's style: `emulate -L zsh` in every function, `print -ru2 --` for messages,
  no explanatory comments beyond what the surrounding code has.

## Review focus

Inputs the spec implies but its test list does not name. Each one gets a test in Task 2:

1. The path is a dangling symlink, or a plain file. `-d` is false, but it is not absent, so
   it must get the old "does not exist" refusal, never recovery.
2. The branch contains `/` (`fix/q20`, directory `repo-fix-q20`). The recovery match must
   compare against `refs/heads/fix/q20`, not against the slug.
3. A registration on a detached HEAD. Refuse, naming "a detached HEAD".
4. Another lifecycle command holds the target lock while the checkout is gone. Refuse with
   the lock message, and remove nothing.
5. A Herdr workspace still pointing at the deleted path. It is closed like any own workspace,
   and removal proceeds.

---

### Task 1: An honest message when removal fails partway

**Files:**
- Modify: `dot_config/zsh/functions`, the `if ! _wt_git $remove_args; then` block in `wt-rm`
  (currently lines 1058–1063).
- Test: `tests/wt-functions.test.sh`, section O, directly after the q11 case (which ends with
  `chmod 700 "$HOME/Code/Org/repo-q11/blocked" 2>/dev/null`).

**Interfaces:**
- Produces: the Q12 fixture (`$Q12`, `$Q12_REG`). Task 2 continues it in the same block.

- [ ] **Step 1: Write the failing test.** Insert after the q11 block:

```zsh
# A removal that deletes the checkout and then fails on Git's registration of it, as a
# sandboxed agent's did on 2026-10-13. Git deletes the checkout before the registration,
# so an unwritable registration directory reproduces exactly that partial state.
setup
mkhook "$REPO" '#!/bin/sh
if [ "$1" = teardown ]; then
  printf "x\n" >> "$WT_MAIN/q12-teardowns"
  chmod 500 "$(git -C "$WT_WORKTREE" rev-parse --absolute-git-dir)"
fi
exit 0'
run "$REPO" wt q12
Q12="$HOME/Code/Org/repo-q12"
Q12_REG="$REPO/.git/worktrees/repo-q12"
[[ -d "$Q12_REG" ]] && _pass "Q12 fixture: the registration directory is where expected" \
                    || _fail "Q12 fixture: the registration directory is where expected"
run "$REPO" wt-rm q12
rc_is 1 "Q12 a removal that fails on Git's registration fails wt-rm"
has "the checkout is deleted, but Git's registration of it remains" "Q12 the failure reports the partial state"
has "teardown done; branch q12 kept" "Q12 it says teardown ran and the branch is kept"
has "finish with: wt-rm q12" "Q12 it offers the retry that finishes the removal"
hasnt "worktree kept" "Q12 it does not claim the worktree was kept"
hasnt "wt-prepare q12" "Q12 it offers no resume route for a deleted checkout"
[[ -e "$Q12" ]] && _fail "Q12 the checkout is deleted" || _pass "Q12 the checkout is deleted"
eq "$(lock_reason_of "$Q12")" "wt-managed; remove with command wt-rm" \
   "Q12 the registration remains and still carries the Herdr lock"
run "$REPO" git branch --list --format='%(refname:short)' q12
eq "$OUT" "q12" "Q12 the branch is kept"
chmod 700 "$Q12_REG"
```

- [ ] **Step 2: Run it and check that it fails.**
  Run `./tests/wt-functions.test.sh 2>&1 | rg 'Q12|passed|failed'`. Expected: five
  message assertions fail, because the output is still the old message: the three `has`
  checks (partial state, "teardown done", "finish with") and both `hasnt` checks ("worktree
  kept" and "wt-prepare q12" are both present). The fixture, deleted-checkout, lock and
  branch assertions pass.

- [ ] **Step 3: Implement.** Replace the failure block in `wt-rm` with:

```zsh
    if ! _wt_git $remove_args; then
      if [[ -e "$dest" || -L "$dest" ]]; then
        print -ru2 -- "wt-rm: removing $dest failed — worktree kept, Herdr workspaces closed. Resources may already be reclaimed."
        print -ru2 -- "    Fix the obstruction and retry: wt-rm $qb    (teardown is idempotent)"
        print -ru2 -- "    Or resume work with: wt-prepare $qb && wt $qb"
      else
        print -ru2 -- "wt-rm: removing $dest failed partway — the checkout is deleted, but Git's registration of it remains. Herdr workspaces closed, teardown done; branch $qb kept."
        print -ru2 -- "    Fix the obstruction Git reported above, then finish with: wt-rm $qb"
      fi
      return 1
    fi
```

- [ ] **Step 4: Run the whole suite.** Run `./tests/run.sh wt-functions`. Expected: every
  assertion passes, q11 included (it still reports "worktree kept" with both routes).

- [ ] **Step 5: Commit.**

```bash
git branch --show-current   # must print fix/wt-rm-partial-removal
git add dot_config/zsh/functions tests/wt-functions.test.sh
git commit -m "Report a removal that deleted the checkout but not its registration"
```

---

### Task 2: A retry finishes the removal

**Files:**
- Modify: `dot_config/zsh/functions`:
  - add three helpers directly above the `# wt-rm <branch> — retire a worktree` comment block;
  - in `wt-rm`: the entry check, the lock-classification block, the branch-deletion block,
    and the header comment.
- Test: `tests/wt-functions.test.sh`:
  - section O: continue the Q12 block, then add Q13–Q20;
  - section I: the contention comment near `# The target is created first`, plus case z5;
  - section E: the `wt-rm nope` case.

**Interfaces:**
- Consumes: the Q12 fixture from Task 1. Also existing helpers: `_wt_git_lock_state <root> <dest>`
  (0 locked, with the reason in `_WT_GIT_LOCK_REASON`; 1 unlocked; 2 unreadable),
  `_wt_herdr_lock_reason`, `_wt_stop_herdr_workspaces <dest>`, `_wt_branch_content_merged <main> <branch>`.
- Produces:
  - `_wt_rm_lock_class <main> <dest>`: 0 Herdr-owned, 1 unlocked, 2 refused (message printed).
  - `_wt_rm_branch <main> <branch> <qb>`: always returns 0.
  - `_wt_rm_registration <main> <dest> <branch> <qb>`: 0 when the registration is removed,
    1 on any refusal.

- [ ] **Step 1: Write the failing tests.** First, continue the Q12 block directly after its
  `chmod 700 "$Q12_REG"`:

```zsh
run "$REPO" wt-rm q12
rc_is 0 "Q12 a retry finishes the partial removal"
has "is already gone — finishing its removal without re-running teardown" "Q12 the retry says teardown is skipped"
has "reclaim its resources yourself" "Q12 the retry says what it leaves to the user"
eq "$(wc -l < "$REPO/q12-teardowns" | tr -d ' ')" "1" "Q12 teardown ran once, not again on the retry"
run "$REPO" git worktree list --porcelain
hasnt "$Q12" "Q12 the Herdr-locked registration is removed (only --force --force can)"
run "$REPO" git branch --list --format='%(refname:short)' q12
eq "$OUT" "" "Q12 the merged branch is deleted"
```

Then add after it:

```zsh
# Q13: an unlocked registration whose checkout is gone takes a plain remove.
setup
run "$REPO" wt q13
Q13="$HOME/Code/Org/repo-q13"
git -C "$REPO" worktree unlock "$Q13"
rm -rf "$Q13"
run "$REPO" wt-rm q13
rc_is 0 "Q13 an unlocked registration whose checkout is gone is removed"
run "$REPO" git worktree list --porcelain
hasnt "$Q13" "Q13 the registration is removed"

# Q14: a registration at the right path on another branch is refused.
setup
Q14="$HOME/Code/Org/repo-q14"
git -C "$REPO" worktree add -q "$Q14" -b q14-other
rm -rf "$Q14"
run "$REPO" wt-rm q14
rc_is 1 "Q14 a missing checkout registered on another branch is refused"
has "is on 'q14-other', not 'q14'" "Q14 the refusal names the branch it has"
run "$REPO" git worktree list --porcelain
has "$Q14" "Q14 the registration survives"

# Q15: another owner's lock is never crossed, checkout or no checkout.
setup
run "$REPO" wt q15
Q15="$HOME/Code/Org/repo-q15"
git -C "$REPO" worktree unlock "$Q15"
git -C "$REPO" worktree lock --reason "user maintenance" "$Q15"
rm -rf "$Q15"
run "$REPO" wt-rm q15
rc_is 1 "Q15 a missing checkout under another owner's lock is refused"
has "locked for another reason: user maintenance" "Q15 the refusal names the lock"
hunlogged "workspace close" "Q15 nothing is closed"
eq "$(lock_reason_of "$Q15")" "user maintenance" "Q15 the registration and its lock survive"
run "$REPO" git branch --list --format='%(refname:short)' q15
eq "$OUT" "q15" "Q15 the branch survives"

# Q16: absence must be proven. A parent that cannot be listed proves nothing, because
# a denied stat looks just like a missing path. Mode 100 keeps the parent searchable,
# so the main checkout beside the target still works.
setup
run "$REPO" wt q16
Q16="$HOME/Code/Org/repo-q16"
rm -rf "$Q16"
chmod 100 "$HOME/Code/Org"
run "$REPO" wt-rm q16
chmod 755 "$HOME/Code/Org"
rc_is 1 "Q16 a target whose parent cannot be listed is refused"
has "cannot confirm $Q16 is gone" "Q16 the refusal says absence is unproven"
run "$REPO" git worktree list --porcelain
has "$Q16" "Q16 the registration survives"
run "$REPO" git branch --list --format='%(refname:short)' q16
eq "$OUT" "q16" "Q16 the branch survives"

# Q17: a foreign Herdr pane still inside the deleted path refuses, closing nothing.
setup
run "$REPO" wt q17
Q17="$HOME/Code/Org/repo-q17"
rm -rf "$Q17"
export MOCK_H_SESSION_LIST="$(sessions "$(session_json default true true)")"
export MOCK_H_WORKSPACES="{\"result\":{\"workspaces\":[
  {\"workspace_id\":\"w1\",\"label\":\"Org/repo\",\"worktree\":{\"checkout_path\":\"$REPO\",\"is_linked_worktree\":false}}]}}"
export MOCK_H_PANES="{\"result\":{\"panes\":[
  {\"workspace_id\":\"w1\",\"pane_id\":\"w1:p2\",\"cwd\":\"$Q17/app\"}]}}"
run "$REPO" wt-rm q17
rc_is 1 "Q17 a foreign pane inside the deleted path refuses recovery"
has "w1:p2" "Q17 the refusal names the pane"
hunlogged "workspace close" "Q17 nothing is closed"
run "$REPO" git worktree list --porcelain
has "$Q17" "Q17 the registration survives"

# Q18: the checkout's own workspace, still pointing at the deleted path, is closed.
setup
run "$REPO" wt q18
Q18="$HOME/Code/Org/repo-q18"
rm -rf "$Q18"
export MOCK_H_SESSION_LIST="$(sessions "$(session_json default true true)")"
export MOCK_H_WORKSPACES="{\"result\":{\"workspaces\":[
  {\"workspace_id\":\"w7\",\"label\":\"q18\",\"worktree\":{\"checkout_path\":\"$Q18\",\"is_linked_worktree\":true}}]}}"
export MOCK_H_PANES="{\"result\":{\"panes\":[
  {\"workspace_id\":\"w7\",\"pane_id\":\"w7:p1\",\"cwd\":\"$Q18\"}]}}"
run "$REPO" wt-rm q18
rc_is 0 "Q18 recovery closes the deleted checkout's own workspace and finishes"
hlogged "workspace close w7" "Q18 the own workspace is closed"
run "$REPO" git worktree list --porcelain
hasnt "$Q18" "Q18 the registration is removed"

# Q19: a dangling symlink, or a plain file, at the target is not absence.
setup
run "$REPO" wt q19
Q19="$HOME/Code/Org/repo-q19"
rm -rf "$Q19"
ln -s "$ROOTTMP/nowhere" "$Q19"
run "$REPO" wt-rm q19
rc_is 1 "Q19 a dangling symlink at the target is refused"
has "$Q19 does not exist." "Q19 it gets the existing refusal, not recovery"
rm -f "$Q19"; : > "$Q19"
run "$REPO" wt-rm q19
rc_is 1 "Q19 a plain file at the target is refused"
run "$REPO" git worktree list --porcelain
has "$Q19" "Q19 the registration survives both"

# Q20: a branch with a slash matches on the branch, not on the slug.
setup
run "$REPO" wt fix/q20
Q20="$HOME/Code/Org/repo-fix-q20"
rm -rf "$Q20"
run "$REPO" wt-rm fix/q20
rc_is 0 "Q20 recovery matches a slashed branch on its full name"
run "$REPO" git branch --list --format='%(refname:short)' fix/q20
eq "$OUT" "" "Q20 its merged branch is deleted"

# Q21: a detached registration at the target is refused.
setup
Q21="$HOME/Code/Org/repo-q21"
git -C "$REPO" worktree add -q --detach "$Q21"
rm -rf "$Q21"
run "$REPO" wt-rm q21
rc_is 1 "Q21 a missing checkout on a detached HEAD is refused"
has "is on 'a detached HEAD', not 'q21'" "Q21 the refusal says it is detached"
```

In section E, after `rc_is 1 "unknown worktree is refused"`, add:

```zsh
has "does not exist." "an unknown worktree keeps the specific refusal"
```

In section I, replace the comment lines

```
#    The target is created first: `wt-rm` and `wt-prepare` refuse an absent
#    directory BEFORE they reach the lock, so an empty fixture would produce the
#    wrong refusal and prove nothing about contention.
```

with

```
#    The target is created first: `wt-prepare` refuses an absent directory BEFORE
#    it reaches the lock, so an empty fixture would produce the wrong refusal and
#    prove nothing about contention.
```

Then add a z5 case after the z1 block, which ends where z1's checkout-survives assertion is:

```zsh
# z5: wt-rm decides between its two paths only under the lock, so a recovery
# candidate is refused while another lifecycle command holds the target.
setup
CD="$REPO/.git"
run "$REPO" wt z5
rm -rf "$HOME/Code/Org/repo-z5"
source "$FUNCS"
_wt_lock "$CD" z5 >/dev/null 2>&1
run "$REPO" wt-rm z5
rc_is 1 "z5 wt-rm refuses a recovery candidate while the lock is held"
has "another lifecycle command is working on 'z5'" "z5 the refusal is the lock's"
_wt_unlock
run "$REPO" git worktree list --porcelain
has "$HOME/Code/Org/repo-z5" "z5 the registration survives the refused recovery"
```

Read the z1 block before inserting: if it unlocks with `_wt_unlock` in the test shell, z5 must
come after that unlock.

- [ ] **Step 2: Run them and check that they fail.** Run
  `./tests/wt-functions.test.sh 2>&1 | rg 'FAIL|passed|failed'`. Expected failures:
  - Q12's retry assertions (it prints "does not exist"), Q13, Q18 and Q20 (each exits 1);
  - Q14's and Q21's message assertions;
  - z5's message assertion, because today the refusal is "does not exist", ahead of the lock.

  Q15, Q16 and Q17 already pass their rc and survival assertions, because today's early
  refusal produces those outcomes for the wrong reason. Their message assertions fail
  (Q15's lock text, Q16's "cannot confirm", Q17's pane id). Q19 passes in full today: it
  guards the existing refusal against the change.

- [ ] **Step 3: Add the helpers.** Insert directly above the
  `# wt-rm <branch> — retire a worktree made by` comment block:

```zsh
# _wt_rm_lock_class <main> <dest> — 0 Herdr-owned (crossed with Git's double force),
# 1 unlocked, 2 refused: another owner's lock, or lock state that cannot be read.
_wt_rm_lock_class() {
  emulate -L zsh
  _wt_git_lock_state "$1" "$2"
  case $? in
    0) [[ "$_WT_GIT_LOCK_REASON" == "$(_wt_herdr_lock_reason)" ]] && return 0
       print -ru2 -- "wt-rm: $2 is locked for another reason: ${_WT_GIT_LOCK_REASON:-<no reason>}"
       print -ru2 -- "    Unlock it yourself only if that owner no longer needs it."
       return 2 ;;
    1) return 1 ;;
    *) return 2 ;;
  esac
}

# _wt_rm_branch <main> <branch> <qb> — delete a removed worktree's branch if its work
# is merged; keeping it is not a failure.
_wt_rm_branch() {
  emulate -L zsh
  local main="$1" branch="$2" qb="$3"
  # -d first, stderr suppressed: its refusal is not a verdict, since a squash-merged
  # branch fails -d. Only if the content test also declines is the work unmerged.
  if ! _wt_git -C "$main" branch -d "$branch" 2>/dev/null; then
    if _wt_branch_content_merged "$main" "$branch" \
       && _wt_git -C "$main" branch -D "$branch" >/dev/null 2>&1; then
      print -r -- "✓ deleted branch $qb (squash-merged — its content is already in the base)"
    else
      print -ru2 -- "wt-rm: branch $qb kept (not fully merged) — inspect or merge it before deleting it explicitly."
    fi
  fi
  return 0
}

# _wt_rm_registration <main> <dest> <branch> <qb> — finish a removal that deleted the
# checkout but not Git's registration of it. Runs under wt-rm's lock, when $dest is
# not a directory.
#
# Absence is proven, not inferred: a denied stat fails exactly like a missing path, and
# Git's own prunable test with it. $dest's parent also holds the main checkout, so a
# listing that lacks the main checkout is a listing that failed.
_wt_rm_registration() {
  emulate -L zsh
  local main="$1" dest="$2" branch="$3" qb="$4" rec wt_path have="" rc in_target=0 found=0
  local -a names fields
  if [[ -e "$dest" || -L "$dest" ]]; then
    print -ru2 -- "wt-rm: $dest does not exist."
    return 1
  fi
  names=( "${dest:h}"/*(DN:t) )
  if (( ! ${names[(Ie)${main:t}]} || ${names[(Ie)${dest:t}]} )); then
    print -ru2 -- "wt-rm: cannot confirm $dest is gone — ${dest:h} cannot be listed reliably. Refusing."
    return 1
  fi
  fields=( ${(0)"$(_wt_git -C "$main" worktree list --porcelain -z 2>/dev/null)"} ); rc=$?
  if (( rc )); then
    print -ru2 -- "wt-rm: cannot read Git's worktree list — refusing."
    return 1
  fi
  for rec in $fields; do
    if [[ "$rec" == 'worktree '* ]]; then
      wt_path="${rec#worktree }"
      in_target=0
      [[ "${wt_path:A}" == "${dest:A}" ]] && { in_target=1; found=1 }
    elif (( in_target )) && [[ "$rec" == 'branch refs/heads/'* ]]; then
      have="${rec#branch refs/heads/}"
    fi
  done
  if (( ! found )); then
    print -ru2 -- "wt-rm: $dest does not exist."
    return 1
  fi
  if [[ "$have" != "$branch" ]]; then
    print -ru2 -- "wt-rm: Git's registration of $dest is on '${have:-a detached HEAD}', not '$branch' — refusing."
    return 1
  fi

  local herdr_owned=0
  _wt_rm_lock_class "$main" "$dest"
  case $? in
    0) herdr_owned=1 ;;
    1) ;;
    *) return 1 ;;
  esac
  _wt_stop_herdr_workspaces "$dest" || return 1

  print -ru2 -- "wt-rm: $dest is already gone — finishing its removal without re-running teardown."
  print -ru2 -- "    If it was deleted by hand rather than by an interrupted wt-rm, reclaim its resources yourself."
  local -a remove_args
  remove_args=(worktree remove "$dest")
  (( herdr_owned )) && remove_args=(worktree remove --force --force "$dest")
  if ! _wt_git -C "$main" $remove_args; then
    print -ru2 -- "wt-rm: removing Git's registration of $dest failed — it remains; branch $qb kept."
    print -ru2 -- "    Fix the obstruction Git reported above, then retry: wt-rm $qb"
    return 1
  fi
  print -r -- "✓ removed Git's registration of $dest"
  _wt_rm_branch "$main" "$branch" "$qb"
}
```

- [ ] **Step 4: Rewire `wt-rm`.**
  1. Delete the line
     `[[ -d "$dest" ]] || { print -ru2 -- "wt-rm: $dest does not exist."; return 1; }`.
     Make the first statement inside the `{` after `_wt_lock "$common" "$slug" || return 1`:

     ```zsh
         [[ -d "$dest" ]] || { _wt_rm_registration "$main" "$dest" "$branch" "$qb"; return }
     ```
  2. Replace everything from `local git_lock_state herdr_owned=0 wanted_lock` through the
     `esac` that closes `case "$git_lock_state" in`. Keep the two comment lines above it. The
     replacement:

     ```zsh
         local herdr_owned=0
         _wt_rm_lock_class "$main" "$dest"
         case $? in
           0) herdr_owned=1 ;;
           1) ;;
           *) return 1 ;;
         esac
     ```
  3. Replace the branch-deletion block, from its `# -d first, stderr suppressed` comment
     through its closing `fi`, with `_wt_rm_branch "$main" "$branch" "$qb"`.
  4. In the header comment, after the numbered list, add:

     ```
     # A checkout that is gone while Git still registers it — a removal that failed after
     # deleting it — skips steps 1-6: _wt_rm_registration proves the absence, reruns the
     # lock and Herdr checks, and removes only the registration.
     ```
  5. Grep the function for the leftover names: `rg -n 'git_lock_state|wanted_lock' dot_config/zsh/functions`.
     The only matches should be the definition and use of `_wt_git_lock_state` itself.

- [ ] **Step 5: Run the whole suite.** Run `./tests/run.sh wt-functions`. Expected: every
  assertion passes, the existing E, I, O, U and V cases included.

- [ ] **Step 6: Commit.**

```bash
git branch --show-current   # must print fix/wt-rm-partial-removal
git add dot_config/zsh/functions tests/wt-functions.test.sh
git commit -m "Finish a wt-rm whose checkout is gone but still registered"
```

---

### Task 3: A grace period before check 4 refuses

**Files:**
- Modify: `dot_config/zsh/functions`, check 4 in `wt-rm` (the `local busy line` block), and
  step 6 of the header comment.
- Test: `tests/wt-functions.test.sh`:
  - the stubs: a new `sleep` stub, and the `lsof` stub;
  - `setup()`;
  - section V, after the `live-sib` case.

**Interfaces:**
- Consumes: `wt-teardown scan` (exit 0 with `<pid> <command>` lines, or with nothing when
  idle; exit 1 when it cannot trust the listing).
- Produces: no new names. Test hooks: `$SLOG`, `MOCK_LSOF_BUSY_N`, `MOCK_LSOF_BUSY_SPEC` and
  `MOCK_LSOF_THEN_FAIL`.

- [ ] **Step 1: Extend the stubs.**
  1. After the `cat > "$STUBS/lsof"` heredoc, add a sleep stub:

     ```zsh
     cat > "$STUBS/sleep" <<'STUB'
     #!/bin/sh
     # Instant and logged: wt-rm's grace period is asserted by its schedule, never waited out.
     printf '%s\n' "$*" >> "${SLOG:-/dev/null}"
     STUB
     ```

     Add `"$STUBS/sleep"` to the `chmod +x` line that follows the stubs.
  2. In the lsof stub, add the sequence controls to its header comment:
     - `MOCK_LSOF_BUSY_N` and `MOCK_LSOF_BUSY_SPEC` make the first N calls since `$LLOG` was
       last emptied answer with the busy spec;
     - after those, calls answer with `MOCK_LSOF_SPEC`, or with nothing at all (a failed
       read) when `MOCK_LSOF_THEN_FAIL` is set.

     Then replace the line `done <<< "${MOCK_LSOF_SPEC:-}"` and the `while` header above it
     so that the loop reads `$spec`, computed after the `-F0pcnR` check:

     ```bash
     spec="${MOCK_LSOF_SPEC:-}"
     if [ -n "${MOCK_LSOF_BUSY_N:-}" ]; then
       n=$(wc -l < "$LLOG")
       if [ "$n" -le "$MOCK_LSOF_BUSY_N" ]; then
         spec="${MOCK_LSOF_BUSY_SPEC:-}"
       elif [ -n "${MOCK_LSOF_THEN_FAIL:-}" ]; then
         exit 0
       fi
     fi
     while IFS=$'\t' read -r pid cmd cwd; do
       [ -n "$pid" ] || continue
       printf 'p%s\0R1\0c%s\0fcwd\0n%s\0\n' "$pid" "$cmd" "$cwd"
     done <<< "$spec"
     ```
  3. In `setup()`:
     - add `SLOG="$ROOTTMP/sleep.log"` to the `export DLOG=…` list and `: > "$SLOG"` to the
       truncation line;
     - add `MOCK_LSOF_BUSY_N MOCK_LSOF_BUSY_SPEC MOCK_LSOF_THEN_FAIL` to the `unset` line.

- [ ] **Step 2: Write the failing tests.** In section V, after the `live-sib` case:

```zsh
# Closing a workspace ends some processes only after a delay: Codex's app-server daemon
# stops a thread's MCP servers a few seconds after its client goes. Check 4 re-scans for
# up to 5 s before refusing, and the schedule is the assertion.
setup
run "$REPO" wt grace-clears
GC="$HOME/Code/Org/repo-grace-clears"
export MOCK_LSOF_BUSY_N=3 MOCK_LSOF_BUSY_SPEC="$(lsof_spec 1 launchd / 5150 node_repl "$GC")"
: > "$LLOG"; : > "$SLOG"
run "$REPO" wt-rm grace-clears
rc_is 0 "a process that exits within the grace period does not block removal"
eq "$(<$SLOG)" $'0.5\n0.5\n0.5' "removal proceeds after exactly three 0.5 s polls"
[[ -d "$GC" ]] && _fail "the checkout is removed once the scan clears" \
               || _pass "the checkout is removed once the scan clears"

setup
run "$REPO" wt grace-stays
GS="$HOME/Code/Org/repo-grace-stays"
export MOCK_LSOF_SPEC="$(lsof_spec 1 launchd / 5150 node_repl "$GS")"
: > "$SLOG"
run "$REPO" wt-rm grace-stays
rc_is 1 "a process still there after the grace period blocks removal"
has "still in use by a running process after waiting 5 s" "the refusal says it waited"
eq "$(wc -l < "$SLOG" | tr -d ' ')" "10" "it polled exactly ten times"
eq "$(sort -u "$SLOG")" "0.5" "every poll sleeps 0.5 s"
[[ -d "$GS" ]] && _pass "the checkout survives the refusal" || _fail "the checkout survives the refusal"
eq "$(lock_reason_of "$GS")" "wt-managed; remove with command wt-rm" "the registration survives the refusal"
run "$REPO" git branch --list --format='%(refname:short)' grace-stays
eq "$OUT" "grace-stays" "the branch survives the refusal"

setup
run "$REPO" wt grace-fails
GF="$HOME/Code/Org/repo-grace-fails"
export MOCK_LSOF_BUSY_N=1 MOCK_LSOF_BUSY_SPEC="$(lsof_spec 1 launchd / 5150 node_repl "$GF")" \
       MOCK_LSOF_THEN_FAIL=1
: > "$LLOG"; : > "$SLOG"
run "$REPO" wt-rm grace-fails
rc_is 1 "a scan that fails during the grace period fails closed"
has "could not scan for processes still in $GF" "the refusal names the failed scan"
eq "$(wc -l < "$SLOG" | tr -d ' ')" "1" "polling stops at the failed scan"
[[ -d "$GF" ]] && _pass "the checkout survives the failed scan" || _fail "the checkout survives the failed scan"
eq "$(lock_reason_of "$GF")" "wt-managed; remove with command wt-rm" "the registration survives the failed scan"
run "$REPO" git branch --list --format='%(refname:short)' grace-fails
eq "$OUT" "grace-fails" "the branch survives the failed scan"
```

- [ ] **Step 3: Run them and check that they fail.**
  Run `./tests/wt-functions.test.sh 2>&1 | rg 'FAIL|passed|failed'`. Expected:
  - grace-clears fails: rc 1, and an empty sleep log;
  - grace-stays fails its "after waiting 5 s" and poll-count assertions;
  - grace-fails fails its "could not scan" and poll-count assertions. Its rc and survival
    assertions pass, because the first busy scan already refuses today.

- [ ] **Step 4: Implement.** Replace check 4's scan-and-refuse block, from `local busy line`
  through the `fi` after the `for line in ${(f)busy}` loop, with:

```zsh
    local busy line polls=0
    while :; do
      busy="$(WT_WORKTREE="$dest" command wt-teardown scan)" || {
        print -ru2 -- "wt-rm: could not scan for processes still in $dest — refusing."
        return 1
      }
      [[ -z "$busy" ]] && break
      (( polls == 10 )) && break
      command sleep 0.5
      (( ++polls ))
    done
    if [[ -n "$busy" ]]; then
      print -ru2 -- "wt-rm: $dest is still in use by a running process after waiting 5 s — removal aborted. Resources may already be reclaimed."
      for line in ${(f)busy}; do print -ru2 -- "    $line"; done
      print -ru2 -- "    Herdr's workspaces for this checkout are closed already; these are still in it."
      print -ru2 -- "    Stop them — from .worktreehook teardown if the project starts them — then retry: wt-rm $qb"
      return 1
    fi
```

  In the header comment, change step 6 to read:

```
#   6. check 4 (`wt-teardown scan`), last before Git deletes files: it reads the OS,
#      which Git and Herdr cannot see. After teardown because stopping project
#      services is what teardown is for. It re-scans every 0.5 s for up to 5 s, since
#      some processes exit only after their workspace closes. A heuristic, not a proof.
```

- [ ] **Step 5: Run the whole suite.** Run `./tests/run.sh wt-functions`. Expected: every
  assertion passes. The existing V cases that stay busy now poll ten times through the
  instant `sleep` stub, so the suite stays as fast as before.

- [ ] **Step 6: Commit.**

```bash
git branch --show-current   # must print fix/wt-rm-partial-removal
git add dot_config/zsh/functions tests/wt-functions.test.sh
git commit -m "Wait up to 5 s for exiting processes before wt-rm refuses"
```
