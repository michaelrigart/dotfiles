#!/usr/bin/env bash
# Tests dot_local/bin/executable_xreview-rpc, the dotfiles' client for the Codex daemon
# (spec section 7.1). The daemon speaks JSON-RPC over a WebSocket on a unix socket, but the
# Claude sandbox denies binding one (F20), so the fake daemon here speaks newline-delimited
# JSON on stdio through XREVIEW_RPC_STDIO. The WebSocket framing is tested as functions, and
# against the real daemon by live-codex-daemon.test.sh.
#
# Run: ./tests/run.sh xreview-rpc   (sandboxed is fine)
set -uo pipefail
export PYTHONDONTWRITEBYTECODE=1
SRC="$(cd "$(dirname "$0")/.." && pwd)"
RPC="$SRC/dot_local/bin/executable_xreview-rpc"
SCHEMA="$SRC/dot_config/xreview/findings.schema.json"
for f in "$RPC" "$SCHEMA"; do
  [ -f "$f" ] || { echo "missing file under test: $f" >&2; exit 2; }
done
pass=0; fail=0
_pass() { printf '  PASS: %s\n' "$1"; pass=$((pass + 1)); }
_fail() { printf '  FAIL: %s\n    | got: %s\n' "$1" "$2"; fail=$((fail + 1)); }
is() { if [ "$2" = "$3" ]; then _pass "$1"; else _fail "$1" "$2"; fi; }

T="$(mktemp -d "${TMPDIR:-/tmp}/xreview-rpc.XXXXXX")"; trap 'rm -rf "$T"' EXIT
cat > "$T/fake.py" <<'PY'
# A fake Codex daemon on stdio. FAKE_SCENARIO holds {"runs": [run, ...]}; each process
# start takes the next run (FAKE_COUNTER), so a dropped connection and the reconnect can
# behave differently. A run maps a method to its response and to notifications sent after
# that response; "exit_after" drops the connection after that many messages sent,
# "drop_on" vanishes on receiving a method, and "silent" never answers a method.
import json, os, sys
scen = json.load(open(os.environ["FAKE_SCENARIO"]))
runs = scen.get("runs") or [scen]
n = 0
cf = os.environ.get("FAKE_COUNTER")
if cf:
    try:
        n = int(open(cf).read())
    except Exception:
        n = 0
    open(cf, "w").write(str(n + 1))
run = runs[min(n, len(runs) - 1)]
log = open(os.environ["FAKE_LOG"], "a")
sent = 0
calls = {}   # per-method call count, for a "responses" entry given as a list
def out(m):
    global sent
    sys.stdout.write(json.dumps(m) + "\n"); sys.stdout.flush(); sent += 1
    if run.get("exit_after") is not None and sent >= run["exit_after"]:
        sys.exit(0)
for line in sys.stdin:
    m = json.loads(line); log.write(json.dumps(m) + "\n"); log.flush()
    meth = m.get("method")
    if meth in run.get("drop_on", []):        # accept the request, then vanish unanswered
        sys.exit(0)
    if meth in run.get("garbage_on", []):     # a corrupt frame instead of a real response
        sys.stdout.write("not-json-at-all\n"); sys.stdout.flush()
        sys.exit(0)
    if "id" in m and meth and meth not in run.get("silent", []):
        resp = run.get("responses", {}).get(meth, {"result": {}})
        if isinstance(resp, list):   # a different answer on each successive call
            i = calls.get(meth, 0); calls[meth] = i + 1
            resp = resp[min(i, len(resp) - 1)]
        out(dict(resp, id=m["id"]))
        for note in run.get("after", {}).get(meth, []):
            out(note)
PY
export FAKE_LOG="$T/log" FAKE_COUNTER="$T/counter" FAKE_SCENARIO="$T/scenario.json"
export XREVIEW_RPC_STDIO="python3 $T/fake.py"
scenario() { printf '%s' "$1" > "$FAKE_SCENARIO"; : > "$FAKE_LOG"; rm -f "$FAKE_COUNTER"; }
rpc() { python3 "$RPC" "$@"; }
params() { jq -c "select(.method == \"$1\") | .params" "$FAKE_LOG" | head -1; }
ANSWER='{"verdict":"changes","findings":[{"severity":"P1","file":"a.sh","line":3,"summary":"s","failure_scenario":"f"}]}'
turn() { # turn <status> <final-text>
  jq -nc --arg s "$1" --arg t "$2" '{id:"turn-1",status:$s,
    error:(if $s == "completed" then null else {message:"boom"} end),
    items:[{type:"userMessage"},{type:"agentMessage",phase:"final_answer",text:$t}]}'
}
listing() { jq -nc --argjson t "$1" '{result:{data:[$t]}}'; }

echo "A. WebSocket framing"
out="$(python3 - "$RPC" <<'PY'
import importlib.machinery, importlib.util, sys
loader = importlib.machinery.SourceFileLoader("xreview_rpc", sys.argv[1])
spec = importlib.util.spec_from_loader("xreview_rpc", loader)
m = importlib.util.module_from_spec(spec); loader.exec_module(m)
ok = True
for n in (5, 200, 70000):          # 7-bit, 16-bit and 64-bit length encodings
    p = bytes(range(256)) * (n // 256) + b"x" * (n % 256)
    f = m.ws_frame(p, mask=b"\x01\x02\x03\x04")
    ok &= m.ws_parse(f) == (True, 1, p, b"")
    ok &= m.ws_parse(f[:-1]) is None
ok &= m.ws_parse(b"\x81\x02hi" + b"tail") == (True, 1, b"hi", b"tail")   # server frames are unmasked
print("ok" if ok else "bad")
PY
)"
is "frames round-trip at every length encoding, and partial frames wait" "$out" ok

echo "A2. Client._other keeps notes empty for anything but turn/completed"
out="$(python3 - "$RPC" <<'PY'
import importlib.machinery, importlib.util, sys
loader = importlib.machinery.SourceFileLoader("xreview_rpc", sys.argv[1])
spec = importlib.util.spec_from_loader("xreview_rpc", loader)
m = importlib.util.module_from_spec(spec); loader.exec_module(m)
c = m.Client.__new__(m.Client)   # skip __init__: no real transport needed for this
c.notes = []
c._other({"method": "item/agentMessage/delta", "params": {}})
c._other({"method": "turn/started", "params": {}})
c._other({"method": "session/updated", "params": {}})
print("ok" if c.notes == [] else "bad " + repr(c.notes))
PY
)"
is "non-turn/completed notifications are never queued" "$out" ok

echo "B. health"
scenario '{}'
rpc health; is "a daemon that answers initialize is healthy" "$?" 0
is "the client sends initialized after initialize" "$(jq -r 'select(.method=="initialized") | .method' "$FAKE_LOG")" initialized
XREVIEW_RPC_STDIO=false rpc health 2>/dev/null; is "a daemon that goes away is unreachable (5)" "$?" 5
env -u XREVIEW_RPC_STDIO XREVIEW_RPC_SOCK="$T/no.sock" python3 "$RPC" health 2>/dev/null
is "a missing socket is unreachable (5)" "$?" 5

echo "B2. thread-start"
scenario '{"responses":{"thread/start":{"result":{"thread":{"id":"th-new-1"}}}}}'
is "it prints the new thread's id" "$(rpc thread-start --cwd /tmp/repo)" th-new-1
is "the cwd is passed through" "$(params thread/start | jq -r .cwd)" /tmp/repo
scenario '{"responses":{"thread/start":{"error":{"code":-1,"message":"nope"}}}}'
rpc thread-start --cwd /tmp/repo 2>/dev/null
is "a refused thread/start exits 1" "$?" 1
XREVIEW_RPC_STDIO=false rpc thread-start --cwd /tmp/repo 2>/dev/null
is "an unreachable daemon exits 5" "$?" 5

echo "C. thread-status"
scenario '{"responses":{"thread/read":{"result":{"thread":{"status":{"type":"active","activeFlags":[]}}}}}}'
is "an active thread is loaded and running" "$(rpc thread-status --thread th | jq -c '[.loaded,.running]')" '[true,true]'
scenario '{"responses":{"thread/read":{"result":{"thread":{"status":{"type":"idle"}}}}}}'
is "an idle thread is loaded and not running" "$(rpc thread-status --thread th | jq -c '[.loaded,.running]')" '[true,false]'
scenario '{"responses":{"thread/read":{"error":{"code":-32600,"message":"no thread"}}}}'
is "an unknown thread is not loaded" "$(rpc thread-status --thread th | jq -c '.loaded')" false

echo "D. turn-start"
printf 'the packet\n' > "$T/in"
scenario '{"responses":{"turn/start":{"result":{"turn":{"id":"turn-9","status":"inProgress"}}}}}'
is "it prints the turn id" "$(rpc turn-start --thread th --input "$T/in" --schema "$SCHEMA")" turn-9
p="$(params turn/start)"
is "the turn targets the thread"          "$(printf '%s' "$p" | jq -r .threadId)" th
is "the input is the packet file"         "$(printf '%s' "$p" | jq -r '.input[0].text')" "the packet"
is "read-only is set on the turn itself"  "$(printf '%s' "$p" | jq -r .sandboxPolicy.type)" readOnly
is "approval is never, on the turn"       "$(printf '%s' "$p" | jq -r .approvalPolicy)" never
is "the findings schema is the outputSchema" "$(printf '%s' "$p" | jq -c .outputSchema)" "$(jq -c . "$SCHEMA")"
scenario '{"responses":{"turn/start":{"error":{"code":-1,"message":"busy"}}}}'
rpc turn-start --thread th --input "$T/in" --schema "$SCHEMA" 2>/dev/null
is "a refused turn/start exits 1" "$?" 1
# Sent but never answered is not "not started": the turn may be running. It gets its own
# exit code, and --known has already recorded what was on the thread before it.
scenario '{"responses":{"thread/turns/list":{"result":{"data":[{"id":"t-old","status":"completed","items":[]}]}}},"drop_on":["turn/start"]}'
rpc turn-start --thread th --input "$T/in" --schema "$SCHEMA" --known "$T/known" 2>/dev/null
is "an unanswered turn/start exits 6" "$?" 6
is "the thread's earlier turns were recorded first" "$(jq -c . "$T/known")" '["t-old"]'
# Without that baseline an unanswered start could later pass an old answer off as new.
scenario '{"responses":{"thread/turns/list":{"error":{"code":-1,"message":"nope"}}},"drop_on":["turn/start"]}'
rpc turn-start --thread th --input "$T/in" --schema "$SCHEMA" --known "$T/known2" 2>/dev/null
is "a baseline that cannot be read refuses (1)" "$?" 1
is "before anything is sent" "$(jq -r 'select(.method=="turn/start") | .method' "$FAKE_LOG" | grep -c .)" 0

echo "D2. a fresh thread's 'not materialized' baseline is empty, not an error"
scenario '{"responses":{"thread/turns/list":{"error":{"code":-32600,"message":"thread 01a0e894-... is not materialized yet; thread/turns/list is unavailable before first user message"}},"turn/start":{"result":{"turn":{"id":"turn-fresh","status":"inProgress"}}}}}'
out="$(rpc turn-start --thread th --input "$T/in" --schema "$SCHEMA" --known "$T/known3")"; rc=$?
is "D2 it still starts the turn" "$rc/$out" "0/turn-fresh"
is "D2 the known file is an empty list" "$(cat "$T/known3")" '[]'
is "D2 turn/start was actually called" "$(jq -r 'select(.method=="turn/start") | .method' "$FAKE_LOG" | grep -c .)" 1

echo "TL. an unloaded checkpoint thread is loaded before its turn starts"
scenario '{"responses":{"thread/read":{"result":{"thread":{"status":{"type":"notLoaded"}}}},"turn/start":{"result":{"turn":{"id":"turn-e1","status":"inProgress"}}}}}'
out="$(rpc turn-start --thread th --input "$T/in" --schema "$SCHEMA")"; rc=$?
is "TL1 it starts the turn" "$rc/$out" "0/turn-e1"
is "TL1 thread/resume comes before turn/start" \
   "$(jq -r 'select(.method) | .method' "$FAKE_LOG" | grep -E '^(thread/resume|turn/start)$' | paste -sd, -)" "thread/resume,turn/start"
is "TL1 on that thread" "$(params thread/resume | jq -r .threadId)" th
scenario '{"responses":{"thread/read":{"result":{"thread":{"status":{"type":"idle"}}}},"turn/start":{"result":{"turn":{"id":"turn-e2","status":"inProgress"}}}}}'
rpc turn-start --thread th --input "$T/in" --schema "$SCHEMA" >/dev/null
is "TL2 a loaded thread is not resumed" "$(jq -r 'select(.method=="thread/resume") | .method' "$FAKE_LOG" | grep -c .)" 0
scenario '{"responses":{"thread/read":{"result":{"thread":{"status":{"type":"notLoaded"}}}},"thread/resume":{"error":{"code":-1,"message":"gone"}}}}'
rpc turn-start --thread th --input "$T/in" --schema "$SCHEMA" 2>/dev/null
is "TL3 a thread that will not load refuses (1)" "$?" 1
is "TL3 and never calls turn/start" "$(jq -r 'select(.method=="turn/start") | .method' "$FAKE_LOG" | grep -c .)" 0

echo "D3. any other thread/turns/list error still refuses, unchanged"
scenario '{"responses":{"thread/turns/list":{"error":{"code":-1,"message":"some other failure"}}},"drop_on":["turn/start"]}'
rpc turn-start --thread th --input "$T/in" --schema "$SCHEMA" --known "$T/known4" 2>/dev/null
is "D3 it refuses (1)" "$?" 1
is "D3 and never calls turn/start" "$(jq -r 'select(.method=="turn/start") | .method' "$FAKE_LOG" | grep -c .)" 0

echo "E. turn-wait on a turn that already finished"
scenario "$(jq -nc --argjson l "$(listing "$(turn completed "$ANSWER")")" '{responses:{"thread/turns/list":$l}}')"
out="$(rpc turn-wait --thread th --turn turn-1 --budget 5 --schema "$SCHEMA")"; rc=$?
is "it exits 0"                         "$rc" 0
is "it prints the schema-valid answer"  "$(printf '%s' "$out" | jq -r .verdict)" changes
is "it subscribed before looking"       "$(jq -r 'select(.method) | .method' "$FAKE_LOG" | grep -E 'thread/(resume|turns/list)' | head -1)" thread/resume

new_turn="$(turn completed "$ANSWER" | jq -c '.id = "turn-2"')"
old_turn='{"id":"t-old","status":"completed","items":[]}'
scenario "$(jq -nc --argjson n "$new_turn" --argjson o "$old_turn" '{responses:{"thread/turns/list":{result:{data:[$n,$o]}}}}')"
out="$(rpc turn-wait --thread th --new-since "$T/known" --resolved "$T/resolved" --budget 5 --schema "$SCHEMA")"; rc=$?
is "E2 --new-since finds the turn that was not there before" "$rc/$(printf '%s' "$out" | jq -r .verdict)" "0/changes"
is "E2 and hands its id back through --resolved" "$(cat "$T/resolved" 2>/dev/null)" turn-2
scenario "$(jq -nc --argjson o "$old_turn" '{responses:{"thread/turns/list":{result:{data:[$o]}}}}')"
rpc turn-wait --thread th --new-since "$T/known" --budget 2 --schema "$SCHEMA" >/dev/null 2>&1
is "E3 and exits 1 when nothing new is on the thread" "$?" 1

echo "E1b. turn-wait follows nextCursor when the fixed turn is older than the newest page"
others="$(jq -nc '[range(50) | {id: ("other-" + (. | tostring)), status:"completed", items:[]}]')"
page1="$(jq -nc --argjson o "$others" '{result:{data:$o, nextCursor:"c2"}}')"
page2="$(jq -nc --argjson t "$(turn completed "$ANSWER")" '{result:{data:[$t]}}')"
scenario "$(jq -nc --argjson p1 "$page1" --argjson p2 "$page2" '{responses:{"thread/turns/list":[$p1,$p2]}}')"
out="$(rpc turn-wait --thread th --turn turn-1 --budget 5 --schema "$SCHEMA")"; rc=$?
is "E1b it exits 0 once the turn is found on the second page" "$rc" 0
is "E1b with the schema-valid answer" "$(printf '%s' "$out" | jq -r .verdict)" changes
is "E1b the second call carried the cursor" \
   "$(jq -r 'select(.method=="thread/turns/list") | .params.cursor // "none"' "$FAKE_LOG" | sed -n 2p)" c2

echo "M6a. a fixed turn absent from every page stops once nextCursor is gone (not retried)"
others2="$(jq -nc '[range(3) | {id: ("other-" + (. | tostring)), status:"completed", items:[]}]')"
lastpage="$(jq -nc --argjson o "$others2" '{result:{data:$o}}')"   # no nextCursor: the last page
scenario "$(jq -nc --argjson p1 "$page1" --argjson p2 "$lastpage" '{responses:{"thread/turns/list":[$p1,$p2]}}')"
rpc turn-wait --thread th --turn turn-absent --budget 5 --schema "$SCHEMA" >/dev/null 2>"$T/err"; rc=$?
is "M6a it exits 1, never finding the turn" "$rc" 1
is "M6a and says no turn, not an unreadable-listing error" "$(grep -c 'no turn' "$T/err")" 1
is "M6a exactly two pages were fetched, then it stopped" \
   "$(jq -r 'select(.method=="thread/turns/list") | .method' "$FAKE_LOG" | grep -c .)" 2

echo "M6b. a cursor that never ends exits 3 (still running, try again) at the budget, never a false 'no turn' (N2)"
forever="$(jq -nc '{result:{data:[{id:"other",status:"completed",items:[]}], nextCursor:"forever"}}')"
scenario "$(jq -nc --argjson f "$forever" '{responses:{"thread/turns/list":[$f]}}')"
rpc turn-wait --thread th --turn turn-absent --budget 0.6 --schema "$SCHEMA" >/dev/null 2>"$T/err"; rc=$?
is "M6b it exits 3, not the plain read-failure 1" "$rc" 3
is "M6b and says to collect again with a larger budget" \
   "$(grep -c 'collect again with a larger budget' "$T/err")" 1
is "M6b and never the plain read-failure message" "$(grep -c 'could not be read' "$T/err")" 0
is "M6b and never claims no turn exists" "$(grep -c 'no turn' "$T/err")" 0

echo "E4. a transient thread/turns/list error is retried, not reported as no turn"
new_turn3="$(turn completed "$ANSWER" | jq -c '.id = "turn-3"')"
printf '["nothing"]' > "$T/known2"
scenario "$(jq -nc --argjson n "$new_turn3" \
  '{responses:{"thread/turns/list":[{error:{code:-1,message:"transient"}},{result:{data:[$n]}}]}}')"
out="$(rpc turn-wait --thread th --new-since "$T/known2" --budget 5 --schema "$SCHEMA")"; rc=$?
is "E4 it exits 0 despite the transient list error" "$rc" 0
is "E4 with the answer found once the retry succeeds" "$(printf '%s' "$out" | jq -r .verdict)" changes

echo "F. turn-wait on a running turn"
done_note="$(jq -nc --argjson t "$(turn completed "$ANSWER")" '{method:"turn/completed",params:{threadId:"th",turn:$t}}')"
approval='{"id":77,"method":"item/commandExecution/requestApproval","params":{}}'
scenario "$(jq -nc --argjson l "$(listing "$(turn inProgress "")")" --argjson n "$done_note" --argjson a "$approval" \
  '{responses:{"thread/turns/list":$l},after:{"thread/turns/list":[$a,$n]}}')"
out="$(rpc turn-wait --thread th --turn turn-1 --budget 5 --schema "$SCHEMA")"; rc=$?
is "it waits for turn/completed and exits 0" "$rc" 0
is "with the answer" "$(printf '%s' "$out" | jq -r '.findings[0].severity')" P1
is "a server approval request is declined" "$(jq -c 'select(.id == 77) | .result.decision' "$FAKE_LOG")" '"decline"'

echo "F2. a flood of other notifications before turn/completed is still handled"
# _other keeps only turn/completed notifications and drops the rest, so wait_note's rescan
# stays cheap over a long review turn that streams many delta notes. This asserts
# correctness is preserved when hundreds of unrelated notifications precede the one that
# matters; it is not a timing benchmark (the O(N^2) case at daemon scale was 20,000 deltas
# taking 6.7s under the old code).
deltas="$(jq -nc '[range(300) | {method:"item/agentMessage/delta",params:{}}]')"
scenario "$(jq -nc --argjson l "$(listing "$(turn inProgress "")")" --argjson ds "$deltas" --argjson n "$done_note" \
  '{responses:{"thread/turns/list":$l},after:{"thread/turns/list":($ds + [$n])}}')"
out="$(rpc turn-wait --thread th --turn turn-1 --budget 5 --schema "$SCHEMA")"; rc=$?
is "F2 it exits 0 despite hundreds of other notifications first" "$rc" 0
is "F2 with the answer" "$(printf '%s' "$out" | jq -r '.findings[0].severity')" P1

echo "F3. a turn/completed notification with a partial items view triggers a re-read"
# A resumed subscriber is not guaranteed the final text in the notification itself
# (F5/F17): an empty items view must not be taken as "no answer" — re-read the turn.
partial_done="$(jq -nc '{method:"turn/completed",params:{threadId:"th",turn:{id:"turn-1",status:"completed",items:[]}}}')"
scenario "$(jq -nc --argjson l1 "$(listing "$(turn inProgress "")")" --argjson l2 "$(listing "$(turn completed "$ANSWER")")" \
  --argjson n "$partial_done" \
  '{responses:{"thread/turns/list":[$l1,$l2]},after:{"thread/turns/list":[$n]}}')"
out="$(rpc turn-wait --thread th --turn turn-1 --budget 5 --schema "$SCHEMA")"; rc=$?
is "F3 it exits 0 despite the notification's empty items" "$rc" 0
is "F3 with the re-read answer" "$(printf '%s' "$out" | jq -r '.findings[0].severity')" P1
is "F3 the turn was re-read on the thread, not trusted from the notification" \
   "$(jq -r 'select(.method=="thread/turns/list") | .method' "$FAKE_LOG" | grep -c .)" 2

echo "F4. a stale re-read (still inProgress) never overwrites the notification's completed turn"
partial_done2="$(jq -nc '{method:"turn/completed",params:{threadId:"th",turn:{id:"turn-1",status:"completed",items:[]}}}')"
scenario "$(jq -nc --argjson l1 "$(listing "$(turn inProgress "")")" \
  --argjson l2 "$(listing "$(turn inProgress "")")" \
  --argjson l3 "$(listing "$(turn completed "$ANSWER")")" \
  --argjson n "$partial_done2" \
  '{responses:{"thread/turns/list":[$l1,$l2,$l3]},after:{"thread/turns/list":[$n]}}')"
out="$(rpc turn-wait --thread th --turn turn-1 --budget 5 --schema "$SCHEMA")"; rc=$?
is "F4 it exits 0 despite the stale re-read" "$rc" 0
is "F4 with the eventually-fresh answer, not the notification's empty one" \
   "$(printf '%s' "$out" | jq -r '.findings[0].severity')" P1
is "F4 the re-read was retried until it was terminal" \
   "$(jq -r 'select(.method=="thread/turns/list") | .method' "$FAKE_LOG" | grep -c .)" 3

echo "F5. the budget can end mid re-read too - still exit 3 (still running), never exit 1 (M5)"
partial_done3="$(jq -nc '{method:"turn/completed",params:{threadId:"th",turn:{id:"turn-1",status:"completed",items:[]}}}')"
scenario "$(jq -nc --argjson l "$(listing "$(turn inProgress "")")" --argjson n "$partial_done3" \
  '{responses:{"thread/turns/list":$l},after:{"thread/turns/list":[$n]}}')"
out="$(rpc turn-wait --thread th --turn turn-1 --budget 2 --schema "$SCHEMA" 2>&1)"; rc=$?
is "F5 it exits 3, not 1, when the re-read never catches up before the budget ends" "$rc" 3
is "F5 and says the turn is still running" "$(printf '%s' "$out" | grep -c 'still running')" 1

echo "G. still running at the budget"
scenario "$(jq -nc --argjson l "$(listing "$(turn inProgress "")")" '{responses:{"thread/turns/list":$l}}')"
rpc turn-wait --thread th --turn turn-1 --budget 1 --schema "$SCHEMA" >/dev/null 2>&1
is "it exits 3" "$?" 3

echo "G2. a drop after the turn is seen running exits 3, not 5 (never re-dispatch either way)"
scenario "$(jq -nc --argjson l "$(listing "$(turn inProgress "")")" '{runs:[{responses:{"thread/turns/list":$l},exit_after:3}]}')"
out="$(rpc turn-wait --thread th --turn turn-1 --budget 2 --schema "$SCHEMA" 2>&1)"; rc=$?
is "it exits 3, not 5" "$rc" 3
is "and says the turn is still running, not unreachable" "$(printf '%s' "$out" | grep -c 'still running')" 1
is "it had reconnected more than once before giving up" \
   "$([ "$(cat "$FAKE_COUNTER" 2>/dev/null || echo 0)" -gt 1 ] && echo yes || echo no)" yes

echo "H. a turn that did not complete"
scenario "$(jq -nc --argjson l "$(listing "$(turn failed "")")" '{responses:{"thread/turns/list":$l}}')"
out="$(rpc turn-wait --thread th --turn turn-1 --budget 5 --schema "$SCHEMA" 2>&1)"; rc=$?
is "H1 a failed turn exits 1" "$rc" 1
is "H1 and says failed" "$(printf '%s' "$out" | grep -c failed)" 1
scenario "$(jq -nc --argjson l "$(listing "$(turn interrupted "")")" '{responses:{"thread/turns/list":$l}}')"
out="$(rpc turn-wait --thread th --turn turn-1 --budget 5 --schema "$SCHEMA" 2>&1)"; rc=$?
is "H2 an interrupted turn (f12 in the pane) exits 1" "$rc" 1
is "H2 and says interrupted" "$(printf '%s' "$out" | grep -c interrupted)" 1
scenario '{"responses":{"thread/turns/list":{"result":{"data":[]}}}}'
out="$(rpc turn-wait --thread th --turn turn-1 --budget 5 --schema "$SCHEMA" 2>&1)"; rc=$?
is "H3 an unknown turn exits 1" "$rc" 1
is "H3 and says there is no such turn" "$(printf '%s' "$out" | grep -c 'no turn')" 1
scenario '{"responses":{"thread/turns/list":{"error":{"code":-1,"message":"nope"}}}}'
out="$(rpc turn-wait --thread th --turn turn-1 --budget 2 --schema "$SCHEMA" 2>&1)"; rc=$?
is "H4 a known turn id with persistent list errors still exits 1" "$rc" 1
is "H4 but says the turns could not be read, not 'no turn'" \
   "$(printf '%s' "$out" | grep -c 'could not be read')" 1
is "H4 and never claims there is no such turn" "$(printf '%s' "$out" | grep -c 'no turn')" 0

echo "I. answers that do not match the schema"
for bad in 'not json at all' '{"verdict":"maybe","findings":[]}' \
           "$(printf '```json\n%s\n```' "$ANSWER")" \
           '{"verdict":"approve","findings":[{"severity":"P1","file":"a","line":"3","summary":"s","failure_scenario":"f"}]}'; do
  scenario "$(jq -nc --argjson l "$(listing "$(turn completed "$bad")")" '{responses:{"thread/turns/list":$l}}')"
  out="$(rpc turn-wait --thread th --turn turn-1 --budget 5 --schema "$SCHEMA" 2>/dev/null)"; rc=$?
  is "I '$(printf '%s' "$bad" | head -c 30)' exits 4" "$rc" 4
  is "I and the raw text is on stdout" "$out" "$bad"
done

echo "J. a dropped connection is resumed within the budget"
scenario "$(jq -nc --argjson l "$(listing "$(turn completed "$ANSWER")")" \
  '{runs:[{exit_after:2},{responses:{"thread/turns/list":$l}}]}')"
out="$(rpc turn-wait --thread th --turn turn-1 --budget 10 --schema "$SCHEMA")"; rc=$?
is "it reconnects and exits 0" "$rc" 0
is "on the second connection" "$(cat "$FAKE_COUNTER")" 2

echo "J2. an invalid JSON frame from the daemon is a dropped connection, not a traceback"
scenario "$(jq -nc --argjson l "$(listing "$(turn completed "$ANSWER")")" \
  '{runs:[{garbage_on:["thread/resume"]},{responses:{"thread/turns/list":$l}}]}')"
out="$(rpc turn-wait --thread th --turn turn-1 --budget 10 --schema "$SCHEMA" 2>"$T/err")"; rc=$?
is "it reconnects and exits 0, not a traceback" "$rc" 0
is "on the second connection" "$(cat "$FAKE_COUNTER")" 2
is "and nothing crashed with a Python traceback" "$(grep -c Traceback "$T/err")" 0

echo "L. the budget bounds connection setup too"
scenario '{"silent":["initialize"]}'
start=$(date +%s)
rpc turn-wait --thread th --turn turn-1 --budget 1 --schema "$SCHEMA" >/dev/null 2>&1; rc=$?
took=$(( $(date +%s) - start ))
is "a daemon that never answers initialize ends at the budget" "$([ "$took" -le 3 ] && echo yes || echo "no ($took s)")" yes
is "as unreachable (5)" "$rc" 5

echo "M. the WebSocket transport, over a socketpair"
out="$(python3 - "$RPC" <<'PY'
import importlib.machinery, importlib.util, json, socket, sys, threading, time
loader = importlib.machinery.SourceFileLoader("xreview_rpc", sys.argv[1])
spec = importlib.util.spec_from_loader("xreview_rpc", loader)
m = importlib.util.module_from_spec(spec); loader.exec_module(m)
# A handshake that dribbles one byte every 0.4 s never completes; the budget is 1 s.
a, b = socket.socketpair(socket.AF_UNIX)
def dribble():
    try:
        b.recv(4096)
        for _ in range(10):
            b.sendall(b"H"); time.sleep(0.4)
    except OSError:
        pass
threading.Thread(target=dribble, daemon=True).start()
t0 = time.monotonic()
try:
    m.WsTransport("socketpair", timeout=1, sock=a); res = "connected"
except m.Unreachable:
    res = "unreachable"
took = time.monotonic() - t0
# A real round trip: the 101 upgrade, then one unmasked server frame carrying JSON.
c, d = socket.socketpair(socket.AF_UNIX)
def serve():
    d.recv(4096)
    body = b'{"id":1}'
    d.sendall(b"HTTP/1.1 101 Switching Protocols\r\n\r\n" + bytes([0x81, len(body)]) + body)
threading.Thread(target=serve, daemon=True).start()
t = m.WsTransport("socketpair", timeout=5, sock=c)
print(res, "fast" if took < 1.6 else f"slow({took:.1f}s)", json.dumps(t.recv(2)))
PY
)"
is "a dribbling handshake ends at the budget, and a real frame round-trips" "$out" 'unreachable fast {"id": 1}'

echo "N. thread-resolve"
loadedlist() { jq -nc --argjson ids "$1" '{result:{data:($ids | map({id:.}))}}'; }
scenario "$(jq -nc --argjson l "$(loadedlist '["01a0e328-c41e-7de0-a526-042e024f74b9","bbbbbbbb-1111-4111-8111-111111111111"]')" '{responses:{"thread/loaded/list":$l}}')"
is "N1 a unique match prints the full id" \
   "$(rpc thread-resolve --prefix 01a0e328-c41e-7de0-a526-042e0)" "01a0e328-c41e-7de0-a526-042e024f74b9"
rpc thread-resolve --prefix 01a0e328-c41e-7de0-a526-042e0 >/dev/null 2>&1
is "N1 exits 0" "$?" 0
out="$(rpc thread-resolve --prefix ffffffff-ffff-4fff-8fff 2>&1)"; rc=$?
is "N2 no match exits 1" "$rc" 1
is "N2 and says so" "$(printf '%s' "$out" | grep -c 'no loaded thread')" 1
scenario "$(jq -nc --argjson l "$(loadedlist '["01a0e328-c41e-7de0-a526-042e024f74b9","01a0e328-c41e-7de0-a526-999999999999"]')" '{responses:{"thread/loaded/list":$l}}')"
out="$(rpc thread-resolve --prefix 01a0e328-c41e-7de0-a526 2>&1)"; rc=$?
is "N3 two matches exits 1" "$rc" 1
is "N3 and lists both" "$(printf '%s' "$out" | grep -c '2 loaded threads')" 1
scenario '{}'
out="$(rpc thread-resolve --prefix short 2>&1)"; rc=$?
is "N4 a prefix shorter than 13 chars is refused (2)" "$rc" 2
out="$(rpc thread-resolve --prefix '01a0e328-c41e-ZZZZ-a526-0' 2>&1)"; rc=$?
is "N5 a prefix with non-hex characters is refused (2)" "$rc" 2
is "N5 no daemon call was needed to refuse either one" "$(jq -r 'select(.method=="thread/loaded/list") | .method' "$FAKE_LOG" | grep -c .)" 0

echo "N6. thread-resolve accepts plain-string data items, not just {id: ...}"
loadedlist_strings() { jq -nc --argjson ids "$1" '{result:{data:$ids}}'; }
scenario "$(jq -nc --argjson l "$(loadedlist_strings '["01a0e328-c41e-7de0-a526-042e024f74b9","bbbbbbbb-1111-4111-8111-111111111111"]')" '{responses:{"thread/loaded/list":$l}}')"
is "N6 a unique match among plain-string ids" \
   "$(rpc thread-resolve --prefix 01a0e328-c41e-7de0-a526-042e0)" "01a0e328-c41e-7de0-a526-042e024f74b9"

echo "N7. thread-resolve follows nextCursor across pages"
page1="$(jq -nc '{result:{data:[{id:"01a0e328-c41e-7de0-a526-042e024f74b9"}],nextCursor:"c2"}}')"
page2="$(jq -nc '{result:{data:[{id:"cccccccc-3333-4333-8333-333333333333"}]}}')"
scenario "$(jq -nc --argjson p1 "$page1" --argjson p2 "$page2" '{responses:{"thread/loaded/list":[$p1,$p2]}}')"
is "N7 a match only on the second page is still found" \
   "$(rpc thread-resolve --prefix cccccccc-3333-4333-8333-3333)" "cccccccc-3333-4333-8333-333333333333"
is "N7 exactly two pages were fetched" \
   "$(jq -r 'select(.method=="thread/loaded/list") | .method' "$FAKE_LOG" | grep -c .)" 2
is "N7 the second call carried the first page's cursor" \
   "$(jq -c 'select(.method=="thread/loaded/list") | .params.cursor' "$FAKE_LOG" | sed -n '2p')" '"c2"'

echo "K. thread-archive"
scenario '{}'
rpc thread-archive --thread th; is "it exits 0" "$?" 0
is "it archives that thread" "$(params thread/archive | jq -r .threadId)" th

echo "R0. release building blocks"
export XDG_STATE_HOME="$T/state"
W="$(mkdir -p "$T/w/repo/sub" "$T/w/repo-x" && cd "$T/w" && pwd -P)"
ln -s "$W/repo" "$T/w/link"
load='import importlib.machinery, importlib.util, sys
loader = importlib.machinery.SourceFileLoader("xreview_rpc", sys.argv[1])
spec = importlib.util.spec_from_loader("xreview_rpc", loader)
m = importlib.util.module_from_spec(spec); loader.exec_module(m)'

out="$(python3 - "$RPC" "$W" "$T/w/link" <<PY
$load
w, link = sys.argv[2], sys.argv[3]
cases = [
    (w + "/repo", w + "/repo", True),
    (w + "/repo/sub", w + "/repo", True),
    (w + "/repo/gone/deeper", w + "/repo", True),   # a cwd that no longer exists
    (w + "/repo-x", w + "/repo", False),            # a sibling sharing the prefix
    (w + "/repo", w + "/repo-x", False),
    (w + "/repo", w + "/repo/", True),              # trailing slash on the dir
    (w + "/repo/sub", link, True),                  # the dir through a symlink
    (w, w + "/repo", False),                        # a parent is not under its child
]
bad = [c for c in cases if m.under(c[0], c[1]) != c[2]]
print("ok" if not bad else "bad " + repr(bad))
PY
)"
is "under() compares whole components, through symlinks, trailing slashes and missing paths" "$out" ok

rm -rf "$XDG_STATE_HOME"
out="$(python3 - "$RPC" "$XDG_STATE_HOME" <<PY
$load
import os
sd = m.state_dir()
ok = sd == os.path.join(sys.argv[2], "xreview-rpc")
m.write_record(sd, "th-1", "/x/repo")
m.write_record(sd, "th-2", "/x/repo-x")
ok &= m.read_records(sd) == [("th-1", "/x/repo"), ("th-2", "/x/repo-x")]
m.drop_record(sd, "th-1"); m.drop_record(sd, "th-1")   # dropping twice is harmless
ok &= m.read_records(sd) == [("th-2", "/x/repo-x")]
for bad_id in ("../evil", "a/b", "", ".hidden"):
    try:
        m.write_record(sd, bad_id, "/x"); ok = False
    except m.RecordError:
        pass
ok &= not os.path.exists(os.path.join(sd, "evil"))
pend = os.path.join(sd, "release-pending")
open(os.path.join(pend, "th-4.tmp"), "w").write("{")   # a write that never finished
ok &= m.read_records(sd) == [("th-2", "/x/repo-x")]
open(os.path.join(pend, "th-3"), "w").write("not json")
try:
    m.read_records(sd); ok = False
except m.RecordError as e:
    ok &= "th-3" in str(e)
for content in ("[]", "null"):
    open(os.path.join(pend, "th-3"), "w").write(content)
    try:
        m.read_records(sd); ok = False
    except m.RecordError:
        pass
os.remove(os.path.join(pend, "th-3"))
open(os.path.join(pend, "bad name"), "w").write('{"cwd": "/x"}')
try:
    m.read_records(sd); ok = False
except m.RecordError as e:
    ok &= "bad name" in str(e)
print("ok" if ok else "bad")
PY
)"
is "records round-trip, refuse non-id names, skip unfinished writes, fail on corrupt ones" "$out" ok

rm -rf "$XDG_STATE_HOME"
out="$(python3 - "$RPC" <<PY
$load
import os, subprocess, time
sd = m.state_dir()
fd = m.take_lock(sd, time.monotonic() + 1)
ok = fd is not None
probe = "import fcntl,os,sys; fd=os.open(sys.argv[1], os.O_RDWR); fcntl.flock(fd, fcntl.LOCK_EX|fcntl.LOCK_NB)"
lock = os.path.join(sd, "release.lock")
ok &= subprocess.run([sys.executable, "-c", probe, lock], stderr=subprocess.DEVNULL).returncode != 0
os.close(fd)
holder = subprocess.Popen([sys.executable, "-c",
    "import fcntl,os,sys,time; fd=os.open(sys.argv[1], os.O_RDWR); fcntl.flock(fd, fcntl.LOCK_EX); print('held', flush=True); time.sleep(30)",
    lock], stdout=subprocess.PIPE)
holder.stdout.readline()
t0 = time.monotonic()
ok &= m.take_lock(sd, time.monotonic() + 0.4) is None
ok &= time.monotonic() - t0 >= 0.4
holder.kill(); holder.wait()
fd = m.take_lock(sd, time.monotonic() + 1)
ok &= fd is not None   # SIGKILL freed it
os.close(fd)
# A waiter whose holder lets go before the deadline gets the lock in that same call. The
# holder lets go only once the busy mark shows the waiter has met it, so no timing is assumed.
mark = os.path.join(os.path.dirname(sd), "busy-mark")
os.environ["XREVIEW_RPC_LOCK_BUSY_MARK"] = mark
holder = subprocess.Popen([sys.executable, "-c",
    "import fcntl,os,sys,time\n"
    "fd=os.open(sys.argv[1], os.O_RDWR); fcntl.flock(fd, fcntl.LOCK_EX); print('held', flush=True)\n"
    "end=time.monotonic()+10\n"
    "while not os.path.exists(sys.argv[2]) and time.monotonic()<end: time.sleep(0.02)",
    lock, mark], stdout=subprocess.PIPE)
holder.stdout.readline()
fd = m.take_lock(sd, time.monotonic() + 30)
ok &= fd is not None and os.path.exists(mark)
holder.wait(timeout=20)
del os.environ["XREVIEW_RPC_LOCK_BUSY_MARK"]
print("ok" if ok else "bad")
PY
)"
is "the lock is exclusive across processes, times out, is freed by a killed holder, and is taken once freed" "$out" ok

: > "$T/afile"
out="$(XDG_STATE_HOME="$T/afile" python3 - "$RPC" <<PY
$load
import time
try:
    m.take_lock(m.state_dir(), time.monotonic() + 1); print("bad")
except OSError:
    print("ok")
PY
)"
is "a state directory that cannot be created raises OSError" "$out" ok

scenario '{"responses":{"thread/list":[{"result":{"data":[{"id":"other"}],"nextCursor":"p2"}},{"result":{"data":[{"id":"th"}]}}]}}'
out="$(python3 - "$RPC" <<PY
$load
print(m.archived(m.Client(), "th", "/x/repo"))
PY
)"
is "archived() follows pages and finds the thread" "$out" True
is "it asks for archived threads of the exact cwd, all ten source kinds" \
   "$(params thread/list | jq -c '[.archived, .cwd, (.sourceKinds | length)]')" '[true,["/x/repo"],10]'
is "the second page is asked for by cursor" \
   "$(jq -c 'select(.method == "thread/list") | .params.cursor' "$FAKE_LOG" | tail -1)" '"p2"'
scenario '{"responses":{"thread/list":{"result":{"data":[]}}}}'
is "archived() is False when the listing lacks the thread" \
   "$(python3 - "$RPC" <<PY
$load
print(m.archived(m.Client(), "th", "/x/repo"))
PY
)" False
scenario '{"responses":{"thread/list":{"error":{"code":-1,"message":"nope"}}}}'
is "archived() is None when the listing fails" \
   "$(python3 - "$RPC" <<PY
$load
print(m.archived(m.Client(), "th", "/x/repo"))
PY
)" None

scenario '{"responses":{"thread/loaded/list":[{"result":{"data":["a"],"nextCursor":"c"}},{"result":{"data":[{"id":"b"}]}}]}}'
is "loaded_ids() follows pages and accepts ids or objects" \
   "$(python3 - "$RPC" <<PY
$load
print(m.loaded_ids(m.Client()))
PY
)" "['a', 'b']"
scenario '{"responses":{"thread/loaded/list":{"error":{"code":-1,"message":"nope"}}}}'
is "loaded_ids() is None when a page fails" \
   "$(python3 - "$RPC" <<PY
$load
print(m.loaded_ids(m.Client()))
PY
)" None
scenario '{"responses":{"thread/list":[{"result":{"data":[],"nextCursor":"p2"}},{"error":{"code":-1,"message":"nope"}}]}}'
is "archived() is None when a later page fails" \
   "$(python3 - "$RPC" <<PY
$load
print(m.archived(m.Client(), "th", "/x/repo"))
PY
)" None
scenario '{"responses":{"thread/loaded/list":[{"result":{"data":["a"],"nextCursor":"c"}},{"error":{"code":-1,"message":"nope"}}]}}'
is "loaded_ids() is None when a later page fails" \
   "$(python3 - "$RPC" <<PY
$load
print(m.loaded_ids(m.Client()))
PY
)" None
unset XDG_STATE_HOME

echo "R. release --dir"
export XDG_STATE_HOME="$T/state"
PEND="$XDG_STATE_HOME/xreview-rpc/release-pending"
pending() { ls "$PEND" 2>/dev/null | grep -v '\.tmp$' | tr '\n' ' ' | sed 's/ $//'; }
record() { mkdir -p "$PEND"; printf '{"cwd":"%s"}' "$2" > "$PEND/$1"; }   # record <id> <cwd>
methods() { jq -r 'select(.id != null and .method != "initialize") | .method + " " + (.params.threadId // "")' "$FAKE_LOG" | tr '\n' '|'; }
th() { # th <id> <cwd> <status> [ephemeral]
  jq -nc --arg id "$1" --arg cwd "$2" --arg s "$3" --argjson e "${4:-false}" \
    '{result:{thread:{id:$id,cwd:$cwd,status:{type:$s},ephemeral:$e}}}'
}
NOTARCH='{"result":{"data":[]}}'
ARCH() { printf '{"result":{"data":[{"id":"%s"}]}}' "$1"; }
ERR='{"error":{"code":-1,"message":"nope"}}'
fresh() { rm -rf "$XDG_STATE_HOME"; }

fresh
scenario "$(jq -nc --argjson a "$(th a "$W/repo" idle)" --argjson b "$(th b "$W/repo/sub" idle)" \
  --argjson x "$(th x "$W/repo-x" idle)" --argjson n "$NOTARCH" \
  '{responses:{"thread/loaded/list":{result:{data:["a","b","x"]}},"thread/read":[$a,$b,$x],"thread/list":$n}}')"
out="$(rpc release --dir "$T/w/link")"; rc=$?
is "R1 release exits 0 once every selected thread is released" "$rc" 0
is "R1 the checkout and its subdirectory are selected, the prefix sibling is not" "$out" $'released a\nreleased b'
is "R1 each thread is archived, restored, then confirmed, in that order" "$(methods)" \
   "thread/loaded/list |thread/read a|thread/read b|thread/read x|thread/archive a|thread/unarchive a|thread/list |thread/archive b|thread/unarchive b|thread/list |"
is "R1 no record is left" "$(pending)" ""

fresh
scenario "$(jq -nc --argjson a "$(th a "$W/repo" idle)" --argjson b "$(th b "$W/repo" idle)" --argjson n "$NOTARCH" \
  '{responses:{"thread/loaded/list":[{result:{data:["a"],nextCursor:"c"}},{result:{data:["b"]}}],"thread/read":[$a,$b],"thread/list":$n}}')"
is "R2 loaded threads are read across pages" "$(rpc release --dir "$W/repo")" $'released a\nreleased b'

fresh
scenario "$(jq -nc --argjson a "$(th a "$W/repo" idle)" --argjson b "$(th b "$W/repo" active)" \
  '{responses:{"thread/loaded/list":{result:{data:["a","b"]}},"thread/read":[$a,$b]}}')"
rpc release --dir "$W/repo" 2>"$T/err"; rc=$?
is "R3 a running thread refuses (1)" "$rc" 1
grep -q "b is running a turn — let it finish, or open it with codex resume b and interrupt it" "$T/err" \
  && _pass "R3 the refusal names the running thread" || _fail "R3 the refusal names the running thread" "$(cat "$T/err")"
is "R3 nothing is archived" "$(grep -c 'thread/archive' "$FAKE_LOG")" 0

fresh
scenario "$(jq -nc --argjson e "$ERR" '{responses:{"thread/loaded/list":{result:{data:["a"]}},"thread/read":$e}}')"
rpc release --dir "$W/repo" 2>"$T/err"; rc=$?
is "R4 an unreadable thread that is still loaded refuses (1)" "$rc" 1
grep -q "cannot read Codex session a" "$T/err" && _pass "R4 the refusal names it" || _fail "R4 the refusal names it" "$(cat "$T/err")"
is "R4 nothing is archived" "$(grep -c 'thread/archive' "$FAKE_LOG")" 0
scenario "$(jq -nc --argjson e "$ERR" '{responses:{"thread/loaded/list":[{result:{data:["a"]}},{result:{data:[]}}],"thread/read":$e}}')"
out="$(rpc release --dir "$W/repo")"; rc=$?
is "R4 an unreadable thread that has since unloaded is skipped" "$rc:$out" "0:"

fresh
scenario "$(jq -nc --argjson a "$(th a "$W/repo" idle)" --argjson e "$ERR" --argjson n "$NOTARCH" \
  '{responses:{"thread/loaded/list":{result:{data:["a"]}},"thread/read":$a,"thread/archive":$e,"thread/list":$n}}')"
rpc release --dir "$W/repo" 2>"$T/err"; rc=$?
is "R5 a failed archive exits 1" "$rc" 1
grep -q "a: archive failed: nope" "$T/err" && _pass "R5 the failure names the thread" || _fail "R5 the failure names the thread" "$(cat "$T/err")"
is "R5 a thread confirmed not archived has its record dropped" "$(pending)" ""
fresh
scenario "$(jq -nc --argjson a "$(th a "$W/repo" idle)" --argjson e "$ERR" --argjson l "$(ARCH a)" \
  '{responses:{"thread/loaded/list":{result:{data:["a"]}},"thread/read":$a,"thread/archive":$e,"thread/list":$l}}')"
rpc release --dir "$W/repo" 2>/dev/null
is "R5 a failed archive that did archive keeps the record" "$(pending)" a

fresh
scenario "$(jq -nc --argjson a "$(th a "$W/repo" idle)" --argjson e "$ERR" --argjson l "$(ARCH a)" \
  '{responses:{"thread/loaded/list":{result:{data:["a"]}},"thread/read":$a,"thread/unarchive":$e,"thread/list":$l}}')"
rpc release --dir "$W/repo" 2>"$T/err"; rc=$?
is "R6 an unconfirmed restore exits 1" "$rc" 1
grep -q "a is archived and could not be restored yet" "$T/err" && _pass "R6 it says the restore is owed" || _fail "R6 it says the restore is owed" "$(cat "$T/err")"
is "R6 the record is kept" "$(pending)" a
fresh
record a "$W/repo"
scenario "$(jq -nc --argjson b "$(th b "$W/repo" idle)" --argjson l "$(ARCH a)" \
  '{responses:{"thread/loaded/list":{result:{data:["b"]}},"thread/read":$b,"thread/list":$l}}')"
rpc release --dir "$W/repo" 2>"$T/err"; rc=$?
is "R6 an owed restore refuses before anything is selected or archived" "$rc:$(methods):$(pending)" "1:thread/unarchive a|thread/list |:a"
grep -q "a is archived and could not be restored yet" "$T/err" && _pass "R6 it names the owed restore" || _fail "R6 it names the owed restore" "$(cat "$T/err")"
fresh
scenario "$(jq -nc --argjson a "$(th a "$W/repo" idle)" --argjson e "$ERR" \
  '{responses:{"thread/loaded/list":{result:{data:["a"]}},"thread/read":$a,"thread/list":$e}}')"
rpc release --dir "$W/repo" 2>/dev/null; rc=$?
is "R6 a failed confirmation listing exits 1 and keeps the record" "$rc:$(pending)" "1:a"

fresh
scenario "$(jq -nc --argjson a "$(th a "$W/repo" idle)" --argjson n "$NOTARCH" \
  '{runs:[{responses:{"thread/loaded/list":{result:{data:["a"]}},"thread/read":$a},drop_on:["thread/unarchive"]},
          {responses:{"thread/loaded/list":{result:{data:[]}},"thread/list":$n}}]}')"
rpc release --dir "$W/repo" 2>/dev/null; rc=$?
is "R7 a connection lost after archive exits 1, not 5" "$rc" 1
is "R7 the record survives the lost connection" "$(pending)" a
: > "$FAKE_LOG"
out="$(rpc release --dir "$W/repo")"; rc=$?
is "R7 the next run restores it first, then finds nothing loaded" "$rc:$out" "0:"
is "R7 the restore precedes the selection" "$(methods)" "thread/unarchive a|thread/list |thread/loaded/list |"
is "R7 the record is gone" "$(pending)" ""

# A restore that is confirmed but whose record cannot be removed is not an owed restore.
fresh
record a "$W/repo"
chmod 500 "$PEND"
scenario "$(jq -nc --argjson n "$NOTARCH" '{responses:{"thread/loaded/list":{result:{data:[]}},"thread/list":$n}}')"
rpc release --dir "$W/repo" 2>"$T/err"; rc=$?
chmod 700 "$PEND"
is "R7 a confirmed restore whose record cannot be removed exits 1 and keeps the record" "$rc:$(pending)" "1:a"
grep -q "a was restored, but its record could not be removed" "$T/err" && ! grep -q "could not be restored yet" "$T/err" \
  && _pass "R7 it says the record, not the restore, is the problem" || _fail "R7 it says the record, not the restore, is the problem" "$(cat "$T/err")"

# A thread whose archive failed and is confirmed not archived owes no restore either. The
# record is made undeletable at the moment the archive fails, by a stand-in for the client.
fresh
out="$(python3 - "$RPC" "$XDG_STATE_HOME/xreview-rpc" "$W/repo" <<PY
$load
import contextlib, io, os
sd, d = sys.argv[2], sys.argv[3]
pend = os.path.join(sd, "release-pending")
class C:
    def call(self, meth, params, timeout=30):
        if meth == "thread/loaded/list":
            return {"result": {"data": ["a"]}}
        if meth == "thread/read":
            return {"result": {"thread": {"cwd": d, "status": {"type": "idle"}}}}
        if meth == "thread/archive":
            os.chmod(pend, 0o500)
            return {"error": {"code": -1, "message": "nope"}}
        return {"result": {"data": []}}
buf = io.StringIO()
try:
    with contextlib.redirect_stderr(buf):
        rc = m.release(C(), sd, d, [])
finally:
    os.chmod(pend, 0o700)
msg = buf.getvalue()
ok = rc == 1 and os.listdir(pend) == ["a"] and "a: archive failed: nope; its record could not be removed" in msg
print("ok" if ok and "could not be restored yet" not in msg else "bad " + msg)
PY
)"
is "R7 a failed archive whose record cannot be removed exits 1, keeps the record and does not claim an owed restore" "$out" ok

fresh
scenario "$(jq -nc --argjson a "$(th a "$W/repo" idle)" '{responses:{"thread/loaded/list":{result:{data:["a"]}},"thread/read":$a},drop_on:["thread/archive"]}')"
rpc release --dir "$W/repo" 2>/dev/null
is "R8 the record is written before the archive is sent" "$(pending)" a

fresh
record a "$W/repo"
scenario "$(jq -nc --argjson n "$NOTARCH" '{responses:{"thread/unarchive":{error:{code:-32600,message:"no archived rollout found for thread id a"}},"thread/list":$n,"thread/loaded/list":{result:{data:[]}}}}')"
rpc release --dir "$W/repo"; rc=$?
is "R9 'no archived rollout found' with the listing clear counts as restored" "$rc:$(pending)" "0:"

fresh
record a "$W/repo"
XREVIEW_RPC_STDIO=false rpc release --dir "$W/repo" 2>"$T/err"; rc=$?
is "R10 an unreachable daemon with a restore owed under --dir exits 1, not 5" "$rc" 1
grep -q "a is archived and could not be restored yet" "$T/err" && _pass "R10 it names the owed restore" || _fail "R10 it names the owed restore" "$(cat "$T/err")"
fresh
record x "$W/repo-x"
XREVIEW_RPC_STDIO=false rpc release --dir "$W/repo" 2>/dev/null; rc=$?
is "R10 a record for another directory does not turn unreachable into 1" "$rc" 5
scenario '{"responses":{"thread/loaded/list":{"result":{"data":[]}}}}'
rpc release --dir "$W/repo"; rc=$?
is "R10 a record for another directory is left alone" "$rc:$(pending):$(grep -c 'thread/unarchive' "$FAKE_LOG")" "0:x:0"

fresh
scenario "$(jq -nc --argjson e "$(th e "$W/repo" idle true)" \
  '{responses:{"thread/loaded/list":[{result:{data:["e"]}},{result:{data:["e"]}},{error:{code:-1,message:"x"}},{result:{data:[]}}],"thread/read":$e}}')"
out="$(XREVIEW_RPC_EPHEMERAL_POLL=0.01 rpc release --dir "$W/repo" 2>"$T/err")"; rc=$?
is "R11 an ephemeral thread is waited out, a failed poll counting as loaded" "$rc:$out" "0:released e"
grep -q "waiting for ephemeral e to unload (up to 90 s)" "$T/err" && _pass "R11 the wait is announced" || _fail "R11 the wait is announced" "$(cat "$T/err")"
is "R11 an ephemeral thread is never archived" "$(grep -c 'thread/archive' "$FAKE_LOG")" 0
scenario "$(jq -nc --argjson e "$(th e "$W/repo" idle true)" '{responses:{"thread/loaded/list":{result:{data:["e"]}},"thread/read":$e}}')"
XREVIEW_RPC_EPHEMERAL_WAIT=0.2 XREVIEW_RPC_EPHEMERAL_POLL=0.05 rpc release --dir "$W/repo" 2>"$T/err"; rc=$?
is "R11 an ephemeral thread still loaded at the end of the wait exits 1" "$rc" 1
grep -q "e (ephemeral) is still loaded — close the Codex client using it" "$T/err" && _pass "R11 it names the thread" || _fail "R11 it names the thread" "$(cat "$T/err")"
XREVIEW_RPC_RELEASE_DEADLINE=1 XREVIEW_RPC_EPHEMERAL_POLL=5 rpc release --dir "$W/repo" 2>"$T/err"; rc=$?
is "R11 a deadline that ends the wait first still exits 1" "$rc" 1
grep -q "e (ephemeral) is still loaded — close the Codex client using it" "$T/err" && _pass "R11 it gives the same message, not a lost connection" || _fail "R11 it gives the same message, not a lost connection" "$(cat "$T/err")"

fresh
scenario "$(jq -nc --argjson x "$(th x "$W/repo-x" idle)" '{responses:{"thread/loaded/list":{result:{data:["x"]}},"thread/read":$x}}')"
out="$(rpc release --dir "$W/repo")"; rc=$?
is "R12 nothing under --dir: exit 0, no output, nothing archived" "$rc:$out:$(grep -c 'thread/archive' "$FAKE_LOG")" "0::0"
XREVIEW_RPC_STDIO=false rpc release --dir "$W/repo" 2>/dev/null; rc=$?
is "R12 an unreachable daemon with nothing owed exits 5" "$rc" 5

fresh
scenario "$(jq -nc --argjson a "$(th '../evil' "$W/repo" idle)" '{responses:{"thread/loaded/list":{result:{data:["../evil"]}},"thread/read":$a}}')"
rpc release --dir "$W/repo" 2>/dev/null; rc=$?
is "R13 a thread id that is not a plain name refuses (1)" "$rc" 1
is "R13 it archives nothing and writes nothing outside the record directory" \
   "$(grep -c 'thread/archive' "$FAKE_LOG"):$(ls "$XDG_STATE_HOME/xreview-rpc" | tr '\n' ' ')" "0:release.lock "

fresh
mkdir -p "$PEND"; printf 'not json' > "$PEND/bad"
scenario '{"responses":{"thread/loaded/list":{"result":{"data":[]}}}}'
rpc release --dir "$W/repo" 2>"$T/err"; rc=$?
is "R14 a corrupt pending record fails closed (1)" "$rc" 1
grep -q "bad" "$T/err" && _pass "R14 the error names the record" || _fail "R14 the error names the record" "$(cat "$T/err")"
is "R14 nothing is sent to the daemon" "$(wc -l < "$FAKE_LOG" | tr -d ' ')" 0

fresh
scenario '{"responses":{"thread/loaded/list":{"result":{"data":[]}}}}'
rpc release --dir "$W/nope" 2>/dev/null; rc=$?
is "R15 a --dir that is not a directory is a usage error (2)" "$rc:$(wc -l < "$FAKE_LOG" | tr -d ' ')" "2:0"

fresh
mkdir -p "$XDG_STATE_HOME/xreview-rpc"
python3 -c 'import fcntl,os,sys,time; fd=os.open(sys.argv[1], os.O_RDWR|os.O_CREAT, 0o600); fcntl.flock(fd, fcntl.LOCK_EX); open(sys.argv[2],"w").close(); time.sleep(60)' \
  "$XDG_STATE_HOME/xreview-rpc/release.lock" "$T/held" &
holder=$!
for _ in $(seq 100); do [ -e "$T/held" ] && break; sleep 0.1; done
scenario '{"responses":{"thread/loaded/list":{"result":{"data":[]}}}}'
XREVIEW_RPC_RELEASE_DEADLINE=0.5 rpc release --dir "$W/repo" 2>"$T/err"; rc=$?
is "R16 a release still blocked on the lock at its deadline exits 1" "$rc" 1
grep -q "another release is running" "$T/err" && _pass "R16 it says why" || _fail "R16 it says why" "$(cat "$T/err")"
is "R16 it sent nothing to the daemon" "$(wc -l < "$FAKE_LOG" | tr -d ' ')" 0
kill -9 "$holder"; wait "$holder" 2>/dev/null
rpc release --dir "$W/repo"; is "R16 a holder killed with SIGKILL frees the lock" "$?" 0
: > "$T/afile"
XDG_STATE_HOME="$T/afile" rpc release --dir "$W/repo" 2>/dev/null; is "R16 an unusable state directory exits 1" "$?" 1

# The same waiting invocation must go on once the holder lets go: blocked, it sends nothing
# and writes no record; released, it does its whole job. The busy mark proves the waiter has
# met the lock before anything is asserted, and the holder lets go only after the assertions.
fresh
mkdir -p "$XDG_STATE_HOME/xreview-rpc"
rm -f "$T/held" "$T/go" "$T/busy"
python3 -c 'import fcntl,os,sys,time
fd=os.open(sys.argv[1], os.O_RDWR|os.O_CREAT, 0o600); fcntl.flock(fd, fcntl.LOCK_EX); open(sys.argv[2],"w").close()
while not os.path.exists(sys.argv[3]): time.sleep(0.05)' \
  "$XDG_STATE_HOME/xreview-rpc/release.lock" "$T/held" "$T/go" &
holder=$!
for _ in $(seq 100); do [ -e "$T/held" ] && break; sleep 0.1; done
scenario "$(jq -nc --argjson a "$(th a "$W/repo" idle)" --argjson n "$NOTARCH" \
  '{responses:{"thread/loaded/list":{result:{data:["a"]}},"thread/read":$a,"thread/list":$n}}')"
XREVIEW_RPC_LOCK_BUSY_MARK="$T/busy" rpc release --dir "$W/repo" > "$T/waiter.out" 2>"$T/err" &
waiter=$!
for _ in $(seq 300); do [ -e "$T/busy" ] && break; sleep 0.1; done
is "R17 the release meets the held lock" "$([ -e "$T/busy" ] && echo yes || echo no)" yes
is "R17 while waiting it sends nothing and writes no record" "$(wc -l < "$FAKE_LOG" | tr -d ' '):$(pending)" "0:"
: > "$T/go"; wait "$holder" 2>/dev/null
wait "$waiter"; rc=$?
is "R17 once the holder lets go, the same release finishes" "$rc:$(cat "$T/waiter.out")" "0:released a"

# A deadline that has passed is exit 1, never the "unreachable" exit 5 that lets wt-rm go on.
fresh
scenario '{"responses":{"thread/loaded/list":{"result":{"data":[]}}}}'
XREVIEW_RPC_RELEASE_DEADLINE=0 rpc release --dir "$W/repo" 2>/dev/null; rc=$?
is "R18 a deadline already passed when the lock is taken exits 1 and asks nothing" \
   "$rc:$(wc -l < "$FAKE_LOG" | tr -d ' ')" "1:0"
scenario '{"silent":["initialize"]}'
XREVIEW_RPC_RELEASE_DEADLINE=0.5 rpc release --dir "$W/repo" 2>/dev/null; rc=$?
is "R18 a connection that runs out of deadline exits 1, not 5" "$rc" 1
unset XDG_STATE_HOME
echo
echo "RESULT: $pass passed, $((pass + fail)) total, $fail failed"
[ "$fail" -eq 0 ]
