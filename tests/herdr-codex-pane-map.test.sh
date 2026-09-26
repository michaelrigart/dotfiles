#!/usr/bin/env bash
# Tests dot_codex/executable_herdr-codex-pane-map.py (spec section 6). The hook runs inside
# the Codex daemon on every SessionStart and reconciles herdr's session id for EVERY Codex
# pane from the thread id at the start of its title - so one wrong report, from anywhere, is
# repaired by the next session start. It must never guess and never fail a session.
#
# Run: ./tests/run.sh herdr-codex-pane-map   (sandboxed is fine)
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
HOOK="$ROOT/dot_codex/executable_herdr-codex-pane-map.py"
[ -f "$HOOK" ] || { echo "missing file under test: $HOOK" >&2; exit 2; }
pass=0; fail=0
_pass() { printf '  PASS: %s\n' "$1"; pass=$((pass + 1)); }
_fail() { printf '  FAIL: %s\n    | got: %s\n' "$1" "$2"; fail=$((fail + 1)); }
is() { if [ "$2" = "$3" ]; then _pass "$1"; else _fail "$1" "$2"; fi; }

T="$(mktemp -d "${TMPDIR:-/tmp}/pane-map.XXXXXX")"; trap 'rm -rf "$T"' EXIT
export CALLS="$T/calls" PANES="$T/panes.json" HERDR_BIN="$T/herdr" PANE_MAP_RETRY_SECS=1
cat > "$T/herdr" <<'H'
#!/bin/sh
case "$1 $2" in
  "pane list") [ -n "${HERDR_FAIL:-}" ] && exit 1; cat "$PANES" ;;
  "pane report-agent-session") shift 2; echo "$*" >> "$CALLS" ;;
esac
exit 0
H
chmod +x "$T/herdr"
U1=11111111-1111-4111-8111-111111111111
U2=22222222-2222-4222-8222-222222222222
U3=33333333-3333-4333-8333-333333333333
pane() { # pane <id> <agent> <title> <session-or-empty>
  local s='null'; [ -n "$4" ] && s="{\"value\":\"$4\"}"
  printf '{"pane_id":"%s","agent":"%s","terminal_title":"◐ %s","terminal_title_stripped":"%s","agent_session":%s}' \
    "$1" "$2" "$3" "$3" "$s"
}
fixture() { printf '{"result":{"panes":[%s]}}' "$1" > "$PANES"; : > "$CALLS"; }
hook() { python3 "$HOOK" "$@"; }
reports() { grep -c . "$CALLS" 2>/dev/null || true; }

echo "A. --reconcile repairs every Codex pane whose title disagrees"
fixture "$(pane w1:p2 codex "$U1 | t | d" "")","$(pane w2:p2 codex "$U2 | t | d" "$U2")","$(pane w3:p2 codex "Greet user | chezmoi" "$U3")","$(pane w4:p1 claude "$U3 | x" "")","$(pane w5:p2 codex "$U3 | t | d" "$U1")"
hook --reconcile; rc=$?
is "it exits 0"                                     "$rc" 0
is "two panes disagreed, two reports"               "$(reports)" 2
is "a pane with no session gets its title's id"     "$(grep -c "^w1:p2 --source herdr:codex --agent codex --agent-session-id $U1 --seq [0-9]*$" "$CALLS")" 1
is "a pane showing another pane's id is corrected"  "$(grep -c "^w5:p2 .*--agent-session-id $U3 " "$CALLS")" 1
is "a matching pane is left alone"                  "$(grep -c '^w2:p2' "$CALLS")" 0
is "a title without a UUID is never guessed from"   "$(grep -c '^w3:p2' "$CALLS")" 0
is "a non-Codex pane is ignored"                    "$(grep -c '^w4:p1' "$CALLS")" 0

echo "B. as a SessionStart hook"
fixture "$(pane w1:p2 codex "$U1 | t | d" "")"
printf '{"hook_event_name":"SessionStart","session_id":"%s","source":"startup"}' "$U1" | hook; rc=$?
is "it exits 0" "$rc" 0
is "the starting session's pane carries its start source" \
   "$(grep -c "^w1:p2 .*--agent-session-id $U1 .*--session-start-source startup$" "$CALLS")" 1

echo "C. a session whose id is on no title yet"
fixture "$(pane w1:p2 codex "$U1 | t | d" "$U1")"
start=$(date +%s)
printf '{"session_id":"%s","source":"startup"}' "$U2" | hook; rc=$?
took=$(( $(date +%s) - start ))
is "it gives up and exits 0"              "$rc" 0
is "within its retry budget"              "$([ "$took" -le 3 ] && echo yes || echo "no ($took s)")" yes
is "and reports nothing it cannot see"    "$(reports)" 0

echo "D. repeated passes never report the same thing twice"
fixture "$(pane w1:p2 codex "$U1 | t | d" "")"
printf '{"session_id":"%s"}' "$U2" | hook
is "one report despite several retry passes" "$(reports)" 1

echo "F. the whole run stays inside its deadline"
# Four reports that each stall for 2 s would take 8 s; the hook timeout is 10 s and the
# pass must never be what Codex kills.
cat > "$T/slowherdr" <<'H'
#!/bin/sh
case "$1 $2" in
  "pane list") cat "$PANES" ;;
  "pane report-agent-session") sleep 2 ;;
esac
exit 0
H
chmod +x "$T/slowherdr"
U4=44444444-4444-4444-8444-444444444444
fixture "$(pane w1:p2 codex "$U1 | t" "")","$(pane w2:p2 codex "$U2 | t" "")","$(pane w3:p2 codex "$U3 | t" "")","$(pane w6:p2 codex "$U4 | t" "")"
start=$(date +%s)
HERDR_BIN="$T/slowherdr" PANE_MAP_DEADLINE_SECS=3 hook --reconcile; rc=$?
took=$(( $(date +%s) - start ))
is "stalled reports still end within the deadline" "$([ "$took" -le 4 ] && echo yes || echo "no ($took s)")" yes
is "and exit 0" "$rc" 0

echo "E. it never fails a session"
fixture ""
HERDR_FAIL=1 hook --reconcile; is "herdr failing exits 0" "$?" 0
printf 'not json' > "$PANES"; hook --reconcile; is "garbage from herdr exits 0" "$?" 0
printf '{{{' | hook; is "garbage on stdin exits 0" "$?" 0
HERDR_BIN="$T/nonexistent" hook --reconcile; is "no herdr at all exits 0" "$?" 0

echo
echo "RESULT: $pass passed, $((pass + fail)) total, $fail failed"
[ "$fail" -eq 0 ]
