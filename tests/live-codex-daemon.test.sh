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
# The exact scenario xreview dispatch now relies on (spec 7.3 steps 3-5): quit the pane's
# current TUI first, exactly as pane_free does, THEN create a thread and start a real (if
# small) review turn on it BEFORE any TUI is attached, then resume the pane onto it while the
# turn is still running. The probe (2026-09-28) found the TUI renders the whole turn from its
# start, prompt included, then streams the rest live.
herdr pane send-keys "$pane" ctrl+c >/dev/null 2>&1; sleep 0.5
herdr pane send-keys "$pane" ctrl+c >/dev/null 2>&1
freed=0
for _ in $(seq 15); do
  a="$(herdr pane get "$pane" 2>/dev/null | jq -r '.result.pane.agent // empty')"
  [ "$a" != codex ] && { freed=1; break; }
  sleep 1
done
is "F22 the pane's TUI is freed before the turn exists" "$freed" 1

f22_thread="$(rpc thread-start --cwd "$SRC")"; rc=$?
is "F22 thread-start creates a thread" "$rc/$([ -n "$f22_thread" ] && echo yes || echo no)" "0/yes"

# token1 is in the PROMPT only, so seeing it proves the pane replayed the turn from its start
# (F22 itself). The answer token is split into two fragments given SEPARATELY, asked to be
# concatenated with NO separator - the joined string is never written anywhere in the prompt
# itself, only its two halves, so seeing the JOINED string in the pane is proof the final
# answer actually landed, not just a replay of the prompt (fix round 2/B: the previous version
# asked for the whole token verbatim, so the instruction line itself satisfied the check). A
# short but real review (not "just say approve") makes the turn take long enough to be caught
# genuinely running, not just read after the fact.
token1="f22-token-$$-$RANDOM"
frag_a="f22frag-a-$$"
frag_b="b-$RANDOM-f22frag"
joined="${frag_a}${frag_b}"
cat > "$T/scratch22.py" <<PY
def add(a, b):
    return a - b  # intentional bug for a live canary review
PY
{
  printf 'Live canary F22 (%s). Review the Python function below for a correctness bug and\n' "$token1"
  printf 'answer in the findings schema. Include exactly one finding, severity P2, whose\n'
  printf '"summary" field is exactly two fragments concatenated with NO separator and nothing\n'
  printf 'else: first "%s", then "%s".\n\n' "$frag_a" "$frag_b"
  cat "$T/scratch22.py"
} > "$T/in22"
is "F22 the prompt carries no literal schema field (so prompt and answer stay distinguishable)" \
   "$(grep -cF '"verdict":' "$T/in22")" 0
is "F22 the joined answer token never appears literally in the prompt" \
   "$(grep -cF "$joined" "$T/in22")" 0

# --known, exactly as xreview dispatch itself calls turn-start: exercises thread/turns/list on
# a zero-turn thread from a fresh connection, whose thread/turns/list refuses as "not
# materialized" until it has a first turn (item A) - turn-start must still succeed here.
f22_turn="$(rpc turn-start --thread "$f22_thread" --input "$T/in22" --schema "$SCHEMA" --known "$T/known22")"; rc=$?
is "F22 turn-start exits 0 on a thread with no turns yet (item A's live check)" "$rc" 0
is "F22 and the --known baseline is the empty list, not an error" "$(cat "$T/known22" 2>/dev/null)" '[]'
# turn-wait starts before the pane is even resumed, in the background, so it subscribes and
# catches turn/completed (F5) regardless of how long the resume itself takes.
rpc turn-wait --thread "$f22_thread" --turn "$f22_turn" --budget 180 --schema "$SCHEMA" \
  > "$T/wait22.out" 2> "$T/wait22.err" &
wait_pid=$!
pane_cmd="$(grep -v '^[[:space:]]*#' "$PCMD" | grep . | head -1)"
herdr pane run "$pane" "$pane_cmd resume $f22_thread" >/dev/null
seen22=0
for _ in $(seq 20); do
  out22="$(herdr pane read "$pane" --source visible 2>/dev/null)"
  if printf '%s' "$out22" | grep -qF "$token1"; then
    seen22=1; break
  fi
  sleep 1
done
is "F22 the resumed pane shows the prompt's own token" "$seen22" 1
# Mid-turn: right after the pane first shows the token, the daemon must still report the
# turn running - proof this was caught genuinely mid-flight, not read after it finished. A
# real review of even a small file (the probe: ~40s) should still be running at this point;
# if this ever goes red, the turn may simply have finished faster than that, not a bug.
is "F22 the turn is still running right after the pane first shows it (a fail here may just mean it finished very fast, not a bug)" \
   "$(rpc thread-status --thread "$f22_thread" 2>/dev/null | jq -r .running)" true

wait "$wait_pid"; rc=$?
res22="$(cat "$T/wait22.out")"
is "F22 turn-wait completes" "$rc" 0
verdict22="$(printf '%s' "$res22" | jq -r .verdict 2>/dev/null)"
case "$verdict22" in
  approve|changes) _pass "F22 with a schema-valid verdict ($verdict22)" ;;
  *) _fail "F22 with a schema-valid verdict" "$verdict22" ;;
esac
summary22="$(printf '%s' "$res22" | jq -r '.findings[0].summary // empty' 2>/dev/null)"
is "F22 the reviewer's answer carries the joined token it was asked to concatenate" \
   "$(printf '%s' "$summary22" | grep -cF "$joined")" 1

# The final-answer check: the JOINED token appears ONLY once the answer has actually landed -
# never during the prompt replay, since the prompt never writes the two fragments joined
# (asserted above, before the turn even started). Guard against an empty pattern before
# grepping for it: an empty grep pattern matches every line.
seen22final=0
if [ -n "$joined" ]; then
  for _ in $(seq 20); do
    out22f="$(herdr pane read "$pane" --source visible 2>/dev/null)"
    printf '%s' "$out22f" | grep -qF "$joined" && { seen22final=1; break; }
    sleep 1
  done
fi
is "F22 the pane shows the joined answer token once the turn completes (never from the prompt)" "$seen22final" 1

# A ctrl+c ladder as xreview runs it (spec 2026-10-01 §4.4): up to three pairs, each followed
# by up to 5 s for the shell to return to the foreground (G1).
pane_is_free() {
  herdr pane process-info --pane "$1" 2>/dev/null \
    | jq -e '.result.process_info | .foreground_process_group_id == .shell_pid' >/dev/null 2>&1
}
ladder() {
  local p="$1" _i _j
  for _i in 1 2 3; do
    herdr pane send-keys "$p" ctrl+c >/dev/null 2>&1; sleep 0.5
    herdr pane send-keys "$p" ctrl+c >/dev/null 2>&1
    for _j in $(seq 10); do pane_is_free "$p" && return 0; sleep 0.5; done
  done
  return 1
}

echo "G1/G3: herdr names the pane's Codex process, and it holds a daemon connection"
pi="$(herdr pane process-info --pane "$pane")"
cpid="$(printf '%s' "$pi" | jq -r '.result.process_info as $i
  | [$i.foreground_processes[]? | select(.name == "codex")]
  | (map(select(.pid == $i.foreground_process_group_id)) + .) | .[0].pid // empty')"
is "G1 process-info names the pane's Codex process" "$([ -n "$cpid" ] && echo yes || echo no)" yes
dpid="$(sed -n 's/.*"pid":\([0-9][0-9]*\).*/\1/p' "${CODEX_HOME:-$HOME/.codex}/app-server-daemon/daemon.pid" | head -1)"
mine="$(lsof -a -U -p "$dpid" -F d 2>/dev/null | sed -n 's/^d//p' | sort -u)"
peers="$(lsof -a -U -p "$cpid" -F n 2>/dev/null | sed -n 's/^n->//p' | sort -u)"
is "G3 the pane's TUI holds a socket whose peer is one of the daemon's" \
   "$([ -n "$(comm -12 <(printf '%s\n' "$mine") <(printf '%s\n' "$peers") | grep .)" ] && echo yes || echo no)" yes

ladder "$pane"; is "V the pane frees before the probes" "$?" 0
other="$T/elsewhere"; mkdir -p "$other"

echo "V2: a resume from another directory, without -C, is held at the chooser; the ladder frees it"
herdr pane run "$pane" "cd $(printf '%q' "$other") && $pane_cmd resume $f22_thread" >/dev/null
chooser=0
for _ in $(seq 15); do
  herdr pane read "$pane" --source visible 2>/dev/null | grep -q 'session directory' && { chooser=1; break; }
  sleep 1
done
# Not a note: V2 is evidence the spec requires (§3). A chooser that never appears fails here,
# and the controller stops at Task 1 (the plan's gate) rather than proceeding unverified.
is "V2 the directory chooser appears without -C" "$chooser" 1
ladder "$pane"; is "V2 the ladder frees the pane held at the chooser" "$?" 0
herdr pane run "$pane" 'echo v2-$((6*7))' >/dev/null
herdr pane wait-output "$pane" --match v2-42 --timeout 10000 >/dev/null 2>&1
is "V2 the shell then runs the next command" "$?" 0

echo "V1: a -C resume from another directory opens the thread with no chooser"
herdr pane run "$pane" "$pane_cmd -C $(printf '%q' "$SRC") resume $f22_thread" >/dev/null
v1=0; want="$(printf '%s' "$f22_thread" | cut -c1-29)"
for _ in $(seq 20); do
  t="$(herdr pane get "$pane" | jq -r '.result.pane.terminal_title_stripped // .result.pane.terminal_title // ""')"
  case "$t" in "$want"*) v1=1; break ;; esac
  sleep 1
done
is "V1 the title shows the thread" "$v1" 1
is "V1 and no chooser is on screen" \
   "$(herdr pane read "$pane" --source visible 2>/dev/null | grep -c 'session directory')" 0

printf '\npassed: %d  failed: %d\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
