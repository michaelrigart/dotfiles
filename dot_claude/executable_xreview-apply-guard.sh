#!/usr/bin/env bash
# PreToolUse guard for the cross-review apply window.
#
# Acting on a reviewer's finding should not be able to change code the review never
# looked at. While `xreview apply <nonce>` is open, edits are confined to files already
# in the branch diff, plus test paths — the RED-test rule requires ADDING a test, so a
# rule confined strictly to the diff would forbid the thing it demands.
#
# This bounds where a mistake lands. It cannot tell whether a RED test was actually
# written first; that stays discipline, and no hook can observe it.
#
# INACTIVE by default: with no apply window open this exits immediately, which is every
# ordinary edit. Anything unexpected — missing jq, unparseable payload, path outside the
# repo — fails open, on the same reasoning as the other guards: a gate that fires
# spuriously gets switched off, and then guards nothing.
set -uo pipefail
set -f

allow() { exit 0; }
deny() {
  printf '%s' "$1" | jq -Rs \
    '{hookSpecificOutput:{hookEventName:"PreToolUse",permissionDecision:"deny",permissionDecisionReason:.}}' \
    2>/dev/null || exit 0
  exit 0
}

[ "${XREVIEW_GUARD:-}" = "off" ] && allow
command -v jq >/dev/null 2>&1 || allow

root=$(git rev-parse --show-toplevel 2>/dev/null) || allow
[ -n "$root" ] || allow
key=$(printf '%s' "$root" | tr '/' '_' | sed 's/^_//')
marker="${XDG_STATE_HOME:-$HOME/.local/state}/xreview/$key/applying"
[ -r "$marker" ] || allow          # no window open — the overwhelmingly common case

payload=$(cat)
[ -n "$payload" ] || allow
tool=$(printf '%s' "$payload" | jq -r '.tool_name // empty' 2>/dev/null) || allow
case "$tool" in Edit|Write|NotebookEdit) ;; *) allow ;; esac

path=$(printf '%s' "$payload" | jq -r '.tool_input.file_path // empty' 2>/dev/null) || allow
[ -n "$path" ] || allow

# Repo-relative, so it can be compared with `git diff --name-only` output. Both sides
# must be resolved first: git reports a real path, while a tool payload may carry the
# symlinked one (/var/folders vs /private/var/folders, /tmp vs /private/tmp). Comparing
# them raw silently classifies in-repo files as outside it, and the guard then allows
# everything — failing open in the one direction that matters.
dir=$(cd "$(dirname "$path")" 2>/dev/null && pwd -P) || allow
[ -n "$dir" ] || allow
abs="$dir/$(basename "$path")"
case "$abs" in
  "$root"/*) rel="${abs#"$root"/}" ;;
  *)         allow ;;                     # outside the repo entirely — not ours to police
esac

grep -Fqx "file=$rel" "$marker" 2>/dev/null && allow

# Test paths are always permitted: the RED-test rule requires adding one.
case "$rel" in
  test/*|tests/*|spec/*|*/test/*|*/tests/*|*/spec/*) allow ;;
  *_test.*|*.test.*|*_spec.*|*.spec.*|test_*) allow ;;
esac

nonce=$(sed -n 's/^nonce=//p' "$marker" 2>/dev/null | head -1)
deny "Outside the cross-review apply window: $rel

Findings from review ${nonce:-?} may only change files already in this branch's diff,
plus test paths. '$rel' is neither, so this edit would change code the review never saw.

If the fix genuinely belongs there, close the window first:

    xreview apply --done

Then make the change deliberately, as your own edit rather than the reviewer's."
