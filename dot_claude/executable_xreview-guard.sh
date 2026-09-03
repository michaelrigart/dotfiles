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

# Fast path. This hook fires on EVERY Bash call, so the common case must cost no
# subprocess at all — a shell-builtin substring test on the raw payload, before any
# JSON parsing. `create` is the one word both gated verbs must contain, so nothing
# real can slip past it, and almost nothing else reaches the check below.
case "$payload" in
  *create*) ;;
  *) allow ;;
esac

cmd=$(printf '%s' "$payload" | jq -r '.tool_input.command // empty' 2>/dev/null) || allow
[ -n "$cmd" ] || allow

# The bypass has to be readable from the COMMAND, not just from this process's
# environment. A model cannot export a variable into a hook that runs beside it; the
# only place it can write one is the command line, which is also the form the deny
# message names. Recorded 2026-09-02: `XREVIEW_GUARD=off glab mr create ...`, sent on
# an explicit instruction to merge without a review, denied anyway because the env
# assignment applied to `glab` and never reached here. Matched anywhere in the string
# so the trailing-comment form works too, exactly as WT_GUARD=off does.
case "$cmd" in *XREVIEW_GUARD=off*) allow ;; esac

# One shape only: `glab mr create` or `gh pr create`, and it must sit in COMMAND
# POSITION. The first version of this matched `*glab*mr*create*|*gh*pr*create*` against
# the whole command, which reads "gh" out of "outright", "pr" out of "proposed" and
# "create" out of "recreate" — so a Basecamp comment describing the branch, an MR body
# written to the scratchpad, or `rg 'gh pr create' docs/` was denied with a message
# about cross-review. Nine such denies against five real ones in the recorded
# transcripts (measured 2026-09-03). Same fix, same regex shape, as rule 2 of
# git-forge-guard.sh; see the note there.
#
# `^` anchors per LINE under grep, which is deliberate: the real-world shape writes the
# body first and puts the verb on its own line after an assignment. It shares the known
# limit of every matcher here — a heredoc body whose line BEGINS with the verb still
# matches, and a command assembled from a variable still does not. This is a guard, not
# a sandbox.
verb_re='(^|[;&|(])[[:space:]]*([A-Za-z_][A-Za-z0-9_]*=[^[:space:]]*[[:space:]]+)*(sudo[[:space:]]+)?(glab[[:space:]]+mr[[:space:]]+create|gh[[:space:]]+pr[[:space:]]+create)([[:space:]]|$)'
printf '%s' "$cmd" | grep -Eq "$verb_re" || allow

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

If this branch genuinely should go up without one, re-run with XREVIEW_GUARD=off in
the command — an environment assignment on the command line is read, a trailing
\`# XREVIEW_GUARD=off\` works too."
