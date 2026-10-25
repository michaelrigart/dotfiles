#!/usr/bin/env bash
# Tests for dot_local/bin/executable_xreview on the Codex daemon (spec section 7).
#
# Every collaborator is stubbed on PATH:
#   herdr         one Codex pane, w1:p2, whose title, agent, process argv, screen and daemon
#                 connection live in files under $P
#   lsof          the daemon's own sockets, and the pane TUI's peer (connected or elsewhere)
#   codex-daemon  ensure/check exit codes
#   xreview-rpc   thread-start, thread status/resolve, turn start and wait, archive
# Each stub logs its calls to $CALLS, so ordering is asserted from the log. Dispatch FREES
# the pane (a ctrl+c ladder, unless the pane already shows the checkpoint thread on a TUI
# connected to the daemon) BEFORE any turn exists, THEN starts the review turn, and only THEN
# best-effort resumes the pane onto it (F22: a TUI resuming a thread mid-turn replays it from
# the start). No precondition may be skipped, and no keystroke (send-keys) may ever reach the
# pane once the turn exists (C1).
set -uo pipefail
SRC="$(cd "$(dirname "$0")/.." && pwd)"
XREVIEW="$SRC/dot_local/bin/executable_xreview"
LEDGER="$SRC/dot_claude/xreview-ledger.py"
PACKET="$SRC/dot_claude/xreview-packet.py"
for f in "$XREVIEW" "$LEDGER" "$PACKET"; do
  [ -f "$f" ] || { echo "missing file under test: $f" >&2; exit 2; }
done
pass=0; fail=0
_pass() { printf '  PASS: %s\n' "$1"; pass=$((pass + 1)); }
_fail() { printf '  FAIL: %s\n    | got: %s\n' "$1" "$2"; fail=$((fail + 1)); }
is() { if [ "$2" = "$3" ]; then _pass "$1"; else _fail "$1" "$2"; fi; }

ROOT="$(mktemp -d "${TMPDIR:-/tmp}/xreview.XXXXXX")"
trap 'rm -rf "$ROOT"' EXIT
export XDG_STATE_HOME="$ROOT/state" XDG_CONFIG_HOME="$ROOT/config" CODEX_HOME="$ROOT/codex" \
       TMPDIR="$ROOT/tmp"
mkdir -p "$XDG_CONFIG_HOME/xreview" "$XDG_CONFIG_HOME/herdr" "$TMPDIR"
cp "$SRC/dot_config/xreview/findings.schema.json" "$SRC/dot_config/xreview/reviewer.md" \
   "$SRC/dot_config/xreview/findings.framed.schema.json" "$SRC/dot_config/xreview/reviewer-framing.md" \
   "$SRC/dot_config/xreview/packets.conf" "$XDG_CONFIG_HOME/xreview/"
cp "$SRC/dot_config/herdr/codex-pane-command" "$XDG_CONFIG_HOME/herdr/"
export XREVIEW_POLL_SECS=0.05 XREVIEW_PANE_WAIT=2 XREVIEW_LEDGER="$LEDGER" XREVIEW_PACKET="$PACKET"
unset XREVIEW_MAX_ROUNDS XREVIEW_PANE XREVIEW_THREAD XREVIEW_LEDGER_LOCK_WAIT
PANE_CMD='codex --sandbox read-only --ask-for-approval never'

mkdir -p "$ROOT/repo" && cd "$ROOT/repo" || exit 1
git init -q . && git config user.email t@t && git config user.name t
git config commit.gpgsign false
git commit -q --allow-empty -m init || { printf 'fixture setup failed\n' >&2; exit 1; }
printf 'body\n' > b.md
CWD="$(git rev-parse --show-toplevel)"
BR="$(git rev-parse --abbrev-ref HEAD)"   # the branch the dispatches below run on
STATE="$XDG_STATE_HOME/xreview/$(printf '%s' "$CWD" | tr '/' '_' | sed 's/^_//')"
MAIN_LEDGER="$(/usr/bin/python3 "$LEDGER" path "$CWD")"   # this repository's review ledger

# --- stubs ------------------------------------------------------------------------
STUB="$ROOT/stub"; P="$ROOT/pane"; mkdir -p "$STUB" "$P"
export CALLS="$ROOT/calls" P CWD
export U0=aaaaaaaa-0000-4000-8000-000000000000   # the thread the pane shows at the start
export U1=bbbbbbbb-1111-4111-8111-111111111111   # what xreview-rpc thread-start creates
export U2=cccccccc-2222-4222-8222-222222222222
export U3=dddddddd-3333-4333-8333-333333333333   # the threads of a sliced round's later slices
export U4=eeeeeeee-4444-4444-8444-444444444444
export NEW_UUID="$U1"
# Codex truncates the title's thread-id item to 29 chars plus "..." once the thread is named
# (F11/F21); a realistic stub title never carries more than that.
trunc() { printf '%s...' "$(printf '%s' "$1" | cut -c1-29)"; }
cat > "$STUB/herdr" <<'H'
#!/bin/sh
# printf, not echo: some shells' builtin echo is XSI-compliant and silently turns a literal
# \033/\007 in a logged argument into real ESC/BEL bytes, which would make the log stop
# matching the literal text the launch command actually contains.
printf '%sherdr %s\n' "${DISPATCH_ID:+$DISPATCH_ID }" "$*" >> "$CALLS"
agent_now() { # the pane's agent as this read sees it: "codex" while a TUI runs, else empty
  a="$(cat "$P/agent" 2>/dev/null)"
  # AGENT_EXIT_DELAY simulates the pane's OWN exit taking a few more reads to actually show
  # up, after send-keys has already flipped the real state - so the ladder's poll genuinely
  # iterates a few times, the same way a real TUI would. Every read counts against the delay:
  # .agent in a pane get or list, and the foreground process in a process-info.
  if [ -n "${AGENT_EXIT_DELAY:-}" ] && [ -e "$P/exit_delay_active" ]; then
    n=$(cat "$P/exit_delay_calls" 2>/dev/null || echo 0); n=$((n + 1)); echo "$n" > "$P/exit_delay_calls"
    if [ "$n" -le "$AGENT_EXIT_DELAY" ]; then a=codex; else rm -f "$P/exit_delay_active"; fi
  fi
  printf '%s' "$a"
}
pane_json() {
  a="$(agent_now)"; t="$(cat "$P/title" 2>/dev/null)"
  s="$(cat "$P/status" 2>/dev/null || echo idle)"
  # The resume command's own title takes one extra read to land, so the final wait loop
  # genuinely iterates at least once, the same way a real TUI's title update would.
  if [ -e "$P/reset_pending" ]; then
    n=$(cat "$P/reset_calls" 2>/dev/null || echo 0); n=$((n + 1)); echo "$n" > "$P/reset_calls"
    if [ "$n" -gt 1 ]; then
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
    # A closed pane gets herdr's real answer: exit 1 and a pane_not_found envelope on stderr.
    # GONE_AFTER_KEYS and GONE_AFTER_RUN close it mid-dispatch (T4).
    if [ -e "$P/gone" ]; then
      echo '{"error":{"code":"pane_not_found","message":"pane w1:p2 not found"},"id":"cli:pane:get"}' >&2
      exit 1
    fi
    # GET_FAIL: a read that fails without the pane being gone - herdr exiting nonzero
    # (exit), or exiting 0 with an error envelope (envelope).
    case "${GET_FAIL:-}" in
      exit) exit 1 ;;
      envelope) echo '{"error":{"code":"internal","message":"boom"},"id":"cli:pane:get"}'; exit 0 ;;
    esac
    printf '{"result":{"pane":%s}}\n' "$(pane_json)" ;;
  "pane process-info")
    [ -n "${PROCINFO_FAIL:-}" ] && exit 1
    # I-1: consume the fail-once marker on the very first process-info read after the quit,
    # simulating a transient herdr failure during the ladder's poll - exit nonzero with no
    # output, never a process of any kind.
    if [ -e "$P/procinfo_fail_once" ]; then rm -f "$P/procinfo_fail_once"; exit 1; fi
    if [ -e "$P/gone" ]; then
      echo '{"error":{"code":"pane_not_found","message":"pane w1:p2 not found"}}' >&2; exit 1
    fi
    # A running TUI is the foreground group's leader, pid 4242, with the argv it was started
    # with ($P/argv, or the pane command). CODEX_CHILD puts a codex child in its group, listed
    # first. PROCINFO_BAD describes the TUI incompletely: argv empty, null or missing, or no
    # name. A pane without a TUI is its shell, pid 4241, in the foreground (G1).
    # PROCINFO_FG: a foreground group that is not the shell (4242) but whose process list is
    # empty (empty) or holds only a non-Codex process (vim); or the shell itself in the
    # foreground while herdr still reports the pane's agent (shell).
    case "${PROCINFO_FG:-}" in
      empty) printf '{"result":{"process_info":{"foreground_process_group_id":4242,"foreground_processes":[],"pane_id":"w1:p2","shell_pid":4241}}}\n'; exit 0 ;;
      shell) printf '{"result":{"process_info":{"foreground_process_group_id":4241,"foreground_processes":[{"argv":["-zsh"],"name":"zsh","pid":4241}],"pane_id":"w1:p2","shell_pid":4241}}}\n'; exit 0 ;;
      vim)   printf '{"result":{"process_info":{"foreground_process_group_id":4242,"foreground_processes":[{"argv":["vim","x"],"name":"vim","pid":4242}],"pane_id":"w1:p2","shell_pid":4241}}}\n'; exit 0 ;;
    esac
    if [ "$(agent_now)" = codex ]; then
      argv="$(cat "$P/argv" 2>/dev/null || printf 'codex --sandbox read-only --ask-for-approval never')"
      argv="$(printf '%s' "$argv" | jq -R -c 'split(" ")')"
      case "${PROCINFO_BAD:-}" in
        argv-empty)   fields='"argv":[],"name":"codex"' ;;
        argv-null)    fields='"argv":null,"name":"codex"' ;;
        argv-missing) fields='"name":"codex"' ;;
        name-missing) fields="\"argv\":$argv" ;;
        *)            fields="\"argv\":$argv,\"name\":\"codex\"" ;;
      esac
      extra=""; [ -n "${CODEX_CHILD:-}" ] && extra=',{"argv":["codex","app-server"],"name":"codex","pid":4243}'
      printf '{"result":{"process_info":{"foreground_process_group_id":4242,"foreground_processes":[%s{%s,"pid":4242}],"pane_id":"w1:p2","shell_pid":4241}}}\n' \
        "${extra:+${extra#,},}" "$fields"
    else
      printf '{"result":{"process_info":{"foreground_process_group_id":4241,"foreground_processes":[{"argv":["-zsh"],"name":"zsh","pid":4241}],"pane_id":"w1:p2","shell_pid":4241}}}\n'
    fi ;;
  "pane read")
    [ -n "${READ_FAIL:-}" ] && exit 1
    cat "$P/screen" 2>/dev/null || printf '%s\n' '› Ask Codex to do anything' ;;
  "pane send-keys")
    sleep "${KEY_DELAY:-0}"
    [ -n "${GONE_AFTER_KEYS:-}" ] && : > "$P/gone"
    n=$(cat "$P/ctrlc" 2>/dev/null || echo 0); n=$((n + 1)); echo "$n" > "$P/ctrlc"
    # The TUI quits at the second ctrl+c. PRESESSION holds it on a pre-session screen, which
    # the first pair only dismisses, so it quits at the fourth (G8). STUCK_TUI never quits.
    # A TUI that quits takes its daemon connection with it.
    q=2; [ -n "${PRESESSION:-}" ] && q=4
    if [ "$n" -ge "$q" ] && [ -z "${STUCK_TUI:-}" ]; then
      : > "$P/agent"; rm -f "$P/connected"
      : > "$P/exit_delay_active"; rm -f "$P/exit_delay_calls"
      [ -n "${AGENT_READ_FAIL_ONCE:-}" ] && : > "$P/procinfo_fail_once"
    fi ;;
  "pane run")
    # PANE_RUN_FAIL simulates herdr itself failing the launch command (Minor 6) - it must
    # never reach the pane's title/agent state at all.
    [ -n "${PANE_RUN_FAIL:-}" ] && exit 1
    [ -n "${GONE_AFTER_RUN:-}" ] && : > "$P/gone"
    echo 0 > "$P/ctrlc"
    rm -f "$P/reset_calls" "$P/reset_pending" "$P/exit_delay_active" "$P/exit_delay_calls" \
          "$P/procinfo_fail_once"
    # pane_resume only ever issues one shape of launch command: "$cmd -C <root> resume
    # $thread" - the thread is always known before the pane is touched. NO_TITLE simulates a
    # pane that never shows any title at all, however long dispatch waits: no TUI starts.
    [ -n "${NO_TITLE:-}" ] && exit 0
    # The relaunched TUI runs the command it was given, connected to the daemon.
    printf codex > "$P/agent"
    printf '%s' "$4" > "$P/argv"; : > "$P/connected"
    full="${4##* resume }"
    # Truncate to a realistic title (F11/F21: 29 chars plus "..." once the thread is named).
    printf '%s... | t | d' "$(printf '%s' "$full" | cut -c1-29)" > "$P/newtitle"
    : > "$P/reset_pending" ;;
esac
exit 0
H
cat > "$STUB/codex-daemon" <<'D'
#!/bin/sh
echo "codex-daemon $*" >> "$CALLS"
case "$1" in
  ensure) [ -n "${ENSURE_MARK:-}" ] && : > "$ENSURE_MARK"   # ENSURE_MARK: say that ensure ran
          exit "${ENSURE_RC:-0}" ;;
  check) [ "${CHECK_RC:-0}" = 0 ] || echo "codex-daemon: carries a herdr pane's environment" >&2
         exit "${CHECK_RC:-0}" ;;
esac
D
# The daemon (pid 999, from fresh's daemon.pid) owns two unix sockets. The pane's TUI (4242)
# holds a peer on one of them while $P/connected exists, and a peer elsewhere otherwise (G3).
# It answers only a call that passes both -a and -U: without -a, lsof ORs its selections
# (every unix socket on the machine, or every file of the pid), and without -U it lists
# every file type. Either is a mis-call, answered with nothing.
cat > "$STUB/lsof" <<'L'
#!/bin/sh
printf 'lsof %s\n' "$*" >> "$CALLS"
[ -n "${LSOF_FAIL:-}" ] && exit 1
pid=""; field=""; and=""; unix=""
while [ "$#" -gt 0 ]; do
  case "$1" in -a) and=1 ;; -U) unix=1 ;; -p) pid="$2"; shift ;; -F) field="$2"; shift ;; esac; shift
done
[ -n "$and" ] && [ -n "$unix" ] || exit 0
case "$pid/$field" in
  999/d)  printf 'p999\nf10\nd0xdaemon1\nf11\nd0xdaemon2\n' ;;
  4242/n) if [ -e "$P/connected" ]; then printf 'p4242\nf5\nn->0xdaemon2\n'; else printf 'p4242\nf5\nn->0xelsewhere\n'; fi ;;
esac
exit 0
L
cat > "$STUB/xreview-rpc" <<'R'
#!/bin/sh
printf '%sxreview-rpc %s\n' "${DISPATCH_ID:+$DISPATCH_ID }" "$*" >> "$CALLS"
cmd="$1"; shift
th=""; input=""; known=""; resolved=""; prefix=""; cwd=""; turn=""; report=""
while [ "$#" -gt 0 ]; do
  case "$1" in --thread) th="$2"; shift ;; --input) input="$2"; shift ;; --known) known="$2"; shift ;;
               --resolved) resolved="$2"; shift ;; --prefix) prefix="$2"; shift ;;
               --cwd) cwd="$2"; shift ;; --turn) turn="$2"; shift ;; --report) report="$2"; shift ;; esac; shift
done
case "$cmd" in
  health) [ -n "${RPC_SWITCH_BRANCH_EARLY:-}" ] && git checkout -q "$RPC_SWITCH_BRANCH_EARLY" 2>/dev/null
          [ -z "${RPC_HEALTH_FAIL:-}" ] || exit 5; exit 0 ;;
  thread-start) [ -n "${RPC_START_THREAD_FAIL:-}" ] && exit 1
                # $P/uuids: the ids later thread-starts hand out, one per call, in order (slices).
                if [ -s "$P/uuids" ]; then
                  head -1 "$P/uuids"; tail -n +2 "$P/uuids" > "$P/uuids.t"; mv "$P/uuids.t" "$P/uuids"
                else echo "$NEW_UUID"; fi ;;
  thread-resolve)
    # RPC_RESOLVE_RC=<n>: the resolver exits n (5: daemon unreachable, 2: usage, 1: no match).
    [ -n "${RPC_RESOLVE_RC:-}" ] && exit "$RPC_RESOLVE_RC"
    for u in "$U0" "$U1" "$U2" "$U3" "$U4"; do
      case "$u" in "$prefix"*) echo "$u"; exit 0 ;; esac
    done
    exit 1 ;;
  thread-status)
    # RPC_STATUS_FAIL_FOR=<id>: that one thread's state cannot be read.
    [ -n "${RPC_STATUS_FAIL_FOR:-}" ] && [ "$th" = "$RPC_STATUS_FAIL_FOR" ] && exit 1
    # RPC_STATUS_NOBOOL_FOR=<id>: that thread's status answers, but with no boolean `running`.
    [ -n "${RPC_STATUS_NOBOOL_FOR:-}" ] && [ "$th" = "$RPC_STATUS_NOBOOL_FOR" ] && { echo '{"loaded":true,"status":"idle","running":"no"}'; exit 0; }
    # RPC_THREAD_RUNNING: every thread queried is running. RPC_THREAD_RUNNING_FOR=<id>:
    # only that one thread is (Minor 4's own check runs on the CHOSEN thread, separately
    # from the precondition gate's check on whatever the pane's title resolves to, so a
    # test targeting one must not also trip the other).
    if [ -n "${RPC_THREAD_RUNNING:-}" ] || { [ -n "${RPC_THREAD_RUNNING_FOR:-}" ] && [ "$th" = "$RPC_THREAD_RUNNING_FOR" ]; }; then
      echo '{"loaded":true,"status":"active","running":true}'
    elif [ -e "$P/running.$th" ]; then
      echo '{"loaded":true,"status":"active","running":true}'
    else echo '{"loaded":true,"status":"idle","running":false}'; fi ;;
  turn-start) cp "$input" "$P/packet"; [ -n "$known" ] && echo '[]' > "$known"
              # SNAP_LEDGER: keep a copy of that ledger as it stood when the turn started.
              [ -n "${SNAP_LEDGER:-}" ] && cp "$SNAP_LEDGER" "$P/ledger-at-start" 2>/dev/null
              [ -n "${RPC_RUNNING_AFTER_START:-}" ] && : > "$P/running.$th"
              # RELIVE_DURING_TURN simulates a live Codex TUI reappearing in the pane while
              # the turn itself was starting (fix round 2/D) - pane_free already saw the shell
              # back in the foreground before this ran; this is what a race would look like.
              [ -n "${RELIVE_DURING_TURN:-}" ] && printf codex > "$P/agent"
              [ -n "${RPC_SWITCH_BRANCH_TO:-}" ] && git checkout -q "$RPC_SWITCH_BRANCH_TO" 2>/dev/null
              # LOCK_PROBE=<lock file>: log whether the pane lock is held while the turn starts.
              if [ -n "${LOCK_PROBE:-}" ]; then
                if /usr/bin/python3 -I -c 'import fcntl,sys; fcntl.flock(open(sys.argv[1], "a"), fcntl.LOCK_EX | fcntl.LOCK_NB)' "$LOCK_PROBE" 2>/dev/null
                then echo "lock-probe free" >> "$CALLS"; else echo "lock-probe held" >> "$CALLS"; fi
              fi
              # $P/start_rc.<thread>: that one thread's turn-start exits with the code in it.
              [ -r "$P/start_rc.$th" ] && exit "$(cat "$P/start_rc.$th")"
              [ -n "${RPC_START_FAIL:-}" ] && exit 1
              [ -n "${RPC_START_UNCERTAIN:-}" ] && exit 6
              if [ -n "${RPC_START_BAD_ID:-}" ]; then echo "turn id/with spaces"; exit 0; fi
              echo "turn-$th" ;;
  thread-turns) # RPC_TURNS_FAIL: the thread's turns cannot be listed.
                [ -n "${RPC_TURNS_FAIL:-}" ] && exit 1
                echo '{"turns":[],"thread_compactions":0}' ;;
  turn-wait) # $P/unfound.<thread>: the next --new-since wait on it finds nothing yet (exit 3).
             if [ -n "$resolved" ] && [ -e "$P/unfound.$th" ]; then rm -f "$P/unfound.$th"; exit 3; fi
             [ -n "$resolved" ] && echo turn-recovered > "$resolved"
             # Per turn: $P/answer.<turn> is its answer, $P/rc.<turn> its exit code for one wait,
             # $P/compacted.<turn> its compaction flag; otherwise RPC_WAIT_OUT, RPC_WAIT_RC and
             # RPC_COMPACTED. The report names RPC_REPORT_TURN instead, when set (a stale one).
             t="${turn:-turn-recovered}"
             o="${RPC_WAIT_OUT:-}"; [ -r "$P/answer.$t" ] && o="$(cat "$P/answer.$t")"
             r="${RPC_WAIT_RC:-0}"; if [ -r "$P/rc.$t" ]; then r="$(cat "$P/rc.$t")"; rm -f "$P/rc.$t"; fi
             if [ -n "$report" ] && { [ "$r" = 0 ] || [ "$r" = 4 ]; }; then
               c="${RPC_COMPACTED:-false}"; [ -r "$P/compacted.$t" ] && c="$(cat "$P/compacted.$t")"
               printf '{"turn":"%s","compacted":%s}\n' "${RPC_REPORT_TURN:-$t}" "$c" > "$report"
             fi
             # $P/hold.<turn>: the first wait on that turn claims it (it becomes holding.<turn>),
             # says so in waiting.<turn>, and answers only once holding.<turn> is removed (60 s
             # at most), with its report already written.
             if mv "$P/hold.$t" "$P/holding.$t" 2>/dev/null; then
               : > "$P/waiting.$t"
               k=0; while [ -e "$P/holding.$t" ] && [ "$k" -lt 600 ]; do sleep 0.1; k=$((k + 1)); done
             fi
             printf '%s\n' "$o"; exit "$r" ;;
esac
exit 0
R
chmod +x "$STUB"/*
export PATH="$STUB:$PATH"
export PINNED_PATH="$PATH"

packets() { # packets <switch>... : packets.conf with exactly these switches on
  local s; : > "$XDG_CONFIG_HOME/xreview/packets.conf"
  for s in framing fit delta omit_plans; do
    case " $* " in *" $s "*) echo "$s=on" ;; *) echo "$s=off" ;; esac >> "$XDG_CONFIG_HOME/xreview/packets.conf"
  done
}

fresh() { # a pane showing U0, idle, its TUI not connected to the daemon; clean log and state
  unset ENSURE_RC CHECK_RC RPC_START_FAIL RPC_START_UNCERTAIN RPC_START_BAD_ID \
        RPC_START_THREAD_FAIL NO_TITLE STUCK_TUI AGENT_EXIT_DELAY PANE_RUN_FAIL \
        AGENT_READ_FAIL_ONCE EXTRA_PANES PANE_CWD XREVIEW_PANE XREVIEW_THREAD RPC_WAIT_OUT \
        RPC_WAIT_RC RPC_THREAD_RUNNING RPC_THREAD_RUNNING_FOR RPC_HEALTH_FAIL \
        RELIVE_DURING_TURN RPC_SWITCH_BRANCH_TO RPC_SWITCH_BRANCH_EARLY \
        KEY_DELAY DISPATCH_ID XREVIEW_LOCK_WAIT RPC_RUNNING_AFTER_START \
        PROCINFO_FAIL PRESESSION GONE_AFTER_KEYS GONE_AFTER_RUN LSOF_FAIL READ_FAIL \
        RPC_STATUS_FAIL_FOR RPC_STATUS_NOBOOL_FOR CODEX_CHILD XREVIEW_RUNG_WAIT GET_FAIL PROCINFO_BAD RPC_RESOLVE_RC PROCINFO_FG \
        SNAP_LEDGER XREVIEW_LEDGER_LOCK_WAIT RPC_TURNS_FAIL RPC_COMPACTED RPC_REPORT_TURN LOCK_PROBE ENSURE_MARK
  export NEW_UUID="$U1"
  packets
  printf codex > "$P/agent"; printf '%s | t | d' "$(trunc "$U0")" > "$P/title"; echo idle > "$P/status"
  echo 0 > "$P/ctrlc"
  rm -f "$P/packet" "$P/reset_calls" "$P/reset_pending" "$P/newtitle" \
        "$P/exit_delay_active" "$P/exit_delay_calls"
  rm -f "$P/connected" "$P/argv" "$P/screen" "$P/gone" "$P/procinfo_fail_once"
  rm -f "$P"/running.* "$P/ledger-at-start"
  rm -f "$P/uuids" "$P"/answer.* "$P"/rc.* "$P"/compacted.* "$P"/start_rc.* "$P"/unfound.* \
        "$P"/hold.* "$P"/holding.* "$P"/waiting.* "$P/ensured"
  mkdir -p "$CODEX_HOME/app-server-daemon"; printf '{"pid":999}\n' > "$CODEX_HOME/app-server-daemon/daemon.pid"
  bash "$XREVIEW" round --reset >/dev/null 2>&1
  rm -rf "$STATE/superseded" "$STATE/pin" "$STATE/turns" "$STATE/missed"
  : > "$CALLS"
}
called() { grep -c -- "$1" "$CALLS" 2>/dev/null || true; }
resumed() { called "herdr pane run w1:p2 $PANE_CMD -C .* resume $1"; }   # resumed <thread>: count
first() { grep -n -- "$1" "$CALLS" | head -1 | cut -d: -f1; }
untouched() { # nothing reached the pane or the reviewer
  [ "$(called 'herdr pane send-keys')$(called 'herdr pane run')$(called 'xreview-rpc turn-start')" = 000 ] && echo yes || echo no
}
none_after() { # none_after <marker> <target>: <target> never appears in $CALLS on or after
  # the first line matching <marker> (C1: nothing may send-keys once the turn exists).
  awk -v m="$1" -v t="$2" '$0 ~ m {f=1} f && $0 ~ t {c++} END{print c+0}' "$CALLS"
}

echo "A. rounds are not capped by default; XREVIEW_MAX_ROUNDS is an opt-in bound"
fresh
capped() { bash "$XREVIEW" dispatch --checkpoint plan b.md 2>&1 | grep -c 'exceeds the cap'; }
is "round counter starts at zero" "$(bash "$XREVIEW" round)" 0
before="$(called 'xreview-rpc turn-start')"
for _ in $(seq 11); do capped >/dev/null; done
is "eleven rounds are dispatched with no cap set" "$(bash "$XREVIEW" round)" 11
is "and each of the eleven started a turn" "$(called 'xreview-rpc turn-start')" "$((before + 11))"
starts="$(called 'xreview-rpc turn-start')"
out="$(bash "$XREVIEW" dispatch --checkpoint plan b.md 2>&1)"
is "the twelfth round is not refused"       "$(printf '%s' "$out" | grep -c 'exceeds the cap')" 0
is "and the twelfth round produces a nonce" "$(printf '%s' "$out" | grep -c '^xr-')" 1
is "and starts a turn"                      "$(called 'xreview-rpc turn-start')" "$((starts + 1))"
out="$(XREVIEW_MAX_ROUNDS= bash "$XREVIEW" dispatch --checkpoint plan b.md 2>&1)"
is "an empty XREVIEW_MAX_ROUNDS is no cap either" "$(printf '%s' "$out" | grep -c '^xr-')" 1
starts="$(called 'xreview-rpc turn-start')"
out="$(XREVIEW_MAX_ROUNDS=13 bash "$XREVIEW" dispatch --checkpoint plan b.md 2>&1)"
is "XREVIEW_MAX_ROUNDS=13 refuses the fourteenth round" "$(printf '%s' "$out" | grep -c 'exceeds the cap')" 1
is "and starts no turn"               "$(called 'xreview-rpc turn-start')" "$starts"
is "a refused round still increments, so retrying stays refused" "$(bash "$XREVIEW" round)" 14
bash "$XREVIEW" round --reset >/dev/null
is "reset returns the counter to zero" "$(bash "$XREVIEW" round)" 0
# round --reset drops the checkpoint thread too, so this dispatch calls thread-start again -
# give it a fresh id so later assertions in this block are unambiguous.
export NEW_UUID="$U2"
out="$(XREVIEW_MAX_ROUNDS=1 bash "$XREVIEW" dispatch --checkpoint plan b.md 2>&1)"
is "dispatch is permitted again after reset" "$(printf '%s' "$out" | grep -c '^xr-')" 1
is "XREVIEW_MAX_ROUNDS lowers the cap" "$(XREVIEW_MAX_ROUNDS=1 bash "$XREVIEW" dispatch --checkpoint plan b.md 2>&1 | grep -c 'exceeds the cap')" 1
export NEW_UUID="$U1"

echo "A2. a malformed XREVIEW_MAX_ROUNDS is refused before the pane is touched"
for v in abc 5x ' 5' -1; do
  fresh
  out="$(XREVIEW_MAX_ROUNDS="$v" bash "$XREVIEW" dispatch --checkpoint plan b.md 2>&1)"; rc=$?
  is "A2 XREVIEW_MAX_ROUNDS='$v' is refused, naming the value" \
     "$rc/$(printf '%s' "$out" | grep -c -F "not '$v'")" "1/1"
  is "A2 and with '$v' nothing reaches the pane or the reviewer" "$(untouched)" yes
done
fresh
out="$(XREVIEW_MAX_ROUNDS=0 bash "$XREVIEW" dispatch --checkpoint plan b.md 2>&1)"
is "A2 a whole number (0) is accepted as a bound" "$(printf '%s' "$out" | grep -c 'exceeds the cap')" 1

echo "B. inline diffs"
# A dispatch that names a path makes the reviewer go and read it; carrying the diff inline
# lets it answer from what it was handed (measured 2026-09-01: ~16 steps per review).
printf 'change\n' > tracked.txt && git add tracked.txt && git commit -q -m "a change to review"
fresh
bash "$XREVIEW" dispatch --checkpoint plan --diff HEAD~1..HEAD b.md >/dev/null 2>&1
is "the diff travels in the packet"          "$(grep -q 'tracked.txt' "$P/packet" && echo yes || echo no)" yes
is "with the caller's body"                  "$(grep -c '^body$' "$P/packet")" 1
is "and the reviewer instructions"           "$(grep -c 'independent reviewer' "$P/packet")" 1
is "wrapped as an authorized request"        "$(head -1 "$P/packet")" "<cross-review-request>"
is "with no correlation line any more"       "$(grep -c 'correlation' "$P/packet")" 0
fresh
out="$(XREVIEW_MAX_DIFF_BYTES=10 bash "$XREVIEW" dispatch --checkpoint plan --diff HEAD~1..HEAD b.md 2>&1)"
is "an oversized diff is refused, never truncated" "$(printf '%s' "$out" | grep -c 'too large')" 1
is "before anything is touched" "$(untouched)" yes
fresh
out="$(bash "$XREVIEW" dispatch --checkpoint plan --diff no-such-ref..HEAD b.md 2>&1)"
is "an unresolvable range is refused" "$(printf '%s' "$out" | grep -c 'cannot diff')" 1
fresh
out="$(bash "$XREVIEW" dispatch --checkpoint plan --diff HEAD..HEAD b.md 2>&1)"
is "an empty range is refused" "$(printf '%s' "$out" | grep -c 'nothing to review')" 1
out="$(bash "$XREVIEW" dispatch --checkpoint plan --expect x b.md 2>&1)"; rc=$?
is "--expect is rejected, not absorbed" "$rc" 1
is "and mints no nonce" "$(printf '%s' "$out" | grep -c '^xr-')" 0

echo "C. preconditions refuse before anything is touched"
fresh; out="$(ENSURE_RC=1 bash "$XREVIEW" dispatch --checkpoint plan b.md 2>&1)"; rc=$?
is "C1 a daemon that will not start refuses" "$rc" 1
is "C1 untouched" "$(untouched)" yes
fresh; out="$(CHECK_RC=1 bash "$XREVIEW" dispatch --checkpoint plan b.md 2>&1)"; rc=$?
is "C2 a contaminated daemon refuses" "$rc" 1
is "C2 and says why" "$(printf '%s' "$out" | grep -c 'refusing to dispatch while the daemon')" 1
is "C2 untouched" "$(untouched)" yes
fresh; out="$(RPC_HEALTH_FAIL=1 bash "$XREVIEW" dispatch --checkpoint plan b.md 2>&1)"; rc=$?
is "C13 an unreachable daemon via xreview-rpc refuses" "$rc" 1
is "C13 and says so" "$(printf '%s' "$out" | grep -c 'cannot reach the Codex daemon through xreview-rpc')" 1
is "C13 untouched" "$(untouched)" yes
is "C13 no round consumed" "$(bash "$XREVIEW" round)" 0
fresh; : > "$P/agent"; out="$(bash "$XREVIEW" dispatch --checkpoint plan b.md 2>&1)"; rc=$?
is "C3 no Codex pane refuses" "$(printf '%s' "$out" | grep -c 'no Codex pane')" 1
is "C3 untouched" "$(untouched)" yes
fresh
export EXTRA_PANES=",{\"agent\":\"codex\",\"agent_status\":\"idle\",\"cwd\":\"$CWD\",\"pane_id\":\"w9:p2\",\"terminal_title\":\"x\"}"
out="$(bash "$XREVIEW" dispatch --checkpoint plan b.md 2>&1)"
is "C4 several Codex panes refuse" "$(printf '%s' "$out" | grep -c 'several Codex panes')" 1
is "C4 naming both" "$(printf '%s' "$out" | grep -c 'w1:p2 w9:p2')" 1
is "C4 untouched" "$(untouched)" yes
out="$(XREVIEW_PANE=w1:p2 bash "$XREVIEW" dispatch --checkpoint plan b.md 2>&1)"
is "C5 XREVIEW_PANE picks one" "$(printf '%s' "$out" | grep -c '^xr-')" 1
fresh
export EXTRA_PANES=",{\"agent\":\"claude\",\"agent_status\":\"idle\",\"cwd\":\"$CWD\",\"pane_id\":\"w1:p1\",\"terminal_title\":\"x\"}"
out="$(XREVIEW_PANE=w1:p1 bash "$XREVIEW" dispatch --checkpoint plan b.md 2>&1)"; rc=$?
is "C9 XREVIEW_PANE naming a non-Codex pane refuses" "$rc" 1
is "C9 and names the pane" "$(printf '%s' "$out" | grep -c 'XREVIEW_PANE=w1:p1 is not a Codex pane')" 1
is "C9 untouched" "$(untouched)" yes
fresh; echo working > "$P/status"; out="$(bash "$XREVIEW" dispatch --checkpoint plan b.md 2>&1)"
is "C6 a pane mid-turn refuses" "$(printf '%s' "$out" | grep -c 'mid-turn')" 1
is "C6 untouched" "$(untouched)" yes
fresh; echo blocked > "$P/status"; out="$(bash "$XREVIEW" dispatch --checkpoint plan b.md 2>&1)"
is "C10 a blocked pane refuses" "$(printf '%s' "$out" | grep -c 'mid-turn')" 1
is "C10 untouched" "$(untouched)" yes
fresh; out="$(RPC_THREAD_RUNNING=1 bash "$XREVIEW" dispatch --checkpoint plan b.md 2>&1)"
is "C11 a running thread behind an idle pane refuses" "$(printf '%s' "$out" | grep -c 'mid-turn')" 1
is "C11 untouched" "$(untouched)" yes
fresh
U5=55555555-5555-4555-8555-555555555555   # never on the resolver stub's known-id list
printf '%s | t | d' "$(trunc "$U5")" > "$P/title"
out="$(bash "$XREVIEW" dispatch --checkpoint plan b.md 2>&1)"
is "C12 the running-thread gate does not block when the title prefix cannot be resolved" \
   "$(printf '%s' "$out" | grep -c '^xr-')" 1
fresh
out="$(XREVIEW_PANE='.*' bash "$XREVIEW" dispatch --checkpoint plan b.md 2>&1)"; rc=$?
is "C14 XREVIEW_PANE='.*' is refused, not matched as a regex" "$rc" 1
is "C14 and names the pane, not a pattern match" "$(printf '%s' "$out" | grep -c 'is not a Codex pane')" 1
is "C14 untouched" "$(untouched)" yes
fresh; mkdir .codex; out="$(bash "$XREVIEW" dispatch --checkpoint plan b.md 2>&1)"; rmdir .codex
is "C7 a project .codex refuses" "$(printf '%s' "$out" | grep -c 'refusing to dispatch')" 1
is "C7 untouched" "$(untouched)" yes
fresh; out="$(XREVIEW_SCHEMA="$ROOT/none.json" bash "$XREVIEW" dispatch --checkpoint plan b.md 2>&1)"
is "C8 a missing schema refuses" "$(printf '%s' "$out" | grep -c 'missing findings schema')" 1

echo "D. the pane is freed before the turn, then best-effort resumed onto it (spec 7.3)"
fresh
nonce="$(bash "$XREVIEW" dispatch --checkpoint plan b.md 2>/dev/null)"
is "D1 a nonce is printed" "$(printf '%s' "$nonce" | grep -c '^xr-')" 1
is "D1 the pane's session is ended" "$(called 'herdr pane send-keys w1:p2 ctrl+c')" 2
is "D1 the pane is resumed onto the new thread" "$(resumed "$U1")" 1
is "D1 herdr is told the pane's thread" \
   "$(called "herdr pane report-agent-session w1:p2 --source herdr:codex --agent codex --agent-session-id $U1")" 1
is "D1 the checkpoint thread is recorded" "$(cat "$STATE/review-thread")" "$U1"
is "D1 the nonce maps to thread and turn" "$(cat "$STATE/turns/$nonce")" "$U1 turn-$U1 plan $BR"
# C1: nothing may ever send-keys to the pane once the turn exists.
is "D1 no send-keys appears after turn-start" "$(none_after 'xreview-rpc turn-start' 'herdr pane send-keys')" 0

echo "D3. a pane that moved off the checkpoint thread is resumed back onto it"
printf '%s | t | d' "$(trunc "$U0")" > "$P/title"; : > "$CALLS"
bash "$XREVIEW" dispatch --checkpoint plan b.md >/dev/null 2>&1
is "D3 it is resumed back onto the checkpoint thread" "$(resumed "$U1")" 1

echo "D3f. a failed process-info read during the ladder keeps waiting, not ends it"
# AGENT_EXIT_DELAY makes the pane genuinely keep reading as Codex for a few more reads after
# send-keys, as a slow-exiting TUI would; AGENT_READ_FAIL_ONCE fails the very first
# process-info read of that phase outright. A failed read counted as "freed" would end the
# ladder on that first (failed) read - long before the delay actually elapses.
fresh
out="$(AGENT_EXIT_DELAY=3 AGENT_READ_FAIL_ONCE=1 XREVIEW_POLL_SECS=0.05 XREVIEW_PANE_WAIT=5 \
        bash "$XREVIEW" dispatch --checkpoint plan b.md 2>&1)"; rc=$?
is "D3f it still succeeds" "$(printf '%s' "$out" | grep -c '^xr-')" 1
# Between the second ctrl+c and `pane run`, the ladder's poll makes one process-info read per
# iteration: the first (failed) one - after which pane_gone's own `pane get`, checking the
# pane did not close, uses up the first of the 3 delayed reads - then 2 more that still read
# Codex, then the one that finally reads the shell and ends the ladder - 4 - plus
# pane_resume's own fix round 2/D check (the shell in the foreground, right before it calls
# `pane run`) - 5 in total. A failed read misread as "freed" would instead end the ladder
# after just that first (failed) read, and pane_resume's check, still seeing Codex, would
# then warn and never call `pane run` - 2 (1 plus pane_resume's own check), not 5.
is "D3f the ladder actually polled through the delay, not stopped on the failed read" \
   "$(awk '/pane send-keys/{n++} n>=2{print} /pane run/{exit}' "$CALLS" | grep -c 'pane process-info')" 5

echo "D8. a refused turn fails the dispatch - the pane was already freed, then relaunched (fix round 2/C)"
# The pane is freed BEFORE turn-start now (C1), so a turn-start failure still costs two
# ctrl+c on the pane - unavoidable, since freeing has to happen before the turn can start at
# all. Fix round 2/C: since pane_free already quit the TUI, the EXIT guard now relaunches
# Codex there before dying, so the pane is never left sitting at a bare shell.
fresh; out="$(RPC_START_FAIL=1 bash "$XREVIEW" dispatch --checkpoint plan b.md 2>&1)"; rc=$?
is "D8 a refused turn fails the dispatch" "$rc" 1
is "D8 and records no nonce" "$(ls "$STATE/turns" 2>/dev/null | grep -c .)" 0
is "D8 the pane was freed (two ctrl+c)" "$(called 'herdr pane send-keys')" 2
is "D8 and relaunched as a fresh session" "$(called "^herdr pane run w1:p2 $PANE_CMD\$")" 1

echo "RC. a refusal after pane_free relaunches Codex in the pane (fix round 2/C)"
fresh; out="$(RPC_START_FAIL=1 bash "$XREVIEW" dispatch --checkpoint plan b.md 2>&1)"; rc=$?
is "RC1 it still refuses" "$rc" 1
relaunch="^herdr pane run w1:p2 $PANE_CMD\$"
is "RC1 the relaunch happens after both ctrl+c" \
   "$([ "$(first 'herdr pane send-keys')" -lt "$(first "$relaunch")" ] && echo yes || echo no)" yes
is "RC1 and exactly once" "$(called "$relaunch")" 1
fresh
bash "$XREVIEW" dispatch --checkpoint plan b.md >/dev/null 2>&1
is "RC2 a successful dispatch never runs the relaunch" "$(called "$relaunch")" 0
fresh
out="$(XREVIEW_MAX_ROUNDS=0 bash "$XREVIEW" dispatch --checkpoint plan b.md 2>&1)"; rc=$?
is "RC3 a refusal before pane_free (the round cap) refuses" "$(printf '%s' "$out" | grep -c 'exceeds the cap')" 1
is "RC3 and never runs the relaunch" "$(called "$relaunch")" 0
is "RC3 and never touches the pane at all" "$(untouched)" yes
# An errexit exit (not die): a mkdir fails after pane_free. The guard must still know the pane.
# The stub fails only the mkdir of the turns directory, which dispatch makes inside that window.
cat > "$STUB/mkdir" <<'M'
#!/bin/sh
if [ -n "${MKDIR_FAIL_SUFFIX:-}" ]; then
  for a in "$@"; do case "$a" in *"$MKDIR_FAIL_SUFFIX") exit 1 ;; esac; done
fi
exec /bin/mkdir "$@"
M
chmod +x "$STUB/mkdir"
fresh; out="$(MKDIR_FAIL_SUFFIX=/turns bash "$XREVIEW" dispatch --checkpoint plan b.md 2>&1)"; rc=$?
is "RC4 a failed mkdir after pane_free refuses" "$rc" 1
is "RC4 and no turn was started" "$(called 'xreview-rpc turn-start')" 0
is "RC4 and the pane is still relaunched" "$(called "$relaunch")" 1

echo "D10. an unanswered turn-start still hands back a nonce; collect recovers it"
fresh
nonce="$(RPC_START_UNCERTAIN=1 bash "$XREVIEW" dispatch --checkpoint plan --diff HEAD~1..HEAD b.md 2>"$ROOT/err")"; rc=$?
is "D10 an unanswered turn/start still hands back a nonce" "$rc/$(printf '%s' "$nonce" | grep -c '^xr-')" "0/1"
is "D10 with a do-not-re-dispatch warning" "$(grep -c 'do NOT re-dispatch' "$ROOT/err")" 1
is "D10 the record marks the turn unknown" "$(cat "$STATE/turns/$nonce")" "$U1 ? plan $BR"
RPC_WAIT_OUT='{"verdict":"approve","findings":[]}' bash "$XREVIEW" collect "$nonce" >/dev/null 2>&1
is "D10 collect looks for what is new on the thread" \
   "$(called "turn-wait --thread $U1 --new-since $STATE/turns/$nonce.known --resolved")" 1
is "D10 the recovered turn replaces the unknown in the record" "$(cat "$STATE/turns/$nonce")" "$U1 turn-recovered plan $BR"
is "D10 and the receipt names it" "$(tail -1 "$MAIN_LEDGER" | jq -r .turn)" turn-recovered
: > "$CALLS"; bash "$XREVIEW" collect "$nonce" >/dev/null 2>&1
is "D10 a later collect waits on that turn by id" "$(called "turn-wait --thread $U1 --turn turn-recovered")" 1

echo "D11. a TUI without a daemon connection is re-pointed even though its title matches"
# A TUI left over from before a daemon restart keeps its title but holds no connection to the
# new daemon (G3): the title alone never takes the fast path, the observed connection does.
fresh
bash "$XREVIEW" dispatch --checkpoint plan b.md >/dev/null 2>&1   # the resumed TUI shows U1, connected
rm -f "$P/connected"; : > "$CALLS"
bash "$XREVIEW" dispatch --checkpoint plan b.md >/dev/null 2>&1
is "D11 the pane is re-pointed despite the title still matching" "$(resumed "$U1")" 1

echo "D12. a pin whose title already matches takes the fast path at once on a connected TUI"
fresh
bash "$XREVIEW" init "$U0" >/dev/null    # the pin the pane's title already shows
: > "$P/connected"; : > "$CALLS"
bash "$XREVIEW" dispatch --checkpoint plan b.md >/dev/null 2>&1
is "D12 a matching, connected pin sends no keys" "$(called 'herdr pane send-keys')" 0
is "D12 and starts no new pane session" "$(called 'herdr pane run')" 0
fresh
bash "$XREVIEW" init "$U0" >/dev/null    # the same pin, on a TUI with no daemon connection
: > "$CALLS"
bash "$XREVIEW" dispatch --checkpoint plan b.md >/dev/null 2>&1
is "D12 without a daemon connection it is resumed exactly once" "$(resumed "$U0")" 1

echo "D16. turn-start returning 0 with a malformed id still hands back a nonce"
fresh
nonce="$(RPC_START_BAD_ID=1 bash "$XREVIEW" dispatch --checkpoint plan b.md 2>"$ROOT/err")"; rc=$?
is "D16 turn-start returning 0 with a malformed id still hands back a nonce" \
   "$rc/$(printf '%s' "$nonce" | grep -c '^xr-')" "0/1"
is "D16 with a do-not-re-dispatch warning, exactly like exit 6" \
   "$(grep -c 'do NOT re-dispatch' "$ROOT/err")" 1
is "D16 the record marks the turn unknown" "$(cat "$STATE/turns/$nonce")" "$U1 ? plan $BR"

echo "T1. a new checkpoint thread comes from xreview-rpc thread-start"
fresh
nonce="$(bash "$XREVIEW" dispatch --checkpoint plan b.md 2>/dev/null)"
is "T1 thread-start is called with the repo root" "$(called "xreview-rpc thread-start --cwd $CWD")" 1
is "T1 the new thread is recorded as the checkpoint thread" "$(cat "$STATE/review-thread")" "$U1"
is "T1 the turn starts on it" "$(called "xreview-rpc turn-start --thread $U1")" 1

echo "T2. no keystroke ever reaches the pane once the turn exists (C1)"
fresh
bash "$XREVIEW" dispatch --checkpoint plan b.md >/dev/null 2>&1
is "T2 the pane is freed (send-keys) before turn-start, not after" \
   "$([ "$(first 'herdr pane send-keys')" -lt "$(first 'xreview-rpc turn-start')" ] && echo yes || echo no)" yes
is "T2 and no send-keys ever appears after turn-start" \
   "$(none_after 'xreview-rpc turn-start' 'herdr pane send-keys')" 0
# Confirmed with a scratch mutant (the ctrl+c moved to AFTER turn-start, mirroring the old
# pane-first-then-ctrl+c bug this fix round closes): both assertions above go red under that
# mutant, and D1's own send-keys-after-turn-start assertion does too - see task-16-report.md.

echo "T3. a pane that never shows the thread still succeeds: the review just is not shown"
fresh
out="$(NO_TITLE=1 XREVIEW_PANE_WAIT=0.15 bash "$XREVIEW" dispatch --checkpoint plan b.md 2>&1)"; rc=$?
nonce="$(printf '%s' "$out" | grep '^xr-')"
is "T3 dispatch still exits 0" "$rc" 0
is "T3 and prints the nonce" "$(printf '%s' "$nonce" | grep -c '^xr-')" 1
is "T3 the turn is recorded" "$(cat "$STATE/turns/$nonce" 2>/dev/null)" "$U1 turn-$U1 plan $BR"
is "T3 and it warns the review is not shown" \
   "$(printf '%s' "$out" | grep -c 'running but not shown in pane w1:p2')" 1
is "T3 the round was still consumed" "$(bash "$XREVIEW" round)" 1

echo "D. pane_resume must not type into a live TUI (fix round 2/D)"
fresh
out="$(RELIVE_DURING_TURN=1 bash "$XREVIEW" dispatch --checkpoint plan b.md 2>&1)"; rc=$?
nonce="$(printf '%s' "$out" | grep '^xr-')"
is "D dispatch still exits 0" "$rc" 0
is "D and prints the nonce" "$(printf '%s' "$nonce" | grep -c '^xr-')" 1
is "D the turn is recorded" "$(cat "$STATE/turns/$nonce" 2>/dev/null)" "$U1 turn-$U1 plan $BR"
is "D it warns instead of typing into the live TUI" \
   "$(printf '%s' "$out" | grep -c 'running but not shown in pane w1:p2')" 1
is "D no pane run ever happens - nothing is typed into it" "$(called 'herdr pane run')" 0

echo "T3b. a session that will not exit even after the ladder REFUSES, before any turn exists (C1)"
# The old behaviour (warn, still exit 0) belonged to the OLD pane-first-then-turn design,
# where freeing the pane happened with no turn yet to protect. Now pane_free runs before
# turn-start, so it can safely die: nothing has started. The ladder is bounded: at most
# three ctrl+c pairs, all inside XREVIEW_PANE_WAIT (spec 2026-10-01 §4.4).
fresh
out="$(STUCK_TUI=1 XREVIEW_RUNG_WAIT=0.1 XREVIEW_PANE_WAIT=1 bash "$XREVIEW" dispatch --checkpoint plan b.md 2>&1)"; rc=$?
is "T3b it refuses" "$rc" 1
is "T3b with the exact line" \
   "$(printf '%s' "$out" | grep -cx 'xreview: the Codex pane w1:p2 did not exit its session within 1s; no review was started')" 1
is "T3b after at most three ctrl+c pairs" \
   "$(called 'herdr pane send-keys' | awk '{print ($1 >= 2 && $1 <= 6) ? "yes" : "no ("$1")"}')" yes
is "T3b no turn was ever started" "$(called 'xreview-rpc turn-start')" 0
is "T3b and no nonce is printed" "$(printf '%s' "$out" | grep -c '^xr-')" 0

echo "T4a. a pane that closes (pane_not_found) WHILE BEING FREED refuses; no turn ever starts"
fresh
out="$(GONE_AFTER_KEYS=1 bash "$XREVIEW" dispatch --checkpoint plan b.md 2>&1)"; rc=$?
is "T4a it refuses" "$rc" 1
is "T4a and says the pane closed while being freed" \
   "$(printf '%s' "$out" | grep -c 'closed while being freed')" 1
is "T4a no turn was ever started" "$(called 'xreview-rpc turn-start')" 0
is "T4a and no nonce is printed" "$(printf '%s' "$out" | grep -c '^xr-')" 0

echo "T4b. a pane that closes (pane_not_found) AFTER the turn starts still warns, quickly, exit 0"
# The turn already exists by the time this fires (pane_free itself succeeded, and the pane
# closes as it is resumed), so this is exactly the spec's step-5 failure mode, unchanged from
# before this fix round.
fresh
start="$EPOCHREALTIME"
out="$(GONE_AFTER_RUN=1 bash "$XREVIEW" dispatch --checkpoint plan b.md 2>&1)"; rc=$?
took="$(awk -v s="$start" -v e="$EPOCHREALTIME" 'BEGIN{printf "%.3f", e-s}')"
nonce="$(printf '%s' "$out" | grep '^xr-')"
is "T4b dispatch still exits 0" "$rc" 0
is "T4b and prints the nonce" "$(printf '%s' "$nonce" | grep -c '^xr-')" 1
is "T4b the turn is recorded" "$(cat "$STATE/turns/$nonce" 2>/dev/null)" "$U1 turn-$U1 plan $BR"
is "T4b and it warns the review is not shown" \
   "$(printf '%s' "$out" | grep -c 'running but not shown in pane w1:p2')" 1
is "T4b it returns quickly, not waiting out XREVIEW_PANE_WAIT" \
   "$(awk -v t="$took" -v w="${XREVIEW_PANE_WAIT:-20}" 'BEGIN{print (t < w) ? "yes" : "no ("t"s)"}')" yes

echo "T5. thread-start failing refuses before any turn or pane keystroke"
fresh
out="$(RPC_START_THREAD_FAIL=1 bash "$XREVIEW" dispatch --checkpoint plan b.md 2>&1)"; rc=$?
is "T5 it refuses" "$rc" 1
is "T5 and says so" "$(printf '%s' "$out" | grep -c 'could not start a new review thread')" 1
is "T5 no turn was started" "$(called 'xreview-rpc turn-start')" 0
is "T5 and the pane was never touched" "$(untouched)" yes
is "T5 no checkpoint thread was recorded" "$([ -e "$STATE/review-thread" ] && echo yes || echo no)" no

echo "T6. the superseded thread is archived only once the pane step succeeds"
fresh
bash "$XREVIEW" dispatch --checkpoint plan b.md >/dev/null 2>&1        # establishes checkpoint thread U1
bash "$XREVIEW" round --reset >/dev/null 2>&1         # supersedes U1; drops the cached thread
export NEW_UUID="$U2"
: > "$CALLS"
bash "$XREVIEW" dispatch --checkpoint plan b.md >/dev/null 2>&1         # a normal dispatch: the pane step succeeds
is "T6 the superseded thread is archived once the pane step succeeds" \
   "$(called "xreview-rpc thread-archive --thread $U1")" 1
export NEW_UUID="$U1"

fresh
bash "$XREVIEW" dispatch --checkpoint plan b.md >/dev/null 2>&1        # establishes checkpoint thread U1
bash "$XREVIEW" round --reset >/dev/null 2>&1
export NEW_UUID="$U2"
: > "$CALLS"
NO_TITLE=1 XREVIEW_PANE_WAIT=0.15 bash "$XREVIEW" dispatch --checkpoint plan b.md >/dev/null 2>&1   # the pane step fails
is "T6 and NOT archived when the pane step fails" "$(called "xreview-rpc thread-archive --thread $U1")" 0
export NEW_UUID="$U1"

echo "M3. superseded threads accumulate across resets with a failed pane step in between"
fresh
bash "$XREVIEW" dispatch --checkpoint plan b.md >/dev/null 2>&1          # checkpoint thread U1
bash "$XREVIEW" round --reset >/dev/null 2>&1           # superseded: [U1]
export NEW_UUID="$U2"
NO_TITLE=1 XREVIEW_PANE_WAIT=0.15 bash "$XREVIEW" dispatch --checkpoint plan b.md >/dev/null 2>&1   # checkpoint U2; pane step FAILS
is "M3 a failed pane step leaves the first superseded thread listed, un-archived" \
   "$(cat "$STATE/superseded" 2>/dev/null)" "$U1"
bash "$XREVIEW" round --reset >/dev/null 2>&1           # a SECOND reset: superseded: [U1, U2]
is "M3 a second reset APPENDS to the list, not overwrites it" \
   "$(cat "$STATE/superseded" 2>/dev/null | tr '\n' ' ')" "$U1 $U2 "
# The failed pane step (NO_TITLE) left the pane genuinely derelict - `pane run` never
# actually started Codex there, so its agent is not "codex" any more, exactly as a real
# abandoned shell would read. Simulate the operator noticing and restarting it by hand,
# same as they would need to in reality before another dispatch can find the pane at all.
printf codex > "$P/agent"
export NEW_UUID="$U0"   # distinct from both U1 and U2; the pane's title still shows U1's form
: > "$CALLS"
bash "$XREVIEW" dispatch --checkpoint plan b.md >/dev/null 2>&1           # a normal dispatch: the pane step succeeds
is "M3 a later successful dispatch archives the first superseded thread" \
   "$(called "xreview-rpc thread-archive --thread $U1")" 1
is "M3 and the second one too" "$(called "xreview-rpc thread-archive --thread $U2")" 1
is "M3 and clears the superseded list" "$([ -e "$STATE/superseded" ] && echo yes || echo no)" no
export NEW_UUID="$U1"

echo "M4. the checkpoint thread itself already running a turn refuses, pane untouched"
fresh
bash "$XREVIEW" init "$U2" >/dev/null   # pin a thread distinct from the pane's own title (U0)
out="$(RPC_THREAD_RUNNING_FOR=$U2 bash "$XREVIEW" dispatch --checkpoint plan b.md 2>&1)"; rc=$?
is "M4 it refuses" "$rc" 1
is "M4 and says to collect it first" "$(printf '%s' "$out" | grep -c 'collect it first')" 1
is "M4 no turn was started" "$(called 'xreview-rpc turn-start')" 0
is "M4 and the pane was never touched" "$(untouched)" yes

echo "M6a. a refused turn-start leaves the round unconsumed"
fresh
before_round="$(bash "$XREVIEW" round)"
RPC_START_FAIL=1 bash "$XREVIEW" dispatch --checkpoint plan b.md >/dev/null 2>&1
is "M6a the round counter is unchanged" "$(bash "$XREVIEW" round)" "$before_round"

echo "M6b. a failing 'herdr pane run' after the turn starts warns and exits 0"
fresh
out="$(PANE_RUN_FAIL=1 bash "$XREVIEW" dispatch --checkpoint plan b.md 2>&1)"; rc=$?
nonce="$(printf '%s' "$out" | grep '^xr-')"
is "M6b dispatch still exits 0" "$rc" 0
is "M6b and prints the nonce" "$(printf '%s' "$nonce" | grep -c '^xr-')" 1
is "M6b and warns the review is not shown" \
   "$(printf '%s' "$out" | grep -c 'running but not shown in pane w1:p2')" 1

echo "M6c. a pin and XREVIEW_THREAD each skip thread-start"
fresh
bash "$XREVIEW" init "$U0" >/dev/null
: > "$CALLS"
bash "$XREVIEW" dispatch --checkpoint plan b.md >/dev/null 2>&1
is "M6c a pin skips thread-start" "$(called 'xreview-rpc thread-start')" 0
fresh
: > "$CALLS"
XREVIEW_THREAD="$U2" bash "$XREVIEW" dispatch --checkpoint plan b.md >/dev/null 2>&1
is "M6c XREVIEW_THREAD skips thread-start" "$(called 'xreview-rpc thread-start')" 0

echo "T7. the fast path sends no keys and starts no new pane session"
fresh
bash "$XREVIEW" dispatch --checkpoint plan b.md >/dev/null 2>&1   # the resumed TUI shows U1, connected
: > "$CALLS"
bash "$XREVIEW" dispatch --checkpoint plan b.md >/dev/null 2>&1
is "T7 no keys are sent on the fast path" "$(called 'herdr pane send-keys')" 0
is "T7 and no new pane session is started" "$(called 'herdr pane run')" 0
is "T7 the turn still starts on the cached thread" "$(called "xreview-rpc turn-start --thread $U1")" 1

echo "S. observation, guard, ladder and screen (spec 2026-10-01 §4.3-§4.6)"
fresh
bash "$XREVIEW" dispatch --checkpoint plan b.md >/dev/null 2>&1; : > "$CALLS"
bash "$XREVIEW" dispatch --checkpoint plan b.md >/dev/null 2>&1
is "S1 a matching, connected pane takes the fast path: no keys" "$(called 'herdr pane send-keys')" 0
is "S1 and no resume" "$(called 'herdr pane run')" 0
: > "$CALLS"; LSOF_FAIL=1 bash "$XREVIEW" dispatch --checkpoint plan b.md >/dev/null 2>&1
is "S2 an unreadable lsof is not observed: ladder, then resume" "$(resumed "$U1")" 1
printf 'codex -c model=x resume %s' "$U1" > "$P/argv"; rm -f "$P/connected"; : > "$CALLS"
bash "$XREVIEW" dispatch --checkpoint plan b.md >/dev/null 2>&1
is "S3 an embedded TUI (no daemon connection) is re-pointed" "$(resumed "$U1")" 1
fresh; PRESESSION=1 XREVIEW_RUNG_WAIT=0.3 XREVIEW_PANE_WAIT=5 bash "$XREVIEW" dispatch --checkpoint plan b.md > "$ROOT/o" 2>&1; rc=$?
is "S4 a pre-session screen is freed by the second pair" "$rc/$(grep -c '^xr-' "$ROOT/o")" "0/1"
is "S4 with four ctrl+c" "$(called 'herdr pane send-keys')" 4
is "S4 all before the turn" "$(none_after 'xreview-rpc turn-start' 'herdr pane send-keys')" 0
fresh; printf 'Update available! 0.160.0\n\033[31mpress enter\033[0m\n' > "$P/screen"
out="$(STUCK_TUI=1 XREVIEW_RUNG_WAIT=0.1 XREVIEW_PANE_WAIT=1 bash "$XREVIEW" dispatch --checkpoint plan b.md 2>&1)"; rc=$?
is "S5 a pane that never quits refuses" "$rc" 1
is "S5 with the exact line" "$(printf '%s' "$out" | grep -cx 'xreview: the Codex pane w1:p2 did not exit its session within 1s; no review was started')" 1
is "S5 then the screen, indented" "$(printf '%s' "$out" | grep -cx '  | Update available! 0.160.0')" 1
is "S5 with escapes stripped" "$(printf '%s' "$out" | grep -c "$(printf '\033')")" 0
is "S5 no turn" "$(called 'xreview-rpc turn-start')" 0
# S6: 30 rows of 97 characters, so the last 12 rows (1,176 bytes) are over the byte cap. The
# excerpt keeps the bottom: the last 1,000 bytes are rows 21-30 whole, after the tail of row 20.
x90="$(head -c 90 /dev/zero | tr '\0' x)"
fresh; for i in $(seq -w 1 30); do printf 'row %s %s\n' "$i" "$x90"; done > "$P/screen"
out="$(NO_TITLE=1 XREVIEW_PANE_WAIT=0.15 bash "$XREVIEW" dispatch --checkpoint plan b.md 2>&1)"
is "S6 a resume that does not confirm keeps the exact warning" \
   "$(printf '%s' "$out" | grep -cx 'xreview: the review is running but not shown in pane w1:p2')" 1
is "S6 the excerpt ends with the screen's final row, whole" "$(printf '%s' "$out" | grep '^  | ' | tail -1)" "  | row 30 $x90"
is "S6 and the byte cap cut the top of the last 12 rows, not the bottom" \
   "$(printf '%s' "$out" | grep -c '^  | row 19 ')/$(printf '%s' "$out" | grep -c '^  | row 21 ')" "0/1"
is "S6 the excerpt is at most 12 lines" \
   "$(printf '%s' "$out" | grep -c '^  | ' | awk '{print ($1 >= 1 && $1 <= 12) ? "yes" : "no ("$1")"}')" yes
is "S6 and at most 1,000 bytes of screen" "$(printf '%s' "$out" | grep '^  | ' | sed 's/^  | //' | tr -d '\n' | wc -c | tr -d ' ')" \
   "$(printf '%s' "$out" | grep '^  | ' | sed 's/^  | //' | tr -d '\n' | wc -c | awk '{print ($1 <= 1000) ? $1 : "over"}')"
is "S6 and the nonce is still printed, on a line of its own" "$(printf '%s' "$out" | grep -c '^xr-')" 1
is "S6 the excerpt's last line is complete (ends in a newline)" \
   "$(printf '%s' "$out" | grep '^  | ' | tail -1 | grep -c 'xr-')" 0
is "S6 and no key reaches the pane after the turn" "$(none_after 'xreview-rpc turn-start' 'herdr pane send-keys')" 0
# S6b: short rows, so the 12-line cap is the one that binds; trailing blank rows are dropped first.
fresh; { for i in $(seq -w 1 30); do printf 'line %s\n' "$i"; done; printf '\n   \n\n'; } > "$P/screen"
out="$(NO_TITLE=1 XREVIEW_PANE_WAIT=0.15 bash "$XREVIEW" dispatch --checkpoint plan b.md 2>&1)"
is "S6b a short screen shows exactly its last 12 rows" "$(printf '%s' "$out" | grep -c '^  | ')" 12
is "S6b from row 19 to the final row, trailing blank rows dropped" \
   "$(printf '%s' "$out" | grep '^  | ' | sed -n '1p;$p' | tr '\n' '/')" "  | line 19/  | line 30/"
# S6c: the byte cut lands inside a 3-byte character (`›`, E2 80 BA): the first of the last 12
# rows is 'ab' plus 40 of them (122 bytes, 123 with its newline) and the other 11 are 80 bytes each,
# so the cut leaves 120 bytes of row 1 - one byte into the first character, with its two
# continuation bytes (80 BA) at the head of the 39 whole characters that follow. The excerpt must not open on them.
chars="$(printf '›%.0s' $(seq 40))"; y79="$(head -c 79 /dev/zero | tr '\0' y)"
fresh; { printf 'ab%s\n' "$chars"; for _ in $(seq 11); do printf '%s\n' "$y79"; done; } > "$P/screen"
out="$(NO_TITLE=1 XREVIEW_PANE_WAIT=0.15 bash "$XREVIEW" dispatch --checkpoint plan b.md 2>&1)"
first="$(printf '%s' "$out" | LC_ALL=C grep -a '^  | ' | head -1 | LC_ALL=C sed 's/^  | //')"
b0="$(printf '%s' "$first" | head -c 1 | od -An -tu1 | tr -d ' ')"
is "S6c the excerpt's first line does not begin on a UTF-8 continuation byte" \
   "$([ "${b0:-0}" -ge 128 ] && [ "${b0:-0}" -le 191 ] && echo "continuation ($b0)" || echo "ok")" ok
is "S6c and starts at the first whole character that remains of the cut row" "$first" "${chars#›}"
is "S6c the excerpt is still twelve lines" "$(printf '%s' "$out" | LC_ALL=C grep -ac '^  | ')" 12
fresh; printf 'codex resume %s' "$U2" > "$P/argv"; : > "$P/title"
out="$(RPC_THREAD_RUNNING_FOR=$U2 bash "$XREVIEW" dispatch --checkpoint plan b.md 2>&1)"
is "S7 a pane resuming a running thread refuses as mid-turn" "$(printf '%s' "$out" | grep -c "thread $U2 is mid-turn")" 1
is "S7 untouched" "$(untouched)" yes
fresh; out="$(PROCINFO_FAIL=1 bash "$XREVIEW" dispatch --checkpoint plan b.md 2>&1)"
is "S8 an unreadable process refuses, naming the check" "$(printf '%s' "$out" | grep -cx "xreview: cannot read the Codex pane w1:p2's process (herdr pane process-info); no review was started")" 1
is "S8 untouched" "$(untouched)" yes
fresh; printf 'codex resume %s' "$U2" > "$P/argv"
out="$(RPC_STATUS_FAIL_FOR=$U2 bash "$XREVIEW" dispatch --checkpoint plan b.md 2>&1)"
is "S9 an unreadable running state refuses" "$(printf '%s' "$out" | grep -cx "xreview: cannot read whether thread $U2 in the Codex pane w1:p2 is running; no review was started")" 1
is "S9 untouched" "$(untouched)" yes
fresh; printf 'codex resume --last' > "$P/argv"
out="$(bash "$XREVIEW" dispatch --checkpoint plan b.md 2>&1)"
is "S10 resume --last refuses" "$(printf '%s' "$out" | grep -cx 'xreview: the Codex pane w1:p2 is resuming something other than a thread id; no review was started')" 1
is "S10 untouched" "$(untouched)" yes
fresh; printf 'codex -m resume' > "$P/argv"
out="$(bash "$XREVIEW" dispatch --checkpoint plan b.md 2>&1)"
is "S11 a flag value 'resume' is not a resume" "$(printf '%s' "$out" | grep -c '^xr-')" 1
fresh; bash "$XREVIEW" dispatch --checkpoint plan b.md >/dev/null 2>&1; : > "$CALLS"
CODEX_CHILD=1 bash "$XREVIEW" dispatch --checkpoint plan b.md >/dev/null 2>&1
is "S12 with a codex child in the group, the leader is judged: fast path" "$(called 'herdr pane send-keys')" 0
fresh; bash "$XREVIEW" dispatch --checkpoint plan b.md >/dev/null 2>&1
is "S13 the resume pins the review root with -C" "$(called "herdr pane run w1:p2 $PANE_CMD -C $CWD resume $U1")" 1
is "S14 nothing writes a pane record" "$([ -e "$STATE/pane" ] && echo yes || echo no)" no
# Spec §4.3/§6: daemon.pid is the third read the fast path needs; unreadable, it is no
# observation either. Same setup as S1, which takes the fast path with it.
fresh; bash "$XREVIEW" dispatch --checkpoint plan b.md >/dev/null 2>&1
rm -f "$CODEX_HOME/app-server-daemon/daemon.pid"; : > "$CALLS"
bash "$XREVIEW" dispatch --checkpoint plan b.md >/dev/null 2>&1
is "S15 an unreadable daemon.pid is not observed: ladder, then resume" "$(resumed "$U1")" 1
# The screen is evidence only: a failed read prints no excerpt, and costs nothing else - the
# turn exists by then, so the nonce must still be printed.
fresh; out="$(NO_TITLE=1 READ_FAIL=1 XREVIEW_PANE_WAIT=0.15 bash "$XREVIEW" dispatch --checkpoint plan b.md 2>&1)"; rc=$?
is "S16 an unreadable screen still warns, exit 0, with the nonce" \
   "$rc/$(printf '%s' "$out" | grep -cx 'xreview: the review is running but not shown in pane w1:p2')/$(printf '%s' "$out" | grep -c '^xr-')" "0/1/1"
is "S16 and shows no excerpt" "$(printf '%s' "$out" | grep -c '^  | ')" 0
# The three-pair cap, with a bound far beyond three short rungs: the cap ends the ladder.
fresh
out="$(STUCK_TUI=1 XREVIEW_POLL_SECS=0.05 XREVIEW_RUNG_WAIT=0.1 XREVIEW_PANE_WAIT=10 bash "$XREVIEW" dispatch --checkpoint plan b.md 2>&1)"; rc=$?
is "S17 a pane that never quits gets exactly three ctrl+c pairs" "$(called 'herdr pane send-keys')" 6
is "S17 then refuses with the exact line" \
   "$rc/$(printf '%s' "$out" | grep -cx 'xreview: the Codex pane w1:p2 did not exit its session within 10s; no review was started')" "1/1"
is "S17 no turn" "$(called 'xreview-rpc turn-start')" 0
# An argv the guard cannot read for certain refuses; one it can still reads as before.
for case_argv in "codex --newflag v resume $U2" "codex resume $U2 prompt" "codex fix-the-tests" \
                 "codex exec x" "codex fork $U2 x" "codex -- resume $U2"; do
  fresh; printf '%s' "$case_argv" > "$P/argv"
  out="$(bash "$XREVIEW" dispatch --checkpoint plan b.md 2>&1)"
  is "S18 '$case_argv' refuses" \
     "$(printf '%s' "$out" | grep -cx 'xreview: the Codex pane w1:p2 is resuming something other than a thread id; no review was started')" 1
  is "S18 '$case_argv': untouched" "$(untouched)" yes
done
fresh; printf 'codex fork %s' "$U2" > "$P/argv"
out="$(bash "$XREVIEW" dispatch --checkpoint plan b.md 2>&1)"
is "S19 a fork is no resume: the dispatch proceeds" "$(printf '%s' "$out" | grep -c '^xr-')" 1
fresh; printf 'codex' > "$P/argv"
out="$(bash "$XREVIEW" dispatch --checkpoint plan b.md 2>&1)"
is "S19 a bare codex (no positional) is a fresh session: the dispatch proceeds" "$(printf '%s' "$out" | grep -c '^xr-')" 1
fresh; printf 'codex fork' > "$P/argv"
out="$(bash "$XREVIEW" dispatch --checkpoint plan b.md 2>&1)"
is "S19 a bare fork proceeds too" "$(printf '%s' "$out" | grep -c '^xr-')" 1
# The chosen review thread's own running check fails closed too, before any keystroke.
for how in FAIL NOBOOL; do
  fresh; out="$(env RPC_STATUS_${how}_FOR=$U1 bash "$XREVIEW" dispatch --checkpoint plan b.md 2>&1)"; rc=$?
  is "S22 an unreadable status for the chosen thread ($how) refuses, exactly" \
     "$rc/$(printf '%s' "$out" | grep -cx "xreview: cannot read whether the review thread $U1 is running; no review was started")" "1/1"
  is "S22 $how: untouched, no turn, no key" "$(untouched)" yes
done
# The title check fails closed: a pane read that fails, or a resolver that cannot reach the
# daemon, refuses before any keystroke. A prefix that resolves to nothing still does not block.
for how in exit envelope; do
  fresh; out="$(GET_FAIL=$how bash "$XREVIEW" dispatch --checkpoint plan b.md 2>&1)"
  is "S20 a failed pane read ($how) refuses, naming the check" \
     "$(printf '%s' "$out" | grep -cx 'xreview: cannot read the Codex pane w1:p2 (herdr pane get); no review was started')" 1
  is "S20 $how: untouched" "$(untouched)" yes
done
P29="$(printf '%s' "$U0" | cut -c1-29)"   # the prefix the pane's title shows
for rrc in 5 2; do
  fresh; out="$(RPC_RESOLVE_RC=$rrc bash "$XREVIEW" dispatch --checkpoint plan b.md 2>&1)"
  is "S21 a resolver exiting $rrc refuses, naming the prefix" \
     "$(printf '%s' "$out" | grep -cx "xreview: cannot read whether thread $P29 in the Codex pane w1:p2 is running; no review was started")" 1
  is "S21 exit $rrc: untouched" "$(untouched)" yes
done
fresh; out="$(RPC_RESOLVE_RC=1 bash "$XREVIEW" dispatch --checkpoint plan b.md 2>&1)"
is "S21 a resolver exiting 1 (no such thread) does not block" "$(printf '%s' "$out" | grep -c '^xr-')" 1
# A Codex process that is not fully described is no observation: before the ladder, the
# process-info refusal.
for bad in argv-empty argv-null argv-missing name-missing; do
  fresh; out="$(PROCINFO_BAD=$bad bash "$XREVIEW" dispatch --checkpoint plan b.md 2>&1)"
  is "S22 a Codex process with $bad refuses as unreadable" \
     "$(printf '%s' "$out" | grep -cx "xreview: cannot read the Codex pane w1:p2's process (herdr pane process-info); no review was started")" 1
  is "S22 $bad: untouched" "$(untouched)" yes
done
# A foreground group that is not the shell, with no Codex process to read, is no observation:
# a TUI on a pre-session screen could be resuming a running thread. Refused before any key,
# whatever the title and status say.
for fg in empty vim; do
  fresh; : > "$P/title"; rm -f "$P/status"
  out="$(PROCINFO_FG=$fg bash "$XREVIEW" dispatch --checkpoint plan b.md 2>&1)"; rc=$?
  is "S23 a non-shell foreground with $fg and no Codex process refuses as unreadable" \
     "$rc/$(printf '%s' "$out" | grep -cx "xreview: cannot read the Codex pane w1:p2's process (herdr pane process-info); no review was started")" "1/1"
  is "S23 $fg: untouched" "$(untouched)" yes
done
# The shell in the foreground is already free: no key, and the resume.
fresh
out="$(PROCINFO_FG=shell bash "$XREVIEW" dispatch --checkpoint plan b.md 2>&1)"; rc=$?
is "S24 the shell in the foreground proceeds, with a nonce" "$rc/$(printf '%s' "$out" | grep -c '^xr-')" "0/1"
is "S24 with no key sent, and the resume" "$(called 'herdr pane send-keys')/$(resumed "$U1")" "0/1"

echo "E. checkpoints and pins"
fresh
bash "$XREVIEW" dispatch --checkpoint plan b.md >/dev/null 2>&1
bash "$XREVIEW" round --reset >/dev/null 2>&1
is "E1 reset drops the checkpoint thread" "$([ -e "$STATE/review-thread" ] && echo kept || echo dropped)" dropped
export NEW_UUID="$U2"; : > "$CALLS"
bash "$XREVIEW" dispatch --checkpoint plan b.md >/dev/null 2>&1
is "E1 the next checkpoint starts a fresh thread" "$(cat "$STATE/review-thread")" "$U2"
is "E1 the old thread is archived" "$(called "xreview-rpc thread-archive --thread $U1")" 1
is "E1 after the new turn started" \
   "$([ "$(first 'xreview-rpc turn-start')" -lt "$(first 'xreview-rpc thread-archive')" ] && echo yes || echo no)" yes
fresh
bash "$XREVIEW" init "$U0" >/dev/null
nonce="$(bash "$XREVIEW" dispatch --checkpoint plan b.md 2>/dev/null)"
is "E2 a pin is used as the review thread" "$(called "xreview-rpc turn-start --thread $U0")" 1
is "E2 and is not recorded as a checkpoint thread" "$([ -e "$STATE/review-thread" ] && echo yes || echo no)" no
bash "$XREVIEW" round --reset >/dev/null 2>&1; : > "$CALLS"
bash "$XREVIEW" dispatch --checkpoint plan b.md >/dev/null 2>&1
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
nonce="$(bash "$XREVIEW" dispatch --checkpoint plan b.md 2>/dev/null)"
is "E7 dispatch never resumes onto the legacy thread" "$(called "resume $U0")" 0
is "E7 a fresh checkpoint thread is used instead" "$(resumed "$U1")" 1
is "E7 the checkpoint gets its own fresh thread" "$(cat "$STATE/review-thread")" "$U1"
fresh
mkdir -p "$STATE" && printf '%s\n' "$U0" > "$STATE/thread"
bash "$XREVIEW" round --reset >/dev/null 2>&1
is "E7 reset drops the legacy file" "$([ -e "$STATE/thread" ] && echo kept || echo dropped)" dropped
is "E7 reset never archives the legacy file" "$([ -e "$STATE/superseded" ] && echo yes || echo no)" no

echo "F. collect"
ANSWER='{"verdict":"changes","findings":[{"severity":"P1","file":"a","line":1,"summary":"s","failure_scenario":"f"}]}'
fresh
nonce="$(bash "$XREVIEW" dispatch --checkpoint plan --diff HEAD~1..HEAD b.md 2>/dev/null)"
ROLL1="$CODEX_HOME/sessions/2026/09/01"; mkdir -p "$ROLL1"
printf '{"type":"turn_context","payload":{"model":"gpt-5.6-sol","effort":"xhigh"}}\n' \
  > "$ROLL1/rollout-2026-09-01T09-00-00-$U1.jsonl"
out="$(RPC_WAIT_OUT="$ANSWER" bash "$XREVIEW" collect "$nonce" 2>&1)"; rc=$?
is "F1 a finished review exits 0" "$rc" 0
is "F1 and prints the findings" "$(printf '%s' "$out" | jq -r .verdict)" changes
is "F1 waiting with the findings schema" "$(called "turn-wait --thread $U1 --turn turn-$U1 --budget 2700 --schema $XDG_CONFIG_HOME/xreview/findings.schema.json")" 1
r="$(tail -1 "$MAIN_LEDGER")"
is "F1 the receipt is a v2 receipt in the repository's ledger" \
   "$(printf '%s' "$r" | jq -r '[.v,.kind,.thread,.nonce,(.dispatched_at|length>0),has("tier")] | map(tostring) | join(" ")')" \
   "2 receipt $U1 $nonce true true"
is "F1 and adds turn, verdict and finding count" "$(printf '%s' "$r" | jq -r '[.turn,.verdict,.findings] | map(tostring) | join(" ")')" "turn-$U1 changes 1"
is "F1 the tier is a real value read from the thread's own rollout file" \
   "$(printf '%s' "$r" | jq -r .tier)" "gpt-5.6-sol/xhigh"
is "F1 the receipt records the checkpoint named at dispatch" "$(printf '%s' "$r" | jq -r .checkpoint)" plan
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

echo "F14. every dispatch names its checkpoint, and the receipt carries it"
fresh
out="$(bash "$XREVIEW" dispatch b.md 2>&1)"; rc=$?
is "F14 a dispatch without --checkpoint is refused" "$rc" 1
is "F14 and the usage names the flag" "$(printf '%s' "$out" | grep -c -- '--checkpoint spec|plan|pre-merge')" 1
is "F14 before anything is touched" "$(untouched)" yes
fresh
out="$(bash "$XREVIEW" dispatch --checkpoint merge b.md 2>&1)"; rc=$?
is "F14 an unknown checkpoint is refused" "$rc/$(printf '%s' "$out" | grep -c 'unknown checkpoint: merge')" "1/1"
is "F14 before anything is touched, too" "$(untouched)" yes
fresh
nonce="$(bash "$XREVIEW" dispatch --checkpoint pre-merge --diff HEAD~1..HEAD b.md 2>/dev/null)"
is "F14 the turn record carries the checkpoint" "$(cat "$STATE/turns/$nonce")" "$U1 turn-$U1 pre-merge $BR"
RPC_WAIT_OUT='{"verdict":"approve","findings":[]}' bash "$XREVIEW" collect "$nonce" >/dev/null 2>&1
is "F14 a pre-merge review's receipt says so" \
   "$(tail -1 "$MAIN_LEDGER" | jq -r '"\(.checkpoint)/\(.verdict)"')" "pre-merge/approve"
# A turn record written before the checkpoint existed has two fields; collect must still
# work and record an empty checkpoint, which the pre-merge gate never accepts.
printf '%s %s\n' "$U1" "turn-$U1" > "$STATE/turns/xr-1-legacy"
RPC_WAIT_OUT='{"verdict":"approve","findings":[]}' bash "$XREVIEW" collect xr-1-legacy >/dev/null 2>&1; rc=$?
is "F14 a legacy two-field record still collects" "$rc" 0
is "F14 with an empty checkpoint on its receipt" "$(tail -1 "$STATE/reviews.jsonl" | jq -r .checkpoint)" ""
is "F14 and the branch checked out now"           "$(tail -1 "$STATE/reviews.jsonl" | jq -r .branch)" "$BR"

echo "F15. the receipt names the branch the review was dispatched on"
# In the shared checkout another session can switch branches between dispatch and collect;
# the verdict belongs to the branch that was reviewed, never to the one checked out later.
fresh
git checkout -q -b review-a
printf 'a\n' > review-a.txt && git add review-a.txt && git commit -q -m "review-a's change"
nonce="$(bash "$XREVIEW" dispatch --checkpoint pre-merge --diff "$BR...review-a" b.md 2>/dev/null)"
is "F15 the turn record names the dispatch branch" "$(cat "$STATE/turns/$nonce")" "$U1 turn-$U1 pre-merge review-a"
git checkout -q -b review-b
git commit -q --allow-empty -m "review-b moves on"
RPC_WAIT_OUT='{"verdict":"approve","findings":[]}' bash "$XREVIEW" collect "$nonce" >/dev/null 2>&1; rc=$?
is "F15 collected on another branch, it still collects" "$rc" 0
is "F15 and the receipt names the dispatch branch" \
   "$(tail -1 "$MAIN_LEDGER" | jq -r '"\(.kind) \(.targets[0].branch)"')" "receipt review-a"
is "F15 with that branch's head at dispatch, not the one checked out" \
   "$(tail -1 "$MAIN_LEDGER" | jq -r '"\(.kind) \(.targets[0].tip)"')" "receipt $(git rev-parse review-a)"
# A record from before the branch field (checkpoint, no branch) names the current branch.
printf '%s %s %s\n' "$U1" "turn-$U1" pre-merge > "$STATE/turns/xr-1-legacy3"
RPC_WAIT_OUT='{"verdict":"approve","findings":[]}' bash "$XREVIEW" collect xr-1-legacy3 >/dev/null 2>&1; rc=$?
is "F15 a legacy three-field record still collects" "$rc" 0
is "F15 with its checkpoint and the current branch" \
   "$(tail -1 "$STATE/reviews.jsonl" | jq -r '"\(.checkpoint)/\(.branch)/\(.head)"')" "pre-merge/review-b/$(git rev-parse HEAD)"
git checkout -q "$BR"
git branch -q -D review-a review-b

echo "F10. the packet temp file never lingers, on the paths the explicit rm covers"
# This proves the explicit `rm -f "$packet"` right after turn-start (success here, a
# refused turn/start, and an unanswered one, exit 6 - every dispatch above too,
# cumulatively): all three already reach that line before returning, so it alone
# accounts for the result below. It does NOT exercise the trap - none of these paths
# dies between `mktemp` and that rm, which is the only case the trap is for - so this
# is not evidence the trap itself works. The trap is kept anyway as defence for an
# earlier death (an unexpected failure before turn-start, a signal) that no fixture
# here reaches.
fresh; RPC_START_FAIL=1 bash "$XREVIEW" dispatch --checkpoint plan b.md >/dev/null 2>&1
fresh; RPC_START_UNCERTAIN=1 bash "$XREVIEW" dispatch --checkpoint plan b.md >/dev/null 2>&1
is "no xreview-packet temp file is left in \$TMPDIR" \
   "$(find "$TMPDIR" -maxdepth 1 -name 'xreview-packet.*' 2>/dev/null | grep -c .)" 0

echo "F11. a receipt that cannot be written warns on stderr, but collect still exits 0"
fresh
nonce="$(bash "$XREVIEW" dispatch --checkpoint plan --diff HEAD~1..HEAD b.md 2>/dev/null)"
mkdir -p "$(dirname "$MAIN_LEDGER")" && mkdir "$MAIN_LEDGER.lock"   # another writer holds the ledger
out="$(XREVIEW_LEDGER_LOCK_WAIT=0.2 RPC_WAIT_OUT="$ANSWER" bash "$XREVIEW" collect "$nonce" 2>&1)"; rc=$?
is "F11 it still exits 0" "$rc" 0
is "F11 but warns that the receipt could not be written" \
   "$(printf '%s' "$out" | grep -c 'could not write the receipt')" 1
rmdir "$MAIN_LEDGER.lock"

echo "F12. an unsafe nonce passed to collect is refused"
out="$(bash "$XREVIEW" collect 'xr-a/b' 2>&1)"; rc=$?
is "F12 it is refused" "$rc" 1
is "F12 and says so" "$(printf '%s' "$out" | grep -c 'refusing unsafe identifier')" 1

echo "F13. missing reviewer instructions or the pane command refuse, pane untouched"
fresh
mv "$XDG_CONFIG_HOME/xreview/reviewer.md" "$ROOT/reviewer.md.bak"
out="$(bash "$XREVIEW" dispatch --checkpoint plan b.md 2>&1)"; rc=$?
is "F13 a missing reviewer.md refuses" "$(printf '%s' "$out" | grep -c 'missing reviewer instructions')" 1
is "F13 untouched" "$(untouched)" yes
mv "$ROOT/reviewer.md.bak" "$XDG_CONFIG_HOME/xreview/reviewer.md"
fresh
mv "$XDG_CONFIG_HOME/herdr/codex-pane-command" "$ROOT/codex-pane-command.bak"
out="$(bash "$XREVIEW" dispatch --checkpoint plan b.md 2>&1)"; rc=$?
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

echo "H. the queue-era machinery, the pane-first race machinery and the pane record are gone"
code="$(grep -v '^[[:space:]]*#' "$XREVIEW")"
for gone in 'codex queue' 'thread_history' 'XREVIEW_THREAD_WARN' 'herdr agent list' 'sqlite3' \
            'die_if_pane_gone' 'daemon_gen' 'pane_agent'; do
  is "no '$gone' in the code" "$(printf '%s' "$code" | grep -c -- "$gone")" 0
done
is "nothing reads or writes \$(state_dir)/pane (spec 2026-10-01 §4.3)" "$(grep -c 'state_dir)/pane"' "$XREVIEW")" 0
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
nonce="$(bash "$XREVIEW" dispatch --checkpoint plan b.md 2>/dev/null)"
is "the pane is found and the dispatch succeeds" "$(printf '%s' "$nonce" | grep -c '^xr-')" 1
SPSTATE="$XDG_STATE_HOME/xreview/$(printf '%s' "$SPCWD" | tr '/' '_' | sed 's/^_//')"
is "its state lands in its own directory" "$(cat "$SPSTATE/review-thread" 2>/dev/null)" "$U1"
cd "$ROOT/repo" || exit 1

echo "P. one dispatch at a time per pane (spec 2026-10-01 §4.9)"
LOCKF="$XDG_STATE_HOME/xreview/locks/w1_p2.lock"
fresh; mkdir -p "$(dirname "$LOCKF")"; rm -f "$ROOT/held"
/usr/bin/python3 -c 'import fcntl,sys,time
f = open(sys.argv[1], "a"); fcntl.flock(f, fcntl.LOCK_EX); open(sys.argv[2], "w").close(); time.sleep(60)' \
  "$LOCKF" "$ROOT/held" &
holder=$!
for _ in $(seq 50); do [ -e "$ROOT/held" ] && break; sleep 0.1; done
out="$(XREVIEW_LOCK_WAIT=0.5 bash "$XREVIEW" dispatch --checkpoint plan b.md 2>&1)"; rc=$?
is "P1 a held pane refuses at the bound" "$rc" 1
is "P1 with the exact message" \
   "$(printf '%s' "$out" | grep -cx 'xreview: another dispatch is using the Codex pane w1:p2; no review was started')" 1
is "P1 untouched" "$(untouched)" yes
is "P1 and no round consumed" "$(bash "$XREVIEW" round)" 0
kill -9 "$holder"; wait "$holder" 2>/dev/null
: > "$CALLS"
out="$(XREVIEW_LOCK_WAIT=2 bash "$XREVIEW" dispatch --checkpoint plan b.md 2>&1)"
is "P2 a SIGKILLed holder's lock is free at once" "$(printf '%s' "$out" | grep -c '^xr-')" 1
is "P2 the lock file is never deleted" "$([ -e "$LOCKF" ] && echo yes || echo no)" yes
fresh
for id in a b c; do
  ( DISPATCH_ID=$id KEY_DELAY=0.2 XREVIEW_LOCK_WAIT=30 \
      bash "$XREVIEW" dispatch --checkpoint plan b.md > "$ROOT/par.$id" 2>&1 ) &
done
wait
blocks="$(grep -E '^[abc] (herdr pane (get|process-info|send-keys|run|read|report-agent-session)|xreview-rpc turn-start)' "$CALLS" \
          | awk '{print $1}' | uniq)"
is "P3 every dispatch reached the pane section" "$(printf '%s\n' "$blocks" | sort -u | grep -c .)" 3
is "P3 no two dispatches interleave inside it" "$(printf '%s\n' "$blocks" | sort | uniq -d | grep -c .)" 0
is "P3 each one ended in a nonce or a clean refusal" \
   "$(for id in a b c; do grep -qE '^(xr-|xreview: (the Codex pane w1:p2 is mid-turn|the Codex pane w1:p2.s thread .* is mid-turn|another dispatch is using the Codex pane))' "$ROOT/par.$id" && echo ok; done | grep -c ok)" 3
fresh; rm -rf "$XDG_STATE_HOME/xreview/locks"; : > "$XDG_STATE_HOME/xreview/locks"
out="$(bash "$XREVIEW" dispatch --checkpoint plan b.md 2>&1)"; rc=$?
is "P4 an uncreatable lock directory refuses" "$rc/$(printf '%s' "$out" | grep -c 'cannot create')" "1/1"
is "P4 untouched" "$(untouched)" yes
rm -f "$XDG_STATE_HOME/xreview/locks"
for bad in abc . 1.2.3 $'5\nx'; do
  fresh
  out="$(XREVIEW_LOCK_WAIT=$bad bash "$XREVIEW" dispatch --checkpoint plan b.md 2>&1)"
  is "P5 a garbage XREVIEW_LOCK_WAIT ($(printf '%q' "$bad")) falls back to the default" "$(printf '%s' "$out" | grep -c '^xr-')" 1
done
# P7: unlock_pane closes fd 9 and nothing else - stderr must stay visible afterwards, and the
# lock must be free for the next locker.
fresh
lock_src="$(sed -n '/^lock_pane() {/,/^}/p;/^unlock_pane() {/p' "$XREVIEW")"
out="$(bash -c "die() { printf 'xreview: %s\n' \"\$1\" >&2; exit 1; }
$lock_src
lock_pane wP:p7
unlock_pane
echo probe >&2
/usr/bin/python3 -c 'import fcntl,sys; fcntl.flock(open(sys.argv[1], \"a\"), fcntl.LOCK_EX | fcntl.LOCK_NB)' \"\$XDG_STATE_HOME/xreview/locks/wP_p7.lock\" && echo free" 2>&1)"
is "P7 stderr written after unlock_pane is still visible" "$(printf '%s' "$out" | grep -cx probe)" 1
is "P7 and the lock is free after unlock_pane" "$(printf '%s' "$out" | grep -cx free)" 1
# P8: a helper that fails for any reason but the bound is not "another dispatch". The lock
# helper is swapped for a stand-in that runs the real python with fd 9 closed (flock raises
# EBADF, the helper's own exit-2 path), or that exits 75 (the bound ran out), or exits 1 (any other status is "cannot lock"). No sandbox-safe way
# exists to make flock itself fail on this filesystem, so the interpreter path is patched in
# a copy of the script, in lock_pane only.
printf '#!/bin/sh\nexec 9>&-\nexec /usr/bin/python3 "$@"\n' > "$ROOT/py-nolock"
printf '#!/bin/sh\nexit 75\n' > "$ROOT/py-timeout"
printf '#!/bin/sh\nexit 1\n' > "$ROOT/py-exit1"
chmod +x "$ROOT/py-nolock" "$ROOT/py-timeout" "$ROOT/py-exit1"
for variant in nolock exit1 timeout; do
  sed "/^lock_pane() {/,/^}/ s#/usr/bin/python3#$ROOT/py-$variant#" "$XREVIEW" > "$ROOT/xreview-$variant"
  fresh
  out="$(bash "$ROOT/xreview-$variant" dispatch --checkpoint plan b.md 2>&1)"; rc=$?
  if [ "$variant" = nolock ] || [ "$variant" = exit1 ]; then
    is "P8 a helper that cannot lock ($variant) refuses as 'cannot lock'" \
       "$rc/$(printf '%s' "$out" | grep -c "^xreview: cannot lock the Codex pane w1:p2 (.*w1_p2.lock); no review was started$")" "1/1"
    is "P8 and never as contention" "$(printf '%s' "$out" | grep -c 'another dispatch')" 0
    is "P8 and no traceback" "$(printf '%s' "$out" | grep -c 'Traceback')" 0
  else
    is "P8 a helper that times out (exit 75) refuses as 'another dispatch'" \
       "$rc/$(printf '%s' "$out" | grep -c '^xreview: another dispatch is using the Codex pane w1:p2; no review was started$')" "1/1"
  fi
  is "P8 $variant: untouched" "$(untouched)" yes
done
# P9: the lock helper is inline Python, run unsandboxed from the repository, and a plain
# `python3 -c` puts the current directory first on sys.path: a sandbox-written fcntl.py there
# would run outside the sandbox. fcntl is not built in on the system Python, so it is planted
# in the repository for the dispatch, and must never be imported (-I: no cwd on sys.path).
fresh; rm -f "$ROOT/pymark"
printf 'open("%s/pymark", "a").write("fcntl imported from the repository\\n")\n' "$ROOT" > "$ROOT/repo/fcntl.py"
/usr/bin/python3 -c 'import sys; sys.exit(0 if "fcntl" in sys.builtin_module_names else 1)'
is "P9 fcntl is not built in, so a planted one would be imported by a bare python3 -c" "$?" 1
( cd "$ROOT/repo" && /usr/bin/python3 -c 'import fcntl' ) 2>/dev/null
is "P9 the planted fcntl.py is live from the repository (control)" "$(grep -c imported "$ROOT/pymark" 2>/dev/null)" 1
rm -f "$ROOT/pymark"
out="$(bash "$XREVIEW" dispatch --checkpoint plan b.md 2>&1)"; rc=$?
rm -f "$ROOT/repo/fcntl.py"
is "P9 a dispatch imports nothing from the repository" "$(cat "$ROOT/pymark" 2>/dev/null)" ""
is "P9 and the dispatch still succeeds" "$rc/$(printf '%s' "$out" | grep -c '^xr-')" "0/1"
# Every inline or stdin Python in the unsandboxed scripts runs isolated (-I).
bare=$(grep -nE 'python3? +(-c|-)( |$)' "$XREVIEW" | grep -vE 'python3? +-I +(-c|-)( |$)')
is "P9 every inline python3 in xreview is isolated with -I" "$bare" ""

# P6 (spec §6): a waiter that gets the lock while the first dispatch's review turn is running
# refuses as mid-turn, and never sends a key into the pane the first one resumed.
fresh
( DISPATCH_ID=a KEY_DELAY=1 RPC_RUNNING_AFTER_START=1 XREVIEW_LOCK_WAIT=30 \
    bash "$XREVIEW" dispatch --checkpoint plan b.md > "$ROOT/par.a" 2>&1 ) &
for _ in $(seq 200); do grep -q '^a herdr pane send-keys' "$CALLS" && break; sleep 0.05; done
( DISPATCH_ID=b RPC_RUNNING_AFTER_START=1 XREVIEW_LOCK_WAIT=30 \
    bash "$XREVIEW" dispatch --checkpoint plan b.md > "$ROOT/par.b" 2>&1 ) &
wait
is "P6 the first dispatch's review started" "$(grep -c '^xr-' "$ROOT/par.a")" 1
is "P6 the waiter refuses as mid-turn once it gets the lock" "$(grep -c 'mid-turn' "$ROOT/par.b")" 1
is "P6 and sends no key after the first's turn-start" \
   "$(none_after '^a xreview-rpc turn-start' '^b herdr pane send-keys')" 0
is "P6 nor any key at all" "$(called '^b herdr pane send-keys')" 0

echo "Q. a harness worktree reviews in the pane of the worktree that holds it (spec 2026-10-01 §4.2)"
cd "$CWD" || exit 1
git worktree add -q "$CWD/.claude/worktrees/h1" -b h1
H1="$(git -C "$CWD/.claude/worktrees/h1" rev-parse --show-toplevel)"
hstate() { printf '%s/xreview/%s' "$XDG_STATE_HOME" "$(printf '%s' "$1" | tr '/' '_' | sed 's/^_//')"; }
fresh; rm -rf "$(hstate "$H1")"
cd "$H1" || exit 1
nonce="$(bash "$XREVIEW" dispatch --checkpoint plan "$CWD/b.md" 2>/dev/null)"
is "Q1 the harness worktree finds its main checkout's pane" "$(printf '%s' "$nonce" | grep -c '^xr-')" 1
is "Q1 its thread starts in the harness worktree" "$(called "xreview-rpc thread-start --cwd $H1")" 1
is "Q1 and its state is its own" "$(cat "$(hstate "$H1")/review-thread" 2>/dev/null)" "$U1"
is "Q1 the owner's pane resumes it with -C <harness root> (spec §6)" \
   "$(called "herdr pane run w1:p2 $PANE_CMD -C $H1 resume $U1")" 1
cd "$CWD" || exit 1
git worktree add -q "$ROOT/repo-sib" -b sib
SIB="$(git -C "$ROOT/repo-sib" rev-parse --show-toplevel)"
git -C "$SIB" worktree add -q "$SIB/.claude/worktrees/h2" -b h2
H2="$(git -C "$SIB/.claude/worktrees/h2" rev-parse --show-toplevel)"
fresh; rm -rf "$(hstate "$H2")"; export PANE_CWD="$SIB"
cd "$H2" || exit 1
nonce="$(bash "$XREVIEW" dispatch --checkpoint plan "$CWD/b.md" 2>/dev/null)"
is "Q2 a harness worktree inside a wt sibling finds the sibling's pane" "$(printf '%s' "$nonce" | grep -c '^xr-')" 1
is "Q2 its thread starts in that harness worktree" "$(called "xreview-rpc thread-start --cwd $H2")" 1
is "Q2 and its state is its own" "$(cat "$(hstate "$H2")/review-thread" 2>/dev/null)" "$U1"
fresh; rm -rf "$(hstate "$SIB")"     # the pane's cwd is the main checkout again
cd "$SIB" || exit 1
out="$(bash "$XREVIEW" dispatch --checkpoint plan "$CWD/b.md" 2>&1)"
is "Q3 a wt sibling never falls back to the main checkout's pane" "$(printf '%s' "$out" | grep -c "no Codex pane for $SIB")" 1
is "Q3 untouched" "$(untouched)" yes
cd "$CWD" || exit 1
fresh; export PANE_CWD="$H1"     # the owner's TUI reports a harness worktree as its cwd
nonce="$(bash "$XREVIEW" dispatch --checkpoint plan b.md 2>/dev/null)"
is "Q4 the owner's pane is still found" "$(printf '%s' "$nonce" | grep -c '^xr-')" 1
unset PANE_CWD
echo "Q5. the longest registered holder wins"
git -C "$H1" worktree add -q "$H1/.claude/worktrees/h3" -b h3
H3="$(git -C "$H1/.claude/worktrees/h3" rev-parse --show-toplevel)"
fresh; rm -rf "$(hstate "$H3")"; export PANE_CWD="$H1"
cd "$H3" || exit 1
nonce="$(bash "$XREVIEW" dispatch --checkpoint plan "$CWD/b.md" 2>/dev/null)"
is "Q5 a nested harness worktree finds the pane of the worktree that holds it" "$(printf '%s' "$nonce" | grep -c '^xr-')" 1
fresh; rm -rf "$(hstate "$H3")"     # the pane's cwd is the main checkout
out="$(bash "$XREVIEW" dispatch --checkpoint plan "$CWD/b.md" 2>&1)"
is "Q5 and never the main checkout's pane" "$(printf '%s' "$out" | grep -c "no Codex pane for $H1")" 1
is "Q5 untouched" "$(untouched)" yes
cd "$CWD" || exit 1

echo "Q6. a pane without a usable cwd, or under a look-alike directory, never breaks or wins the search"
fresh
export EXTRA_PANES=',{"agent":"codex","agent_status":"idle","pane_id":"w8:p2","terminal_title":"x"},{"agent":"codex","agent_status":"idle","cwd":null,"pane_id":"w8:p3","terminal_title":"x"}'
nonce="$(bash "$XREVIEW" dispatch --checkpoint plan b.md 2>/dev/null)"
is "Q6 Codex panes with no cwd or a null cwd do not stop the search" "$(printf '%s' "$nonce" | grep -c '^xr-')" 1
fresh; export PANE_CWD="$ROOT/elsewhere"
export EXTRA_PANES=",{\"agent\":\"codex\",\"agent_status\":\"idle\",\"cwd\":\"$CWD/.claude/worktreesX\",\"pane_id\":\"w8:p4\",\"terminal_title\":\"x\"}"
out="$(bash "$XREVIEW" dispatch --checkpoint plan b.md 2>&1)"
is "Q6 a pane under .claude/worktreesX is not the owner's" "$(printf '%s' "$out" | grep -c "no Codex pane for $CWD")" 1
is "Q6 untouched" "$(untouched)" yes

echo "Q7. a bare init from a harness worktree refuses; an explicit id still pins"
fresh; rm -rf "$(hstate "$H1")"
cd "$H1" || exit 1
out="$(bash "$XREVIEW" init 2>&1)"; rc=$?
is "Q7 a bare init refuses" "$rc" 1
is "Q7 naming the pane's owner" "$(printf '%s' "$out" | grep -c "the Codex pane belongs to $CWD; pass a thread id: xreview init <thread-id>")" 1
is "Q7 and pins nothing" "$([ -e "$(hstate "$H1")/pin" ] && echo yes || echo no)" no
bash "$XREVIEW" init "$U0" >/dev/null 2>&1
is "Q7 init with an id pins it in the worktree's own state" "$(cat "$(hstate "$H1")/pin" 2>/dev/null)" "$U0"
rm -rf "$(hstate "$H1")"
cd "$CWD" || exit 1
fresh
git worktree remove --force "$H3"; git worktree remove --force "$H2"; git worktree remove --force "$SIB"; git worktree remove --force "$H1"
git branch -q -D h1 h2 h3 sib

echo "K. a comma-decimal locale does not break the ctrl+c gap or the poll wait (I-2)"
fresh
out="$(LC_ALL=nl_BE.UTF-8 bash "$XREVIEW" dispatch --checkpoint plan b.md 2>&1)"; rc=$?
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
out="$(LC_ALL=nl_BE.UTF-8 NO_TITLE=1 XREVIEW_PANE_WAIT=0.15 XREVIEW_POLL_SECS=0.05 bash "$XREVIEW" dispatch --checkpoint plan b.md 2>&1)"; rc=$?
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
nonce="$(bash "$XREVIEW" dispatch --checkpoint plan b.md 2>/dev/null)"
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

echo "R. the round counter binds to the branch the dispatch recorded (spec 2026-10-01 §4.8)"
fresh
git checkout -q -b rc-a && git branch -q rc-b
RPC_SWITCH_BRANCH_TO=rc-b bash "$XREVIEW" dispatch --checkpoint plan b.md >/dev/null 2>&1
is "R1 the shared checkout moved to rc-b mid-dispatch" "$(git rev-parse --abbrev-ref HEAD)" rc-b
is "R1 rc-b's counter is untouched" "$(bash "$XREVIEW" round)" 0
git checkout -q rc-a
is "R1 rc-a, the dispatched branch, counts the round" "$(bash "$XREVIEW" round)" 1
git checkout -q "$BR" && git branch -q -D rc-a rc-b
fresh
git checkout -q -b rc-a && git branch -q rc-b
printf 'rc-a=10\n' > "$STATE/rounds"
out="$(XREVIEW_MAX_ROUNDS=10 RPC_SWITCH_BRANCH_EARLY=rc-b bash "$XREVIEW" dispatch --checkpoint plan b.md 2>&1)"; rc=$?
is "R2 the checkout moved to rc-b before the cap check" "$(git rev-parse --abbrev-ref HEAD)" rc-b
is "R2 the dispatched branch is refused at its cap" "$rc:$(printf '%s' "$out" | grep -c 'exceeds the cap')" 1:1
is "R2 and no turn was started" "$(called 'xreview-rpc turn-start')" 0
is "R2 the over-cap bump lands on rc-a" "$(grep -c '^rc-a=11$' "$STATE/rounds")" 1
is "R2 and rc-b gets no row" "$(grep -c '^rc-b=' "$STATE/rounds")" 0
git checkout -q "$BR" && git branch -q -D rc-a rc-b
fresh
git checkout -q -b rc-a && git branch -q rc-b
RPC_SWITCH_BRANCH_TO=rc-b RPC_START_UNCERTAIN=1 bash "$XREVIEW" dispatch --checkpoint plan b.md >/dev/null 2>&1
is "R3 the checkout moved to rc-b mid-dispatch" "$(git rev-parse --abbrev-ref HEAD)" rc-b
is "R3 an uncertain turn-start leaves rc-b's counter untouched" "$(bash "$XREVIEW" round)" 0
git checkout -q rc-a
is "R3 and bumps rc-a, the dispatched branch" "$(bash "$XREVIEW" round)" 1
git checkout -q "$BR" && git branch -q -D rc-a rc-b

echo "L. round counting is exact-match, not sed/grep regex, so a branch with '/' or metacharacters works"
fresh
ORIG_BRANCH="$(git rev-parse --abbrev-ref HEAD)"
git checkout -q -b feat/x
is "L1 round counter starts at zero on a slash branch" "$(bash "$XREVIEW" round)" 0
bash "$XREVIEW" dispatch --checkpoint plan b.md >/dev/null 2>&1
is "L2 a dispatch on a slash branch bumps its own counter" "$(bash "$XREVIEW" round)" 1
git checkout -q -b feat/xy
is "L3 a sibling branch whose name extends the first starts at its own zero" "$(bash "$XREVIEW" round)" 0
bash "$XREVIEW" dispatch --checkpoint plan b.md >/dev/null 2>&1
is "L4 and bumps independently" "$(bash "$XREVIEW" round)" 1
git checkout -q feat/x
is "L5 feat/x is unaffected by feat/xy's dispatch" "$(bash "$XREVIEW" round)" 1
XREVIEW_MAX_ROUNDS=1 bash "$XREVIEW" round --reset >/dev/null
export NEW_UUID="$U2"   # round --reset drops the cached thread, so this dispatch calls
                         # thread-start again - give it a fresh id
out="$(XREVIEW_MAX_ROUNDS=1 bash "$XREVIEW" dispatch --checkpoint plan b.md 2>&1)"
is "L6 XREVIEW_MAX_ROUNDS=1 the first dispatch on a slash branch is allowed" \
   "$(printf '%s' "$out" | grep -c '^xr-')" 1
out="$(XREVIEW_MAX_ROUNDS=1 bash "$XREVIEW" dispatch --checkpoint plan b.md 2>&1)"
is "L7 and the second is refused at the cap" "$(printf '%s' "$out" | grep -c 'exceeds the cap')" 1
git checkout -q -b 'a.b+c'
is "L8 a branch with regex metacharacters ('.', '+') starts at zero" "$(bash "$XREVIEW" round)" 0
bash "$XREVIEW" dispatch --checkpoint plan b.md >/dev/null 2>&1
is "L9 and bumps to one without disturbing other branches' rows" "$(bash "$XREVIEW" round)" 1
git checkout -q feat/x
is "L10 feat/x's row is untouched by the a.b+c branch's dispatch" "$(bash "$XREVIEW" round)" 2

echo "M. a branch name containing '=' is split on the LAST '=', not the first (I-1)"
git checkout -q -b 'x=y'
is "M1 round counter starts at zero on a branch containing '='" "$(bash "$XREVIEW" round)" 0
bash "$XREVIEW" dispatch --checkpoint plan b.md >/dev/null 2>&1
is "M2 a dispatch on it bumps to one" "$(bash "$XREVIEW" round)" 1
bash "$XREVIEW" dispatch --checkpoint plan b.md >/dev/null 2>&1
is "M3 and a second dispatch bumps to two" "$(bash "$XREVIEW" round)" 2
out="$(XREVIEW_MAX_ROUNDS=2 bash "$XREVIEW" dispatch --checkpoint plan b.md 2>&1)"
is "M4 XREVIEW_MAX_ROUNDS=2 refuses the third dispatch at the cap" \
   "$(printf '%s' "$out" | grep -c 'exceeds the cap')" 1
git checkout -q -b x
is "M5 a coexisting branch 'x' (a prefix of 'x=y') has its own independent count" "$(bash "$XREVIEW" round)" 0
bash "$XREVIEW" dispatch --checkpoint plan b.md >/dev/null 2>&1
is "M6 and a dispatch on 'x' bumps only its own row" "$(bash "$XREVIEW" round)" 1
git checkout -q 'x=y'
is "M7 'x=y' is unaffected by 'x's dispatch" "$(bash "$XREVIEW" round)" 3

echo "N. the rewrite half of bump_round keeps rows it must not match, even under the old buggy regex (M2)"
git checkout -q 'a.b+c'
mkdir -p "$STATE"
printf 'aXb+c=5\n' > "$STATE/rounds"   # 'aXb+c' is NOT 'a.b+c' - but the old grep -v "^a.b+c="
                                       # treated '.' as a wildcard and '+' as literal, so it
                                       # matched and wrongly dropped this row
bash "$XREVIEW" dispatch --checkpoint plan b.md >/dev/null 2>&1
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
out="$(PATH="$STUB2:$PATH" PINNED_PATH="$STUB2:$PATH" bash "$XREVIEW" round 2>&1)"; rc=$?
is "O1 'xreview round' does not crash when its awk read fails" "$rc" 0
is "O1 and still prints a number, not an empty line" "$(printf '%s' "$out" | grep -cE '^[0-9]+$')" 1

git checkout -q "$ORIG_BRANCH"
git branch -q -D feat/x feat/xy 'a.b+c' 'x=y' x

echo "V. review targets and pending entries (spec 2026-10-02 §3.2-§3.4)"
# vrepo <dir>: a repository on main with one commit, and a branch, feature, one change ahead and
# checked out. Its own default branch is main, whatever this machine's git configuration says.
vrepo() {
  mkdir -p "$1" && git -C "$1" init -q -b main && git -C "$1" config user.email t@t \
    && git -C "$1" config user.name t && git -C "$1" config commit.gpgsign false
  printf 'one\n' > "$1/a.txt" && git -C "$1" add a.txt && git -C "$1" commit -q -m init
  git -C "$1" switch -q -c feature && printf 'two\n' >> "$1/a.txt" && git -C "$1" commit -q -am feature
  printf 'body\n' > "$1/b.md"
}
V="$ROOT/v-one"; vrepo "$V"
V2="$ROOT/v-two"; vrepo "$V2"
VCWD="$(git -C "$V" rev-parse --show-toplevel)"
VSTATE="$XDG_STATE_HOME/xreview/$(printf '%s' "$VCWD" | tr '/' '_' | sed 's/^_//')"
VLEDGER="$(/usr/bin/python3 "$LEDGER" path "$V")"
V2LEDGER="$(/usr/bin/python3 "$LEDGER" path "$V2")"
targets_files() { find "$VSTATE/turns" -name '*.targets' 2>/dev/null | wc -l | tr -d ' '; }
cd "$V" || exit 1
fresh; export PANE_CWD="$VCWD"
nonce="$(bash "$XREVIEW" dispatch --checkpoint plan b.md 2>/dev/null)"
is "V1 a plan dispatch with no --diff still works" "$(printf '%s' "$nonce" | grep -c '^xr-')" 1
is "V2 its targets file names no target" "$(jq -c .targets "$VSTATE/turns/$nonce.targets")" "[]"
is "V3 and it writes no ledger entry" "$([ -e "$VLEDGER" ] && echo written || echo none)" none
fresh; export PANE_CWD="$VCWD"
nonce="$(bash "$XREVIEW" dispatch --checkpoint spec b.md 2>/dev/null)"
is "V4 so does a spec dispatch" "$(printf '%s' "$nonce" | grep -c '^xr-')" 1
fresh; export PANE_CWD="$VCWD"
nonce="$(SNAP_LEDGER="$VLEDGER" bash "$XREVIEW" dispatch --checkpoint pre-merge b.md 2>/dev/null)"
is "V5 a pre-merge dispatch with no --diff targets the branch against the default branch" \
   "$(jq -r '.targets[0] | "\(.range) \(.dest) \(.branch) \(.full)"' "$VSTATE/turns/$nonce.targets")" \
   "main...feature main feature true"
is "V6 its targets file carries the nonce, the checkpoint and the dispatch time" \
   "$(jq -r '"\(.nonce) \(.checkpoint) \(.dispatched_at | test("^[0-9-]+T[0-9:]+\\.[0-9]{6}Z$"))"' "$VSTATE/turns/$nonce.targets")" \
   "$nonce pre-merge true"
is "V7 its pending entry was on record before the turn started" \
   "$(jq -r 'select(.kind == "pending") | .nonce' "$P/ledger-at-start" 2>/dev/null)" "$nonce"
is "V8 naming the same targets" \
   "$(jq -c --arg n "$nonce" 'select(.nonce == $n and .kind == "pending") | .targets' "$VLEDGER")" \
   "$(jq -c .targets "$VSTATE/turns/$nonce.targets")"
fresh; export PANE_CWD="$VCWD"
before="$(targets_files)"
mkdir "$VLEDGER.lock"   # another writer holds the ledger past the wait
out="$(XREVIEW_LEDGER_LOCK_WAIT=0.2 bash "$XREVIEW" dispatch --checkpoint pre-merge b.md 2>&1)"; rc=$?
is "V9 a pre-merge dispatch whose pending write fails is refused" \
   "$rc/$(printf '%s' "$out" | grep -c 'cannot record the pending review in every target ledger')" "1/1"
is "V10 before the pane or the reviewer is touched" "$(untouched)" yes
is "V11 with no nonce handed back" "$(printf '%s' "$out" | grep -c '^xr-')" 0
is "V12 and no targets file left behind" "$(targets_files)" "$before"
rmdir "$VLEDGER.lock"
fresh; export PANE_CWD="$VCWD"
git switch -q main
out="$(bash "$XREVIEW" dispatch --checkpoint pre-merge b.md 2>&1)"; rc=$?
is "V13 a pre-merge dispatch whose target is empty is refused" \
   "$rc/$(printf '%s' "$out" | grep -c 'nothing to review')" "1/1"
is "V14 untouched" "$(untouched)" yes
printf 'm\n' > m.txt && git add m.txt && git commit -q -m "main moves on"
git switch -q feature
fresh; export PANE_CWD="$VCWD"
bash "$XREVIEW" dispatch --checkpoint pre-merge --diff main..feature b.md >/dev/null 2>&1
is "V15 main..feature is normalized: the packet carries the branch's own change" "$(grep -c '^+two$' "$P/packet")" 1
is "V16 and not main's later change, reversed" "$(grep -c 'm.txt' "$P/packet")" 0
git switch -q -c sub main
git update-index --add --cacheinfo 160000,1111111111111111111111111111111111111111,lib
git commit -q -m "a gitlink"
git config diff.ignoreSubmodules all
fresh; export PANE_CWD="$VCWD"
bash "$XREVIEW" dispatch --checkpoint plan --diff main...sub b.md >/dev/null 2>&1
is "V17 the inlined diff shows a gitlink even with diff.ignoreSubmodules=all" \
   "$(grep -c '^+Subproject commit 1111111111111111111111111111111111111111$' "$P/packet")" 1
git config --unset diff.ignoreSubmodules
git switch -q feature
fresh; export PANE_CWD="$VCWD"
nonce="$(bash "$XREVIEW" dispatch --checkpoint plan --diff main...feature --diff "$V2:main...feature" b.md 2>/dev/null)"
is "V18 --diff repeats: both diffs travel in the packet" "$(grep -c '^--- diff (' "$P/packet")" 2
is "V19 the second labelled with its repository" "$(grep -cF -- "--- diff ($V2:main...feature) ---" "$P/packet")" 1
is "V20 one target per repository" \
   "$(jq -r '[.targets[].repo] | unique | length' "$VSTATE/turns/$nonce.targets")" 2
one="$(git -C "$V2" diff main...feature | wc -c | tr -d ' ')"
fresh; export PANE_CWD="$VCWD"
out="$(XREVIEW_MAX_DIFF_BYTES=$((one * 2 - 10)) bash "$XREVIEW" dispatch --checkpoint plan \
         --diff main...feature --diff "$V2:main...feature" b.md 2>&1)"
is "V21 the size cap binds the total of all the diffs" "$(printf '%s' "$out" | grep -c 'too large')" 1
is "V22 untouched" "$(untouched)" yes
fresh; export PANE_CWD="$VCWD"
out="$(bash "$XREVIEW" dispatch --checkpoint plan --diff "$ROOT/no-such:main...feature" b.md 2>&1)"; rc=$?
is "V23 a --diff naming no directory is refused" "$rc/$(printf '%s' "$out" | grep -c 'is not a directory')" "1/1"
# The packet shows every path and byte the fingerprint names, whatever the reviewed repository's
# configuration says: diff.relative with xreview run from a subdirectory, an external diff
# driver that prints nothing, and a textconv that rewrites content.
git switch -q -c hostile main
mkdir -p deep && printf 'in\n' > deep/in.txt && printf 'out\n' > out.txt
git add deep/in.txt out.txt && git commit -q -m "one file inside deep/, one outside"
printf '#!/bin/sh\nexit 0\n' > "$ROOT/silent-diff"; chmod +x "$ROOT/silent-diff"
git config diff.relative true
git config diff.external "$ROOT/silent-diff"
git config diff.upper.textconv 'tr a-z A-Z'
printf '*.txt diff=upper\n' > .git/info/attributes
cd deep || exit 1
fresh; export PANE_CWD="$VCWD"
bash "$XREVIEW" dispatch --checkpoint plan --diff main...hostile ../b.md >/dev/null 2>&1
cd "$V" || exit 1
want="$(git diff --no-relative --no-renames --name-only main...hostile | sort | tr '\n' ' ')"
is "V24 from a subdirectory, under diff.relative, an external driver and a textconv, the packet holds every changed path" \
   "$(sed -n 's/^diff --git a\/\([^ ]*\) .*/\1/p' "$P/packet" | sort | tr '\n' ' ')" "$want"
is "V25 with the content as committed, never converted" "$(grep -c '^+in$' "$P/packet")" 1
git config --unset diff.relative; git config --unset diff.external; git config --unset diff.upper.textconv
rm .git/info/attributes
# A partial range keeps its literal base, and the packet shows exactly that base..tip: from a
# divergent commit, the commit's own file goes away.
git switch -q -c divergent main
printf 'd\n' > div.txt && git add div.txt && git commit -q -m divergent
DIV="$(git rev-parse HEAD)"
git switch -q feature
fresh; export PANE_CWD="$VCWD"
nonce="$(bash "$XREVIEW" dispatch --checkpoint plan --diff "$DIV...feature" b.md 2>/dev/null)"
is "V26 a divergent commit...branch is recorded with its literal base" \
   "$(jq -r '.targets[0] | "\(.base) \(.full)"' "$VSTATE/turns/$nonce.targets")" "$DIV false"
is "V27 and the packet shows that base..tip" "$(grep -c '^diff --git a/div.txt b/div.txt$' "$P/packet")" 1
cd "$ROOT/repo" || exit 1
unset PANE_CWD

echo "W. receipts: one per repository, fixed at dispatch, idempotent (spec 2026-10-02 §3.5)"
APPROVE='{"verdict":"approve","findings":[]}'
CHANGES='{"verdict":"changes","findings":[]}'
# vgate <repo> [tip]: the pre-merge gate's decision for <tip> (default feature) landing on main.
vgate() { /usr/bin/python3 "$LEDGER" decide "$1" main main "${2:-feature}" | jq -r 'if .allow then "allow" else "deny" end'; }
receipts_of() { jq -r --arg n "$1" 'select(.nonce == $n and .kind == "receipt") | .verdict' "$2" 2>/dev/null; }
cd "$V" || exit 1
fresh; export PANE_CWD="$VCWD"
n1="$(bash "$XREVIEW" dispatch --checkpoint pre-merge --diff main...feature b.md 2>/dev/null)"
is "W1 a dispatch alone leaves the gate closed" "$(vgate "$V")" deny
RPC_WAIT_OUT="$APPROVE" bash "$XREVIEW" collect "$n1" >/dev/null 2>&1
is "W2 an approving collect opens it" "$(vgate "$V")" allow
is "W3 with one receipt for the nonce" "$(receipts_of "$n1" "$VLEDGER")" approve
RPC_WAIT_OUT="$APPROVE" bash "$XREVIEW" collect "$n1" >/dev/null 2>&1
is "W4 collecting it again appends nothing" "$(receipts_of "$n1" "$VLEDGER" | wc -l | tr -d ' ')" 1
fresh; export PANE_CWD="$VCWD"
n2="$(bash "$XREVIEW" dispatch --checkpoint pre-merge --diff main...feature b.md 2>/dev/null)"
is "W5 a newer pending review closes it" "$(vgate "$V")" deny
RPC_WAIT_OUT="$CHANGES" bash "$XREVIEW" collect "$n2" >/dev/null 2>&1
is "W6 a later changes verdict keeps it closed" "$(vgate "$V")" deny
is "W6b with the changes receipt for that nonce on record" "$(receipts_of "$n2" "$VLEDGER")" changes
RPC_WAIT_OUT="$APPROVE" bash "$XREVIEW" collect "$n1" >/dev/null 2>&1
is "W7 re-collecting the old approve does not reopen it" "$(vgate "$V")" deny
fresh; export PANE_CWD="$VCWD"
n3="$(bash "$XREVIEW" dispatch --checkpoint pre-merge --diff main...feature b.md 2>/dev/null)"
mkdir "$VLEDGER.lock"   # another writer holds the ledger past the wait
out="$(XREVIEW_LEDGER_LOCK_WAIT=0.2 RPC_WAIT_OUT="$APPROVE" bash "$XREVIEW" collect "$n3" 2>&1)"; rc=$?
rmdir "$VLEDGER.lock"
is "W8 a receipt that cannot be written warns, and collect still exits 0" \
   "$rc/$(printf '%s' "$out" | grep -c "could not write the receipt for $n3")" "0/1"
is "W9 the gate stays closed: the pending entry is the newest state" "$(vgate "$V")" deny
RPC_WAIT_OUT="$APPROVE" bash "$XREVIEW" collect "$n3" >/dev/null 2>&1
is "W10 until a later collect records the receipt" "$(vgate "$V")" allow
fresh; export PANE_CWD="$VCWD"
n4="$(bash "$XREVIEW" dispatch --checkpoint pre-merge --diff main...feature b.md 2>/dev/null)"
printf 'three\n' >> a.txt && git commit -q -am "after the dispatch"
RPC_WAIT_OUT="$APPROVE" bash "$XREVIEW" collect "$n4" >/dev/null 2>&1
# The receipt adds only what collect found (spec 2026-10-25 §3.6): each target's missing labels.
is "W11 the receipt names the targets fixed at dispatch" \
   "$(jq -c --arg n "$n4" 'select(.nonce == $n and .kind == "receipt") | [.targets[] | del(.missing)]' "$VLEDGER")" \
   "$(jq -c --arg n "$n4" 'select(.nonce == $n and .kind == "pending") | .targets' "$VLEDGER")"
is "W12 so a commit made after the dispatch is not approved" "$(vgate "$V")" deny
printf '%s %s %s %s\n' "$U1" "turn-$U1" pre-merge feature > "$VSTATE/turns/xr-1-old"
before="$(wc -l < "$VLEDGER" | tr -d ' ')"
RPC_WAIT_OUT="$APPROVE" bash "$XREVIEW" collect xr-1-old >/dev/null 2>&1; rc=$?
is "W13 an old turn record without a targets file still collects" "$rc" 0
is "W14 as a v1 receipt in the checkout's own file" \
   "$(tail -1 "$VSTATE/reviews.jsonl" | jq -r '"\(.nonce) \(.checkpoint) \(.branch) \(has("v"))"')" \
   "xr-1-old pre-merge feature false"
is "W15 which never reaches the ledger" "$(wc -l < "$VLEDGER" | tr -d ' ')" "$before"
fresh; export PANE_CWD="$VCWD"
nm="$(bash "$XREVIEW" dispatch --checkpoint pre-merge --diff main...feature --diff "$V2:main...feature" b.md 2>/dev/null)"
is "W16 one dispatch, two repositories: one pending entry in each ledger" \
   "$(for f in "$VLEDGER" "$V2LEDGER"; do jq -r --arg n "$nm" 'select(.nonce == $n and .kind == "pending") | .targets | length' "$f"; done | tr '\n' ' ')" "1 1 "
RPC_WAIT_OUT="$APPROVE" bash "$XREVIEW" collect "$nm" >/dev/null 2>&1
is "W17 and one receipt in each" "$(receipts_of "$nm" "$VLEDGER")/$(receipts_of "$nm" "$V2LEDGER")" "approve/approve"
is "W18 each opens its own repository's gate" "$(vgate "$V") $(vgate "$V2")" "allow allow"
git worktree add -q "$VCWD/.claude/worktrees/hw" -b hw main
HW="$(git -C "$VCWD/.claude/worktrees/hw" rev-parse --show-toplevel)"
printf 'hw\n' > "$HW/hw.txt" && git -C "$HW" add hw.txt && git -C "$HW" commit -q -m "harness change"
cd "$HW" || exit 1
fresh; export PANE_CWD="$VCWD"
nw="$(bash "$XREVIEW" dispatch --checkpoint pre-merge "$V/b.md" 2>/dev/null)"
RPC_WAIT_OUT="$APPROVE" bash "$XREVIEW" collect "$nw" >/dev/null 2>&1
cd "$V" || exit 1
is "W19 a review collected in a harness worktree opens the gate in the main checkout" "$(vgate "$V" hw)" allow
out="$(bash "$XREVIEW" receipts)"
is "W20 receipts lists the repository's ledger, harness reviews included" "$(printf '%s\n' "$out" | grep -c "\"nonce\":\"$nw\"")" 2
is "W21 and this checkout's v1 receipts after it" "$(printf '%s\n' "$out" | tail -1 | jq -r .nonce)" xr-1-old
is "W22 --tiers counts receipts, never pending entries" \
   "$(bash "$XREVIEW" receipts --tiers | awk '{s += $1} END {print s}')" \
   "$(( $(jq -r 'select(.kind == "receipt") | .nonce' "$VLEDGER" | wc -l) + 1 ))"
fresh; export PANE_CWD="$VCWD"
nA="$(bash "$XREVIEW" dispatch --checkpoint pre-merge --diff main...feature b.md 2>/dev/null)"
nB="$(bash "$XREVIEW" dispatch --checkpoint pre-merge --diff main...feature b.md 2>/dev/null)"
RPC_WAIT_OUT="$CHANGES" bash "$XREVIEW" collect "$nB" >/dev/null 2>&1
RPC_WAIT_OUT="$APPROVE" bash "$XREVIEW" collect "$nA" >/dev/null 2>&1
is "W26 a first-time approve of the older dispatch, collected last, leaves it closed" "$(vgate "$V")" deny
is "W27 because a receipt keeps its dispatch time" \
   "$(jq -r --arg n "$nA" 'select(.nonce == $n and .kind == "receipt") | .dispatched_at' "$VLEDGER")" \
   "$(jq -r --arg n "$nA" 'select(.nonce == $n and .kind == "pending") | .dispatched_at' "$VLEDGER")"
# A helper that succeeds but warns (a release that could not take the break lock): collect
# passes the warning through on stderr and still exits 0.
printf '%s\n' 'import os, runpy, sys' \
  'if "append" in sys.argv: sys.stderr.write("xreview-ledger: stub warning\n")' \
  'runpy.run_path(os.environ["XREVIEW_REAL_LEDGER"], run_name="__main__")' > "$ROOT/warn-ledger.py"
fresh; export PANE_CWD="$VCWD"
nWn="$(bash "$XREVIEW" dispatch --checkpoint pre-merge --diff main...feature b.md 2>/dev/null)"
out="$(XREVIEW_REAL_LEDGER="$LEDGER" XREVIEW_LEDGER="$ROOT/warn-ledger.py" RPC_WAIT_OUT="$APPROVE" bash "$XREVIEW" collect "$nWn" 2>&1 >/dev/null)"; rc=$?
is "W28 a helper warning on a successful receipt write reaches stderr, and collect exits 0" \
   "$rc/$(printf '%s' "$out" | grep -c 'xreview-ledger: stub warning')/$(receipts_of "$nWn" "$VLEDGER")" "0/1/approve"
# A writer that died holding the ledger's break lock leaves it in place: collect warns, naming
# it, and a pre-merge dispatch is refused until it is removed by hand.
fresh; export PANE_CWD="$VCWD"
n5="$(bash "$XREVIEW" dispatch --checkpoint pre-merge --diff main...feature b.md 2>/dev/null)"
mkdir "$VLEDGER.lock.break"
/usr/bin/python3 -c 'import os,sys,time; t=time.time()-120; os.utime(sys.argv[1],(t,t))' "$VLEDGER.lock.break"
out="$(RPC_WAIT_OUT="$APPROVE" bash "$XREVIEW" collect "$n5" 2>&1)"; rc=$?
is "W23 a stale break lock: collect warns, naming it to remove by hand, and still exits 0" \
   "$rc/$(printf '%s' "$out" | grep -c -F "remove it by hand (rmdir $VLEDGER.lock.break)")" "0/1"
fresh; export PANE_CWD="$VCWD"
out="$(bash "$XREVIEW" dispatch --checkpoint pre-merge --diff main...feature b.md 2>&1)"; rc=$?
is "W24 and a pre-merge dispatch is refused, naming it" \
   "$rc/$(printf '%s' "$out" | grep -c -F "remove it by hand (rmdir $VLEDGER.lock.break)")" "1/1"
is "W25 the break lock is left in place" "$([ -d "$VLEDGER.lock.break" ] && echo kept || echo gone)" kept
rmdir "$VLEDGER.lock.break"
# record_pending on a targets document that names no repository would put nothing on record
# and report success, so the review would run with nothing pending for it.
rp="$(bash -c 'calls="$2"; ledger() { echo called >> "$calls"; }; eval "$(sed -n "/^record_pending() {/,/^}/p" "$1")"
  record_pending "{\"v\":2,\"nonce\":\"xr-none\",\"checkpoint\":\"pre-merge\",\"targets\":[]}"; echo "$?"' _ "$XREVIEW" "$ROOT/rp-calls")"
is "W29 record_pending fails on a targets document naming no repository, writing nothing" \
   "$rp/$([ -e "$ROOT/rp-calls" ] && echo wrote || echo none)" "1/none"
cd "$ROOT/repo" || exit 1
unset PANE_CWD

# H1-H6: every help form prints the usage of every subcommand on stdout and exits 0,
# touching nothing.
: > "$CALLS"
for form in "help" "-h" "--help" "dispatch --help" "collect xr-1-a -h" "apply --help"; do
  # shellcheck disable=SC2086
  out="$(bash "$XREVIEW" $form 2>"$ROOT/help-err")"; rc=$?
  missing=""
  # Each needle is the start of its own usage line: two spaces of indent, then the command
  # word and its arguments. A bare "thread" would also match the "tier [thread]" line.
  for sub in "dispatch --checkpoint spec|plan|pre-merge" "collect <nonce>" "apply <nonce>" \
             "apply --done" "round [--reset]" "receipts [--tiers]" "tier [thread]" "thread  " \
             "init [id]" "help, -h, --help"; do
    found=""
    while IFS= read -r line; do
      [[ $line == "  $sub"* ]] && found=1
    done <<< "$out"
    [ -n "$found" ] || missing="$missing [$sub]"
  done
  is "H xreview $form exits 0 with every subcommand's usage on stdout and nothing on stderr" \
     "$rc/${missing:-all}/$(wc -c < "$ROOT/help-err" | tr -d ' ')" "0/all/0"
done
is "H7 no help form called herdr, the daemon or the reviewer" "$(wc -c < "$CALLS" | tr -d ' ')" 0

# P1-P2: xreview runs outside the sandbox, so a jq or git reached through a mise shim (whose
# repository mise.toml an agent can edit) or anything else on the caller's PATH must not run.
HOSTILE="$ROOT/hostile"; mkdir -p "$HOSTILE" "$ROOT/hosthome"
for t in jq git herdr python3; do
  printf '#!/bin/sh\necho %s >> "%s/hostile-marker"\nexit 0\n' "$t" "$ROOT" > "$HOSTILE/$t"; chmod 755 "$HOSTILE/$t"
done
# bash itself is on the hostile list, and xreview runs as an executable, the way the Bash
# tool runs an excluded command: its shebang must not resolve bash through PATH.
printf '#!/bin/sh\necho bash >> "%s/hostile-marker"\nexit 0\n' "$ROOT" > "$HOSTILE/bash"; chmod 755 "$HOSTILE/bash"
cp "$XREVIEW" "$ROOT/xreview-exec"; chmod 755 "$ROOT/xreview-exec"
out="$( (unset PINNED_PATH; HOME="$ROOT/hosthome" PATH="$HOSTILE:$PATH" "$ROOT/xreview-exec" round) 2>&1)"
is "P1 xreview round runs with a hostile PATH (bash included) and no PINNED_PATH" "$( [ -e "$ROOT/hostile-marker" ] && cat "$ROOT/hostile-marker" | tr '\n' ' ' || echo clean)" clean
is "P2 and still answers" "$(printf '%s' "$out" | grep -c '^[0-9]')" 1

echo "AP. xreview apply runs no command from the repository's configuration"
# apply runs unsandboxed and the repository's configuration is writable from the sandbox: a
# worktree or index diff would run core.fsmonitor and every clean filter. Each writes its own
# marker; the scope must still list the changed files.
HR="$ROOT/hostile-repo"; HM="$ROOT/hostile-marks"; mkdir -p "$HR" "$HM"
printf '#!/bin/sh\ntouch "%s/fsmonitor"\n' "$HM" > "$ROOT/evil-fsmonitor"; chmod +x "$ROOT/evil-fsmonitor"
printf '#!/bin/sh\ntouch "%s/clean"\ncat\n' "$HM" > "$ROOT/evil-clean"; chmod +x "$ROOT/evil-clean"
printf '#!/bin/sh\ntouch "%s/process"\n' "$HM" > "$ROOT/evil-process"; chmod +x "$ROOT/evil-process"
git -C "$HR" init -q -b main && git -C "$HR" config user.email t@t && git -C "$HR" config user.name t
git -C "$HR" config commit.gpgsign false
printf '* filter=m\n' > "$HR/.gitattributes"; printf 'one\n' > "$HR/a.txt"
git -C "$HR" add . && git -C "$HR" commit -q -m init
git -C "$HR" switch -q -c feat; printf 'two\n' > "$HR/b.txt"
git -C "$HR" add b.txt && git -C "$HR" commit -q -m "add b"
printf 'edited\n' > "$HR/a.txt"; printf 'staged\n' > "$HR/c.txt"; git -C "$HR" add c.txt
git -C "$HR" config core.fsmonitor "$ROOT/evil-fsmonitor"
git -C "$HR" config filter.m.clean "$ROOT/evil-clean"
git -C "$HR" config filter.m.process "$ROOT/evil-process"
# A tracked file whose stat changed but not its content makes the worktree diff refresh the
# index and write it back, which runs core.hooksPath's post-index-change and, on git 2.54 and
# later, every hook.<name>.command whose event is post-index-change (core.hooksPath=/dev/null
# does not switch those off). Each source writes its own marker.
mkdir -p "$ROOT/evil-hooks"
printf '#!/bin/sh\ntouch "%s/hook"\n' "$HM" > "$ROOT/evil-hooks/post-index-change"
chmod +x "$ROOT/evil-hooks/post-index-change"
git -C "$HR" config core.hooksPath "$ROOT/evil-hooks"
printf '#!/bin/sh\ntouch "%s/confighook"\n' "$HM" > "$ROOT/evil-confighook"; chmod +x "$ROOT/evil-confighook"
git -C "$HR" config hook.evil.command "$ROOT/evil-confighook"
git -C "$HR" config hook.evil.event post-index-change
touch -t 200001010000 "$HR/b.txt"
rm -f "$HM"/*
out="$(cd "$HR" && bash "$XREVIEW" apply xr-s1 2>&1)"; rc=$?
applying="$(cat "$XDG_STATE_HOME/xreview/$(git -C "$HR" rev-parse --show-toplevel | tr '/' '_' | sed 's/^_//')/applying" 2>/dev/null)"
is "AP1 apply succeeds in a repository whose configuration names commands" "$rc" 0
is "AP2 and the scope lists the commit, worktree and index changes" \
   "$(printf '%s' "$applying" | grep '^file=' | tr '\n' ' ')" "file=a.txt file=b.txt file=c.txt "
is "AP3 neither core.fsmonitor nor a filter ran" "$(ls "$HM" | grep -v '^\(hook\|confighook\)$' | tr '\n' ' ')" ""
is "AP4 and no hook from core.hooksPath ran (the index refresh writes it back)" "$(ls "$HM" | grep -c '^hook$')" 0
is "AP4b and no hook.<name>.command for post-index-change ran" "$(ls "$HM" | grep -c '^confighook$')" 0
(cd "$HR" && bash "$XREVIEW" apply --done >/dev/null 2>&1)
# The scope count prints once: grep -c prints 0 and exits 1 on an empty scope, and a fallback
# of its own used to add a second 0.
ER="$ROOT/empty-repo"; mkdir -p "$ER"
git -C "$ER" init -q -b main && git -C "$ER" config user.email t@t && git -C "$ER" config user.name t
git -C "$ER" config commit.gpgsign false
printf 'one\n' > "$ER/a.txt"; git -C "$ER" add . && git -C "$ER" commit -q -m init
out="$(cd "$ER" && bash "$XREVIEW" apply xr-e1 2>&1)"
is "AP5 an empty scope is reported on one line, as 0 files" "$out" "xreview: apply window open for xr-e1 (0 files in scope)"
(cd "$ER" && bash "$XREVIEW" apply --done >/dev/null 2>&1)
# Driver names git cannot take through "-c key=value": git splits that at its first "=", so a
# driver named "x=y" would set the key "filter.x" and leave "filter.x=y.clean" configured; a
# dot inside the name must not shift where the name ends either. Each driver names a marker
# command, and its file is stat-dirty, so the index refresh would run the clean filter.
OR="$ROOT/odd-repo"; OM="$ROOT/odd-marks"; mkdir -p "$OR" "$OM"
git -C "$OR" init -q -b main && git -C "$OR" config user.email t@t && git -C "$OR" config user.name t
git -C "$OR" config commit.gpgsign false
printf 'base\n' > "$OR/base.txt"; git -C "$OR" add . && git -C "$OR" commit -q -m init
git -C "$OR" switch -q -c feat
printf 'x.txt filter=x=y\neq.txt filter=x=\ndot.txt filter=a.b\n' > "$OR/.gitattributes"
printf 'one\n' > "$OR/x.txt"; printf 'one\n' > "$OR/eq.txt"; printf 'one\n' > "$OR/dot.txt"
git -C "$OR" add . && git -C "$OR" commit -q -m "add files"
for n in 'x=y' 'x=' 'a.b'; do
  safe="$(printf '%s' "$n" | tr -c 'A-Za-z0-9' '_')"
  printf '#!/bin/sh\ntouch "%s/clean-%s"\ncat\n' "$OM" "$safe" > "$ROOT/odd-clean-$safe"
  chmod +x "$ROOT/odd-clean-$safe"
  git -C "$OR" config "filter.$n.clean" "$ROOT/odd-clean-$safe"
done
touch -t 200001010000 "$OR/x.txt" "$OR/eq.txt" "$OR/dot.txt"
rm -f "$OM"/*
out="$(cd "$OR" && bash "$XREVIEW" apply xr-o1 2>&1)"; rc=$?
applying="$(cat "$XDG_STATE_HOME/xreview/$(git -C "$OR" rev-parse --show-toplevel | tr '/' '_' | sed 's/^_//')/applying" 2>/dev/null)"
is "AP6 apply succeeds with drivers named x=y, x= and a.b" "$rc" 0
is "AP7 no clean filter ran, whatever its driver is called" "$(ls "$OM" | tr '\n' ' ')" ""
is "AP8 and the scope still lists the files" \
   "$(printf '%s' "$applying" | grep '^file=' | tr '\n' ' ')" "file=.gitattributes file=dot.txt file=eq.txt file=x.txt "
# Command-line-style overrides already in the environment must not reach the diffs: git reads
# GIT_CONFIG_PARAMETERS after GIT_CONFIG_KEY_n/VALUE_n, so an inherited one would win over ours,
# and bash reads GIT_CONFIG_COUNT=010 as octal, which misnumbered our pairs and lost the first.
printf '#!/bin/sh\ntouch "%s/fsmonitor"\n' "$OM" > "$ROOT/odd-fsmonitor"; chmod +x "$ROOT/odd-fsmonitor"
git -C "$OR" config core.fsmonitor "$ROOT/odd-fsmonitor"
rm -f "$OM"/*
out="$(cd "$OR" && bash "$XREVIEW" apply xr-o0 2>&1)"; rc=$?
is "AP9 the fixture's own core.fsmonitor is switched off" "$rc/$(ls "$OM" | tr '\n' ' ')" "0/"
printf '#!/bin/sh\ntouch "%s/inherited-fsmonitor"\n' "$OM" > "$ROOT/odd-inherited-fsmonitor"; chmod +x "$ROOT/odd-inherited-fsmonitor"
rm -f "$OM"/*
out="$(cd "$OR" && GIT_CONFIG_PARAMETERS="'core.fsmonitor=$ROOT/odd-inherited-fsmonitor'" bash "$XREVIEW" apply xr-o2 2>&1)"; rc=$?
applying="$(cat "$XDG_STATE_HOME/xreview/$(git -C "$OR" rev-parse --show-toplevel | tr '/' '_' | sed 's/^_//')/applying" 2>/dev/null)"
is "AP10 an inherited GIT_CONFIG_PARAMETERS naming a core.fsmonitor does not run it" "$rc/$(ls "$OM" | tr '\n' ' ')" "0/"
is "AP10b and the scope still lists the files" "$(printf '%s' "$applying" | grep -c '^file=')" 4
rm -f "$OM"/*
out="$(cd "$OR" && env GIT_CONFIG_COUNT=010 GIT_CONFIG_KEY_0=core.abbrev GIT_CONFIG_VALUE_0=7 \
  GIT_CONFIG_KEY_1=core.abbrev GIT_CONFIG_VALUE_1=7 GIT_CONFIG_KEY_2=core.abbrev GIT_CONFIG_VALUE_2=7 \
  GIT_CONFIG_KEY_3=core.abbrev GIT_CONFIG_VALUE_3=7 GIT_CONFIG_KEY_4=core.abbrev GIT_CONFIG_VALUE_4=7 \
  GIT_CONFIG_KEY_5=core.abbrev GIT_CONFIG_VALUE_5=7 GIT_CONFIG_KEY_6=core.abbrev GIT_CONFIG_VALUE_6=7 \
  GIT_CONFIG_KEY_7=core.abbrev GIT_CONFIG_VALUE_7=7 GIT_CONFIG_KEY_8=core.abbrev GIT_CONFIG_VALUE_8=7 \
  GIT_CONFIG_KEY_9=core.abbrev GIT_CONFIG_VALUE_9=7 \
  bash "$XREVIEW" apply xr-o3 2>&1)"; rc=$?
applying="$(cat "$XDG_STATE_HOME/xreview/$(git -C "$OR" rev-parse --show-toplevel | tr '/' '_' | sed 's/^_//')/applying" 2>/dev/null)"
is "AP11 an inherited GIT_CONFIG_COUNT=010 with pairs does not lose the fsmonitor override" "$rc/$(ls "$OM" | tr '\n' ' ')" "0/"
is "AP11b and the scope still lists the files" "$(printf '%s' "$applying" | grep -c '^file=')" 4
(cd "$OR" && bash "$XREVIEW" apply --done >/dev/null 2>&1)

echo "AL. xreview apply never lazy-fetches from a partial clone's remote"
# A blob-filtered partial clone fetches a missing blob on demand, and that runs the remote's
# uploadpack command, which the repository's configuration names (writable from the sandbox).
# The range holds a rename with an edit, so rename detection would read both blobs, neither of
# them local. The marker is what the uploadpack command leaves; the scope must still list the
# renamed paths (apply fails closed on the blob, never on the paths: --no-renames lists both).
LO="$ROOT/lazy-origin"; LC="$ROOT/lazy-clone"; LM="$ROOT/lazy-marks"; mkdir -p "$LO" "$LM"
git -C "$LO" init -q -b main && git -C "$LO" config user.email t@t && git -C "$LO" config user.name t
git -C "$LO" config commit.gpgsign false && git -C "$LO" config uploadpack.allowFilter true
git -C "$LO" config uploadpack.allowAnySHA1InWant true
seq 1 40 > "$LO/old.txt"; git -C "$LO" add . && git -C "$LO" commit -q -m init
git -C "$LO" switch -q -c feat; git -C "$LO" mv old.txt new.txt; echo extra >> "$LO/new.txt"
git -C "$LO" add -A && git -C "$LO" commit -q -m "rename and edit"; git -C "$LO" switch -q main
git clone -q --no-checkout --filter=blob:none "file://$LO" "$LC" 2>/dev/null
git -C "$LC" config user.email t@t; git -C "$LC" config user.name t
git -C "$LC" update-ref refs/heads/feat refs/remotes/origin/feat
git -C "$LC" symbolic-ref HEAD refs/heads/feat; git -C "$LC" read-tree HEAD
printf '#!/bin/sh\ntouch "%s/uploadpack"\nexec git upload-pack "$@"\n' "$LM" > "$ROOT/evil-uploadpack"
chmod +x "$ROOT/evil-uploadpack"; git -C "$LC" config remote.origin.uploadpack "$ROOT/evil-uploadpack"
is "AL0 the fixture is a blob-filtered partial clone with the blob missing" \
   "$(git -C "$LC" config remote.origin.partialclonefilter) $(GIT_NO_LAZY_FETCH=1 git -C "$LC" cat-file -e "$(git -C "$LO" rev-parse feat:new.txt)" 2>/dev/null; echo $?)" "blob:none 1"
rm -f "$LM"/*
out="$(cd "$LC" && bash "$XREVIEW" apply xr-l1 2>&1)"; rc=$?
applying="$(cat "$XDG_STATE_HOME/xreview/$(git -C "$LC" rev-parse --show-toplevel | tr '/' '_' | sed 's/^_//')/applying" 2>/dev/null)"
is "AL1 apply succeeds in the partial clone" "$rc" 0
is "AL2 the remote's uploadpack never ran" "$(ls "$LM" | tr '\n' ' ')" ""
is "AL3 and the scope lists both sides of the rename" \
   "$(printf '%s' "$applying" | grep '^file=\(old\|new\).txt$' | tr '\n' ' ')" "file=new.txt file=old.txt "
(cd "$LC" && bash "$XREVIEW" apply --done >/dev/null 2>&1)
# Resolving origin/HEAD needs no lazy fetch in the fixture above, since the rename is gone
# (--no-renames), so the export itself was never exercised. A symbolic origin/HEAD that names
# a missing commit makes "merge-base HEAD origin/HEAD" fetch it, which runs the uploadpack.
LD="$ROOT/lazy-dangling"; DM="$ROOT/lazy-dangling-marks"; mkdir -p "$DM"
git clone -q --no-checkout --filter=blob:none "file://$LO" "$LD" 2>/dev/null
git -C "$LD" config user.email t@t; git -C "$LD" config user.name t
git -C "$LD" config remote.origin.uploadpack "$ROOT/evil-uploadpack-dangling"
printf '#!/bin/sh\ntouch "%s/uploadpack"\nexec git upload-pack "$@"\n' "$DM" > "$ROOT/evil-uploadpack-dangling"
chmod +x "$ROOT/evil-uploadpack-dangling"
printf '%s\n' 0123456789abcdef0123456789abcdef01234567 > "$LD/.git/refs/remotes/origin/gone"
git -C "$LD" symbolic-ref refs/remotes/origin/HEAD refs/remotes/origin/gone
is "AL4 the fixture's origin/HEAD names a commit that is not there" \
   "$(GIT_NO_LAZY_FETCH=1 git -C "$LD" cat-file -e 0123456789abcdef0123456789abcdef01234567 2>/dev/null; echo $?)" 1
rm -f "$DM"/*
out="$(cd "$LD" && bash "$XREVIEW" apply xr-l2 2>&1)"; rc=$?
is "AL5 apply succeeds with a dangling origin/HEAD" "$rc" 0
is "AL6 and the remote's uploadpack never ran" "$(ls "$DM" | tr '\n' ' ')" ""
(cd "$LD" && bash "$XREVIEW" apply --done >/dev/null 2>&1)


echo "X. review packets: the dispatch asks the packet module (spec 2026-10-25 §3.2, §3.3, §3.8)"
# A rollout is where the module reads a thread's context and its window from. U2 holds the
# checkpoint's context; the window of every other rollout stands for a fresh thread's.
rollout() { # rollout <thread> <context tokens> <window>
  local d="$CODEX_HOME/sessions/2026/10/25"; mkdir -p "$d"
  printf '{"type":"event_msg","payload":{"type":"task_started","model_context_window":%s}}\n' "$3" \
    > "$d/rollout-2026-10-25T00-00-00-$1.jsonl"
  printf '{"type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"total_tokens":%s},"model_context_window":%s}}}\n' \
    "$2" "$3" >> "$d/rollout-2026-10-25T00-00-00-$1.jsonl"
}
xbranch() { git rev-parse --abbrev-ref HEAD; }
for n in 1 2 3; do seq 1 3000 | sed "s/^/file $n line /" > "big$n.txt"; done
git add big1.txt big2.txt big3.txt && git commit -q -m "three big files to review"
XD=(--diff HEAD~1..HEAD)
last_nonce() { ls -t "$STATE/turns" | grep -m1 '^xr-[0-9a-f-]*$'; }

fresh; packets framing fit; rm -rf "$CODEX_HOME/sessions"; rollout $U0 1000 258400
out="$(XREVIEW_MAX_DIFF_BYTES=10 bash "$XREVIEW" dispatch --checkpoint plan "${XD[@]}" b.md 2>&1)"; rc=$?
nonce="$(printf '%s' "$out" | grep -m1 '^xr-')"
is "N1 fit and framing on: a diff over the cap is sent, not refused" "$rc/$(printf '%s' "$out" | grep -c 'too large')" "0/0"
is "N1 and it has a nonce and a turn" "$(called 'xreview-rpc turn-start')/$([ -n "$nonce" ] && echo yes)" "1/yes"
is "N1 the packet carries the framing and the file list" \
   "$(grep -c 'Files in this change (3):' "$P/packet")/$(grep -c '^  shown ' "$P/packet")" "1/3"
is "N1 the framed schema is what the turn is held to" \
   "$(grep 'xreview-rpc turn-start' "$CALLS" | grep -c 'findings.framed.schema.json')" 1
is "N1 a first dispatch starts the thread and writes it down" \
   "$(called 'xreview-rpc thread-start')/$(cat "$STATE/review-thread")" "1/$U1"
is "N1 the packet files are gone once the turn has started" "$(ls -d "$STATE/turns/$nonce.packets" 2>/dev/null | wc -l | tr -d ' ')" 0
labels="$(cat "$STATE/turns/$nonce.shown")"
is "N1 .shown lists the labels, one per line" "$(printf '%s\n' "$labels" | tr '\n' ' ')" "big1.txt big2.txt big3.txt "

echo "X4. .targets carries the switches and each target's packet fields"
doc="$STATE/turns/$nonce.targets"
is "N4 the receipt-level switches" "$(jq -c '.switches' "$doc")" '{"framing":true,"fit":true,"delta":false,"omit_plans":false}'
is "N4 each target's packet" "$(jq -r '.targets[0] | "\(.packet) \(.delta_from) \(.history) \(.plans_from | length)"' "$doc")" "full null null 0"
is "N4 and the target's own fields are kept" "$(jq -r '.targets[0] | [.repo, .base, .tip] | map(type) | join(",")' "$doc")" "string,string,string"

echo "X5. a refusal comes before the pane is touched"
fresh; packets framing fit; rm -rf "$CODEX_HOME/sessions"
out="$(bash "$XREVIEW" dispatch --checkpoint plan "${XD[@]}" b.md 2>&1)"; rc=$?
is "N5 a window nobody can read refuses" "$rc/$(printf '%s' "$out" | grep -c "cannot read the model's context window")" "1/1"
is "N5 untouched" "$(untouched)" yes
is "N5 no thread was started for it" "$(called 'xreview-rpc thread-start')" 0
is "N5 and no round consumed" "$(bash "$XREVIEW" round)" 0
fresh; packets framing; out="$(XREVIEW_MAX_DIFF_BYTES=10 bash "$XREVIEW" dispatch --checkpoint plan "${XD[@]}" b.md 2>&1)"; rc=$?
is "N5 framing with the fit check off keeps the cap, in today's words" \
   "$rc/$(printf '%s' "$out" | grep -c 'too large to carry inline')/$(printf '%s' "$out" | grep -c 'Review them in slices, or raise XREVIEW_MAX_DIFF_BYTES')" "1/1/1"
is "N5 untouched here too" "$(untouched)" yes
fresh
out="$(XREVIEW_MAX_DIFF_BYTES=12x bash "$XREVIEW" dispatch --checkpoint plan "${XD[@]}" b.md 2>&1)"; rc=$?
is "N5 a garbage XREVIEW_MAX_DIFF_BYTES is refused, naming it" "$rc/$(printf '%s' "$out" | grep -c "not '12x'")/$(untouched)" "1/1/yes"
fresh; printf '%s\n' "$U2" > "$STATE/review-thread"
out="$(XREVIEW_PACKET="$ROOT/does-not-exist.py" bash "$XREVIEW" dispatch --checkpoint plan "${XD[@]}" b.md 2>&1)"; rc=$?
is "N5 a module that fails is a refusal" "$rc/$(printf '%s' "$out" | grep -c 'cannot build the review packet')" "1/1"
is "N5 and nothing was touched" "$(untouched)/$(called 'xreview-rpc thread-start')" "yes/0"

echo "X2. a thread that cannot hold the packet: the checkpoint moves to a fresh thread"
fresh; packets framing fit; rm -rf "$CODEX_HOME/sessions"; rollout $U2 250000 258400
printf '%s\n' "$U2" > "$STATE/review-thread"; mkdir -p "$STATE"; printf '%s=3\n' "$(xbranch)" > "$STATE/rounds"
NO_TITLE=1 bash "$XREVIEW" dispatch --checkpoint plan "${XD[@]}" b.md > "$ROOT/o" 2>&1; rc=$?
is "N2 the dispatch succeeds" "$rc" 0
is "N2 a new thread was started" "$(called 'xreview-rpc thread-start')" 1
is "N2 the turn runs on it, not on the old one" \
   "$(grep 'xreview-rpc turn-start' "$CALLS" | grep -c -- "--thread $U1")/$(grep 'xreview-rpc turn-start' "$CALLS" | grep -c -- "--thread $U2")" "1/0"
is "N2 it is the checkpoint's thread now" "$(cat "$STATE/review-thread")" "$U1"
is "N2 the old thread is queued as superseded (the pane could not follow, so it waits)" "$(cat "$STATE/superseded")" "$U2"
is "N2 the round counter carries on" "$(bash "$XREVIEW" round)" 4
fresh; packets framing fit; rm -rf "$CODEX_HOME/sessions"; rollout $U2 250000 258400
printf '%s\n' "$U2" > "$STATE/review-thread"
bash "$XREVIEW" dispatch --checkpoint plan "${XD[@]}" b.md > "$ROOT/o" 2>&1; rc=$?
is "N2 the pane is resumed onto the new thread" "$(resumed $U1)" 1
is "N2 and the old thread is archived once it shows it" "$(called "xreview-rpc thread-archive --thread $U2")/$([ -e "$STATE/superseded" ] && echo left || echo gone)" "1/gone"
is "N2 the turn starts before the pane is resumed" \
   "$([ "$(first 'xreview-rpc turn-start')" -lt "$(first "herdr pane run w1:p2 $PANE_CMD")" ] && echo yes || echo no)" yes
is "N2 no keystroke after the turn exists (C1)" "$(none_after 'xreview-rpc turn-start' 'herdr pane send-keys')" 0
is "N2 the pane is freed before the turn" \
   "$([ "$(first 'herdr pane send-keys')" -lt "$(first 'xreview-rpc turn-start')" ] && echo yes || echo no)" yes
fresh; packets framing fit; rm -rf "$CODEX_HOME/sessions"; rollout $U2 20000 258400
printf '%s\n' "$U2" > "$STATE/review-thread"
bash "$XREVIEW" dispatch --checkpoint plan "${XD[@]}" b.md > "$ROOT/o" 2>&1
is "N2 a thread that holds the packet is kept: no new thread, the turn runs on it" \
   "$(called 'xreview-rpc thread-start')/$(grep 'xreview-rpc turn-start' "$CALLS" | grep -c -- "--thread $U2")" "0/1"
fresh; packets framing fit; rm -rf "$CODEX_HOME/sessions"; rollout $U2 20000 258400
printf '%s\n' "$U2" > "$STATE/pin"
bash "$XREVIEW" dispatch --checkpoint plan "${XD[@]}" b.md > "$ROOT/o" 2>&1
is "N2 (control) a pinned thread that fits is used as it is" "$(grep 'xreview-rpc turn-start' "$CALLS" | grep -c -- "--thread $U2")" 1
for kind in pin env; do
  fresh; packets framing fit; rm -rf "$CODEX_HOME/sessions"; rollout $U2 250000 258400
  if [ "$kind" = pin ]; then printf '%s\n' "$U2" > "$STATE/pin"; out="$(bash "$XREVIEW" dispatch --checkpoint plan "${XD[@]}" b.md 2>&1)"; rc=$?
  else out="$(XREVIEW_THREAD=$U2 bash "$XREVIEW" dispatch --checkpoint plan "${XD[@]}" b.md 2>&1)"; rc=$?; fi
  is "N2 a $kind thread that cannot hold the packet is refused, naming it" "$rc/$(printf '%s' "$out" | grep -c -- "$U2 .*cannot hold this packet")" "1/1"
  is "N2 and the remedy is named ($kind)" \
     "$(printf '%s' "$out" | grep -c "$([ "$kind" = pin ] && echo 'round --reset' || echo 'unset XREVIEW_THREAD')")" 1
  is "N2 untouched, no thread started, nothing superseded ($kind)" \
     "$(untouched)/$(called 'xreview-rpc thread-start')/$([ -e "$STATE/superseded" ] && echo left || echo none)" "yes/0/none"
done

echo "X3. a packet too big even for a fresh thread: dispatch starts slice 1 only"
fresh; packets framing fit; rm -rf "$CODEX_HOME/sessions"; rollout $U0 1000 110000
out="$(bash "$XREVIEW" dispatch --checkpoint plan "${XD[@]}" b.md 2>&1)"; rc=$?
nonce="$(printf '%s' "$out" | grep -m1 '^xr-')"
is "N3 the dispatch succeeds and prints a nonce" "$rc/$([ -n "$nonce" ] && echo yes)" "0/yes"
is "N3 one turn, on one new thread" "$(called 'xreview-rpc turn-start')/$(called 'xreview-rpc thread-start')" "1/1"
sl="$STATE/turns/$nonce.slices"
is "N3 .slices names every slice, next 1, and slice 1's thread" \
   "$(jq -r '"\(.packets | length > 1) \(.next) \(.threads | join(",")) \(.turns | length)"' "$sl")" "true 1 $U1 1"
is "N3 the packet files outlive the dispatch, for collect" \
   "$(for f in $(jq -r '.packets[].file' "$sl"); do [ -s "$f" ] || echo missing; done | wc -l | tr -d ' ')" 0
is "N3 the turn sent slice 1" "$(grep -c 'This is slice 1 of' "$P/packet")" 1
is "N3 .shown holds slice 1's labels" "$(cat "$STATE/turns/$nonce.shown")" "$(jq -r '.packets[0].shown[]' "$sl")"
is "N3 .targets says the packet was sliced" "$(jq -r '.targets[0].packet' "$STATE/turns/$nonce.targets")" slices
is "N3 the sent packet is the first of them" "$(cmp -s "$P/packet" "$(jq -r '.packets[0].file' "$sl")" && echo same)" same

echo "X6. the history, the labels missed last round, duplicate targets and ignored switches"
fresh; packets framing fit delta; rm -rf "$CODEX_HOME/sessions"; rollout $U2 20000 258400; printf '%s\n' "$U2" > "$STATE/review-thread"
bash "$XREVIEW" dispatch --checkpoint plan "${XD[@]}" b.md > "$ROOT/o" 2>&1
is "thread-turns is not asked at a plan checkpoint, even with delta in force" "$(called 'xreview-rpc thread-turns')" 0
fresh; packets framing fit delta; rm -rf "$CODEX_HOME/sessions"; rollout $U2 20000 258400; printf '%s\n' "$U2" > "$STATE/review-thread"
bash "$XREVIEW" dispatch --checkpoint pre-merge "${XD[@]}" b.md > "$ROOT/o" 2>&1
is "thread-turns is asked for the checkpoint's thread at pre-merge when delta is in force" "$(called "xreview-rpc thread-turns --thread $U2")" 1
is "and it is asked before the pane is looked at (the window to the ctrl+c stays short)" \
   "$([ "$(first 'codex-daemon ensure')" -lt "$(first 'xreview-rpc thread-turns')" ] && [ "$(first 'xreview-rpc thread-turns')" -lt "$(first 'herdr pane')" ] && echo yes || echo no)" yes
fresh; packets framing fit; rm -rf "$CODEX_HOME/sessions"; rollout $U2 250000 258400; printf '%s\n' "$U2" > "$STATE/review-thread"
bash "$XREVIEW" dispatch --checkpoint plan "${XD[@]}" b.md > "$ROOT/o" 2>&1
is "the packet is decided before the pane is looked at, and a thread started only after it" \
   "$([ "$(first 'codex-daemon ensure')" -lt "$(first 'herdr pane')" ] && [ "$(first 'herdr pane')" -lt "$(first 'xreview-rpc thread-start')" ] && echo yes || echo no)" yes
fresh;for sw in "" "framing fit" "fit delta"; do
  fresh; packets $sw; rm -rf "$CODEX_HOME/sessions"; printf '%s\n' "$U2" > "$STATE/review-thread"
  bash "$XREVIEW" dispatch --checkpoint plan b.md > "$ROOT/o" 2>&1
  is "thread-turns is not asked with switches [${sw:-none}]: delta is not in force" "$(called 'xreview-rpc thread-turns')" 0
done
fresh; packets framing fit delta; rm -rf "$CODEX_HOME/sessions"; rollout $U2 20000 258400; printf '%s\n' "$U2" > "$STATE/review-thread"
RPC_TURNS_FAIL=1 bash "$XREVIEW" dispatch --checkpoint plan "${XD[@]}" b.md > "$ROOT/o" 2>&1; rc=$?
is "a thread whose turns cannot be listed is not a refusal" "$rc/$(called 'xreview-rpc turn-start')" "0/1"
fresh; packets framing fit; rm -rf "$CODEX_HOME/sessions"; rollout $U2 20000 258400; printf '%s\n' "$U2" > "$STATE/review-thread"
mkdir -p "$STATE"; printf 'big2.txt\nbig3.txt\n' > "$STATE/missed"
bash "$XREVIEW" dispatch --checkpoint plan "${XD[@]}" b.md > "$ROOT/o" 2>&1
is "the labels the last reviewer did not list go into the packet" "$(grep -c 'did not list: big2.txt, big3.txt' "$P/packet")" 1
is "and the file is spent once the turn has started" "$([ -e "$STATE/missed" ] && echo left || echo gone)" gone
fresh; packets framing fit; rm -rf "$CODEX_HOME/sessions"; rollout $U0 1000 258400
nonce="$(bash "$XREVIEW" dispatch --checkpoint plan "${XD[@]}" --diff HEAD~1..HEAD --diff .:HEAD~1..HEAD b.md 2>/dev/null | grep -m1 '^xr-')"
is "a range named twice is one target" "$(jq '.targets | length' "$STATE/turns/$nonce.targets")" 1
fresh; packets fit delta; out="$(bash "$XREVIEW" dispatch --checkpoint plan b.md 2>&1)"
is "switches that need framing are named once, and stay off" \
   "$(printf '%s' "$out" | grep -c 'packets.conf turns on fit, delta, which need framing')/$(grep -c 'Files in this change' "$P/packet")" "1/0"
fresh; packets; out="$(bash "$XREVIEW" dispatch --checkpoint plan b.md 2>&1)"
is "with every switch off there is nothing to say" "$(printf '%s' "$out" | grep -c 'packets.conf')" 0
is "with every switch off the schema is today's" \
   "$(grep 'xreview-rpc turn-start' "$CALLS" | grep -c 'findings.schema.json')" 1
packets


echo "X7. every switch off: a refusal for size is the first thing, as it always was"
for variant in plain thread_running rounds; do
  fresh; packets; printf '%s\n' "$U2" > "$STATE/review-thread"
  case "$variant" in
    plain) out="$(XREVIEW_MAX_DIFF_BYTES=10 bash "$XREVIEW" dispatch --checkpoint plan "${XD[@]}" b.md 2>&1)"; rc=$? ;;
    thread_running) out="$(RPC_THREAD_RUNNING=1 XREVIEW_MAX_DIFF_BYTES=10 bash "$XREVIEW" dispatch --checkpoint plan "${XD[@]}" b.md 2>&1)"; rc=$? ;;
    rounds) out="$(ENSURE_RC=1 XREVIEW_MAX_ROUNDS=0 XREVIEW_MAX_DIFF_BYTES=10 bash "$XREVIEW" dispatch --checkpoint plan "${XD[@]}" b.md 2>&1)"; rc=$? ;;
  esac
  is "X7 $variant: the size refusal, in today's words" "$rc/$(printf '%s' "$out" | grep -c 'too large to carry inline')" "1/1"
  is "X7 $variant: no daemon, rpc or herdr call was made" "$(wc -c < "$CALLS" | tr -d ' ')" 0
  is "X7 $variant: no round consumed and no thread written" "$(bash "$XREVIEW" round)/$(cat "$STATE/review-thread")" "0/$U2"
done

echo "X8. a refusal after the packet is built leaves no state behind"
fresh; packets framing fit; rm -rf "$CODEX_HOME/sessions"; rollout $U2 250000 258400; printf '%s\n' "$U2" > "$STATE/review-thread"
out="$(RPC_STATUS_FAIL_FOR=$U1 bash "$XREVIEW" dispatch --checkpoint plan "${XD[@]}" b.md 2>&1)"; rc=$?
is "X8 a new thread whose state cannot be read refuses" "$rc/$(printf '%s' "$out" | grep -c 'cannot read whether the review thread')" "1/1"
is "X8 the checkpoint thread was not rewritten and nothing is superseded" \
   "$(cat "$STATE/review-thread")/$([ -e "$STATE/superseded" ] && echo left || echo none)" "$U2/none"
is "X8 no packet directory or targets file is left" "$(ls "$STATE/turns" 2>/dev/null | wc -l | tr -d ' ')" 0
is "X8 the pane was not touched" "$(untouched)" yes
fresh; packets framing fit; rm -rf "$CODEX_HOME/sessions"; rollout $U2 250000 258400; printf '%s\n' "$U2" > "$STATE/review-thread"
mkdir -p "$(dirname "$MAIN_LEDGER")" && mkdir "$MAIN_LEDGER.lock"
out="$(XREVIEW_LEDGER_LOCK_WAIT=0.2 bash "$XREVIEW" dispatch --checkpoint pre-merge "${XD[@]}" b.md 2>&1)"; rc=$?
rmdir "$MAIN_LEDGER.lock"
is "X8 a refused pending entry refuses the dispatch" "$rc/$(printf '%s' "$out" | grep -c 'cannot record the pending review')" "1/1"
is "X8 the checkpoint thread was not rewritten and nothing is superseded" \
   "$(cat "$STATE/review-thread")/$([ -e "$STATE/superseded" ] && echo left || echo none)" "$U2/none"
is "X8 no packet directory or targets file is left" "$(ls "$STATE/turns" 2>/dev/null | wc -l | tr -d ' ')" 0
is "X8 the thread started for it is archived, not kept" "$(called "xreview-rpc thread-archive --thread $U1")" 1
is "X8 and the pane was not touched" "$(untouched)" yes

echo "X9. the ledger entries carry the dispatch's switches"
fresh; packets framing fit; rm -rf "$CODEX_HOME/sessions"; rollout $U0 1000 258400
nonce="$(bash "$XREVIEW" dispatch --checkpoint pre-merge "${XD[@]}" b.md 2>/dev/null)"
RPC_WAIT_OUT='{"verdict":"approve","findings":[]}' bash "$XREVIEW" collect "$nonce" >/dev/null 2>&1
want='{"framing":true,"fit":true,"delta":false,"omit_plans":false}'
is "X9 the pending entry and the receipt both record the switches" \
   "$(jq -c --arg n "$nonce" 'select(.nonce == $n) | [.kind, .switches]' "$MAIN_LEDGER" | tr '\n' ' ')" \
   "[\"pending\",$want] [\"receipt\",$want] "
is "X9 and they equal the dispatch's own" "$(jq -c .switches "$STATE/turns/$nonce.targets")" "$want"
packets

echo "Y. collect judges each turn clean or not, and records it (spec 2026-10-25 §3.6, §3.7)"
printf 'one\n' > cl1.txt; printf 'two\n' > cl2.txt
git add cl1.txt cl2.txt && git commit -q -m "two small files"
CLR="$(git rev-parse HEAD~1)..$(git rev-parse HEAD)"
BIGR="$(git rev-parse HEAD~2)..$(git rev-parse HEAD~1)"   # the three big files, another range on .
YB="$(git rev-parse --abbrev-ref HEAD)"
wait_for() { # wait_for <file>: until it exists, 60 s at most; says so when it gives up
  local k
  for k in $(seq 600); do [ -e "$1" ] && return 0; sleep 0.1; done
  printf '  (gave up after 60 s waiting for %s; the assertions that follow are void)\n' "$1"
  return 1
}
hold_lock() { # hold_lock <secs>: another dispatch takes the pane lock now and holds it that long
  rm -f "$ROOT/held"
  /usr/bin/python3 -c 'import fcntl,sys,time
f = open(sys.argv[1], "a"); fcntl.flock(f, fcntl.LOCK_EX); open(sys.argv[2], "w").close(); time.sleep(float(sys.argv[3]))' \
    "$LOCKF" "$ROOT/held" "$1" &
  holder=$!
  wait_for "$ROOT/held"
}
reports_left() { ls "$STATE/turns" 2>/dev/null | grep -c "^$1\.report" || true; }
receipt() { jq -c --arg n "$1" 'select(.nonce == $n and .kind == "receipt")' "${2:-$MAIN_LEDGER}"; }
framed() { # framed <verdict> <label>...: a framed answer that lists those labels
  local v="$1"; shift
  jq -nc --arg v "$v" '{verdict:$v, findings:[], reviewed_files:$ARGS.positional}' --args "$@"
}
framed_dispatch() { # framed_dispatch <checkpoint> [--diff ...]: framing and fit on, a first dispatch
  fresh; packets framing fit; rm -rf "$CODEX_HOME/sessions"; rollout $U0 1000 258400
  local cp="$1"; shift
  nonce="$(bash "$XREVIEW" dispatch --checkpoint "$cp" "$@" b.md 2>/dev/null)"
}

framed_dispatch pre-merge --diff "$CLR"
RPC_COMPACTED=true RPC_WAIT_OUT="$(framed approve cl1.txt cl2.txt)" bash "$XREVIEW" collect "$nonce" > "$ROOT/out" 2> "$ROOT/err"; rc=$?
is "CL1 a compacted turn with fit on prints the answer and exits 0" "$rc/$(jq -r .verdict "$ROOT/out")" "0/approve"
is "CL1 and says on stderr that it is not clean and why, and that the gate stays closed" \
   "$(cat "$ROOT/err")" "xreview: this review is not clean (compacted); the merge gate stays closed for it"
is "CL1 the receipt records the compaction and that it is not clean" \
   "$(receipt "$nonce" | jq -c '[.compacted, .clean, .targets[0].missing]')" '[true,false,[]]'
is "CL1 the wait used the framed schema and asked for a report of this collect's own" \
   "$(called "turn-wait --thread $U1 --turn turn-$U1 --budget 2700 --schema $XDG_CONFIG_HOME/xreview/findings.framed.schema.json --report $STATE/turns/$nonce\.report\.[0-9][0-9]*$")" 1
is "CL1 the report does not linger" "$(reports_left "$nonce")" 0

framed_dispatch pre-merge --diff "$CLR"
RPC_WAIT_OUT="$(framed changes cl1.txt)" bash "$XREVIEW" collect "$nonce" > "$ROOT/out" 2> "$ROOT/err"; rc=$?
is "CL2 a coverage gap with framing on prints the answer and exits 0" "$rc/$(jq -r .verdict "$ROOT/out")" "0/changes"
is "CL2 the notice names the labels missed" \
   "$(cat "$ROOT/err")" "xreview: this review is not clean (missed: cl2.txt); the merge gate stays closed for it"
is "CL2 the receipt: missing on the target, not compacted, not clean" \
   "$(receipt "$nonce" | jq -c '[.targets[0].missing, .compacted, .clean]')" '[["cl2.txt"],false,false]'
is "CL2 the labels missed wait for the next dispatch" "$(cat "$STATE/missed")" cl2.txt
rollout $U1 1000 258400
bash "$XREVIEW" dispatch --checkpoint pre-merge --diff "$CLR" b.md >/dev/null 2>&1
is "CL2 and the next dispatch's packet names them" "$(grep -c 'did not list: cl2.txt\.' "$P/packet")" 1

fresh; printf 'stale\n' > "$STATE/missed"
nonce="$(bash "$XREVIEW" dispatch --checkpoint pre-merge --diff "$CLR" b.md 2>/dev/null)"
printf 'stale\n' > "$STATE/missed"
RPC_WAIT_OUT='{"verdict":"approve","findings":[]}' bash "$XREVIEW" collect "$nonce" > "$ROOT/out" 2> "$ROOT/err"; rc=$?
r="$(receipt "$nonce")"
is "CL3 with every switch off the receipt still records compacted and clean" "$rc/$(printf '%s' "$r" | jq -c '[.compacted, .clean]')" "0/[false,true]"
is "CL3 with the switches, and each target's packet and empty missing list" \
   "$(printf '%s' "$r" | jq -c '[.switches, .targets[0].packet, .targets[0].missing]')" \
   '[{"framing":false,"fit":false,"delta":false,"omit_plans":false},"full",[]]'
is "CL3 and no notice" "$(cat "$ROOT/err")" ""
is "CL3 the wait used today's schema, with the report" \
   "$(called "--schema $XDG_CONFIG_HOME/xreview/findings.schema.json --report $STATE/turns/$nonce\.report\.[0-9]")" 1
is "CL3 nothing missed: the labels file is cleared" "$([ -e "$STATE/missed" ] && echo left || echo gone)" gone
fresh
nonce="$(bash "$XREVIEW" dispatch --checkpoint pre-merge --diff "$CLR" b.md 2>/dev/null)"
RPC_COMPACTED=true RPC_WAIT_OUT='{"verdict":"approve","findings":[]}' bash "$XREVIEW" collect "$nonce" > "$ROOT/out" 2> "$ROOT/err"; rc=$?
is "CL3b every switch off and compacted: not clean, but a full packet with fit off leaves the gate as it was" \
   "$rc/$(cat "$ROOT/err")" "0/xreview: this review is not clean (compacted); the merge gate is not affected (fit was off)"
is "CL3b recorded as such" "$(receipt "$nonce" | jq -c '[.compacted, .clean]')" '[true,false]'
fresh; packets framing
nonce="$(bash "$XREVIEW" dispatch --checkpoint pre-merge --diff "$CLR" b.md 2>/dev/null)"
RPC_WAIT_OUT="$(framed approve cl1.txt cl2.txt)" bash "$XREVIEW" collect "$nonce" > "$ROOT/out" 2> "$ROOT/err"; rc=$?
is "CL3c framing on, every shown label listed, no compaction: clean, no notice" \
   "$rc/$(receipt "$nonce" | jq -c '[.compacted, .clean, .targets[0].missing]')/$(cat "$ROOT/err")" "0/[false,true,[]]/"

framed_dispatch plan --diff "$CLR"
RPC_COMPACTED=null RPC_WAIT_OUT="$(framed approve cl1.txt cl2.txt)" bash "$XREVIEW" collect "$nonce" > "$ROOT/out" 2> "$ROOT/err"; rc=$?
is "CL4 a report that cannot tell records the compaction as unknown, never clean" \
   "$rc/$(receipt "$nonce" | jq -c '[.compacted, .clean]')" "0/[null,false]"
is "CL4 named as unknown; a plan review that is not clean binds no plan" \
   "$(cat "$ROOT/err")" "xreview: this review is not clean (compaction unknown); it binds no plan for later pre-merge reviews"
framed_dispatch plan --diff "$CLR"
RPC_REPORT_TURN=turn-other RPC_WAIT_OUT="$(framed approve cl1.txt cl2.txt)" bash "$XREVIEW" collect "$nonce" >/dev/null 2>&1
is "CL4b a report about another turn (a stale file) is no report: unknown" \
   "$(receipt "$nonce" | jq -c '[.compacted, .clean]')" "[null,false]"

framed_dispatch pre-merge --diff "$CLR"
seq 1 60 | sed 's/^/f/' > "$STATE/turns/$nonce.shown"
RPC_WAIT_OUT="$(framed approve f1)" bash "$XREVIEW" collect "$nonce" > "$ROOT/out" 2> "$ROOT/err"
is "CL5 a target records at most 50 missing labels, in shown order" \
   "$(receipt "$nonce" | jq -c '.targets[0].missing | [length, first, last]')" '[50,"f2","f51"]'
is "CL5 the next dispatch gets every one of them" "$(grep -c . "$STATE/missed")/$(tail -1 "$STATE/missed")" "59/f60"
is "CL5 the notice shows ten and counts the rest" "$(cat "$ROOT/err")" \
   "xreview: this review is not clean (missed: f2, f3, f4, f5, f6, f7, f8, f9, f10, f11 … (+49 more)); the merge gate stays closed for it"

framed_dispatch pre-merge --diff "$CLR"
RPC_WAIT_OUT="$(framed approve ./cl1.txt b/cl2.txt)" bash "$XREVIEW" collect "$nonce" > "$ROOT/out" 2> "$ROOT/err"
is "CL6 a listed label matches after a/, b/ and ./ are stripped" \
   "$(receipt "$nonce" | jq -c '[.clean, .targets[0].missing]')/$(cat "$ROOT/err")" "[true,[]]/"

framed_dispatch spec --diff "$CLR"
RPC_COMPACTED=true RPC_WAIT_OUT="$(framed approve cl1.txt)" bash "$XREVIEW" collect "$nonce" > "$ROOT/out" 2> "$ROOT/err"
is "CL7 both reasons, and a spec review names no consequence" \
   "$(cat "$ROOT/err")" "xreview: this review is not clean (compacted; missed: cl2.txt)"

framed_dispatch pre-merge --diff "$CLR" --diff "$V2:main...feature"
is "CL8 (setup) two targets, each label carrying its target's" "$(tr '\n' ' ' < "$STATE/turns/$nonce.shown")" ".:cl1.txt .:cl2.txt $V2:a.txt "
RPC_WAIT_OUT="$(framed approve .:cl1.txt .:cl2.txt)" bash "$XREVIEW" collect "$nonce" > "$ROOT/out" 2> "$ROOT/err"
is "CL8 each target records only its own missing labels" \
   "$(receipt "$nonce" | jq -c '.targets[0].missing')/$(receipt "$nonce" "$V2LEDGER" | jq -c '.targets[0].missing')" "[]/[\"$V2:a.txt\"]"
is "CL8 and the receipt in each ledger is not clean" \
   "$(receipt "$nonce" | jq -c .clean)/$(receipt "$nonce" "$V2LEDGER" | jq -c .clean)" "false/false"

# Two ranges of one repository both carry the prefix .: a label cannot be told apart by it, so
# every target it could belong to is held to it (fail closed), never just one of them.
framed_dispatch pre-merge --diff "$CLR" --diff "$BIGR"
is "CL8b (setup) two ranges on ., one prefix" "$(tr '\n' ' ' < "$STATE/turns/$nonce.shown")" \
   ".:cl1.txt .:cl2.txt .:big1.txt .:big2.txt .:big3.txt "
RPC_WAIT_OUT="$(framed approve .:cl1.txt .:big1.txt .:big2.txt .:big3.txt)" bash "$XREVIEW" collect "$nonce" > "$ROOT/out" 2> "$ROOT/err"
is "CL8b a label two targets' prefixes match equally is missing from both" \
   "$(receipt "$nonce" | jq -c '[.targets[].missing]')" '[[".:cl2.txt"],[".:cl2.txt"]]'

# With framing on, labels shown that cannot be read are no coverage at all: never clean.
framed_dispatch pre-merge --diff "$CLR"
rm -f "$STATE/turns/$nonce.shown"; printf 'stale\n' > "$STATE/missed"
RPC_WAIT_OUT="$(framed approve cl1.txt cl2.txt)" bash "$XREVIEW" collect "$nonce" > "$ROOT/out" 2> "$ROOT/err"; rc=$?
is "CL9 the shown labels gone: the answer is printed, exit 0" "$rc/$(jq -r .verdict "$ROOT/out")" "0/approve"
is "CL9 coverage cannot be judged, so the notice says so" \
   "$(cat "$ROOT/err")" "xreview: this review is not clean (coverage unknown); the merge gate stays closed for it"
is "CL9 not clean, and every target missing the fixed sentinel" \
   "$(receipt "$nonce" | jq -c '[.clean, .targets[0].missing]')" '[false,["(shown labels unreadable)"]]'
is "CL9 the sentinel never reaches the next dispatch" "$([ -e "$STATE/missed" ] && cat "$STATE/missed" || echo gone)" gone

# Two collects of one turn at once: the second one's report never replaces, or removes, the first's.
framed_dispatch pre-merge --diff "$CLR"
: > "$P/hold.turn-$U1"
RPC_WAIT_OUT="$(framed approve cl1.txt cl2.txt)" bash "$XREVIEW" collect "$nonce" > "$ROOT/outA" 2> "$ROOT/errA" &
first_collect=$!
wait_for "$P/waiting.turn-$U1"
RPC_WAIT_OUT="$(framed approve cl1.txt cl2.txt)" bash "$XREVIEW" collect "$nonce" > "$ROOT/outB" 2> "$ROOT/errB"; rcB=$?
rm -f "$P/holding.turn-$U1"
wait "$first_collect"; rcA=$?
is "CL10 a collect run while another waits on the same turn reads its own report" "$rcB/$(cat "$ROOT/errB")" "0/"
is "CL10 and the first, answering after it, still reads its own: no compaction unknown" "$rcA/$(cat "$ROOT/errA")" "0/"
is "CL10 neither report lingers" "$(reports_left "$nonce")" 0

echo "PB. a plan review records the plans its packet showed whole (spec 2026-10-25 §3.5)"
mkdir -p docs/superpowers/plans && printf '# plan\n' > docs/superpowers/plans/2026-10-25-p.md
git add docs && git commit -q -m "a plan"
PBR="$(git rev-parse HEAD~1)..$(git rev-parse HEAD)"
PBLOB="$(git rev-parse HEAD:docs/superpowers/plans/2026-10-25-p.md)"
fresh
nonce="$(bash "$XREVIEW" dispatch --checkpoint plan --diff "$PBR" b.md 2>/dev/null)"
RPC_WAIT_OUT='{"verdict":"approve","findings":[]}' bash "$XREVIEW" collect "$nonce" >/dev/null 2>&1
is "PB a plan-checkpoint receipt carries plan_blobs on its target" \
   "$(receipt "$nonce" | jq -c '.targets[0].plan_blobs')" "{\"docs/superpowers/plans/2026-10-25-p.md\":\"$PBLOB\"}"
fresh
nonce="$(bash "$XREVIEW" dispatch --checkpoint pre-merge --diff "$PBR" b.md 2>/dev/null)"
RPC_WAIT_OUT='{"verdict":"approve","findings":[]}' bash "$XREVIEW" collect "$nonce" >/dev/null 2>&1
is "PB a pre-merge receipt carries none" "$(receipt "$nonce" | jq -c '.targets[0] | has("plan_blobs")')" false
printf '%s\n' 'import os, runpy, sys' 'if sys.argv[1:2] == ["plan-blobs"]: sys.exit(1)' \
  'runpy.run_path(os.environ["XREVIEW_REAL_PACKET"], run_name="__main__")' > "$ROOT/fail-blobs.py"
fresh
nonce="$(bash "$XREVIEW" dispatch --checkpoint plan --diff "$PBR" b.md 2>/dev/null)"
XREVIEW_REAL_PACKET="$PACKET" XREVIEW_PACKET="$ROOT/fail-blobs.py" RPC_WAIT_OUT='{"verdict":"approve","findings":[]}' \
  bash "$XREVIEW" collect "$nonce" >/dev/null 2>&1; rc=$?
is "PB2 plan-blobs failing records [] and never fails the collect" "$rc/$(receipt "$nonce" | jq -c '.targets[0].plan_blobs')" "0/[]"

echo "SL. collect runs a sliced round to the end, one fresh thread per slice (spec 2026-10-25 §3.3)"
for n in 1 2 3; do seq 1 1500 | sed "s/^/slice $n line /" > "s$n.txt"; done
git add s1.txt s2.txt s3.txt && git commit -q -m "three files, a slice each"
SLR="$(git rev-parse HEAD~1)..$(git rev-parse HEAD)"
sliced() { # a first pre-merge dispatch of SLR, sliced; sets nonce and sl, and L1-L3 (the labels)
  fresh; packets framing fit; rm -rf "$CODEX_HOME/sessions"; rollout $U0 1000 114300
  nonce="$(bash "$XREVIEW" dispatch --checkpoint pre-merge --diff "$SLR" b.md 2>/dev/null)"
  sl="$STATE/turns/$nonce.slices"
  L1="$(jq -r '.packets[0].shown[]' "$sl" 2>/dev/null)"; L2="$(jq -r '.packets[1].shown[]' "$sl" 2>/dev/null)"
  L3="$(jq -r '.packets[2].shown[]' "$sl" 2>/dev/null)"
  printf '%s\n%s\n' "$U3" "$U4" > "$P/uuids"   # the threads collect starts for slices 2 and 3
}
approve_all() { # approve_all <slice-2 turn>: every slice approves, listing its own labels
  framed approve $L1 > "$P/answer.turn-$U1"; framed approve $L2 > "$P/answer.$1"; framed approve $L3 > "$P/answer.turn-$U4"
}
slices_done() { [ -e "$sl" ] && echo left || echo gone; }

sliced
is "SL1 (setup) the round is three slices, a file each" "$(jq -c '[.packets[].shown]' "$sl")" '[["s1.txt"],["s2.txt"],["s3.txt"]]'
framed approve $L1 > "$P/answer.turn-$U1"
jq -nc '{verdict:"changes",findings:[{severity:"P2",file:"s2.txt",line:1,summary:"s",failure_scenario:"f"}],reviewed_files:$ARGS.positional}' \
  --args $L2 s1.txt > "$P/answer.turn-$U3"
framed approve $L3 > "$P/answer.turn-$U4"
: > "$CALLS"
LOCK_PROBE="$LOCKF" bash "$XREVIEW" collect "$nonce" > "$ROOT/out" 2> "$ROOT/err"; rc=$?
is "SL1 collect runs every slice and exits 0" "$rc" 0
is "SL1 slices 2 and 3 run on fresh threads of their own" \
   "$(called 'xreview-rpc thread-start')/$(grep 'xreview-rpc turn-start' "$CALLS" | sed 's/.*--thread \([^ ]*\).*/\1/' | tr '\n' ' ')" "2/$U3 $U4 "
is "SL1 each slice's turn starts under the pane lock" "$(called 'lock-probe held')/$(called 'lock-probe free')" "2/0"
is "SL1 the pane is freed for each slice, then follows it" \
   "$(called 'herdr pane send-keys')/$(resumed "$U3")/$(resumed "$U4")" "4/1/1"
is "SL1 no keystroke while a turn runs" \
   "$(awk '/xreview-rpc turn-start/ {r = 1} /xreview-rpc turn-wait/ {r = 0} r && /herdr pane send-keys/ {c++} END {print c + 0}' "$CALLS")" 0
is "SL1 one merged answer: changes, as one slice asked for them" "$(jq -r .verdict "$ROOT/out")/$(grep -c . "$ROOT/out")" "changes/1"
is "SL1 with every slice's findings, and reviewed_files the union in first-seen order" \
   "$(jq -c '[(.findings | length), .reviewed_files]' "$ROOT/out")" '[1,["s1.txt","s2.txt","s3.txt"]]'
r="$(receipt "$nonce")"
is "SL1 the receipt names the last slice's thread and turn" "$(printf '%s' "$r" | jq -r '"\(.thread) \(.turn)"')" "$U4 turn-$U4"
is "SL1 and every slice's turn" "$(printf '%s' "$r" | jq -c '[.slice_turns[] | [.thread, .turn, .compacted]]')" \
   "[[\"$U1\",\"turn-$U1\",false],[\"$U3\",\"turn-$U3\",false],[\"$U4\",\"turn-$U4\",false]]"
is "SL1 a slices receipt, clean, with the merged verdict and count" \
   "$(printf '%s' "$r" | jq -c '[.targets[0].packet, .clean, .compacted, .targets[0].missing, .verdict, .findings]')" \
   '["slices",true,false,[],"changes",1]'
is "SL1 no notice" "$(cat "$ROOT/err")" ""
is "SL1 the last slice's thread is the checkpoint's thread" "$(cat "$STATE/review-thread")" "$U4"
is "SL1 the earlier slices' threads are archived as the pane moves on" \
   "$(called "thread-archive --thread $U1")/$(called "thread-archive --thread $U3")/$(called "thread-archive --thread $U4")" "1/1/0"
is "SL1 the round is the dispatch's" "$(bash "$XREVIEW" round)" 1
is "SL1 the packets and the slice state are gone" \
   "$([ -e "$STATE/turns/$nonce.packets" ] && echo left || echo gone)/$(slices_done)" "gone/gone"
is "SL1 the turn record names the last slice" "$(cat "$STATE/turns/$nonce")" "$U4 turn-$U4 pre-merge $YB"
: > "$CALLS"
bash "$XREVIEW" collect "$nonce" > "$ROOT/out2" 2>/dev/null; rc=$?
is "SL1 collecting a finished round again prints the merged answer, waiting on nothing" \
   "$rc/$(cmp -s "$ROOT/out" "$ROOT/out2" && echo same)/$(called 'xreview-rpc')" "0/same/0"

sliced; approve_all "turn-$U3"
echo 3 > "$P/rc.turn-$U3"
: > "$CALLS"
bash "$XREVIEW" collect "$nonce" > "$ROOT/out" 2> "$ROOT/err"; rc=$?
is "SL2 exit 3 during slice 2" "$rc/$(grep -c "xreview collect $nonce" "$ROOT/err")" "3/1"
is "SL2 slice 1's answer is kept, and slice 2's turn is on record" \
   "$(jq -c '[(.answers | map(select(. != null)) | length), .turns]' "$sl")" "[1,[\"turn-$U1\",\"turn-$U3\"]]"
: > "$CALLS"
bash "$XREVIEW" collect "$nonce" > "$ROOT/out" 2> "$ROOT/err"; rc=$?
is "SL2 collecting again finishes the round" "$rc/$(jq -r .verdict "$ROOT/out")" "0/approve"
is "SL2 it never waits on slice 1 again" "$(called "turn-wait --thread $U1")" 0
is "SL2 it resumes the wait on slice 2 by its id" "$(called "turn-wait --thread $U3 --turn turn-$U3 ")" 1
is "SL2 and starts slice 3 alone: nothing twice" "$(called 'xreview-rpc thread-start')/$(called 'xreview-rpc turn-start')" "1/1"
sliced; approve_all "turn-$U3"
echo 3 > "$P/rc.turn-$U3"
bash "$XREVIEW" collect "$nonce" >/dev/null 2>&1
jq -c 'del(.threads[1], .turns[1])' "$sl" > "$sl.t" && mv "$sl.t" "$sl"   # as if never saved
: > "$CALLS"
bash "$XREVIEW" collect "$nonce" > "$ROOT/out" 2> "$ROOT/err"; rc=$?
is "SL2b a slice the turn record shows started, its state unsaved, is taken up from the record" \
   "$rc/$(called "turn-start --thread $U3")/$(called "turn-wait --thread $U3 --turn turn-$U3 ")" "0/0/1"

sliced; approve_all "turn-$U3"
rm -f "$ROOT/held"
/usr/bin/python3 -c 'import fcntl,sys,time
f = open(sys.argv[1], "a"); fcntl.flock(f, fcntl.LOCK_EX); open(sys.argv[2], "w").close(); time.sleep(1.5)
open(sys.argv[3], "a").write("holder lets go of the lock\n")' "$LOCKF" "$ROOT/held" "$CALLS" &
holder=$!
for _ in $(seq 50); do [ -e "$ROOT/held" ] && break; sleep 0.1; done
: > "$CALLS"
XREVIEW_LOCK_WAIT=30 bash "$XREVIEW" collect "$nonce" > "$ROOT/out" 2> "$ROOT/err"; rc=$?
wait "$holder" 2>/dev/null
is "SL3 a pane lock held by another dispatch: collect waits for it, then finishes" "$rc/$(jq -r .verdict "$ROOT/out")" "0/approve"
is "SL3 slice 2 starts only once the holder has let go" \
   "$([ "$(first 'holder lets go')" -lt "$(first "xreview-rpc turn-start --thread $U3")" ] && echo yes || echo no)" yes
# Another collect of the same round starts slice 2, or runs it to its answer, while this one
# waits for the lock: the holder stands in for it, writing that into the round's state before it
# lets go. It writes only once this collect has called codex-daemon ensure for slice 2, which
# comes after its last save of slice 1's answer and before it asks for the lock (an event, not a
# timed poll); should that never come, it writes nothing and says so.
for other in started finished; do
  sliced; approve_all "turn-$U3"; printf '%s\n' "$U4" > "$P/uuids"
  rm -f "$ROOT/held" "$ROOT/holder-err"
  /usr/bin/python3 -c 'import fcntl, json, os, sys, time
f = open(sys.argv[1], "a"); fcntl.flock(f, fcntl.LOCK_EX); open(sys.argv[2], "w").close()
deadline = time.monotonic() + 60
while not os.path.exists(sys.argv[6]):
    if time.monotonic() > deadline:
        open(sys.argv[7], "w").write("holder: collect never called codex-daemon ensure within 60 s\n")
        sys.exit(1)
    time.sleep(0.05)
s = json.load(open(sys.argv[3]))
s["threads"].append(sys.argv[4]); s["turns"].append("turn-" + sys.argv[4])
if sys.argv[5] == "finished":
    s["answers"].append({"thread": sys.argv[4], "turn": "turn-" + sys.argv[4], "compacted": False,
                         "answer": {"verdict": "approve", "findings": [], "reviewed_files": ["s2.txt"]}})
open(sys.argv[3] + ".t", "w").write(json.dumps(s)); os.rename(sys.argv[3] + ".t", sys.argv[3])
time.sleep(0.3)' "$LOCKF" "$ROOT/held" "$sl" "$U3" "$other" "$P/ensured" "$ROOT/holder-err" &
  holder=$!
  wait_for "$ROOT/held"
  : > "$CALLS"
  ENSURE_MARK="$P/ensured" XREVIEW_LOCK_WAIT=90 bash "$XREVIEW" collect "$nonce" > "$ROOT/out" 2> "$ROOT/err"; rc=$?
  wait "$holder"; hrc=$?
  is "SL3b ($other) the holder stood in for the other collect" "$hrc/$(cat "$ROOT/holder-err" 2>/dev/null)" "0/"
  is "SL3b a slice another collect $other meanwhile is taken up under the lock, not started again" \
     "$rc/$(jq -r .verdict "$ROOT/out")/$(called 'xreview-rpc thread-start')/$(grep 'xreview-rpc turn-start' "$CALLS" | grep -c -- "--thread $U3")" \
     "0/approve/1/0"
  is "SL3b ($other) waited on only if it had no answer yet" "$(called "turn-wait --thread $U3 --turn turn-$U3 ")" \
     "$([ "$other" = started ] && echo 1 || echo 0)"
  is "SL3b ($other) and its turn is in the receipt" "$(receipt "$nonce" | jq -r '.slice_turns[1].turn')" "turn-$U3"
done

sliced; approve_all turn-recovered
echo 6 > "$P/start_rc.$U3"; : > "$P/unfound.$U3"
: > "$CALLS"
bash "$XREVIEW" collect "$nonce" > "$ROOT/out" 2> "$ROOT/err"; rc=$?
is "SL4 slice 2's turn-start goes unanswered and its turn is not found yet: exit 3" "$rc" 3
is "SL4 with the warning never to re-dispatch" "$(grep -c 'do NOT re-dispatch' "$ROOT/err")" 1
is "SL4 the slice's turn is on record as unknown, with what its thread held before" \
   "$(jq -c .turns "$sl")/$([ -e "$STATE/turns/$nonce.known" ] && echo known)" "[\"turn-$U1\",\"?\"]/known"
is "SL4 and so is the turn record" "$(cat "$STATE/turns/$nonce")" "$U3 ? pre-merge $YB"
rm -f "$P/start_rc.$U3"
: > "$CALLS"
bash "$XREVIEW" collect "$nonce" > "$ROOT/out" 2> "$ROOT/err"; rc=$?
is "SL4 the next collect finds it as the turn that was not on the thread before" \
   "$(called "turn-wait --thread $U3 --new-since $STATE/turns/$nonce.known --resolved")" 1
is "SL4 and never sends it again" "$(called "turn-start --thread $U3")" 0
is "SL4 the round finishes with the recovered turn" "$rc/$(receipt "$nonce" | jq -c '.slice_turns[1].turn')" '0/"turn-recovered"'

sliced; approve_all "turn-$U3"
rm -f "$ROOT/held"
/usr/bin/python3 -c 'import fcntl,sys,time
f = open(sys.argv[1], "a"); fcntl.flock(f, fcntl.LOCK_EX); open(sys.argv[2], "w").close(); time.sleep(60)' \
  "$LOCKF" "$ROOT/held" &
holder=$!
for _ in $(seq 50); do [ -e "$ROOT/held" ] && break; sleep 0.1; done
: > "$CALLS"
XREVIEW_LOCK_WAIT=0.5 bash "$XREVIEW" collect "$nonce" > "$ROOT/out" 2> "$ROOT/err"; rc=$?
kill -9 "$holder"; wait "$holder" 2>/dev/null
is "SL5 a pane held past the bound refuses before slice 2 starts" \
   "$rc/$(grep -c 'another dispatch is using the Codex pane w1:p2' "$ROOT/err")" "1/1"
is "SL5 saying the round is on record and collect can be run again" \
   "$(grep -c "the round is on record for $nonce; run xreview collect $nonce again" "$ROOT/err")" 1
is "SL5 no thread or turn was started for it" "$(called 'xreview-rpc thread-start')/$(called 'xreview-rpc turn-start')" "0/0"
is "SL5 slice 1's answer is kept" "$(jq -c '[(.answers | map(select(. != null)) | length), (.turns | length)]' "$sl")" "[1,1]"
is "SL5 and the checkpoint's thread is still slice 1's, nothing superseded" \
   "$(cat "$STATE/review-thread")/$([ -e "$STATE/superseded" ] && echo left || echo none)" "$U1/none"
: > "$CALLS"
ENSURE_RC=1 bash "$XREVIEW" collect "$nonce" > "$ROOT/out" 2> "$ROOT/err"; rc=$?
is "SL5 a daemon that will not start refuses the same way, the pane untouched" \
   "$rc/$(grep -c "the round is on record for $nonce" "$ROOT/err")/$(untouched)" "1/1/yes"
: > "$CALLS"
bash "$XREVIEW" collect "$nonce" > "$ROOT/out" 2> "$ROOT/err"; rc=$?
is "SL5 collecting again resumes: slice 2 and 3 start, slice 1 is not waited on" \
   "$rc/$(jq -r .verdict "$ROOT/out")/$(called 'xreview-rpc turn-start')/$(called "turn-wait --thread $U1")" "0/approve/2/0"

# Slice 1 lists nothing; slice 2 lists slice 1's label beside its own. Slice 1's label is still
# missing: slice 2's reviewer never saw that file's patch.
sliced
framed approve > "$P/answer.turn-$U1"; framed approve $L1 $L2 > "$P/answer.turn-$U3"; framed approve $L3 > "$P/answer.turn-$U4"
bash "$XREVIEW" collect "$nonce" > "$ROOT/out" 2> "$ROOT/err"
is "SL6 a label listed only by a slice that did not show it is not covered" \
   "$(receipt "$nonce" | jq -c '[.clean, .targets[0].missing]')/$(cat "$STATE/missed")" '[false,["s1.txt"]]/s1.txt'
is "SL6 though the merged answer still lists what was listed" "$(jq -c .reviewed_files "$ROOT/out")" '["s1.txt","s2.txt","s3.txt"]'
is "SL6 and the notice names the slice's label" \
   "$(cat "$ROOT/err")" "xreview: this review is not clean (missed: s1.txt); the merge gate stays closed for it"

sliced; approve_all "turn-$U3"; echo null > "$P/compacted.turn-$U3"
bash "$XREVIEW" collect "$nonce" >/dev/null 2>&1
is "SL7 one slice of unknown compaction: the receipt's is unknown, and not clean" \
   "$(receipt "$nonce" | jq -c '[.compacted, .clean, [.slice_turns[].compacted]]')" '[null,false,[false,null,false]]'
sliced; approve_all "turn-$U3"; echo null > "$P/compacted.turn-$U3"; echo true > "$P/compacted.turn-$U4"
bash "$XREVIEW" collect "$nonce" >/dev/null 2>&1
is "SL7 one compacted slice makes the receipt compacted" "$(receipt "$nonce" | jq -c '[.compacted, .clean]')" '[true,false]'

sliced; approve_all "turn-$U3"; echo 4 > "$P/rc.turn-$U3"; printf 'prose\n' > "$P/answer.turn-$U3"
bash "$XREVIEW" collect "$nonce" > "$ROOT/out" 2> "$ROOT/err"; rc=$?
is "SL8 a slice's answer off the schema: exit 4, the raw text, nothing recorded" \
   "$rc/$(cat "$ROOT/out")/$(receipt "$nonce" | grep -c .)" "4/prose/0"
is "SL8 the round stays where it was" "$(jq -c '[(.answers | map(select(. != null)) | length), (.turns | length)]' "$sl")" "[1,2]"

# Two collects, A and B, wait on slice 1. A gets the answer first, starts slice 2 and saves
# that; B's copy of the round is then stale. B saving slice 1's answer must keep A's slice 2,
# so B takes it up instead of starting it again. The test plays A while B's wait is held.
sliced; approve_all "turn-$U3"; printf '%s\n' "$U4" > "$P/uuids"
: > "$P/hold.turn-$U1"
: > "$CALLS"
bash "$XREVIEW" collect "$nonce" > "$ROOT/outB" 2> "$ROOT/errB" &
second_collect=$!
wait_for "$P/waiting.turn-$U1"
jq -c --arg t "$U3" '.answers = [{thread: .threads[0], turn: .turns[0], compacted: false,
                                  answer: {verdict: "approve", findings: [], reviewed_files: ["s1.txt"]}}]
                     | .threads += [$t] | .turns += ["turn-" + $t] | .next = 2' "$sl" > "$sl.t" && mv "$sl.t" "$sl"
rm -f "$P/holding.turn-$U1"
wait "$second_collect"; rc=$?
is "SL9 a collect whose copy went stale keeps the slice another one started, and never starts it again" \
   "$rc/$(jq -r .verdict "$ROOT/outB")/$(called 'xreview-rpc thread-start')/$(grep 'xreview-rpc turn-start' "$CALLS" | sed 's/.*--thread \([^ ]*\).*/\1/' | tr '\n' ' ')" \
   "0/approve/1/$U4 "
is "SL9 and the receipt names the slice 2 turn that A started" "$(receipt "$nonce" | jq -r '.slice_turns[1].turn')" "turn-$U3"

# The budget is measured from collect's start for every wait, the first one included: a
# resumed collect that starts a slice before its first wait has spent part of it already.
sliced; approve_all "turn-$U3"
ENSURE_RC=1 bash "$XREVIEW" collect "$nonce" >/dev/null 2>&1   # slice 1 answered, slice 2 refused
hold_lock 2.5
: > "$CALLS"
bash "$XREVIEW" collect "$nonce" > "$ROOT/out" 2> "$ROOT/err"; rc=$?
wait "$holder" 2>/dev/null
given="$(grep "turn-wait --thread $U3 " "$CALLS" | sed -n 's/.*--budget \([0-9][0-9]*\) .*/\1/p')"
is "SL10 a resumed collect's first wait, after a slice start that waited 2.5 s for the lock, gets less than the budget" \
   "$rc/$([ -n "$given" ] && [ "$given" -lt 2700 ] && [ "$given" -ge 2600 ] && echo less || echo "${given:-none}")" "0/less"
sliced; approve_all "turn-$U3"
ENSURE_RC=1 bash "$XREVIEW" collect "$nonce" >/dev/null 2>&1
hold_lock 2.5
: > "$CALLS"
bash "$XREVIEW" collect "$nonce" 2 > "$ROOT/out" 2> "$ROOT/err"; rc=$?
wait "$holder" 2>/dev/null
is "SL10 a budget used up by the slice start: exit 3, saying so, with no wait" \
   "$rc/$(grep -c "the budget of 2s is used up" "$ROOT/err")/$(called "turn-wait --thread $U3")" "3/1/0"
is "SL10 the slice it started is on record" "$(jq -c .turns "$sl")" "[\"turn-$U1\",\"turn-$U3\"]"
: > "$CALLS"
bash "$XREVIEW" collect "$nonce" > "$ROOT/out" 2> "$ROOT/err"; rc=$?
is "SL10 and collecting again resumes it" "$rc/$(jq -r .verdict "$ROOT/out")/$(called "turn-start --thread $U3")" "0/approve/0"

# A slice whose shown labels cannot be read is no coverage at all.
sliced; approve_all "turn-$U3"
jq -c 'del(.packets[1].shown)' "$sl" > "$sl.t" && mv "$sl.t" "$sl"
bash "$XREVIEW" collect "$nonce" > "$ROOT/out" 2> "$ROOT/err"; rc=$?
is "SL11 a slice's shown labels unreadable: not clean, the sentinel on the target, the notice says so" \
   "$rc/$(receipt "$nonce" | jq -c '[.clean, .targets[0].missing]')/$(cat "$ROOT/err")" \
   '0/[false,["(shown labels unreadable)"]]/xreview: this review is not clean (coverage unknown); the merge gate stays closed for it'

printf '\npassed: %d  failed: %d\n' "$pass" "$fail"
(( fail == 0 ))
