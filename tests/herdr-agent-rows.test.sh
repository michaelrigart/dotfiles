#!/usr/bin/env bash
# Tests dot_config/herdr/plugin-agent-rows (the dev.agent-rows plugin): the manifest and
# agent-rows.py, whose worker spins a braille frame on working agent panes and words
# `blocked` as "needs you" (spec 2026-11-05-herdr-ui-refresh-design.md section 3).
#
# The sandbox denies unix sockets, so nothing here touches a real herdr: the loop runs against
# an injected FakeTransport, a fake clock and a fake select; the Transport's framing runs over
# socket.socketpair() (the xreview-rpc suite's pattern).
#
# Run: ./tests/run.sh herdr-agent-rows   (sandboxed is fine)
set -uo pipefail
export PINNED_PATH="$PATH"
export PYTHONDONTWRITEBYTECODE=1
SRC="$(cd "$(dirname "$0")/.." && pwd)"
DIR="$SRC/dot_config/herdr/plugin-agent-rows"
MANIFEST="$DIR/herdr-plugin.toml"
PLUGIN="$DIR/executable_agent-rows.py"
for f in "$MANIFEST" "$PLUGIN"; do
  [ -f "$f" ] || { echo "missing file under test: $f" >&2; exit 2; }
done
pass=0; fail=0
_pass() { printf '  PASS: %s\n' "$1"; pass=$((pass + 1)); }
_fail() { printf '  FAIL: %s\n    | got: %s\n' "$1" "$2"; fail=$((fail + 1)); }
is() { if [ "$2" = "$3" ]; then _pass "$1"; else _fail "$1" "$2"; fi; }

echo "A. Manifest and file"
is "manifest id" "$(grep -c '^id = "dev.agent-rows"$' "$MANIFEST")" 1
is "manifest name" "$(grep -c '^name = "Agent rows"$' "$MANIFEST")" 1
is "manifest version" "$(grep -c '^version = "0.1.0"$' "$MANIFEST")" 1
is "manifest min_herdr_version" "$(grep -c '^min_herdr_version = "0.9.0"$' "$MANIFEST")" 1
is "manifest platforms" "$(grep -c '^platforms = \["macos"\]$' "$MANIFEST")" 1
is "manifest has one startup hook" "$(grep -c '^\[\[startup\]\]$' "$MANIFEST")" 1
is "manifest startup command" "$(grep '^command = ' "$MANIFEST")" \
  'command = ["/bin/zsh", "-c", "exec /usr/bin/python3 -I \"$HOME/.config/herdr/plugin-agent-rows/agent-rows.py\" start"]'
is "manifest says how to link it" "$(grep -c 'herdr plugin link ~/.config/herdr/plugin-agent-rows' "$MANIFEST")" 1
is "manifest says unlink waits for the next server start" "$(grep -ci 'next server start' "$MANIFEST")" 1
is "plugin script has the absolute python shebang" "$(head -1 "$PLUGIN")" '#!/usr/bin/python3 -I'
if [ -x "$PLUGIN" ]; then _pass "plugin script is executable"; else _fail "plugin script is executable" "mode $(stat -f %Lp "$PLUGIN")"; fi
is "plugin script compiles on the system python3" \
  "$(/usr/bin/python3 -I -c 'import sys; compile(open(sys.argv[1]).read(), "agent-rows.py", "exec")' "$PLUGIN" 2>&1 && echo ok)" ok

T="$(mktemp -d "${TMPDIR:-/tmp}/herdr-agent-rows.XXXXXX")"; trap 'rm -rf "$T"' EXIT
cat > "$T/t.py" <<'PY'
import ast, fcntl, importlib.machinery, importlib.util, json, os, signal, socket, sys, tempfile, threading

PLUGIN = sys.argv[1]
loader = importlib.machinery.SourceFileLoader("agent_rows", PLUGIN)
spec = importlib.util.spec_from_loader("agent_rows", loader)
ar = importlib.util.module_from_spec(spec)
loader.exec_module(ar)

passed = failed = 0
def check(name, cond, got=None):
    global passed, failed
    if cond:
        passed += 1
        print("  PASS: %s" % name)
    else:
        failed += 1
        print("  FAIL: %s\n    | got: %s" % (name, got))

class FakeClock:
    def __init__(self): self.t = 0.0
    def __call__(self): return self.t
    def sleep(self, s): self.t += s

class FakeSub:
    def __init__(self, entries):
        self.entries = entries
        self.queue = []          # event batches, or an exception to raise from read_events
        self.closed = False
    def fileno(self): return 99
    def read_events(self):
        item = self.queue.pop(0)
        if isinstance(item, BaseException):
            raise item
        return item
    def close(self): self.closed = True

class FakeTransport:
    """Records every request; serves scripted snapshots (the last one repeats)."""
    def __init__(self, snapshots):
        self.snapshots = list(snapshots)
        self.snap_i = 0
        self.requests = []
        self.subs = []
        self.refuse = False
    def request(self, method, params):
        self.requests.append((method, params))
        if self.refuse:
            raise ConnectionRefusedError("refused")
        if method == "session.snapshot":
            s = self.snapshots[min(self.snap_i, len(self.snapshots) - 1)]
            self.snap_i += 1
            return {"id": "x", "result": {"type": "session_snapshot", "snapshot": s}}
        return {"id": "x", "result": {"type": "ok"}}
    def subscribe(self, subscriptions):
        self.requests.append(("events.subscribe", subscriptions))
        if self.refuse:
            raise ConnectionRefusedError("refused")
        sub = FakeSub(subscriptions)
        self.subs.append(sub)
        return sub

class FakeSelect:
    """Stands in for the module's `select`: when the live subscription has nothing queued it
    records the timeout, advances the fake clock by it, and runs the next script step."""
    def __init__(self, clock, stop, script):
        self.clock, self.stop, self.script = clock, stop, list(script)
        self.timeouts = []
    def select(self, rlist, wlist, xlist, timeout=None):
        sub = rlist[0]
        if sub.queue:
            return ([sub], [], [])
        self.timeouts.append(timeout)
        if timeout:
            self.clock.t += timeout
        if self.script:
            self.script.pop(0)(sub)
        else:
            self.stop.set()
        return ([sub], [], []) if sub.queue else ([], [], [])

def P(pid, status="idle", agent="claude"):
    return {"pane_id": pid, "agent": agent, "agent_status": status, "state_labels": {}, "tokens": {}}
def NP(pid):
    return {"pane_id": pid, "agent": None, "agent_status": "unknown", "state_labels": {}, "tokens": {}}
def snap(*panes): return {"panes": list(panes)}
def status_ev(pid, status):
    return {"event": "pane.agent_status_changed",
            "data": {"type": "pane_agent_status_changed", "pane_id": pid, "agent_status": status}}
def detected_ev(pid):
    return {"event": "pane.agent_detected",
            "data": {"type": "pane_agent_detected", "pane_id": pid, "agent": "claude"}}
def closed_ev(pid):
    return {"event": "pane.closed", "data": {"type": "pane_closed", "pane_id": pid}}
def moved_ev(prev, new, status="working"):
    return {"event": "pane.moved", "data": {"type": "pane_moved", "previous_pane_id": prev,
            "pane": {"pane_id": new, "agent": "claude", "agent_status": status}}}

def go(snapshots, script, setup=None):
    """Run the loop with fakes; returns (rc, transport, select, clock)."""
    clock, stop = FakeClock(), threading.Event()
    tr = FakeTransport(snapshots)
    if setup: setup(tr)
    fake = FakeSelect(clock, stop, script)
    real = ar.select
    ar.select = fake
    try:
        rc = ar.run(tr, clock, clock.sleep, stop)
    finally:
        ar.select = real
    return rc, tr, fake, clock

def reports(tr):
    return [p for m, p in tr.requests if m == "pane.report_metadata"]
def frames(tr, pid=None):
    return [p for p in reports(tr)
            if (p.get("tokens") or {}).get("spin") and (pid is None or p["pane_id"] == pid)]
def clears(tr, pid=None):
    return [p for p in reports(tr)
            if "tokens" in p and p["tokens"].get("spin", 1) is None and (pid is None or p["pane_id"] == pid)]
def labels(tr, pid=None):
    return [p for p in reports(tr) if "state_labels" in p and (pid is None or p["pane_id"] == pid)]
def noop(sub): pass

LABELS = {"blocked": "needs you"}

print("B. Constants")
check("frames are ten braille cells", ar.FRAMES == "⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏", ar.FRAMES)
check("constants", (ar.SOURCE, ar.TOKEN, ar.FRAME_S, ar.TTL_MS, ar.LABELS)
      == ("dev.agent-rows", "spin", 0.14, 1500, LABELS), (ar.SOURCE, ar.TOKEN, ar.FRAME_S, ar.TTL_MS, ar.LABELS))

print("C. Idle agents: labels once, then no work at all")
state = {}
def idle_a(sub): state["n0"] = len(state["tr"].requests); state["clock"].t += 50
def idle_b(sub): state["n1"] = len(state["tr"].requests)
clock, stop = FakeClock(), threading.Event()
tr = state["tr"] = FakeTransport([snap(P("w1:p1"), NP("w1:p9"), P("w1:p2", "done"))])
state["clock"] = clock
fake = FakeSelect(clock, stop, [idle_a, idle_b])
real = ar.select; ar.select = fake
try: rc = ar.run(tr, clock, clock.sleep, stop)
finally: ar.select = real
check("idle run returns 0", rc == 0, rc)
check("every agent pane, and only agent panes, gets the label",
      sorted(p["pane_id"] for p in labels(tr)) == ["w1:p1", "w1:p2"], labels(tr))
check("label report carries state_labels, the source and no tokens or ttl",
      all(p["state_labels"] == LABELS and p["source"] == "dev.agent-rows" and "tokens" not in p and "ttl_ms" not in p
          for p in labels(tr)), labels(tr))
check("no spin token while idle", not frames(tr) and not clears(tr), reports(tr))
check("no request over 50 fake seconds of waiting", state["n0"] == state["n1"], (state["n0"], state["n1"]))
check("the wait has no timeout while nothing works", all(t is None for t in fake.timeouts), fake.timeouts)
check("the lifecycle subscription is closed on exit", all(s.closed for s in tr.subs), [s.closed for s in tr.subs])

print("D. One working pane: a frame per tick")
rc, tr, fake, clock = go([snap(P("w1:p1", "working"), P("w1:p2", "idle"))], [noop] * 5)
fr = frames(tr)
check("five ticks, five frames", len(fr) == 5, len(fr))
check("frames go to the working pane only", {p["pane_id"] for p in fr} == {"w1:p1"}, [p["pane_id"] for p in fr])
check("every frame has ttl_ms 1500 and the source", all(p["ttl_ms"] == 1500 and p["source"] == "dev.agent-rows" for p in fr), fr)
check("frames cycle through FRAMES in order",
      [p["tokens"]["spin"] for p in fr] == [ar.FRAMES[i] for i in range(5)], [p["tokens"] for p in fr])
check("the wait is one frame interval after the first tick", set(fake.timeouts[1:]) == {ar.FRAME_S}, fake.timeouts)
check("no clear while it keeps working; one on shutdown",
      len(clears(tr)) == 1 and reports(tr)[-1] == clears(tr)[0], clears(tr))

print("E. working -> done")
mark = {}
def finish(sub): mark["n"] = len(tr_box[0].requests); sub.queue.append([status_ev("w1:p1", "done")])
def settled(sub): mark["m"] = len(tr_box[0].requests)
tr_box = [None]
def go_done():
    c, stop = FakeClock(), threading.Event()
    t = FakeTransport([snap(P("w1:p1", "working"))]); tr_box[0] = t
    f = FakeSelect(c, stop, [noop, noop, finish, settled, noop])
    real = ar.select; ar.select = f
    try: ar.run(t, c, c.sleep, stop)
    finally: ar.select = real
    return t, f
tr, fake = go_done()
cl = clears(tr, "w1:p1")
check("one clear, without ttl_ms", len(cl) == 1 and "ttl_ms" not in cl[0] and cl[0]["tokens"] == {"spin": None}, cl)
after = [p for m, p in tr.requests[mark["n"]:mark["m"]] if m == "pane.report_metadata"]
check("the clear goes out at once, and is the only report after the status change", after == cl, after)
check("the wait has no timeout again once nothing works", fake.timeouts[-1] is None and fake.timeouts[-2] is None, fake.timeouts)

print("F. Detection, labels and resubscribe")
rows = ar.Rows()
eff = rows.apply_snapshot(snap(P("w1:p1"), P("w1:p2", "working"), NP("w1:p3")))
check("snapshot labels each agent pane",
      sorted(r["pane_id"] for r in eff.reports if "state_labels" in r) == ["w1:p1", "w1:p2"], eff.reports)
check("snapshot that discovers panes sets resubscribe", eff.resubscribe is True, eff.resubscribe)
rows.mark_covered(frozenset(["w1:p1", "w1:p2"]))
eff = rows.apply_snapshot(snap(P("w1:p1"), P("w1:p2", "working")))
check("an unchanged pane set neither relabels nor resubscribes", eff.resubscribe is False and eff.reports == [], (eff.reports, eff.resubscribe))
eff = rows.apply_event(detected_ev("w1:p4"))
check("a detection labels the new pane and sets resubscribe",
      eff.resubscribe is True and [r["pane_id"] for r in eff.reports] == ["w1:p4"] and eff.reports[0]["state_labels"] == LABELS, eff.reports)
check("subscriptions(): 3 lifecycle entries plus one status entry per agent pane",
      rows.subscriptions()[:3] == [{"type": "pane.agent_detected"}, {"type": "pane.closed"}, {"type": "pane.moved"}]
      and sorted(s["pane_id"] for s in rows.subscriptions()[3:]) == ["w1:p1", "w1:p2", "w1:p4"]
      and all(s["type"] == "pane.agent_status_changed" for s in rows.subscriptions()[3:]), rows.subscriptions())
eff = rows.apply_event(status_ev("w9:p9", "working"))
check("a status event for an unknown pane is ignored",
      eff.reports == [] and {r["pane_id"] for r in rows.frame_effects("x").reports} == {"w1:p2"}, eff.reports)
eff = rows.apply_event({"event": "pane.created", "data": {"type": "pane_created"}})
check("an unrelated event does nothing", eff.reports == [] and eff.resubscribe is True, (eff.reports, eff.resubscribe))
rows2 = ar.Rows()
eff = rows2.apply_event({"event": "pane.agent_detected", "data": {"pane_id": "w1:p1", "agent": "claude"}})
check("the kind falls back to the line's event name, dotted or not", [r["pane_id"] for r in eff.reports] == ["w1:p1"], eff.reports)

def detect_script(sub): sub.queue.append([detected_ev("w1:p5")])
rc, tr, fake, clock = go([snap(P("w1:p1")), snap(P("w1:p1")), snap(P("w1:p1"), P("w1:p5"))], [detect_script, noop, noop])
check("the loop labels the detected pane once", len(labels(tr, "w1:p5")) == 1, labels(tr, "w1:p5"))
ids = lambda sub: sorted(s.get("pane_id", "") for s in sub.entries if s["type"] == "pane.agent_status_changed")
check("the next subscription names the detected pane", ids(tr.subs[-1]) == ["w1:p1", "w1:p5"], [ids(s) for s in tr.subs])

print("G. pane_moved")
def move(sub): sub.queue.append([moved_ev("w1:p1", "w2:p1")])
w1 = snap(P("w1:p1", "working"))
w2 = snap(P("w2:p1", "working"))
cut = {}
def mark_move(sub): cut["n"] = len(cut["tr"].requests); move(sub)
def go_move():
    c, stop = FakeClock(), threading.Event()
    t = FakeTransport([w1, w1, w2]); cut["tr"] = t
    f = FakeSelect(c, stop, [noop, mark_move, noop, noop, noop])
    real = ar.select; ar.select = f
    try: ar.run(t, c, c.sleep, stop)
    finally: ar.select = real
    return t
tr = go_move()
post = [p for m, p in tr.requests[cut["n"]:] if m == "pane.report_metadata"]
check("frames reach the new id after the move", len([p for p in post if p["pane_id"] == "w2:p1" and p.get("tokens", {}).get("spin")]) >= 3, post)
check("no frame goes to the old id after the move",
      not [p for p in post if p["pane_id"] == "w1:p1" and p.get("tokens", {}).get("spin")], post)
check("the old id's frame is cleared", [p["tokens"] for p in post if p["pane_id"] == "w1:p1"] == [{"spin": None}], post)
check("the new id gets its label again", len([p for p in post if p["pane_id"] == "w2:p1" and "state_labels" in p]) == 1, post)
check("the next subscription names w2:p1, not w1:p1", ids(tr.subs[-1]) == ["w2:p1"], [ids(s) for s in tr.subs])
check("the old subscription is closed", all(s.closed for s in tr.subs[:-1]), [s.closed for s in tr.subs])

rows = ar.Rows()
rows.apply_snapshot(snap(P("w1:p1", "working")))
rows.mark_covered(["w1:p1"])
rows.frame_effects("x")
eff = rows.apply_event(moved_ev("w1:p1", "w2:p1"))
check("the move itself relabels the new id and clears the old one, before any resync",
      [(r["pane_id"], "state_labels" in r) for r in eff.reports] == [("w1:p1", False), ("w2:p1", True)] and eff.resubscribe is True,
      eff.reports)

print("H. pane_closed")
cut = {}
def mark_close(sub): cut["n"] = len(cut["tr"].requests); sub.queue.append([closed_ev("w1:p1")])
def go_close():
    c, stop = FakeClock(), threading.Event()
    both = snap(P("w1:p1", "working"), P("w1:p2", "working"))
    t = FakeTransport([both, both, snap(P("w1:p2", "working"))]); cut["tr"] = t
    f = FakeSelect(c, stop, [noop, mark_close, noop, noop])
    real = ar.select; ar.select = f
    try: ar.run(t, c, c.sleep, stop)
    finally: ar.select = real
    return t
tr = go_close()
post = [p for m, p in tr.requests[cut["n"]:] if m == "pane.report_metadata"]
check("nothing at all is sent to a closed pane", not [p for p in post if p["pane_id"] == "w1:p1"], post)
check("the other pane keeps spinning", len([p for p in post if p["pane_id"] == "w2:p1" or p["pane_id"] == "w1:p2"]) >= 2, post)
check("the next subscription drops the closed pane", ids(tr.subs[-1]) == ["w1:p2"], [ids(s) for s in tr.subs])

print("I. events_lost / EOF: resubscribe and a fresh snapshot")
def lose(sub): sub.queue.append(EOFError("events_lost"))
a = snap(P("w1:p1", "working"), P("w1:p2"))
b = snap(P("w1:p1", "idle"), P("w1:p2", "working"))
cut = {}
def mark_lose(sub): cut["n"] = len(cut["tr"].requests); lose(sub)
def go_lost():
    c, stop = FakeClock(), threading.Event()
    t = FakeTransport([a, a, b]); cut["tr"] = t; cut["clock"] = c
    f = FakeSelect(c, stop, [noop, mark_lose, noop, noop])
    real = ar.select; ar.select = f
    try: ar.run(t, c, c.sleep, stop)
    finally: ar.select = real
    return t
tr = go_lost()
post = tr.requests[cut["n"]:]
non_report = [m for m, _ in post if m != "pane.report_metadata"]
check("reconnect bootstraps again: lifecycle subscription, snapshot, full subscription, snapshot",
      non_report[:4] == ["events.subscribe", "session.snapshot", "events.subscribe", "session.snapshot"], non_report)
check("the reconnect's first subscription holds only the 3 lifecycle entries", len(tr.subs[2].entries) == 3, tr.subs[2].entries)
pp = [p for _, p in post if _ == "pane.report_metadata"]
check("state is rebuilt from the new snapshot: w1:p1 cleared, w1:p2 spins",
      [p["tokens"] for p in pp if p["pane_id"] == "w1:p1" and "tokens" in p] == [{"spin": None}]
      and any(p["pane_id"] == "w1:p2" and p.get("tokens", {}).get("spin") for p in pp), pp)
check("labels are re-reported after a reconnect (metadata may not have survived)",
      sorted(p["pane_id"] for p in pp if "state_labels" in p) == ["w1:p1", "w1:p2"], pp)
check("the lost subscription is closed", tr.subs[1].closed, tr.subs[1].closed)

print("J. Bootstrap: lifecycle first, then the per-pane set")
live = {}
def start_working(sub):
    live["sub"] = sub
    sub.queue.append([status_ev("w1:p2", "working")])
rc, tr, fake, clock = go([snap(P("w1:p1"), P("w1:p2"))], [start_working, noop, noop])
non_report = [m for m, _ in tr.requests if m != "pane.report_metadata"]
check("order: subscribe, snapshot, subscribe, snapshot", non_report[:4] == ["events.subscribe", "session.snapshot", "events.subscribe", "session.snapshot"], non_report)
check("first subscription has the 3 lifecycle entries only", [s["type"] for s in tr.subs[0].entries]
      == ["pane.agent_detected", "pane.closed", "pane.moved"], tr.subs[0].entries)
check("second subscription has 5 entries", len(tr.subs[1].entries) == 5, tr.subs[1].entries)
check("the first subscription is closed", tr.subs[0].closed, tr.subs[0].closed)
check("a status event delivered on the second subscription starts frames for its pane",
      live["sub"] is tr.subs[1] and {p["pane_id"] for p in frames(tr)} == {"w1:p2"} and len(frames(tr)) >= 2,
      (live["sub"] is tr.subs[1], frames(tr)))
check("no third subscription", len(tr.subs) == 2, len(tr.subs))

print("K. Many panes")
many = [P("w%d:p1" % i, "working" if i in (3, 17, 38) else "idle") for i in range(39)]
rc, tr, fake, clock = go([snap(*many)], [noop] * 10)
check("the live subscription holds 3 + 39 entries", len(tr.subs[-1].entries) == 42, len(tr.subs[-1].entries))
check("frames go to exactly the 3 working panes", {p["pane_id"] for p in frames(tr)} == {"w3:p1", "w17:p1", "w38:p1"},
      sorted({p["pane_id"] for p in frames(tr)}))
check("no resubscribe while the set is unchanged", len(tr.subs) == 2, len(tr.subs))
check("each tick reports each working pane", len(frames(tr)) == 30, len(frames(tr)))

print("L. Server gone")
cut = {}
def gone(sub):
    cut["t"] = cut["clock"].t; cut["n"] = len(cut["tr"].requests)
    cut["tr"].refuse = True
    sub.queue.append(EOFError("closed"))
def go_gone():
    c, stop = FakeClock(), threading.Event()
    t = FakeTransport([snap(P("w1:p1", "working"), P("w1:p2", "working"))]); cut["tr"], cut["clock"] = t, c
    f = FakeSelect(c, stop, [noop, gone])
    real = ar.select; ar.select = f
    try: rc = ar.run(t, c, c.sleep, stop)
    finally: ar.select = real
    return rc, t, c
rc, tr, clock = go_gone()
spent = clock.t - cut["t"]
post = tr.requests[cut["n"]:]
check("run returns 0", rc == 0, rc)
check("it gives up once reconnects have failed for 10 s (on the fake clock)", 10.0 <= spent <= 10.6, spent)
check("it retried the connection meanwhile", len([m for m, _ in post if m == "events.subscribe"]) >= 5, [m for m, _ in post])
check("shown frames were cleared best-effort (attempted even though refused)",
      sorted(p["pane_id"] for m, p in post if m == "pane.report_metadata" and p["tokens"] == {"spin": None}) == ["w1:p1", "w1:p2"], post)

print("M. SIGTERM")
stop_box = {}
def term(sub): os.kill(os.getpid(), signal.SIGTERM)
def go_term():
    c, stop = FakeClock(), threading.Event()
    t = FakeTransport([snap(P("w1:p1", "working"), P("w1:p2", "working"), P("w1:p3"))])
    f = FakeSelect(c, stop, [noop, term, noop, noop])
    old = {s: signal.getsignal(s) for s in (signal.SIGTERM, signal.SIGINT)}
    ar.install_signal_handlers(stop)
    real = ar.select; ar.select = f
    try: rc = ar.run(t, c, c.sleep, stop)
    finally:
        ar.select = real
        for s, h in old.items(): signal.signal(s, h)
    return rc, t, stop
rc, tr, stop = go_term()
check("run returns 0", rc == 0, rc)
check("both spinning panes are cleared", sorted(p["pane_id"] for p in clears(tr)) == ["w1:p1", "w1:p2"], clears(tr))
check("the clears carry no ttl_ms", all("ttl_ms" not in p for p in clears(tr)), clears(tr))
check("nothing is sent after the clears", reports(tr)[-2:] == clears(tr) and len(clears(tr)) == 2, reports(tr)[-4:])
check("the handler set the stop event", stop.is_set(), None)

print("N. One instance")
with tempfile.TemporaryDirectory() as d:
    held = open(os.path.join(d, "agent-rows.lock"), "w")
    fcntl.flock(held, fcntl.LOCK_EX | fcntl.LOCK_NB)
    tr = FakeTransport([snap(P("w1:p1", "working"))])
    rc = ar.main(["worker"], env={"HERDR_PLUGIN_STATE_DIR": d, "HERDR_SOCKET_PATH": "/nonexistent"}, transport=tr)
    check("a second worker exits 0", rc == 0, rc)
    check("and makes no request", tr.requests == [] and tr.subs == [], tr.requests)
    fcntl.flock(held, fcntl.LOCK_UN); held.close()
    got = ar.acquire_lock(d)
    check("the lock is taken when free", got is not None, got)
    again = ar.acquire_lock(d)
    check("and refused while held", again is None, again)

print("O. Log")
with tempfile.TemporaryDirectory() as d:
    log = ar.Log(os.path.join(d, "agent-rows.log"))
    line = "x" * 1000
    for _ in range(300): log(line)
    size = os.path.getsize(os.path.join(d, "agent-rows.log"))
    check("the log is truncated once it passes 256 KiB", 0 < size <= 256 * 1024, size)
    log("tail-marker")
    check("and keeps the latest line", open(os.path.join(d, "agent-rows.log")).read().rstrip().endswith("tail-marker"), None)

print("P. start detaches the worker")
calls = []
class FakePopen:
    def __init__(self, args, **kw): calls.append((args, kw))
real_popen = ar.subprocess.Popen
ar.subprocess.Popen = FakePopen
try:
    rc = ar.main(["start"], env={"HERDR_SOCKET_PATH": "/nonexistent"})
finally:
    ar.subprocess.Popen = real_popen
check("start exits 0 after one Popen", rc == 0 and len(calls) == 1, (rc, calls))
args, kw = calls[0]
check("it runs `worker` of this file under isolated python", args[-1] == "worker" and "-I" in args and args[-2].endswith(".py"), args)
check("in a new session, with stdio to /dev/null", kw.get("start_new_session") is True and all(
      kw.get(k) is not None for k in ("stdin", "stdout", "stderr")), kw)

print("Q. Transport framing over socketpair")
a, b = socket.socketpair()
tr = ar.Transport("/unused", connect=lambda: a)
b.sendall(b'{"id":"x","result":{"ok":true}}\n')
resp = tr.request("pane.report_metadata", {"pane_id": "w1:p1", "source": "s"})
line = b.recv(65536)
sent = json.loads(line)
check("one request line out", line.endswith(b"\n") and line.count(b"\n") == 1
      and sent["method"] == "pane.report_metadata" and sent["params"] == {"pane_id": "w1:p1", "source": "s"} and "id" in sent, line)
check("one response line parsed", resp == {"id": "x", "result": {"ok": True}}, resp)
check("the connection is closed after the response", a.fileno() == -1, a.fileno())
b.close()

a, b = socket.socketpair()
tr = ar.Transport("/unused", connect=lambda: a)
ev1 = {"event": "pane.closed", "data": {"type": "pane_closed", "pane_id": "w1:p1"}}
ev2 = {"event": "pane.moved", "data": {"type": "pane_moved", "previous_pane_id": "w1:p2", "pane": {"pane_id": "w2:p2"}}}
e1, e2 = (json.dumps(e).encode() for e in (ev1, ev2))
b.sendall(b'{"id":"x","result":{"type":"subscription_started"}}\n' + e1 + b"\n" + e2[:20])
sub = tr.subscribe([{"type": "pane.closed"}])
req = json.loads(b.recv(65536))
check("the subscription request names events.subscribe and the entries",
      req["method"] == "events.subscribe" and req["params"] == {"subscriptions": [{"type": "pane.closed"}]}, req)
check("fileno() is the connection's", sub.fileno() == a.fileno(), sub.fileno())
check("first read returns the complete event and holds the partial one", sub.read_events() == [ev1], None)
b.sendall(e2[20:] + b"\n")
check("the next read completes the split event", sub.read_events() == [ev2], None)
b.sendall(b'{"event":"x"}\n{"event":"y"}\n')
check("two lines in one read come back together", [e["event"] for e in sub.read_events()] == ["x", "y"], None)
b.sendall(b'{"id":"x","error":{"code":"events_lost","message":"m"}}\n')
try: sub.read_events(); got = None
except EOFError as e: got = e
check("an error line raises EOFError", isinstance(got, EOFError), got)
sub.close()
check("close() closes the connection", a.fileno() == -1, a.fileno())
b.close()

a, b = socket.socketpair()
b.sendall(b'{"id":"x","result":{"type":"subscription_started"}}\n')
sub = ar.Transport("/unused", connect=lambda: a).subscribe([])
b.close()
try: sub.read_events(); got = None
except EOFError as e: got = e
check("a closed peer raises EOFError", isinstance(got, EOFError), got)
sub.close()

a, b = socket.socketpair()
b.sendall(b'{"id":"x","error":{"code":"bad","message":"no"}}\n')
try: ar.Transport("/unused", connect=lambda: a).subscribe([]); got = None
except Exception as e: got = e
check("a rejected subscription raises RpcError", isinstance(got, ar.RpcError), got)
b.close()

print("R. Imports are stdlib only")
tree = ast.parse(open(PLUGIN).read())
mods = set()
for node in ast.walk(tree):
    if isinstance(node, ast.Import): mods.update(n.name.split(".")[0] for n in node.names)
    elif isinstance(node, ast.ImportFrom) and node.level == 0: mods.add(node.module.split(".")[0])
stdlib = os.path.dirname(os.__file__)
def is_stdlib(m):
    s = importlib.util.find_spec(m)
    if s is None: return False
    o = s.origin
    return o in ("built-in", "frozen") or (o is not None and o.startswith(stdlib) and "site-packages" not in o)
bad = sorted(m for m in mods if not is_stdlib(m))
check("every import is a stdlib module", mods and not bad, bad)

print("RESULT %d %d" % (passed, failed))
sys.exit(1 if failed else 0)
PY
out="$(/usr/bin/python3 -I "$T/t.py" "$PLUGIN" 2>&1)"; rc=$?
printf '%s\n' "$out" | grep -v '^RESULT '
py_pass=$(printf '%s\n' "$out" | grep -c '^  PASS: ')
py_fail=$(printf '%s\n' "$out" | grep -c '^  FAIL: ')
pass=$((pass + py_pass)); fail=$((fail + py_fail))
if [ "$rc" -ne 0 ] && [ "$py_fail" -eq 0 ]; then
  _fail "python harness exited $rc without reporting a failure" "$(printf '%s\n' "$out" | tail -5)"
fi
echo
echo "RESULT: $pass passed, $((pass + fail)) total, $fail failed"
[ "$fail" -eq 0 ]
