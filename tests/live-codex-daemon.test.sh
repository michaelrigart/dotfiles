#!/usr/bin/env bash
# Live canary for xreview's Codex daemon path: the real daemon, a scratch herdr tab and one
# small real turn. Re-checks facts F11, F21 and F14-F17 and the pane-map hook after a Codex
# update, when the experimental app-server protocol may have moved (spec section 9). The title
# only ever carries a thread-id PREFIX (F11/F21); this asserts both that the title carries one
# and that it resolves to exactly one loaded thread. Needs everything deployed
# (`chezmoi apply`) and a clean daemon (`codex-daemon check`).
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
tab=""; pane=""; thread=""; prefix=""; wait_pid=""; f22_thread=""
cleanup() {
  # A turn-wait backgrounded for F16/F17 must never outlive an early exit above it.
  if [ -n "$wait_pid" ] && kill -0 "$wait_pid" 2>/dev/null; then
    kill "$wait_pid" 2>/dev/null
  fi
  if [ -n "$pane" ]; then
    herdr pane send-keys "$pane" ctrl+c >/dev/null 2>&1; sleep 0.5
    herdr pane send-keys "$pane" ctrl+c >/dev/null 2>&1; sleep 1
  fi
  [ -n "$tab" ] && herdr tab close "$tab" >/dev/null 2>&1
  # thread is only set once F11/F21/F14 resolves it; an earlier exit leaves it empty even
  # though a title prefix was already seen. Resolve it here too, so the scratch thread this
  # run actually started still gets archived instead of leaking.
  if [ -z "$thread" ] && [ -n "$prefix" ]; then
    thread="$(rpc thread-resolve --prefix "$prefix" 2>/dev/null)" || thread=""
  fi
  [ -n "$thread" ] && rpc thread-archive --thread "$thread" >/dev/null 2>&1
  [ -n "$f22_thread" ] && rpc thread-archive --thread "$f22_thread" >/dev/null 2>&1
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

echo "F11/F21/F14: the title carries a thread-id prefix at launch, and it resolves to one loaded thread"
t=""; prefix=""
for _ in $(seq 20); do
  t="$(herdr pane get "$pane" | jq -r '.result.pane.terminal_title_stripped // .result.pane.terminal_title // ""')"
  prefix="$(printf '%s' "$t" | grep -oE '^[[:space:]]*[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{5,12}' | tr -d ' ' || true)"
  [ -n "$prefix" ] && break; sleep 1
done
if [ -n "$prefix" ]; then _pass "the pane title carries a thread-id prefix"; else _fail "the pane title carries a thread-id prefix" "$t"; fi
thread="$(rpc thread-resolve --prefix "$prefix")"; rc=$?
is "it resolves to one loaded thread" "$rc" 0
is "the daemon has the resolved thread loaded" "$(rpc thread-status --thread "$thread" | jq -r .loaded)" true

echo "F15: a turn from another client renders in the pane"
printf 'Live canary. Reply with verdict "approve" and no findings.\n' > "$T/in"
turn="$(rpc turn-start --thread "$thread" --input "$T/in" --schema "$SCHEMA")"
# turn-wait starts right after turn-start, in the background, so it subscribes and
# waits on the turn/completed NOTIFICATION (F5) rather than only finding an
# already-finished turn later via thread/turns/list.
rpc turn-wait --thread "$thread" --turn "$turn" --budget 180 --schema "$SCHEMA" \
  > "$T/wait.out" 2> "$T/wait.err" &
wait_pid=$!
seen=0
for _ in $(seq 10); do
  grep -q 'Live canary' <<<"$(herdr pane read "$pane" 2>/dev/null)" && { seen=1; break; }; sleep 1
done
is "the pane shows the turn another client started" "$seen" 1

echo "F16/F17: waiting from a fresh connection returns schema-valid JSON"
wait "$wait_pid"; rc=$?
res="$(cat "$T/wait.out")"
is "turn-wait completes" "$rc" 0
# rc 0 already proves schema validity; a model answering "changes" is not protocol
# drift, so either verdict the schema allows is accepted here.
verdict="$(printf '%s' "$res" | jq -r .verdict 2>/dev/null)"
case "$verdict" in
  approve|changes) _pass "with a schema-valid verdict ($verdict)" ;;
  *) _fail "with a schema-valid verdict" "$verdict" ;;
esac

echo "the pane-map hook tells herdr the pane's thread after its first turn"
s=""
for _ in $(seq 15); do
  s="$(herdr pane get "$pane" | jq -r '.result.pane.agent_session.value // empty')"
  [ "$s" = "$thread" ] && break; sleep 1
done
is "herdr knows the scratch pane's thread" "$s" "$thread"

echo "F22: codex resume on a thread with a turn already running replays it, then streams live"
# The exact scenario xreview dispatch now relies on (spec 7.3 step 4): create a thread and
# start a turn on it BEFORE any TUI is attached, then resume a pane onto it while the turn
# is still running. The probe (2026-09-28) found the TUI renders the whole turn from its
# start, prompt included, then streams the rest live.
f22_thread="$(rpc thread-start --cwd "$SRC")"; rc=$?
is "F22 thread-start creates a thread" "$rc/$([ -n "$f22_thread" ] && echo yes || echo no)" "0/yes"
printf 'Live canary F22. Reply with verdict "approve" and no findings.\n' > "$T/in22"
f22_turn="$(rpc turn-start --thread "$f22_thread" --input "$T/in22" --schema "$SCHEMA")"
# turn-wait starts before the pane is even resumed, in the background, so it subscribes and
# catches turn/completed (F5) regardless of how long the resume itself takes.
rpc turn-wait --thread "$f22_thread" --turn "$f22_turn" --budget 180 --schema "$SCHEMA" \
  > "$T/wait22.out" 2> "$T/wait22.err" &
wait_pid=$!
pane_cmd="$(grep -v '^[[:space:]]*#' "$PCMD" | grep . | head -1)"
herdr pane run "$pane" "$pane_cmd resume $f22_thread" >/dev/null
seen22=0
for _ in $(seq 15); do
  out22="$(herdr pane read "$pane" --source visible 2>/dev/null)"
  if printf '%s' "$out22" | grep -q 'Live canary F22' || printf '%s' "$out22" | grep -qi 'Working'; then
    seen22=1; break
  fi
  sleep 1
done
is "F22 the resumed pane shows the turn while it runs (prompt or Working)" "$seen22" 1
wait "$wait_pid"; rc=$?
res22="$(cat "$T/wait22.out")"
is "F22 turn-wait completes" "$rc" 0
verdict22="$(printf '%s' "$res22" | jq -r .verdict 2>/dev/null)"
case "$verdict22" in
  approve|changes) _pass "F22 with a schema-valid verdict ($verdict22)" ;;
  *) _fail "F22 with a schema-valid verdict" "$verdict22" ;;
esac
seen22final=0
for _ in $(seq 15); do
  out22f="$(herdr pane read "$pane" --source visible 2>/dev/null)"
  printf '%s' "$out22f" | grep -qi "$verdict22" && { seen22final=1; break; }
  sleep 1
done
is "F22 the pane shows the final answer once the turn completes" "$seen22final" 1

printf '\npassed: %d  failed: %d\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
