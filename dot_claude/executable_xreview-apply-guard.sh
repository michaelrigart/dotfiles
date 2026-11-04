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
#
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

# The edited file's checkout, never the hook's cwd: the git toplevel of the nearest existing
# ancestor of its directory (a Write into a new directory has no directory to enter yet), with
# the missing tail appended. Both sides must be resolved before comparing: git reports a real
# path, while a tool payload may carry the symlinked one (/var/folders vs /private/var/folders,
# /tmp vs /private/tmp). Comparing them raw silently classifies in-repo files as outside it,
# and the guard then allows everything — failing open in the one direction that matters.
#
# resolve <absolute path> sets `cur` (the physical, existing directory the path reaches) and
# `miss` (the components still to be created). Walking the missing tail component by component
# applies `.` and `..` there lexically — a `..` after a missing directory cancels it, and one
# with nothing left to cancel climbs out of `cur` — so the path is classified where the tool
# will write it, not where the walk happened to stop. Existing parts resolve physically.
resolve() {
  local d=$1 tail= c p IFS=/
  while [ ! -d "$d" ]; do
    p=$(dirname "$d")
    [ "$p" != "$d" ] || allow
    tail="/$(basename "$d")$tail"; d=$p
  done
  cur=$(cd "$d" 2>/dev/null && pwd -P) || allow
  [ -n "$cur" ] || allow
  miss=
  for c in $tail; do
    case "$c" in
      ""|.) ;;
      ..) if [ -n "$miss" ]; then miss=${miss%/*}; else cur=$(dirname "$cur"); fi ;;
      *)  if [ -z "$miss" ] && [ -d "$cur/$c" ]; then
            cur=$(cd "$cur/$c" 2>/dev/null && pwd -P) || allow
          else
            miss="$miss/$c"
          fi ;;
    esac
  done
}

resolve "$path"
abs="${cur%/}$miss"
# A symlinked file belongs to its target's checkout, not to the link's directory. Follow a
# chain a bounded number of hops (plain `readlink`: the one form every pinned PATH offers); a
# loop or an unreadable link is unexpected, so it fails open like every other surprise.
hops=0
while [ -L "$abs" ]; do
  hops=$((hops + 1)); [ "$hops" -le 10 ] || allow
  target=$(readlink "$abs" 2>/dev/null) || allow
  [ -n "$target" ] || allow
  case "$target" in /*) ;; *) target="$(dirname "$abs")/$target" ;; esac
  resolve "$target"
  abs="${cur%/}$miss"
done
real=$cur

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
