#!/usr/bin/env zsh
# Mocked test for the worktree/session helpers in dot_config/zsh/functions:
# _wt_session_name (canonical naming + round-trip lookup), dev (partial-creation
# reporting), wt (destination validation, branch-base semantics, copy-failure
# propagation) and wt-rm (dirty preflight ordering, refusal cases).
#
# zellij and wtcp are stubbed on PATH and every invocation is logged, so the tests can
# assert *ordering* — notably that a dirty worktree never loses its Zellij session —
# without launching anything. Git is NOT stubbed: real repos are used, because git's own
# refusals (unmerged branch, dirty tree) are part of what's under test.
#
# Run: zsh .scripts/test-wt-functions.sh
set -u

FUNCS="$(cd "${0:h}/.." && pwd)/dot_config/zsh/functions"
[[ -r "$FUNCS" ]] || { print -ru2 -- "cannot read $FUNCS"; exit 1 }

# Isolate git from the real user/system config so tests are reproducible.
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t
REAL_HOME="$HOME"

pass=0 fail=0 OUT="" RC=0
_pass() { print -r -- "  PASS: $1"; pass=$((pass + 1)) }
_fail() { print -r -- "  FAIL: $1"; print -r -- "$OUT" | sed 's/^/    | /'; fail=$((fail + 1)) }
has()    { [[ "$OUT" == *"$1"* ]] && _pass "$2" || _fail "$2" }
hasnt()  { [[ "$OUT" == *"$1"* ]] && _fail "$2" || _pass "$2" }
rc_is()  { [[ "$RC" == "$1" ]] && _pass "$2" || _fail "$2 (rc=$RC)" }
eq()     { [[ "$1" == "$2" ]] && _pass "$3" || _fail "$3 ('$1' != '$2')" }
logged() { [[ "$(<$ZLOG)" == *"$1"* ]] && _pass "$2" || _fail "$2" }
unlogged() { [[ "$(<$ZLOG)" == *"$1"* ]] && _fail "$2" || _pass "$2" }

# --- stubs ------------------------------------------------------------------
# Root every scratch dir at $TMPDIR explicitly: bare `mktemp -d` ignores it on macOS in
# favour of the per-user Darwin temp dir, which sandboxed runners may refuse to write.
TMPROOT="${TMPDIR:-/tmp}"
mkd() { mktemp -d "${TMPROOT%/}/wt-test.XXXXXX" }
STUBS=$(mkd)
trap 'rm -rf "$STUBS" "${ROOTTMP:-}"' EXIT

cat > "$STUBS/zellij" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$ZLOG"
case "$*" in
  "list-sessions -s")            printf '%s' "$MOCK_ZJ_SESSIONS" ;;
  *"attach --create-background"*) exit "$MOCK_ZJ_ATTACH_RC" ;;
  *"action new-tab"*)             exit "$MOCK_ZJ_NEWTAB_RC" ;;
  *"action switch-session"*)      exit "$MOCK_ZJ_SWITCH_RC" ;;
  "delete-session"*)              exit "$MOCK_ZJ_DELETE_RC" ;;
  *) exit 0 ;;
esac
STUB
cat > "$STUBS/wtcp" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$WLOG"
exit "$MOCK_WTCP_RC"
STUB
chmod +x "$STUBS/zellij" "$STUBS/wtcp"
export PATH="$STUBS:$PATH"

# --- fixture ----------------------------------------------------------------
ROOTTMP=""
setup() {   # fresh $HOME with Code/Org/repo, fresh logs, default mock behaviour
  [[ -n "$ROOTTMP" ]] && rm -rf "$ROOTTMP"
  ROOTTMP=$(mkd) || { print -ru2 -- "mktemp failed"; exit 1 }
  ROOTTMP="${ROOTTMP:A}"        # resolve /tmp -> /private/tmp up front, so the paths
  export HOME="$ROOTTMP/home"   # git reports compare equal to the ones we build
  mkdir -p "$HOME/Code/Org"
  REPO="$HOME/Code/Org/repo"
  git init -q -b main "$REPO"
  git -C "$REPO" commit -q --allow-empty -m init
  export ZLOG="$ROOTTMP/zellij.log" WLOG="$ROOTTMP/wtcp.log"
  : > "$ZLOG"; : > "$WLOG"
  export MOCK_ZJ_SESSIONS="" MOCK_ZJ_ATTACH_RC=0 MOCK_ZJ_NEWTAB_RC=0 \
         MOCK_ZJ_SWITCH_RC=0 MOCK_ZJ_DELETE_RC=0 MOCK_WTCP_RC=0
  unset ZELLIJ
}
# run <dir> <command...> — source the functions fresh and run one command in $dir.
# A subshell per scenario keeps zsh options/state from leaking between tests.
run() {
  local dir="$1"; shift
  OUT="$(cd "$dir" && source "$FUNCS" && "$@" 2>&1)"; RC=$?
}
sha() { git -C "$1" rev-parse HEAD 2>/dev/null }

print -r -- "A. _wt_session_name — canonical naming and round-trip lookup"
setup
run "$REPO" _wt_session_name "$REPO"
eq "$OUT" "org--repo" "short path -> org--repo"

# A name over the 60-char cap keeps a hashed tail; the old lookup reversed '--' to '/'
# and could never find these again.
LONGNAME="repo-$(printf 'x%.0s' {1..55})"
git init -q -b main "$HOME/Code/Org/$LONGNAME"
git -C "$HOME/Code/Org/$LONGNAME" commit -q --allow-empty -m init
run "$REPO" _wt_session_name "$HOME/Code/Org/$LONGNAME"
LONGSESS="$OUT"
eq "${#LONGSESS}" "60" "over-long path is capped at 60 chars"
run "$REPO" dev "$LONGSESS"
logged "--session $LONGSESS" "hashed session name round-trips through dev"

# A repo directory containing '--' also broke the reversal.
git init -q -b main "$HOME/Code/Org/od--d"
git -C "$HOME/Code/Org/od--d" commit -q --allow-empty -m init
: > "$ZLOG"
run "$REPO" dev "org--od--d"
logged "--session org--od--d" "repo name containing '--' round-trips through dev"

print -r -- "B. wt — destination validation"
setup
mkdir -p "$HOME/Code/Org/repo-husk/tmp/cache"     # leftover husk: no .git at all
run "$REPO" wt husk
rc_is 1 "husk directory is refused"
has "not a registered worktree" "husk refusal explains why"

setup
run "$REPO" wt feature/foo
rc_is 0 "wt feature/foo succeeds"
run "$REPO" wt feature-foo                         # same slug, different branch
rc_is 1 "slug collision with a different branch is refused"
has "is on 'feature/foo'" "collision refusal names the branch actually checked out"

print -r -- "C. wt — branch base"
setup
run "$REPO" wt a
git -C "$HOME/Code/Org/repo-a" commit -q --allow-empty -m ahead
run "$HOME/Code/Org/repo-a" wt b                   # invoked from inside worktree a
eq "$(sha "$HOME/Code/Org/repo-b")" "$(sha "$HOME/Code/Org/repo-a")" \
   "new branch starts from the caller's HEAD, not main's"
has "branching 'b' from a" "base is reported"

run "$HOME/Code/Org/repo-a" wt c main               # explicit start point
eq "$(sha "$HOME/Code/Org/repo-c")" "$(sha "$REPO")" "explicit start-point wins"

git -C "$HOME/Code/Org/repo-a" checkout -q --detach
run "$HOME/Code/Org/repo-a" wt d
has "branching 'd' from detached@" "detached HEAD base is shown, not warned about"
rc_is 0 "detached HEAD is allowed"

print -r -- "D. wt — .worktreeinclude copy failures"
setup
print -r -- "env.local" > "$REPO/.worktreeinclude"
print -r -- "secret" > "$REPO/env.local"
MOCK_WTCP_RC=1 run "$REPO" wt e
rc_is 1 "wtcp failure propagates"
has "dev $HOME/Code/Org/repo-e" "failure message prints the dev command to recover"
[[ -d "$HOME/Code/Org/repo-e" ]] && _pass "worktree is left in place to recover" \
                                 || _fail "worktree is left in place to recover"

setup
printf 'env.local\nmissing.local\n' > "$REPO/.worktreeinclude"
print -r -- "secret" > "$REPO/env.local"
run "$REPO" wt f
rc_is 0 "a missing .worktreeinclude entry is only a warning"
has "not found in" "missing entry is reported"
logged "--session org--repo-f" "dev still launches after a missing-entry warning"

setup
print -r -- "env.local" > "$REPO/.worktreeinclude"
print -r -- "secret" > "$REPO/env.local"
# Simulating absence needs a stripped PATH, not a moved stub: wtcp is really installed
# on this machine, so hiding the stub just falls through to the real binary.
CLEANP=$(mkd)
# Every external the lifecycle reaches before the wtcp check. wtcp is absent on
# purpose. If a helper later grows a new external dependency, add it here too, or
# this test starts failing for a reason that has nothing to do with wtcp.
for b in env git awk mkdir; do ln -s "$(command -v $b)" "$CLEANP/$b"; done
OUT="$(cd "$REPO" && source "$FUNCS" && export PATH="$CLEANP" && wt g 2>&1)"; RC=$?
rc_is 1 "missing wtcp aborts instead of silently skipping the copy"
has "wtcp is missing" "abort names the missing tool"

print -r -- "E. wt-rm"
setup
run "$REPO" wt h
print -r -- "wip" > "$HOME/Code/Org/repo-h/dirty.txt"
: > "$ZLOG"
run "$REPO" wt-rm h
rc_is 1 "dirty worktree is refused"
unlogged "delete-session" "session is NOT killed before the dirty check"
[[ -d "$HOME/Code/Org/repo-h" ]] && _pass "dirty worktree survives" \
                                 || _fail "dirty worktree survives"

rm "$HOME/Code/Org/repo-h/dirty.txt"
export MOCK_ZJ_SESSIONS="org--repo-h"
: > "$ZLOG"
run "$REPO" wt-rm h
rc_is 0 "clean worktree is removed"
logged "delete-session" "session is stopped"
[[ -d "$HOME/Code/Org/repo-h" ]] && _fail "worktree directory is gone" \
                                 || _pass "worktree directory is gone"
run "$REPO" git branch --list h
eq "$OUT" "" "merged branch is deleted"

setup
run "$REPO" wt i
git -C "$HOME/Code/Org/repo-i" commit -q --allow-empty -m unmerged
run "$REPO" wt-rm i
has "not fully merged" "unmerged branch is kept, never force-deleted"

setup
run "$REPO" wt j
run "$HOME/Code/Org/repo-j" wt-rm j                 # from inside the doomed worktree
rc_is 1 "refuses to remove the worktree it is standing in"

setup
run "$REPO" wt-rm nope
rc_is 1 "unknown worktree is refused"

# A failing `git status` must never read as "clean". Corrupt the linked worktree's index
# specifically: HEAD stays readable, so _wt_assert_worktree still passes and execution
# reaches the dirty check — which is the path under test.
setup
run "$REPO" wt k
print -r -- "garbage" > "$REPO/.git/worktrees/repo-k/index"
export MOCK_ZJ_SESSIONS="org--repo-k"
: > "$ZLOG"
run "$REPO" wt-rm k
rc_is 1 "unreadable git status is refused, not treated as clean"
has "cannot determine whether" "refusal says the state is unknown"
unlogged "delete-session" "session is NOT killed when cleanliness is unknown"
[[ -d "$HOME/Code/Org/repo-k" ]] && _pass "worktree survives an unreadable status" \
                                 || _fail "worktree survives an unreadable status"

# Stopping the session is an invariant, not a courtesy: if it fails, removal must not
# proceed — that is exactly how a live process gets its directory pulled out from under it.
setup
run "$REPO" wt l
export MOCK_ZJ_SESSIONS="org--repo-l" MOCK_ZJ_DELETE_RC=1
run "$REPO" wt-rm l
rc_is 1 "failing to stop the session aborts removal"
has "refusing to remove" "abort explains the session could not be stopped"
[[ -d "$HOME/Code/Org/repo-l" ]] && _pass "worktree survives a failed session stop" \
                                 || _fail "worktree survives a failed session stop"

print -r -- "F. dev — partial session creation is reported accurately"
setup
export ZELLIJ=1 MOCK_ZJ_ATTACH_RC=1
run "$REPO" dev "$REPO"
rc_is 1 "failed creation returns nonzero"
has "failed to create session" "failed creation is not reported as ready"
hasnt "is ready" "does not claim readiness when nothing was created"

setup
export ZELLIJ=1 MOCK_ZJ_NEWTAB_RC=1
run "$REPO" dev "$REPO"
rc_is 1 "failed layout load returns nonzero"
has "dev layout failed" "layout failure is distinguished from a switch failure"

setup
export ZELLIJ=1 MOCK_ZJ_SWITCH_RC=1
run "$REPO" dev "$REPO"
rc_is 1 "failed switch returns nonzero"
has "is ready but switching failed" "switch failure keeps its actionable message"

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

print -r -- "K. hook execution"
setup
mkhook "$REPO" '#!/bin/sh
printf "%s|%s|%s|%s|%s\n" "$1" "$(pwd)" "$WT_MAIN" "$WT_BRANCH" "$WT_SLUG" > "$WT_MAIN/hook.out"
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
[[ "$REC" == "setup|$HOME/Code/Org/repo-k1|$REPO|k1|k1"* ]] \
  && _pass "verb, cwd and WT_* are correct" || _fail "verb, cwd and WT_* are correct"
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

# The hook is executed, not sourced: a variable it sets must not leak out.
setup
mkhook "$REPO" '#!/bin/sh
LEAKED=yes
exit 0'
run "$REPO" wt k4
OUT="$(cd "$REPO" && source "$FUNCS" && \
  _wt_hook_run "$REPO" "$HOME/Code/Org/repo-k4" k4 k4 setup >/dev/null 2>&1; print -r -- "${LEAKED:-unset}")"
eq "$OUT" "unset" "hook runs as a process, not sourced"

export HOME="$REAL_HOME"
print -r -- ""
print -r -- "passed: $pass  failed: $fail"
(( fail == 0 ))
