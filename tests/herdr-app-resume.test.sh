#!/usr/bin/env bash
# Tests for the herdr-app resume helpers. Run: ./tests/herdr-app-resume.test.sh
set -uo pipefail

SRC=$(cd "$(dirname "$0")/.." && pwd)
H=$SRC/dot_config/herdr-app/bin/executable_session-running
for f in "$H"; do
  [ -f "$f" ] || { echo "missing ${f#"$SRC"/}" >&2; exit 2; }
done
root=$(mktemp -d "${TMPDIR:-/tmp}/herdr-app-resume.XXXXXX") || exit 1
trap 'rm -rf "$root"' EXIT
export HOME=$root
unset CODEX_HOME

passed=0 total=0
check() { # <description> <command...>: passes when the command succeeds
  local what=$1; shift
  total=$((total + 1))
  if "$@"; then passed=$((passed + 1)); echo "  PASS: $what"; else echo "  FAIL: $what"; fi
}
rc() { "$H" "$@" >/dev/null 2>&1; echo $?; }

# --- session-running ------------------------------------------------------------------------
c=11111111-1111-4111-8111-111111111111 x=22222222-2222-4222-8222-222222222222 u=33333333-3333-4333-8333-333333333333
mkdir -p "$HOME/.claude/sessions" "$HOME/.codex/sessions/2026/11/15" "$HOME/.config/herdr"
sleep 60 & live=$!
printf '{"pid":%d,"sessionId":"%s"}' "$live" "$c" > "$HOME/.claude/sessions/$live.json"
check "a Claude session whose registry pid is alive is running" test "$(rc claude $c)" = 0
kill "$live"; wait "$live" 2>/dev/null
check "...and is not once that pid is dead" test "$(rc claude $c)" = 1
f="$HOME/.codex/sessions/2026/11/15/rollout-2026-11-15T00-00-00-$x.jsonl"; : > "$f"
exec 3<"$f"
check "a Codex session whose rollout is held open is running" test "$(rc codex $x)" = 0
exec 3<&-
check "...and is not once it is closed" test "$(rc codex $x)" = 1
printf '{"workspaces":[{"tabs":[{"panes":[{"agent_session":{"agent":"codex","kind":"id","source":"herdr:codex","value":"%s"}}]}]}]}' "$u" > "$HOME/.config/herdr/session.json"
check "a session the herdr TUI keeps is running" test "$(rc codex $u)" = 0

echo "$passed/$total passed"
[ "$passed" -eq "$total" ]
