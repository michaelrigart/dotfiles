import json
import os
import sys
import threading
import time
from argparse import Namespace

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import helpers
from helpers import git, is_, ok, put

helpers.setup()
from process_replay import codex as K  # noqa: E402
from process_replay import common as C  # noqa: E402
from process_replay import scratch  # noqa: E402
from process_replay.common import Failed  # noqa: E402

XR, L = C.XR, C.L
ROOT = helpers.tmp_root()
STATE = os.path.join(ROOT, "state")
SNAPSHOTS = os.path.join(ROOT, "snapshots")
os.makedirs(STATE)
ORIGINAL_HOME = os.environ["CODEX_HOME"]          # the "original" Codex home helpers.setup() redirects
PLAN = "docs/superpowers/plans/2026-10-20-x.md"
MARK = "PLAN-BODY-MARKER"
AT_PLAN, AT_R1, AT_LATER = "2026-10-19T09:00:00.000000Z", "2026-10-20T10:00:00.000000Z", "2026-10-21T10:00:00.000000Z"
FUTURE = int(time.time()) + 3600
F1 = {"severity": "P1", "file": "src/a.py", "line": 3, "summary": "a is wrong", "failure_scenario": "x"}
F2 = {"severity": "P2", "file": "src/b.py", "line": 7, "summary": "b is wrong", "failure_scenario": "y"}
F3 = {"severity": "P3", "file": "src/c.py", "line": 9, "summary": "c is ugly", "failure_scenario": "z"}


def ans(verdict="changes", findings=(F1,), files=("src/a.py", "src/b.py")):
    return {"verdict": verdict, "findings": list(findings), "reviewed_files": list(files)}


def args(**kw):
    return Namespace(**dict({"state": STATE, "max_tokens": 10 ** 9, "budget": 60, "snapshot_root": SNAPSHOTS}, **kw))


def log(stub):
    return helpers.read_log(os.path.join(os.path.dirname(stub), "rpc.log"))


def packet(stub, turn):
    with open(os.path.join(os.path.dirname(stub), "inputs", turn)) as f:
        return f.read()


def replay_home(name, window=200000):
    home = os.path.join(ROOT, "cxh", name)
    helpers.write_rollout(home, "probe-" + name, [{"turn": "pb", "answer": None, "window": window}])
    return home


def stub_for(name, home, script):
    stub = helpers.stub_rpc(os.path.join(ROOT, "rpc-" + name), home, script)
    XR.RPC = stub
    return stub


class World(object):
    """An original repository (branch feat, a plan, a ledger with an approved clean plan receipt and a round 1),
    its scratch repository built the way production builds it, and a run state for it."""

    def __init__(self, name, plan_receipt=True, big=False, snap=False, prepare=True):
        self.name = name
        self.orig = helpers.make_repo(ROOT, "orig-" + name)
        put(self.orig, "README", "base\n")
        self.base = helpers.commit(self.orig, "base")
        git(self.orig, "checkout", "-q", "-b", "feat")
        put(self.orig, PLAN, "# plan\n{}\n".format(MARK))
        if big:
            for n in "abc":
                put(self.orig, "src/{}.py".format(n), "".join("line {} of {} is here\n".format(i, n) for i in range(2500)))
        else:
            put(self.orig, "src/a.py", "def a():\n    return 1\n")
            put(self.orig, "src/b.py", "def b():\n    return 2\n")
        self.tip = helpers.commit(self.orig, "feature")
        self.common = os.path.realpath(os.path.join(self.orig, ".git"))
        self.workdir = os.path.dirname(self.common)
        plan_thread = "pth-" + name
        plan_tip = self.plan_tip = self.tip
        if snap:
            # the plan review's tip survives only in the snapshot: a clone holds a commit adding the same plan
            clone = os.path.join(ROOT, "snap-" + name)
            helpers.git(ROOT, "clone", "-q", "--no-hardlinks", self.orig, clone)
            git(clone, "checkout", "-q", "-b", "planonly", self.base)
            put(clone, PLAN, "# plan\n{}\n".format(MARK))
            plan_tip = self.plan_tip = helpers.commit(clone, "plan only")
            os.makedirs(os.path.join(SNAPSHOTS, "orig-" + name))
            os.symlink(os.path.join(clone, ".git", "objects"), os.path.join(SNAPSHOTS, "orig-" + name, "objects"))
        helpers.write_rollout(ORIGINAL_HOME, plan_thread, [{"turn": "pt1", "answer": ans("approve", ())}])
        target = {"repo": self.common, "dest": "main", "dest_ref": "main", "branch": "feat", "range": "main...feat",
                  "base": self.base, "tip": self.tip, "full": True}
        plan_target = dict(target, tip=plan_tip)
        entries = [{"v": 2, "kind": "receipt", "checkpoint": "pre-merge", "nonce": "n1-" + name, "thread": "orig-th-" + name,
                    "turn": "ot1", "dispatched_at": AT_R1, "verdict": "changes", "targets": [dict(target)]},
                   {"v": 2, "kind": "receipt", "checkpoint": "pre-merge", "nonce": "n2-" + name, "thread": "orig-th-" + name,
                    "turn": "ot2", "dispatched_at": AT_LATER, "verdict": "approve", "targets": [dict(target)]}]
        if plan_receipt:
            entries.append({"v": 2, "kind": "receipt", "checkpoint": "plan", "nonce": "pn-" + name, "thread": plan_thread,
                            "turn": "pt1", "dispatched_at": AT_PLAN, "verdict": "approve", "targets": [plan_target]})
        helpers.write_ledger(os.environ["XDG_STATE_HOME"], self.orig, entries)
        files = os.path.join(ROOT, "files-" + name)
        scratch.export(os.path.join(self.orig, ".git", "objects"), self.tip, files)
        self.scratch = os.path.join(os.environ["XDG_STATE_HOME"], "review-work", "scratch", name)
        scratch.build(os.path.join(self.orig, ".git", "objects"), self.base, files, self.scratch, "main", "feat",
                      expect_tree=git(self.orig, "rev-parse", self.tip + "^{tree}"))
        self.branch = {"id": "b" + name, "repo": self.common, "objects": None, "view": None, "dest": "main", "dest_ref": "main",
                       "branch": "feat", "base": self.base,
                       "rounds": [{"k": 1, "nonce": "n1-" + name, "tip": self.tip, "base": self.base, "thread": "orig-th-" + name,
                                   "turns": [["orig-th-" + name, "ot1"]], "at": AT_R1, "verdict": "changes"}]}
        self.case = {"id": "c" + name}
        self.run = {"case": "c" + name, "label": "lab1", "scratch": self.scratch, "thread": None, "round": 0, "step": "codex",
                    "reviews": [], "rejected": [], "tokens": 0}
        if prepare:
            K.prepare_ledger(args(), self.run, self.case, self.branch)

    def round(self, home, **kw):
        out = K.codex_round(args(**kw), self.run, self.case, self.branch, home)
        if out.get("kind") == "codex":
            self.run["reviews"].append(out)
            self.run["thread"] = out["thread"]
            self.run["tokens"] += out["tokens"]
        return out


# ---- plans_omitted_as_today
w = World("plans")
home = replay_home("plans")
stub = stub_for("plans", home, {"default": {"answer": ans()}})
rv = w.round(home)
ok("plans_omitted_as_today: the round is a Codex review", rv.get("kind") == "codex", rv)
plans_from = rv["decision"]["targets"][0]["plans_from"]
is_("plans_omitted_as_today: the decision's target names the approved plan", [(p["path"], p["nonce"]) for p in plans_from], [(PLAN, "pn-plans")])
ok("plans_omitted_as_today: the packet does not carry the plan's text", MARK not in packet(stub, rv["turns"][0][1]))
is_("plans_omitted_as_today: the target is the scratch repository at its HEAD", rv["decision"]["targets"][0]["tip"], git(w.scratch, "rev-parse", "HEAD"))
is_("plans_omitted_as_today: the target's repository is the scratch repository's git directory", rv["decision"]["targets"][0]["repo"], w.scratch + "/.git")
turn_cwd = [e["cwd"] for e in log(stub) if e["cmd"] == "turn-start"][0]
is_("plans_omitted_as_today: the turn's cwd is the scratch repository itself, a neutral real path", turn_cwd, w.scratch)
ok("plans_omitted_as_today: ... which names no replay", "process-replay" not in os.path.realpath(turn_cwd), turn_cwd)
w2 = World("noplan", plan_receipt=False)
home2 = replay_home("noplan")
stub2 = stub_for("noplan", home2, {"default": {"answer": ans()}})
rv2 = w2.round(home2)
is_("plans_omitted_as_today: with no plan receipt nothing is omitted", rv2["decision"]["targets"][0]["plans_from"], [])
ok("plans_omitted_as_today: ... and the plan's text is in the packet", MARK in packet(stub2, rv2["turns"][0][1]))

# ---- prepare_ledger
w = World("ledger")
led = w.run["ledger"]
is_("prepare_ledger: it is recorded in the run and lies under the run's directory",
    led, os.path.join(STATE, "runs", "cledger", "lab1", "ledger"))
alias_repo = w.scratch + "/.git"
path = os.path.join(led, "xreview", "ledgers", L.ledger_key(alias_repo), "reviews.jsonl")
entries = L.read_entries(path)
is_("prepare_ledger: the entries are the ones before the original round 1, under the scratch repository's key",
    sorted(e["nonce"] for e in entries), ["pn-ledger"])
plan = entries[0]
is_("prepare_ledger: the plan receipt is rebound to the scratch repository", [t["repo"] for t in plan["targets"]], [alias_repo])
is_("prepare_ledger: its plan_blobs are the original's", plan["targets"][0]["plan_blobs"], L.plan_blobs(w.common, w.base, w.tip))
ok("prepare_ledger: it lies beside the scratch repository, not inside it", not led.startswith(w.scratch + "/"), led)

# ---- ledger_prepared_once
w = World("noledger", prepare=False)
home = replay_home("noledger")
stub = stub_for("noledger", home, {"default": {"answer": ans()}})
try:
    w.round(home)
    got = None
except Failed as e:
    got = str(e)
ok("ledger_prepared_once: a round without a prepared ledger raises Failed", got is not None and "prepared ledger" in got, got)
is_("ledger_prepared_once: ... and made no call", log(stub), [])
w = World("once")
home = replay_home("once")
stub = stub_for("once", home, {"default": {"answer": ans()}})
os.remove(helpers.rollout_file(ORIGINAL_HOME, "pth-once"))
XR._TURNS.clear()
rv = w.round(home)
is_("ledger_prepared_once: with one, the round never reads the original home's rollouts (they are gone, the plan is still omitted)",
    [p["path"] for p in rv["decision"]["targets"][0]["plans_from"]], [PLAN])
with K._homed(home):
    try:
        K.prepare_ledger(args(), w.run, w.case, w.branch)
        refused = False
    except Failed:
        refused = True
ok("ledger_prepared_once: preparing a ledger while a replay home is active is refused", refused)

# ---- plan_blobs_through_the_view
w = World("snap", snap=True)
home = replay_home("snap")
stub = stub_for("snap", home, {"default": {"answer": ans()}})
ok("plan_blobs_through_the_view: the plan review's tip is not in the original repository", not helpers.git_ok(w.orig, "cat-file", "-e", w.plan_tip))
rv = w.round(home)
is_("plan_blobs_through_the_view: the plan it approved is still omitted", [p["path"] for p in rv["decision"]["targets"][0]["plans_from"]], [PLAN])
ok("plan_blobs_through_the_view: ... and its text is not in the packet", MARK not in packet(stub, rv["turns"][0][1]))

# ---- thread_continuity
w = World("threads")
home = replay_home("threads")
stub = stub_for("threads", home, {"threads": {"th1": [{"answer": ans(), "tokens": 190000}]}, "default": {"answer": ans()}})
r1 = w.round(home)
is_("thread_continuity: round 1 starts th1", (r1["k"], r1["thread"], r1["tokens"]), (1, "th1", 190000))
r2 = w.round(home)
ok("thread_continuity: round 1 filled th1's context, so round 2 is a fresh thread", r2["decision"]["action"] == "fresh" and r2["thread"] == "th2", r2.get("decision", r2))
r3 = w.round(home)
turn_threads = [e["argv"][e["argv"].index("--thread") + 1] for e in log(stub) if e["cmd"] == "turn-start"]
is_("thread_continuity: round 3 reuses the fresh thread", (r3["k"], r3["decision"]["action"], r3["thread"], turn_threads), (3, "send", "th2", ["th1", "th2", "th2"]))
is_("thread_continuity: only two threads were started", sum(1 for e in log(stub) if e["cmd"] == "thread-start"), 2)
w = World("threads2")
home = replay_home("threads2")
stub = stub_for("threads2", home, {"default": {"answer": ans()}})
w.round(home)
w.round(home)
turn_threads = [e["argv"][e["argv"].index("--thread") + 1] for e in log(stub) if e["cmd"] == "turn-start"]
is_("thread_continuity: round 2 names round 1's thread, and starts none", (turn_threads, sum(1 for e in log(stub) if e["cmd"] == "thread-start")), (["th1", "th1"], 1))
threads = XR.jload(os.path.join(STATE, "threads.json"))["threads"]
ok("thread_continuity: every thread the round started is recorded for cleanup", {"th1", "th2"} <= set(t["thread"] for t in threads), threads)

# ---- thread_continuity: slices
w = World("slices", big=True)
home = replay_home("slices", window=110000)
S1 = dict(F1, summary="first slice")
S2 = dict(F2, summary="second slice")
stub = stub_for("slices", home, {"turns": [{"answer": ans("approve", (S1,))}, {"answer": ans("changes", (S2,))}], "default": {"answer": ans("approve", ())}})
rv = w.round(home)
n = len(rv["turns"])
ok("slices: the decision is slices, one turn per slice", rv["decision"]["action"] == "slices" and n >= 2 and n == len(rv["decision"]["packets"]), (rv["decision"]["action"], n))
is_("slices: one thread per slice, the round's thread is the last slice's", (len(set(t for t, _x in rv["turns"])), rv["thread"]), (n, rv["turns"][-1][0]))
is_("slices: the findings are the union of every slice's", [f["summary"] for f in rv["findings"]], ["first slice", "second slice"])
is_("slices: approve only if every slice approves", rv["verdict"], "changes")
stub = stub_for("slices-ok", home, {"default": {"answer": ans("approve", ())}})
w.run["reviews"], w.run["thread"] = [], None
rv = w.round(home)
is_("slices: every slice approving makes the round approve", rv["verdict"], "approve")
is_("slices: the run's next round reuses the last slice's thread", rv["thread"], rv["turns"][-1][0])

# ---- missed_carried
w = World("missed")
home = replay_home("missed")
stub = stub_for("missed", home, {"default": {"answer": ans("changes", (F1,), files=("src/a.py",))}})
r1 = w.round(home)
is_("missed_carried: a shown label the answer did not list is missing", r1["missing"], ["src/b.py"])
r2 = w.round(home)
text = packet(stub, r2["turns"][0][1])
ok("missed_carried: the next round's packet asks for it", "did not list: src/b.py. Review them too." in text)
ok("missed_carried: round 1's packet carried no such note", "did not list" not in packet(stub, r1["turns"][0][1]))

# ---- body_strings
LITERAL = ("Pre-merge review of feat against main: the change is main...feat. Review the change as it now stands. Your working "
           "directory is this repository at this round's tip: read files only there. Paths from earlier turns of this thread "
           "name other checkouts; ignore them.\n")
br = {"branch": "feat", "dest": "main", "dest_ref": "main"}
is_("body_strings: round 1 is the body XR.prepare writes (literal)", K.body(br, 1, [], []), LITERAL)
is_("body_strings: round 2 with nothing to add is the same", K.body(br, 2, [], []), LITERAL)
is_("body_strings: round 2 adds the addressed and the rejected lines",
    K.body(br, 2, ["a.py:3 one", "b.py:9 two"], ["c.py:1 three"]),
    LITERAL + "Addressed since the last round: a.py:3 one; b.py:9 two.\nJudged not defects: c.py:1 three.\n")
is_("body_strings: an empty list's line is omitted", K.body(br, 2, [], ["c.py:1 three"]), LITERAL + "Judged not defects: c.py:1 three.\n")
is_("body_strings: no branch name reads 'the branch'", K.body({"branch": None, "dest": "main", "dest_ref": "origin/main"}, 1, [], [])[:59],
    "Pre-merge review of the branch against main: the change is ")
is_("body_strings: an identifier is file:line and the summary's first 80 characters",
    K.identifier({"file": "x.py", "line": 12, "summary": "s" * 100}), "x.py:12 " + "s" * 80)
is_("body_strings: a null line writes the file alone, never 'None'", K.identifier({"file": "x.py", "line": None, "summary": "s"}), "x.py s")
is_("body_strings: a summary's line breaks do not break the line", K.identifier({"file": "x.py", "line": 1, "summary": "a\nb"}), "x.py:1 a b")
w = World("body")
home = replay_home("body")
stub = stub_for("body", home, {"default": {"answer": ans()}})
r1 = w.round(home)
w.run["addressed"], w.run["rejected"] = ["src/a.py:3 a is wrong"], ["src/c.py:9 c is ugly"]
r2 = w.round(home)
ok("body_strings: round 1's packet carries the literal body", LITERAL in packet(stub, r1["turns"][0][1]))
ok("body_strings: round 2's packet carries the added lines",
   "Addressed since the last round: src/a.py:3 a is wrong.\nJudged not defects: src/c.py:9 c is ugly.\n" in packet(stub, r2["turns"][0][1]))

# ---- weekly_pause
def limits(primary, secondary, name, age=0, resets=FUTURE):
    home = os.path.join(ROOT, "cxh", name)
    rl = {"primary": dict(primary, resets_at=resets), "secondary": dict(secondary, resets_at=resets) if secondary else None}
    p = helpers.write_rollout(home, "lim-" + name, [{"turn": "l1", "answer": None, "rate_limits": rl}])
    os.utime(p, (time.time() - age, time.time() - age))
    return home


home = limits({"used_percent": 81, "window_minutes": 10080}, None, "wk1")
is_("weekly_pause: the primary window of 10080 minutes is the weekly one", K.weekly(home), (81.0, FUTURE))
w = World("pause")
helpers.write_rollout(home, "probe-pause", [{"turn": "pb", "answer": None}])
stub = stub_for("pause", home, {"default": {"answer": ans()}})
os.utime(helpers.rollout_file(home, "probe-pause"), (time.time() - 100, time.time() - 100))
out = w.round(home)
ok("weekly_pause: at 81% the round is paused, naming resets_at", set(out) == {"paused", "resets_at"} and str(FUTURE) in out["paused"], out)
is_("weekly_pause: ... and no call was made to the daemon", log(stub), [])
home = limits({"used_percent": 95, "window_minutes": 300}, {"used_percent": 10, "window_minutes": 10080}, "wk2")
is_("weekly_pause: the secondary window is read when it is the weekly one; a 300-minute window is not", K.weekly(home), (10.0, FUTURE))
home = limits({"used_percent": 79.9, "window_minutes": 10080}, None, "wk3")
is_("weekly_pause: 79.9% does not pause", "paused" in K.codex_round(args(), w.run, w.case, w.branch, home), False)
home = limits({"used_percent": 99, "window_minutes": 10080}, None, "wk4", resets=int(time.time()) - 5)
is_("weekly_pause: a window that has reset does not pause", "paused" in K.codex_round(args(), w.run, w.case, w.branch, home), False)
home = limits({"used_percent": 90, "window_minutes": 10080}, None, "wk5", age=500)
helpers.write_rollout(home, "newer", [{"turn": "n1", "answer": None, "rate_limits": {"primary": {"used_percent": 12, "window_minutes": 10080, "resets_at": FUTURE}}}])
is_("weekly_pause: the newest rollout's figure is the one that counts", K.weekly(home), (12.0, FUTURE))
is_("weekly_pause: a home with no figure has none", K.weekly(replay_home("wk6")), None)

# ---- token_stop
w = World("stop")
home = replay_home("stop")
stub = stub_for("stop", home, {"default": {"answer": ans()}})
w.run["tokens"] = 600
out = w.round(home, max_tokens=1000)
ok("token_stop: below the stop the round runs", out.get("kind") == "codex", out)
w.run["tokens"] = 1000
before = len(log(stub))
out = w.round(home, max_tokens=1000)
ok("token_stop: at the stop the round is stopped", set(out) == {"stopped"}, out)
is_("token_stop: ... and no call was made", len(log(stub)), before)
XR.jsave(os.path.join(STATE, "runs", "cother", "labx", "state.json"), {"case": "cother", "label": "labx", "tokens": 500})
XR.jsave(os.path.join(STATE, "runs", "cstop", "lab1", "state.json"), {"case": "cstop", "label": "lab1", "tokens": 99999})
w.run["tokens"] = 600
out = w.round(home, max_tokens=1000)
ok("token_stop: the stop counts every run's tokens, this run's from the caller, not from its file", set(out) == {"stopped"}, out)

# ---- leak_scan
W = "/work/orig"
lhome = os.path.join(ROOT, "cxh", "leak")
ORIG_W = K.wall([W])        # the original checkout alone: its wt siblings count, nothing else is forbidden


def tool(kind, text):
    return {"type": kind, "name": "shell", "arguments": text}


def rollout(thread, turns, user=None, home=None):
    recs, total = [], 0
    for t in turns:
        more, total = helpers.rollout_lines(t, total)
        if user:
            more.insert(1, {"type": "response_item", "payload": {"type": "message", "role": "user", "content": [{"type": "input_text", "text": user}]}})
        recs += more
    path = helpers.rollout_file(home or lhome, thread)
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w") as f:
        f.write("".join(json.dumps(r) + "\n" for r in recs))


rollout("lk1", [{"turn": "t1", "answer": None, "tools": [tool("custom_tool_call", "cat {}/src/a.py".format(W))]}])
is_("leak_scan: a custom_tool_call naming the original work dir is a leak", K.leaks(lhome, [("lk1", "t1")], ORIG_W), [W + " in t1"])
rollout("lk2", [{"turn": "t1", "answer": None, "tools": [tool("function_call", json.dumps({"cmd": "ls {}-feat/src".format(W)}))]}])
is_("leak_scan: a function_call naming a sibling <dir>-feat is a leak", K.leaks(lhome, [("lk2", "t1")], ORIG_W), [W + " in t1"])
rollout("lk3", [{"turn": "t1", "answer": None, "developer": "the checkout is {} and {}-feat".format(W, W), "tools": [tool("function_call", "ls /scratch/x")]}],
        user="please read {}/src/a.py".format(W))
is_("leak_scan: the same path in a user or developer message is not a leak", K.leaks(lhome, [("lk3", "t1")], ORIG_W), [])
rollout("lk4", [{"turn": "t1", "answer": None, "tools": [tool("function_call", "ls {}x/src {}2".format(W, W))]}])
is_("leak_scan: another directory whose name merely starts the same is not a leak", K.leaks(lhome, [("lk4", "t1")], ORIG_W), [])
rollout("lk5", [{"turn": "t1", "answer": None, "tools": [tool("function_call", "ls /scratch")]},
                {"turn": "t2", "answer": None, "tools": [tool("function_call", "ls " + W)]}])
is_("leak_scan: only the named turns are read", K.leaks(lhome, [("lk5", "t1")], ORIG_W), [])
is_("leak_scan: ... and a named turn that leaked is found", K.leaks(lhome, [("lk5", "t1"), ("lk5", "t2")], ORIG_W), [W + " in t2"])
house = os.path.expanduser("~")
rollout("lk6", [{"turn": "t1", "answer": None, "tools": [tool("custom_tool_call", "cat ~/Code/Org/repo/x")]}])
is_("leak_scan: the ~ spelling of a path under $HOME is a leak", K.leaks(lhome, [("lk6", "t1")], K.wall([house + "/Code/Org/repo/.git"])), [house + "/Code/Org/repo in t1"])
is_("leak_scan: a scanned turn whose thread has no rollout cannot be shown clean: it counts as a leak", K.leaks(lhome, [("nothing", "t1")], ORIG_W),
    ["rollout unreadable in t1"])
is_("leak_scan: a scanned turn the rollout does not hold counts as a leak too, the turns it holds are still read",
    K.leaks(lhome, [("lk5", "t1"), ("lk5", "t2"), ("lk5", "t9")], ORIG_W), [W + " in t2", "rollout unreadable in t9"])
os.makedirs(os.path.join(lhome, "sessions", "2026", "10", "20"), exist_ok=True)
with open(helpers.rollout_file(lhome, "lkzst", sub="sessions/2026/10/20").replace(".jsonl", ".jsonl.zst"), "wb") as f:
    f.write(b"this is not a zstd frame")
is_("leak_scan: a rollout that cannot be decompressed counts as a leak", K.leaks(lhome, [("lkzst", "t1")], ORIG_W), ["rollout unreadable in t1"])
real_run = K.subprocess.run


def zstd_hangs(argv, *args, **kw):
    if argv and argv[0] == "zstd":
        raise K.subprocess.TimeoutExpired(argv, kw.get("timeout"))
    return real_run(argv, *args, **kw)


K.subprocess.run = zstd_hangs
try:
    hung = K.leaks(lhome, [("lkzst", "t1")], ORIG_W)
finally:
    K.subprocess.run = real_run
is_("leak_scan: a rollout whose decompression times out counts as a leak too (the scan does not raise)", hung, ["rollout unreadable in t1"])
w = World("leakround")
home = replay_home("leakround")
stub = stub_for("leakround", home, {"default": {"answer": ans(), "tools": [tool("custom_tool_call", "cat {}/src/a.py".format(w.workdir))]}})
out = w.round(home)
ok("leak_scan: a round whose turn read the original checkout is void, with its tokens", set(out) == {"leak", "tokens", "thread", "turns"} and out["tokens"] == 1000 and out["leak"], out)
w = World("cleanround")
home = replay_home("cleanround")
stub = stub_for("cleanround", home, {"default": {"answer": ans(), "tools": [tool("custom_tool_call", "cat src/a.py")]}})
ok("leak_scan: a round that read only the scratch repository is a review", w.round(home).get("kind") == "codex")

# ---- leak_scan: one forbidden-paths function (K.forbidden) for the Codex round, the final reviewer and xreview-replay
w = World("wall1")
w_other = World("wall2")
home = replay_home("wall1")
for label, text in (("another run's scratch (../<label>)", "cat ../wall2/src/a.py"),
                    ("a staged item's input (../../items/<hex>/input.json)", "cat ../../items/0123456789abcdef/input.json"),
                    ("an alias into the state (../../<8 hex>/repairs)", "ls ../../deadbeef/repairs")):
    stub = stub_for("wall1", home, {"default": {"answer": ans(), "tools": [tool("custom_tool_call", text)]}})
    out = w.round(home)
    ok("leak_scan: a Codex call reading {} voids the round".format(label), set(out) == {"leak", "tokens", "thread", "turns"} and bool(out["leak"]), out)
stub = stub_for("wall1", home, {"default": {"answer": ans(), "tools": [tool("custom_tool_call", "cat src/a.py; git log; ls .")]}})
ok("leak_scan: ... while an ordinary read inside its own scratch does not", w.round(home).get("kind") == "codex")

XSH = os.environ["XDG_STATE_HOME"]
FSTATE = os.path.join(ROOT, "forbidden-state")
os.makedirs(FSTATE, exist_ok=True)
OWN = os.path.join(XSH, "review-work", "scratch", "own00001")
os.makedirs(OWN, exist_ok=True)
BRANCH = {"repo": house + "/Code/Org/repo/.git"}
fwall = K.forbidden(FSTATE, BRANCH, [OWN])
mwall = K.forbidden(FSTATE, BRANCH, [OWN], memwatch=True)
is_("forbidden: the roots, by the path they are reported as: the checkout, the state, review-work, the snapshot, October's answers, xreview, cxh",
    [r.label for r in fwall.roots],
    [house + "/Code/Org/repo", FSTATE, os.path.join(XSH, "review-work"), house + "/Code/.replay/snapshot", house + "/.codex",
     house + "/.claude", os.path.join(XSH, "xreview"), os.path.join(XSH, "cxh")])
is_("forbidden: only the checkout has wt siblings", [r.label for r in fwall.roots if r.siblings], [house + "/Code/Org/repo"])
is_("forbidden: the run's own directories are allowed, as real paths, then the instructions in ~/.codex and ~/.claude", fwall.allowed,
    [K._parts(os.path.realpath(OWN))] + [K._parts(os.path.realpath(os.path.expanduser(x))) for x in K.INSTRUCTIONS])
is_("forbidden: a memories run adds the watcher's directory", [r.label for r in mwall.roots][len(fwall.roots):], [os.path.join(XSH, "process-replay", "memwatch")])


n_fb = [0]


def forbid(text, memwatch=False, cwd=OWN, wall=None, home=None):
    """What one function_call (`text` as its arguments) in a rollout of `home` (default lhome) leaks behind `wall` (default the
    usual one for a run whose scratch is OWN)."""
    n_fb[0] += 1
    thread = "fbd{}".format(n_fb[0])
    rollout(thread, [{"turn": "t1", "answer": None, "tools": [tool("function_call", text)]}], home=home or lhome)
    return K.leaks(home or lhome, [(thread, "t1")], wall or (mwall if memwatch else fwall), cwd)


ALIAS = os.path.join(ROOT, "neutral-alias")
os.symlink(FSTATE, ALIAS)
os.symlink(house + "/Code/Org/repo", os.path.join(OWN, "evil"))
for label, text in (("the original checkout", "cat ~/Code/Org/repo/src/a.py"), ("a wt sibling of it", "cat ~/Code/Org/repo-feat/x"),
                    ("the state directory", "cat {}/inventory/b.json".format(FSTATE)),
                    ("the snapshot root", "ls ~/Code/.replay/snapshot/2026-11-02"), ("October's codex sessions", "rg -n x ~/.codex/sessions/2026"),
                    ("October's archived codex sessions", "ls $HOME/.codex/archived_sessions"), ("October's memories", "cat ~/.codex/memories/MEMORY.md"),
                    ("the Claude transcripts", "ls ~/.claude/projects"), ("the xreview ledgers", "cat $XDG_STATE_HOME/xreview/ledgers/k/reviews.jsonl"),
                    ("the xreview ledgers by path", "cat {}/xreview/ledgers/k/reviews.jsonl".format(XSH)),
                    ("the replay homes", "ls $XDG_STATE_HOME/cxh/nomem/sessions"), ("a replay home by path", "cat {}/cxh/mem-a1/sessions/r.jsonl".format(XSH)),
                    ("another scratch", "cat ../other000/x"), ("a staged item", "cat ../../items/0123456789abcdef/input.json"),
                    ("an alias link", "cat ../../deadbeef/inventory/b.json"), ("review-work itself", "ls ../.."), ("a stray ../..", "cat ../../../xreview/x"),
                    ("the state through a symlink outside review-work (realpath)", "cat {}/inventory/b.json".format(ALIAS)),
                    ("the original through a symlink inside its own scratch (judged where it lands)", "cat evil/src/a.py"),
                    ("another scratch by a glob", "cat ../*/src/a.py"), ("October's sessions by a glob", "cat ~/.codex/*/2026/x.jsonl"),
                    ("a wt sibling by a glob", "ls ~/Code/Org/repo-*/src"),
                    ("another scratch after cd ..", "cd .. && cat other000/x"), ("the checkout after cd to its parent and ;", "cd ~/Code/Org; cat repo/x"),
                    ("the checkout from a heredoc fed to python", "python3 - <<'EOF'\nprint(open('{}/Code/Org/repo/src/a.py').read())\nEOF".format(house)),
                    ("the checkout from an inline script", "python3 -c \"print(open('{}/Code/Org/repo/src/a.py').read())\"".format(house)),
                    ("the checkout as a redirect", "wc -l < ~/Code/Org/repo/src/a.py"),
                    ("a pattern file in a forbidden root", "rg -f ~/.codex/memories/MEMORY.md src"),
                    ("a grep's file operand after -e", "grep -n -e xreview ~/.codex/sessions"),
                    ("a $( ) inside a quoted word", 'echo "$(cat ~/.codex/memories/MEMORY.md)"'),
                    ("a glued --git-dir", "git --git-dir={}/Code/Org/repo/.git log".format(house))):
    got = forbid(text)
    ok("forbidden: reading {} is a leak".format(label), got != [], got)
for label, text in (("a file in its own scratch", "cat src/a.py"), ("its own scratch by path", "git -C {} log".format(OWN)), ("a relative path inside it", "cat ./x/../src/a.py"),
                    ("a code path named like the roots", "rg -n sessions memories projects xreview src"),
                    ("a search for a root's name in its own scratch, by absolute path", "rg -n xreview {}/dot_claude".format(OWN)),
                    ("git -C its own scratch by absolute path with a root's name in the pattern", "git -C {} log --grep xreview".format(OWN)),
                    ("a search for cxh in its own scratch", "rg -n cxh {}".format(OWN)),
                    ("a grep pattern naming a forbidden root's path (N3)", "rg -n '.claude/projects' dot_claude"),
                    ("a grep pattern spelled as a forbidden path", "rg -n ~/.codex/sessions src; grep -rn $XDG_STATE_HOME/xreview ."),
                    ("a grep pattern after options that take a value", "rg -n -C 3 -g '*.py' ~/.codex/memories src"),
                    ("a grep -e pattern", "grep -rn -e ~/.codex/sessions -e $XDG_STATE_HOME/cxh src"),
                    ("a git grep pattern", "git -C {} grep -n ~/.claude/projects".format(OWN)),
                    ("a glob inside its own scratch", "cat src/*.py"),
                    ("a subshell's cd does not outlive it", "(cd ~/Code/Org) && cat repo/x"),
                    ("a cd inside its own scratch and back up", "cd src && cat ../README.md"),
                    ("its own scratch through a symlink to it", "cat {}/src/a.py".format(os.path.join(ROOT, "to-own")))):
    if label.startswith("its own scratch through"):
        os.symlink(OWN, os.path.join(ROOT, "to-own"))
    is_("forbidden: {} is not a leak".format(label), forbid(text), [])
# ---- a recursive search rooted at an ancestor of a forbidden root walks into it (ruling on the restructure's concern 2)
for label, text, cwd in (("rg over the home directory", "rg foo ~", OWN), ("grep -r over ~/Code (the checkout's and the snapshot's parent)", "grep -rn foo ~/Code", OWN),
                         ("grep -R with options glued", "grep -inR foo $HOME", OWN), ("grep -d recurse", "grep -d recurse foo ~", OWN),
                         ("find over the home directory", "find ~ -name '*.jsonl'", OWN), ("find with global options first", "find -L ~/.codex -type f", OWN),
                         ("fd over ~/.codex", "fd -e jsonl x ~/.codex", OWN), ("fd --search-path", "fd jsonl --search-path ~/.claude", OWN),
                         ("tree over $XDG_STATE_HOME", "tree -L 2 $XDG_STATE_HOME", OWN), ("ls -R over ~/.claude", "ls -laR ~/.claude", OWN),
                         ("ag over /", "ag foo /", OWN), ("ack over ~/Code", "ack foo ~/Code", OWN),
                         ("rg with no path from a workdir above a root", json.dumps({"cmd": "rg foo", "workdir": house}), OWN),
                         ("rg with no path after cd to the home directory", "cd ~ && rg -n foo", OWN),
                         ("find with no path from $XDG_STATE_HOME", "cd $XDG_STATE_HOME; find -name x", OWN),
                         ("rg --files over the home directory", "rg --files ~", OWN)):
    got = forbid(text, cwd=cwd)
    ok("search: {} is a leak".format(label), got != [], got)
for label, text in (("rg over . from its own scratch", "rg foo ."), ("find . from its own scratch", "find . -name x"),
                    ("rg with no path from its own scratch", "rg -n foo"), ("grep -r with no path from its own scratch", "grep -rn foo"),
                    ("fd and tree inside its own scratch", "fd -e py x src; tree -L 2 src"), ("ls -R of its own scratch", "ls -R ."),
                    ("a grep without -r naming the home directory (it reads no directory)", "grep -n foo ~"), ("ls of the home directory, not recursive", "ls -la ~"),
                    ("an rg that reads a pipe, from a workdir above a root", json.dumps({"cmd": "git -C {} diff | rg foo".format(OWN), "workdir": house})),
                    ("rg over its own scratch by absolute path", "rg foo {}".format(OWN))):
    is_("search: {} is not a leak".format(label), forbid(text), [])
is_("search: an ancestor search reports every root beneath it", forbid("rg foo ~/Code"),
    sorted("{} in t1".format(x) for x in (house + "/Code/Org/repo", house + "/Code/.replay/snapshot")))

# ---- the review of the rewrite (eaceea4): I-1, M-1, M-2, M-3, M-5, M-6
CX, CL = house + "/.codex", house + "/.claude"
for label, rel in (("memories_v2 rollout summaries", ".codex/memories_v2/rollout_summaries/x.md"), ("memories_1.sqlite", ".codex/memories_1.sqlite"),
                   ("memories_v2_1.sqlite", ".codex/memories_v2_1.sqlite"), ("thread_history_1.sqlite", ".codex/thread_history_1.sqlite"),
                   ("state_5.sqlite", ".codex/state_5.sqlite"), ("logs_2.sqlite", ".codex/logs_2.sqlite"), ("Codex's history.jsonl", ".codex/history.jsonl"),
                   ("session_index.jsonl", ".codex/session_index.jsonl"), ("shell_snapshots", ".codex/shell_snapshots/x.sh"),
                   ("Claude's file-history", ".claude/file-history/abc/1.txt"), ("Claude's history.jsonl", ".claude/history.jsonl"),
                   ("a deployed guard in ~/.claude", ".claude/xreview-guard.py"), ("Claude's settings", ".claude/settings.json")):
    is_("home stores: reading {} is a leak (I-1)".format(label), forbid("sqlite3 ~/{} .dump".format(rel)), [(CX if rel.startswith(".codex") else CL) + " in t1"])
for label, rel in (("a ~/.codex skill", ".codex/skills/review/SKILL.md"), ("a ~/.codex plugin skill", ".codex/plugins/cache/m/agent-skills/0.6/skills/x/SKILL.md"),
                   ("~/.codex rules", ".codex/rules/default.rules"), ("~/.codex/AGENTS.md", ".codex/AGENTS.md"),
                   ("a ~/.claude plugin skill", ".claude/plugins/cache/o/superpowers/5.0/skills/x/SKILL.md"), ("a ~/.claude skill", ".claude/skills/x/SKILL.md"),
                   ("a ~/.claude agent", ".claude/agents/sp-architect.md"), ("~/.claude/CLAUDE.md", ".claude/CLAUDE.md")):
    is_("home stores: reading {} (instructions) is not a leak".format(label), forbid("cat ~/" + rel), [])
is_("home stores: a file that merely starts like ~/.codex/AGENTS.md is a leak", forbid("cat ~/.codex/AGENTS.md.bak"), [CX + " in t1"])
is_("home stores: an escape from ~/.codex/skills is judged where it lands", forbid("cat ~/.codex/skills/../memories/MEMORY.md"), [CX + " in t1"])
for label, cmd in (("rg with no path and stderr sent away", "rg -n defect 2>/dev/null"), ("rg with no path and its output redirected", "rg -n x > /tmp/out"),
                   ("grep -r with no path and 2>&1", "grep -rn x 2>&1"), ("ls -R with no path and stderr sent away", "ls -R 2>/dev/null"),
                   ("find with no path and &>", "find -name x &>/dev/null")):
    got = forbid(json.dumps({"cmd": cmd, "workdir": house}))
    ok("redirections: {} from a workdir above a root still walks it (M-1)".format(label), got != [], got)
is_("redirections: ... and from its own scratch it is clean", forbid("rg -n x 2>/dev/null; grep -rn x >/tmp/o 2>&1; ls -R 2>/dev/null"), [])
is_("redirections: an input redirection's target is still read", forbid("wc -l < ~/.codex/sessions/x.jsonl"), [CX + " in t1"])
for label, cmd in (("a $( ) inside a grep pattern", 'rg -n "$(head -1 ~/.codex/memories/MEMORY.md)" src'),
                   ("a backtick inside a grep pattern", 'rg -n "`head -1 ~/.codex/memories/MEMORY.md`" src')):
    is_("substitutions: {} still runs (M-2)".format(label), forbid(cmd), [CX + " in t1"])
for label, cmd, want in (("a cd to a computed directory does not go to $HOME", "cd $(git rev-parse --show-toplevel) && rg -n foo", []),
                         ("... nor with backticks", "cd `git rev-parse --show-toplevel` && rg -n foo", []),
                         ("$PWD is the tracked directory", 'rg foo "$PWD"; rg foo ${PWD}/src', []),
                         ("$(pwd) is the tracked directory", 'rg foo "$(pwd)"; cat `pwd`/src/a.py', []),
                         ("cd - returns to the previous directory, its own scratch", "cd ~ && cd - && rg foo", [])):
    is_("cwd: {} (M-3)".format(label), forbid(cmd), want)
ABOVE = sorted("{} in t1".format(x) for x in (house + "/Code/Org/repo", house + "/Code/.replay/snapshot", CX, CL))
is_("cwd: ... and a second cd - goes back again, above every root under $HOME", forbid("cd ~ && cd - && cd - && rg foo"), ABOVE)
is_("cwd: $PWD after a cd above a root is that directory", forbid('cd ~ && rg foo "$PWD"'), ABOVE)
is_("cwd: ... and so is $(pwd)", forbid('cd ~ && rg foo "$(pwd)"'), ABOVE)
for label, cmd in (("git log -G", "git log -G '~/.codex/memories' --oneline"), ("git log --grep", "git log --grep ~/.codex/sessions"),
                   ("git log --grep=", "git log --grep=$XDG_STATE_HOME/xreview"), ("git log -S glued", "git log -S'$XDG_STATE_HOME/xreview'"),
                   ("git diff -S", "git diff -S ~/.claude/projects HEAD~1"), ("git grep -e", "git grep -n -e ~/.codex/memories"),
                   ("rg --replace", "rg -n --replace '~/.codex/memories' x ."), ("rg -r", "rg -r ~/.claude x src")):
    is_("patterns: the value of {} is a pattern, not a path (M-5)".format(label), forbid(cmd), [])
is_("globs: a word that is no valid glob ([z-a]) does not break the scan, as a search root or deep enough to meet a root",
    forbid("rg foo '/[z-a]'; ls /[z-a]/a/b/c/d/e/f/g/h/i/j/k/l/m/n/o/p"), [])
for label, cmd, want in (("ag -g PAT DIR walks DIR", "ag -g jsonl ~/.codex", [CX + " in t1"]), ("ack -g PAT DIR walks DIR", "ack -g jsonl ~/.codex", [CX + " in t1"]),
                         ("ag -g with a forbidden-looking pattern in its own scratch", "ag -g '~/.codex' src", []),
                         ("ack --match PAT DIR", "ack --match '~/.codex' src", [])):
    is_("ag/ack: {} (M-6)".format(label), forbid(cmd), want)
MW = "cat $XDG_STATE_HOME/process-replay/memwatch/polls.jsonl"
is_("forbidden: the memories watcher's directory is open to an ordinary run", forbid(MW), [])
ok("forbidden: ... and forbidden to a memories run", forbid(MW, memwatch=True) != [], forbid(MW, memwatch=True))
ok("forbidden: ... by its path too", forbid("ls {}/process-replay/memwatch".format(XSH), memwatch=True) != [])

# ---- allowed subtrees: a §6 arm's own memories (F-3), a reviewer's own replay home's skills, plugins, rules and AGENTS.md (A)
HOME_A = os.path.join(XSH, "cxh", "mem-a1")
MEMWALL = K.forbidden(FSTATE, BRANCH, [OWN], home=HOME_A, memories=True)
is_("allowed: a path inside an allowed directory is not a read of the root above it (absolute, $XDG_STATE_HOME)",
    (forbid("cat {}/memories/MEMORY.md".format(HOME_A), wall=MEMWALL), forbid("cat $XDG_STATE_HOME/cxh/mem-a1/memories/MEMORY.md", wall=MEMWALL)), ([], []))
for label, text in (("another home's memories", "cat {}/cxh/mem-b2/memories/MEMORY.md".format(XSH)), ("the same home's sessions", "cat {}/sessions/x.jsonl".format(HOME_A)),
                    ("a directory that merely starts like the allowed one", "cat {}/memories-old/x".format(HOME_A)),
                    ("an escape from the allowed directory to its home's sessions (B)", "cat {}/memories/../sessions/x.jsonl".format(HOME_A)),
                    ("... in the $XDG_STATE_HOME spelling, to another home", "cat $XDG_STATE_HOME/cxh/mem-a1/memories/../../mem-b2/memories/x")):
    got = forbid(text, wall=MEMWALL)
    ok("allowed: {} is a leak".format(label), got == [os.path.join(XSH, "cxh") + " in t1"], got)
SKILLWALL = K.forbidden(FSTATE, BRANCH, [OWN], home=HOME_A)
is_("own_home: the parts of a replay home its reviewer may read", K.own_home("/h"), ["/h/skills", "/h/plugins", "/h/rules", "/h/AGENTS.md"])
is_("own_home: ... and for a memories arm its memories", K.own_home("/h", memories=True)[-1], "/h/memories")
is_("own_home: forbidden() allows them for the reviewer's home", SKILLWALL.allowed[-4:], [K._parts(os.path.realpath(x)) for x in K.own_home(HOME_A)])
for label, rel in (("a plugin's skill", "plugins/cache/market/superpowers/1.0.0/skills/brainstorming/SKILL.md"), ("a skill", "skills/review/SKILL.md"),
                   ("its rules", "rules/default.rules"), ("its AGENTS.md", "AGENTS.md")):
    is_("own_home: a reviewer reading {} in its own home is not a leak (A)".format(label), forbid("cat {}/{}".format(HOME_A, rel), wall=SKILLWALL), [])
for label, text in (("another home's plugin skill", "cat {}/cxh/nomem/plugins/cache/market/superpowers/1.0.0/skills/x/SKILL.md".format(XSH)),
                    ("its own home's sessions", "cat {}/sessions/2026/x.jsonl".format(HOME_A)), ("its own home's config", "cat {}/config.toml".format(HOME_A)),
                    ("a file that merely starts like AGENTS.md", "cat {}/AGENTS.md.bak".format(HOME_A)),
                    ("an escape from its plugins", "cat {}/plugins/../memories/x".format(HOME_A))):
    ok("own_home: {} is a leak".format(label), forbid(text, wall=SKILLWALL) != [], forbid(text, wall=SKILLWALL))
CXHOME = os.path.join(XSH, "cxh", "own-h")
CXWALL = K.forbidden(FSTATE, BRANCH, [OWN], home=CXHOME)
is_("own_home: $CODEX_HOME is the reviewer's own home: its skills are not a leak", forbid("cat $CODEX_HOME/skills/s/SKILL.md", wall=CXWALL, home=CXHOME), [])
is_("own_home: ... its sessions are", forbid("cat ${CODEX_HOME}/sessions/2026/x.jsonl", wall=CXWALL, home=CXHOME), [os.path.join(XSH, "cxh") + " in t1"])
w = World("ownhome")
home = os.path.join(XSH, "cxh", "ownhome")
helpers.write_rollout(home, "probe-ownhome", [{"turn": "pb", "answer": None}])
SKILL = os.path.join(home, "plugins", "cache", "market", "superpowers", "1.0.0", "skills", "x", "SKILL.md")
stub = stub_for("ownhome", home, {"default": {"answer": ans(), "tools": [tool("custom_tool_call", "cat " + SKILL)]}})
ok("own_home: a Codex round reading a plugin skill of its own replay home is a review (A)", w.round(home).get("kind") == "codex")
stub = stub_for("ownhome", home, {"default": {"answer": ans(), "tools": [tool("custom_tool_call", "cat " + SKILL.replace("/ownhome/", "/nomem/"))]}})
ok("own_home: ... and one reading another home's is void", "leak" in w.round(home))
wp = K.forbidden(FSTATE, BRANCH, [OWN, "/items/own"], snapshot_root="/elsewhere/snap")
ok("forbidden: a snapshot root given by the caller is forbidden too, and every own directory is allowed",
   "/elsewhere/snap" in [r.label for r in wp.roots] and wp.allowed[:2] == [K._parts(os.path.realpath(OWN)), ("items", "own")], wp)
# a case whose original is the chezmoi source: ~/.codex, ~/.claude and a replay home copied from them hold that repository's later
# state, so no instruction allowance applies; an A/A2 arm keeps its own memories. Any other repository keeps them all.
DOTFILES = {"repo": house + "/.local/share/chezmoi/.git"}
TAGTEAM = {"repo": house + "/.local/share/tagteam/.git"}
READS = (("~/.claude/CLAUDE.md", "cat ~/.claude/CLAUDE.md", CL), ("~/.codex/AGENTS.md", "cat ~/.codex/AGENTS.md", CX),
         ("a ~/.claude plugin skill", "cat ~/.claude/plugins/cache/o/superpowers/5.0/skills/x/SKILL.md", CL),
         ("~/.codex rules", "cat ~/.codex/rules/default.rules", CX),
         ("its own home's skill", "cat {}/skills/x/SKILL.md".format(HOME_A), os.path.join(XSH, "cxh")),
         ("its own home's plugin skill", "cat {}/plugins/cache/m/p/1/skills/x/SKILL.md".format(HOME_A), os.path.join(XSH, "cxh")))
dot_wall, tag_wall = K.forbidden(FSTATE, DOTFILES, [OWN], home=HOME_A, memories=True), K.forbidden(FSTATE, TAGTEAM, [OWN], home=HOME_A, memories=True)
for label, cmd, root in READS:
    is_("dotfiles: a dotfiles-case reviewer reading {} reads the source's later state: a leak".format(label), forbid(cmd, wall=dot_wall), [root + " in t1"])
    is_("dotfiles: ... a tagteam-case reviewer reading it is clean", forbid(cmd, wall=tag_wall), [])
is_("dotfiles: a dotfiles-case A/A2 arm still reads its own memories", forbid("cat {}/memories/MEMORY.md".format(HOME_A), wall=dot_wall), [])
is_("dotfiles: ... and its scratch", forbid("cat src/a.py", wall=dot_wall), [])
is_("dotfiles: a dotfiles-case wall allows only the reviewer's own directories", dot_wall.allowed,
    [K._parts(os.path.realpath(OWN)), K._parts(os.path.realpath(os.path.join(HOME_A, "memories")))])
OBJ, VIEW = os.path.join(ROOT, "objects-elsewhere"), os.path.join(ROOT, "view-elsewhere")
ovwall = K.forbidden(FSTATE, dict(BRANCH, objects=OBJ, view=VIEW), [OWN])
is_("forbidden: a branch's objects directory and its view are roots of their own, after the checkout (M-7)", [r.label for r in ovwall.roots][1:3], [OBJ, VIEW])
is_("forbidden: ... and reading either is a leak", (forbid("cat {}/pack/x.idx".format(OBJ), wall=ovwall), forbid("git -C {} log".format(VIEW), wall=ovwall)),
    ([OBJ + " in t1"], [VIEW + " in t1"]))

# ---- home_env
w = World("env")
home = replay_home("env")
wrapper = os.path.join(ROOT, "wrap-rpc")
real = helpers.stub_rpc(os.path.join(ROOT, "rpc-env"), home, {"default": {"answer": ans()}})
with open(wrapper, "w") as f:
    f.write('#!/bin/sh\necho "[$XREVIEW_RPC_SOCK][$XREVIEW_RPC_STDIO]" >> {}\nexec {} "$@"\n'.format(os.path.join(ROOT, "env.log"), real))
os.chmod(wrapper, 0o755)
XR.RPC = wrapper
os.environ["XREVIEW_RPC_SOCK"] = "/nonexistent/sock"
os.environ["XREVIEW_RPC_STDIO"] = "1"
before = os.environ["CODEX_HOME"]
out = w.round(home)
calls = log(real)
ok("home_env: the round made calls", len(calls) >= 3 and out.get("kind") == "codex", calls)
is_("home_env: every rpc call carries CODEX_HOME=<replay home>", sorted(set(e["codex_home"] for e in calls)), [home])
seen = open(os.path.join(ROOT, "env.log")).read().split("\n")
ok("home_env: an inherited XREVIEW_RPC_SOCK and XREVIEW_RPC_STDIO are dropped for the calls", set(l for l in seen if l) == {"[][]"}, seen)
is_("home_env: the environment is restored afterwards", (os.environ["CODEX_HOME"], os.environ["XREVIEW_RPC_SOCK"], os.environ["XREVIEW_RPC_STDIO"]), (before, "/nonexistent/sock", "1"))
del os.environ["XREVIEW_RPC_SOCK"], os.environ["XREVIEW_RPC_STDIO"]

# ---- errors keep what they spent
w = World("fail")
home = replay_home("fail")
stub = stub_for("fail", home, {"turns": [{"answer": ans(), "tokens": 700, "rc": 4, "raw": "not json"}]})
try:
    w.round(home)
    got = None
except K.RoundFailed as e:
    got = (e.tokens, e.thread, "schema-failed" in str(e))
is_("round_failed: a turn that fails raises RoundFailed with its tokens and thread", got, (700, "th1", True))
ok("round_failed: it is a Failed", issubclass(K.RoundFailed, Failed))


# ---- state_home_swap (two overlapping builds must leave L.state_home as it was)
real_state_home = L.state_home
in_a, seen_by = threading.Event(), {}


def swap_a():
    with K._state_home("/ledger/A"):
        in_a.set()
        seen_by["A_inside"] = L.state_home()
        time.sleep(0.3)
        seen_by["main_while_swapped"] = seen_by.get("main_while_swapped")
    seen_by["A_after"] = L.state_home()


def swap_b():
    in_a.wait()
    with K._state_home("/ledger/B"):
        seen_by["B_inside"] = L.state_home()


ta, tb = threading.Thread(target=swap_a), threading.Thread(target=swap_b)
ta.start()
tb.start()
in_a.wait()
other = L.state_home()
ta.join()
tb.join()
ok("state_home_swap: after overlapping swaps L.state_home is the real function", L.state_home is real_state_home)
is_("state_home_swap: each thread saw its own ledger home while it held the swap", (seen_by["A_inside"], seen_by["B_inside"]), ("/ledger/A", "/ledger/B"))
ok("state_home_swap: a thread not building saw the real state home meanwhile", other == real_state_home(), other)

# ---- leak_scan: lexical spellings
house = os.path.expanduser("~")
REPO = house + "/Code/Org/repo/.git"
SCR = "/work/scratch/x"
n_lk = [0]


def leaked(text, paths=(REPO,), cwd=SCR, kind="function_call", arguments=None):
    n_lk[0] += 1
    thread = "lx{}".format(n_lk[0])
    rollout(thread, [{"turn": "t1", "answer": None, "tools": [tool(kind, text if arguments is None else arguments)]}])
    return K.leaks(lhome, [(thread, "t1")], K.wall(list(paths)), cwd)


want = [house + "/Code/Org/repo in t1"]
# The cwd was /work/scratch/x, from which five .. land on /Code/Org/repo, not the checkout: the old textual tail match flagged it all
# the same. Resolved, the climb is a leak from where a scratch really lives (under ~/.local/state), and not from elsewhere.
REAL_SCR = house + "/.local/state/review-work/scratch/lab1"
is_("leak_scan: ../ climbing out of the scratch cwd to ~/Code/Org/repo is a leak", leaked("cat ../../../../../Code/Org/repo/src/a.py", cwd=REAL_SCR), want)
is_("leak_scan: ... while the same climb from a cwd where it lands elsewhere (/Code/Org/repo) is not", leaked("cat ../../../../../Code/Org/repo/src/a.py"), [])
is_("leak_scan: ${HOME}/ spelling is a leak", leaked("cat ${HOME}/Code/Org/repo/x"), want)
is_("leak_scan: $HOME/ spelling is a leak", leaked("cat $HOME/Code/Org/repo/x"), want)
is_("leak_scan: a sibling named under the HOME-relative tail is a leak", leaked("cat ~/Code/Org/repo-feat/x"), want)
is_("leak_scan: cd to the parent, then a token naming the sibling, in one call, is a leak", leaked("cd ~/Code/Org && cat repo-feat/x"), want)
is_("leak_scan: ... and a quoted bash -lc command is read the same", leaked(json.dumps({"cmd": ["bash", "-lc", "cd ~/Code/Org && cat repo/x"]})), want)
is_("leak_scan: another repository under the same parent is not a leak", leaked("cd ~/Code/Org && cat repox/x; cat ~/Code/Org/other/y"), [])
is_("leak_scan: the scratch repository's own files are not a leak", leaked("cat src/a.py; ls ../.. ; cat repo/x"), [])
is_("leak_scan: a relative path with .. that resolves to the original is a leak", leaked("cat ../../orig/src/a.py", ["/work/orig/.git"]), ["/work/orig in t1"])
is_("leak_scan: ... but only against the cwd it starts from", leaked("cat ../../orig/src/a.py", ["/work/orig/.git"], cwd="/elsewhere/a/b"), [])
is_("leak_scan: a call's own workdir is where its relative paths start",
    leaked(None, ["/work/orig/.git"], cwd="/elsewhere/a/b", arguments=json.dumps({"cmd": ["bash", "-lc", "cat ../orig/a"], "workdir": "/work/scratch"})),
    ["/work/orig in t1"])
is_("leak_scan: a relative path that resolves inside the scratch is not a leak", leaked("cat ../x/../x/a.py", ["/work/orig/.git"]), [])

# ---- scratch_neutral
w = World("neutral")
home = replay_home("neutral")
stub = stub_for("neutral", home, {"default": {"answer": ans()}})
saved = w.run["scratch"]
real_dir = os.path.join(ROOT, "process-replay", "x")
os.makedirs(real_dir)
for label, where in (("a path naming process-replay", real_dir),
                     ("a neutral-looking link into process-replay", os.path.join(ROOT, "neutral-link"))):
    if where.endswith("neutral-link"):
        os.symlink(real_dir, where)
    w.run["scratch"] = where
    try:
        w.round(home)
        got = None
    except Failed as e:
        got = str(e)
    ok("scratch_neutral: " + label + " is refused before any call", got is not None and "names the replay" in got and log(stub) == [], got)
w.run["scratch"] = saved
try:
    K.prepare_ledger(args(), dict(w.run, scratch=real_dir), w.case, w.branch)
    got = None
except Failed as e:
    got = str(e)
ok("scratch_neutral: prepare_ledger refuses it too", got is not None and "names the replay" in got, got)

# ---- token_stop: the run's own file is not counted twice
w = World("stop2")
home = replay_home("stop2")
stub = stub_for("stop2", home, {"default": {"answer": ans()}})
STATE2 = os.path.join(ROOT, "state-stop2")
XR.jsave(os.path.join(STATE2, "runs", "cstop2", "lab1", "state.json"), {"case": "cstop2", "label": "lab1", "tokens": 99999})
XR.jsave(os.path.join(STATE2, "runs", "cother2", "labx", "state.json"), {"case": "cother2", "label": "labx", "tokens": 500})
w.run["tokens"] = 100
out = K.codex_round(args(state=STATE2, max_tokens=1000), w.run, w.case, w.branch, home)
ok("token_stop: caller 100 + another run's 500 is below 1000: the run's own file (99999) is not counted", out.get("kind") == "codex", out)
w.run["reviews"], w.run["thread"] = [], None
out = K.codex_round(args(state=STATE2, max_tokens=600), w.run, w.case, w.branch, home)
ok("token_stop: ... and 100 + 500 does stop at 600", set(out) == {"stopped"}, out)

# ---- missing_per_turn
w = World("permissive", big=True)
home = replay_home("permissive", window=110000)
stub = stub_for("permissive-probe", home, {"default": {"answer": ans("approve", (), files=())}})
probe = w.round(home)
shown1, shown2 = probe["decision"]["packets"][0]["shown"], probe["decision"]["packets"][1]["shown"]
ok("missing_per_turn: the fixture has two slices with labels of their own", len(probe["turns"]) >= 2 and shown1 and shown2 and not set(shown1) & set(shown2), (shown1, shown2))
w.run["reviews"], w.run["thread"] = [], None
home = replay_home("permissive2", window=110000)
stub = stub_for("permissive-run", home, {"turns": [{"answer": ans("approve", (), files=shown1[1:])}, {"answer": ans("approve", (), files=shown1 + shown2)}],
                                          "default": {"answer": ans("approve", (), files=())}})
rv = w.round(home)
allshown = [l for pk in rv["decision"]["packets"] for l in pk["shown"]]
rest = [l for pk in rv["decision"]["packets"][2:] for l in pk["shown"]]
is_("missing_per_turn: a label only slice 2 listed, shown in slice 1, stays missing; shown order is kept",
    rv["missing"], [shown1[0]] + rest)

# ---- weekly: the greatest timestamp across the replay home and the live home
def stamped(home, name, pct, stamp, resets=FUTURE, mtime=None):
    recs, _t = helpers.rollout_lines({"turn": "s1", "answer": None, "rate_limits": {"primary": {"used_percent": pct, "window_minutes": 10080, "resets_at": resets}}})
    for r in recs:
        r["timestamp"] = stamp
    path = helpers.rollout_file(home, name)
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w") as f:
        f.write("".join(json.dumps(r) + "\n" for r in recs))
    if mtime is not None:
        os.utime(path, (mtime, mtime))
    return path


rep_home, live_home = os.path.join(ROOT, "cxh", "wts-replay"), os.path.join(ROOT, "wts-live")
stamped(rep_home, "r", 85, "2026-11-02T10:00:00.000Z", mtime=time.time())
stamped(live_home, "l", 10, "2026-11-02T11:00:00.000Z", mtime=time.time() - 5000)
is_("weekly_live: the live home's newer figure wins over the replay home's stale one, whatever the file times", K.weekly(rep_home, live=live_home), (10.0, FUTURE))
stamped(live_home, "l", 10, "2026-11-02T09:00:00.000Z", mtime=time.time() + 5000)
is_("weekly_live: the replay home's newer figure wins over an older live one", K.weekly(rep_home, live=live_home), (85.0, FUTURE))
is_("weekly_live: the live home is optional", K.weekly(rep_home, live=os.path.join(ROOT, "no-such-home")), (85.0, FUTURE))
w = World("livepause")
home = replay_home("livepause")
stub = stub_for("livepause", home, {"default": {"answer": ans()}})
live_file = stamped(ORIGINAL_HOME, "live-lim", 90, "2999-01-01T00:00:00.000Z")
out = w.round(home)
os.remove(live_file)
ok("weekly_live: the pause reads the live home (CODEX_HOME as the process had it) without writing there", "paused" in out and log(stub) == [], out)
unknown = os.path.join(ROOT, "cxh", "wts-unknown")
recs, _t = helpers.rollout_lines({"turn": "u1", "answer": None, "rate_limits": {"primary": {"used_percent": 88, "window_minutes": 10080}}})
os.makedirs(os.path.join(unknown, "sessions", "x"))
with open(os.path.join(unknown, "sessions", "x", "rollout-2026-10-20T10-00-00-u.jsonl"), "w") as f:
    f.write("".join(json.dumps(r) + "\n" for r in recs))
is_("weekly_live: a window without resets_at is still read, with resets_at None", K.weekly(unknown, live=os.path.join(ROOT, "no-such-home")), (88.0, None))
w = World("unknownpause")
stub = stub_for("unknownpause", unknown, {"default": {"answer": ans()}})
helpers.write_rollout(unknown, "probe-u", [{"turn": "pb", "answer": None}])
os.utime(helpers.rollout_file(unknown, "probe-u"), (time.time() - 50, time.time() - 50))
out = w.round(unknown)
ok("weekly_live: ... and pauses, reporting resets_at as unknown", out.get("resets_at", 1) is None and "unknown" in out.get("paused", ""), out)

# ---- build failures and failed rounds
w = World("buildfail")
home = replay_home("buildfail")
stub = stub_for("buildfail", home, {"default": {"answer": ans()}})
orig_build = K.XP.build
K.XP.build = lambda *a, **k: (_ for _ in ()).throw(KeyError("boom"))
try:
    K.codex_round(args(), w.run, w.case, w.branch, home)
    got = None
except K.RoundFailed as e:
    got = str(e)
finally:
    K.XP.build = orig_build
ok("round_failed: any exception from the packet builder becomes a RoundFailed", got is not None and "cannot build the packet" in got and "boom" in got, got)
w = World("failleak")
home = replay_home("failleak")
stub = stub_for("failleak", home, {"turns": [{"answer": ans(), "tokens": 300, "rc": 4, "raw": "not json",
                                               "tools": [tool("custom_tool_call", "cat {}/src/a.py".format(w.workdir))]}]})
try:
    w.round(home)
    got = None
except K.RoundFailed as e:
    got = (e.tokens, e.leak)
is_("round_failed: the turns of a failed round are leak-scanned and the leak rides on the exception", got, (300, [w.workdir + " in tu1"]))


# ---- leak_scan, round 2: parents only as paths, glued options, workdirs of every call shape, repo-specific tools
def fc(cmd, **more):
    return json.dumps(dict({"cmd": cmd}, **more))


HULDER = [house + "/Code/hulder/.git"]
is_("leak_scan: ordinary text naming Code and the repo's name as a word is not a leak (parent only as a path)",
    leaked("rg -n 'Claude Code' docs; rg -n hulder setup.py", HULDER), [])
is_("leak_scan: ... while the parent spelled as a path beside the name is", leaked("cd ~/Code && cat hulder/x", HULDER), [house + "/Code/hulder in t1"])
TAG = [house + "/.local/share/tagteam/.git"]
is_("leak_scan: another tool reading ~/.local/share/foo is not a leak for a repo beside it", leaked(fc("chezmoi cat ~/.local/share/foo"), TAG), [])
is_("leak_scan: the bare tail .local/share is never the parent", leaked("rg -n tagteam .local/share/x", TAG), [])
is_("leak_scan: ${HOME}/.local/share beside the name is", leaked("cd ${HOME}/.local/share && ls tagteam", TAG), [house + "/.local/share/tagteam in t1"])
DOT = [house + "/dotrepo/.git"]
is_("leak_scan: a repo directly under $HOME: its parent does not fire on the scratch workdir",
    leaked("cd {}/.local/state/review-work/scratch/lab1 && cat dotrepo/x".format(house), DOT), [])
is_("leak_scan: ... its own path still does", leaked("cat ~/dotrepo/x", DOT), [house + "/dotrepo in t1"])
is_("leak_scan: ... as does $HOME/ or ${HOME}/", (leaked("cat $HOME/dotrepo/x", DOT), leaked("cat ${HOME}/dotrepo/x", DOT)), ([house + "/dotrepo in t1"],) * 2)
is_("leak_scan: a file named like a repo directly under $HOME is not a leak", leaked("cat src/dotrepo.py", DOT), [])
SCR2 = house + "/.local/state/review-work/scratch/lab1"
is_("leak_scan: a .. token that resolves to the parent, beside the name, is a leak", leaked("cd ../../../../share && cat tagteam/x", TAG, cwd=SCR2), [house + "/.local/share/tagteam in t1"])
is_("leak_scan: git -C glued to a .. path is resolved", leaked("git -C../../orig log", ["/work/orig/.git"]), ["/work/orig in t1"])
is_("leak_scan: --git-dir= with a .. path is resolved", leaked("git --git-dir=../../orig/.git log", ["/work/orig/.git"]), ["/work/orig in t1"])
is_("leak_scan: NAME=../x is resolved", leaked("GIT_DIR=../../orig/.git git log", ["/work/orig/.git"]), ["/work/orig in t1"])
is_("leak_scan: an option glued to a path inside the scratch is not a leak", leaked("git -C../x log", ["/work/orig/.git"]), [])


def leaked_payload(payload, paths, cwd=SCR):
    n_lk[0] += 1
    thread = "lp{}".format(n_lk[0])
    recs, _t = helpers.rollout_lines({"turn": "t1", "answer": None, "tools": [tool("function_call", "x")]})
    for r in recs:
        if r["type"] == "response_item" and r["payload"].get("type") == "function_call":
            r["payload"] = payload
    path = helpers.rollout_file(lhome, thread)
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w") as f:
        f.write("".join(json.dumps(r) + "\n" for r in recs))
    return K.leaks(lhome, [(thread, "t1")], K.wall(list(paths)), cwd)


ORIG = ["/work/orig/.git"]
js = 'text(await tools.exec_command({cmd:"cat ../orig/a",workdir:"/work/scratch"}));\n'
is_("leak_scan: a Codex exec call's JavaScript workdir is where its relative paths start",
    leaked_payload({"type": "custom_tool_call", "name": "exec", "input": js}, ORIG, cwd="/elsewhere/a/b"), ["/work/orig in t1"])
is_("leak_scan: ... with the key quoted as JSON writes it",
    leaked_payload({"type": "custom_tool_call", "name": "exec", "input": js.replace("workdir:", '"workdir":')}, ORIG, cwd="/elsewhere/a/b"), ["/work/orig in t1"])
is_("leak_scan: ... and without a workdir the scratch path is the fallback",
    leaked_payload({"type": "custom_tool_call", "name": "exec", "input": 'text(await tools.exec_command({cmd:"cat ../orig/a"}));'}, ORIG, cwd="/elsewhere/a/b"), [])
two = 'const r=await Promise.all([tools.exec_command({cmd:"ls ../orig",workdir:"/other/place"}),tools.exec_command({cmd:"ls ../orig",workdir:"/work/scratch"})]);'
is_("leak_scan: each exec_command of one input has its own workdir",
    leaked_payload({"type": "custom_tool_call", "name": "exec", "input": two}, ORIG, cwd="/elsewhere/a/b"), ["/work/orig in t1"])
shell = {"type": "local_shell_call", "action": {"type": "exec", "command": ["bash", "-lc", "cat ../orig/a"], "working_directory": "/work/scratch"}}
is_("leak_scan: a local_shell_call's working_directory is read", leaked_payload(shell, ORIG, cwd="/elsewhere/a/b"), ["/work/orig in t1"])
is_("leak_scan: ... and without it the scratch path is the fallback",
    leaked_payload({"type": "local_shell_call", "action": {"type": "exec", "command": ["bash", "-lc", "cat ../orig/a"]}}, ORIG, cwd="/elsewhere/a/b"), [])

CHZ = [house + "/.local/share/chezmoi/.git"]
for label, call in (("a bare command", fc("chezmoi apply")), ("after &&", fc("cd /tmp && chezmoi diff")), ("after ;", fc("ls; chezmoi status")),
                    ("after a pipe", fc("ls | chezmoi execute-template")), ("after command", fc("command chezmoi cat x")),
                    ("after env and an assignment", fc("env FOO=1 chezmoi managed")), ("by its full path", fc("/opt/homebrew/bin/chezmoi diff")),
                    ("inside bash -lc", fc(["bash", "-lc", "chezmoi diff"])), ("inside sh -c", fc("sh -c 'cd /tmp; chezmoi diff'"))):
    is_("tool_words: chezmoi run as a command ({}) is a leak when the original is the chezmoi source".format(label), leaked(call, CHZ), [house + "/.local/share/chezmoi in t1"])
is_("tool_words: a Codex exec call running chezmoi is a leak",
    leaked_payload({"type": "custom_tool_call", "name": "exec", "input": 'text(await tools.exec_command({cmd:"chezmoi diff"}));'}, CHZ), [house + "/.local/share/chezmoi in t1"])
is_("tool_words: $XDG_DATA_HOME/chezmoi is a leak", leaked("cat $XDG_DATA_HOME/chezmoi/AGENTS.md", CHZ), [house + "/.local/share/chezmoi in t1"])
is_("tool_words: ${XDG_DATA_HOME}/chezmoi is a leak", leaked("cat ${XDG_DATA_HOME}/chezmoi/AGENTS.md", CHZ), [house + "/.local/share/chezmoi in t1"])
for label, call in (("an argument", fc("rg -n chezmoi docs")), ("a path component", fc("cat docs/chezmoi.md")), ("a quoted string", fc('echo "chezmoi apply"')),
                    ("a file name", fc("cat /tmp/chezmoi-notes")), ("a longer word", fc("git log -- dot_chezmoi"))):
    is_("tool_words: chezmoi as {} is not a leak".format(label), leaked(call, CHZ), [])
is_("tool_words: for any other original, running chezmoi is not a leak", leaked(fc("chezmoi apply"), ORIG), [])

# ---- weekly: a rollout that vanishes while listed
real_glob = K.glob.glob
vanished = os.path.join(ROOT, "cxh", "wk-vanish", "sessions", "2026", "rollout-2026-10-20T10-00-00-gone.jsonl")
K.glob.glob = lambda *a, **k: real_glob(*a, **k) + [vanished]
try:
    got = K.weekly(replay_home("wk-vanish"), live=os.path.join(ROOT, "no-such-home"))
finally:
    K.glob.glob = real_glob
is_("weekly_vanish: a rollout that moves between the listing and the read is skipped, not raised", got, None)
is_("weekly_vanish: a missing file has modification time 0", K._mtime(vanished), 0)

# ---- tool_words, round 3: command positions, lookups, template literals
CHZN = [house + "/.local/share/chezmoi in t1"]
for label, cmd in (("after a newline", "ls\nchezmoi diff"), ("after an indented newline", "cd /tmp\n  chezmoi cat x"), ("after a CRLF", "echo hi\r\nchezmoi diff"),
                   ("after then", "if true; then chezmoi diff; fi"), ("after then on its own line", "if true\nthen\n  chezmoi diff\nfi"),
                   ("after do", "for f in a; do chezmoi cat $f; done"), ("after else", "if false; then ls; else chezmoi diff; fi"),
                   ("inside braces", "{ chezmoi diff; }"), ("after !", "! chezmoi diff"), ("inside $( )", "echo $(chezmoi diff)"),
                   ("inside a double-quoted $( )", 'echo "$(chezmoi diff)"'), ("inside backticks", "echo `chezmoi diff`"),
                   ("under xargs", "xargs chezmoi diff < f"), ("under xargs with options", "ls | xargs -n 1 -I {} chezmoi cat {}"),
                   ("under timeout", "timeout 10 chezmoi diff"), ("under nice", "nice -n 5 chezmoi diff"), ("under nice", "nice chezmoi diff"),
                   ("under env -u", "env -u X chezmoi diff"), ("under env with an assignment", "env A=1 -u X chezmoi diff"),
                   ("under sudo -u", "sudo -u me chezmoi diff"), ("under sudo -E", "sudo -E chezmoi diff"),
                   ("under mise exec --", "mise exec -- chezmoi diff"), ("with no space after &&", "ls &&chezmoi diff"), ("after a semicolon", "ls;chezmoi diff"),
                   ("as ./chezmoi", "./chezmoi diff"), ("after a comment-free multi-line script", "set -e\ncd ~/x\nchezmoi apply --dry-run")):
    is_("tool_words: chezmoi {} is a leak".format(label), leaked(fc(cmd), CHZ), CHZN)
for label, cmd in (("command -v", "command -v chezmoi"), ("command -V", "command -V chezmoi"), ("which", "which chezmoi"), ("type", "type chezmoi"),
                   ("hash", "hash chezmoi"), ("a lookup in an if", "if command -v chezmoi >/dev/null; then echo yes; fi"),
                   ("a lookup after a newline", "ls\ncommand -v chezmoi"), ("a heredoc body", "cat <<EOF\nchezmoi diff\nEOF"),
                   ("a quoted heredoc body", "cat <<'EOF' > x\nls\nchezmoi apply\nEOF\nls"), ("a quoted multi-line string", "echo 'a\nchezmoi diff'"),
                   ("an argument of xargs", "ls | xargs rg chezmoi"), ("a lookup under sudo", "sudo which chezmoi")):
    is_("tool_words: {} only looks the binary up, or is not a command: not a leak".format(label), leaked(fc(cmd), CHZ), [])
is_("tool_words: the heredoc's later lines are commands again", leaked(fc("cat <<EOF\nx\nEOF\nchezmoi diff"), CHZ), CHZN)
TL = 'await tools.exec_command({cmd:`ls\nchezmoi diff`, workdir:`/work/scratch`});'
is_("tool_words: a template-literal cmd is read", leaked_payload({"type": "custom_tool_call", "name": "exec", "input": TL}, CHZ), CHZN)
TL2 = 'await tools.exec_command({cmd:`cat ../orig/a`, workdir:`/work/scratch`});'
is_("leak_scan: a template-literal workdir is read", leaked_payload({"type": "custom_tool_call", "name": "exec", "input": TL2}, ORIG, cwd="/elsewhere/a/b"), ["/work/orig in t1"])
is_("leak_scan: a template-literal cmd with a newline escape and workdir", leaked_payload(
    {"type": "custom_tool_call", "name": "exec", "input": 'tools.exec_command({cmd:`ls\\ncat ../orig/a`,workdir:`/work/scratch`})'}, ORIG, cwd="/elsewhere/a/b"), ["/work/orig in t1"])

# ---- parent as a path: the reviewer's round-2 probes
# Was a leak under the textual parent-plus-basename rule (ruling T7-l kept it as a conservative positive); both words are grep
# patterns, which name no path read, and nothing else in the call resolves into the chezmoi source.
is_("leak_scan: the parent and the basename as two grep patterns are not a read (original: the chezmoi source)",
    leaked("rg -n 'chezmoi' README.md; rg -n '~/.local/share' AGENTS.md", CHZ), [])
is_("leak_scan: ... while a cd to the parent and the basename as a path is", leaked("cd ~/.local/share && cat chezmoi/AGENTS.md", CHZ), CHZN)
is_("leak_scan: a trailing comment naming Code and a module named like the repo is not a leak", leaked("python -m hulder.cli --help  # Code", HULDER), [])
is_("leak_scan: a Code glob and an ls of the repo's name is not a leak", leaked("rg 'Code' -g '*.md' && ls hulder", HULDER), [])

# ---- comments in a multi-line command
is_("tool_words: a comment does not hide the next line", leaked(fc("ls # note\nchezmoi diff"), CHZ), CHZN)
is_("tool_words: an apostrophe in a comment does not open a quote", leaked(fc("ls # don't\nchezmoi diff"), CHZ), CHZN)
is_("tool_words: a comment line of its own", leaked(fc("# the chezmoi diff\nls"), CHZ), [])
is_("tool_words: a # inside a word is not a comment", K._logical("echo a#b; ls"), "echo a#b; ls")
is_("tool_words: a # in quotes is not a comment", K._logical("echo '# x' \"# y\"\nls"), "echo '# x' \"# y\" ; ls")
is_("tool_words: a command inside a comment's line is not run", leaked(fc("ls # chezmoi diff"), CHZ), [])
is_("tool_words: a here-string is not a heredoc: the next line is a command again", leaked(fc("cat <<< x\nchezmoi diff"), CHZ), CHZN)
is_("tool_words: a heredoc body is not run, but a path in it is read", leaked(fc("sh <<'EOF'\ncat ~/.local/share/chezmoi/AGENTS.md\nEOF"), CHZ), CHZN)
