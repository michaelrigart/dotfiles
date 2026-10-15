#!/usr/bin/env zsh
# Mocked test for the worktree/session helpers and the .worktreehook protocol in
# dot_config/zsh/functions. Nineteen sections, in dependency order — helpers
# first, then the commands composed from them:
#
#   B  wt                  destination validation (husks, slug collisions)
#   C  wt                  branch base: caller's HEAD, explicit start point, detached
#   D  wt                  .worktreeinclude copy failures
#   E  wt-rm               dirty preflight ordering and refusal cases
#   G  _wt_git/_wt_primary routing clearance, bare repos, linked worktrees
#   H  _wt_clean           three-state cleanliness, config- and routing-resistant
#   I  locking             helper semantics, then command-level acquire/release
#   J  _wt_hook_check      index + working-tree validation, fail-closed index reads
#   K  _wt_hook_run        interface, subshell isolation, shebang, trust boundary
#   L  _wt_manifest        containment, filtering, missing sources
#   M  wt-prepare          copy/setup recovery path, quoting
#   N  wt                  creation paths, pre-validation consequences, reopening
#   O  wt-rm               teardown ordering, the three cleanliness checks, retry
#   Q  PATH wrappers       the functions are reachable from a non-interactive shell
#   S  `command` dispatch  a same-named shell function never shadows the wrapper
#   T  wt                  a proven Git lifecycle opens a native Herdr workspace
#   U  wt-rm               Herdr workspace shutdown and persisted-state safety
#   V  wt-rm               live processes still inside the checkout block removal
#   W  wt-rm               the checkout's Codex sessions are released before check 4
#
# Herdr and layout.sh are stubbed on PATH and every invocation is logged, so the
# tests can assert *ordering* — notably that a dirty worktree never loses its terminal
# workspace — without launching anything. Git is NOT stubbed: real repos are used,
# because git's own refusals (unmerged branch, dirty tree) are part of what's under
# test. The one `git` on PATH is the SIGINT delay injector, and it is a pass-through:
# it decides when a real signal lands, then execs the real git with the identical argv.
#
# Run: ./tests/wt-functions.test.sh
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
dlogged() { [[ "$(<$DLOG)" == *"$1"* ]] && _pass "$2" || _fail "$2" }
dunlogged() { [[ "$(<$DLOG)" == *"$1"* ]] && _fail "$2" || _pass "$2" }
hlogged() { [[ "$(<$HLOG)" == *"$1"* ]] && _pass "$2" || _fail "$2" }
hunlogged() { [[ "$(<$HLOG)" == *"$1"* ]] && _fail "$2" || _pass "$2" }

# --- stubs ------------------------------------------------------------------
# Root every scratch dir at $TMPDIR explicitly: bare `mktemp -d` ignores it on macOS in
# favour of the per-user Darwin temp dir, which sandboxed runners may refuse to write.
TMPROOT="${TMPDIR:-/tmp}"
mkd() { mktemp -d "${TMPROOT%/}/wt-test.XXXXXX" }
STUBS=$(mkd)
SIGSTUBS=$(mkd)
FAILSTUBS=$(mkd)
trap 'rm -rf "$STUBS" "$SIGSTUBS" "$FAILSTUBS" "${ROOTTMP:-}"' EXIT

cat > "$STUBS/layout.sh" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$DLOG"
exit "${MOCK_LAYOUT_RC:-0}"
STUB
cat > "$STUBS/herdr" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$HLOG"
session="${HERDR_SESSION:-default}"
[ "${1:-}" = --session ] && session="$2"
closed=0
[ -n "${MOCK_H_CLOSED_FILE:-}" ] && grep -Fqx -- "$session" "$MOCK_H_CLOSED_FILE" 2>/dev/null && closed=1
case "$*" in
  "session list --json")
    printf '%s' "${MOCK_H_SESSION_LIST:-}"
    exit "${MOCK_H_SESSION_RC:-0}" ;;
  *"workspace list")
    if [ "$closed" -eq 1 ]; then
      printf '%s' '{"result":{"workspaces":[]}}'
    elif [ "$session" = team ] && [ -n "${MOCK_H_TEAM_WORKSPACES:-}" ]; then
      printf '%s' "$MOCK_H_TEAM_WORKSPACES"
    else
      printf '%s' "${MOCK_H_WORKSPACES:-}"
    fi
    exit "${MOCK_H_LIST_RC:-0}" ;;
  *"pane list")
    if [ "$closed" -eq 1 ]; then
      printf '%s' '{"result":{"panes":[]}}'
    elif [ "$session" = team ] && [ -n "${MOCK_H_TEAM_PANES:-}" ]; then
      printf '%s' "$MOCK_H_TEAM_PANES"
    else
      printf '%s' "${MOCK_H_PANES:-}"
    fi
    exit "${MOCK_H_LIST_RC:-0}" ;;
  *"workspace close "*)
    [ -n "${MOCK_H_CLOSE_TOUCH:-}" ] && : > "$MOCK_H_CLOSE_TOUCH"
    printf '%s' "${MOCK_H_CLOSE_OUT:-}"
    rc="${MOCK_H_CLOSE_RC:-0}"
    [ "$rc" -eq 0 ] && [ -n "${MOCK_H_CLOSED_FILE:-}" ] && printf '%s\n' "$session" >> "$MOCK_H_CLOSED_FILE"
    exit "$rc" ;;
  *) exit 0 ;;
esac
STUB
cat > "$STUBS/lsof" <<'STUB'
#!/usr/bin/env bash
# Faithful about the one thing that matters: it emits the field format its arguments
# ask for. A stub that ignored -F would let the caller change the wire format without
# a single test noticing, which is exactly the drift section V exists to catch.
#
# MOCK_LSOF_SPEC is one record per line, "pid<TAB>command<TAB>cwd". The cwd column is
# emitted verbatim because it is lsof's *rendering* of a path, not the path. Write it as
# the binary prints it **under LC_ALL=C**, which is what the code under test pins: a
# backslash as \\, a newline as \n, other control characters in caret notation, and every
# byte above 0x7f as \xHH — so a path containing é is written caf\xc3\xa9, not café. A
# fixture that used the raw path would describe a wire format that invocation never
# produces, and would silently simulate an occupant the helper cannot match. MOCK_LSOF_RAW overrides it for malformed output, and the exit
# status is separately controllable: real lsof exits 1 both when it matches nothing and
# when it fails, which is the ambiguity the caller has to resolve.
#
# MOCK_LSOF_BUSY_N and MOCK_LSOF_BUSY_SPEC make the first N calls since $LLOG was last
# emptied answer with the busy spec; after those, calls answer with MOCK_LSOF_SPEC, or
# with nothing at all (a failed read) when MOCK_LSOF_THEN_FAIL is set.
printf '%s\n' "$*" >> "$LLOG"
if [ -n "${MOCK_LSOF_RAW+x}" ]; then
  printf '%b' "$MOCK_LSOF_RAW"
  exit "${MOCK_LSOF_RC:-0}"
fi
case " $* " in
  *" -F0pcnR "*) ;;
  *) echo "lsof stub: unexpected invocation: $*" >&2; exit 1 ;;
esac
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
exit "${MOCK_LSOF_RC:-0}"
STUB
cat > "$STUBS/sleep" <<'STUB'
#!/bin/sh
# Instant and logged: wt-rm's grace period is asserted by its schedule, never waited out.
printf '%s\n' "$*" >> "${SLOG:-/dev/null}"
STUB
chmod +x "$STUBS/layout.sh" "$STUBS/herdr" "$STUBS/lsof" "$STUBS/sleep"
TEARDOWN_SRC="$(cd "${0:h}/.." && pwd)/dot_local/bin/executable_wt-teardown"
[[ -r "$TEARDOWN_SRC" ]] || { print -ru2 -- "cannot read $TEARDOWN_SRC"; exit 2 }
print -r -- "#!/bin/sh
exec zsh '$TEARDOWN_SRC' \"\$@\"" > "$STUBS/wt-teardown"
chmod +x "$STUBS/wt-teardown"
# Never the real daemon. Logs its argv one argument per line, so the --dir value is checked
# as exactly one argument, then answers as MOCK_XRPC_* say: by default exit 0, nothing
# released. MOCK_XRPC_TO_LLOG also marks the call in $LLOG, for ordering against teardown
# and the check-4 scan.
cat > "$STUBS/xreview-rpc" <<'STUB'
#!/bin/sh
{ printf -- '---\n'; for a in "$@"; do printf '%s\n' "$a"; done; } >> "${XLOG:-/dev/null}"
[ -n "${MOCK_XRPC_TO_LLOG:-}" ] && printf 'xreview-rpc\n' >> "$LLOG"
[ -n "${MOCK_XRPC_OUT:-}" ] && printf '%b' "$MOCK_XRPC_OUT"
[ -n "${MOCK_XRPC_ERR:-}" ] && printf '%b' "$MOCK_XRPC_ERR" >&2
[ -n "${MOCK_XRPC_SIGNAL:-}" ] && kill -s "$MOCK_XRPC_SIGNAL" $$
exit "${MOCK_XRPC_RC:-0}"
STUB
chmod +x "$STUBS/xreview-rpc"
export PATH="$STUBS:$PATH"
export DEV_LAYOUT="$STUBS/layout.sh"

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

# --- git call-failure injector ----------------------------------------------
# A second pass-through `git`, in its own directory and prepended to PATH for one test
# at a time. It logs every call whose argv contains WT_FAIL_MATCH and fails the
# WT_FAIL_NTH such call: it runs the real git first (unless WT_FAIL_SKIP is set), then
# exits 128. Every other call passes through to the real git with the identical argv. Like the
# SIGINT shim it fakes nothing about the code under test; it decides only which
# invocation of a repeated read is the one that breaks. With WT_FAIL_SKIP set, the failed
# call never reaches the real git, so a mutating command can be made to fail without its
# side effects. WT_FAIL_MATCH2, WT_FAIL_NTH2 and WT_FAIL_LOG2 are a second slot, so one test
# can fail one call of each of two commands. The second slot always runs the real git,
# because WT_FAIL_SKIP applies only to the first.
#
# That distinction is the point: a helper that checks the status of one call and parses
# the output of another cannot be caught by failing the call it checks. It has to be
# possible to fail the *second* one, and to count how many there were.
cat > "$FAILSTUBS/git" <<STUB
#!/bin/sh
if [ -n "\${WT_FAIL_MATCH:-}" ]; then
  case " \$* " in
    *" \$WT_FAIL_MATCH "*)
      printf '%s\\n' "\$*" >> "\$WT_FAIL_LOG"
      n=\$(wc -l < "\$WT_FAIL_LOG")
      if [ "\$n" -eq "\${WT_FAIL_NTH:-0}" ]; then
        [ -n "\${WT_FAIL_SKIP:-}" ] || $REALGIT "\$@"
        echo "git: injected read failure" >&2
        exit 128
      fi
      ;;
  esac
fi
if [ -n "\${WT_FAIL_MATCH2:-}" ]; then
  case " \$* " in
    *" \$WT_FAIL_MATCH2 "*)
      printf '%s\\n' "\$*" >> "\$WT_FAIL_LOG2"
      n=\$(wc -l < "\$WT_FAIL_LOG2")
      if [ "\$n" -eq "\${WT_FAIL_NTH2:-0}" ]; then
        $REALGIT "\$@"
        echo "git: injected read failure" >&2
        exit 128
      fi
      ;;
  esac
fi
exec $REALGIT "\$@"
STUB
chmod +x "$FAILSTUBS/git"

# --- fixture ----------------------------------------------------------------
ROOTTMP=""
setup() {   # fresh $HOME with Code/Org/repo, fresh logs, default mock behaviour
  unset HERDR_WORKSPACE_ID HERDR_SOCKET_PATH HERDR_SESSION HERDR_ENV
  [[ -n "$ROOTTMP" ]] && rm -rf "$ROOTTMP"
  ROOTTMP=$(mkd) || { print -ru2 -- "mktemp failed"; exit 1 }
  ROOTTMP="${ROOTTMP:A}"        # resolve /tmp -> /private/tmp up front, so the paths
  export HOME="$ROOTTMP/home"   # git reports compare equal to the ones we build
  mkdir -p "$HOME/Code/Org"
  REPO="$HOME/Code/Org/repo"
  git init -q -b main "$REPO"
  git -C "$REPO" commit -q --allow-empty -m init
  export DLOG="$ROOTTMP/layout.log" \
         HLOG="$ROOTTMP/herdr.log" LLOG="$ROOTTMP/lsof.log" SLOG="$ROOTTMP/sleep.log" \
         FLOG="$ROOTTMP/git-fail.log" XLOG="$ROOTTMP/xreview-rpc.log" MOCK_H_CLOSED_FILE="$ROOTTMP/herdr-closed"
  : > "$DLOG"; : > "$HLOG"; : > "$LLOG"; : > "$FLOG"; : > "$SLOG"; : > "$XLOG"; : > "$MOCK_H_CLOSED_FILE"
  export MOCK_LAYOUT_RC=0 MOCK_H_SESSION_LIST='{"sessions":[]}' MOCK_H_SESSION_RC=0 \
         MOCK_H_WORKSPACES='{"result":{"workspaces":[]}}' \
         MOCK_H_PANES='{"result":{"panes":[]}}' MOCK_H_LIST_RC=0 MOCK_H_CLOSE_RC=0 \
         MOCK_H_CLOSE_TOUCH="" MOCK_H_CLOSE_OUT=""
  # One well-formed record for an unrelated cwd. Real lsof scanning every process
  # can never return nothing — this shell's own cwd is always in the answer — so
  # "no records at all" is reserved for the failure the caller must fail closed on.
  export MOCK_LSOF_RC=0 MOCK_LSOF_SPEC="$(lsof_spec 1 launchd /)"
  unset MOCK_LSOF_RAW MOCK_H_TEAM_WORKSPACES MOCK_H_TEAM_PANES \
        MOCK_LSOF_BUSY_N MOCK_LSOF_BUSY_SPEC MOCK_LSOF_THEN_FAIL \
        MOCK_XRPC_RC MOCK_XRPC_OUT MOCK_XRPC_ERR MOCK_XRPC_SIGNAL MOCK_XRPC_TO_LLOG
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
# lock_reason_of <worktree> — the lock reason git records for it, or nothing.
lock_reason_of() {
  git -C "$REPO" worktree list --porcelain | awk -v p="$1" '
    /^worktree /{ cur = substr($0, 10) }
    /^locked/   { if (cur == p) { sub(/^locked ?/, ""); print } }'
}
# lsof_spec <pid> <cmd> <cwd> [...] — build MOCK_LSOF_SPEC rows. The cwd column is
# lsof's rendering of a path, so pass it as lsof would print it: a real backslash as two
# characters, a real newline as the two characters \ and n.
lsof_spec() {
  local -a rows
  while (( $# >= 3 )); do rows+=( "$1"$'\t'"$2"$'\t'"$3" ); shift 3; done
  print -rl -- $rows
}
# session_json <name> <default> <running> — one session-list entry with a socket path.
session_json() {
  print -r -- "{\"default\":$2,\"name\":\"$1\",\"running\":$3,\"session_dir\":\"$ROOTTMP/$1\",\"socket_path\":\"$ROOTTMP/$1.sock\"}"
}
sessions() { local IFS=,; print -r -- "{\"sessions\":[$*]}" }
mkhook() {   # mkhook <repo> <body>  — tracked, executable, committed
  print -r -- "$2" > "$1/.worktreehook"
  chmod +x "$1/.worktreehook"
  git -C "$1" add --chmod=+x .worktreehook >/dev/null
  git -C "$1" commit -q -m hook
}

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
# CP1: a copy that fails stops wt with the recovery message (spec §8).
setup
print -r -- "env.local" > "$REPO/.worktreeinclude"
print -r -- "secret" > "$REPO/env.local"
chmod 000 "$REPO/env.local"
run "$REPO" wt e
chmod 600 "$REPO/env.local"
rc_is 1 "CP1 a failed copy fails wt"
has "entry 'env.local'" "CP1 the failure names the entry that could not be copied"
has "wt-prepare e && wt e" "CP1 the failure prints the recovery command"
[[ -d "$HOME/Code/Org/repo-e" ]] && _pass "CP1 the worktree is left in place to recover" \
                                 || _fail "CP1 the worktree is left in place to recover"

setup
printf 'env.local\nmissing.local\n' > "$REPO/.worktreeinclude"
print -r -- "secret" > "$REPO/env.local"
run "$REPO" wt f
rc_is 0 "a missing .worktreeinclude entry is only a warning"
has "not found in" "missing entry is reported"
dlogged "--worktree $REPO $HOME/Code/Org/repo-f" "dev still launches after a missing-entry warning"

print -r -- "E. wt-rm"
setup
run "$REPO" wt h
print -r -- "wip" > "$HOME/Code/Org/repo-h/dirty.txt"
# A running Herdr session holding a workspace at the checkout. setup()'s default is an
# EMPTY session list, so without this fixture nothing is ever closed and the negative
# assertion below would pass no matter what wt-rm did.
export MOCK_H_SESSION_LIST="{\"sessions\":[{\"default\":true,\"name\":\"default\",\"running\":true,\"session_dir\":\"$ROOTTMP/default\"}]}"
export MOCK_H_WORKSPACES="{\"result\":{\"workspaces\":[{\"workspace_id\":\"wh\",\"worktree\":{\"checkout_path\":\"$HOME/Code/Org/repo-h\"}}]}}"
export MOCK_H_PANES='{"result":{"panes":[]}}'
: > "$HLOG"
run "$REPO" wt-rm h
rc_is 1 "dirty worktree is refused"
hunlogged "workspace close" "the workspace is NOT closed before the dirty check"
[[ -d "$HOME/Code/Org/repo-h" ]] && _pass "dirty worktree survives" \
                                 || _fail "dirty worktree survives"

rm "$HOME/Code/Org/repo-h/dirty.txt"
: > "$HLOG"
run "$REPO" wt-rm h
rc_is 0 "clean worktree is removed"
hlogged "workspace close" "the workspace is closed"
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
has "does not exist." "an unknown worktree keeps the specific refusal"

# A failing `git status` must never read as "clean". Corrupt the linked worktree's index
# specifically: HEAD stays readable, so _wt_assert_worktree still passes and execution
# reaches the dirty check — which is the path under test.
setup
run "$REPO" wt k
print -r -- "garbage" > "$REPO/.git/worktrees/repo-k/index"
export MOCK_H_SESSION_LIST="{\"sessions\":[{\"default\":true,\"name\":\"default\",\"running\":true,\"session_dir\":\"$ROOTTMP/default\"}]}"
export MOCK_H_WORKSPACES="{\"result\":{\"workspaces\":[{\"workspace_id\":\"wk\",\"worktree\":{\"checkout_path\":\"$HOME/Code/Org/repo-k\"}}]}}"
export MOCK_H_PANES='{"result":{"panes":[]}}'
: > "$HLOG"
run "$REPO" wt-rm k
rc_is 1 "unreadable git status is refused, not treated as clean"
has "cannot determine whether" "refusal says the state is unknown"
hunlogged "workspace close" "the workspace is NOT closed when cleanliness is unknown"
[[ -d "$HOME/Code/Org/repo-k" ]] && _pass "worktree survives an unreadable status" \
                                 || _fail "worktree survives an unreadable status"

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
#    The target is created first: `wt-prepare` refuses an absent directory BEFORE
#    it reaches the lock, so an empty fixture would produce the wrong refusal and
#    prove nothing about contention.
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
: > "$DLOG"
OUT="$(cd "$REPO" && zsh "$ROOTTMP/int-probe.zsh" "$FUNCS" z5c 2>&1)"; RC=$?
has "SURVIVED" "control: an uninterrupted wt lets the probe shell reach its last line"
dlogged "--worktree $REPO $HOME/Code/Org/repo-z5c" "control: the uninterrupted wt reaches dev"

mkhook "$REPO" '#!/bin/sh
[ "$1" = setup ] && kill -INT "$TEST_SIGTARGET"
exit 0'
: > "$DLOG"
OUT="$(cd "$REPO" && zsh "$ROOTTMP/int-probe.zsh" "$FUNCS" z5 2>&1)"; RC=$?
rc_is 130 "a real SIGINT during wt unwinds the command and the shell running it"
hasnt "SURVIVED" "the interrupted shell does not carry on past the command"
dunlogged "--worktree $REPO $HOME/Code/Org/repo-z5" "the interrupted wt never reached dev"
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
# unattended runner or `foo | zsh wt-functions.test.sh` gives it — and this call
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
# End to end, because BSD `cp -pR` writes THROUGH an existing destination symlink, to a
# file or a directory. The present-entry filter above is the only thing standing
# between a symlinked destination and a write outside the worktree, so the copy itself
# is run and the symlink's target checked. (A check on _wt_manifest alone passes
# whether or not _wt_do_prepare honours the filter.)
run "$REPO" wt-prepare m6
rc_is 0 "prepare over a destination symlink succeeds"
eq "$(<"$ROOTTMP/elsewhere/t.env")" "UNTOUCHED" "prepare never writes through a destination symlink"
[[ -L "$D/t.env" ]] && _pass "the destination symlink is left in place" || _fail "the destination symlink is left in place"

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
: > "$HLOG"; : > "$DLOG"
run "$REPO" wt-prepare n1
rc_is 0 "prepare succeeds"
[[ -f "$HOME/Code/Org/repo-n1/a.env" ]] && _pass "missing file is copied" || _fail "missing file is copied"
# Assert both logs are EMPTY. A needle-based `hunlogged` would be vacuous here: the
# stubs log their argv, and the question is whether either ran at all.
[[ -s "$HLOG" || -s "$DLOG" ]] && _fail "prepare makes no multiplexer calls" \
                               || _pass "prepare makes no multiplexer calls"

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

# CP2: a failed copy aborts prepare before the setup hook.
setup
run "$REPO" wt n3
print -r -- "a.env" > "$REPO/.worktreeinclude"; print -r -- "A" > "$REPO/a.env"
mkhook "$REPO" '#!/bin/sh
touch "$WT_MAIN/setup-ran"; exit 0'
chmod 000 "$REPO/a.env"
run "$REPO" wt-prepare n3
chmod 600 "$REPO/a.env"
rc_is 1 "CP2 a failed copy fails prepare"
[[ -f "$REPO/setup-ran" ]] && _fail "CP2 setup is skipped after a copy failure" \
                           || _pass "CP2 setup is skipped after a copy failure"

# CP3 (review focus 4): modes survive, and a directory entry arrives whole.
setup
printf 'config/master.key\nsecrets.d\n' > "$REPO/.worktreeinclude"
mkdir -p "$REPO/config" "$REPO/secrets.d/inner"
print -r -- "KEY" > "$REPO/config/master.key"; chmod 600 "$REPO/config/master.key"
print -r -- "IN" > "$REPO/secrets.d/inner/x.env"; chmod 640 "$REPO/secrets.d/inner/x.env"
run "$REPO" wt cp3
rc_is 0 "CP3 a nested file and a directory entry are carried"
eq "$(stat -f %Lp "$HOME/Code/Org/repo-cp3/config/master.key")" "600" "CP3 master.key keeps mode 600"
eq "$(<"$HOME/Code/Org/repo-cp3/secrets.d/inner/x.env")" "IN" "CP3 the directory's nested file arrived"
eq "$(stat -f %Lp "$HOME/Code/Org/repo-cp3/secrets.d/inner/x.env")" "640" "CP3 nested modes survive"

# CP5: overlapping entries carry once; the second never nests a duplicate inside the first.
setup
printf 'secrets.d\nsecrets.d/inner\n' > "$REPO/.worktreeinclude"
mkdir -p "$REPO/secrets.d/inner"
print -r -- "IN" > "$REPO/secrets.d/inner/x.env"
run "$REPO" wt cp5
rc_is 0 "CP5 overlapping entries are carried"
[[ -f "$HOME/Code/Org/repo-cp5/secrets.d/inner/x.env" ]] && _pass "CP5 the nested file arrived" \
                                                         || _fail "CP5 the nested file arrived"
[[ -e "$HOME/Code/Org/repo-cp5/secrets.d/inner/inner" ]] && _fail "CP5 no duplicate nests inside the first copy" \
                                                         || _pass "CP5 no duplicate nests inside the first copy"

# CP4: a partly copied directory entry is removed, so the recovery run copies it again.
setup
run "$REPO" wt cp4
printf 'secrets.d\n' > "$REPO/.worktreeinclude"
mkdir -p "$REPO/secrets.d"
print -r -- "AA" > "$REPO/secrets.d/a.env"
print -r -- "BB" > "$REPO/secrets.d/b.env"
chmod 000 "$REPO/secrets.d/b.env"
run "$REPO" wt-prepare cp4
chmod 600 "$REPO/secrets.d/b.env"
rc_is 1 "CP4 a partly failed directory copy fails prepare"
[[ -e "$HOME/Code/Org/repo-cp4/secrets.d" ]] && _fail "CP4 the partial copy is removed" \
                                             || _pass "CP4 the partial copy is removed"
run "$REPO" wt-prepare cp4
rc_is 0 "CP4 the recovery run succeeds"
eq "$(<"$HOME/Code/Org/repo-cp4/secrets.d/a.env" 2>/dev/null)" "AA" "CP4 the readable file arrived on recovery"
eq "$(<"$HOME/Code/Org/repo-cp4/secrets.d/b.env" 2>/dev/null)" "BB" "CP4 the formerly unreadable file arrived on recovery"

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

# Spec §11.3 wants "no multiplexer calls, *including with an active session*". The
# n1 fixture above runs with no Herdr session at all, which is the easy half: a
# regression that closed or focused the workspace would plausibly guard on it
# existing first, and would sail past it. This is the half that matters — wt-prepare
# is documented as safe to run against a live workspace.
setup
run "$REPO" wt n7
print -r -- "a.env" > "$REPO/.worktreeinclude"; print -r -- "A" > "$REPO/a.env"
mkhook "$REPO" '#!/bin/sh
exit 0'
export MOCK_H_SESSION_LIST="$(sessions "$(session_json default true true)")"
export MOCK_H_WORKSPACES="{\"result\":{\"workspaces\":[{\"workspace_id\":\"wn7\",\"worktree\":{\"checkout_path\":\"$HOME/Code/Org/repo-n7\"}}]}}"
export MOCK_H_PANES='{"result":{"panes":[]}}'
: > "$HLOG"; : > "$DLOG"
run "$REPO" wt-prepare n7
rc_is 0 "prepare succeeds against an active workspace"
[[ -f "$HOME/Code/Org/repo-n7/a.env" ]] && _pass "prepare still copies with a workspace live" \
                                        || _fail "prepare still copies with a workspace live"
[[ -s "$HLOG" || -s "$DLOG" ]] && _fail "prepare makes no multiplexer calls even with an active workspace" \
                               || _pass "prepare makes no multiplexer calls even with an active workspace"

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
: > "$DLOG"
run "$REPO" wt o2
rc_is 0 "creating a worktree for an existing branch succeeds"
[[ -f "$REPO/setup-o2" ]] && _pass "setup runs on the existing-branch path" || _fail "setup runs on the existing-branch path"
dlogged "--worktree $REPO $HOME/Code/Org/repo-o2" "dev is launched after preparation"

setup
git -C "$REPO" branch o3
run "$REPO" wt o3 main
rc_is 1 "start-point with an existing branch is refused"

# Setup failure gates dev.
setup
mkhook "$REPO" '#!/bin/sh
exit 5'
: > "$DLOG"
run "$REPO" wt o4
rc_is 1 "setup failure fails wt"
dunlogged "--worktree" "dev is not launched after a setup failure"
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
: > "$DLOG"
run "$REPO" wt o5                        # reopen
rc_is 0 "reopening an existing worktree succeeds"
has "reopening" "the reopen path is announced"
[[ -f "$REPO/setup-ran-o5" ]] && _fail "reopening does not re-run setup" \
                              || _pass "reopening does not re-run setup"
[[ -f "$HOME/Code/Org/repo-o5/a.env" ]] && _fail "reopening does not re-copy the manifest" \
                                        || _pass "reopening does not re-copy the manifest"
dlogged "--worktree $REPO $HOME/Code/Org/repo-o5" "reopening still hands off to dev"

# Locked at creation (spec §3): a failed setup never reaches dev, which used to be the
# only place the lock was applied.
setup
mkhook "$REPO" '#!/bin/sh
exit 5'
run "$REPO" wt lk1
rc_is 1 "LK1 a failed setup fails wt"
eq "$(lock_reason_of "$HOME/Code/Org/repo-lk1")" "wt-managed; remove with command wt-rm" \
  "LK1 a new branch's worktree is locked from creation"

setup
git -C "$REPO" branch lk2
mkhook "$REPO" '#!/bin/sh
exit 5'
run "$REPO" wt lk2
eq "$(lock_reason_of "$HOME/Code/Org/repo-lk2")" "wt-managed; remove with command wt-rm" \
  "LK2 an existing branch's new worktree is locked from creation"
mkhook "$REPO" '#!/bin/sh
exit 0'
run "$REPO" wt-prepare lk2
rc_is 0 "LK3 wt-prepare works on a worktree locked at creation"
run "$REPO" wt-rm lk2
rc_is 0 "LK4 wt-rm removes a worktree locked at creation"
[[ -d "$HOME/Code/Org/repo-lk2" ]] && _fail "LK4 the locked checkout is gone" \
                                   || _pass "LK4 the locked checkout is gone"

print -r -- "O. wt-rm teardown"
setup
mkhook "$REPO" '#!/bin/sh
[ "$1" = teardown ] && touch "$WT_MAIN/torn-$WT_SLUG"
exit 0'
run "$REPO" wt q1
run "$REPO" wt-rm q1
rc_is 0 "teardown path removes the worktree"
[[ -f "$REPO/torn-q1" ]] && _pass "teardown hook ran" || _fail "teardown hook ran"

# Teardown failure preserves the worktree with its Herdr workspaces closed.
setup
mkhook "$REPO" '#!/bin/sh
[ "$1" = teardown ] && exit 4
exit 0'
run "$REPO" wt q2
run "$REPO" wt-rm q2
rc_is 1 "teardown failure fails wt-rm"
[[ -d "$HOME/Code/Org/repo-q2" ]] && _pass "worktree preserved after teardown failure" || _fail "worktree preserved after teardown failure"

# Hook exit 130 is the interruption proxy.
setup
mkhook "$REPO" '#!/bin/sh
[ "$1" = teardown ] && exit 130
exit 0'
run "$REPO" wt q3
run "$REPO" wt-rm q3
rc_is 1 "hook exit 130 preserves the stopped worktree"
[[ -d "$HOME/Code/Org/repo-q3" ]] && _pass "worktree preserved on interruption proxy" || _fail "worktree preserved on interruption proxy"

# Non-ignored teardown output is caught by check 3.
setup
mkhook "$REPO" '#!/bin/sh
[ "$1" = teardown ] && echo report > "$WT_WORKTREE/teardown-report.txt"
exit 0'
run "$REPO" wt q4
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
run "$REPO" wt q5
run "$REPO" wt-rm q5
rc_is 0 "git-ignored teardown output still allows removal"

# Check 3 fails closed when teardown makes status unreadable.
setup
mkhook "$REPO" '#!/bin/sh
[ "$1" = teardown ] && echo garbage > "$WT_MAIN/.git/worktrees/repo-q6/index"
exit 0'
run "$REPO" wt q6
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

# No matching workspace at all counts as successful shutdown, so retry works.
setup
run "$REPO" wt q7
run "$REPO" wt-rm q7
rc_is 0 "an absent workspace counts as successful shutdown"

# Hook validation happens BEFORE the workspace is closed.
setup
run "$REPO" wt q9
print -r -- '#!/bin/sh' > "$REPO/.worktreehook"; chmod +x "$REPO/.worktreehook"   # untracked
export MOCK_H_SESSION_LIST="{\"sessions\":[{\"default\":true,\"name\":\"default\",\"running\":true,\"session_dir\":\"$ROOTTMP/default\"}]}"
export MOCK_H_WORKSPACES="{\"result\":{\"workspaces\":[{\"workspace_id\":\"wq9\",\"worktree\":{\"checkout_path\":\"$HOME/Code/Org/repo-q9\"}}]}}"
export MOCK_H_PANES='{"result":{"panes":[]}}'
: > "$HLOG"
run "$REPO" wt-rm q9
rc_is 1 "invalid hook refuses wt-rm"
hunlogged "workspace close" "the workspace is not closed when hook config is invalid"

# Retry reruns teardown idempotently (spec §11.4). Everything above stops at the
# failure, so the recovery contract the whole protocol rests on — "retrying
# wt-rm reruns the idempotent teardown hook from the stopped state" — was
# untested. The hook counts its own teardown calls, so a retry that skipped the
# hook (jumping straight to removal because the workspace was already closed)
# would leave the count at 1.
#
# The workspace is live for the FIRST attempt only. The herdr stub records a
# successful close, so the retry sees an empty workspace list — the real state a
# retry starts from, since the first attempt closed the workspace before teardown
# failed. Starting the retry from a still-open workspace would let a "nothing was
# closed, so nothing needs tearing down" regression slip through.
setup
mkhook "$REPO" '#!/bin/sh
if [ "$1" = teardown ]; then
  echo call >> "$WT_MAIN/teardown-calls"
  [ -f "$WT_MAIN/fail-teardown" ] && exit 4
fi
exit 0'
run "$REPO" wt q10
: > "$REPO/fail-teardown"
export MOCK_H_SESSION_LIST="{\"sessions\":[{\"default\":true,\"name\":\"default\",\"running\":true,\"session_dir\":\"$ROOTTMP/default\"}]}"
export MOCK_H_WORKSPACES="{\"result\":{\"workspaces\":[{\"workspace_id\":\"wq10\",\"worktree\":{\"checkout_path\":\"$HOME/Code/Org/repo-q10\"}}]}}"
export MOCK_H_PANES='{"result":{"panes":[]}}'
: > "$HLOG"
run "$REPO" wt-rm q10
hlogged "workspace close" "the first attempt closed the workspace before teardown failed"
rc_is 1 "the first wt-rm fails at teardown"
[[ -d "$HOME/Code/Org/repo-q10" ]] && _pass "the failed attempt leaves the worktree in place" \
                                   || _fail "the failed attempt leaves the worktree in place"
rm "$REPO/fail-teardown"                 # fix whatever teardown was complaining about
run "$REPO" wt-rm q10
rc_is 0 "the retry removes the worktree once teardown is fixed"
eq "$(grep -c call "$REPO/teardown-calls")" "2" "the retry reran teardown rather than skipping it"
[[ -d "$HOME/Code/Org/repo-q10" ]] && _fail "the retry actually removes the worktree" \
                                   || _pass "the retry actually removes the worktree"

# A removal that fails after a SUCCESSFUL teardown. The obstruction is a git-ignored
# directory stripped of write permission by teardown itself: ignored files leave all three
# cleanliness checks satisfied (so the code under test is genuinely reached), while the
# unwritable directory makes Git's own recursive delete fail. Git still deletes the
# registration after that failure, so what is left is an unregistered directory — and the
# message must say so, not "worktree kept" with two routes that both refuse.
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
run "$REPO" wt-rm q11
Q11="$HOME/Code/Org/repo-q11"
rc_is 1 "a failed removal after a successful teardown fails wt-rm"
has "Git's registration of it is removed, but the directory remains and is no longer a worktree" \
    "q11 the failure reports the leftover directory"
has "teardown done; branch q11 kept" "q11 it says teardown ran and the branch is kept"
has "git branch -d q11" "q11 it gives the branch-deletion advice"
hasnt "worktree kept" "q11 it does not claim the worktree was kept"
hasnt "retry: wt-rm q11" "q11 it offers no retry, which would refuse"
hasnt "wt-prepare q11" "q11 it offers no resume route, which would refuse"
[[ -d "$Q11" ]] && _pass "q11 the leftover directory remains" || _fail "q11 the leftover directory remains"
run "$REPO" git worktree list --porcelain
hasnt "$Q11" "q11 Git no longer registers the leftover"
run "$REPO" git branch --list --format='%(refname:short)' q11
eq "$OUT" "q11" "q11 the branch is kept"
chmod 700 "$Q11/blocked" 2>/dev/null
rm -rf "$Q11"
run "$REPO" git branch -d q11
rc_is 0 "q11 the advised cleanup works: the leftover deletes and the merged branch goes with -d"

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
run "$REPO" wt-rm q12
rc_is 1 "Q12 a retry that Git's registration still blocks fails"
has "removing Git's registration of $Q12 failed — it remains; branch q12 kept" "Q12 the recovery failure says the registration remains"
has "retry: wt-rm q12" "Q12 the recovery failure offers the retry"
run "$REPO" git branch --list --format='%(refname:short)' q12
eq "$OUT" "q12" "Q12 the branch is kept by the failed retry"
eq "$(lock_reason_of "$Q12")" "wt-managed; remove with command wt-rm" \
   "Q12 the registration and its lock survive the failed retry"
chmod 700 "$Q12_REG"
run "$REPO" wt-rm q12
rc_is 0 "Q12 a retry finishes the partial removal"
has "is already gone — finishing its removal without re-running teardown" "Q12 the retry says teardown is skipped"
has "reclaim its resources yourself" "Q12 the retry says what it leaves to the user"
eq "$(wc -l < "$REPO/q12-teardowns" | tr -d ' ')" "1" "Q12 teardown ran once, not again on the retry"
run "$REPO" git worktree list --porcelain
hasnt "$Q12" "Q12 the Herdr-locked registration is removed (only --force --force can)"
run "$REPO" git branch --list --format='%(refname:short)' q12
eq "$OUT" "" "Q12 the merged branch is deleted"

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
export MOCK_H_SESSION_LIST="$(sessions "$(session_json default true true)")"
export MOCK_H_WORKSPACES="{\"result\":{\"workspaces\":[
  {\"workspace_id\":\"w15\",\"label\":\"q15\",\"worktree\":{\"checkout_path\":\"$Q15\",\"is_linked_worktree\":true}}]}}"
export MOCK_H_PANES="{\"result\":{\"panes\":[
  {\"workspace_id\":\"w15\",\"pane_id\":\"w15:p1\",\"cwd\":\"$Q15\"}]}}"
: > "$HLOG"
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
has "$Q19 does not exist." "Q19 the plain file gets the existing refusal, not recovery"
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

# q22: both deletes fail. Git removes the checkout's .git link first, so the directory
# that survives is no longer a working checkout, while the registration remains.
setup
print -r -- "blocked/" > "$REPO/.gitignore"
git -C "$REPO" add .gitignore >/dev/null; git -C "$REPO" commit -q -m ignore
mkhook "$REPO" '#!/bin/sh
if [ "$1" = teardown ]; then
  mkdir -p "$WT_WORKTREE/blocked"
  : > "$WT_WORKTREE/blocked/pinned"
  chmod 500 "$WT_WORKTREE/blocked"
  chmod 500 "$(git -C "$WT_WORKTREE" rev-parse --absolute-git-dir)"
fi
exit 0'
run "$REPO" wt q22
Q22="$HOME/Code/Org/repo-q22"
Q22_REG="$REPO/.git/worktrees/repo-q22"
run "$REPO" wt-rm q22
rc_is 1 "q22 a removal that fails on both deletes fails wt-rm"
[[ -d "$Q22" && ! -e "$Q22/.git" ]] && _pass "q22 fixture: the directory survives without its .git link" \
                                    || _fail "q22 fixture: the directory survives without its .git link"
has "the checkout is partly deleted and no longer a working checkout, but Git's registration of it remains" \
    "q22 the failure reports the partly deleted checkout"
has "delete what is left in $Q22 yourself, then finish with: wt-rm q22" "q22 it gives the route that works"
hasnt "worktree kept" "q22 it does not claim the worktree was kept"
hasnt "wt-prepare q22" "q22 it offers no resume route, which would refuse"
eq "$(lock_reason_of "$Q22")" "wt-managed; remove with command wt-rm" "q22 the registration remains, still locked"
chmod 700 "$Q22/blocked" "$Q22_REG"
rm -rf "$Q22"
run "$REPO" wt-rm q22
rc_is 0 "q22 the advised route works: after deleting the leftover, wt-rm finishes"
run "$REPO" git worktree list --porcelain
hasnt "$Q22" "q22 the registration is removed"

# q23: the removal fails before Git touches anything, so a working checkout and its
# registration both remain. "worktree kept" is true here, and so are both routes.
setup
run "$REPO" wt q23
Q23="$HOME/Code/Org/repo-q23"
: > "$FLOG"
# BSD ls colours an executable even when colour is forced, and never a plain file, so the
# .git link is made executable for the one run whose environment forces colour.
chmod +x "$Q23/.git"
OUT="$(builtin cd "$REPO" && source "$FUNCS" \
       && PATH="$FAILSTUBS:$PATH" WT_FAIL_LOG="$FLOG" CLICOLOR=1 CLICOLOR_FORCE=1 WT_FAIL_NTH=1 WT_FAIL_SKIP=1 \
          WT_FAIL_MATCH="worktree remove" \
          wt-rm q23 2>&1)"; RC=$?
rc_is 1 "q23 a removal that fails before deleting anything fails wt-rm"
eq "$(grep -c . "$FLOG")" "1" "q23 fixture: exactly the one remove call was failed"
has "worktree kept, Herdr workspaces closed" "q23 an intact checkout is reported as kept"
hasnt "delete what is left" "q23 decorated ls output never reads as a missing .git link"
has "retry: wt-rm q23" "q23 it offers the retry"
has "wt-prepare q23 && wt q23" "q23 it offers the resume route"
[[ -e "$Q23/.git" ]] && _pass "q23 the checkout is intact" || _fail "q23 the checkout is intact"
chmod -x "$Q23/.git"
run "$REPO" wt-rm q23
rc_is 0 "q23 the advised retry works"
[[ -e "$Q23" ]] && _fail "q23 the retry removes the checkout" || _pass "q23 the retry removes the checkout"

# q24: what remains cannot be read. The removal fails as in Q12, then the injector fails
# the worktree-list read that follows it, which is the last such read wt-rm makes.
setup
mkhook "$REPO" '#!/bin/sh
[ "$1" = teardown ] && chmod 500 "$(git -C "$WT_WORKTREE" rev-parse --absolute-git-dir)"
exit 0'
run "$REPO" wt q24
Q24_REG="$REPO/.git/worktrees/repo-q24"
: > "$FLOG"
OUT="$(builtin cd "$REPO" && source "$FUNCS" \
       && PATH="$FAILSTUBS:$PATH" WT_FAIL_LOG="$FLOG" WT_FAIL_NTH=4 \
          WT_FAIL_MATCH="worktree list --porcelain -z" \
          wt-rm q24 2>&1)"; RC=$?
rc_is 1 "q24 a failed removal whose aftermath cannot be read fails wt-rm"
eq "$(grep -c . "$FLOG")" "4" "q24 fixture: the failed read is the last worktree-list read"
has "cannot be read to tell what remains" "q24 the failure says the state is unknown"
has "branch q24 kept" "q24 it says the branch is kept"
hasnt "worktree kept" "q24 it claims nothing about what is left"
run "$REPO" git branch --list --format='%(refname:short)' q24
eq "$OUT" "q24" "q24 the branch is kept"
chmod 700 "$Q24_REG"

# q25: the surviving checkout's own Git state cannot be confirmed. Its .git link is there,
# but the branch read fails after printing the right answer. That is unknown, never
# "kept", and never advice to delete a registered checkout.
setup
run "$REPO" wt q25
Q25="$HOME/Code/Org/repo-q25"
F2LOG="$ROOTTMP/git-fail2.log"
: > "$FLOG"; : > "$F2LOG"
OUT="$(builtin cd "$REPO" && source "$FUNCS" \
       && PATH="$FAILSTUBS:$PATH" WT_FAIL_LOG="$FLOG" WT_FAIL_NTH=1 WT_FAIL_SKIP=1 \
          WT_FAIL_MATCH="worktree remove" \
          WT_FAIL_LOG2="$F2LOG" WT_FAIL_NTH2=2 \
          WT_FAIL_MATCH2="symbolic-ref --quiet --short HEAD" \
          wt-rm q25 2>&1)"; RC=$?
rc_is 1 "q25 a removal whose leftover cannot be confirmed fails wt-rm"
eq "$(grep -c . "$F2LOG")" "2" "q25 fixture: the failed read is the last branch read"
has "cannot be read to tell what remains" "q25 an unconfirmed checkout is reported as unknown"
hasnt "worktree kept" "q25 it is never reported as kept"
hasnt "delete what is left" "q25 it never advises deleting a registered checkout"
[[ -e "$Q25/.git" ]] && _pass "q25 the checkout is intact" || _fail "q25 the checkout is intact"
run "$REPO" git branch --list --format='%(refname:short)' q25
eq "$OUT" "q25" "q25 the branch is kept"
eq "$(lock_reason_of "$Q25")" "wt-managed; remove with command wt-rm" "q25 the registration remains, still locked"

# q25b: as q25, but the failed read is the checkout's toplevel, which also printed the right
# answer before failing.
setup
run "$REPO" wt q25b
Q25B="$HOME/Code/Org/repo-q25b"
F2LOG="$ROOTTMP/git-fail2.log"
: > "$FLOG"; : > "$F2LOG"
OUT="$(builtin cd "$REPO" && source "$FUNCS" \
       && PATH="$FAILSTUBS:$PATH" WT_FAIL_LOG="$FLOG" WT_FAIL_NTH=1 WT_FAIL_SKIP=1 \
          WT_FAIL_MATCH="worktree remove" \
          WT_FAIL_LOG2="$F2LOG" WT_FAIL_NTH2=2 \
          WT_FAIL_MATCH2="rev-parse --path-format=absolute --show-toplevel" \
          wt-rm q25b 2>&1)"; RC=$?
rc_is 1 "q25b a removal whose toplevel cannot be confirmed fails wt-rm"
eq "$(grep -c . "$F2LOG")" "2" "q25b fixture: the failed read is the last toplevel read"
has "cannot be read to tell what remains" "q25b an unconfirmed checkout is reported as unknown"
hasnt "worktree kept" "q25b it is never reported as kept"
hasnt "delete what is left" "q25b it never advises deleting a registered checkout"
[[ -e "$Q25B/.git" ]] && _pass "q25b the checkout is intact" || _fail "q25b the checkout is intact"
run "$REPO" git branch --list --format='%(refname:short)' q25b
eq "$OUT" "q25b" "q25b the branch is kept"
eq "$(lock_reason_of "$Q25B")" "wt-managed; remove with command wt-rm" "q25b the registration remains, still locked"

# q26: the removal fails before Git touches anything, as in q23, but a listing of the
# directory fails. The .git link is there, yet its absence cannot be proven or disproven by
# a failed read, so the state is unknown: never "kept", never advice to delete.
setup
run "$REPO" wt q26
Q26="$HOME/Code/Org/repo-q26"
LSSTUBS=$(mkd)
printf '#!/bin/sh\nexit 1\n' > "$LSSTUBS/ls"; chmod +x "$LSSTUBS/ls"
: > "$FLOG"
OUT="$(builtin cd "$REPO" && source "$FUNCS" \
       && PATH="$LSSTUBS:$FAILSTUBS:$PATH" WT_FAIL_LOG="$FLOG" WT_FAIL_NTH=1 WT_FAIL_SKIP=1 \
          WT_FAIL_MATCH="worktree remove" \
          wt-rm q26 2>&1)"; RC=$?
rc_is 1 "q26 a removal whose leftover cannot be listed fails wt-rm"
eq "$(grep -c . "$FLOG")" "1" "q26 fixture: exactly the one remove call was failed"
has "cannot be read to tell what remains" "q26 an unlistable checkout is reported as unknown"
hasnt "worktree kept" "q26 it is never reported as kept"
hasnt "delete what is left" "q26 it never advises deleting a registered checkout"
[[ -e "$Q26/.git" ]] && _pass "q26 the checkout is intact" || _fail "q26 the checkout is intact"
run "$REPO" git branch --list --format='%(refname:short)' q26
eq "$OUT" "q26" "q26 the branch is kept"
eq "$(lock_reason_of "$Q26")" "wt-managed; remove with command wt-rm" "q26 the registration remains, still locked"

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
# wt-rm (validation, then cleanliness check 1). Both are ahead of the workspace
# closure, the teardown hook, the removal and the branch deletion, so all four
# must be absent afterwards.
#
# The fixture is deliberately CLEAN and its session deliberately present: left
# alone, this exact wt-rm removes the worktree, closes the workspace, runs
# teardown and deletes the branch. The control below runs it and checks that
# it does.
# Every assertion in the interrupted runs is therefore load-bearing — it can
# only hold because the interrupt stopped the command.
#
# HONEST LIMIT, restated where it matters most: the child shell dies of the
# signal, so this proves destructive work stops and that process death releases
# the lock. It says nothing about an interactive shell that survives its own
# Ctrl-C and keeps the lock descriptor open; see the note in section I.
sigfixture() {   # sigfixture <slug> — clean worktree, live workspace, marking hook
  setup
  mkhook "$REPO" '#!/bin/sh
[ "$1" = teardown ] && : > "$WT_MAIN/torn-$WT_SLUG"
exit 0'
  run "$REPO" wt "$1"
  # A running Herdr session holding a workspace at the checkout. setup() defaults to
  # an EMPTY session list, so without this there is nothing to close and the
  # "closes no workspace" assertions below could not go red.
  export MOCK_H_SESSION_LIST="{\"sessions\":[{\"default\":true,\"name\":\"default\",\"running\":true,\"session_dir\":\"$ROOTTMP/default\"}]}"
  export MOCK_H_WORKSPACES="{\"result\":{\"workspaces\":[{\"workspace_id\":\"ws-$1\",\"worktree\":{\"checkout_path\":\"$HOME/Code/Org/repo-$1\"}}]}}"
  export MOCK_H_PANES='{"result":{"panes":[]}}'
  : > "$HLOG"
}

# Control: identical fixture, identical child shell, injector disarmed.
sigfixture s0
sigint_run "" wt-rm s0
rc_is 0 "control: wt-rm in the child shell completes with the injector disarmed"
eq "$SIGFIRED" "no" "control: no signal was delivered"
hlogged "workspace close" "control: the uninterrupted run does close the workspace"
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
hunlogged "workspace close" "interrupted validation closes no workspace"
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
hunlogged "workspace close" "an interrupted check 1 closes no workspace"
[[ -f "$REPO/torn-s2" ]] && _fail "an interrupted check 1 runs no hook" \
                         || _pass "an interrupted check 1 runs no hook"
run "$REPO" git branch --list --format="%(refname:short)" s2
eq "$OUT" "s2" "an interrupted check 1 deletes no branch"
eq "$(other_process_can_lock "$REPO/.git" s2)" "RELEASED" \
   "the interrupted child's death releases the lock, so a retry is not blocked"

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

# --- `command` defeats function shadowing (invocation-surface design §4.6) --
# Every case above invokes the wrapper by absolute path, which bypasses PATH
# resolution and shell-function lookup entirely — none of them exercise real
# command resolution, which is where the actual hazard lives: a shell FUNCTION
# named wt-rm shadows a PATH wrapper of the same name (functions win the
# lookup), and Claude Code's Bash tool initialises its shell from a snapshot
# that defines wt-rm/wt-prepare as functions — so a bare `wt-rm` there never
# reaches the wrapper, and so never gets its sourcing of zshenv and the
# functions file, its recursion guard, or its dispatch to the function with
# the full lifecycle's guarantees. `command wt-rm` bypasses the function and
# resolves the PATH executable instead. Both halves run inside a
# command-substitution subshell so the shadowing function defined here cannot
# leak into any other case in this file.
print -r -- ""
print -r -- "S. \`command\` defeats a same-named shell function shadowing the wrapper"

SHADOWBIN="$ROOTTMP/shadowbin"
mkdir -p "$SHADOWBIN"
cp "$WRAPDIR/executable_wt-rm" "$SHADOWBIN/wt-rm"
chmod +x "$SHADOWBIN/wt-rm"

OUT="$(
  wt-rm() { print -r -- "SHADOW-RAN"; return 0 }
  PATH="$SHADOWBIN:$PATH" XDG_CONFIG_HOME="$REPOCONF" wt-rm 2>&1
)"; RC=$?
has "SHADOW-RAN" "bare wt-rm resolves the shadowing function, not the PATH wrapper"
hasnt "usage: wt-rm <branch>" "bare wt-rm never reaches the wrapper"

OUT="$(
  wt-rm() { print -r -- "SHADOW-RAN"; return 0 }
  PATH="$SHADOWBIN:$PATH" XDG_CONFIG_HOME="$REPOCONF" command wt-rm 2>&1
)"; RC=$?
has "usage: wt-rm <branch>" "command wt-rm bypasses the function and reaches the wrapper"
hasnt "SHADOW-RAN" "command wt-rm does not run the shadowing function"

print -r -- ""
print -r -- "T. wt — the proven Git lifecycle opens a native Herdr worktree workspace"

setup
run "$REPO" wt feature/herdr
rc_is 0 "wt creates and prepares a new worktree"
NATIVEWT="$HOME/Code/Org/repo-feature-herdr"
[[ -d "$NATIVEWT" ]] && _pass "wt creates the checkout at the expected sibling path" \
                     || _fail "wt creates the checkout at the expected sibling path"
dlogged "--worktree $REPO $NATIVEWT" "wt hands the prepared checkout to Herdr worktree mode"
run "$REPO" git worktree list --porcelain
has "locked wt-managed; remove with command wt-rm" \
  "a Herdr-managed checkout carries the lifecycle ownership lock"
OUT="$(git -C "$REPO" worktree remove --force "$NATIVEWT" 2>&1)"; RC=$?
rc_is 128 "Herdr's one-force native removal cannot bypass the lifecycle lock"
[[ -d "$NATIVEWT" ]] && _pass "the blocked native removal leaves the checkout intact" \
                 || _fail "the blocked native removal leaves the checkout intact"

setup
print -r -- "env.local" > "$REPO/.worktreeinclude"
print -r -- "secret" > "$REPO/env.local"
chmod 000 "$REPO/env.local"
run "$REPO" wt broken
chmod 600 "$REPO/env.local"
rc_is 1 "wt propagates preparation failure"
dunlogged "--worktree" "a half-prepared checkout is not opened in Herdr"
[[ -d "$HOME/Code/Org/repo-broken" ]] \
  && _pass "the failed checkout is preserved for wt-prepare recovery" \
  || _fail "the failed checkout is preserved for wt-prepare recovery"

setup
run "$REPO" wt existing
: > "$DLOG"
run "$REPO" wt existing
rc_is 0 "wt reopens an existing matching worktree"
has "reopening" "wt reports the reopen path"
dlogged "--worktree $REPO $HOME/Code/Org/repo-existing" \
  "reopen returns to the same native Herdr workspace"

# The in-Herdr popup feeds this prompt. It must use the same wt path, not Herdr's
# built-in create action, so copy/setup/locking cannot be bypassed from the TUI.
setup
OUT="$(cd "$REPO" && source "$FUNCS" && print -r -- 'feature/popup' | wt-prompt 2>&1)"; RC=$?
rc_is 0 "wt-prompt creates a worktree from its interactive branch input"
POPUP="$HOME/Code/Org/repo-feature-popup"
[[ -d "$POPUP" ]] && _pass "the popup uses the standard sibling checkout path" \
                      || _fail "the popup uses the standard sibling checkout path"
dlogged "--worktree $REPO $POPUP" "the popup opens the checkout through native Herdr mode"
run "$REPO" git worktree list --porcelain
has "locked wt-managed; remove with command wt-rm" "the popup-created checkout is lifecycle-locked"

setup
OUT="$(cd "$REPO" && source "$FUNCS" && print -r -- '' | wt-prompt 2>&1)"; RC=$?
rc_is 1 "an empty popup branch cancels without creating anything"
has "cancelled" "the empty prompt reports cancellation"

# Opening an ordinary wt-created checkout through dev must add the same lock. Otherwise
# `dev <worktree>` would be the unguarded alternate entrance to native Herdr removal.
setup
run "$REPO" wt direct
DIRECT="$HOME/Code/Org/repo-direct"
run "$REPO" dev "$DIRECT"
rc_is 0 "dev can adopt an existing wt-created checkout"
run "$REPO" git worktree list --porcelain
has "locked wt-managed; remove with command wt-rm" \
  "direct dev adoption adds the same lifecycle ownership lock"

# An arbitrary registered checkout cannot be promised the wt-rm lifecycle: wt-rm
# derives the standard sibling path from the branch name and could never find it.
setup
CUSTOM="$ROOTTMP/custom-checkout"
git -C "$REPO" worktree add -q -b custom "$CUSTOM"
CUSTOM="${CUSTOM:A}"
: > "$DLOG"
run "$REPO" dev "$CUSTOM"
rc_is 1 "dev refuses a linked checkout outside the wt sibling convention"
has "not a wt-managed sibling" "the refusal explains the teardown mismatch"
dunlogged "--worktree" "an unremovable checkout is not opened in Herdr"
OUT="$(git -C "$REPO" worktree list --porcelain)"
hasnt "locked wt-managed" "the arbitrary checkout is not stranded behind our lock"

# A user-owned Git lock is not ours to overwrite or later remove with two forces.
setup
run "$REPO" wt reserved
RESERVED="$HOME/Code/Org/repo-reserved"
# Replace the lifecycle lock wt just took, rather than trying to add a second one:
# `worktree lock` on an already-locked worktree fails and leaves our own reason.
git -C "$REPO" worktree unlock "$RESERVED"
git -C "$REPO" worktree lock --reason "user maintenance" "$RESERVED"
: > "$DLOG"
run "$REPO" dev "$RESERVED"
rc_is 1 "dev refuses a worktree carrying someone else's Git lock"
has "locked for another reason" "the refusal explains why the lock is preserved"
dunlogged "--worktree" "a foreign-locked checkout is never opened in Herdr"

# There is one creation path now, and it always takes ownership: wt-rm is the only
# supported removal route, so a wt worktree left unlocked could be removed by a raw
# `git worktree remove` that skips teardown entirely.
setup
run "$REPO" wt locked-by-default
run "$REPO" git worktree list --porcelain
has "locked wt-managed; remove with command wt-rm" \
  "wt takes lifecycle ownership of every checkout it creates"

# wt-rm is the sole path allowed to cross the ownership lock, and only after its
# existing cleanliness and teardown gates. A normal remove cannot cross this fixture;
# success therefore proves wt-rm used Git's locked-worktree form intentionally.
setup
run "$REPO" wt retire
RETIRE="$HOME/Code/Org/repo-retire"
run "$REPO" wt-rm retire
rc_is 0 "wt-rm retires a Herdr-owned locked checkout"
[[ -d "$RETIRE" ]] && _fail "the Herdr-owned checkout is actually removed" \
                       || _pass "the Herdr-owned checkout is actually removed"

# The double-force path is authorized only by our exact lock reason. A foreign lock
# must stop the lifecycle before either terminal manager is disrupted.
setup
mkhook "$REPO" '#!/bin/sh
[ "$1" = teardown ] && touch "$WT_MAIN/protected-teardown-ran"
exit 0'
run "$REPO" wt protected
PROTECTED="$HOME/Code/Org/repo-protected"
# wt takes the lifecycle ownership lock on every checkout it creates, so a foreign
# lock has to REPLACE it — `worktree lock` on an already-locked worktree fails and
# would leave our own reason in place, turning this into the owned-lock case.
git -C "$REPO" worktree unlock "$PROTECTED"
git -C "$REPO" worktree lock --reason "user maintenance" "$PROTECTED"
export MOCK_H_SESSION_LIST="{\"sessions\":[{\"default\":true,\"name\":\"default\",\"running\":true,\"session_dir\":\"$ROOTTMP/default\"}]}"
export MOCK_H_WORKSPACES="{\"result\":{\"workspaces\":[{\"workspace_id\":\"wp\",\"worktree\":{\"checkout_path\":\"$PROTECTED\"}}]}}"
export MOCK_H_PANES='{"result":{"panes":[]}}'
: > "$HLOG"
run "$REPO" wt-rm protected
rc_is 1 "wt-rm refuses a checkout locked for another reason"
has "locked for another reason" "wt-rm explains that it does not own the lock"
hunlogged "workspace close" "a foreign lock is detected before Herdr shutdown"
[[ -f "$REPO/protected-teardown-ran" ]] && _fail "teardown is skipped for a foreign-locked checkout" \
                                        || _pass "teardown is skipped for a foreign-locked checkout"
[[ -d "$PROTECTED" ]] && _pass "the foreign-locked checkout survives" \
                          || _fail "the foreign-locked checkout survives"
run "$REPO" git worktree list --porcelain
has "$PROTECTED" "the foreign-locked checkout is still a registered worktree"

# The lock state is read once, and the status checked belongs to the read that was
# parsed. Splitting it across two calls — status from the first, records from the
# second — means a read that failed is parsed as though it succeeded, and an empty
# result from a broken read is indistinguishable from a worktree that is not
# registered. Git is real here; only the chosen invocation fails.
setup
run "$REPO" wt lockstate-once
LOCKONCE="$HOME/Code/Org/repo-lockstate-once"
: > "$FLOG"
OUT="$(builtin cd "$REPO" && source "$FUNCS" \
       && PATH="$FAILSTUBS:$PATH" WT_FAIL_LOG="$FLOG" WT_FAIL_NTH=0 \
          WT_FAIL_MATCH="worktree list --porcelain -z" \
          _wt_git_lock_state "$REPO" "$LOCKONCE" 2>&1)"; RC=$?
rc_is 0 "the lifecycle lock on a wt checkout is reported as locked"
eq "$(grep -c . "$FLOG")" "1" "worktree lock state is read in exactly one invocation"

# A read that breaks must say so, even when it produced a syntactically perfect answer
# first. The injector runs the real git — so the target's record is present and says
# "unlocked" — and only then exits nonzero. Trusting the records over the status would
# report a definite, wrong lock state to a caller that removes worktrees.
setup
run "$REPO" wt lockstate-fail
LOCKFAIL="$HOME/Code/Org/repo-lockstate-fail"
: > "$FLOG"
OUT="$(builtin cd "$REPO" && source "$FUNCS" \
       && PATH="$FAILSTUBS:$PATH" WT_FAIL_LOG="$FLOG" WT_FAIL_NTH=1 \
          WT_FAIL_MATCH="worktree list --porcelain -z" \
          _wt_git_lock_state "$REPO" "$LOCKFAIL" 2>&1)"; RC=$?
rc_is 2 "a read that emits valid records and then fails is not trusted"
has "cannot read Git worktree lock state" "the broken read is diagnosed as a read failure"
hasnt "is not a registered worktree" \
  "a broken read is never reported as an unregistered worktree"

print -r -- ""
print -r -- "U. wt-rm — Herdr workspace shutdown and persisted-state safety"

# U1: the workspace whose provenance is the checkout is closed, and removal proceeds.
setup
run "$REPO" wt herdr-close
HCLOSE="$HOME/Code/Org/repo-herdr-close"
export MOCK_H_SESSION_LIST="$(sessions "$(session_json default true true)")"
export MOCK_H_WORKSPACES="{\"result\":{\"workspaces\":[
  {\"workspace_id\":\"w7\",\"label\":\"herdr-close\",\"worktree\":{\"checkout_path\":\"$HCLOSE\",\"is_linked_worktree\":true}}]}}"
export MOCK_H_PANES="{\"result\":{\"panes\":[{\"workspace_id\":\"w7\",\"pane_id\":\"w7:p1\",\"cwd\":\"$HCLOSE/src\"}]}}"
run "$REPO" wt-rm herdr-close
rc_is 0 "U1 wt-rm closes the checkout's own workspace and removes it"
hlogged "workspace close w7" "U1 the workspace whose provenance is the checkout is closed"
[[ -d "$HCLOSE" ]] && _fail "U1 the checkout is removed" || _pass "U1 the checkout is removed"

# U2 (bug 1): a pane of the PRIMARY's workspace that cd'd into the checkout must not get
# the primary's workspace closed. Refuse, and close nothing at all.
setup
mkhook "$REPO" '#!/bin/sh
[ "$1" = teardown ] && touch "$WT_MAIN/foreign-teardown-ran"
exit 0'
run "$REPO" wt foreign-pane
HFOREIGN="$HOME/Code/Org/repo-foreign-pane"
export MOCK_H_SESSION_LIST="$(sessions "$(session_json default true true)")"
export MOCK_H_WORKSPACES="{\"result\":{\"workspaces\":[
  {\"workspace_id\":\"w1\",\"label\":\"Org/repo\",\"worktree\":{\"checkout_path\":\"$REPO\",\"is_linked_worktree\":false}},
  {\"workspace_id\":\"w7\",\"label\":\"foreign-pane\",\"worktree\":{\"checkout_path\":\"$HFOREIGN\",\"is_linked_worktree\":true}}]}}"
export MOCK_H_PANES="{\"result\":{\"panes\":[
  {\"workspace_id\":\"w1\",\"pane_id\":\"w1:p2\",\"cwd\":\"$HFOREIGN/app\"},
  {\"workspace_id\":\"w7\",\"pane_id\":\"w7:p1\",\"cwd\":\"$HFOREIGN\"}]}}"
run "$REPO" wt-rm foreign-pane
rc_is 1 "U2 a pane of another workspace inside the checkout refuses removal"
has "w1:p2" "U2 the refusal names the pane"
has "workspace w1 'Org/repo'" "U2 the refusal names the other workspace"
hunlogged "workspace close" "U2 nothing is closed, not even the checkout's own workspace"
[[ -f "$REPO/foreign-teardown-ran" ]] && _fail "U2 teardown is skipped" || _pass "U2 teardown is skipped"
[[ -d "$HFOREIGN" ]] && _pass "U2 the checkout survives" || _fail "U2 the checkout survives"

# U3: a workspace with no provenance at all (made by hand) is never closed for a pane cwd.
setup
run "$REPO" wt plain-ws
HPLAIN="$HOME/Code/Org/repo-plain-ws"
export MOCK_H_SESSION_LIST="$(sessions "$(session_json default true true)")"
export MOCK_H_WORKSPACES='{"result":{"workspaces":[{"workspace_id":"w9","label":"scratch"}]}}'
export MOCK_H_PANES="{\"result\":{\"panes\":[{\"workspace_id\":\"w9\",\"pane_id\":\"w9:p1\",\"cwd\":\"$HPLAIN/deep\"}]}}"
run "$REPO" wt-rm plain-ws
rc_is 1 "U3 a pane cwd alone never makes a workspace closable"
hunlogged "workspace close" "U3 the provenance-less workspace is not closed"

# U4: a workspace whose provenance is a nested repository inside the checkout refuses.
setup
run "$REPO" wt nested
HNEST="$HOME/Code/Org/repo-nested"
export MOCK_H_SESSION_LIST="$(sessions "$(session_json default true true)")"
export MOCK_H_WORKSPACES="{\"result\":{\"workspaces\":[
  {\"workspace_id\":\"w4\",\"label\":\"vendored\",\"worktree\":{\"checkout_path\":\"$HNEST/vendor/lib\",\"is_linked_worktree\":false}}]}}"
export MOCK_H_PANES='{"result":{"panes":[]}}'
run "$REPO" wt-rm nested
rc_is 1 "U4 a nested repository's workspace refuses removal"
has "inside the checkout" "U4 the refusal says why"
hunlogged "workspace close" "U4 nothing is closed"

# U5: any named session other than $HERDR_SESSION refuses before anything is read or closed.
setup
run "$REPO" wt named
HNAMED="$HOME/Code/Org/repo-named"
export MOCK_H_SESSION_LIST="$(sessions "$(session_json default true true)" "$(session_json team false true)")"
export MOCK_H_WORKSPACES="{\"result\":{\"workspaces\":[{\"workspace_id\":\"w7\",\"worktree\":{\"checkout_path\":\"$HNAMED\"}}]}}"
export MOCK_H_PANES='{"result":{"panes":[]}}'
run "$REPO" wt-rm named
rc_is 1 "U5 a named Herdr session refuses removal"
has "session 'team'" "U5 the refusal names the session"
hunlogged "workspace close" "U5 nothing is closed"
[[ -d "$HNAMED" ]] && _pass "U5 the checkout survives" || _fail "U5 the checkout survives"

# U6: the session named by $HERDR_SESSION is a target alongside the default.
setup
run "$REPO" wt targeted
HTGT="$HOME/Code/Org/repo-targeted"
export MOCK_H_SESSION_LIST="$(sessions "$(session_json default true true)" "$(session_json team false true)")"
export MOCK_H_WORKSPACES="{\"result\":{\"workspaces\":[{\"workspace_id\":\"w7\",\"worktree\":{\"checkout_path\":\"$HTGT\"}}]}}"
export MOCK_H_PANES='{"result":{"panes":[]}}'
HERDR_SESSION=team run "$REPO" wt-rm targeted
rc_is 0 "U6 the HERDR_SESSION session is handled, not refused"
hlogged "--session team workspace close w7" "U6 its own workspace is closed"
hlogged "--session default workspace close w7" "U6 the default session's own workspace is closed too"

# U7: running wt-rm from inside the workspace it would close refuses.
setup
run "$REPO" wt selfclose
HSELF="$HOME/Code/Org/repo-selfclose"
export MOCK_H_SESSION_LIST="$(sessions "$(session_json default true true)")"
export MOCK_H_WORKSPACES="{\"result\":{\"workspaces\":[{\"workspace_id\":\"w7\",\"worktree\":{\"checkout_path\":\"$HSELF\"}}]}}"
export MOCK_H_PANES='{"result":{"panes":[]}}'
HERDR_WORKSPACE_ID=w7 HERDR_SOCKET_PATH="$ROOTTMP/default.sock" run "$REPO" wt-rm selfclose
rc_is 1 "U7 wt-rm refuses to close the workspace it runs in"
has "run wt-rm from another workspace" "U7 the refusal says what to do"
hunlogged "workspace close" "U7 nothing is closed"

# U8: HERDR_SESSION does not hide the caller's own session from the self-close check.
setup
run "$REPO" wt selfclose2
HSELF2="$HOME/Code/Org/repo-selfclose2"
export MOCK_H_SESSION_LIST="$(sessions "$(session_json default true true)" "$(session_json team false true)")"
export MOCK_H_WORKSPACES="{\"result\":{\"workspaces\":[{\"workspace_id\":\"w7\",\"worktree\":{\"checkout_path\":\"$HSELF2\"}}]}}"
export MOCK_H_PANES='{"result":{"panes":[]}}'
export MOCK_H_TEAM_WORKSPACES='{"result":{"workspaces":[]}}' MOCK_H_TEAM_PANES='{"result":{"panes":[]}}'
HERDR_SESSION=team HERDR_WORKSPACE_ID=w7 HERDR_SOCKET_PATH="$ROOTTMP/default.sock" \
  run "$REPO" wt-rm selfclose2
rc_is 1 "U8 the caller's session is found by socket, not by HERDR_SESSION"
hunlogged "workspace close" "U8 nothing is closed"

# U9: the converse — a caller in another session may close the default's workspace w7.
setup
run "$REPO" wt otherses
HOTHER="$HOME/Code/Org/repo-otherses"
export MOCK_H_SESSION_LIST="$(sessions "$(session_json default true true)" "$(session_json team false true)")"
export MOCK_H_WORKSPACES="{\"result\":{\"workspaces\":[{\"workspace_id\":\"w7\",\"worktree\":{\"checkout_path\":\"$HOTHER\"}}]}}"
export MOCK_H_PANES='{"result":{"panes":[]}}'
export MOCK_H_TEAM_WORKSPACES='{"result":{"workspaces":[]}}' MOCK_H_TEAM_PANES='{"result":{"panes":[]}}'
HERDR_SESSION=team HERDR_WORKSPACE_ID=w7 HERDR_SOCKET_PATH="$ROOTTMP/team.sock" \
  run "$REPO" wt-rm otherses
rc_is 0 "U9 a same-numbered workspace in another session is not the caller's"
hlogged "workspace close w7" "U9 the default session's own workspace is closed"

# U10 (review focus 1): provenance reported through a symlinked path is still own.
setup
run "$REPO" wt linked-path
HLINK="$HOME/Code/Org/repo-linked-path"
ln -s "$HOME/Code" "$ROOTTMP/codelink"
export MOCK_H_SESSION_LIST="$(sessions "$(session_json default true true)")"
export MOCK_H_WORKSPACES="{\"result\":{\"workspaces\":[{\"workspace_id\":\"w7\",\"worktree\":{\"checkout_path\":\"$ROOTTMP/codelink/Org/repo-linked-path\"}}]}}"
export MOCK_H_PANES='{"result":{"panes":[]}}'
run "$REPO" wt-rm linked-path
rc_is 0 "U10 provenance through a symlink resolves to the checkout"
hlogged "workspace close w7" "U10 the symlink-reported workspace is closed as own"

# U11 (review focus 5): HERDR_SESSION naming no listed session changes nothing.
setup
run "$REPO" wt ghost
HGHOST="$HOME/Code/Org/repo-ghost"
export MOCK_H_SESSION_LIST="$(sessions "$(session_json default true true)")"
export MOCK_H_WORKSPACES="{\"result\":{\"workspaces\":[{\"workspace_id\":\"w7\",\"worktree\":{\"checkout_path\":\"$HGHOST\"}}]}}"
export MOCK_H_PANES='{"result":{"panes":[]}}'
HERDR_SESSION=ghost run "$REPO" wt-rm ghost
rc_is 0 "U11 a HERDR_SESSION with no matching session is not a refusal"

# U19: with HERDR_SESSION naming another session, the default session is still the one
# read for the default's occupancy. A bare call there would read team and miss w1:p2.
setup
run "$REPO" wt routed
HROUTED="$HOME/Code/Org/repo-routed"
export MOCK_H_SESSION_LIST="$(sessions "$(session_json default true true)" "$(session_json team false true)")"
export MOCK_H_WORKSPACES="{\"result\":{\"workspaces\":[
  {\"workspace_id\":\"w1\",\"label\":\"Org/repo\",\"worktree\":{\"checkout_path\":\"$REPO\"}}]}}"
export MOCK_H_PANES="{\"result\":{\"panes\":[{\"workspace_id\":\"w1\",\"pane_id\":\"w1:p2\",\"cwd\":\"$HROUTED\"}]}}"
export MOCK_H_TEAM_WORKSPACES='{"result":{"workspaces":[]}}' MOCK_H_TEAM_PANES='{"result":{"panes":[]}}'
HERDR_SESSION=team run "$REPO" wt-rm routed
rc_is 1 "U19 the default session is read explicitly even when HERDR_SESSION names another"
has "w1:p2" "U19 the default session's foreign pane is found"
hlogged "--session default workspace list" "U19 the default session is addressed by name"

# U12: a close failure keeps the checkout and skips teardown.
setup
mkhook "$REPO" '#!/bin/sh
[ "$1" = teardown ] && touch "$WT_MAIN/herdr-close-teardown-ran"
exit 0'
run "$REPO" wt herdr-fail
HFAIL="$HOME/Code/Org/repo-herdr-fail"
export MOCK_H_SESSION_LIST="$(sessions "$(session_json default true true)")"
export MOCK_H_WORKSPACES="{\"result\":{\"workspaces\":[{\"workspace_id\":\"w8\",\"worktree\":{\"checkout_path\":\"$HFAIL\"}}]}}"
export MOCK_H_PANES='{"result":{"panes":[]}}' MOCK_H_CLOSE_RC=1
run "$REPO" wt-rm herdr-fail
rc_is 1 "U12 a failed Herdr workspace close aborts removal"
has "could not close Herdr workspace" "U12 the close failure is named"
[[ -f "$REPO/herdr-close-teardown-ran" ]] && _fail "U12 teardown is skipped" || _pass "U12 teardown is skipped"
run "$REPO" git worktree list --porcelain
has "$HFAIL" "U12 the checkout is still a registered worktree"

# U13: an exit-zero error envelope from close is a close failure.
setup
run "$REPO" wt herdr-envelope
HENVELOPE="$HOME/Code/Org/repo-herdr-envelope"
export MOCK_H_SESSION_LIST="$(sessions "$(session_json default true true)")"
export MOCK_H_WORKSPACES="{\"result\":{\"workspaces\":[{\"workspace_id\":\"w8e\",\"worktree\":{\"checkout_path\":\"$HENVELOPE\"}}]}}"
export MOCK_H_PANES='{"result":{"panes":[]}}' \
       MOCK_H_CLOSE_OUT='{"error":{"code":"busy","message":"not closed"}}'
run "$REPO" wt-rm herdr-envelope
rc_is 1 "U13 an exit-zero error envelope from close aborts removal"
[[ -d "$HENVELOPE" ]] && _pass "U13 the checkout survives" || _fail "U13 the checkout survives"

# U14: dirt flushed by closing the own workspace is caught by check 2.
setup
mkhook "$REPO" '#!/bin/sh
[ "$1" = teardown ] && touch "$WT_MAIN/herdr-flush-teardown-ran"
exit 0'
run "$REPO" wt herdr-flush
HFLUSH="$HOME/Code/Org/repo-herdr-flush"
export MOCK_H_SESSION_LIST="$(sessions "$(session_json default true true)")"
export MOCK_H_WORKSPACES="{\"result\":{\"workspaces\":[{\"workspace_id\":\"w9\",\"worktree\":{\"checkout_path\":\"$HFLUSH\"}}]}}"
export MOCK_H_PANES="{\"result\":{\"panes\":[{\"workspace_id\":\"w9\",\"pane_id\":\"w9:p1\",\"cwd\":\"$HFLUSH/deep\"}]}}"
export MOCK_H_CLOSE_TOUCH="$HFLUSH/flushed-by-herdr.txt"
run "$REPO" wt-rm herdr-flush
rc_is 1 "U14 dirt flushed by Herdr shutdown is caught"
has "closing Herdr workspaces left changes" "U14 check 2 reports the flush"
[[ -f "$REPO/herdr-flush-teardown-ran" ]] && _fail "U14 teardown does not run" || _pass "U14 teardown does not run"

# U15: a stopped default session that remembers the checkout refuses.
setup
run "$REPO" wt herdr-stopped
HSTOP="$HOME/Code/Org/repo-herdr-stopped"
mkdir -p "$ROOTTMP/default"
print -r -- "{\"version\":3,\"workspaces\":[{\"id\":\"w10\",\"tabs\":[{\"panes\":{\"1\":{\"cwd\":\"$HSTOP\"}}}]}]}" \
  > "$ROOTTMP/default/session.json"
export MOCK_H_SESSION_LIST="$(sessions "$(session_json default true false)")"
run "$REPO" wt-rm herdr-stopped
rc_is 1 "U15 persisted state in the stopped default session blocks removal"
has "stopped Herdr session 'default'" "U15 the refusal identifies the session"
has "Start it with: herdr" "U15 the refusal gives the recovery command"
[[ -d "$HSTOP" ]] && _pass "U15 the checkout survives" || _fail "U15 the checkout survives"

# U16: unrelated stopped state does not block removal.
setup
run "$REPO" wt unrelated-state
UNRELATED="$HOME/Code/Org/repo-unrelated-state"
mkdir -p "$ROOTTMP/default"
print -r -- '{"version":3,"workspaces":[{"id":"w1","tabs":[{"panes":{"1":{"cwd":"/somewhere/else"}}}]}]}' \
  > "$ROOTTMP/default/session.json"
export MOCK_H_SESSION_LIST="$(sessions "$(session_json default true false)")"
run "$REPO" wt-rm unrelated-state
rc_is 0 "U16 unrelated stopped Herdr state does not block removal"

# U17: invalid session discovery fails closed before anything is disrupted.
setup
mkhook "$REPO" '#!/bin/sh
[ "$1" = teardown ] && touch "$WT_MAIN/bad-state-teardown-ran"
exit 0'
run "$REPO" wt bad-herdr-state
BADSTATE="$HOME/Code/Org/repo-bad-herdr-state"
export MOCK_H_SESSION_LIST='not-json'
run "$REPO" wt-rm bad-herdr-state
rc_is 1 "U17 invalid Herdr session discovery fails closed"
has "invalid session list" "U17 the malformed response is diagnosed"
[[ -f "$REPO/bad-state-teardown-ran" ]] && _fail "U17 teardown is skipped" || _pass "U17 teardown is skipped"

# U18: running-but-unreachable is not "stopped".
setup
run "$REPO" wt unreachable-herdr
UNREACHABLE="$HOME/Code/Org/repo-unreachable-herdr"
export MOCK_H_SESSION_LIST="$(sessions "$(session_json default true true)")"
export MOCK_H_WORKSPACES='{"error":{"code":"server_not_running","message":"not reachable"}}'
run "$REPO" wt-rm unreachable-herdr
rc_is 1 "U18 a running-but-unreachable Herdr session fails closed"
has "reported running but its API is unreachable" "U18 the discrepancy is explicit"
[[ -d "$UNREACHABLE" ]] && _pass "U18 the checkout survives" || _fail "U18 the checkout survives"

# U20: a refusal found only in the SECOND target session still blocks every close. The
# default session's own w7 must stay open.
setup
run "$REPO" wt second-ses
HSECOND="$HOME/Code/Org/repo-second-ses"
export MOCK_H_SESSION_LIST="$(sessions "$(session_json default true true)" "$(session_json team false true)")"
export MOCK_H_WORKSPACES="{\"result\":{\"workspaces\":[{\"workspace_id\":\"w7\",\"worktree\":{\"checkout_path\":\"$HSECOND\"}}]}}"
export MOCK_H_PANES='{"result":{"panes":[]}}'
export MOCK_H_TEAM_WORKSPACES='{"result":{"workspaces":[{"workspace_id":"w5","label":"scratch"}]}}'
export MOCK_H_TEAM_PANES="{\"result\":{\"panes\":[{\"workspace_id\":\"w5\",\"pane_id\":\"w5:p3\",\"cwd\":\"$HSECOND/lib\"}]}}"
HERDR_SESSION=team run "$REPO" wt-rm second-ses
rc_is 1 "U20 a foreign pane in the second session refuses removal"
has "w5:p3" "U20 the refusal names the pane"
has "session 'team'" "U20 the refusal names the session"
hunlogged "workspace close" "U20 nothing is closed in either session"
[[ -d "$HSECOND" ]] && _pass "U20 the checkout survives" || _fail "U20 the checkout survives"

# U21: a stopped second session that remembers the checkout blocks every close too.
setup
run "$REPO" wt second-stopped
HSTOP2="$HOME/Code/Org/repo-second-stopped"
mkdir -p "$ROOTTMP/team"
print -r -- "{\"version\":3,\"workspaces\":[{\"id\":\"w3\",\"tabs\":[{\"panes\":{\"1\":{\"cwd\":\"$HSTOP2\"}}}]}]}" \
  > "$ROOTTMP/team/session.json"
export MOCK_H_SESSION_LIST="$(sessions "$(session_json default true true)" "$(session_json team false false)")"
export MOCK_H_WORKSPACES="{\"result\":{\"workspaces\":[{\"workspace_id\":\"w7\",\"worktree\":{\"checkout_path\":\"$HSTOP2\"}}]}}"
export MOCK_H_PANES='{"result":{"panes":[]}}'
HERDR_SESSION=team run "$REPO" wt-rm second-stopped
rc_is 1 "U21 a stopped second session remembering the checkout refuses removal"
has "stopped Herdr session 'team'" "U21 the refusal identifies the session"
has "Start it with: herdr session attach team" "U21 the refusal gives the attach command"
hunlogged "workspace close" "U21 nothing is closed in either session"
[[ -d "$HSTOP2" ]] && _pass "U21 the checkout survives" || _fail "U21 the checkout survives"

# U22: the stopped default session is listed FIRST and the running one LAST, so the
# caller's `session_dir` still holds the running session's directory when the stopped one
# is inspected. `_wt_stopped_herdr_has_checkout` must read the state under its own $2; a
# combined `local` line would read the caller's directory and fail open.
setup
run "$REPO" wt stopped-first
HSTOP3="$HOME/Code/Org/repo-stopped-first"
mkdir -p "$ROOTTMP/default"
print -r -- "{\"version\":3,\"workspaces\":[{\"id\":\"w3\",\"tabs\":[{\"panes\":{\"1\":{\"cwd\":\"$HSTOP3\"}}}]}]}" \
  > "$ROOTTMP/default/session.json"
export MOCK_H_SESSION_LIST="$(sessions "$(session_json default true false)" "$(session_json team false true)")"
export MOCK_H_TEAM_WORKSPACES='{"result":{"workspaces":[]}}'
export MOCK_H_TEAM_PANES='{"result":{"panes":[]}}'
HERDR_SESSION=team run "$REPO" wt-rm stopped-first
rc_is 1 "U22 a stopped default session listed before a running one still refuses removal"
has "stopped Herdr session 'default'" "U22 the refusal identifies the stopped session"
hunlogged "workspace close" "U22 nothing is closed"
[[ -d "$HSTOP3" ]] && _pass "U22 the checkout survives" || _fail "U22 the checkout survives"

# Library functions must use `builtin cd`: they must not depend on whatever an interactive
# shell binds `cd` to, because the `zsh -ic` shells that Herdr popups run never reach a
# prompt.
OUT="$(grep -nE '(^|[^[:alnum:]_.])cd ' "$FUNCS" | grep -vE 'builtin cd|command cd' | grep -vE '^[0-9]+: *#')"
[[ -z "$OUT" ]] \
  && _pass "library functions use builtin cd, never alias-expandable bare cd" \
  || _fail "library functions use builtin cd, never alias-expandable bare cd"

print -r -- ""
print -r -- "V. wt-rm — a live process inside the checkout blocks removal"

# The husk this guards against: closing a Herdr workspace escalates SIGHUP → SIGTERM →
# SIGKILL over roughly half a second across the pane's process group, so everything
# still in that group dies. The signal follows group membership, not ancestry, so a
# process that has left for a session of its own — setsid, a
# double-forked daemon, anything a project starts detached — survives that, keeps its
# cwd inside the checkout, and writes the directory back into existence after
# `git worktree remove` has deleted it. Herdr's own state cannot see such a process:
# it is no longer in any pane. The OS is the only remaining witness.
setup
run "$REPO" wt live-cwd
LIVE="$HOME/Code/Org/repo-live-cwd"
export MOCK_LSOF_SPEC="$(lsof_spec 1 launchd / 4242 redis-server "$LIVE")"
run "$REPO" wt-rm live-cwd
rc_is 1 "a process whose cwd is the checkout blocks removal"
has "still in use by a running process" "the refusal names the reason"
has "4242" "the refusal names the pid so it can be stopped"
has "redis-server" "the refusal names the command"
[[ -d "$LIVE" ]] && _pass "the checkout survives a live process" \
                      || _fail "the checkout survives a live process"
run "$REPO" git worktree list --porcelain
has "$LIVE" "the checkout is still a registered worktree after the refusal"

# A daemon almost never sits at the top of the checkout; it sits in log/, tmp/ or a
# service subdirectory. Matching only the exact path would miss every realistic case.
setup
run "$REPO" wt live-deep
DEEP="$HOME/Code/Org/repo-live-deep"
export MOCK_LSOF_SPEC="$(lsof_spec 77 sidekiq "$DEEP/log/nested")"
run "$REPO" wt-rm live-deep
rc_is 1 "a process whose cwd is below the checkout blocks removal"
[[ -d "$DEEP" ]] && _pass "the checkout survives a process nested inside it" \
                      || _fail "the checkout survives a process nested inside it"

# Sibling worktrees of the same repo differ by a suffix on one path — repo-a and
# repo-a-extra live next to each other by construction. A plain string-prefix test
# would let a process in one worktree veto removal of the other forever.
setup
run "$REPO" wt live-sib
SIB="$HOME/Code/Org/repo-live-sib"
export MOCK_LSOF_SPEC="$(lsof_spec 90 nvim "${SIB}-extra" 91 nvim "${SIB}x/deep")"
run "$REPO" wt-rm live-sib
rc_is 0 "a process in a sibling path that merely shares a prefix does not block removal"
[[ -d "$SIB" ]] && _fail "the checkout is removed when only siblings are busy" \
                     || _pass "the checkout is removed when only siblings are busy"

# Closing a workspace ends some processes only after a delay, so check 4 re-scans for up
# to 5 s before refusing, and the schedule is the assertion. (Codex's daemon keeps a
# thread's MCP servers for ~60 s, far beyond this; section W covers how wt-rm frees them.)
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
: > "$LLOG"
run "$REPO" wt-rm grace-stays
rc_is 1 "a process still there after the grace period blocks removal"
has "still in use by a running process after waiting 5 s" "the refusal says it waited"
eq "$(wc -l < "$SLOG" | tr -d ' ')" "10" "it polled exactly ten times"
eq "$(sort -u "$SLOG")" "0.5" "every poll sleeps 0.5 s"
eq "$(grep -c . "$LLOG")" "11" "it scans once more after the last sleep"
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

# Ordering is the whole design of this check. Stopping project services is exactly
# what .worktreehook teardown is for, so scanning before teardown would refuse every
# repository that does the right thing. The scan belongs after teardown, where the
# invariant is "everything that should have stopped has stopped", and before Git
# deletes any files.
setup
mkhook "$REPO" '#!/bin/sh
[ "$1" = teardown ] && echo teardown-hook >> "$LLOG"
exit 0'
run "$REPO" wt live-order
run "$REPO" wt-rm live-order
rc_is 0 "the ordering fixture removes the worktree normally"
eq "$(sed -n 1p "$LLOG")" "teardown-hook" "teardown runs before the process scan"
[[ "$(sed -n 2p "$LLOG")" == *"-F"* ]] && _pass "the process scan runs after teardown" \
                                        || _fail "the process scan runs after teardown"

# Fail closed, like every other unverifiable state in this lifecycle: an unreadable
# answer is not the same as an empty one.
setup
run "$REPO" wt no-teardown
NOTD="$HOME/Code/Org/repo-no-teardown"
NOTDP=$(mkd)
for b in env git mkdir mktemp rm tee grep; do ln -s "$(command -v $b)" "$NOTDP/$b"; done
ln -s "$STUBS/xreview-rpc" "$NOTDP/xreview-rpc"   # the release must pass to reach check 4
OUT="$(cd "$REPO" && source "$FUNCS" && export PATH="$NOTDP" && wt-rm no-teardown 2>&1)"; RC=$?
rc_is 1 "a missing wt-teardown aborts removal instead of skipping the scan"
has "could not scan for processes" "the abort says the scan could not run"
[[ -d "$NOTD" ]] && _pass "the checkout survives when processes cannot be scanned" \
                 || _fail "the checkout survives when processes cannot be scanned"

# Real lsof scanning every process always reports something — the running shell's own
# cwd is in the answer. Nothing at all therefore means the scan failed, not that the
# machine is idle, and treating it as "clean" would disable the guard silently.
setup
run "$REPO" wt lsof-empty
EMPTY="$HOME/Code/Org/repo-lsof-empty"
export MOCK_LSOF_SPEC=""
run "$REPO" wt-rm lsof-empty
rc_is 1 "an empty process listing fails closed rather than reading as idle"
has "could not read the process list" "the empty listing is diagnosed as a failure"
[[ -d "$EMPTY" ]] && _pass "the checkout survives an empty process listing" \
                       || _fail "the checkout survives an empty process listing"

# The status that matters is the one belonging to the listing actually parsed. Reading
# the listing in a second, unchecked invocation means a scan that failed *after*
# emitting some of its records is indistinguishable from a clean checkout — the records
# it never got to is exactly where the occupant would have been.
setup
run "$REPO" wt lsof-once
ONCE="$HOME/Code/Org/repo-lsof-once"
run "$REPO" wt-rm lsof-once
rc_is 0 "the single-invocation fixture removes the worktree normally"
eq "$(grep -c . "$LLOG")" "1" "the process list is read in exactly one invocation"

# lsof exits nonzero both when it matches nothing and when it fails, but this
# invocation scans every process rather than a path, so nonzero can only be failure.
# Records in hand do not redeem it: a listing that stopped early is not a short listing.
setup
run "$REPO" wt lsof-rc
LSOFRC="$HOME/Code/Org/repo-lsof-rc"
export MOCK_LSOF_SPEC="$(lsof_spec 1 launchd / 4321 halfway-daemon "$LSOFRC")" MOCK_LSOF_RC=1
run "$REPO" wt-rm lsof-rc
rc_is 1 "a nonzero lsof exit fails closed even when it produced well-formed records"
has "could not read the process list" "the failed scan is diagnosed"
hasnt "halfway-daemon" "records from a failed scan are not reported as findings"
[[ -d "$LSOFRC" ]] && _pass "the checkout survives a failed process scan" \
                        || _fail "the checkout survives a failed process scan"

# --- squash-merged branches -------------------------------------------------
#
# `git branch -d` tests ancestry, not content. A squash-merge rewrites the branch
# into one new commit on the base, so none of the branch's own commits are
# ancestors of it and -d refuses — even though every line of the work is already
# in. GitLab squash-merges by default, so this is the normal end of an MR here,
# not an edge case. wt-rm asks the stronger question instead: does merging this
# branch into the base still change anything? If not, the branch is spent.

setup
run "$REPO" wt sq1
print -r -- "sq1" > "$HOME/Code/Org/repo-sq1/sq1.txt"
git -C "$HOME/Code/Org/repo-sq1" add -A
git -C "$HOME/Code/Org/repo-sq1" commit -q -m "work 1"
git -C "$HOME/Code/Org/repo-sq1" commit -q --allow-empty -m "work 2"
git -C "$REPO" merge --squash -q sq1 >/dev/null 2>&1
git -C "$REPO" commit -q -m "squash: sq1"
run "$REPO" wt-rm sq1
rc_is 0 "squash-merged worktree is removed"
hasnt "not fully merged" "no unmerged warning when the content is all in the base"
run "$REPO" git branch --list sq1
eq "$OUT" "" "squash-merged branch is deleted (ancestry says no, content says yes)"

# The naive `git diff <base> <branch>` test passes above and fails here: once any
# other MR lands, the base tree no longer equals the branch tree. Detection must
# survive the base moving on, or it silently stops working after the first merge.
setup
run "$REPO" wt sq2
print -r -- "sq2" > "$HOME/Code/Org/repo-sq2/sq2.txt"
git -C "$HOME/Code/Org/repo-sq2" add -A
git -C "$HOME/Code/Org/repo-sq2" commit -q -m "work"
git -C "$REPO" merge --squash -q sq2 >/dev/null 2>&1
git -C "$REPO" commit -q -m "squash: sq2"
git -C "$REPO" commit -q --allow-empty -m "a later, unrelated MR"
run "$REPO" wt-rm sq2
run "$REPO" git branch --list sq2
eq "$OUT" "" "squash-merge is still detected after the base branch advances"

# Safety: real unmerged content must still be kept. The existing empty-commit case
# covers ancestry; this one proves the content test itself does not false-positive.
setup
run "$REPO" wt sq3
print -r -- "unmerged work" > "$HOME/Code/Org/repo-sq3/sq3.txt"
git -C "$HOME/Code/Org/repo-sq3" add -A
git -C "$HOME/Code/Org/repo-sq3" commit -q -m "genuinely unmerged"
run "$REPO" wt-rm sq3
has "not fully merged" "a branch with real unmerged content is kept"
run "$REPO" git branch --list sq3
[[ -n "$OUT" ]] && _pass "the kept branch still exists" \
                || _fail "the kept branch still exists"

# Partly merged: one commit squashed in, another added after. Content still
# differs, so this must be kept too — the check is all-or-nothing, not "most of it".
setup
run "$REPO" wt sq4
print -r -- "first" > "$HOME/Code/Org/repo-sq4/a.txt"
git -C "$HOME/Code/Org/repo-sq4" add -A
git -C "$HOME/Code/Org/repo-sq4" commit -q -m "first"
git -C "$REPO" merge --squash -q sq4 >/dev/null 2>&1
git -C "$REPO" commit -q -m "squash: sq4 (partial)"
print -r -- "second" > "$HOME/Code/Org/repo-sq4/b.txt"
git -C "$HOME/Code/Org/repo-sq4" add -A
git -C "$HOME/Code/Org/repo-sq4" commit -q -m "added after the merge"
run "$REPO" wt-rm sq4
has "not fully merged" "a partly-merged branch is kept"

print -r -- ""
print -r -- "W. wt-rm — the checkout's Codex sessions are released before check 4"

# Codex's daemon keeps a thread loaded, and its MCP helpers running inside the checkout, for
# about 60 s after the TUI goes, so wt-rm asks it to release them. Only exit 5 (daemon
# unreachable, no restore owed) continues without a release: any other status may have left
# a session archived, and the retry restores it.
setup
mkhook "$REPO" '#!/bin/sh
[ "$1" = teardown ] && echo teardown-hook >> "$LLOG"
exit 0'
run "$REPO" wt rel-order
RO="$HOME/Code/Org/repo-rel-order"
export MOCK_XRPC_TO_LLOG=1
run "$REPO" wt-rm rel-order
rc_is 0 "W1 the release fixture removes the worktree normally"
eq "$(sed -n 1p "$LLOG")" "teardown-hook" "W1 teardown runs first"
eq "$(sed -n 2p "$LLOG")" "xreview-rpc" "W1 the release runs after teardown and check 3"
[[ "$(sed -n 3p "$LLOG")" == *"-F"* ]] && _pass "W1 check 4 scans after the release" \
                                        || _fail "W1 check 4 scans after the release"
eq "$(<$XLOG)" $'---\nrelease\n--dir\n'"$RO" "W1 the release gets the checkout as one --dir argument"

setup
run "$REPO" wt rel-ok
ROK="$HOME/Code/Org/repo-rel-ok"
export MOCK_XRPC_OUT='released th-1\nreleased th-2\n'
RT=$(mkd)
TMPDIR="$RT" run "$REPO" wt-rm rel-ok
rc_is 0 "W2 released sessions let removal proceed"
has "✓ released Codex session th-1" "W2 the first released session is reported"
has "✓ released Codex session th-2" "W2 the second released session is reported"
[[ -d "$ROK" ]] && _fail "W2 the checkout is removed" || _pass "W2 the checkout is removed"
eq "$(ls "$RT" | grep -c 'wt-rm-release')" "0" "W2 the scratch directory is removed"

# Only the progress line of stderr is shown live; the rest is kept for a refusal.
setup
run "$REPO" wt rel-wait
export MOCK_XRPC_OUT='released e\n' \
       MOCK_XRPC_ERR='xreview-rpc: waiting for ephemeral e to unload (up to 90 s)\nxreview-rpc: noise\n'
run "$REPO" wt-rm rel-wait
rc_is 0 "W2b a release that waits still lets removal proceed"
has "xreview-rpc: waiting for ephemeral e to unload (up to 90 s)" "W2b the wait is shown live"
has "✓ released Codex session e" "W2b the released session is reported"
hasnt "xreview-rpc: noise" "W2b other stderr is not shown on success"

setup
run "$REPO" wt rel-none
run "$REPO" wt-rm rel-none
rc_is 0 "W3 nothing to release: removal proceeds"
hasnt "released Codex session" "W3 nothing to release: nothing is reported"

for st in 1 2 signal; do
  setup
  run "$REPO" wt rel-refuse
  RR="$HOME/Code/Org/repo-rel-refuse"
  if [[ $st == signal ]]; then
    export MOCK_XRPC_SIGNAL=TERM; want=143
  else
    export MOCK_XRPC_RC=$st; want=$st
  fi
  export MOCK_XRPC_OUT='released th-0\n'
  export MOCK_XRPC_ERR='xreview-rpc: th-1 is running a turn — let it finish\n'
  : > "$LLOG"
  RT=$(mkd)
  TMPDIR="$RT" run "$REPO" wt-rm rel-refuse
  rc_is 1 "W4 release status $want refuses removal"
  has "✓ released Codex session th-0" "W4 status $want: an id released before the failure is still reported"
  [[ $st == 1 ]] && eq "$(ls "$RT" | grep -c 'wt-rm-release')" "0" "W4 status 1: the scratch directory is removed"
  has "wt-rm: could not release the Codex sessions in $RR (status $want) — removal aborted. Resources may already be reclaimed." \
      "W4 status $want: the refusal names the status"
  has "    xreview-rpc: th-1 is running a turn — let it finish" "W4 status $want: the command's lines follow, indented"
  has "    Then retry: wt-rm rel-refuse" "W4 status $want: the retry is offered"
  [[ -d "$RR" ]] && _pass "W4 status $want: the checkout survives" || _fail "W4 status $want: the checkout survives"
  eq "$(lock_reason_of "$RR")" "wt-managed; remove with command wt-rm" "W4 status $want: the registration survives"
  run "$REPO" git branch --list --format='%(refname:short)' rel-refuse
  eq "$OUT" "rel-refuse" "W4 status $want: the branch survives"
  eq "$(grep -c -- '-F' "$LLOG")" "0" "W4 status $want: check 4 never runs"
done

setup
run "$REPO" wt rel-missing
RMI="$HOME/Code/Org/repo-rel-missing"
NOXR=$(mkd)
for b in env git mkdir mktemp rm tee grep; do ln -s "$(command -v $b)" "$NOXR/$b"; done
OUT="$(cd "$REPO" && source "$FUNCS" && export PATH="$NOXR" && wt-rm rel-missing 2>&1)"; RC=$?
rc_is 1 "W5 a missing xreview-rpc refuses removal"
has "(status 127)" "W5 the refusal carries the missing command's status"
[[ -d "$RMI" ]] && _pass "W5 the checkout survives" || _fail "W5 the checkout survives"

setup
run "$REPO" wt rel-noscratch
RNS="$HOME/Code/Org/repo-rel-noscratch"
TMPDIR="$ROOTTMP/does-not-exist" run "$REPO" wt-rm rel-noscratch
rc_is 1 "W4b an unusable TMPDIR refuses removal"
has "cannot create a scratch directory to release Codex sessions — refusing." "W4b it says why"
[[ -d "$RNS" ]] && _pass "W4b the checkout survives" || _fail "W4b the checkout survives"
eq "$(<$XLOG)" "" "W4b xreview-rpc is never called"

setup
run "$REPO" wt rel-down
RD="$HOME/Code/Org/repo-rel-down"
export MOCK_XRPC_RC=5 MOCK_XRPC_ERR='xreview-rpc: Codex daemon unreachable: gone\n'
run "$REPO" wt-rm rel-down
rc_is 0 "W6 an unreachable daemon with no restore owed continues"
has "wt-rm: the Codex daemon is not reachable — continuing; check 4 decides." "W6 it says it continues"
hasnt "Codex daemon unreachable: gone" "W6 the command's own diagnostic is not repeated"
[[ -d "$RD" ]] && _fail "W6 check 4 and removal still run" || _pass "W6 check 4 and removal still run"

setup
run "$REPO" wt rel-dirty
print -r -- "wip" > "$HOME/Code/Org/repo-rel-dirty/dirty.txt"
run "$REPO" wt-rm rel-dirty
rc_is 1 "W7 a dirty checkout is refused at check 1"
eq "$(<$XLOG)" "" "W7 a refusal before teardown never calls xreview-rpc"

export HOME="$REAL_HOME"
print -r -- ""
print -r -- "passed: $pass  failed: $fail"
(( fail == 0 ))
