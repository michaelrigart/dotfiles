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
# Keyed by the edited file's checkout, never the hook's cwd (spec 2026-11-03 §3).
# Path model: (1) the payload path, absolute against $PWD, is folded lexically; (2) its nearest
# existing ancestor is resolved physically, the missing tail appended; (3) a final symlink is allowed:
# Claude Code 2.1.316 refuses to write through one and names the target, which the next edit is
# classified on; (4) the checkout is the git toplevel of the directory from (2).

# INACTIVE by default: with no apply window open this exits immediately, which is every
# ordinary edit. Anything unexpected — missing jq, unparseable payload, path outside the
# repo — fails open, on the same reasoning as the other guards: a gate that fires
# spuriously gets switched off, and then guards nothing.
# Runs outside the sandbox, so it resolves nothing a sandboxed command can write (spec
# 2026-10-16, sandbox write boundary). PINNED_PATH is for the suites only.
PATH=${PINNED_PATH:-/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin}; export PATH
set -uo pipefail
set -f

allow() { exit 0; }
deny() {
  printf '%s' "$1" | jq -Rs \
    '{hookSpecificOutput:{hookEventName:"PreToolUse",permissionDecision:"deny",permissionDecisionReason:.}}' \
    2>/dev/null || exit 0
  exit 0
}

# Stdin is read first, so an early exit never hands the writer an EPIPE.
payload=$(cat)

[ "${XREVIEW_GUARD:-}" = "off" ] && allow
command -v jq >/dev/null 2>&1 || allow

# No window open anywhere: allow before parsing anything or starting a process, since this
# runs on every tool call. Globbing is on for this test alone.
open=
set +f
for m in "${XDG_STATE_HOME:-$HOME/.local/state}"/xreview/*/applying; do
  [ -e "$m" ] && { open=1; break; }
done
set -f
[ -n "$open" ] || allow

[ -n "$payload" ] || allow
tool=$(printf '%s' "$payload" | jq -r '.tool_name // empty' 2>/dev/null) || allow
case "$tool" in Edit|Write|NotebookEdit) ;; *) allow ;; esac

path=$(printf '%s' "$payload" \
       | jq -r '.tool_input.file_path // .tool_input.notebook_path // empty' 2>/dev/null) || allow
[ -n "$path" ] || allow
case "$path" in /*) ;; *) path="$PWD/$path" ;; esac

# norm <absolute path> sets `npath` to the path with `.` and empty components dropped and each
# `..` popping the component before it (never above `/`) - a stack in pure shell, no subprocess.
norm() {
  local c IFS=/
  npath=
  for c in $1; do
    case "$c" in
      ""|.) ;;
      ..)   npath=${npath%/*} ;;
      *)    npath="$npath/$c" ;;
    esac
  done
  [ -n "$npath" ] || npath=/
}

norm "$path"
dir=$npath; miss=
while [ ! -d "$dir" ]; do miss="/${dir##*/}$miss"; dir=${dir%/*}; [ -n "$dir" ] || dir=/; done
cd -P -- "$dir" 2>/dev/null || allow
real=$PWD; abs="${real%/}$miss"
[ -L "$abs" ] && allow        # Claude Code refuses to write through it and names the target

root=$(git -C "$real" rev-parse --show-toplevel 2>/dev/null) || allow
[ -n "$root" ] || allow
key=$(printf '%s' "$root" | tr '/' '_' | sed 's/^_//')
marker="${XDG_STATE_HOME:-$HOME/.local/state}/xreview/$key/applying"
[ -r "$marker" ] || allow          # this checkout has no window open

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

qroot=$(printf '%q' "$root")
nonce=$(sed -n 's/^nonce=//p' "$marker" 2>/dev/null | head -1)
deny "Outside the cross-review apply window: $rel

Findings from review ${nonce:-?} may only change files already in this branch's diff,
plus test paths. '$rel' is neither, so this edit would change code the review never saw.

If the fix genuinely belongs there, close the window first:

    xreview -C $qroot apply --done

Then make the change deliberately, as your own edit rather than the reviewer's."
