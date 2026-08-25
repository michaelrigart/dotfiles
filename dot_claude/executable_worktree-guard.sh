#!/usr/bin/env bash
# PreToolUse(Bash) guard for raw worktree removal.
#
# Enforces the worktree rule from ~/.config/agents/GLOBAL.md that prose alone
# cannot guarantee: a wt-managed sibling worktree is retired with `wt-rm`, never
# raw `git worktree remove`. Raw removal skips session shutdown, so live
# processes rewrite into the deleted path — six husk directories came from that.
#
# Scope is deliberately ONE command shape (design §5.1): a literal ABSOLUTE
# target matching the wt sibling convention. Relative targets, -C-relative
# targets, unique-suffix identifiers, variable targets, native worktree tools and
# WT_GUARD=off are documented blind spots that fail open (§5.3). This is a
# correctness catch, not a security boundary.
#
# `git worktree prune` is ALWAYS allowed: it touches only $GIT_DIR/worktrees,
# acts only where the directory is already gone, and is what git prescribes after
# a manual removal — the reconciliation path of hook-protocol design §10.
#
# SAFETY: a guard that breaks unrelated commands is worse than no guard. There is
# no `set -e`; every failure path calls allow(); anything unparseable is allowed.
# The on-disk sibling check is itself the main false-positive defence: the guard
# denies only when the target exists RIGHT NOW next to a real repository.
#
# Bypass for a one-off: put WT_GUARD=off anywhere in the command.
#
# Bash 3.2 compatible (macOS system bash). Tests: .scripts/test-worktree-guard.sh

set -uo pipefail
set -f   # no pathname expansion — command text is never a glob

allow() { exit 0; }

# A deny reason contains paths and quotes, so it goes through jq -Rs rather than
# hand-escaping. If jq fails, allow.
deny() {
  printf '%s' "$1" | jq -Rs \
    '{hookSpecificOutput:{hookEventName:"PreToolUse",permissionDecision:"deny",permissionDecisionReason:.}}' \
    2>/dev/null || exit 0
  exit 0
}

payload=$(cat)
[ -n "$payload" ] || allow
command -v jq >/dev/null 2>&1 || allow

# Fast path. This hook fires on EVERY Bash call, so the common case must cost no
# subprocess at all — a shell-builtin substring test before any JSON parsing.
case "$payload" in
  *"worktree remove"*) ;;
  *) allow ;;
esac

cmd=$(printf '%s' "$payload" | jq -r '.tool_input.command // empty' 2>/dev/null) || allow
[ -n "$cmd" ] || allow
[ "$cmd" = "null" ] && allow

case "$cmd" in *WT_GUARD=off*) allow ;; esac

# Anchored at the start of the first line. Every one of the six observed husk
# commands BEGAN with the removal — pipes and `&& echo` came after, nothing
# before. A preceding command (`cd x && git worktree remove ...`) is out of scope
# and fails open, because a regex that matches mid-command cannot tell which
# invocation a later token belongs to.
first=$(printf '%s\n' "$cmd" | head -1)
verb_re='^[[:space:]]*(sudo[[:space:]]+)?git([[:space:]]+-[^[:space:]]+([[:space:]]+[^[:space:]-][^[:space:]]*)?)*[[:space:]]+worktree[[:space:]]+remove([[:space:]]+|$)'
printf '%s' "$first" | grep -Eq "$verb_re" || allow

# Extraction is BOUND to that invocation: drop the matched prefix and read the
# target from what remains. Scanning for a `remove` token instead would pick up
# `echo remove /other && git worktree remove /real` and name the wrong directory.
strip_re='^[[:space:]]*(sudo[[:space:]]+)?git([[:space:]]+-[^[:space:]]+([[:space:]]+[^[:space:]-][^[:space:]]*)?)*[[:space:]]+worktree[[:space:]]+remove[[:space:]]*'
args=$(printf '%s' "$first" | sed -E "s#$strip_re##")

target=""
quoted=""
rest=""
after=""
for tok in $args; do
  case "$tok" in
    -*) continue ;;
  esac
  # A quoted target keeps its quote characters after word splitting, so `/*`
  # would never match and `git worktree remove "/abs/path"` — the COMMON form —
  # would sail through. Take everything between the opening quote and the next
  # one, which also drops any operator glued on after the close (`"/p";`).
  # A token with no closing quote is a quoted path containing spaces: it split
  # across tokens, so bail rather than act on a truncated path.
  case "$tok" in
    \"*)
      rest=${tok#\"}
      case "$rest" in
        *\"*)
          target=${rest%%\"*}
          after=${rest#*\"}
          # Whatever follows the closing quote must be a shell operator. Otherwise
          # the word CONCATENATES into a different path ("/p"x -> /px), and acting
          # on the quoted part would deny the wrong directory.
          case "$after" in
            ""|[\;\&\|\)\<\>]*) quoted=1 ;;
            *) target=""; break ;;
          esac
          ;;
        *) target=""; break ;;
      esac
      ;;
    \'*)
      rest=${tok#\'}
      case "$rest" in
        *\'*)
          target=${rest%%\'*}
          after=${rest#*\'}
          case "$after" in
            ""|[\;\&\|\)\<\>]*) quoted=1 ;;
            *) target=""; break ;;
          esac
          ;;
        *) target=""; break ;;
      esac
      ;;
    *) target=$tok; quoted="" ;;
  esac
  case "$target" in
    /*) break ;;
    *)  target=""; break ;;
  esac
done
[ -n "$target" ] || allow

# Unquoted only: word splitting leaves a trailing shell metacharacter glued to
# the token (`... remove /path;`). Inside quotes those are literal filename
# characters, so trimming them there would corrupt a legitimate target.
[ -z "$quoted" ] && target=${target%%[;&|)<>]*}
target=${target%/}
[ -d "$target" ] || allow

# Sibling classification, filesystem only — no git subprocess. For each hyphen in
# the basename, test whether <parent>/<prefix> is a repository. Splitting at every
# hyphen rather than the first is required: repository names contain hyphens, as
# VM.Portal-duplicate-alerts shows.
parent=$(dirname "$target")
base=$(basename "$target")

acc=""
rest="$base"
matched=""
while [ "${rest#*-}" != "$rest" ]; do
  seg=${rest%%-*}
  if [ -n "$acc" ]; then acc="$acc-$seg"; else acc=$seg; fi
  rest=${rest#*-}
  if [ -d "$parent/$acc" ] && [ -e "$parent/$acc/.git" ]; then
    matched=$acc
    break
  fi
done
[ -n "$matched" ] || allow

slug=${base#"$matched"-}

deny "Raw \`git worktree remove\` on a wt-managed worktree.

$target is the wt sibling of the repository at $parent/$matched.

Removing it with raw git skips session shutdown and the project teardown hook.
Live processes then write back into the deleted path, which is what leaves husk
directories behind. Retire it through the protocol instead:

    command wt-rm <branch>

(\`command\` is required — a shell function of the same name can shadow the
PATH wrapper that carries the safety preflight.)

The directory slug is \"$slug\". That is not always the branch name — a slug maps
'/' to '-', so a branch containing a slash differs. Use the branch you were
working on.

If this worktree belongs to another tool (a native or harness worktree), use that
tool's own lifecycle command; this rule covers the wt sibling convention only.

For a deliberate manual reconciliation, re-run with WT_GUARD=off in the command."
