#!/usr/bin/env bash
# Tests for dot_local/bin/executable_xreview on the Codex daemon (spec section 7).
#
# Every collaborator is stubbed on PATH:
#   herdr         one Codex pane, w1:p2, whose title and agent live in files under $P
#   codex-daemon  ensure/check exit codes
#   xreview-rpc   thread status, turn start and wait, archive
# Each stub logs its calls to $CALLS, so ordering is asserted from the log. Nothing may
# reach the pane or the reviewer before the preconditions pass, and no turn may start
# before the pane shows the thread.
set -uo pipefail
SRC="$(cd "$(dirname "$0")/.." && pwd)"
XREVIEW="$SRC/dot_local/bin/executable_xreview"
[ -f "$XREVIEW" ] || { echo "missing CLI under test: $XREVIEW" >&2; exit 2; }
pass=0; fail=0
_pass() { printf '  PASS: %s\n' "$1"; pass=$((pass + 1)); }
_fail() { printf '  FAIL: %s\n    | got: %s\n' "$1" "$2"; fail=$((fail + 1)); }
is() { if [ "$2" = "$3" ]; then _pass "$1"; else _fail "$1" "$2"; fi; }

ROOT="$(mktemp -d "${TMPDIR:-/tmp}/xreview.XXXXXX")"
trap 'rm -rf "$ROOT"' EXIT
export XDG_STATE_HOME="$ROOT/state" XDG_CONFIG_HOME="$ROOT/config" CODEX_HOME="$ROOT/codex"
mkdir -p "$XDG_CONFIG_HOME/xreview" "$XDG_CONFIG_HOME/herdr"
cp "$SRC/dot_config/xreview/findings.schema.json" "$SRC/dot_config/xreview/reviewer.md" "$XDG_CONFIG_HOME/xreview/"
cp "$SRC/dot_config/herdr/codex-pane-command" "$XDG_CONFIG_HOME/herdr/"
export XREVIEW_PANE_WAIT=3
unset XREVIEW_MAX_ROUNDS XREVIEW_PANE XREVIEW_THREAD

mkdir -p "$ROOT/repo" && cd "$ROOT/repo" || exit 1
git init -q . && git config user.email t@t && git config user.name t
git config commit.gpgsign false
git commit -q --allow-empty -m init || { printf 'fixture setup failed\n' >&2; exit 1; }
printf 'body\n' > b.md
CWD="$(git rev-parse --show-toplevel)"
STATE="$XDG_STATE_HOME/xreview/$(printf '%s' "$CWD" | tr '/' '_' | sed 's/^_//')"

# --- stubs ------------------------------------------------------------------------
STUB="$ROOT/stub"; P="$ROOT/pane"; mkdir -p "$STUB" "$P"
export CALLS="$ROOT/calls" P CWD
U0=aaaaaaaa-0000-4000-8000-000000000000   # the thread the pane shows at the start
U1=bbbbbbbb-1111-4111-8111-111111111111   # the thread a fresh session in the pane creates
U2=cccccccc-2222-4222-8222-222222222222
export NEW_UUID="$U1"
cat > "$STUB/herdr" <<'H'
#!/bin/sh
echo "herdr $*" >> "$CALLS"
pane_json() {
  a="$(cat "$P/agent" 2>/dev/null)"; t="$(cat "$P/title" 2>/dev/null)"
  s="$(cat "$P/status" 2>/dev/null || echo idle)"
  af=""; [ -n "$a" ] && af="\"agent\":\"$a\","
  printf '{%s"agent_status":"%s","cwd":"%s","pane_id":"w1:p2","terminal_title":"%s","terminal_title_stripped":"%s"}' \
    "$af" "$s" "${PANE_CWD:-$CWD}" "$t" "$t"
}
case "$1 $2" in
  "pane list") printf '{"result":{"panes":[%s%s]}}\n' "$(pane_json)" "${EXTRA_PANES:-}" ;;
  "pane get") printf '{"result":{"pane":%s}}\n' "$(pane_json)" ;;
  "pane send-keys")
    n=$(cat "$P/ctrlc" 2>/dev/null || echo 0); n=$((n + 1)); echo "$n" > "$P/ctrlc"
    if [ "$n" -ge 2 ] && [ -z "${STUCK_TUI:-}" ]; then : > "$P/agent"; fi ;;
  "pane run")
    echo 0 > "$P/ctrlc"
    [ -n "${NO_TITLE:-}" ] && exit 0
    printf codex > "$P/agent"
    case "$4" in
      *" resume "*) printf '%s | t | d' "${4##* resume }" > "$P/title" ;;
      *) printf '%s | t | d' "$NEW_UUID" > "$P/title" ;;
    esac ;;
esac
exit 0
H
cat > "$STUB/codex-daemon" <<'D'
#!/bin/sh
echo "codex-daemon $*" >> "$CALLS"
case "$1" in
  ensure) exit "${ENSURE_RC:-0}" ;;
  check) [ "${CHECK_RC:-0}" = 0 ] || echo "codex-daemon: carries a herdr pane's environment" >&2
         exit "${CHECK_RC:-0}" ;;
esac
D
cat > "$STUB/xreview-rpc" <<'R'
#!/bin/sh
echo "xreview-rpc $*" >> "$CALLS"
cmd="$1"; shift
th=""; input=""; known=""; resolved=""
while [ "$#" -gt 0 ]; do
  case "$1" in --thread) th="$2"; shift ;; --input) input="$2"; shift ;; --known) known="$2"; shift ;;
               --resolved) resolved="$2"; shift ;; esac; shift
done
case "$cmd" in
  thread-status)
    n=$(cat "$P/status_calls" 2>/dev/null || echo 0); n=$((n + 1)); echo "$n" > "$P/status_calls"
    if [ -n "${RPC_NOT_LOADED:-}" ] || { [ -n "${RPC_NOT_LOADED_ONCE:-}" ] && [ "$n" = 1 ]; }; then
      echo '{"loaded":false,"status":"notLoaded","running":false}'
    else echo '{"loaded":true,"status":"idle","running":false}'; fi ;;
  turn-start) cp "$input" "$P/packet"; [ -n "$known" ] && echo '[]' > "$known"
              [ -n "${RPC_START_FAIL:-}" ] && exit 1
              [ -n "${RPC_START_UNCERTAIN:-}" ] && exit 6
              echo "turn-$th" ;;
  turn-wait) [ -n "$resolved" ] && echo turn-recovered > "$resolved"
             printf '%s\n' "${RPC_WAIT_OUT:-}"; exit "${RPC_WAIT_RC:-0}" ;;
esac
exit 0
R
chmod +x "$STUB"/*
export PATH="$STUB:$PATH"

fresh() { # a pane showing U0, idle; clean log and state
  unset ENSURE_RC CHECK_RC RPC_NOT_LOADED RPC_NOT_LOADED_ONCE RPC_START_FAIL RPC_START_UNCERTAIN \
        NO_TITLE STUCK_TUI EXTRA_PANES PANE_CWD XREVIEW_PANE XREVIEW_THREAD RPC_WAIT_OUT RPC_WAIT_RC
  export NEW_UUID="$U1"
  printf codex > "$P/agent"; printf '%s | t | d' "$U0" > "$P/title"; echo idle > "$P/status"
  echo 0 > "$P/ctrlc"; rm -f "$P/packet" "$P/status_calls"
  bash "$XREVIEW" round --reset >/dev/null 2>&1
  rm -rf "$STATE/superseded" "$STATE/pin" "$STATE/turns"
  : > "$CALLS"
}
called() { grep -c -- "$1" "$CALLS" 2>/dev/null || true; }
first() { grep -n -- "$1" "$CALLS" | head -1 | cut -d: -f1; }
untouched() { # nothing reached the pane or the reviewer
  [ "$(called 'herdr pane send-keys')$(called 'herdr pane run')$(called 'xreview-rpc turn-start')" = 000 ] && echo yes || echo no
}

echo "A. the round cap binds before a turn is spent"
fresh
capped() { bash "$XREVIEW" dispatch b.md 2>&1 | grep -c 'exceeds the cap'; }
is "round counter starts at zero" "$(bash "$XREVIEW" round)" 0
for _ in $(seq 9); do capped >/dev/null; done
is "nine rounds are permitted"        "$(bash "$XREVIEW" round)" 9
is "the tenth round is still allowed" "$(capped)" 0
starts="$(called 'xreview-rpc turn-start')"
is "the eleventh round is refused"    "$(capped)" 1
is "and starts no turn"               "$(called 'xreview-rpc turn-start')" "$starts"
is "a refused round still increments, so retrying stays refused" "$(bash "$XREVIEW" round)" 11
bash "$XREVIEW" round --reset >/dev/null
is "reset returns the counter to zero" "$(bash "$XREVIEW" round)" 0
XREVIEW_MAX_ROUNDS=1 bash "$XREVIEW" dispatch b.md >/dev/null 2>&1
is "XREVIEW_MAX_ROUNDS lowers the cap" "$(XREVIEW_MAX_ROUNDS=1 bash "$XREVIEW" dispatch b.md 2>&1 | grep -c 'exceeds the cap')" 1

echo "B. inline diffs"
# A dispatch that names a path makes the reviewer go and read it; carrying the diff inline
# lets it answer from what it was handed (measured 2026-09-01: ~16 steps per review).
printf 'change\n' > tracked.txt && git add tracked.txt && git commit -q -m "a change to review"
fresh
bash "$XREVIEW" dispatch --diff HEAD~1..HEAD b.md >/dev/null 2>&1
is "the diff travels in the packet"          "$(grep -q 'tracked.txt' "$P/packet" && echo yes || echo no)" yes
is "with the caller's body"                  "$(grep -c '^body$' "$P/packet")" 1
is "and the reviewer instructions"           "$(grep -c 'independent reviewer' "$P/packet")" 1
is "wrapped as an authorized request"        "$(head -1 "$P/packet")" "<cross-review-request>"
is "with no correlation line any more"       "$(grep -c 'correlation' "$P/packet")" 0
fresh
out="$(XREVIEW_MAX_DIFF_BYTES=10 bash "$XREVIEW" dispatch --diff HEAD~1..HEAD b.md 2>&1)"
is "an oversized diff is refused, never truncated" "$(printf '%s' "$out" | grep -c 'too large')" 1
is "before anything is touched" "$(untouched)" yes
fresh
out="$(bash "$XREVIEW" dispatch --diff no-such-ref..HEAD b.md 2>&1)"
is "an unresolvable range is refused" "$(printf '%s' "$out" | grep -c 'cannot diff')" 1
fresh
out="$(bash "$XREVIEW" dispatch --diff HEAD..HEAD b.md 2>&1)"
is "an empty range is refused" "$(printf '%s' "$out" | grep -c 'nothing to review')" 1
out="$(bash "$XREVIEW" dispatch --expect x b.md 2>&1)"; rc=$?
is "--expect is rejected, not absorbed" "$rc" 1
is "and mints no nonce" "$(printf '%s' "$out" | grep -c '^xr-')" 0

echo "C. preconditions refuse before anything is touched"
fresh; out="$(ENSURE_RC=1 bash "$XREVIEW" dispatch b.md 2>&1)"; rc=$?
is "C1 a daemon that will not start refuses" "$rc" 1
is "C1 untouched" "$(untouched)" yes
fresh; out="$(CHECK_RC=1 bash "$XREVIEW" dispatch b.md 2>&1)"; rc=$?
is "C2 a contaminated daemon refuses" "$rc" 1
is "C2 and says why" "$(printf '%s' "$out" | grep -c 'refusing to dispatch while the daemon')" 1
is "C2 untouched" "$(untouched)" yes
fresh; : > "$P/agent"; out="$(bash "$XREVIEW" dispatch b.md 2>&1)"; rc=$?
is "C3 no Codex pane refuses" "$(printf '%s' "$out" | grep -c 'no Codex pane')" 1
is "C3 untouched" "$(untouched)" yes
fresh
export EXTRA_PANES=",{\"agent\":\"codex\",\"agent_status\":\"idle\",\"cwd\":\"$CWD\",\"pane_id\":\"w9:p2\",\"terminal_title\":\"x\"}"
out="$(bash "$XREVIEW" dispatch b.md 2>&1)"
is "C4 several Codex panes refuse" "$(printf '%s' "$out" | grep -c 'several Codex panes')" 1
is "C4 naming both" "$(printf '%s' "$out" | grep -c 'w1:p2 w9:p2')" 1
is "C4 untouched" "$(untouched)" yes
out="$(XREVIEW_PANE=w1:p2 bash "$XREVIEW" dispatch b.md 2>&1)"
is "C5 XREVIEW_PANE picks one" "$(printf '%s' "$out" | grep -c '^xr-')" 1
fresh
export EXTRA_PANES=",{\"agent\":\"claude\",\"agent_status\":\"idle\",\"cwd\":\"$CWD\",\"pane_id\":\"w1:p1\",\"terminal_title\":\"x\"}"
out="$(XREVIEW_PANE=w1:p1 bash "$XREVIEW" dispatch b.md 2>&1)"; rc=$?
is "C9 XREVIEW_PANE naming a non-Codex pane refuses" "$rc" 1
is "C9 and names the pane" "$(printf '%s' "$out" | grep -c 'XREVIEW_PANE=w1:p1 is not a Codex pane')" 1
is "C9 untouched" "$(untouched)" yes
fresh; echo working > "$P/status"; out="$(bash "$XREVIEW" dispatch b.md 2>&1)"
is "C6 a pane mid-turn refuses" "$(printf '%s' "$out" | grep -c 'mid-turn')" 1
is "C6 untouched" "$(untouched)" yes
fresh; mkdir .codex; out="$(bash "$XREVIEW" dispatch b.md 2>&1)"; rmdir .codex
is "C7 a project .codex refuses" "$(printf '%s' "$out" | grep -c 'refusing to dispatch')" 1
is "C7 untouched" "$(untouched)" yes
fresh; out="$(XREVIEW_SCHEMA="$ROOT/none.json" bash "$XREVIEW" dispatch b.md 2>&1)"
is "C8 a missing schema refuses" "$(printf '%s' "$out" | grep -c 'missing findings schema')" 1

echo "D. the pane comes first"
fresh
nonce="$(bash "$XREVIEW" dispatch b.md 2>/dev/null)"
is "D1 a nonce is printed" "$(printf '%s' "$nonce" | grep -c '^xr-')" 1
is "D1 the pane's session is ended" "$(called 'herdr pane send-keys w1:p2 ctrl+c')" 2
is "D1 a fresh session runs the pane command" \
   "$(called 'herdr pane run w1:p2 codex --sandbox read-only --ask-for-approval never')" 1
is "D1 the new thread is confirmed loaded" "$(called "xreview-rpc thread-status --thread $U1")" 1
is "D1 herdr is told the pane's thread" \
   "$(called "herdr pane report-agent-session w1:p2 --source herdr:codex --agent codex --agent-session-id $U1")" 1
is "D1 the turn goes to the thread the pane shows" "$(called "xreview-rpc turn-start --thread $U1")" 1
is "D1 and only after the pane shows it" \
   "$([ "$(first 'herdr pane run')" -lt "$(first 'xreview-rpc turn-start')" ] && echo yes || echo no)" yes
is "D1 the checkpoint thread is recorded" "$(cat "$STATE/review-thread")" "$U1"
is "D1 the nonce maps to thread and turn" "$(cat "$STATE/turns/$nonce")" "$U1 turn-$U1"
: > "$CALLS"
bash "$XREVIEW" dispatch b.md >/dev/null 2>&1
is "D2 the next round finds the pane already on the thread" "$(called 'herdr pane send-keys')" 0
is "D2 and goes to the same thread" "$(called "xreview-rpc turn-start --thread $U1")" 1
printf '%s | t | d' "$U0" > "$P/title"; : > "$CALLS"
bash "$XREVIEW" dispatch b.md >/dev/null 2>&1
is "D3 a pane that moved off the thread is resumed onto it" "$(called "herdr pane run w1:p2 codex --sandbox read-only --ask-for-approval never resume $U1")" 1
fresh; out="$(NO_TITLE=1 bash "$XREVIEW" dispatch b.md 2>&1)"; rc=$?
is "D4 a pane that never shows a thread refuses" "$rc" 1
is "D4 and no turn starts" "$(called 'xreview-rpc turn-start')" 0
fresh; printf 'Greet user | chezmoi' > "$P/title"
nonce="$(bash "$XREVIEW" dispatch b.md 2>/dev/null)"
is "D5 a pane whose title has no id is restarted and adopted" "$(cat "$STATE/review-thread" 2>/dev/null)" "$U1"
fresh; out="$(STUCK_TUI=1 bash "$XREVIEW" dispatch b.md 2>&1)"; rc=$?
is "D6 a session that will not exit refuses" "$(printf '%s' "$out" | grep -c 'did not exit')" 1
is "D6 and never starts a new one" "$(called 'herdr pane run')" 0
fresh; out="$(RPC_NOT_LOADED=1 bash "$XREVIEW" dispatch b.md 2>&1)"; rc=$?
is "D7 a thread the daemon has not loaded refuses" "$rc" 1
is "D7 and no turn starts" "$(called 'xreview-rpc turn-start')" 0
fresh; out="$(RPC_START_FAIL=1 bash "$XREVIEW" dispatch b.md 2>&1)"; rc=$?
is "D8 a refused turn fails the dispatch" "$rc" 1
is "D8 and records no nonce" "$(ls "$STATE/turns" 2>/dev/null | grep -c .)" 0
fresh
bash "$XREVIEW" dispatch b.md >/dev/null 2>&1        # the pane now shows U1, recorded
: > "$CALLS"; rm -f "$P/status_calls"
RPC_NOT_LOADED_ONCE=1 bash "$XREVIEW" dispatch b.md >/dev/null 2>&1
is "D9 a matching title on a thread the daemon lost is resumed, not trusted" \
   "$(called "herdr pane run w1:p2 codex --sandbox read-only --ask-for-approval never resume $U1")" 1
is "D9 and the turn starts after that" "$(called "xreview-rpc turn-start --thread $U1")" 1
fresh
nonce="$(RPC_START_UNCERTAIN=1 bash "$XREVIEW" dispatch b.md 2>"$ROOT/err")"; rc=$?
is "D10 an unanswered turn/start still hands back a nonce" "$rc/$(printf '%s' "$nonce" | grep -c '^xr-')" "0/1"
is "D10 with a do-not-re-dispatch warning" "$(grep -c 'do NOT re-dispatch' "$ROOT/err")" 1
is "D10 the record marks the turn unknown" "$(cat "$STATE/turns/$nonce")" "$U1 ?"
RPC_WAIT_OUT='{"verdict":"approve","findings":[]}' bash "$XREVIEW" collect "$nonce" >/dev/null 2>&1
is "D10 collect looks for what is new on the thread" \
   "$(called "turn-wait --thread $U1 --new-since $STATE/turns/$nonce.known --resolved")" 1
is "D10 the recovered turn replaces the unknown in the record" "$(cat "$STATE/turns/$nonce")" "$U1 turn-recovered"
is "D10 and the receipt names it" "$(tail -1 "$STATE/reviews.jsonl" | jq -r .turn)" turn-recovered
: > "$CALLS"; bash "$XREVIEW" collect "$nonce" >/dev/null 2>&1
is "D10 a later collect waits on that turn by id" "$(called "turn-wait --thread $U1 --turn turn-recovered")" 1

fresh
bash "$XREVIEW" dispatch b.md >/dev/null 2>&1   # the pane is now on U1, and it is recorded
mkdir -p "$CODEX_HOME/app-server-daemon"; printf '{"pid":999}\n' > "$CODEX_HOME/app-server-daemon/daemon.pid"
: > "$CALLS"
bash "$XREVIEW" dispatch b.md >/dev/null 2>&1
is "D11 a daemon restart is detected even though the title still matches and the thread is loaded" \
   "$(called "herdr pane run w1:p2 codex --sandbox read-only --ask-for-approval never resume $U1")" 1
is "D11 and the turn starts only after the pane is re-pointed" \
   "$([ "$(first 'herdr pane run')" -lt "$(first 'xreview-rpc turn-start')" ] && echo yes || echo no)" yes
rm -rf "$CODEX_HOME/app-server-daemon"   # restore the "no daemon.pid yet" baseline for later tests

fresh
bash "$XREVIEW" init "$U0" >/dev/null    # the pin the pane's title already shows, nothing recorded
: > "$CALLS"
bash "$XREVIEW" dispatch b.md >/dev/null 2>&1
is "D12 a pin whose title already matches is still resumed once, with nothing recorded yet" \
   "$(called "herdr pane run w1:p2 codex --sandbox read-only --ask-for-approval never resume $U0")" 1
: > "$CALLS"
bash "$XREVIEW" dispatch b.md >/dev/null 2>&1
is "D12 the dispatch after that takes the fast path" "$(called 'herdr pane send-keys')" 0

echo "E. checkpoints and pins"
fresh
bash "$XREVIEW" dispatch b.md >/dev/null 2>&1
bash "$XREVIEW" round --reset >/dev/null 2>&1
is "E1 reset drops the checkpoint thread" "$([ -e "$STATE/review-thread" ] && echo kept || echo dropped)" dropped
export NEW_UUID="$U2"; : > "$CALLS"
bash "$XREVIEW" dispatch b.md >/dev/null 2>&1
is "E1 the next checkpoint starts a fresh thread" "$(cat "$STATE/review-thread")" "$U2"
is "E1 the old thread is archived" "$(called "xreview-rpc thread-archive --thread $U1")" 1
is "E1 after the new turn started" \
   "$([ "$(first 'xreview-rpc turn-start')" -lt "$(first 'xreview-rpc thread-archive')" ] && echo yes || echo no)" yes
fresh
bash "$XREVIEW" init "$U0" >/dev/null
nonce="$(bash "$XREVIEW" dispatch b.md 2>/dev/null)"
is "E2 a pin is used as the review thread" "$(called "xreview-rpc turn-start --thread $U0")" 1
is "E2 and is not recorded as a checkpoint thread" "$([ -e "$STATE/review-thread" ] && echo yes || echo no)" no
bash "$XREVIEW" round --reset >/dev/null 2>&1; : > "$CALLS"
bash "$XREVIEW" dispatch b.md >/dev/null 2>&1
is "E2 a pinned thread is never archived" "$(called "thread-archive --thread $U0")" 0
fresh
is "E3 XREVIEW_THREAD overrides" "$(XREVIEW_THREAD=$U2 bash "$XREVIEW" thread)" "$U2"
out="$(bash "$XREVIEW" thread 2>&1)"; rc=$?
is "E4 no thread yet says the next dispatch starts one" "$(printf '%s' "$out" | grep -c 'next dispatch starts one')" 1
bash "$XREVIEW" init >/dev/null
is "E5 init without an id pins the pane's thread" "$(cat "$STATE/pin")" "$U0"
out="$(bash "$XREVIEW" init '../../x' 2>&1)"; rc=$?
is "E6 an unsafe id is refused" "$(printf '%s' "$out" | grep -c 'refusing unsafe identifier')" 1

echo "E7. the legacy queue-era 'thread' file is inert"
# The old xreview cached herdr's session id at $state_dir/thread. Reading it as a checkpoint
# thread would resume a non-cold session; --reset must drop it without archiving it, because
# it was never a checkpoint thread.
fresh
mkdir -p "$STATE" && printf '%s\n' "$U0" > "$STATE/thread"
nonce="$(bash "$XREVIEW" dispatch b.md 2>/dev/null)"
is "E7 dispatch never resumes onto the legacy thread" "$(called "resume $U0")" 0
is "E7 a fresh pane session starts instead" \
   "$(called 'herdr pane run w1:p2 codex --sandbox read-only --ask-for-approval never')" 1
is "E7 the checkpoint gets its own fresh thread" "$(cat "$STATE/review-thread")" "$U1"
fresh
mkdir -p "$STATE" && printf '%s\n' "$U0" > "$STATE/thread"
bash "$XREVIEW" round --reset >/dev/null 2>&1
is "E7 reset drops the legacy file" "$([ -e "$STATE/thread" ] && echo kept || echo dropped)" dropped
is "E7 reset never archives the legacy file" "$([ -e "$STATE/superseded" ] && echo yes || echo no)" no

echo "F. collect"
ANSWER='{"verdict":"changes","findings":[{"severity":"P1","file":"a","line":1,"summary":"s","failure_scenario":"f"}]}'
fresh
nonce="$(bash "$XREVIEW" dispatch b.md 2>/dev/null)"
out="$(RPC_WAIT_OUT="$ANSWER" bash "$XREVIEW" collect "$nonce" 2>&1)"; rc=$?
is "F1 a finished review exits 0" "$rc" 0
is "F1 and prints the findings" "$(printf '%s' "$out" | jq -r .verdict)" changes
is "F1 waiting with the findings schema" "$(called "turn-wait --thread $U1 --turn turn-$U1 --budget 2700 --schema $XDG_CONFIG_HOME/xreview/findings.schema.json")" 1
r="$(tail -1 "$STATE/reviews.jsonl")"
is "F1 the receipt keeps the old fields" "$(printf '%s' "$r" | jq -r '[.thread,.nonce,(.ts|length>0),(.head|length>0),has("tier")] | map(tostring) | join(" ")')" "$U1 $nonce true true true"
is "F1 and adds turn, verdict and finding count" "$(printf '%s' "$r" | jq -r '[.turn,.verdict,.findings] | map(tostring) | join(" ")')" "turn-$U1 changes 1"
out="$(RPC_WAIT_RC=3 bash "$XREVIEW" collect "$nonce" 60 2>&1)"; rc=$?
is "F2 a running turn exits 3" "$rc" 3
is "F2 says so and how to keep waiting" "$(printf '%s' "$out" | grep -c "xreview collect $nonce")" 1
out="$(RPC_WAIT_RC=4 RPC_WAIT_OUT='prose' bash "$XREVIEW" collect "$nonce" 2>&1)"; rc=$?
is "F3 a schema miss exits 4" "$rc" 4
is "F3 and labels the text untrusted" "$(printf '%s' "$out" | grep -c UNTRUSTED)" 1
out="$(RPC_WAIT_RC=1 bash "$XREVIEW" collect "$nonce" 2>&1)"; rc=$?
is "F4 a failed turn exits 1" "$rc" 1
out="$(RPC_WAIT_RC=5 bash "$XREVIEW" collect "$nonce" 2>&1)"; rc=$?
is "F5 an unreachable daemon exits 1 and says so" "$rc/$(printf '%s' "$out" | grep -c unreachable)" "1/1"
out="$(bash "$XREVIEW" collect xr-1-nosuchnonce 2>&1)"; rc=$?
is "F6 an unknown nonce is ambiguous and exits 1" "$rc/$(printf '%s' "$out" | grep -c 'do NOT retry')" "1/1"
out="$(bash "$XREVIEW" collect "$U1" "$nonce" 2>&1)"; rc=$?
is "F7 the old thread-first form is refused with the usage" "$rc/$(printf '%s' "$out" | grep -c 'usage: xreview collect <nonce>')" "1/1"
is "F8 the default budget is at least 30 minutes" \
   "$(grep -E '^COLLECT_BUDGET_DEFAULT=' "$XREVIEW" | cut -d= -f2 | awk '{print ($1 >= 1800)}')" 1

echo "G. the reviewer tier is reported, never enforced"
ROLL="$CODEX_HOME/sessions/2026/09/01"; mkdir -p "$ROLL"
tc() { printf '{"type":"turn_context","payload":{"model":"%s","effort":"%s"}}\n' "$1" "$2"; }
{ tc gpt-5.6-sol xhigh; tc gpt-5.6-terra high; } > "$ROLL/rollout-2026-09-01T10-00-00-faketh.jsonl"
is "tier reflects the last turn's setting" "$(bash "$XREVIEW" tier faketh 2>&1)" "gpt-5.6-terra/high"
: > "$STATE/reviews.jsonl"
for _ in 1 2; do printf '{"thread":"t","nonce":"n","tier":"gpt-5.6-sol/xhigh"}\n' >> "$STATE/reviews.jsonl"; done
printf '{"thread":"t","nonce":"n"}\n' >> "$STATE/reviews.jsonl"
out="$(bash "$XREVIEW" receipts --tiers 2>&1)"
is "the tier summary counts each tier" "$(printf '%s' "$out" | grep -c 'gpt-5.6-sol/xhigh')" 1
is "and receipts without a tier as unrecorded" "$(printf '%s' "$out" | grep -ci unrecorded)" 1
is "no --expect handling survives" "$(grep -c -- '--expect' "$XREVIEW")" 0

echo "H. the queue-era machinery is gone"
code="$(grep -v '^[[:space:]]*#' "$XREVIEW")"
for gone in 'codex queue' 'thread_history' 'XREVIEW_THREAD_WARN' 'herdr agent list' 'sqlite3'; do
  is "no '$gone' in the code" "$(printf '%s' "$code" | grep -c -- "$gone")" 0
done

echo "I. a repository path with a space"
mkdir -p "$ROOT/sp ace" && cd "$ROOT/sp ace" || exit 1
git init -q . && git config user.email t@t && git config user.name t && git config commit.gpgsign false
git commit -q --allow-empty -m init; printf 'body\n' > b.md
SPCWD="$(git rev-parse --show-toplevel)"
fresh; export PANE_CWD="$SPCWD"
nonce="$(bash "$XREVIEW" dispatch b.md 2>/dev/null)"
is "the pane is found and the dispatch succeeds" "$(printf '%s' "$nonce" | grep -c '^xr-')" 1
SPSTATE="$XDG_STATE_HOME/xreview/$(printf '%s' "$SPCWD" | tr '/' '_' | sed 's/^_//')"
is "its state lands in its own directory" "$(cat "$SPSTATE/review-thread" 2>/dev/null)" "$U1"
cd "$ROOT/repo" || exit 1

printf '\npassed: %d  failed: %d\n' "$pass" "$fail"
(( fail == 0 ))
