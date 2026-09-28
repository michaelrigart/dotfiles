#!/usr/bin/env bash
# Tests dot_local/bin/executable_xreview-rpc, xreview's client for the Codex daemon
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

echo "M6b. a cursor that never ends is reported as unreadable at the budget, never a false 'no turn'"
forever="$(jq -nc '{result:{data:[{id:"other",status:"completed",items:[]}], nextCursor:"forever"}}')"
scenario "$(jq -nc --argjson f "$forever" '{responses:{"thread/turns/list":[$f]}}')"
rpc turn-wait --thread th --turn turn-absent --budget 0.6 --schema "$SCHEMA" >/dev/null 2>"$T/err"; rc=$?
is "M6b it exits 1" "$rc" 1
is "M6b and reports the listing as unreadable, never a false 'no turn'" \
   "$(grep -c 'could not be read' "$T/err")" 1
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

echo
echo "RESULT: $pass passed, $((pass + fail)) total, $fail failed"
[ "$fail" -eq 0 ]
