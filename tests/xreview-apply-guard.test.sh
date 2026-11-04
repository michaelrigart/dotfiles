#!/usr/bin/env bash
# Tests for dot_claude/executable_xreview-apply-guard.sh — the apply-window guard.
#
# This guard has a wildcard matcher, so it runs on every tool call. Its most important
# property is being INERT with no window open: a regression there blocks ordinary edits
# everywhere. That case is asserted first and deliberately.
set -uo pipefail
GUARD="$(cd "$(dirname "$0")/.." && pwd)/dot_claude/executable_xreview-apply-guard.sh"
[ -f "$GUARD" ] || { echo "missing guard under test: $GUARD" >&2; exit 2; }
XREVIEW="$(cd "$(dirname "$0")/.." && pwd)/dot_local/bin/executable_xreview"
[ -f "$XREVIEW" ] || { echo "missing xreview under test: $XREVIEW" >&2; exit 2; }
pass=0; fail=0
_pass() { printf '  PASS: %s\n' "$1"; pass=$((pass + 1)); }
_fail() { printf '  FAIL: %s\n    | got: %s\n' "$1" "$2"; fail=$((fail + 1)); }
is() { if [ "$2" = "$3" ]; then _pass "$1"; else _fail "$1" "$2"; fi; }

decide() {
  local out; out="$(cat)"
  [ -n "$out" ] || { printf 'allow'; return; }
  printf '%s' "$out" | jq -r '.hookSpecificOutput.permissionDecision // "allow"' 2>/dev/null \
    || printf 'allow'
}
# guard_out <payload> [<cwd>] - the guard's raw answer, run from <cwd> (default: the suite's own).
# PINNED_PATH is the suite's PATH unless the caller set one, as the spy cases do.
guard_out() { ( cd "${2:-.}" && printf '%s' "$1" | PINNED_PATH="${PINNED_PATH:-$PATH}" bash "$GUARD" 2>/dev/null ); }
edit() { guard_out "$(printf '{"tool_name":"%s","tool_input":{"file_path":"%s"}}' "${2:-Edit}" "$1")" "${3:-.}" | decide; }
nbedit() { guard_out "$(printf '{"tool_name":"NotebookEdit","tool_input":{"notebook_path":"%s"}}' "$1")" "${2:-.}" | decide; }

ROOT="$(mktemp -d "${TMPDIR:-/tmp}/xrapply.XXXXXX")"
trap 'rm -rf "$ROOT"' EXIT
export XDG_STATE_HOME="$ROOT/state"
mkdir -p "$ROOT/repo/src" "$ROOT/repo/tests" && cd "$ROOT/repo" || exit 1
git init -q . && git config user.email t@t && git config user.name t
printf 'x\n' > src/in-diff.txt; printf 'y\n' > src/untouched.txt
git config commit.gpgsign false          # see xreview.test.sh for why
git add -A
if ! git commit -q -m init; then printf 'fixture setup failed\n' >&2; exit 1; fi
printf 'changed\n' > src/in-diff.txt      # working-tree change → in scope

KEY="$(printf '%s' "$(git rev-parse --show-toplevel)" | tr '/' '_' | sed 's/^_//')"
MARKER="$XDG_STATE_HOME/xreview/$KEY/applying"

is "INERT with no window open (most important)" "$(edit "$ROOT/repo/src/untouched.txt")" allow

mkdir -p "$(dirname "$MARKER")"
{ printf 'nonce=xr-test\n'; printf 'file=src/in-diff.txt\n'; } > "$MARKER"

is "file in the branch diff is allowed"      "$(edit "$ROOT/repo/src/in-diff.txt")"   allow
is "file outside the diff is denied"         "$(edit "$ROOT/repo/src/untouched.txt")" deny
is "a test path is allowed (RED-test rule)"  "$(edit "$ROOT/repo/tests/new_spec.rb")" allow
is "a *_test.* file is allowed"              "$(edit "$ROOT/repo/src/thing_test.go")" allow
is "Write is guarded too"                    "$(edit "$ROOT/repo/src/untouched.txt" Write)" deny
is "a non-editing tool is ignored"           "$(edit "$ROOT/repo/src/untouched.txt" Bash)"  allow
is "a path outside the repo is not policed"  "$(edit "/etc/hosts")"                   allow

XREVIEW_GUARD=off; export XREVIEW_GUARD
is "XREVIEW_GUARD=off bypasses"              "$(edit "$ROOT/repo/src/untouched.txt")" allow
unset XREVIEW_GUARD

rm -f "$MARKER"
is "inert again once the window is closed"   "$(edit "$ROOT/repo/src/untouched.txt")" allow

# --- K. The window is keyed by the edited file's checkout, never the hook's cwd (spec 2026-11-03 §3)
A="$ROOT/repo"; B="$ROOT/repo-b"; H="$ROOT/repo/.claude/worktrees/h"
mkdir -p "$ROOT/norepo"
git -C "$A" worktree add -q "$B" -b b 2>/dev/null && git -C "$A" worktree add -q "$H" -b h 2>/dev/null \
  || { echo "worktree fixture setup failed" >&2; exit 1; }
printf 'changed b\n' > "$B/src/in-diff.txt"
printf 'changed h\n' > "$H/src/in-diff.txt"
BTOP="$(git -C "$B" rev-parse --show-toplevel)"
# window <checkout> - open a window on that checkout, as the existing marker is written, under
# its own key; only src/in-diff.txt is in scope.
window() {
  local top key; top="$(git -C "$1" rev-parse --show-toplevel)"
  key="$(printf '%s' "$top" | tr '/' '_' | sed 's/^_//')"
  mkdir -p "$XDG_STATE_HOME/xreview/$key"
  { printf 'nonce=xr-k\n'; printf 'file=src/in-diff.txt\n'; } > "$XDG_STATE_HOME/xreview/$key/applying"
}
no_windows() { rm -rf "$XDG_STATE_HOME/xreview"; }
REAL_GIT="$(command -v git)"; REAL_JQ="$(command -v jq)"
mkdir -p "$ROOT/spy"
for t in git jq; do
  real="$REAL_GIT"; [ "$t" = jq ] && real="$REAL_JQ"
  printf '#!/bin/sh\necho %s >> "%s/spy.log"\nexec "%s" "$@"\n' "$t" "$ROOT" "$real" > "$ROOT/spy/$t"
  chmod +x "$ROOT/spy/$t"
done

no_windows; : > "$ROOT/spy.log"
is "K0: no window anywhere is allowed" \
   "$(PINNED_PATH="$ROOT/spy:$PATH" edit "$A/src/untouched.txt")" allow
is "K0: no window anywhere runs no git and no jq" "$(cat "$ROOT/spy.log")" ""

# The writer's own exit status: a guard that exits before reading stdin hands it SIGPIPE.
no_windows
head -c 300000 /dev/zero | tr '\0' x | PINNED_PATH="$PATH" bash "$GUARD" >/dev/null 2>&1
printf '%s' "${PIPESTATUS[1]}" > "$ROOT/writer.status"
is "K0b: with no window the guard still reads all of stdin (writer exits 0)" "$(cat "$ROOT/writer.status")" 0

no_windows; window "$B"
is "K1: B's window denies B's file outside the diff, from A" "$(edit "$B/src/untouched.txt")" deny
is "K1: B's window allows B's file in the diff"              "$(edit "$B/src/in-diff.txt")"  allow
is "K2: B's window leaves A's file alone"                    "$(edit "$A/src/untouched.txt")" allow
is "K5: B's window holds when the hook runs outside any repository" \
   "$(edit "$B/src/untouched.txt" Edit "$ROOT/norepo")" deny
is "K6: a Write into a new directory of B is denied"   "$(edit "$B/src/new/dir/f.txt" Write)" deny
is "K6: a Write of a new test file in B is allowed"    "$(edit "$B/tests/new/x_test.rb" Write)" allow
is "K7: NotebookEdit is policed by its notebook_path"  "$(nbedit "$B/src/nb.ipynb")" deny
reason="$(guard_out "$(printf '{"tool_name":"Edit","tool_input":{"file_path":"%s"}}' "$B/src/untouched.txt")" \
          | jq -r '.hookSpecificOutput.permissionDecisionReason // ""')"
is "K8: the deny reason starts with the classified first line" \
   "$(printf '%s' "$reason" | head -1)" "Outside the cross-review apply window: src/untouched.txt"
case "$reason" in
  *"xreview -C $BTOP apply --done"*) is "K8: the remedy names B's checkout" ok ok ;;
  *) is "K8: the remedy names B's checkout" "$reason" "a reason holding: xreview -C $BTOP apply --done" ;;
esac

no_windows; window "$H"
is "K3: H's window denies H's file, from A's cwd" "$(edit "$H/src/untouched.txt")" deny

no_windows; window "$A"
is "K4: A's window does not claim H's file" "$(edit "$H/src/untouched.txt")" allow
is "K4: A's window still denies A's own file" "$(edit "$A/src/untouched.txt")" deny

no_windows
PINNED_PATH="$PATH" bash "$XREVIEW" -C "$B" apply xr-k9 >/dev/null 2>&1
is "K9: xreview apply opened a window the guard finds (B's file outside the diff)" \
   "$(edit "$B/src/untouched.txt")" deny
is "K9: and B's file in the diff" "$(edit "$B/src/in-diff.txt")" allow
no_windows

git -C "$A" worktree remove --force "$B" 2>/dev/null; git -C "$A" worktree remove --force "$H" 2>/dev/null
git -C "$A" branch -D b h >/dev/null 2>&1

printf '\npassed: %d  failed: %d\n' "$pass" "$fail"
(( fail == 0 ))
