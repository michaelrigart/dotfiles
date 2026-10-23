#!/usr/bin/env bash
# Feeds fixtures through the Claude Desktop modify script and asserts the emitted config.
# The modify script is a pure stdin->stdout filter, so this needs no chezmoi run and never
# touches the deployed file. Run: ./tests/claude-desktop-config.test.sh
set -u
SRC="$(cd "$(dirname "$0")/.." && pwd)"
MOD="$SRC/Library/Application Support/Claude/modify_private_claude_desktop_config.json"
[ -f "$MOD" ] || { echo "missing script under test: $MOD" >&2; exit 2; }
pass=0; fail=0; OUT=""
L="$HOME/.local/bin/ha-mcp"

_pass() { echo "  PASS: $1"; pass=$((pass + 1)); }
_fail() { echo "  FAIL: $1"; printf '    | got: %s\n' "$2"; fail=$((fail + 1)); }
emit()  { OUT=$(printf '%s' "$1" | HOME="$HOME" /bin/bash "$MOD"); }
jq_is() { # jq_is <filter> <expected> <label>
  got=$(printf '%s' "$OUT" | jq -c "$1" 2>&1)
  if [ "$got" = "$2" ]; then _pass "$3"; else _fail "$3" "$got"; fi
}

echo "A. empty input yields only the Home Assistant entry"
EXP=$(jq -S -c -n --arg l "$L" '{mcpServers: {"Home Assistant": {command: $l}}}')
for in in '' $'  \n'; do
  emit "$in"
  got=$(printf '%s' "$OUT" | jq -S -c . 2>&1)
  if [ "$got" = "$EXP" ]; then _pass "empty input ($(printf '%s' "$in" | wc -c | tr -d ' ') bytes) emits exactly the entry"; else _fail "empty input emits exactly the entry" "$got"; fi
done

echo "B. everything else is kept"
emit '{"preferences":{"a":{"b":[1,2]},"c":true},"coworkUserFilesPath":"/x/y","mcpServers":{"Other":{"command":"x","args":["y"]}}}'
jq_is '.preferences'         '{"a":{"b":[1,2]},"c":true}'      "nested preferences unchanged"
jq_is '.coworkUserFilesPath' '"/x/y"'                          "coworkUserFilesPath unchanged"
jq_is '.mcpServers.Other'    '{"command":"x","args":["y"]}'    "other MCP server unchanged"

echo "C. a stale entry is replaced and its token is gone"
STALE='{"mcpServers":{"Home Assistant":{"command":"/u/uvx","args":["--python","3.13","ha-mcp@latest"],"env":{"HOMEASSISTANT_TOKEN":"SECRET-TOKEN-123"}}}}'
emit "$STALE"
jq_is '.mcpServers["Home Assistant"]' "$(jq -c -n --arg l "$L" '{command: $l}')" "entry is exactly the launcher command"
case "$OUT" in
  *SECRET-TOKEN-123*) _fail "output does not contain the token" "token present" ;;
  *) _pass "output does not contain the token" ;;
esac

echo "D. invalid input is refused with no stdout"
for bad in 'not json {' '{} {}'; do
  out=$(printf '%s' "$bad" | /bin/bash "$MOD" 2>/dev/null); rc=$?
  if [ "$rc" -ne 0 ] && [ -z "$out" ]; then _pass "refused: $bad"; else _fail "refused: $bad" "rc=$rc stdout=$out"; fi
done

echo "E. idempotent"
emit '{"preferences":{"a":1},"mcpServers":{"Other":{"command":"x"}}}'
FIRST=$OUT
emit "$FIRST"
if [ "$OUT" = "$FIRST" ]; then _pass "a second pass emits byte-identical output"; else _fail "a second pass emits byte-identical output" "$OUT"; fi

echo; echo "RESULT: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
