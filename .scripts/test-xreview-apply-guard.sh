#!/usr/bin/env bash
# Tests for dot_claude/executable_xreview-apply-guard.sh — the apply-window guard.
#
# This guard has a wildcard matcher, so it runs on every tool call. Its most important
# property is being INERT with no window open: a regression there blocks ordinary edits
# everywhere. That case is asserted first and deliberately.
set -uo pipefail
GUARD="$(cd "$(dirname "$0")/.." && pwd)/dot_claude/executable_xreview-apply-guard.sh"
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
edit() { printf '{"tool_name":"%s","tool_input":{"file_path":"%s"}}' "${2:-Edit}" "$1" \
         | bash "$GUARD" 2>/dev/null | decide; }

ROOT="$(mktemp -d "${TMPDIR:-/tmp}/xrapply.XXXXXX")"
trap 'rm -rf "$ROOT"' EXIT
export XDG_STATE_HOME="$ROOT/state"
mkdir -p "$ROOT/repo/src" "$ROOT/repo/tests" && cd "$ROOT/repo" || exit 1
git init -q . && git config user.email t@t && git config user.name t
printf 'x\n' > src/in-diff.txt; printf 'y\n' > src/untouched.txt
git add -A && git commit -q -m init
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

printf '\npassed: %d  failed: %d\n' "$pass" "$fail"
(( fail == 0 ))
