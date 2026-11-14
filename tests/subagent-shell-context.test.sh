#!/usr/bin/env bash
# Tests for dot_claude/hooks/executable_subagent-shell-context.sh, the SubagentStart hook that
# puts the path rule in front of every subagent's first prompt.
#
# Pins the three promises the hook makes: it adds exactly the measured line as context, it
# never decides anything, and it fails open and silent, so a broken hook cannot stop a dispatch.
#
#   ./tests/subagent-shell-context.test.sh   (sandboxed is fine)
set -uo pipefail
SRC="$(cd "$(dirname "$0")/.." && pwd)"
HOOK="$SRC/dot_claude/hooks/executable_subagent-shell-context.sh"
[ -f "$HOOK" ] || { echo "missing script under test: $HOOK" >&2; exit 2; }
pass=0; fail=0
_pass() { printf '  PASS: %s\n' "$1"; pass=$((pass + 1)); }
_fail() { printf '  FAIL: %s\n    | got: %s\n' "$1" "$2"; fail=$((fail + 1)); }
is() { if [ "$2" = "$3" ]; then _pass "$1"; else _fail "$1" "$2"; fi; }

T="$(mktemp -d "${TMPDIR:-/tmp}/subagent-ctx.XXXXXX")"
trap 'rm -rf "$T"' EXIT

# The line measured on 2026-11-14 (8 of 8 Sonnet 5.5 dispatches denied without it, none of the
# first calls with it). Word for word: a reworded line is an unmeasured one.
LINE="Shell: every Bash call starts fresh in the session's directory and a \`cd\` never carries over, so never begin a command with \`cd\` (the path guard denies it). Name every file by its absolute path."

# fire <agent_type> [PATH for the hook] -> sets OUT, ERR and RC
fire() {
  local path=${2:-$PATH}
  jq -cn --arg a "$1" \
    '{session_id:"sess-1",transcript_path:"/x.jsonl",cwd:"/work/repo",hook_event_name:"SubagentStart",agent_id:"agent-1",agent_type:$a}' \
    > "$T/in.json"
  OUT=$(PINNED_PATH="$path" /bin/bash "$HOOK" < "$T/in.json" 2> "$T/err"); RC=$?
  ERR=$(cat "$T/err")
}

echo "A. it adds the measured line as SubagentStart context"
fire sp-standard
is "exit 0" "$RC" 0
is "nothing on stderr" "$ERR" ""
is "the event is SubagentStart" "$(printf '%s' "$OUT" | jq -r '.hookSpecificOutput.hookEventName')" SubagentStart
is "the context is the measured line, word for word" "$(printf '%s' "$OUT" | jq -r '.hookSpecificOutput.additionalContext')" "$LINE"
fire Explore
is "every agent type gets the same line" "$(printf '%s' "$OUT" | jq -r '.hookSpecificOutput.additionalContext')" "$LINE"

echo "B. it never decides"
fire sp-reviewer
is "the output holds only hookSpecificOutput" "$(printf '%s' "$OUT" | jq -c 'keys')" '["hookSpecificOutput"]'
is "and that only the event and the context" "$(printf '%s' "$OUT" | jq -c '.hookSpecificOutput | keys')" '["additionalContext","hookEventName"]'

echo "C. it fails open and silent"
# A PATH holding cat and no jq, as a hook would find it on a machine without jq: the payload
# drains, so the run reaches jq and fails there.
mkdir "$T/nojq"
ln -s /bin/cat "$T/nojq/cat"
fire sp-standard "$T/nojq"
is "with no jq it still exits 0" "$RC" 0
is "and prints nothing on stdout" "$OUT" ""
is "or on stderr" "$ERR" ""
# A payload that cannot be read is an error like any other, even with jq present.
OUT=$(PINNED_PATH="$PATH" /bin/bash "$HOOK" < "$T" 2> "$T/err"); RC=$?
is "an unreadable payload exits 0" "$RC" 0
is "and prints nothing on stdout" "$OUT" ""
is "or on stderr" "$(cat "$T/err")" ""
OUT=$(PINNED_PATH="$PATH" /bin/bash "$HOOK" < /dev/null 2> "$T/err"); RC=$?
is "an empty payload still exits 0" "$RC" 0
is "and still adds the line: it never reads the payload" "$(printf '%s' "$OUT" | jq -r '.hookSpecificOutput.additionalContext')" "$LINE"

printf '\npassed: %d  failed: %d\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
