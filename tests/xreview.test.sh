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
export XDG_STATE_HOME="$ROOT/state" XDG_CONFIG_HOME="$ROOT/config" CODEX_HOME="$ROOT/codex" \
       TMPDIR="$ROOT/tmp"
mkdir -p "$XDG_CONFIG_HOME/xreview" "$XDG_CONFIG_HOME/herdr" "$TMPDIR"
cp "$SRC/dot_config/xreview/findings.schema.json" "$SRC/dot_config/xreview/reviewer.md" "$XDG_CONFIG_HOME/xreview/"
cp "$SRC/dot_config/herdr/codex-pane-command" "$XDG_CONFIG_HOME/herdr/"
export XREVIEW_POLL_SECS=0.05 XREVIEW_PANE_WAIT=0.15
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
export U0=aaaaaaaa-0000-4000-8000-000000000000   # the thread the pane shows at the start
export U1=bbbbbbbb-1111-4111-8111-111111111111   # the thread a fresh session in the pane creates
export U2=cccccccc-2222-4222-8222-222222222222
export NEW_UUID="$U1"
# Codex truncates the title's thread-id item to 29 chars plus "..." once the thread is named
# (F11/F21); a realistic stub title never carries more than that.
trunc() { printf '%s...' "$(printf '%s' "$1" | cut -c1-29)"; }
cat > "$STUB/herdr" <<'H'
#!/bin/sh
# printf, not echo: some shells' builtin echo is XSI-compliant and silently turns a literal
# \033/\007 in a logged argument into real ESC/BEL bytes, which would make the log stop
# matching the literal text the launch command actually contains (M4). printf's %s never
# reinterprets its argument.
printf 'herdr %s\n' "$*" >> "$CALLS"
pane_json() {
  a="$(cat "$P/agent" 2>/dev/null)"; t="$(cat "$P/title" 2>/dev/null)"
  s="$(cat "$P/status" 2>/dev/null || echo idle)"
  # AGENT_LAG simulates the pane's title updating before herdr's own .agent field
  # catches up: after a `pane run`, the title already shows the new session for the
  # first N post-run queries, while .agent has not flipped back to "codex" yet. Only
  # active once a run has actually happened, so preconditions before the restart never
  # see it.
  if [ -n "${AGENT_LAG:-}" ] && [ -e "$P/lag_active" ]; then
    n=$(cat "$P/get_calls" 2>/dev/null || echo 0); n=$((n + 1)); echo "$n" > "$P/get_calls"
    [ "$n" -le "$AGENT_LAG" ] && a=""
  fi
  # AGENT_EXIT_DELAY simulates the pane's OWN exit taking a few more polls to actually show
  # up in .agent, after send-keys has already flipped the real state - so the agent-exit
  # wait genuinely iterates a few times, the same way a real TUI would.
  if [ -n "${AGENT_EXIT_DELAY:-}" ] && [ -e "$P/exit_delay_active" ]; then
    n=$(cat "$P/exit_delay_calls" 2>/dev/null || echo 0); n=$((n + 1)); echo "$n" > "$P/exit_delay_calls"
    if [ "$n" -le "$AGENT_EXIT_DELAY" ]; then a=codex; else rm -f "$P/exit_delay_active"; fi
  fi
  # Step (c)'s launch command sets the real title; RESET_LAG (read-count, default 1)
  # simulates the terminal taking a few more reads to catch up before it shows, so the
  # steady-cadence wait loop genuinely iterates. RESET_LAG=0 means it shows on the very
  # first read - the reviewer's own scenario (item 21/P2): nothing to catch, because
  # nothing was watching the pane before step (c) even ran.
  if [ -e "$P/reset_pending" ]; then
    n=$(cat "$P/reset_calls" 2>/dev/null || echo 0); n=$((n + 1)); echo "$n" > "$P/reset_calls"
    if [ "$n" -gt "${RESET_LAG:-1}" ]; then
      t="$(cat "$P/newtitle" 2>/dev/null)"; printf '%s' "$t" > "$P/title"
      rm -f "$P/reset_pending"
    else
      t=xreview
    fi
  fi
  af=""; [ -n "$a" ] && af="\"agent\":\"$a\","
  printf '{%s"agent_status":"%s","cwd":"%s","pane_id":"w1:p2","terminal_title":"%s","terminal_title_stripped":"%s"}' \
    "$af" "$s" "${PANE_CWD:-$CWD}" "$t" "$t"
}
case "$1 $2" in
  "pane list") printf '{"result":{"panes":[%s%s]}}\n' "$(pane_json)" "${EXTRA_PANES:-}" ;;
  "pane get")
    # I-1: consume the fail-once marker on the very first read after the run, simulating a
    # transient herdr failure - exit nonzero with no output, never a title of any kind.
    if [ -e "$P/reset_fail_once" ]; then rm -f "$P/reset_fail_once"; exit 1; fi
    # Pre-existing: same idea, but for the agent-exit wait BEFORE the run - one failed read
    # there must keep waiting, not be read as "the field is empty" (already exited).
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
    rm -f "$P/get_calls" "$P/reset_calls" "$P/reset_pending" "$P/reset_fail_once" \
          "$P/exit_delay_active" "$P/exit_delay_calls" "$P/agent_fail_once"
    # The resume path now sends the reset ALONE, as its own `pane run` (step a), and only
    # afterwards the actual launch command (step c) - no more single combined command
    # (item 21/P2). React to which shape this call actually has, not to "a pane run
    # happened": the exact reset-alone string is step (a); anything else (a bare resume
    # command, or the fresh-session path's own combined "reset; launch" line, which never
    # carries "resume") is the launch itself.
    case "$4" in
      "printf '\033]2;xreview\007'")
        # Step (a): the reset alone. Clears the old session; the title then STAYS at
        # "xreview" (nothing else runs in the pane until step (c)), unless STUCK_TITLE
        # simulates the disconnected TUI never relaunching at all.
        : > "$P/agent"
        # I-1: one `pane get` right after the reset fails outright (not merely empty),
        # simulating a transient herdr hiccup during the reset wait - applies whichever
        # call carries it, so it also covers the exact repro combined with STUCK_TITLE: a
        # failed read must never be read as "observed a title that is not want".
        [ -n "${RESET_FAIL_ONCE:-}" ] && : > "$P/reset_fail_once"
        if [ -n "${STUCK_TITLE:-}" ]; then
          : # the disconnected TUI never actually attaches: the title stays exactly as it
            # was, still showing `want` - pane_prepare must never accept that without first
            # observing a non-want title.
        else
          printf xreview > "$P/title"
        fi ;;
      *)
        # Step (c) (or the fresh-session's single combined call).
        [ -n "${NO_TITLE:-}" ] && exit 0
        printf codex > "$P/agent"
        : > "$P/lag_active"
        # Truncate to a realistic title (F11/F21: 29 chars plus "..." once the thread is
        # named). This is its own process (#!/bin/sh), so it cannot call the parent
        # script's trunc().
        case "$4" in
          *" resume "*) full="${4##* resume }"; len=29 ;;
          # M4: a relaunch can show the SAME thread at a different truncation length than
          # whatever the pane's title showed before - RELAUNCH_PREFIX_LEN simulates that.
          *) full="$NEW_UUID"; len="${RELAUNCH_PREFIX_LEN:-29}" ;;
        esac
        [ -n "${RESET_FAIL_ONCE:-}" ] && : > "$P/reset_fail_once"
        if [ -n "${STUCK_TITLE:-}" ]; then
          : # never shows the new title either, whichever call is meant to carry it
        else
          printf '%s... | t | d' "$(printf '%s' "$full" | cut -c1-"$len")" > "$P/newtitle"
          if [ "${RESET_LAG:-1}" = 0 ]; then
            cat "$P/newtitle" > "$P/title"
          else
            printf xreview > "$P/title"; : > "$P/reset_pending"
          fi
        fi ;;
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
th=""; input=""; known=""; resolved=""; prefix=""
while [ "$#" -gt 0 ]; do
  case "$1" in --thread) th="$2"; shift ;; --input) input="$2"; shift ;; --known) known="$2"; shift ;;
               --resolved) resolved="$2"; shift ;; --prefix) prefix="$2"; shift ;; esac; shift
done
case "$cmd" in
  health) [ -z "${RPC_HEALTH_FAIL:-}" ] || exit 5; exit 0 ;;
  thread-resolve)
    for u in "$U0" "$U1" "$U2"; do
      case "$u" in "$prefix"*) echo "$u"; exit 0 ;; esac
    done
    exit 1 ;;
  thread-status)
    n=$(cat "$P/status_calls" 2>/dev/null || echo 0); n=$((n + 1)); echo "$n" > "$P/status_calls"
    if [ -n "${RPC_THREAD_RUNNING:-}" ]; then
      echo '{"loaded":true,"status":"active","running":true}'
    elif [ -n "${RPC_NOT_LOADED:-}" ] \
         || { [ -n "${RPC_NOT_LOADED_ONCE:-}" ] && [ "$n" = "${RPC_NOT_LOADED_ONCE_AT:-1}" ]; }; then
      echo '{"loaded":false,"status":"notLoaded","running":false}'
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

fresh() { # a pane showing U0, idle; clean log and state
  unset ENSURE_RC CHECK_RC RPC_NOT_LOADED RPC_NOT_LOADED_ONCE RPC_NOT_LOADED_ONCE_AT RPC_START_FAIL \
        RPC_START_UNCERTAIN RPC_START_BAD_ID NO_TITLE STUCK_TUI STUCK_TITLE RESET_LAG \
        RESET_FAIL_ONCE AGENT_EXIT_DELAY \
        AGENT_READ_FAIL_ONCE EXTRA_PANES PANE_CWD XREVIEW_PANE XREVIEW_THREAD RPC_WAIT_OUT \
        RPC_WAIT_RC RPC_THREAD_RUNNING RPC_HEALTH_FAIL AGENT_LAG
  export NEW_UUID="$U1"
  printf codex > "$P/agent"; printf '%s | t | d' "$(trunc "$U0")" > "$P/title"; echo idle > "$P/status"
  echo 0 > "$P/ctrlc"
  rm -f "$P/packet" "$P/status_calls" "$P/get_calls" "$P/lag_active" "$P/reset_calls" \
        "$P/reset_pending" "$P/newtitle" "$P/reset_fail_once" "$P/exit_delay_active" \
        "$P/exit_delay_calls" "$P/agent_fail_once"
  bash "$XREVIEW" round --reset >/dev/null 2>&1
  rm -rf "$STATE/superseded" "$STATE/pin" "$STATE/turns"
  rm -f "$STATE/pane"   # F31: the fast-path record must never leak from a previous test
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
out="$(bash "$XREVIEW" dispatch b.md 2>&1)"
is "the tenth round is still allowed"    "$(printf '%s' "$out" | grep -c 'exceeds the cap')" 0
is "and the tenth round produces a nonce" "$(printf '%s' "$out" | grep -c '^xr-')" 1
starts="$(called 'xreview-rpc turn-start')"
is "the eleventh round is refused"    "$(capped)" 1
is "and starts no turn"               "$(called 'xreview-rpc turn-start')" "$starts"
is "a refused round still increments, so retrying stays refused" "$(bash "$XREVIEW" round)" 11
bash "$XREVIEW" round --reset >/dev/null
is "reset returns the counter to zero" "$(bash "$XREVIEW" round)" 0
# round --reset drops the checkpoint thread too, so this dispatch takes the slow,
# fresh-session path - give it a thread id the pane's title has never shown before
# (U1, reused throughout this section, would otherwise look unchanged, not new).
export NEW_UUID="$U2"
out="$(XREVIEW_MAX_ROUNDS=1 bash "$XREVIEW" dispatch b.md 2>&1)"
is "dispatch is permitted again after reset" "$(printf '%s' "$out" | grep -c '^xr-')" 1
is "XREVIEW_MAX_ROUNDS lowers the cap" "$(XREVIEW_MAX_ROUNDS=1 bash "$XREVIEW" dispatch b.md 2>&1 | grep -c 'exceeds the cap')" 1
export NEW_UUID="$U1"
fresh
bash "$XREVIEW" round --reset >/dev/null
before_round="$(bash "$XREVIEW" round)"
STUCK_TUI=1 bash "$XREVIEW" dispatch b.md >/dev/null 2>&1
is "A2 a pane-preparation failure leaves the round count unchanged" "$(bash "$XREVIEW" round)" "$before_round"

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
out="$(RPC_THREAD_RUNNING=1 bash "$XREVIEW" dispatch b.md 2>&1)"
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

echo "D. the pane comes first"
fresh
nonce="$(bash "$XREVIEW" dispatch b.md 2>/dev/null)"
is "D1 a nonce is printed" "$(printf '%s' "$nonce" | grep -c '^xr-')" 1
is "D1 the pane's session is ended" "$(called 'herdr pane send-keys w1:p2 ctrl+c')" 2
is "D1 a fresh session runs the pane command" \
   "$(called 'herdr pane run w1:p2 .*codex --sandbox read-only --ask-for-approval never')" 1
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
printf '%s | t | d' "$(trunc "$U0")" > "$P/title"; : > "$CALLS"
bash "$XREVIEW" dispatch b.md >/dev/null 2>&1
is "D3 a pane that moved off the thread is resumed onto it" "$(called "herdr pane run w1:p2 .*codex --sandbox read-only --ask-for-approval never resume $U1")" 1
is "D3b the reset is sent alone, as its own pane run" \
   "$(grep -Fxc "herdr pane run w1:p2 printf '\033]2;xreview\007'" "$CALLS")" 1
is "D3b' the resume relaunch carries no reset prefix of its own" \
   "$(grep -Fc "herdr pane run w1:p2 printf '\033]2;xreview\007'; codex " "$CALLS")" 0
reset_line="$(grep -Fn "herdr pane run w1:p2 printf '\033]2;xreview\007'" "$CALLS" | head -1 | cut -d: -f1)"
resume_line="$(grep -Fn "resume $U1" "$CALLS" | head -1 | cut -d: -f1)"
is "D3b'' the reset happens before the resume relaunch" \
   "$([ -n "$reset_line" ] && [ -n "$resume_line" ] && [ "$reset_line" -lt "$resume_line" ] && echo yes || echo no)" yes

echo "D3c. the P1 (slice 2): a disconnected TUI's retained title never passes as the resumed session"
fresh
bash "$XREVIEW" dispatch b.md >/dev/null 2>&1   # establishes want=U1; the pane's title already shows it
mkdir -p "$CODEX_HOME/app-server-daemon"; printf '{"pid":999}\n' > "$CODEX_HOME/app-server-daemon/daemon.pid"
: > "$CALLS"
out="$(STUCK_TITLE=1 bash "$XREVIEW" dispatch b.md 2>&1)"; rc=$?
is "D3c it refuses after the wait, never trusting the retained title" \
   "$(printf '%s' "$out" | grep -c 'did not show')" 1
is "D3c and no turn ever starts on the unwatched pane" "$(called 'xreview-rpc turn-start')" 0
rm -rf "$CODEX_HOME/app-server-daemon"   # restore the "no daemon.pid yet" baseline for later tests

echo "D3d. I-1: a single failed read right after the run is never mistaken for 'observed not-want'"
fresh
bash "$XREVIEW" dispatch b.md >/dev/null 2>&1   # establishes want=U1; the pane's title already shows it
mkdir -p "$CODEX_HOME/app-server-daemon"; printf '{"pid":999}\n' > "$CODEX_HOME/app-server-daemon/daemon.pid"
: > "$CALLS"
out="$(STUCK_TITLE=1 RESET_FAIL_ONCE=1 bash "$XREVIEW" dispatch b.md 2>&1)"; rc=$?
is "D3d it refuses after the wait, a failed read never counted as a real observation" \
   "$(printf '%s' "$out" | grep -c 'did not show')" 1
is "D3d and no turn ever starts on the unwatched pane" "$(called 'xreview-rpc turn-start')" 0
rm -rf "$CODEX_HOME/app-server-daemon"   # restore the "no daemon.pid yet" baseline for later tests

echo "D3e. item 21/P2: the replacement TUI restoring want on the very first post-launch read is not refused"
# The old combined reset+relaunch command left a real, if short, window during which a
# fast-attaching replacement TUI could restore `want` before pane_prepare's poll ever
# observed the intermediate reset - so dispatch refused a pane that was actually ready
# (item 21/P2, the reviewer's own repro). The two-step relaunch removes the window
# entirely: the reset is confirmed BEFORE the replacement session is even launched, so
# nothing can restore `want` early. RESET_LAG=0 simulates the tightest case, want showing
# on the very first read after the relaunch - deterministic, not timing-dependent (this
# replaces the flaky wall-clock M5/D3e case, which no longer has anything to reproduce:
# nothing runs in the pane between the two steps for a transient to hide in).
fresh
bash "$XREVIEW" dispatch b.md >/dev/null 2>&1   # establishes want=U1
mkdir -p "$CODEX_HOME/app-server-daemon"; printf '{"pid":999}\n' > "$CODEX_HOME/app-server-daemon/daemon.pid"
: > "$CALLS"
out="$(RESET_LAG=0 bash "$XREVIEW" dispatch b.md 2>&1)"; rc=$?
is "D3e it still succeeds, want showing immediately after the relaunch" \
   "$(printf '%s' "$out" | grep -c '^xr-')" 1
is "D3e and the reset was still issued as its own pane run, before the relaunch" \
   "$(grep -Fxc "herdr pane run w1:p2 printf '\033]2;xreview\007'" "$CALLS")" 1
rm -rf "$CODEX_HOME/app-server-daemon"

echo "D3f. pre-existing: a failed .agent read during the exit wait keeps waiting, not skips it"
# AGENT_EXIT_DELAY makes .agent genuinely keep reading "codex" for a few more polls after
# send-keys, as a slow-exiting TUI would; AGENT_READ_FAIL_ONCE fails the very first read of
# that phase outright. A read failure treated as "the field is empty" would end the wait on
# that first (failed) read - long before the delay actually elapses.
fresh
printf '%s | t | d' "$(trunc "$U0")" > "$P/title"; : > "$CALLS"   # forces the resume path
out="$(AGENT_EXIT_DELAY=3 AGENT_READ_FAIL_ONCE=1 XREVIEW_POLL_SECS=0.05 XREVIEW_PANE_WAIT=5 \
        bash "$XREVIEW" dispatch b.md 2>&1)"; rc=$?
is "D3f it still succeeds" "$(printf '%s' "$out" | grep -c '^xr-')" 1
# Between the second ctrl+c and `pane run`, the exit-wait loop makes one ".agent" read per
# iteration: the first (failed) one, then 3 more covering the delay, then the one that
# finally reads empty and breaks the loop - 5 in total. A failed read misread as "already
# exited" would instead call `pane run` after just that first (failed) read - 1, not 5.
is "D3f the exit wait actually iterated through the delay, not stopped on the failed read" \
   "$(awk '/pane send-keys/{n++} n>=2{print} /pane run/{exit}' "$CALLS" | grep -c 'pane get')" 5

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
RPC_NOT_LOADED_ONCE=1 RPC_NOT_LOADED_ONCE_AT=2 bash "$XREVIEW" dispatch b.md >/dev/null 2>&1
is "D9 a matching title on a thread the daemon lost is resumed, not trusted" \
   "$(called "herdr pane run w1:p2 .*codex --sandbox read-only --ask-for-approval never resume $U1")" 1
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
   "$(called "herdr pane run w1:p2 .*codex --sandbox read-only --ask-for-approval never resume $U1")" 1
is "D11 and the turn starts only after the pane is re-pointed" \
   "$([ "$(first 'herdr pane run')" -lt "$(first 'xreview-rpc turn-start')" ] && echo yes || echo no)" yes

fresh
mkdir -p "$CODEX_HOME/app-server-daemon"; printf '{"pid":111}\n' > "$CODEX_HOME/app-server-daemon/daemon.pid"
bash "$XREVIEW" dispatch b.md >/dev/null 2>&1   # records the generation for pid 111
printf '{"pid":222}\n' > "$CODEX_HOME/app-server-daemon/daemon.pid"   # content CHANGES, not just appears
: > "$CALLS"
bash "$XREVIEW" dispatch b.md >/dev/null 2>&1
is "D11b a daemon.pid whose content changes (not just appears) is also a detected restart" \
   "$(called "herdr pane run w1:p2 .*codex --sandbox read-only --ask-for-approval never resume $U1")" 1
rm -rf "$CODEX_HOME/app-server-daemon"   # restore the "no daemon.pid yet" baseline for later tests

fresh
bash "$XREVIEW" init "$U0" >/dev/null    # the pin the pane's title already shows, nothing recorded
: > "$CALLS"
bash "$XREVIEW" dispatch b.md >/dev/null 2>&1
is "D12 a pin whose title already matches is still resumed once, with nothing recorded yet" \
   "$(called "herdr pane run w1:p2 .*codex --sandbox read-only --ask-for-approval never resume $U0")" 1
: > "$CALLS"
bash "$XREVIEW" dispatch b.md >/dev/null 2>&1
is "D12 the dispatch after that takes the fast path" "$(called 'herdr pane send-keys')" 0

fresh; export AGENT_LAG=2
start="$EPOCHREALTIME"
nonce="$(bash "$XREVIEW" dispatch b.md 2>/dev/null)"
took="$(awk -v s="$start" -v e="$EPOCHREALTIME" 'BEGIN{printf "%.3f", e-s}')"
is "D13 a title that updates before .agent says codex is not trusted early" \
   "$(printf '%s' "$nonce" | grep -c '^xr-')" 1
# At least one poll interval must have elapsed for .agent to catch up (sub-second: the
# suite scales XREVIEW_POLL_SECS down, so whole-second resolution would always read 0).
is "D13 dispatch waited for .agent to actually say codex" \
   "$(awk -v t="$took" -v p="$XREVIEW_POLL_SECS" 'BEGIN{print (t >= p) ? "yes" : "no ("t"s)"}')" yes
fresh; export AGENT_LAG=10
out="$(bash "$XREVIEW" dispatch b.md 2>&1)"; rc=$?
is "D14 .agent never saying codex times out" "$rc" 1
is "D14 and says so" "$(printf '%s' "$out" | grep -c 'did not show')" 1
unset AGENT_LAG

fresh; export NEW_UUID=dddddddd-4444-4444-8444-444444444444   # unknown to the resolver stub
out="$(bash "$XREVIEW" dispatch b.md 2>&1)"; rc=$?
is "D15 a title prefix that resolves to no loaded thread refuses after the wait" \
   "$(printf '%s' "$out" | grep -c 'did not show')" 1
is "D15 and no turn starts" "$(called 'xreview-rpc turn-start')" 0

fresh
nonce="$(RPC_START_BAD_ID=1 bash "$XREVIEW" dispatch b.md 2>"$ROOT/err")"; rc=$?
is "D16 turn-start returning 0 with a malformed id still hands back a nonce" \
   "$rc/$(printf '%s' "$nonce" | grep -c '^xr-')" "0/1"
is "D16 with a do-not-re-dispatch warning, exactly like exit 6" \
   "$(grep -c 'do NOT re-dispatch' "$ROOT/err")" 1
is "D16 the record marks the turn unknown" "$(cat "$STATE/turns/$nonce")" "$U1 ?"

echo "D17. a relaunch showing the SAME thread at a different truncation length is not new (M4/F42)"
fresh
bash "$XREVIEW" dispatch b.md >/dev/null 2>&1   # the pane now shows U1's standard 29-char prefix
bash "$XREVIEW" round --reset >/dev/null 2>&1   # want="" for the next dispatch; the title is untouched
: > "$CALLS"
out="$(RELAUNCH_PREFIX_LEN=36 bash "$XREVIEW" dispatch b.md 2>&1)"; rc=$?
is "D17 it refuses, never mistaking the shorter prefix for a new thread" "$rc" 1
is "D17 and says so" "$(printf '%s' "$out" | grep -c 'did not show a new thread')" 1
is "D17 and never dispatches into the old (or any) thread" "$(called 'xreview-rpc turn-start')" 0

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
is "E7 a fresh pane session starts instead" \
   "$(called 'herdr pane run w1:p2 .*codex --sandbox read-only --ask-for-approval never')" 1
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
fresh
start="$(/bin/date +%s.%N)"
out="$(LC_ALL=nl_BE.UTF-8 NO_TITLE=1 XREVIEW_PANE_WAIT=0.15 XREVIEW_POLL_SECS=0.05 bash "$XREVIEW" dispatch b.md 2>&1)"; rc=$?
took="$(LC_ALL=C awk -v s="$start" -v e="$(/bin/date +%s.%N)" 'BEGIN{printf "%.3f", e-s}')"
is "K2 it refuses (never shows a thread)" "$rc" 1
is "K2 and the 0.15s bound actually held, not stretched by whole-second truncation" \
   "$(LC_ALL=C awk -v t="$took" 'BEGIN{print (t<0.6) ? "yes" : "no ("t"s)"}')" yes

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
export NEW_UUID="$U2"   # round --reset drops the cached thread, so this dispatch takes the
                         # slow, fresh-session path - give it a thread id the pane's title
                         # (still showing U1 from L2/L4) has never shown before
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
