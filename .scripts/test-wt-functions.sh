#!/usr/bin/env zsh
# Mocked test for the worktree/session helpers and the .worktreehook protocol in
# dot_config/zsh/functions. Fifteen sections, in dependency order — helpers
# first, then the commands composed from them:
#
#   A  _wt_session_name    canonical naming, round-trip lookup through dev
#   B  wt                  destination validation (husks, slug collisions)
#   C  wt                  branch base: caller's HEAD, explicit start point, detached
#   D  wt                  .worktreeinclude copy failures and missing wtcp
#   E  wt-rm               dirty preflight ordering and refusal cases
#   F  dev                 partial session creation is reported accurately
#   G  _wt_git/_wt_primary routing clearance, bare repos, linked worktrees
#   H  _wt_clean           three-state cleanliness, config- and routing-resistant
#   I  locking             helper semantics, then command-level acquire/release
#   J  _wt_hook_check      index + working-tree validation, fail-closed index reads
#   K  _wt_hook_run        interface, subshell isolation, shebang, trust boundary
#   L  _wt_manifest        containment, filtering, missing sources
#   M  wt-prepare          copy/setup recovery path, quoting, wtcp presence
#   N  wt                  creation paths, pre-validation consequences, reopening
#   O  wt-rm               teardown ordering, the three cleanliness checks, retry
#
# zellij and wtcp are stubbed on PATH and every invocation is logged, so the tests can
# assert *ordering* — notably that a dirty worktree never loses its Zellij session —
# without launching anything. Git is NOT stubbed: real repos are used, because git's own
# refusals (unmerged branch, dirty tree) are part of what's under test. The one `git` on
# PATH is the SIGINT delay injector, and it is a pass-through: it decides when a real
# signal lands, then execs the real git with the identical argv.
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
SIGSTUBS=$(mkd)
trap 'rm -rf "$STUBS" "$SIGSTUBS" "${ROOTTMP:-}"' EXIT

cat > "$STUBS/zellij" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$ZLOG"
case "$*" in
  "list-sessions -s")            printf '%s' "$MOCK_ZJ_SESSIONS" ;;
  *"attach --create-background"*) exit "$MOCK_ZJ_ATTACH_RC" ;;
  *"action new-tab"*)             exit "$MOCK_ZJ_NEWTAB_RC" ;;
  *"action switch-session"*)      exit "$MOCK_ZJ_SWITCH_RC" ;;
  "delete-session"*)
    [ -n "${MOCK_ZJ_DELETE_TOUCH:-}" ] && : > "$MOCK_ZJ_DELETE_TOUCH"
    exit "$MOCK_ZJ_DELETE_RC" ;;
  *) exit 0 ;;
esac
STUB
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
chmod +x "$STUBS/zellij" "$STUBS/wtcp"
export PATH="$STUBS:$PATH"

# --- SIGINT delay injector --------------------------------------------------
# A `git` that delivers one real SIGINT to a named pid immediately before
# handing the IDENTICAL argv to the real git. It is not a git stub: git does the
# real work and returns its own status, so nothing about the code under test is
# faked — the shim only decides *when* the signal lands.
#
# It lives in its own directory, prepended to PATH for the signalled child shell
# alone (see sigint_run), and is an inert pass-through unless WT_SIG_MATCH is
# set. The rest of the suite never sees it.
#
# The signal has to be timed from inside the child, not by the parent: nothing
# the parent can observe says which helper the child is currently executing, and
# a sleep-then-kill would be a race — precisely the kind of assertion that
# passes for the wrong reason. Matching on argv puts it inside one named git
# call, deterministically. Delivery is still what §11.7 requires: a real SIGINT
# to one pid, never to the process group, which would take the harness down.
REALGIT="$(whence -p git)" || { print -ru2 -- "cannot locate git"; exit 1 }
cat > "$SIGSTUBS/git" <<STUB
#!/bin/sh
if [ -n "\${WT_SIG_MATCH:-}" ] && [ ! -e "\$WT_SIG_ONCE" ]; then
  case " \$* " in
    *" \$WT_SIG_MATCH "*) : > "\$WT_SIG_ONCE"; kill -INT "\$WT_SIG_TARGET" ;;
  esac
fi
exec $REALGIT "\$@"
STUB
chmod +x "$SIGSTUBS/git"

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
         MOCK_ZJ_SWITCH_RC=0 MOCK_ZJ_DELETE_RC=0 MOCK_WTCP_RC=0 MOCK_ZJ_DELETE_TOUCH=""
  unset ZELLIJ
}
# run <dir> <command...> — source the functions fresh and run one command in $dir.
# A subshell per scenario keeps zsh options/state from leaking between tests.
run() {
  local dir="$1"; shift
  OUT="$(cd "$dir" && source "$FUNCS" && "$@" 2>&1)"; RC=$?
}
# runp <dir> <command...> — like run(), but in THIS shell's own process.
#
# run() wraps the command in a command substitution, so every lifecycle command
# it drives gets a fresh subshell whose exit closes any descriptor the command
# opened. That makes run() structurally incapable of observing the lock:
# neutering all three `always { _wt_unlock }` blocks leaves a run()-only suite
# entirely green, because the kernel cleans up on the subshell's exit either way.
# Section I's command-level tests therefore run in the process that is still
# alive afterwards, capturing output through a file instead of `$(...)`.
#
# The trade-off is that state leaks between runp calls, so each caller does its
# own `setup` first and treats the shell as the long-lived one it is simulating.
runp() {
  local dir="$1"; shift
  local prev="$PWD" tf="$ROOTTMP/runp.out"
  OUT=""; RC=127
  cd "$dir" || return 1
  source "$FUNCS"
  "$@" > "$tf" 2>&1
  RC=$?
  OUT="$(<$tf)"
  cd "$prev"
}
# other_process_can_lock <common-dir> <slug> — "RELEASED" if a SEPARATE process
# can take the lock right now. The only way to observe release from inside the
# shell that ran the command: fcntl locks are per-process, so a same-shell
# reacquisition succeeds whether or not the first was ever released (see
# _wt_lock requirement 3), and an assertion built on it could never fail.
other_process_can_lock() {
  zsh -c "source '$FUNCS'; _wt_lock '$1' '$2' >/dev/null 2>&1 && print -r -- RELEASED"
}
# sigint_run <argv-match> <command...> — run one lifecycle command in a child zsh
# that receives a real SIGINT, by pid, during the first git call whose argv
# contains <argv-match>. An empty match disarms the injector, which is how the
# control runs prove the shim is a transparent pass-through.
#
# The child is driven through a command substitution on purpose: a `&`
# background job inherits SIG_IGN for INT in a non-interactive shell, so the
# signal would simply be discarded and every assertion would pass vacuously. A
# command-substitution child dies of the signal as intended and reports 130,
# while the harness itself is untouched.
#
# SIGFIRED reports whether the injector matched anything at all, so a pattern
# that silently stopped matching cannot be mistaken for a clean interrupt.
SIGFIRED=no
sigint_run() {
  local match="$1"; shift
  local once="$ROOTTMP/sig-once"
  rm -f "$once"
  OUT="$(cd "$REPO" && PATH="$SIGSTUBS:$PATH" WT_SIG_MATCH="$match" WT_SIG_ONCE="$once" \
         zsh -c 'export WT_SIG_TARGET=$$; source "$1"; shift; "$@"' _ "$FUNCS" "$@" 2>&1)"
  RC=$?
  [[ -e "$once" ]] && SIGFIRED=yes || SIGFIRED=no
}
sha() { git -C "$1" rev-parse HEAD 2>/dev/null }
mkhook() {   # mkhook <repo> <body>  — tracked, executable, committed
  print -r -- "$2" > "$1/.worktreehook"
  chmod +x "$1/.worktreehook"
  git -C "$1" add --chmod=+x .worktreehook >/dev/null
  git -C "$1" commit -q -m hook
}

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
# Task 8 rework: the base message now shell-quotes the branch with ${(q-)...}
# instead of hardcoded literal quotes, so a plain name like "b" prints
# unquoted — quoting only appears when actually needed (see section M's
# hostile-branch-name coverage of the same convention in _wt_do_prepare).
has "branching b from a" "base is reported"

run "$HOME/Code/Org/repo-a" wt c main               # explicit start point
eq "$(sha "$HOME/Code/Org/repo-c")" "$(sha "$REPO")" "explicit start-point wins"

git -C "$HOME/Code/Org/repo-a" checkout -q --detach
run "$HOME/Code/Org/repo-a" wt d
has "branching d from detached@" "detached HEAD base is shown, not warned about"
rc_is 0 "detached HEAD is allowed"

print -r -- "D. wt — .worktreeinclude copy failures"
setup
print -r -- "env.local" > "$REPO/.worktreeinclude"
print -r -- "secret" > "$REPO/env.local"
MOCK_WTCP_RC=1 run "$REPO" wt e
rc_is 1 "wtcp failure propagates"
# Task 8 rework: creation now delegates preparation to the shared
# _wt_do_prepare (see wt-prepare), so a copy failure's recovery message is
# _wt_do_prepare's own ("wt-prepare <branch> && wt <branch>"), not wt's old
# inline "dev $dest" — re-running wt-prepare is now the correct next step
# because wt-prepare itself did not exist when this assertion was written.
has "wt-prepare e && wt e" "failure message prints the recovery command"
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

# --- command-level locking (spec §11.5) -------------------------------------
# Everything above tests the helpers in isolation; nothing above drives a
# *command* under contention. That gap was structural, not accidental: see the
# runp() comment. These use runp/other_process_can_lock so the descriptor's
# fate is actually observable.

# 1) A lock held by another process makes every lifecycle command refuse and
#    name the slug. Held here in the test shell, contended from run()'s
#    subshell — a different process, which is the only kind fcntl locks exclude.
#    The target is created first: `wt-rm` and `wt-prepare` refuse an absent
#    directory BEFORE they reach the lock, so an empty fixture would produce the
#    wrong refusal and prove nothing about contention.
setup
CD="$REPO/.git"
run "$REPO" wt z1
rc_is 0 "the contention fixture's target is created"
source "$FUNCS"
_wt_lock "$CD" z1 >/dev/null 2>&1; RC=$?
rc_is 0 "the test shell takes the target lock directly"
run "$REPO" wt z1
rc_is 1 "wt refuses while another process holds the target lock"
has "another lifecycle command is working on 'z1'" "the refusal names the busy slug"
run "$REPO" wt-prepare z1
rc_is 1 "wt-prepare refuses on the same held lock"
has "another lifecycle command is working on 'z1'" "wt-prepare's refusal names the slug"
run "$REPO" wt-rm z1
rc_is 1 "wt-rm refuses on the same held lock"
has "another lifecycle command is working on 'z1'" "wt-rm's refusal names the slug"
[[ -d "$HOME/Code/Org/repo-z1" ]] && _pass "the refused wt-rm removed nothing" \
                                  || _fail "the refused wt-rm removed nothing"
_wt_unlock

# 2) Release after a SUCCESSFUL command, observed from the shell that ran it.
setup
CD="$REPO/.git"
runp "$REPO" wt z2
rc_is 0 "wt succeeds when driven in the test shell's own process"
eq "$(other_process_can_lock "$CD" z2)" "RELEASED" \
   "a completed wt leaves no lock behind in the shell that ran it"

# 3) Release after a FAILED command — spec §11.5, "the lock is released after a
#    failed command, so retry is not blocked". The failure has to happen INSIDE
#    the locked block, so an untracked-but-executable hook is used: `wt` takes
#    the lock, then refuses at pre-validation.
setup
CD="$REPO/.git"
print -r -- '#!/bin/sh
exit 0' > "$REPO/.worktreehook"
chmod +x "$REPO/.worktreehook"          # executable on disk, but untracked: invalid
runp "$REPO" wt z3
rc_is 1 "wt fails inside the locked block"
eq "$(other_process_can_lock "$CD" z3)" "RELEASED" \
   "the lock is released after a failed wt, so a retry is not blocked"

setup
CD="$REPO/.git"
runp "$REPO" wt z4
print -r -- "wip" > "$HOME/Code/Org/repo-z4/dirty.txt"
runp "$REPO" wt-rm z4
rc_is 1 "wt-rm fails inside the locked block"
eq "$(other_process_can_lock "$CD" z4)" "RELEASED" \
   "the lock is released after a failed wt-rm, so a retry is not blocked"

# 4) Real SIGINT (spec §9.4). No INT/TERM trap exists — see the interruption
#    note beside _wt_unlock in dot_config/zsh/functions for why one was removed.
#    What is guaranteed instead is that the interrupt unwinds the whole command,
#    and that the kernel releases the lock along with the shell it takes down.
#
#    The setup hook does the killing because it is the only place that can time
#    the signal to land INSIDE the command. It targets one pid — the probe shell
#    — never the process group, which would take the harness down with it (spec
#    §11.7). Every assertion is then made out here, from state the child cannot
#    fabricate.
#
#    HONEST LIMIT — this covers the non-interactive case only. It proves the
#    interrupt stops the work and that a shell the interrupt kills leaves no
#    lock behind. It cannot reproduce the INTERACTIVE case, where the shell
#    survives its own Ctrl-C and keeps the lock descriptor open: the harness
#    cannot host an interactive shell, and nothing below should be read as
#    covering it. That retention is an accepted, documented cost (spec §9.4),
#    not a tested property.
setup
CD="$REPO/.git"
cat > "$ROOTTMP/int-probe.zsh" <<'PROBE'
source "$1"
export TEST_SIGTARGET=$$          # the hook signals THIS shell, by pid
wt "$2" >/dev/null 2>&1
print -r -- "SURVIVED"
PROBE
# Control, run first and with no signalling hook committed yet: the probe must
# reach its last line unaided. Without this, "SURVIVED is absent" below would be
# satisfied just as well by a probe that never ran at all.
: > "$ZLOG"
OUT="$(cd "$REPO" && zsh "$ROOTTMP/int-probe.zsh" "$FUNCS" z5c 2>&1)"; RC=$?
has "SURVIVED" "control: an uninterrupted wt lets the probe shell reach its last line"
logged "--session org--repo-z5c" "control: the uninterrupted wt reaches dev"

mkhook "$REPO" '#!/bin/sh
[ "$1" = setup ] && kill -INT "$TEST_SIGTARGET"
exit 0'
: > "$ZLOG"
OUT="$(cd "$REPO" && zsh "$ROOTTMP/int-probe.zsh" "$FUNCS" z5 2>&1)"; RC=$?
rc_is 130 "a real SIGINT during wt unwinds the command and the shell running it"
hasnt "SURVIVED" "the interrupted shell does not carry on past the command"
unlogged "--session org--repo-z5" "the interrupted wt never reached dev"
eq "$(other_process_can_lock "$CD" z5)" "RELEASED" \
   "the interrupted shell's death releases the lock, so a retry is not blocked"

print -r -- "J. hook validation"
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
printf "%s|%s|%s|%s|%s|%s\n" "$1" "$(pwd)" "$WT_MAIN" "$WT_WORKTREE" "$WT_BRANCH" "$WT_SLUG" > "$WT_MAIN/hook.out"
read line || line="(no stdin)"
printf "stdin=%s\n" "$line" >> "$WT_MAIN/hook.out"
echo "to-stdout"; echo "to-stderr" >&2
exit 0'
# `</dev/null` is mandatory, not tidiness: this hook blocks in `read` until its
# stdin yields a line or EOF, and `wt` deliberately hands the hook the caller's
# stdin. Run the suite with stdin on a tty or an open pipe — which is what an
# unattended runner or `foo | zsh test-wt-functions.sh` gives it — and this call
# hangs forever. The stdin-inheritance assertion is unaffected: it is proven by
# the explicit `print -r -- "fed" | _wt_hook_run` below, whose hook.out record
# overwrites this one.
run "$REPO" wt k1 </dev/null
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

# --- trust boundary (spec §11.1, Goal 3) ------------------------------------
# "Hook present only in the target branch: never executed" and "Primary-worktree
# hook used even when the target is another branch" are the security guarantee
# of the whole design, and every other fixture in sections J/K runs
# `mkhook "$REPO"` BEFORE branching — so the target worktree always carries a
# byte-identical copy and "which copy ran" is unfalsifiable. Pointing
# _wt_hook_run at "$wt/.worktreehook" passes all of them. These two fixtures put
# the two copies in different places, and each carries a guard asserting the
# split is real, so neither can decay into a fixture that proves nothing.

# 1) Hook committed on the TARGET branch only. The primary never opted in, so
#    nothing may run — a feature branch cannot introduce code that `wt` executes.
setup
git -C "$REPO" checkout -q -b t1
print -r -- '#!/bin/sh
: > "$WT_MAIN/target-branch-hook-ran.marker"
exit 0' > "$REPO/.worktreehook"
chmod +x "$REPO/.worktreehook"
git -C "$REPO" add --chmod=+x .worktreehook >/dev/null
git -C "$REPO" commit -q -m "hook on the target branch only"
git -C "$REPO" checkout -q main         # the primary loses the file with the branch
[[ -e "$REPO/.worktreehook" || -L "$REPO/.worktreehook" ]] \
  && _fail "fixture guard: the primary genuinely carries no hook" \
  || _pass "fixture guard: the primary genuinely carries no hook"
run "$REPO" wt t1
rc_is 0 "a worktree for a branch carrying its own hook is still created"
[[ -x "$HOME/Code/Org/repo-t1/.worktreehook" ]] \
  && _pass "fixture guard: the target worktree genuinely carries an executable hook" \
  || _fail "fixture guard: the target worktree genuinely carries an executable hook"
[[ -f "$REPO/target-branch-hook-ran.marker" ]] \
  && _fail "a hook present only in the target branch is never executed by wt" \
  || _pass "a hook present only in the target branch is never executed by wt"
run "$REPO" _wt_hook_run "$REPO" "$HOME/Code/Org/repo-t1" t1 t1 setup
rc_is 0 "_wt_hook_run treats a target-only hook as not-opted-in, a successful no-op"
[[ -f "$REPO/target-branch-hook-ran.marker" ]] \
  && _fail "a direct _wt_hook_run does not execute the target-only hook either" \
  || _pass "a direct _wt_hook_run does not execute the target-only hook either"

# 2) Hook on the PRIMARY only, with the target branched BEFORE the hook commit,
#    so the target's tree cannot contain it. The primary's copy must still run.
setup
git -C "$REPO" branch t2                # branched before the hook exists
mkhook "$REPO" '#!/bin/sh
: > "$WT_MAIN/primary-hook-ran-$WT_SLUG"
exit 0'
run "$REPO" wt t2
rc_is 0 "a worktree for a branch predating the hook is created and prepared"
[[ -e "$HOME/Code/Org/repo-t2/.worktreehook" || -L "$HOME/Code/Org/repo-t2/.worktreehook" ]] \
  && _fail "fixture guard: the target branch genuinely lacks the hook" \
  || _pass "fixture guard: the target branch genuinely lacks the hook"
[[ -f "$REPO/primary-hook-ran-t2" ]] \
  && _pass "the primary worktree's hook runs even when the target branch lacks it" \
  || _fail "the primary worktree's hook runs even when the target branch lacks it"

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

# Spec §11.3 wants "no Zellij calls, *including with an active session*". The
# n1 fixture above runs with MOCK_ZJ_SESSIONS empty, which is the easy half: a
# regression that stopped or switched the session would plausibly guard on the
# session existing first, and would sail past it. This is the half that matters
# — wt-prepare is documented as safe to run against a live session.
setup
run "$REPO" wt n7
print -r -- "a.env" > "$REPO/.worktreeinclude"; print -r -- "A" > "$REPO/a.env"
mkhook "$REPO" '#!/bin/sh
exit 0'
export MOCK_ZJ_SESSIONS="org--repo-n7"
: > "$ZLOG"
run "$REPO" wt-prepare n7
rc_is 0 "prepare succeeds against an active session"
[[ -f "$HOME/Code/Org/repo-n7/a.env" ]] && _pass "prepare still copies with a session live" \
                                        || _fail "prepare still copies with a session live"
[[ -s "$ZLOG" ]] && _fail "prepare makes no Zellij calls even with an active session" \
                 || _pass "prepare makes no Zellij calls even with an active session"
export MOCK_ZJ_SESSIONS=""

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

# Reopening (spec §7.4, §11.3 "Reopening calls dev with no copy and no setup").
# Nothing else in the suite reopens an existing worktree at all, so a regression
# that re-ran a project's setup hook on every `wt <branch>` would ship green —
# and for an adopting repository that means re-provisioning databases and ports
# on every return to a checkout.
#
# Both side effects are made observable by DELETING their traces after creation:
# a re-run setup recreates the marker, and a re-run copy restores the removed
# a.env. Checking the logs alone would not distinguish "did not copy" from
# "copied over an identical file".
setup
mkhook "$REPO" '#!/bin/sh
: > "$WT_MAIN/setup-ran-$WT_SLUG"
exit 0'
print -r -- "a.env" > "$REPO/.worktreeinclude"; print -r -- "A" > "$REPO/a.env"
run "$REPO" wt o5
rc_is 0 "the worktree is created and prepared once"
[[ -f "$REPO/setup-ran-o5" ]] && _pass "creation ran setup" || _fail "creation ran setup"
[[ -f "$HOME/Code/Org/repo-o5/a.env" ]] && _pass "creation copied the manifest entry" \
                                        || _fail "creation copied the manifest entry"
rm "$REPO/setup-ran-o5" "$HOME/Code/Org/repo-o5/a.env"
: > "$ZLOG"; : > "$WLOG"
run "$REPO" wt o5                        # reopen
rc_is 0 "reopening an existing worktree succeeds"
has "reopening" "the reopen path is announced"
[[ -f "$REPO/setup-ran-o5" ]] && _fail "reopening does not re-run setup" \
                              || _pass "reopening does not re-run setup"
[[ -f "$HOME/Code/Org/repo-o5/a.env" ]] && _fail "reopening does not re-copy the manifest" \
                                        || _pass "reopening does not re-copy the manifest"
[[ -s "$WLOG" ]] && _fail "reopening invokes wtcp not at all" \
                 || _pass "reopening invokes wtcp not at all"
logged "--session org--repo-o5" "reopening still hands off to dev"

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
# Neither assertion above can fail on its own: with cleanliness check 3 deleted
# outright, `git worktree remove` still refuses the corrupt index (rc 128) and
# still leaves the directory. Spec §11.4 wants this fixture to exercise the
# third status call independently, so the discriminating evidence is the
# message — only check 3 says the state is undeterminable, Git says the index is
# broken. Checks 1 and 2 ran before teardown corrupted anything, so this text
# can only have come from check 3.
has "cannot determine whether" "the refusal names check 3, not Git's own"

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

# Retry reruns teardown idempotently (spec §11.4). Everything above stops at the
# failure, so the recovery contract the whole protocol rests on — "retrying
# wt-rm reruns the idempotent teardown hook from the stopped state" — was
# untested. The hook counts its own teardown calls, so a retry that skipped the
# hook (jumping straight to removal because the session was already stopped)
# would leave the count at 1.
#
# The retry runs with MOCK_ZJ_SESSIONS emptied, because that is the real state a
# retry starts from: the first attempt stopped the session before teardown
# failed. Leaving the session mocked as still-present would let a "nothing was
# stopped, so nothing needs tearing down" regression slip through.
setup
mkhook "$REPO" '#!/bin/sh
if [ "$1" = teardown ]; then
  echo call >> "$WT_MAIN/teardown-calls"
  [ -f "$WT_MAIN/fail-teardown" ] && exit 4
fi
exit 0'
run "$REPO" wt q10
: > "$REPO/fail-teardown"
export MOCK_ZJ_SESSIONS="org--repo-q10"
run "$REPO" wt-rm q10
rc_is 1 "the first wt-rm fails at teardown"
[[ -d "$HOME/Code/Org/repo-q10" ]] && _pass "the failed attempt leaves the worktree in place" \
                                   || _fail "the failed attempt leaves the worktree in place"
rm "$REPO/fail-teardown"                 # fix whatever teardown was complaining about
export MOCK_ZJ_SESSIONS=""               # the first attempt already stopped it
run "$REPO" wt-rm q10
rc_is 0 "the retry removes the worktree once teardown is fixed"
eq "$(grep -c call "$REPO/teardown-calls")" "2" "the retry reran teardown rather than skipping it"
[[ -d "$HOME/Code/Org/repo-q10" ]] && _fail "the retry actually removes the worktree" \
                                   || _pass "the retry actually removes the worktree"
export MOCK_ZJ_SESSIONS=""

# A removal that fails after a SUCCESSFUL teardown is spec §9.3's third
# post-shutdown failure mode, and must report the same exact partial state as
# the other two — Git's bare refusal names the obstruction but not whether
# resources were already reclaimed. The obstruction is a git-ignored directory
# stripped of write permission by teardown itself: ignored files leave all three
# cleanliness checks satisfied (so the code under test is genuinely reached),
# while the unwritable directory makes Git's own recursive delete fail.
setup
print -r -- "blocked/" > "$REPO/.gitignore"
git -C "$REPO" add .gitignore >/dev/null; git -C "$REPO" commit -q -m ignore
mkhook "$REPO" '#!/bin/sh
if [ "$1" = teardown ]; then
  mkdir -p "$WT_WORKTREE/blocked"
  : > "$WT_WORKTREE/blocked/pinned"
  chmod 500 "$WT_WORKTREE/blocked"
fi
exit 0'
run "$REPO" wt q11
export MOCK_ZJ_SESSIONS="org--repo-q11"
run "$REPO" wt-rm q11
rc_is 1 "a failed removal after a successful teardown fails wt-rm"
has "worktree kept, session stopped" "the failure reports the exact partial state"
has "Resources may already be reclaimed" "it says resources may already be gone"
has "retry: wt-rm q11" "it offers the fix-and-retry recovery route"
has "wt-prepare q11 && wt q11" "it offers the resume-work recovery route"
[[ -d "$HOME/Code/Org/repo-q11" ]] && _pass "the worktree is kept when removal fails" \
                                   || _fail "the worktree is kept when removal fails"
run "$REPO" git branch --list q11
eq "$OUT" "  q11" "the branch is not deleted when removal fails"
chmod 700 "$HOME/Code/Org/repo-q11/blocked" 2>/dev/null
export MOCK_ZJ_SESSIONS=""

# --- a real SIGINT during wt-rm must destroy nothing -------------------------
#
# This replaces a set of assertions that overrode _wt_clean to return a
# synthetic 130. Those tested a status the code cannot produce, and they stayed
# green across a Critical regression: an INT/TERM trap whose `return 130`
# unwound only the innermost function, so an interrupted _wt_clean reported 0 to
# wt-rm and a DIRTY worktree lost its session to `delete-session --force`.
#
# The replacement runs the real command, takes a real SIGINT delivered by pid,
# and asserts from OUT HERE — from state the child cannot fabricate — rather
# than from any status the child reports. A return code is exactly what the
# regression corrupted, so it is not evidence.
#
# Each scenario interrupts one named git call inside the pre-shutdown region of
# wt-rm (validation, then cleanliness check 1). Both are ahead of the session
# shutdown, the teardown hook, the removal and the branch deletion, so all four
# must be absent afterwards.
#
# The fixture is deliberately CLEAN and its session deliberately present: left
# alone, this exact wt-rm removes the worktree, stops the session, runs teardown
# and deletes the branch. The control below runs it and checks that it does.
# Every assertion in the interrupted runs is therefore load-bearing — it can
# only hold because the interrupt stopped the command.
#
# HONEST LIMIT, restated where it matters most: the child shell dies of the
# signal, so this proves destructive work stops and that process death releases
# the lock. It says nothing about an interactive shell that survives its own
# Ctrl-C and keeps the lock descriptor open; see the note in section I.
sigfixture() {   # sigfixture <slug> — clean worktree, live session, marking hook
  setup
  mkhook "$REPO" '#!/bin/sh
[ "$1" = teardown ] && : > "$WT_MAIN/torn-$WT_SLUG"
exit 0'
  run "$REPO" wt "$1"
  export MOCK_ZJ_SESSIONS="org--repo-$1"
  : > "$ZLOG"
}

# Control: identical fixture, identical child shell, injector disarmed.
sigfixture s0
sigint_run "" wt-rm s0
rc_is 0 "control: wt-rm in the child shell completes with the injector disarmed"
eq "$SIGFIRED" "no" "control: no signal was delivered"
logged "delete-session" "control: the uninterrupted run does stop the session"
[[ -f "$REPO/torn-s0" ]] && _pass "control: the uninterrupted run does run teardown" \
                         || _fail "control: the uninterrupted run does run teardown"
[[ -d "$HOME/Code/Org/repo-s0" ]] && _fail "control: the uninterrupted run does remove the worktree" \
                                  || _pass "control: the uninterrupted run does remove the worktree"

# Scenario 1 — the signal lands in worktree validation. `_wt_primary` runs its
# own `worktree list` first, with no -C, so matching the -C form pins this to
# _wt_assert_worktree.
sigfixture s1
sigint_run "-C $REPO worktree list" wt-rm s1
eq "$SIGFIRED" "yes" "the injector fired inside worktree validation"
rc_is 130 "a SIGINT during validation takes the child shell down"
[[ -d "$HOME/Code/Org/repo-s1" ]] && _pass "interrupted validation leaves the worktree in place" \
                                  || _fail "interrupted validation leaves the worktree in place"
unlogged "delete-session" "interrupted validation stops no session"
[[ -f "$REPO/torn-s1" ]] && _fail "interrupted validation runs no hook" \
                         || _pass "interrupted validation runs no hook"
run "$REPO" git branch --list --format="%(refname:short)" s1
eq "$OUT" "s1" "interrupted validation deletes no branch"

# Scenario 2 — the signal lands in cleanliness check 1. Only _wt_clean passes
# --porcelain=v1, and the injector is one-shot, so this is the first of the
# three checks: the one that still guards the session.
sigfixture s2
sigint_run "status --porcelain=v1" wt-rm s2
eq "$SIGFIRED" "yes" "the injector fired inside a cleanliness check"
rc_is 130 "a SIGINT during cleanliness check 1 takes the child shell down"
[[ -d "$HOME/Code/Org/repo-s2" ]] && _pass "an interrupted check 1 leaves the worktree in place" \
                                  || _fail "an interrupted check 1 leaves the worktree in place"
unlogged "delete-session" "an interrupted check 1 stops no session"
[[ -f "$REPO/torn-s2" ]] && _fail "an interrupted check 1 runs no hook" \
                         || _pass "an interrupted check 1 runs no hook"
run "$REPO" git branch --list --format="%(refname:short)" s2
eq "$OUT" "s2" "an interrupted check 1 deletes no branch"
eq "$(other_process_can_lock "$REPO/.git" s2)" "RELEASED" \
   "the interrupted child's death releases the lock, so a retry is not blocked"
export MOCK_ZJ_SESSIONS=""

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

# --- non-interactive wrappers (invocation-surface design §4.3, §7) -----------
# The wrappers exist because the lifecycle functions are only defined in an
# interactive shell. These cases run them the way an agent would: a bare `zsh`
# with no interactive rc, invoking the file by path.
print -r -- ""
print -r -- "Q. PATH wrappers reach the functions from a non-interactive shell"

WRAPDIR="$(cd "${0:h}/.." && pwd)/dot_local/bin"

# Source mode is NOT asserted: chezmoi derives the deployed 0755 from the
# `executable_` prefix, and the tracked modes in this repo are inconsistent
# (executable_git-forge-guard.sh is 100644, executable_app-cleaner is 100755).
# Step 6 verifies the mode that actually matters, on the deployed file.
for w in wt-rm wt-prepare; do
  [[ -f "$WRAPDIR/executable_$w" && -r "$WRAPDIR/executable_$w" ]] \
    && _pass "$w wrapper source exists and is readable" \
    || _fail "$w wrapper source exists and is readable"
done

# Every other case in this suite pins the repo's own copy of the functions via
# $FUNCS; these wrapper cases must too. Left to fall through to
# `${XDG_CONFIG_HOME:-$HOME/.config}`, they'd read whatever is actually
# deployed on this machine, not the repo under test — green only by
# coincidence that the deployed copy currently matches.
setup
REPOCONF="$ROOTTMP/repoconf"
mkdir -p "$REPOCONF/zsh"
cp "$(cd "${0:h}/.." && pwd)/dot_config/zsh/zshenv"    "$REPOCONF/zsh/zshenv"
cp "$(cd "${0:h}/.." && pwd)/dot_config/zsh/functions" "$REPOCONF/zsh/functions"

# A wrapper with no arguments must reach the function and hit its own usage
# error — proof the dispatch happened, not that the file merely ran.
for w in wt-rm wt-prepare; do
  OUT="$(XDG_CONFIG_HOME="$REPOCONF" zsh "$WRAPDIR/executable_$w" 2>&1)"; RC=$?
  has "usage: $w <branch>" "$w wrapper dispatches to the function"
  rc_is 1 "$w wrapper propagates the function's exit status"
done

# Arguments must survive, including a branch containing a slash. `wt-rm` reports
# the derived sibling path in its does-not-exist refusal, so the slug proves the
# argument arrived intact.
OUT="$(cd "$REPO" && XDG_CONFIG_HOME="$REPOCONF" zsh "$WRAPDIR/executable_wt-rm" 'feature/foo' 2>&1)"; RC=$?
has "repo-feature-foo" "wrapper preserves an argument containing a slash"

# Degenerate functions files. The empty case is the one that exercises the
# recursion guard: the file is readable, so the readability check passes, and
# only `$+functions` stands between the bare call and an infinite PATH loop.
FAKECONF="$ROOTTMP/fakeconf"
mkdir -p "$FAKECONF/zsh"
cp "$(cd "${0:h}/.." && pwd)/dot_config/zsh/zshenv" "$FAKECONF/zsh/zshenv"

# Recursion must be REACHABLE for this case to mean anything: an executable
# `wt-rm` has to exist on PATH. Without the $+functions guard, that plus a
# functions file that defines nothing would make the bare call resolve back to
# this script and recurse without limit.
FAKEBIN="$ROOTTMP/fakebin"
mkdir -p "$FAKEBIN"
# A COPY, chmod +x — never the source, which must stay 644. A symlink to the
# non-executable source yields `permission denied` (126), so the bare call would
# never reach the recursion this guard exists to prevent.
cp "$WRAPDIR/executable_wt-rm" "$FAKEBIN/wt-rm"
chmod +x "$FAKEBIN/wt-rm"

: > "$FAKECONF/zsh/functions"
OUT="$(PATH="$FAKEBIN:$PATH" XDG_CONFIG_HOME="$FAKECONF" \
       zsh "$FAKEBIN/wt-rm" x 2>&1)"; RC=$?
has "did not define wt-rm" "empty functions file is refused, not recursed into"
rc_is 1 "empty functions file exits 1"

rm -f "$FAKECONF/zsh/functions"
OUT="$(XDG_CONFIG_HOME="$FAKECONF" zsh "$WRAPDIR/executable_wt-rm" x 2>&1)"; RC=$?
has "cannot read" "missing functions file is refused"
rc_is 1 "missing functions file exits 1"

export HOME="$REAL_HOME"
print -r -- ""
print -r -- "passed: $pass  failed: $fail"
(( fail == 0 ))
