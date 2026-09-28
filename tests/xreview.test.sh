#!/usr/bin/env bash
# Tests for dot_local/bin/executable_xreview on the Codex daemon (spec section 7).
#
# Every collaborator is stubbed on PATH:
#   herdr         one Codex pane, w1:p2, whose title and agent live in files under $P
#   codex-daemon  ensure/check exit codes
#   xreview-rpc   thread-start, thread status/resolve, turn start and wait, archive
# Each stub logs its calls to $CALLS, so ordering is asserted from the log. Dispatch FREES
# the pane (quits its TUI, if it is not already on the checkpoint thread) BEFORE any turn
# exists, THEN starts the review turn, and only THEN best-effort resumes the pane onto it
# (F22: a TUI resuming a thread mid-turn replays it from the start). No precondition may be
# skipped, and no keystroke (send-keys) may ever reach the pane once the turn exists (C1).
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
export XDG_STATE_HOME="$ROOT/state" XDG_CONFIG_HOME="$ROOT/config" CODEX_HOME="$ROOT/codex" \
       TMPDIR="$ROOT/tmp"
mkdir -p "$XDG_CONFIG_HOME/xreview" "$XDG_CONFIG_HOME/herdr" "$TMPDIR"
cp "$SRC/dot_config/xreview/findings.schema.json" "$SRC/dot_config/xreview/reviewer.md" "$XDG_CONFIG_HOME/xreview/"
cp "$SRC/dot_config/herdr/codex-pane-command" "$XDG_CONFIG_HOME/herdr/"
export XREVIEW_POLL_SECS=0.05 XREVIEW_PANE_WAIT=2
unset XREVIEW_MAX_ROUNDS XREVIEW_PANE XREVIEW_THREAD
PANE_CMD='codex --sandbox read-only --ask-for-approval never'

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
export U0=aaaaaaaa-0000-4000-8000-000000000000   # the thread the pane shows at the start
export U1=bbbbbbbb-1111-4111-8111-111111111111   # what xreview-rpc thread-start creates
export U2=cccccccc-2222-4222-8222-222222222222
export NEW_UUID="$U1"
# Codex truncates the title's thread-id item to 29 chars plus "..." once the thread is named
# (F11/F21); a realistic stub title never carries more than that.
trunc() { printf '%s...' "$(printf '%s' "$1" | cut -c1-29)"; }
cat > "$STUB/herdr" <<'H'
#!/bin/sh
# printf, not echo: some shells' builtin echo is XSI-compliant and silently turns a literal
# \033/\007 in a logged argument into real ESC/BEL bytes, which would make the log stop
# matching the literal text the launch command actually contains.
printf 'herdr %s\n' "$*" >> "$CALLS"
pane_json() {
  a="$(cat "$P/agent" 2>/dev/null)"; t="$(cat "$P/title" 2>/dev/null)"
  s="$(cat "$P/status" 2>/dev/null || echo idle)"
  # AGENT_EXIT_DELAY simulates the pane's OWN exit taking a few more polls to actually show
  # up in .agent, after send-keys has already flipped the real state - so the agent-exit
  # wait genuinely iterates a few times, the same way a real TUI would.
  if [ -n "${AGENT_EXIT_DELAY:-}" ] && [ -e "$P/exit_delay_active" ]; then
    n=$(cat "$P/exit_delay_calls" 2>/dev/null || echo 0); n=$((n + 1)); echo "$n" > "$P/exit_delay_calls"
    if [ "$n" -le "$AGENT_EXIT_DELAY" ]; then a=codex; else rm -f "$P/exit_delay_active"; fi
  fi
  # The resume command's own title takes RESET_LAG (read-count, default 1) reads to land, so
  # the final wait loop genuinely iterates. RESET_LAG=0 means it shows on the very first read.
  if [ -e "$P/reset_pending" ]; then
    n=$(cat "$P/reset_calls" 2>/dev/null || echo 0); n=$((n + 1)); echo "$n" > "$P/reset_calls"
    if [ "$n" -gt "${RESET_LAG:-1}" ]; then
      t="$(cat "$P/newtitle" 2>/dev/null)"; printf '%s' "$t" > "$P/title"
      rm -f "$P/reset_pending"
    fi
  fi
  af=""; [ -n "$a" ] && af="\"agent\":\"$a\","
  printf '{%s"agent_status":"%s","cwd":"%s","pane_id":"w1:p2","terminal_title":"%s","terminal_title_stripped":"%s"}' \
    "$af" "$s" "${PANE_CWD:-$CWD}" "$t" "$t"
}
case "$1 $2" in
  "pane list") printf '{"result":{"panes":[%s%s]}}\n' "$(pane_json)" "${EXTRA_PANES:-}" ;;
  "pane get")
    # PANE_GONE_AT=<n>: from the n-th read on, the pane is closed - herdr's real answer for a
    # closed pane. Used to simulate the pane closing mid-prepare (T4).
    if [ -n "${PANE_GONE_AT:-}" ]; then
      gn=$(cat "$P/get_seq" 2>/dev/null || echo 0); gn=$((gn + 1)); echo "$gn" > "$P/get_seq"
      if [ "$gn" -ge "$PANE_GONE_AT" ]; then
        echo '{"error":{"code":"pane_not_found","message":"pane w1:p2 not found"},"id":"cli:pane:get"}' >&2
        exit 1
      fi
    fi
    # I-1: consume the fail-once marker on the very first read after send-keys, simulating a
    # transient herdr failure during the exit wait - exit nonzero with no output, never a
    # title of any kind.
    if [ -e "$P/agent_fail_once" ]; then rm -f "$P/agent_fail_once"; exit 1; fi
    printf '{"result":{"pane":%s}}\n' "$(pane_json)" ;;
  "pane send-keys")
    n=$(cat "$P/ctrlc" 2>/dev/null || echo 0); n=$((n + 1)); echo "$n" > "$P/ctrlc"
    if [ "$n" -ge 2 ] && [ -z "${STUCK_TUI:-}" ]; then
      : > "$P/agent"
      : > "$P/exit_delay_active"; rm -f "$P/exit_delay_calls"
      [ -n "${AGENT_READ_FAIL_ONCE:-}" ] && : > "$P/agent_fail_once"
    fi ;;
  "pane run")
    echo 0 > "$P/ctrlc"
    rm -f "$P/reset_calls" "$P/reset_pending" "$P/exit_delay_active" "$P/exit_delay_calls" \
          "$P/agent_fail_once"
    # pane_resume only ever issues one shape of launch command: "$cmd resume $thread" - the
    # thread is always known before the pane is touched. NO_TITLE simulates a pane that never
    # shows any title at all, however long dispatch waits.
    [ -n "${NO_TITLE:-}" ] && exit 0
    printf codex > "$P/agent"
    full="${4##* resume }"
    # Truncate to a realistic title (F11/F21: 29 chars plus "..." once the thread is named).
    printf '%s... | t | d' "$(printf '%s' "$full" | cut -c1-29)" > "$P/newtitle"
    if [ "${RESET_LAG:-1}" = 0 ]; then
      cat "$P/newtitle" > "$P/title"
    else
      : > "$P/reset_pending"
    fi ;;
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
th=""; input=""; known=""; resolved=""; prefix=""; cwd=""
while [ "$#" -gt 0 ]; do
  case "$1" in --thread) th="$2"; shift ;; --input) input="$2"; shift ;; --known) known="$2"; shift ;;
               --resolved) resolved="$2"; shift ;; --prefix) prefix="$2"; shift ;;
               --cwd) cwd="$2"; shift ;; esac; shift
done
case "$cmd" in
  health) [ -z "${RPC_HEALTH_FAIL:-}" ] || exit 5; exit 0 ;;
  thread-start) [ -n "${RPC_START_THREAD_FAIL:-}" ] && exit 1
                echo "$NEW_UUID" ;;
  thread-resolve)
    for u in "$U0" "$U1" "$U2"; do
      case "$u" in "$prefix"*) echo "$u"; exit 0 ;; esac
    done
    exit 1 ;;
  thread-status)
    # RPC_THREAD_RUNNING: every thread queried is running. RPC_THREAD_RUNNING_FOR=<id>:
    # only that one thread is (Minor 4's own check runs on the CHOSEN thread, separately
    # from the precondition gate's check on whatever the pane's title resolves to, so a
    # test targeting one must not also trip the other).
    if [ -n "${RPC_THREAD_RUNNING:-}" ] || { [ -n "${RPC_THREAD_RUNNING_FOR:-}" ] && [ "$th" = "$RPC_THREAD_RUNNING_FOR" ]; }; then
      echo '{"loaded":true,"status":"active","running":true}'
    else echo '{"loaded":true,"status":"idle","running":false}'; fi ;;
  turn-start) cp "$input" "$P/packet"; [ -n "$known" ] && echo '[]' > "$known"
              [ -n "${RPC_START_FAIL:-}" ] && exit 1
              [ -n "${RPC_START_UNCERTAIN:-}" ] && exit 6
              if [ -n "${RPC_START_BAD_ID:-}" ]; then echo "turn id/with spaces"; exit 0; fi
              echo "turn-$th" ;;
  turn-wait) [ -n "$resolved" ] && echo turn-recovered > "$resolved"
             printf '%s\n' "${RPC_WAIT_OUT:-}"; exit "${RPC_WAIT_RC:-0}" ;;
esac
exit 0
R
chmod +x "$STUB"/*
export PATH="$STUB:$PATH"
# A `sleep` that records each poll sleep in the call log, so a test can prove a retry
# actually waited before re-reading instead of inferring it from wall-clock timing. Its own
# directory, put on PATH only by the runs that need it (sleep_logged), so no other test pays
# the wrapper's per-sleep cost.
SLEEPSTUB="$ROOT/sleepstub"; mkdir -p "$SLEEPSTUB"
cat > "$SLEEPSTUB/sleep" <<'SL'
#!/bin/sh
printf 'sleep\n' >> "$CALLS"
exec /bin/sleep "$@"
SL
chmod +x "$SLEEPSTUB/sleep"
sleep_logged() { PATH="$SLEEPSTUB:$PATH" "$@"; }

fresh() { # a pane showing U0, idle; clean log and state
  unset ENSURE_RC CHECK_RC RPC_START_FAIL RPC_START_UNCERTAIN RPC_START_BAD_ID \
        RPC_START_THREAD_FAIL NO_TITLE STUCK_TUI RESET_LAG AGENT_EXIT_DELAY \
        AGENT_READ_FAIL_ONCE EXTRA_PANES PANE_CWD XREVIEW_PANE XREVIEW_THREAD RPC_WAIT_OUT \
        RPC_WAIT_RC RPC_THREAD_RUNNING RPC_THREAD_RUNNING_FOR RPC_HEALTH_FAIL PANE_GONE_AT
  export NEW_UUID="$U1"
  printf codex > "$P/agent"; printf '%s | t | d' "$(trunc "$U0")" > "$P/title"; echo idle > "$P/status"
  echo 0 > "$P/ctrlc"
  rm -f "$P/packet" "$P/reset_calls" "$P/reset_pending" "$P/newtitle" \
        "$P/exit_delay_active" "$P/exit_delay_calls" "$P/agent_fail_once" "$P/get_seq"
  bash "$XREVIEW" round --reset >/dev/null 2>&1
  rm -rf "$STATE/superseded" "$STATE/pin" "$STATE/turns"
  rm -f "$STATE/pane"   # the fast-path record must never leak from a previous test
  : > "$CALLS"
}
called() { grep -c -- "$1" "$CALLS" 2>/dev/null || true; }
first() { grep -n -- "$1" "$CALLS" | head -1 | cut -d: -f1; }
untouched() { # nothing reached the pane or the reviewer
  [ "$(called 'herdr pane send-keys')$(called 'herdr pane run')$(called 'xreview-rpc turn-start')" = 000 ] && echo yes || echo no
}
none_after() { # none_after <marker> <target>: <target> never appears in $CALLS on or after
  # the first line matching <marker> (C1: nothing may send-keys once the turn exists).
  awk -v m="$1" -v t="$2" '$0 ~ m {f=1} f && $0 ~ t {c++} END{print c+0}' "$CALLS"
}

echo "A. the round cap binds before a turn is spent"
fresh
capped() { bash "$XREVIEW" dispatch b.md 2>&1 | grep -c 'exceeds the cap'; }
is "round counter starts at zero" "$(bash "$XREVIEW" round)" 0
for _ in $(seq 9); do capped >/dev/null; done
is "nine rounds are permitted"        "$(bash "$XREVIEW" round)" 9
out="$(bash "$XREVIEW" dispatch b.md 2>&1)"
is "the tenth round is still allowed"    "$(printf '%s' "$out" | grep -c 'exceeds the cap')" 0
is "and the tenth round produces a nonce" "$(printf '%s' "$out" | grep -c '^xr-')" 1
starts="$(called 'xreview-rpc turn-start')"
is "the eleventh round is refused"    "$(capped)" 1
is "and starts no turn"               "$(called 'xreview-rpc turn-start')" "$starts"
is "a refused round still increments, so retrying stays refused" "$(bash "$XREVIEW" round)" 11
bash "$XREVIEW" round --reset >/dev/null
is "reset returns the counter to zero" "$(bash "$XREVIEW" round)" 0
# round --reset drops the checkpoint thread too, so this dispatch calls thread-start again -
# give it a fresh id so later assertions in this block are unambiguous.
export NEW_UUID="$U2"
out="$(XREVIEW_MAX_ROUNDS=1 bash "$XREVIEW" dispatch b.md 2>&1)"
is "dispatch is permitted again after reset" "$(printf '%s' "$out" | grep -c '^xr-')" 1
is "XREVIEW_MAX_ROUNDS lowers the cap" "$(XREVIEW_MAX_ROUNDS=1 bash "$XREVIEW" dispatch b.md 2>&1 | grep -c 'exceeds the cap')" 1
export NEW_UUID="$U1"

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
fresh; out="$(RPC_HEALTH_FAIL=1 bash "$XREVIEW" dispatch b.md 2>&1)"; rc=$?
is "C13 an unreachable daemon via xreview-rpc refuses" "$rc" 1
is "C13 and says so" "$(printf '%s' "$out" | grep -c 'cannot reach the Codex daemon through xreview-rpc')" 1
is "C13 untouched" "$(untouched)" yes
is "C13 no round consumed" "$(bash "$XREVIEW" round)" 0
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
fresh; echo blocked > "$P/status"; out="$(bash "$XREVIEW" dispatch b.md 2>&1)"
is "C10 a blocked pane refuses" "$(printf '%s' "$out" | grep -c 'mid-turn')" 1
is "C10 untouched" "$(untouched)" yes
fresh; out="$(RPC_THREAD_RUNNING=1 bash "$XREVIEW" dispatch b.md 2>&1)"
is "C11 a running thread behind an idle pane refuses" "$(printf '%s' "$out" | grep -c 'mid-turn')" 1
is "C11 untouched" "$(untouched)" yes
fresh
U5=55555555-5555-4555-8555-555555555555   # never on the resolver stub's known-id list
printf '%s | t | d' "$(trunc "$U5")" > "$P/title"
out="$(bash "$XREVIEW" dispatch b.md 2>&1)"
is "C12 the running-thread gate does not block when the title prefix cannot be resolved" \
   "$(printf '%s' "$out" | grep -c '^xr-')" 1
fresh
out="$(XREVIEW_PANE='.*' bash "$XREVIEW" dispatch b.md 2>&1)"; rc=$?
is "C14 XREVIEW_PANE='.*' is refused, not matched as a regex" "$rc" 1
is "C14 and names the pane, not a pattern match" "$(printf '%s' "$out" | grep -c 'is not a Codex pane')" 1
is "C14 untouched" "$(untouched)" yes
fresh; mkdir .codex; out="$(bash "$XREVIEW" dispatch b.md 2>&1)"; rmdir .codex
is "C7 a project .codex refuses" "$(printf '%s' "$out" | grep -c 'refusing to dispatch')" 1
is "C7 untouched" "$(untouched)" yes
fresh; out="$(XREVIEW_SCHEMA="$ROOT/none.json" bash "$XREVIEW" dispatch b.md 2>&1)"
is "C8 a missing schema refuses" "$(printf '%s' "$out" | grep -c 'missing findings schema')" 1

echo "D. the pane is freed before the turn, then best-effort resumed onto it (spec 7.3)"
fresh
nonce="$(bash "$XREVIEW" dispatch b.md 2>/dev/null)"
is "D1 a nonce is printed" "$(printf '%s' "$nonce" | grep -c '^xr-')" 1
is "D1 the pane's session is ended" "$(called 'herdr pane send-keys w1:p2 ctrl+c')" 2
is "D1 the pane is resumed onto the new thread" \
   "$(called "herdr pane run w1:p2 .*$PANE_CMD resume $U1")" 1
is "D1 herdr is told the pane's thread" \
   "$(called "herdr pane report-agent-session w1:p2 --source herdr:codex --agent codex --agent-session-id $U1")" 1
is "D1 the checkpoint thread is recorded" "$(cat "$STATE/review-thread")" "$U1"
is "D1 the nonce maps to thread and turn" "$(cat "$STATE/turns/$nonce")" "$U1 turn-$U1"
# C1: nothing may ever send-keys to the pane once the turn exists.
is "D1 no send-keys appears after turn-start" "$(none_after 'xreview-rpc turn-start' 'herdr pane send-keys')" 0

echo "D3. a pane that moved off the checkpoint thread is resumed back onto it"
printf '%s | t | d' "$(trunc "$U0")" > "$P/title"; : > "$CALLS"
bash "$XREVIEW" dispatch b.md >/dev/null 2>&1
is "D3 it is resumed back onto the checkpoint thread" \
   "$(called "herdr pane run w1:p2 .*$PANE_CMD resume $U1")" 1

echo "D3f. a failed .agent read during the exit wait keeps waiting, not skips it"
# AGENT_EXIT_DELAY makes .agent genuinely keep reading "codex" for a few more polls after
# send-keys, as a slow-exiting TUI would; AGENT_READ_FAIL_ONCE fails the very first read of
# that phase outright. A read failure treated as "the field is empty" would end the wait on
# that first (failed) read - long before the delay actually elapses.
fresh
out="$(AGENT_EXIT_DELAY=3 AGENT_READ_FAIL_ONCE=1 XREVIEW_POLL_SECS=0.05 XREVIEW_PANE_WAIT=5 \
        bash "$XREVIEW" dispatch b.md 2>&1)"; rc=$?
is "D3f it still succeeds" "$(printf '%s' "$out" | grep -c '^xr-')" 1
# Between the second ctrl+c and `pane run`, the exit-wait loop makes one ".agent" read per
# iteration: the first (failed) one, then 3 more covering the delay, then the one that
# finally reads empty and breaks the loop - 5 in total. A failed read misread as "already
# exited" would instead call `pane run` after just that first (failed) read - 1, not 5.
is "D3f the exit wait actually iterated through the delay, not stopped on the failed read" \
   "$(awk '/pane send-keys/{n++} n>=2{print} /pane run/{exit}' "$CALLS" | grep -c 'pane get')" 5

echo "D8. a refused turn fails the dispatch - the pane was already freed, but never resumed"
# The pane is freed BEFORE turn-start now (C1), so a turn-start failure still costs two
# ctrl+c on the pane - unavoidable, since freeing has to happen before the turn can start at
# all - but it must never reach `pane run` (no resume), and no turn is ever recorded.
fresh; out="$(RPC_START_FAIL=1 bash "$XREVIEW" dispatch b.md 2>&1)"; rc=$?
is "D8 a refused turn fails the dispatch" "$rc" 1
is "D8 and records no nonce" "$(ls "$STATE/turns" 2>/dev/null | grep -c .)" 0
is "D8 the pane was freed (two ctrl+c)" "$(called 'herdr pane send-keys')" 2
is "D8 but never resumed (no pane run)" "$(called 'herdr pane run')" 0

echo "D10. an unanswered turn-start still hands back a nonce; collect recovers it"
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

echo "D11. a daemon restart is detected even though the title and pane record still match"
fresh
bash "$XREVIEW" dispatch b.md >/dev/null 2>&1   # establishes the fast-path pane record
mkdir -p "$CODEX_HOME/app-server-daemon"; printf '{"pid":999}\n' > "$CODEX_HOME/app-server-daemon/daemon.pid"
: > "$CALLS"
bash "$XREVIEW" dispatch b.md >/dev/null 2>&1
is "D11 the pane is re-pointed despite the title still matching" \
   "$(called "herdr pane run w1:p2 .*$PANE_CMD resume $U1")" 1

echo "D11b. a daemon.pid whose content changes (not just appears) is also a detected restart"
fresh
mkdir -p "$CODEX_HOME/app-server-daemon"; printf '{"pid":111}\n' > "$CODEX_HOME/app-server-daemon/daemon.pid"
bash "$XREVIEW" dispatch b.md >/dev/null 2>&1   # records the generation for pid 111
printf '{"pid":222}\n' > "$CODEX_HOME/app-server-daemon/daemon.pid"   # content CHANGES, not just appears
: > "$CALLS"
bash "$XREVIEW" dispatch b.md >/dev/null 2>&1
is "D11b a changed daemon.pid content is also a detected restart" \
   "$(called "herdr pane run w1:p2 .*$PANE_CMD resume $U1")" 1
rm -rf "$CODEX_HOME/app-server-daemon"   # restore the "no daemon.pid yet" baseline for later tests

echo "D12. a pin whose title already matches is still resumed once, then takes the fast path"
fresh
bash "$XREVIEW" init "$U0" >/dev/null    # the pin the pane's title already shows, nothing recorded
: > "$CALLS"
bash "$XREVIEW" dispatch b.md >/dev/null 2>&1
is "D12 a pin whose title already matches is still resumed once, with nothing recorded yet" \
   "$(called "herdr pane run w1:p2 .*$PANE_CMD resume $U0")" 1
: > "$CALLS"
bash "$XREVIEW" dispatch b.md >/dev/null 2>&1
is "D12 the dispatch after that takes the fast path" "$(called 'herdr pane send-keys')" 0

echo "D16. turn-start returning 0 with a malformed id still hands back a nonce"
fresh
nonce="$(RPC_START_BAD_ID=1 bash "$XREVIEW" dispatch b.md 2>"$ROOT/err")"; rc=$?
is "D16 turn-start returning 0 with a malformed id still hands back a nonce" \
   "$rc/$(printf '%s' "$nonce" | grep -c '^xr-')" "0/1"
is "D16 with a do-not-re-dispatch warning, exactly like exit 6" \
   "$(grep -c 'do NOT re-dispatch' "$ROOT/err")" 1
is "D16 the record marks the turn unknown" "$(cat "$STATE/turns/$nonce")" "$U1 ?"

echo "T1. a new checkpoint thread comes from xreview-rpc thread-start"
fresh
nonce="$(bash "$XREVIEW" dispatch b.md 2>/dev/null)"
is "T1 thread-start is called with the repo root" "$(called "xreview-rpc thread-start --cwd $CWD")" 1
is "T1 the new thread is recorded as the checkpoint thread" "$(cat "$STATE/review-thread")" "$U1"
is "T1 the turn starts on it" "$(called "xreview-rpc turn-start --thread $U1")" 1

echo "T2. no keystroke ever reaches the pane once the turn exists (C1)"
fresh
bash "$XREVIEW" dispatch b.md >/dev/null 2>&1
is "T2 the pane is freed (send-keys) before turn-start, not after" \
   "$([ "$(first 'herdr pane send-keys')" -lt "$(first 'xreview-rpc turn-start')" ] && echo yes || echo no)" yes
is "T2 and no send-keys ever appears after turn-start" \
   "$(none_after 'xreview-rpc turn-start' 'herdr pane send-keys')" 0
# Confirmed with a scratch mutant (the ctrl+c moved to AFTER turn-start, mirroring the old
# pane-first-then-ctrl+c bug this fix round closes): both assertions above go red under that
# mutant, and D1's own send-keys-after-turn-start assertion does too - see task-16-report.md.

echo "T3. a pane that never shows the thread still succeeds: the review just is not shown"
fresh
out="$(NO_TITLE=1 XREVIEW_PANE_WAIT=0.15 bash "$XREVIEW" dispatch b.md 2>&1)"; rc=$?
nonce="$(printf '%s' "$out" | grep '^xr-')"
is "T3 dispatch still exits 0" "$rc" 0
is "T3 and prints the nonce" "$(printf '%s' "$nonce" | grep -c '^xr-')" 1
is "T3 the turn is recorded" "$(cat "$STATE/turns/$nonce" 2>/dev/null)" "$U1 turn-$U1"
is "T3 and it warns the review is not shown" \
   "$(printf '%s' "$out" | grep -c 'running but not shown in pane w1:p2')" 1
is "T3 the round was still consumed" "$(bash "$XREVIEW" round)" 1

echo "T3b. a session that will not exit now REFUSES, before any turn exists (C1)"
# The old behaviour (warn, still exit 0) belonged to the OLD pane-first-then-turn design,
# where freeing the pane happened with no turn yet to protect. Now pane_free runs before
# turn-start, so it can safely die: nothing has started.
fresh
out="$(STUCK_TUI=1 XREVIEW_PANE_WAIT=0.15 bash "$XREVIEW" dispatch b.md 2>&1)"; rc=$?
is "T3b it refuses" "$rc" 1
is "T3b and says the session would not exit" "$(printf '%s' "$out" | grep -c 'did not exit its session')" 1
is "T3b no turn was ever started" "$(called 'xreview-rpc turn-start')" 0
is "T3b and no nonce is printed" "$(printf '%s' "$out" | grep -c '^xr-')" 0

echo "T4a. a pane that closes (pane_not_found) WHILE BEING FREED refuses; no turn ever starts"
fresh
out="$(PANE_GONE_AT=1 bash "$XREVIEW" dispatch b.md 2>&1)"; rc=$?
is "T4a it refuses" "$rc" 1
is "T4a and says the pane closed while being freed" \
   "$(printf '%s' "$out" | grep -c 'closed while being freed')" 1
is "T4a no turn was ever started" "$(called 'xreview-rpc turn-start')" 0
is "T4a and no nonce is printed" "$(printf '%s' "$out" | grep -c '^xr-')" 0

echo "T4b. a pane that closes (pane_not_found) AFTER the turn starts still warns, quickly, exit 0"
# The turn already exists by the time this fires (pane_free itself succeeded), so this is
# exactly the spec's step-5 failure mode, unchanged from before this fix round.
fresh
start="$EPOCHREALTIME"
out="$(PANE_GONE_AT=5 bash "$XREVIEW" dispatch b.md 2>&1)"; rc=$?
took="$(awk -v s="$start" -v e="$EPOCHREALTIME" 'BEGIN{printf "%.3f", e-s}')"
nonce="$(printf '%s' "$out" | grep '^xr-')"
is "T4b dispatch still exits 0" "$rc" 0
is "T4b and prints the nonce" "$(printf '%s' "$nonce" | grep -c '^xr-')" 1
is "T4b the turn is recorded" "$(cat "$STATE/turns/$nonce" 2>/dev/null)" "$U1 turn-$U1"
is "T4b and it warns the review is not shown" \
   "$(printf '%s' "$out" | grep -c 'running but not shown in pane w1:p2')" 1
is "T4b it returns quickly, not waiting out XREVIEW_PANE_WAIT" \
   "$(awk -v t="$took" -v w="${XREVIEW_PANE_WAIT:-20}" 'BEGIN{print (t < w) ? "yes" : "no ("t"s)"}')" yes

echo "T5. thread-start failing refuses before any turn or pane keystroke"
fresh
out="$(RPC_START_THREAD_FAIL=1 bash "$XREVIEW" dispatch b.md 2>&1)"; rc=$?
is "T5 it refuses" "$rc" 1
is "T5 and says so" "$(printf '%s' "$out" | grep -c 'could not start a new review thread')" 1
is "T5 no turn was started" "$(called 'xreview-rpc turn-start')" 0
is "T5 and the pane was never touched" "$(untouched)" yes
is "T5 no checkpoint thread was recorded" "$([ -e "$STATE/review-thread" ] && echo yes || echo no)" no

echo "T6. the superseded thread is archived only once the pane step succeeds"
fresh
bash "$XREVIEW" dispatch b.md >/dev/null 2>&1        # establishes checkpoint thread U1
bash "$XREVIEW" round --reset >/dev/null 2>&1         # supersedes U1; drops the cached thread
export NEW_UUID="$U2"
: > "$CALLS"
bash "$XREVIEW" dispatch b.md >/dev/null 2>&1         # a normal dispatch: the pane step succeeds
is "T6 the superseded thread is archived once the pane step succeeds" \
   "$(called "xreview-rpc thread-archive --thread $U1")" 1
export NEW_UUID="$U1"

fresh
bash "$XREVIEW" dispatch b.md >/dev/null 2>&1        # establishes checkpoint thread U1
bash "$XREVIEW" round --reset >/dev/null 2>&1
export NEW_UUID="$U2"
: > "$CALLS"
NO_TITLE=1 XREVIEW_PANE_WAIT=0.15 bash "$XREVIEW" dispatch b.md >/dev/null 2>&1   # the pane step fails
is "T6 and NOT archived when the pane step fails" "$(called "xreview-rpc thread-archive --thread $U1")" 0
export NEW_UUID="$U1"

echo "M4. the checkpoint thread itself already running a turn refuses, pane untouched"
fresh
bash "$XREVIEW" init "$U2" >/dev/null   # pin a thread distinct from the pane's own title (U0)
out="$(RPC_THREAD_RUNNING_FOR=$U2 bash "$XREVIEW" dispatch b.md 2>&1)"; rc=$?
is "M4 it refuses" "$rc" 1
is "M4 and says to collect it first" "$(printf '%s' "$out" | grep -c 'collect it first')" 1
is "M4 no turn was started" "$(called 'xreview-rpc turn-start')" 0
is "M4 and the pane was never touched" "$(untouched)" yes

echo "T7. the fast path sends no keys and starts no new pane session"
fresh
bash "$XREVIEW" dispatch b.md >/dev/null 2>&1   # establishes the pane record for U1
: > "$CALLS"
bash "$XREVIEW" dispatch b.md >/dev/null 2>&1
is "T7 no keys are sent on the fast path" "$(called 'herdr pane send-keys')" 0
is "T7 and no new pane session is started" "$(called 'herdr pane run')" 0
is "T7 the turn still starts on the cached thread" "$(called "xreview-rpc turn-start --thread $U1")" 1

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
fresh
U6=66666666-6666-4666-8666-666666666666   # never on the resolver stub's known-id list
printf '%s | t | d' "$(trunc "$U6")" > "$P/title"
out="$(bash "$XREVIEW" init 2>&1)"; rc=$?
is "E8 init refuses when the title prefix does not resolve" "$rc" 1
is "E8 and says so" "$(printf '%s' "$out" | grep -c 'could not be resolved')" 1
fresh; : > "$P/agent"   # no Codex pane at all
out="$(bash "$XREVIEW" init 2>&1)"; rc=$?
is "E9 init with no Codex pane refuses" "$rc" 1
is "E9 and prints exactly one error line" "$(printf '%s' "$out" | grep -c .)" 1

echo "E7. the legacy queue-era 'thread' file is inert"
# The old xreview cached herdr's session id at $state_dir/thread. Reading it as a checkpoint
# thread would resume a non-cold session; --reset must drop it without archiving it, because
# it was never a checkpoint thread.
fresh
mkdir -p "$STATE" && printf '%s\n' "$U0" > "$STATE/thread"
nonce="$(bash "$XREVIEW" dispatch b.md 2>/dev/null)"
is "E7 dispatch never resumes onto the legacy thread" "$(called "resume $U0")" 0
is "E7 a fresh checkpoint thread is used instead" \
   "$(called "herdr pane run w1:p2 .*$PANE_CMD resume $U1")" 1
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
ROLL1="$CODEX_HOME/sessions/2026/09/01"; mkdir -p "$ROLL1"
printf '{"type":"turn_context","payload":{"model":"gpt-5.6-sol","effort":"xhigh"}}\n' \
  > "$ROLL1/rollout-2026-09-01T09-00-00-$U1.jsonl"
out="$(RPC_WAIT_OUT="$ANSWER" bash "$XREVIEW" collect "$nonce" 2>&1)"; rc=$?
is "F1 a finished review exits 0" "$rc" 0
is "F1 and prints the findings" "$(printf '%s' "$out" | jq -r .verdict)" changes
is "F1 waiting with the findings schema" "$(called "turn-wait --thread $U1 --turn turn-$U1 --budget 2700 --schema $XDG_CONFIG_HOME/xreview/findings.schema.json")" 1
r="$(tail -1 "$STATE/reviews.jsonl")"
is "F1 the receipt keeps the old fields" "$(printf '%s' "$r" | jq -r '[.thread,.nonce,(.ts|length>0),(.head|length>0),has("tier")] | map(tostring) | join(" ")')" "$U1 $nonce true true true"
is "F1 and adds turn, verdict and finding count" "$(printf '%s' "$r" | jq -r '[.turn,.verdict,.findings] | map(tostring) | join(" ")')" "turn-$U1 changes 1"
is "F1 the tier is a real value read from the thread's own rollout file" \
   "$(printf '%s' "$r" | jq -r .tier)" "gpt-5.6-sol/xhigh"
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
for bad in "3.5" "abc" "-1" "10s"; do
  out="$(bash "$XREVIEW" collect "$nonce" "$bad" 2>&1)"; rc=$?
  is "F9 a budget of '$bad' dies with the usage line" "$rc/$(printf '%s' "$out" | grep -c 'usage: xreview collect')" "1/1"
  is "F9 '$bad' is never reported as a failed review" "$(printf '%s' "$out" | grep -c 'reviewer turn failed')" 0
done

echo "F10. the packet temp file never lingers, on the paths the explicit rm covers"
# This proves the explicit `rm -f "$packet"` right after turn-start (success here, a
# refused turn/start, and an unanswered one, exit 6 - every dispatch above too,
# cumulatively): all three already reach that line before returning, so it alone
# accounts for the result below. It does NOT exercise the trap - none of these paths
# dies between `mktemp` and that rm, which is the only case the trap is for - so this
# is not evidence the trap itself works. The trap is kept anyway as defence for an
# earlier death (an unexpected failure before turn-start, a signal) that no fixture
# here reaches.
fresh; RPC_START_FAIL=1 bash "$XREVIEW" dispatch b.md >/dev/null 2>&1
fresh; RPC_START_UNCERTAIN=1 bash "$XREVIEW" dispatch b.md >/dev/null 2>&1
is "no xreview-packet temp file is left in \$TMPDIR" \
   "$(find "$TMPDIR" -maxdepth 1 -name 'xreview-packet.*' 2>/dev/null | grep -c .)" 0

echo "F11. record_receipt warns on stderr but still exits 0 when it cannot write"
fresh
nonce="$(bash "$XREVIEW" dispatch b.md 2>/dev/null)"
rm -f "$STATE/reviews.jsonl"; mkdir -p "$STATE/reviews.jsonl"   # the append target cannot be written
out="$(RPC_WAIT_OUT="$ANSWER" bash "$XREVIEW" collect "$nonce" 2>&1)"; rc=$?
is "F11 it still exits 0" "$rc" 0
is "F11 but warns that the receipt could not be written" \
   "$(printf '%s' "$out" | grep -c 'could not write the receipt')" 1
rmdir "$STATE/reviews.jsonl"

echo "F12. an unsafe nonce passed to collect is refused"
out="$(bash "$XREVIEW" collect 'xr-a/b' 2>&1)"; rc=$?
is "F12 it is refused" "$rc" 1
is "F12 and says so" "$(printf '%s' "$out" | grep -c 'refusing unsafe identifier')" 1

echo "F13. missing reviewer instructions or the pane command refuse, pane untouched"
fresh
mv "$XDG_CONFIG_HOME/xreview/reviewer.md" "$ROOT/reviewer.md.bak"
out="$(bash "$XREVIEW" dispatch b.md 2>&1)"; rc=$?
is "F13 a missing reviewer.md refuses" "$(printf '%s' "$out" | grep -c 'missing reviewer instructions')" 1
is "F13 untouched" "$(untouched)" yes
mv "$ROOT/reviewer.md.bak" "$XDG_CONFIG_HOME/xreview/reviewer.md"
fresh
mv "$XDG_CONFIG_HOME/herdr/codex-pane-command" "$ROOT/codex-pane-command.bak"
out="$(bash "$XREVIEW" dispatch b.md 2>&1)"; rc=$?
is "F13 a missing codex-pane-command refuses" "$rc" 1
is "F13 and names the file" "$(printf '%s' "$out" | grep -c 'codex-pane-command')" 1
is "F13 untouched" "$(untouched)" yes
mv "$ROOT/codex-pane-command.bak" "$XDG_CONFIG_HOME/herdr/codex-pane-command"

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

echo "H. the queue-era machinery, and the pane-first race machinery, are gone"
code="$(grep -v '^[[:space:]]*#' "$XREVIEW")"
for gone in 'codex queue' 'thread_history' 'XREVIEW_THREAD_WARN' 'herdr agent list' 'sqlite3' \
            'die_if_pane_gone'; do
  is "no '$gone' in the code" "$(printf '%s' "$code" | grep -c -- "$gone")" 0
done
is "no title-reset escape sequence in the code (the two-step reset is gone)" \
   "$(printf '%s' "$code" | grep -cF '2;xreview')" 0
is "pane_prepare never calls thread-resolve any more (the thread is always already known)" \
   "$(awk '/^pane_prepare\(\)/{f=1} f{print} f && /^}/{exit}' "$XREVIEW" | grep -c 'thread-resolve')" 0

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

echo "K. a comma-decimal locale does not break the ctrl+c gap or the poll wait (I-2)"
fresh
out="$(LC_ALL=nl_BE.UTF-8 bash "$XREVIEW" dispatch b.md 2>&1)"; rc=$?
is "K1 a dispatch under nl_BE.UTF-8 still succeeds" "$(printf '%s' "$out" | grep -c '^xr-')" 1
is "K1 and exactly two ctrl+c were sent, not aborted after the first" \
   "$(called 'herdr pane send-keys')" 2

echo "K2. N1: \$EPOCHREALTIME's locale radix never truncates a sub-second wait to whole seconds"
# Under nl_BE, $EPOCHREALTIME itself reads "S,ssssss" - LC_ALL=C awk then parses only the
# whole-second part, so a 0.15s bound could run for up to a whole extra second before the
# truncated math finally shows the deadline passed. epoch_now() must normalise this.
# The radix is checked on epoch_now() itself: timing a whole dispatch against a sub-second
# bound goes red on a loaded machine without any regression.
fresh
out="$(LC_ALL=nl_BE.UTF-8 NO_TITLE=1 XREVIEW_PANE_WAIT=0.15 XREVIEW_POLL_SECS=0.05 bash "$XREVIEW" dispatch b.md 2>&1)"; rc=$?
is "K2 it still succeeds (never shows a thread, but only warns)" "$(printf '%s' "$out" | grep -c '^xr-')" 1
out="$(LC_ALL=nl_BE.UTF-8 bash -c "$(sed -n '/^epoch_now() {/,/^}/p' "$XREVIEW")"$'\nepoch_now')"
is "K2 epoch_now under nl_BE prints a '.' radix with the fraction intact" \
   "$(printf '%s' "$out" | grep -cE '^[0-9]{10,}\.[0-9]+$')" 1

# N1: exec-ing a fresh bash for the whole dispatch cannot simulate "EPOCHREALTIME absent"
# in-process - a new bash 5+ instance always recomputes its own. Unit-test the helper
# itself instead, extracted verbatim from the source file, in a subshell where it is
# actually unset (bash allows unsetting a dynamic variable within the same process).
echo "K3. N1: epoch_now() falls back to whole-second date when \$EPOCHREALTIME is unset"
epoch_now_src="$(sed -n '/^epoch_now() {/,/^}/p' "$XREVIEW")"
out="$(bash -c "$epoch_now_src"$'\nunset EPOCHREALTIME\nepoch_now')"
is "K3 it still prints something, never empty/unbound" \
   "$([ -n "$out" ] && echo yes || echo no)" yes
is "K3 and it looks like a plausible whole-second unix time, not truncated garbage" \
   "$(printf '%s' "$out" | grep -cE '^[0-9]{10,}$')" 1

echo "J. an unborn HEAD and no git repo at all (I-1)"
# `git rev-parse --abbrev-ref HEAD` exits 128 on an unborn HEAD; inherit_errexit must not
# let that kill round accounting or dispatch, and it must not surface as an empty line.
UNBORN="$(mktemp -d "${TMPDIR:-/tmp}/xreview-unborn.XXXXXX")"
mkdir -p "$UNBORN/repo" && cd "$UNBORN/repo" || exit 1
git init -q . && git config user.email t@t && git config user.name t && git config commit.gpgsign false
printf 'body\n' > b.md
UBCWD="$(git rev-parse --show-toplevel)"
fresh; export PANE_CWD="$UBCWD"
out="$(bash "$XREVIEW" round 2>&1)"; rc=$?
is "J1 'xreview round' on an unborn HEAD does not crash" "$rc" 0
is "J1 and prints a real number, not an empty line" "$(printf '%s' "$out" | grep -cE '^[0-9]+$')" 1
nonce="$(bash "$XREVIEW" dispatch b.md 2>/dev/null)"
is "J2 a dispatch on an unborn HEAD still succeeds" "$(printf '%s' "$nonce" | grep -c '^xr-')" 1
cd "$UNBORN" || exit 1
out="$(GIT_CEILING_DIRECTORIES="$UNBORN" bash "$XREVIEW" round 2>&1)"; rc=$?
is "J3 'xreview round' outside any git repo does not crash" "$rc" 0
is "J3 and prints a real number, not an empty line" "$(printf '%s' "$out" | grep -cE '^[0-9]+$')" 1
before_apply="$(find "$XDG_STATE_HOME" -name applying 2>/dev/null | wc -l)"
out="$(GIT_CEILING_DIRECTORIES="$UNBORN" bash "$XREVIEW" apply xr-1 2>&1)"; rc=$?
is "J4 'xreview apply' outside any git repo refuses" "$rc" 1
is "J4 and says why" "$(printf '%s' "$out" | grep -c 'not inside a git repository')" 1
is "J4 and writes no apply window" "$(find "$XDG_STATE_HOME" -name applying 2>/dev/null | wc -l)" "$before_apply"
cd "$ROOT/repo" || exit 1
unset PANE_CWD
rm -rf "$UNBORN"

echo "L. round counting is exact-match, not sed/grep regex, so a branch with '/' or metacharacters works"
fresh
ORIG_BRANCH="$(git rev-parse --abbrev-ref HEAD)"
git checkout -q -b feat/x
is "L1 round counter starts at zero on a slash branch" "$(bash "$XREVIEW" round)" 0
bash "$XREVIEW" dispatch b.md >/dev/null 2>&1
is "L2 a dispatch on a slash branch bumps its own counter" "$(bash "$XREVIEW" round)" 1
git checkout -q -b feat/xy
is "L3 a sibling branch whose name extends the first starts at its own zero" "$(bash "$XREVIEW" round)" 0
bash "$XREVIEW" dispatch b.md >/dev/null 2>&1
is "L4 and bumps independently" "$(bash "$XREVIEW" round)" 1
git checkout -q feat/x
is "L5 feat/x is unaffected by feat/xy's dispatch" "$(bash "$XREVIEW" round)" 1
XREVIEW_MAX_ROUNDS=1 bash "$XREVIEW" round --reset >/dev/null
export NEW_UUID="$U2"   # round --reset drops the cached thread, so this dispatch calls
                         # thread-start again - give it a fresh id
out="$(XREVIEW_MAX_ROUNDS=1 bash "$XREVIEW" dispatch b.md 2>&1)"
is "L6 XREVIEW_MAX_ROUNDS=1 the first dispatch on a slash branch is allowed" \
   "$(printf '%s' "$out" | grep -c '^xr-')" 1
out="$(XREVIEW_MAX_ROUNDS=1 bash "$XREVIEW" dispatch b.md 2>&1)"
is "L7 and the second is refused at the cap" "$(printf '%s' "$out" | grep -c 'exceeds the cap')" 1
git checkout -q -b 'a.b+c'
is "L8 a branch with regex metacharacters ('.', '+') starts at zero" "$(bash "$XREVIEW" round)" 0
bash "$XREVIEW" dispatch b.md >/dev/null 2>&1
is "L9 and bumps to one without disturbing other branches' rows" "$(bash "$XREVIEW" round)" 1
git checkout -q feat/x
is "L10 feat/x's row is untouched by the a.b+c branch's dispatch" "$(bash "$XREVIEW" round)" 2

echo "M. a branch name containing '=' is split on the LAST '=', not the first (I-1)"
git checkout -q -b 'x=y'
is "M1 round counter starts at zero on a branch containing '='" "$(bash "$XREVIEW" round)" 0
bash "$XREVIEW" dispatch b.md >/dev/null 2>&1
is "M2 a dispatch on it bumps to one" "$(bash "$XREVIEW" round)" 1
bash "$XREVIEW" dispatch b.md >/dev/null 2>&1
is "M3 and a second dispatch bumps to two" "$(bash "$XREVIEW" round)" 2
out="$(XREVIEW_MAX_ROUNDS=2 bash "$XREVIEW" dispatch b.md 2>&1)"
is "M4 XREVIEW_MAX_ROUNDS=2 refuses the third dispatch at the cap" \
   "$(printf '%s' "$out" | grep -c 'exceeds the cap')" 1
git checkout -q -b x
is "M5 a coexisting branch 'x' (a prefix of 'x=y') has its own independent count" "$(bash "$XREVIEW" round)" 0
bash "$XREVIEW" dispatch b.md >/dev/null 2>&1
is "M6 and a dispatch on 'x' bumps only its own row" "$(bash "$XREVIEW" round)" 1
git checkout -q 'x=y'
is "M7 'x=y' is unaffected by 'x's dispatch" "$(bash "$XREVIEW" round)" 3

echo "N. the rewrite half of bump_round keeps rows it must not match, even under the old buggy regex (M2)"
git checkout -q 'a.b+c'
mkdir -p "$STATE"
printf 'aXb+c=5\n' > "$STATE/rounds"   # 'aXb+c' is NOT 'a.b+c' - but the old grep -v "^a.b+c="
                                       # treated '.' as a wildcard and '+' as literal, so it
                                       # matched and wrongly dropped this row
bash "$XREVIEW" dispatch b.md >/dev/null 2>&1
is "N1 an unrelated row survives a dispatch on 'a.b+c'" "$(grep -c '^aXb+c=5$' "$STATE/rounds")" 1

echo "O. current_round's read tolerates awk itself failing (e.g. the file vanishing between the -r check and the read) (M3)"
# A directory in place of the file doesn't reproduce this: this platform's awk reads a
# directory as empty input and exits 0. Simulate the real failure mode instead - awk itself
# returning nonzero - with a PATH-shadowing awk that fails only current_round's own program
# (matched on '== b', which bump_round's rewrite program never contains) and otherwise execs
# the real awk, so every other awk call in the script (checksums, poll timing) is untouched.
REALAWK="$(command -v awk)"
STUB2="$ROOT/stub-awk-fail"; mkdir -p "$STUB2"
cat > "$STUB2/awk" <<'AWKEOF'
#!/bin/sh
for a in "$@"; do
  case "$a" in *'== b'*) exit 7 ;; esac
done
exec REALAWK_PLACEHOLDER "$@"
AWKEOF
sed -i '' "s#REALAWK_PLACEHOLDER#$REALAWK#" "$STUB2/awk"
chmod +x "$STUB2/awk"
out="$(PATH="$STUB2:$PATH" bash "$XREVIEW" round 2>&1)"; rc=$?
is "O1 'xreview round' does not crash when its awk read fails" "$rc" 0
is "O1 and still prints a number, not an empty line" "$(printf '%s' "$out" | grep -cE '^[0-9]+$')" 1

git checkout -q "$ORIG_BRANCH"
git branch -q -D feat/x feat/xy 'a.b+c' 'x=y' x

printf '\npassed: %d  failed: %d\n' "$pass" "$fail"
(( fail == 0 ))
