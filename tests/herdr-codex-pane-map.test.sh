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
export U1=11111111-1111-4111-8111-111111111111
export U2=22222222-2222-4222-8222-222222222222
export U3=33333333-3333-4333-8333-333333333333
export RPC_CALLS="$T/rpc-calls"
# Codex truncates tui.terminal_title's thread-id item to 29 chars plus "..." once the thread
# is named (F11/F21), so a realistic fixture title never carries the full id.
trunc() { printf '%s...' "$(printf '%s' "$1" | cut -c1-29)"; }
cat > "$T/xreview-rpc" <<'R'
#!/bin/sh
echo "$*" >> "$RPC_CALLS"
[ "$1" = "thread-resolve" ] || exit 2
shift
prefix=""
while [ "$#" -gt 0 ]; do case "$1" in --prefix) prefix="$2"; shift ;; esac; shift; done
for u in "$U1" "$U2" "$U3" "$U4"; do
  case "$u" in "$prefix"*) echo "$u"; exit 0 ;; esac
done
exit 1
R
chmod +x "$T/xreview-rpc"
export XREVIEW_RPC_BIN="$T/xreview-rpc"
pane() { # pane <id> <agent> <title> <session-or-empty>
  local s='null'; [ -n "$4" ] && s="{\"value\":\"$4\"}"
  printf '{"pane_id":"%s","agent":"%s","terminal_title":"◐ %s","terminal_title_stripped":"%s","agent_session":%s}' \
    "$1" "$2" "$3" "$3" "$s"
}
pane_raw() { # pane_raw <id> <agent> <title> <session-or-empty>: no terminal_title_stripped -
             # the fallback path (F12) must strip the leading spinner glyphs and whitespace itself.
  local s='null'; [ -n "$4" ] && s="{\"value\":\"$4\"}"
  printf '{"pane_id":"%s","agent":"%s","terminal_title":"  \xe2\x97\x90\xe2\x97\x91 %s","agent_session":%s}' \
    "$1" "$2" "$3" "$s"
}
fixture() { printf '{"result":{"panes":[%s]}}' "$1" > "$PANES"; : > "$CALLS"; : > "$RPC_CALLS"; }
hook() { python3 "$HOOK" "$@"; }
reports() { grep -c . "$CALLS" 2>/dev/null || true; }
rpc_calls() { grep -c . "$RPC_CALLS" 2>/dev/null || true; }

echo "A. --reconcile repairs every Codex pane whose title disagrees"
fixture "$(pane w1:p2 codex "$(trunc "$U1") | t | d" "")","$(pane w2:p2 codex "$(trunc "$U2") | t | d" "$U2")","$(pane w3:p2 codex "Greet user | chezmoi" "$U3")","$(pane w4:p1 claude "$(trunc "$U3") | x" "")","$(pane w5:p2 codex "$(trunc "$U3") | t | d" "$U1")"
hook --reconcile; rc=$?
is "it exits 0"                                     "$rc" 0
is "two panes disagreed, two reports"               "$(reports)" 2
is "a pane with no session gets its title's id, resolved"     "$(grep -c "^w1:p2 --source herdr:codex --agent codex --agent-session-id $U1 --seq [0-9]*$" "$CALLS")" 1
is "a pane showing another pane's id is corrected, resolved"  "$(grep -c "^w5:p2 .*--agent-session-id $U3 " "$CALLS")" 1
is "a matching pane is left alone, no resolve needed"          "$(grep -c '^w2:p2' "$CALLS")" 0
is "a title without an id prefix is never guessed from"        "$(grep -c '^w3:p2' "$CALLS")" 0
is "a non-Codex pane is ignored"                                "$(grep -c '^w4:p1' "$CALLS")" 0
seqs="$(grep -oE -- '--seq [0-9]+' "$CALLS" | awk '{print $2}' | sort -u | wc -l | tr -d ' ')"
is "both reports from the same listing share one --seq" "$seqs" 1
is "--reconcile resolves both prefixes through the stub" "$(rpc_calls)" 2

echo "B. as a SessionStart hook"
fixture "$(pane w1:p2 codex "$(trunc "$U1") | t | d" "")"
printf '{"hook_event_name":"SessionStart","session_id":"%s","source":"startup"}' "$U1" | hook; rc=$?
is "it exits 0" "$rc" 0
is "the starting session's pane carries its start source" \
   "$(grep -c "^w1:p2 .*--agent-session-id $U1 .*--session-start-source startup$" "$CALLS")" 1
is "hook mode confirms the shortcut through the resolver before trusting it" "$(rpc_calls)" 1

echo "C. a session whose id is on no title yet"
fixture "$(pane w1:p2 codex "$(trunc "$U1") | t | d" "$U1")"
start="$EPOCHREALTIME"
printf '{"session_id":"%s","source":"startup"}' "$U2" | hook; rc=$?
took="$(awk -v s="$start" -v e="$EPOCHREALTIME" 'BEGIN{printf "%.3f", e-s}')"
is "it gives up and exits 0"              "$rc" 0
is "within its retry budget"              "$(awk -v t="$took" 'BEGIN{print (t<=3) ? "yes" : "no ("t"s)"}')" yes
is "and reports nothing it cannot see"    "$(reports)" 0

echo "D. repeated passes never report the same thing twice"
fixture "$(pane w1:p2 codex "$(trunc "$U1") | t | d" "")"
printf '{"session_id":"%s"}' "$U2" | hook
is "one report despite several retry passes" "$(reports)" 1

echo "D2. a pane whose session already starts with the title prefix is left alone"
fixture "$(pane w1:p2 codex "$(trunc "$U1") | t | d" "$U1")"
hook --reconcile; rc=$?
is "it exits 0" "$rc" 0
is "no report" "$(reports)" 0
is "and the resolver is never called" "$(rpc_calls)" 0

echo "D3. a resolver that cannot resolve a prefix reports nothing, never a prefix"
U5=55555555-5555-4555-8555-555555555555   # never on the stub's known-id list
fixture "$(pane w7:p2 codex "$(trunc "$U5") | t | d" "")"
hook --reconcile; rc=$?
is "it exits 0" "$rc" 0
is "and reports nothing for the unresolved pane" "$(reports)" 0
is "the resolver was tried" "$(rpc_calls)" 1

echo "D4. a missing xreview-rpc binary reports nothing rather than guessing"
fixture "$(pane w8:p2 codex "$(trunc "$U1") | t | d" "")"
XREVIEW_RPC_BIN="$T/nonexistent-rpc" hook --reconcile; rc=$?
is "it exits 0" "$rc" 0
is "and reports nothing when the resolver cannot run" "$(reports)" 0

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
export U4=44444444-4444-4444-8444-444444444444
fixture "$(pane w1:p2 codex "$(trunc "$U1") | t" "")","$(pane w2:p2 codex "$(trunc "$U2") | t" "")","$(pane w3:p2 codex "$(trunc "$U3") | t" "")","$(pane w6:p2 codex "$(trunc "$U4") | t" "")"
start="$EPOCHREALTIME"
HERDR_BIN="$T/slowherdr" PANE_MAP_DEADLINE_SECS=3 hook --reconcile; rc=$?
took="$(awk -v s="$start" -v e="$EPOCHREALTIME" 'BEGIN{printf "%.3f", e-s}')"
is "stalled reports still end within the deadline" "$(awk -v t="$took" 'BEGIN{print (t<=4) ? "yes" : "no ("t"s)"}')" yes
is "and exit 0" "$rc" 0

echo "E. it never fails a session"
fixture ""
HERDR_FAIL=1 hook --reconcile; is "herdr failing exits 0" "$?" 0
printf 'not json' > "$PANES"; hook --reconcile; is "garbage from herdr exits 0" "$?" 0
printf '{{{' | hook; is "garbage on stdin exits 0" "$?" 0
HERDR_BIN="$T/nonexistent" hook --reconcile; is "no herdr at all exits 0" "$?" 0

echo "G. malformed env budgets fall back to their defaults, never raise"
fixture "$(pane w1:p2 codex "$(trunc "$U1") | t | d" "")"
out="$(PANE_MAP_DEADLINE_SECS=notanumber hook --reconcile 2>&1)"; rc=$?
is "a malformed deadline exits 0"          "$rc" 0
is "and still repairs the pane"            "$(reports)" 1
out="$(printf '{"session_id":"%s"}' "$U2" | PANE_MAP_RETRY_SECS='' hook 2>&1)"; rc=$?
is "an empty retry budget exits 0"         "$rc" 0

echo "H. the raw-title fallback strips leading spinner glyphs and whitespace"
fixture "$(pane_raw w1:p2 codex "$(trunc "$U1") | t | d" "")"
hook --reconcile; rc=$?
is "it exits 0"                                 "$rc" 0
is "the id under the spinner glyphs is still resolved" \
   "$(grep -c "^w1:p2 --source herdr:codex --agent codex --agent-session-id $U1 --seq [0-9]*$" "$CALLS")" 1

echo "I. malformed pane entries do not stop the rest of the pass"
badstr='"just a string, not a pane object"'
badagent='{"pane_id":"w9:p2","agent":"codex","terminal_title_stripped":"'"$(trunc "$U2")"' | t","agent_session":"not-an-object"}'
good="$(pane w11:p2 codex "$(trunc "$U3") | t" "")"
fixture "$badstr,$badagent,$good"
hook --reconcile; rc=$?
is "it exits 0 despite the malformed entries"      "$rc" 0
is "the good pane after them is still repaired"    "$(grep -c '^w11:p2' "$CALLS")" 1
is "M3 the pane with a string agent_session is skipped, never reported" \
   "$(grep -c '^w9:p2' "$CALLS")" 0

echo "I2. with two panes in hook mode, --session-start-source goes only to the starting pane"
fixture "$(pane w1:p2 codex "$(trunc "$U1") | t | d" "")","$(pane w2:p2 codex "$(trunc "$U3") | t | d" "")"
printf '{"session_id":"%s","source":"startup"}' "$U1" | hook; rc=$?
is "it exits 0"                                                  "$rc" 0
is "the starting session's pane carries the start source"        \
   "$(grep -c "^w1:p2 .*--session-start-source startup$" "$CALLS")" 1
is "the other, resolved pane is reported too"                     "$(grep -c '^w2:p2' "$CALLS")" 1
is "only the starting pane's report carries a start source"       "$(grep -c 'session-start-source' "$CALLS")" 1

echo "J. the hook's own pane is handled first each pass"
# Both panes disagree; a deadline that only allows one report must spend it on the pane
# that matches the hook's own session_id, not on the other one, whichever herdr lists first.
cat > "$T/slowreport" <<'H'
#!/bin/sh
case "$1 $2" in
  "pane list") cat "$PANES" ;;
  # The write happens AFTER the stall, so a report killed by the client's own timeout
  # (the deadline running out) never lands in $CALLS at all.
  "pane report-agent-session") shift 2; sleep 2; echo "$*" >> "$CALLS" ;;
esac
exit 0
H
chmod +x "$T/slowreport"
fixture "$(pane w1:p2 codex "$(trunc "$U1") | t" "")","$(pane w2:p2 codex "$(trunc "$U2") | t" "")"
printf '{"session_id":"%s","source":"startup"}' "$U2" \
  | HERDR_BIN="$T/slowreport" PANE_MAP_DEADLINE_SECS=3 PANE_MAP_RETRY_SECS=0 hook; rc=$?
is "it exits 0"                                            "$rc" 0
is "the session's own pane is reported"                    "$(grep -c '^w2:p2' "$CALLS")" 1
is "the deadline leaves no room for the other pane"        "$(grep -c '^w1:p2' "$CALLS")" 0

echo "K. a resolver that keeps failing is called at most once per prefix per run"
U6=66666666-6666-4666-8666-666666666666   # never on the stub's known-id list
fixture "$(pane w12:p2 codex "$(trunc "$U6") | t" "")"
printf '{"session_id":"%s"}' "$U1" | PANE_MAP_RETRY_SECS=1 hook; rc=$?
is "it exits 0"                                          "$rc" 0
is "the resolver is asked about the failing prefix only once, despite several retry passes" \
   "$(rpc_calls)" 1

echo "L. two panes sharing the same title prefix never both get the hook's own full id"
# Both panes' prefix is a prefix of the hook's own session_id, so the shortcut is ambiguous.
# It must fall back to the resolver for both, which refuses (ambiguous) - so neither is
# reported, and no later pass is left with two panes stuck on the same full id (item 13).
cat > "$T/failrpc" <<'R'
#!/bin/sh
echo "$*" >> "$RPC_CALLS"
exit 1
R
chmod +x "$T/failrpc"
fixture "$(pane w20:p2 codex "$(trunc "$U1") | t | d" "")","$(pane w21:p2 codex "$(trunc "$U1") | t | d" "")"
printf '{"session_id":"%s","source":"startup"}' "$U1" \
  | XREVIEW_RPC_BIN="$T/failrpc" PANE_MAP_RETRY_SECS=0 hook; rc=$?
is "it exits 0"                                                 "$rc" 0
is "neither ambiguous pane is reported"                          "$(reports)" 0
is "the resolver is asked once, for the shared prefix, and refuses" "$(rpc_calls)" 1

echo "M. the own-session shortcut confirms through the daemon before trusting itself (item 21/F13)"
# One matching pane does not prove the prefix names only THIS thread - two threads can share
# a 29-char prefix. The shortcut must confirm through xreview-rpc thread-resolve, and a
# resolver that cannot be reached at all confirms nothing.
cat > "$T/confirmrpc" <<'R'
#!/bin/sh
echo "$*" >> "$RPC_CALLS"
[ "$1" = "thread-resolve" ] || exit 2
case "${CONFIRM_MODE:-}" in
  same)    echo "$U1" ;;
  other)   echo "$U2" ;;
  refuse)  exit 1 ;;
  unreach) exit 5 ;;
  *)       exit 2 ;;
esac
R
chmod +x "$T/confirmrpc"

fixture "$(pane w1:p2 codex "$(trunc "$U1") | t | d" "")"
printf '{"session_id":"%s","source":"startup"}' "$U1" \
  | CONFIRM_MODE=same XREVIEW_RPC_BIN="$T/confirmrpc" PANE_MAP_RETRY_SECS=0 hook; rc=$?
is "M1 it exits 0"                                      "$rc" 0
is "M1 the resolver confirms the shortcut once"          "$(rpc_calls)" 1
is "M1 a confirmed session_id is reported"               \
   "$(grep -c "^w1:p2 .*--agent-session-id $U1 .*--session-start-source startup$" "$CALLS")" 1

fixture "$(pane w1:p2 codex "$(trunc "$U1") | t | d" "")"
printf '{"session_id":"%s","source":"startup"}' "$U1" \
  | CONFIRM_MODE=other XREVIEW_RPC_BIN="$T/confirmrpc" PANE_MAP_RETRY_SECS=0 hook; rc=$?
is "M2 it exits 0"                                      "$rc" 0
is "M2 a resolver naming a different thread reports nothing" "$(reports)" 0

fixture "$(pane w1:p2 codex "$(trunc "$U1") | t | d" "")"
printf '{"session_id":"%s","source":"startup"}' "$U1" \
  | CONFIRM_MODE=refuse XREVIEW_RPC_BIN="$T/confirmrpc" PANE_MAP_RETRY_SECS=0 hook; rc=$?
is "M3 it exits 0"                                      "$rc" 0
is "M3 a resolver refusing as ambiguous reports nothing" "$(reports)" 0

# Exit 5 (xreview-rpc's own "daemon unreachable") and a missing binary are both
# deterministic, no deadline or sleep involved.
fixture "$(pane w1:p2 codex "$(trunc "$U1") | t | d" "")"
printf '{"session_id":"%s","source":"startup"}' "$U1" \
  | CONFIRM_MODE=unreach XREVIEW_RPC_BIN="$T/confirmrpc" PANE_MAP_RETRY_SECS=0 hook; rc=$?
is "M4 it exits 0"                                      "$rc" 0
is "M4 an unreachable daemon (exit 5) reports nothing"  "$(reports)" 0

fixture "$(pane w1:p2 codex "$(trunc "$U1") | t | d" "")"
printf '{"session_id":"%s","source":"startup"}' "$U1" \
  | XREVIEW_RPC_BIN="$T/nonexistent-rpc" PANE_MAP_RETRY_SECS=0 hook; rc=$?
is "M5 it exits 0"                                      "$rc" 0
is "M5 a missing resolver binary also reports nothing" "$(reports)" 0

echo
echo "RESULT: $pass passed, $((pass + fail)) total, $fail failed"
[ "$fail" -eq 0 ]
