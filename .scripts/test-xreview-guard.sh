#!/usr/bin/env bash
# Tests for dot_claude/executable_xreview-guard.sh — the pre-merge cross-review gate.
#
# Fixtures are real git repos under $TMPDIR with a fake XDG_STATE_HOME, so the guard's
# receipt lookup is exercised for real rather than mocked. Every assertion pins an exact
# decision string: "did not crash" is not evidence a guard fired.
set -uo pipefail
GUARD="$(cd "$(dirname "$0")/.." && pwd)/dot_claude/executable_xreview-guard.sh"
pass=0; fail=0
_pass() { printf '  PASS: %s\n' "$1"; pass=$((pass + 1)); }
_fail() { printf '  FAIL: %s\n    | got: %s\n' "$1" "$2"; fail=$((fail + 1)); }

payload() { printf '{"tool_input":{"command":"%s"}}' "$1"; }
# An allow is silence, not JSON — jq on empty stdin prints nothing, so the empty case
# must be handled before jq rather than by its // default.
decide() {
  local out; out="$(cat)"
  [ -n "$out" ] || { printf 'allow'; return; }
  printf '%s' "$out" | jq -r '.hookSpecificOutput.permissionDecision // "allow"' 2>/dev/null \
    || printf 'allow'
}
decision() { payload "$1" | bash "$GUARD" 2>/dev/null | decide; }
is() { [ "$2" = "$3" ] && _pass "$1" || _fail "$1" "$2"; }

ROOT="$(mktemp -d "${TMPDIR:-/tmp}/xrguard.XXXXXX")"
trap 'rm -rf "$ROOT"' EXIT
export XDG_STATE_HOME="$ROOT/state"
mkdir -p "$ROOT/repo" && cd "$ROOT/repo" || exit 1
git init -q . && git config user.email t@t && git config user.name t
git commit -q --allow-empty -m init

BRANCH="$(git rev-parse --abbrev-ref HEAD)"
KEY="$(printf '%s' "$(git rev-parse --show-toplevel)" | tr '/' '_' | sed 's/^_//')"
RECEIPTS="$XDG_STATE_HOME/xreview/$KEY/reviews.jsonl"

is "glab mr create is denied with no receipt"  "$(decision 'glab mr create --fill')" deny
is "gh pr create is denied with no receipt"    "$(decision 'gh pr create --fill')"   deny
is "an unrelated command is allowed"           "$(decision 'git status')"            allow
is "git merge is out of scope and allowed"     "$(decision 'git merge feature')"     allow

mkdir -p "$(dirname "$RECEIPTS")"
printf '{"ts":"t","branch":"other","head":"h","thread":"x","nonce":"n"}\n' > "$RECEIPTS"
is "a receipt for a DIFFERENT branch still denies" "$(decision 'glab mr create')" deny

printf '{"ts":"t","branch":"%s","head":"h","thread":"x","nonce":"n"}\n' "$BRANCH" >> "$RECEIPTS"
is "a receipt for this branch allows"          "$(decision 'glab mr create')" allow

XREVIEW_GUARD=off
export XREVIEW_GUARD
rm -f "$RECEIPTS"
is "XREVIEW_GUARD=off bypasses deliberately"   "$(decision 'glab mr create')" allow
unset XREVIEW_GUARD

is "an empty payload fails open"  "$(printf '' | bash "$GUARD" 2>/dev/null | decide)" allow

printf '\npassed: %d  failed: %d\n' "$pass" "$fail"
(( fail == 0 ))
