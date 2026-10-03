#!/usr/bin/env bash
# PreToolUse(Bash) guard for the pre-merge cross-review gate.
#
# Enforces the one part of the cross-review workflow that prose cannot: that nothing is
# proposed or merged without an approving pre-merge Codex review of exactly that change. A
# skipped review is otherwise indistinguishable from one that found nothing.
# Design: docs/superpowers/specs/2026-10-02-xreview-receipt-binding-design.md, section 3.6.
#
# Gated: MR/PR creation and agent-run merges - glab mr create|new|merge|accept, gh pr
# create|new|merge, their REST forms through glab api / gh api, GraphQL mutations that create
# or merge (denied outright), and a local git merge into the default branch. Each opens only
# when the latest full-range pre-merge review of that exact change, for that destination,
# approved it. The change is named by a content fingerprint, so any content change after the
# approval closes the gate again, while a clean rebase keeps it open. The receipts live in one
# ledger per repository, shared by all its worktrees (xreview-ledger.py beside this file).
#
# This shell front is the fast path. The hook fires on EVERY Bash call, so a payload that
# names none of create, new, merge, accept, pulls or graphql, or none of glab, gh or git,
# costs no subprocess at all. It matches each word as the raw JSON payload can spell it, with
# quotes, backslashes and line continuations allowed between its letters: g''it, mer""ge and
# mer\<newline>ge all name their verb. A payload holding an ANSI-C $'...' string, which can
# spell any word with escapes, always goes on. Everything else goes to xreview-guard.py
# beside this file, which owns the grammar and the checks and fails closed on a gated shape.
#
# The bypass is XREVIEW_GUARD=off, for Michael's explicit use only: in this hook's
# environment, or anywhere in the command (the only place a model can write it).
#
# Bash 3.2 compatible (macOS system bash).
set -uo pipefail
set -f

[ "${XREVIEW_GUARD:-}" = "off" ] && exit 0

payload=$(cat)
[ -n "$payload" ] || exit 0

# Between two letters of a word the JSON payload may hold a single quote, or an escaped double
# quote, backslash or newline (\" \\ \n): g is that gap. One [[ =~ ]] per word keeps this
# linear; a ${payload//...} substitution is quadratic in bash 5 and far worse in bash 3.2,
# which leaves a large command without a decision inside the hook's time limit.
g="('|\\\\[\"\\\\n])*"
spells() {
  local word re i
  for word in "$@"; do
    re=${word:0:1}
    for (( i = 1; i < ${#word}; i++ )); do re="$re$g${word:i:1}"; done
    [[ $payload =~ $re ]] && return 0
  done
  return 1
}
case "$payload" in
  *"\$'"*) ;;
  *) spells create new merge accept pulls graphql || exit 0
     spells glab gh git || exit 0 ;;
esac

py=/usr/bin/python3
[ -x "$py" ] || py=python3
helper="$(dirname "$0")/xreview-guard.py"
verdict=$(printf '%s' "$payload" | "$py" "$helper" 2>/dev/null)
rc=$?
if [ -n "$verdict" ]; then
  printf '%s\n' "$verdict"
  exit 0
fi
[ "$rc" -eq 0 ] && exit 0

# The helper could not run at all. FAIL DIRECTION IS CLOSED for a command that may propose or
# merge: glab/gh with mr, pr or api, or git with merge, as whole words on one line - the
# helper's own last resort (CRUDE). The text is read with quotes and backslashes dropped,
# both with every backslash-newline joined and without, so neither a fused redirection
# (git>log merge), a continuation (git \<newline>merge) nor a backtick hides the verb.
# Anything else is allowed.
cmd=$(printf '%s' "$payload" | jq -r '.tool_input.command // empty' 2>/dev/null) || cmd=$payload
case "$cmd" in *XREVIEW_GUARD=off*) exit 0 ;; esac
crude='\b(glab|gh)\b.*\b(mr|pr|api)\b|\bgit\b.*\bmerge\b'
if { printf '%s\n' "$cmd" | awk '{ if (sub(/\\$/, "")) printf "%s", $0; else print }'
     printf '%s\n' "$cmd"; } | tr -d "'\"\\\\" | grep -Eq "$crude"; then
  reason="Pre-merge gate: the gate's check could not run ($helper exited $rc), so this command, which may propose or merge a change, is refused. Restore the helper (chezmoi apply)."
  printf '%s' "$reason" | jq -Rs \
    '{hookSpecificOutput:{hookEventName:"PreToolUse",permissionDecision:"deny",permissionDecisionReason:.}}' 2>/dev/null \
    || printf '%s\n' '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":"Pre-merge gate: the check could not run, so this command is refused."}}'
fi
exit 0
