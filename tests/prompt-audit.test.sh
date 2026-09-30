#!/usr/bin/env bash
# Tests for dot_claude/hooks/executable_prompt-audit.sh, the PermissionRequest hook that
# logs each permission prompt for the safe-autonomy evaluation (spec 2026-09-30, section 5).
#
# Pins the two promises the hook makes: it never decides (prints nothing), and it never
# logs a command line, only its first word or two. Fixture secrets are assembled at
# runtime so no committed line looks like one.
#
#   ./tests/prompt-audit.test.sh   (sandboxed is fine)
set -uo pipefail
SRC="$(cd "$(dirname "$0")/.." && pwd)"
HOOK="$SRC/dot_claude/hooks/executable_prompt-audit.sh"
[ -f "$HOOK" ] || { echo "missing script under test: $HOOK" >&2; exit 2; }
pass=0; fail=0
_pass() { printf '  PASS: %s\n' "$1"; pass=$((pass + 1)); }
_fail() { printf '  FAIL: %s\n    | got: %s\n' "$1" "$2"; fail=$((fail + 1)); }
is() { if [ "$2" = "$3" ]; then _pass "$1"; else _fail "$1" "$2"; fi; }

ROOT="$(mktemp -d "${TMPDIR:-/tmp}/promptaudit.XXXXXX")"
trap 'rm -rf "$ROOT"' EXIT
export XDG_STATE_HOME="$ROOT/state"
LOG="$XDG_STATE_HOME/agent-audit/prompts.jsonl"

# fire <tool> <tool_input json> -> the hook's stdout
fire() {
  jq -cn --arg t "$1" --argjson i "$2" \
    '{hook_event_name:"PermissionRequest",session_id:"sess-1",cwd:"/work/repo",tool_name:$t,tool_input:$i,permission_suggestions:[]}' \
    | bash "$HOOK"
}
bash_cmd() { fire Bash "$(jq -cn --arg c "$1" '{command:$c,description:"d"}')"; }
last() { tail -1 "$LOG" | jq -r "$1"; }

is "it prints nothing: the prompt is never decided" "$(bash_cmd 'git push origin main')" ""
is "the log line carries the session"   "$(last .session)" sess-1
is "and the cwd"                        "$(last .cwd)" /work/repo
is "and the tool"                       "$(last .tool)" Bash
is "a multi-command tool keeps its subcommand" "$(last .subcommand)" "git push"
last '.ts' | grep -Eq '^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$' \
  && _pass "the timestamp is UTC ISO-8601" || _fail "the timestamp is UTC ISO-8601" "$(last .ts)"
is "exactly the five fields" "$(tail -1 "$LOG" | jq -c 'keys')" '["cwd","session","subcommand","tool","ts"]'

word=hunter; secret="${word}2-$RANDOM"
bash_cmd "TOKEN=$secret git push origin main" >/dev/null
is "leading assignments are skipped"    "$(last .subcommand)" "git push"
bash_cmd "echo $secret" >/dev/null
is "any other tool logs its first word only" "$(last .subcommand)" echo
bash_cmd "curl -H \"Authorization: Bearer $secret\" https://example.com" >/dev/null
is "flags are never logged"             "$(last .subcommand)" curl
bash_cmd "op read op://Private/item/$secret" >/dev/null
is "op read is logged as op read"       "$(last .subcommand)" "op read"
# The split is on whitespace, which a quote, an escaped space or a substitution in an
# assignment can span: the word after it may be a fragment of the value, so nothing is
# logged. Two distinct fragments, so the log check below names which one leaked.
quoted="${word}3q$RANDOM"; escaped="${word}4e$RANDOM"
bash_cmd "TOKEN='prefix $quoted suffix' git push origin main" >/dev/null
is "a quoted assignment spanning words logs no subcommand" "$(last .subcommand)" ""
bash_cmd "TOKEN=\"prefix $quoted suffix\" git push origin main" >/dev/null
is "a double-quoted one logs none either" "$(last .subcommand)" ""
bash_cmd "TOKEN=my\\ $escaped git push origin main" >/dev/null
is "an escaped space in an assignment logs no subcommand" "$(last .subcommand)" ""
bash_cmd "TOKEN=\$(cat $escaped file) git push origin main" >/dev/null
is "a substitution spanning words logs no subcommand" "$(last .subcommand)" ""
bash_cmd "TOKEN=plain git push origin main" >/dev/null
is "a plain assignment still logs the subcommand" "$(last .subcommand)" "git push"
# claude and codex take a free-text prompt as their second word.
bash_cmd "claude $quoted" >/dev/null
is "claude logs its first word only" "$(last .subcommand)" claude
bash_cmd "codex $escaped" >/dev/null
is "codex logs its first word only" "$(last .subcommand)" codex
for f in "$quoted" "$escaped"; do
  if grep -q "$f" "$LOG"; then _fail "the fragment $f appears nowhere in the log" "$(grep -c "$f" "$LOG") lines"
  else _pass "the fragment $f appears nowhere in the log"; fi
done
if grep -q "$secret" "$LOG"; then _fail "no secret ever reaches the log" "$(grep -c "$secret" "$LOG") lines"
else _pass "no secret ever reaches the log"; fi

fire mcp__claude_ai_Microsoft_365__outlook_send_mail "$(jq -cn --arg b "$secret" '{to:"a@b",body:$b}')" >/dev/null
is "an MCP tool logs the tool name"     "$(last .subcommand)" mcp__claude_ai_Microsoft_365__outlook_send_mail
fire Edit '{"file_path":"/work/repo/x","old_string":"a","new_string":"b"}' >/dev/null
is "any other tool logs no subcommand"  "$(last .subcommand)" ""

lines=$(wc -l < "$LOG" | tr -d ' ')
out=$(printf 'not json' | bash "$HOOK"; echo "rc=$?")
is "a malformed payload fails open and silent" "$out" "rc=0"
is "and appends nothing" "$(wc -l < "$LOG" | tr -d ' ')" "$lines"
out=$(printf '' | bash "$HOOK"; echo "rc=$?")
is "an empty payload fails open and silent" "$out" "rc=0"

mkdir -p "$ROOT/ro/agent-audit"; : > "$ROOT/ro/agent-audit/prompts.jsonl"; chmod 444 "$ROOT/ro/agent-audit/prompts.jsonl"
out=$(XDG_STATE_HOME="$ROOT/ro" bash_cmd 'git push' 2>&1; echo "rc=$?")
is "an unwritable log fails open and silent" "$out" "rc=0"

printf '\npassed: %d  failed: %d\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
