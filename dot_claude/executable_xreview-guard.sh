#!/usr/bin/env bash
# PreToolUse(Bash) guard for the pre-merge cross-review checkpoint.
#
# Enforces the one part of the cross-review workflow that prose cannot: that a
# branch is not proposed for merge without Codex having reviewed it at least once.
# The relay itself is automatic, but nothing otherwise guarantees it ran — and a
# skipped review is indistinguishable from one that found nothing.
#
# Scope is deliberately ONE command shape: creating a merge/pull request via glab
# or gh. Merging locally, pushing, forge web UIs, other CLIs and XREVIEW_GUARD=off
# are documented blind spots that fail open. A narrow guard that never fires
# spuriously is worth more than a broad one that gets disabled.
#
# The receipt is advisory about freshness, not about existence: it records the head
# at review time but does not invalidate itself when HEAD moves, because applying a
# review finding necessarily moves HEAD and a self-invalidating receipt would demand
# a review of the fix for the review.
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

payload=$(cat)
[ -n "$payload" ] || allow
command -v jq >/dev/null 2>&1 || allow

cmd=$(printf '%s' "$payload" | jq -r '.tool_input.command // empty' 2>/dev/null) || allow
[ -n "$cmd" ] || allow

# One shape only: `glab mr create` or `gh pr create`, in that word order.
case "$cmd" in
  *glab*mr*create*|*gh*pr*create*) ;;
  *) allow ;;
esac

root=$(git rev-parse --show-toplevel 2>/dev/null) || allow
[ -n "$root" ] || allow
branch=$(git rev-parse --abbrev-ref HEAD 2>/dev/null) || allow

key=$(printf '%s' "$root" | tr '/' '_' | sed 's/^_//')
receipts="${XDG_STATE_HOME:-$HOME/.local/state}/xreview/$key/reviews.jsonl"

# No receipts file at all, or none naming this branch.
if [ -r "$receipts" ] &&
   jq -e --arg b "$branch" 'select(.branch == $b)' "$receipts" >/dev/null 2>&1; then
  allow
fi

deny "No Codex cross-review on record for branch '$branch'.

The pre-merge checkpoint requires one review of this branch before it is proposed
for merge. Run the cross-review skill, or dispatch directly:

    xreview dispatch <body-file>   # then: xreview collect <nonce>

Receipts live at $receipts.
Set XREVIEW_GUARD=off to bypass deliberately."
