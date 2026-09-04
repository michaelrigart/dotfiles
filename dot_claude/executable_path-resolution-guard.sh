#!/usr/bin/env bash
# PreToolUse guard for Bash commands the permission analyser cannot resolve statically.
#
# Two command shapes interrupt with a permission prompt every single time:
#
#   1. A compound command whose first statement is `cd`. Every relative path after it
#      becomes statically unresolvable, so the analyser cannot evaluate the configured
#      Read() deny rules and falls back to asking — in any repo, even for a file
#      nowhere near a secret.
#   2. A recursive grep/rg rooted at `.`, which could reach a path matching a deny glob
#      (**/secrets.*.yml, **/.env.production*, **/*.key, **/*.pem).
#
# A deny rule is absolute — no allow entry and no hook lifts it — so the approval is
# never cached and the prompt returns on every such command. The only lever left is to
# not write the command that way. This bounces it back to the model with the fix, which
# costs one tool call instead of a human interruption. Both fixes are strictly better
# commands anyway: absolute paths say what they mean, and a named directory searches
# less than `.` does.
#
# Both rules match on shell STRUCTURE, never on raw text. Rule 1 fires only when the
# first token of the whole command is `cd`, so a `cd` inside a heredoc body, a subshell,
# a `bash -c` string, or a script being written is untouched — the guard has no business
# policing text that merely contains a command.
#
# Fails open on anything unexpected — missing jq, unparseable payload, an unfamiliar
# shape — on the same reasoning as the other guards: a gate that fires spuriously gets
# switched off, and then guards nothing.
#
# Kill switch: PATH_RESOLUTION_GUARD=off
set -uo pipefail
set -f

allow() { exit 0; }
deny() {
  printf '%s' "$1" | jq -Rs \
    '{hookSpecificOutput:{hookEventName:"PreToolUse",permissionDecision:"deny",permissionDecisionReason:.}}' \
    2>/dev/null || exit 0
  exit 0
}

# Drain stdin before any early exit: leaving the payload unread hands the writer an
# EPIPE, which surfaces as a spurious "writing output failed: Broken pipe" on stderr.
payload=$(cat)

[ "${PATH_RESOLUTION_GUARD:-}" = "off" ] && allow
command -v jq >/dev/null 2>&1 || allow
[ -n "$payload" ] || allow
# Fast path. This hook fires on EVERY Bash call, so the common case must cost no
# subprocess at all — a shell-builtin substring test on the raw payload, before any JSON
# parsing. It cannot be as sharp as the forge guard's: `cd` is two characters and turns
# up inside a hex session id roughly one session in eight, and that id is in every
# payload, so those sessions sit on the slow path throughout. A false hit only costs the
# parse; it can never change the verdict.
case $payload in
  *cd*|*grep*|*rg*) ;;
  *) allow ;;
esac

# One jq spawn, not two: on macOS the process spawn dominates everything the guard
# actually does. Filtering the tool inside the same program keeps a non-Bash payload
# from costing a second one.
cmd=$(printf '%s' "$payload" \
  | jq -r 'if .tool_name == "Bash" then (.tool_input.command // "") else "" end' 2>/dev/null) || allow
[ -n "$cmd" ] || allow

# ---- Rule 1: compound command whose first statement is `cd` --------------------------
head=${cmd#"${cmd%%[![:space:]]*}"}          # strip leading whitespace and newlines
if [[ $head =~ ^cd([[:space:]]|$) ]]; then
  rest=${head#cd}
  rest=${rest%"${rest##*[![:space:]]}"}      # strip trailing whitespace and newlines
  case $rest in
    *"&&"*|*"||"*|*";"*|*$'\n'*)
      deny "Compound command starting with \`cd\`.

Every relative path after a \`cd\` is statically unresolvable, so the permission
analyser cannot evaluate the configured Read() deny rules and falls back to asking —
on every such command, in any repo, even for a file nowhere near a secret. A deny rule
is absolute, so the approval is never cached: the same prompt returns every time.

Re-issue it one of two ways:

  - Drop the \`cd\` and give every file argument an absolute path:
        grep -n 'def foo' -A15 /abs/dir/app/helpers/x.rb

  - If the command genuinely needs a working directory (a test runner, a build),
    send \`cd /abs/dir\` on its own as a separate Bash call first. The working
    directory persists between calls, so the following calls inherit it.

Commands that take a directory flag need neither: git -C DIR, make -C DIR,
npm --prefix DIR."
      ;;
  esac
fi

# ---- Rule 2: recursive search rooted at `.` ------------------------------------------
# Each pipeline/list segment is checked on its own, so `echo hi && grep -rn foo .` is
# caught. A bare `rg foo` with no path operand is deliberately left alone: it is the
# single most common search command, and only an explicit `.` is documented as tripping
# the gate. Better to miss one than to deny thousands.
while IFS= read -r seg; do
  seg=${seg#"${seg%%[![:space:]]*}"}
  [ -n "$seg" ] || continue
  word=${seg%%[[:space:]]*}
  word=${word##*/}                           # /usr/bin/grep -> grep
  case $word in
    grep|egrep|fgrep|rg) ;;
    *) continue ;;
  esac
  case " $seg " in                           # a standalone `.` or `./` path operand
    *" . "*|*" ./ "*) ;;
    *) continue ;;
  esac
  if [ "$word" != rg ]; then                 # rg recurses by default; grep needs the flag
    [[ $seg =~ (^|[[:space:]])(-[A-Za-z]*[rR]|--recursive) ]] || continue
  fi
  deny "Recursive search rooted at \`.\`.

A recursive read over \`.\` can reach a path matching a Read() deny glob
(**/secrets.*.yml, **/.env.production*, **/*.key, **/*.pem), so the permission analyser
falls back to asking. A deny rule is absolute, so the approval is never cached: the same
prompt returns every time.

Name the directories to search instead of passing \`.\`:
      grep -rn foo dot_config dot_claude .scripts

That searches less and reads faster too."
done <<EOF
$(printf '%s' "$cmd" | tr '|;&' '\n\n\n')
EOF

allow
