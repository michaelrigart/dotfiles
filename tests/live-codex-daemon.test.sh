#!/usr/bin/env bash
# Live canary for xreview's Codex daemon path: the real daemon, a scratch herdr tab and one
# small real turn. Re-checks facts F11 and F14-F17 and the pane-map hook after a Codex update,
# when the experimental app-server protocol may have moved (spec section 9). Needs everything
# deployed (`chezmoi apply`) and a clean daemon (`codex-daemon check`).
# test-requires: unsandboxed, herdr, codex-daemon  # drives the real daemon and a scratch herdr tab
set -uo pipefail
SRC="$(cd "$(dirname "$0")/.." && pwd)"
RPCF="$SRC/dot_local/bin/executable_xreview-rpc"
SCHEMA="$SRC/dot_config/xreview/findings.schema.json"
PCMD="$SRC/dot_config/herdr/codex-pane-command"
for f in "$RPCF" "$SCHEMA" "$PCMD"; do
  [ -f "$f" ] || { echo "missing file under test: $f" >&2; exit 2; }
done
pass=0; fail=0
_pass() { printf '  PASS: %s\n' "$1"; pass=$((pass + 1)); }
_fail() { printf '  FAIL: %s\n    | got: %s\n' "$1" "$2"; fail=$((fail + 1)); }
is() { if [ "$2" = "$3" ]; then _pass "$1"; else _fail "$1" "$2"; fi; }
rpc() { python3 "$RPCF" "$@"; }

command -v herdr >/dev/null || { echo "INCONCLUSIVE: herdr not on PATH" >&2; exit 2; }
command -v jq >/dev/null || { echo "INCONCLUSIVE: jq not on PATH" >&2; exit 2; }
codex-daemon check || { echo "INCONCLUSIVE: the Codex daemon is not running clean" >&2; exit 2; }
ws="${HERDR_WORKSPACE_ID:-}"
[ -n "$ws" ] || { echo "INCONCLUSIVE: run from inside a herdr pane" >&2; exit 2; }

T="$(mktemp -d "${TMPDIR:-/tmp}/live-codex.XXXXXX")"
tab=""; pane=""; thread=""
cleanup() {
  if [ -n "$pane" ]; then
    herdr pane send-keys "$pane" ctrl+c >/dev/null 2>&1; sleep 0.5
    herdr pane send-keys "$pane" ctrl+c >/dev/null 2>&1; sleep 1
  fi
  [ -n "$tab" ] && herdr tab close "$tab" >/dev/null 2>&1
  [ -n "$thread" ] && rpc thread-archive --thread "$thread" >/dev/null 2>&1
  rm -rf "$T"
}
trap cleanup EXIT

out="$(herdr tab create --workspace "$ws" --cwd "$SRC" --label live-codex --no-focus)"
tab="$(printf '%s' "$out" | jq -r '.result.tab.tab_id')"
pane="$(printf '%s' "$out" | jq -r '.result.root_pane.pane_id')"
if [ -z "$tab" ] || [ "$tab" = "null" ] || [ -z "$pane" ] || [ "$pane" = "null" ]; then
  echo "INCONCLUSIVE: herdr tab create returned no usable tab/pane id" >&2
  printf '%s\n' "$out" >&2
  exit 2
fi
herdr pane run "$pane" "$(grep -v '^[[:space:]]*#' "$PCMD" | grep . | head -1)" >/dev/null

echo "F11/F14: the title carries the thread id at launch, and the daemon has it loaded"
t=""
for _ in $(seq 20); do
  t="$(herdr pane get "$pane" | jq -r '.result.pane.terminal_title_stripped // .result.pane.terminal_title // ""')"
  thread="$(printf '%s' "$t" | grep -oE '^[[:space:]]*[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}' | tr -d ' ' || true)"
  [ -n "$thread" ] && break; sleep 1
done
if [ -n "$thread" ]; then _pass "the pane title starts with the thread id"; else _fail "the pane title starts with the thread id" "$t"; fi
is "the daemon has the new thread loaded" "$(rpc thread-status --thread "$thread" | jq -r .loaded)" true

echo "F15: a turn from another client renders in the pane"
printf 'Live canary. Reply with verdict "approve" and no findings.\n' > "$T/in"
turn="$(rpc turn-start --thread "$thread" --input "$T/in" --schema "$SCHEMA")"
seen=0
for _ in $(seq 10); do
  grep -q 'Live canary' <<<"$(herdr pane read "$pane" 2>/dev/null)" && { seen=1; break; }; sleep 1
done
is "the pane shows the turn another client started" "$seen" 1

echo "F16/F17: waiting from a fresh connection returns schema-valid JSON"
res="$(rpc turn-wait --thread "$thread" --turn "$turn" --budget 180 --schema "$SCHEMA")"; rc=$?
is "turn-wait completes" "$rc" 0
is "with the schema's verdict" "$(printf '%s' "$res" | jq -r .verdict 2>/dev/null)" approve

echo "the pane-map hook tells herdr the pane's thread after its first turn"
s=""
for _ in $(seq 15); do
  s="$(herdr pane get "$pane" | jq -r '.result.pane.agent_session.value // empty')"
  [ "$s" = "$thread" ] && break; sleep 1
done
is "herdr knows the scratch pane's thread" "$s" "$thread"

printf '\npassed: %d  failed: %d\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
