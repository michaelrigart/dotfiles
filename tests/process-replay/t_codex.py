import json
import os
import sys
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
        self.scratch = os.path.join(STATE, "scratch", name)
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
ok("plans_omitted_as_today: the target's repository is the scratch's alias, which names no replay",
   rv["decision"]["targets"][0]["repo"].endswith("/scratch/plans/.git") and "process-replay" not in rv["decision"]["targets"][0]["repo"],
   rv["decision"]["targets"][0]["repo"])
turn_cwd = [e["cwd"] for e in log(stub) if e["cmd"] == "turn-start"][0]
ok("plans_omitted_as_today: the turn's cwd is the alias of the scratch repository", turn_cwd == C.aliased(STATE, w.scratch) and turn_cwd != w.scratch, turn_cwd)
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
alias_repo = C.aliased(STATE, w.scratch) + "/.git"
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


def tool(kind, text):
    return {"type": kind, "name": "shell", "arguments": text}


def rollout(thread, turns, user=None):
    recs, total = [], 0
    for t in turns:
        more, total = helpers.rollout_lines(t, total)
        if user:
            more.insert(1, {"type": "response_item", "payload": {"type": "message", "role": "user", "content": [{"type": "input_text", "text": user}]}})
        recs += more
    path = helpers.rollout_file(lhome, thread)
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w") as f:
        f.write("".join(json.dumps(r) + "\n" for r in recs))


rollout("lk1", [{"turn": "t1", "answer": None, "tools": [tool("custom_tool_call", "cat {}/src/a.py".format(W))]}])
is_("leak_scan: a custom_tool_call naming the original work dir is a leak", K.leaks(lhome, [("lk1", "t1")], [W]), [W + " in t1"])
rollout("lk2", [{"turn": "t1", "answer": None, "tools": [tool("function_call", json.dumps({"cmd": "ls {}-feat/src".format(W)}))]}])
is_("leak_scan: a function_call naming a sibling <dir>-feat is a leak", K.leaks(lhome, [("lk2", "t1")], [W]), [W + " in t1"])
rollout("lk3", [{"turn": "t1", "answer": None, "developer": "the checkout is {} and {}-feat".format(W, W), "tools": [tool("function_call", "ls /scratch/x")]}],
        user="please read {}/src/a.py".format(W))
is_("leak_scan: the same path in a user or developer message is not a leak", K.leaks(lhome, [("lk3", "t1")], [W]), [])
rollout("lk4", [{"turn": "t1", "answer": None, "tools": [tool("function_call", "ls {}x/src {}2".format(W, W))]}])
is_("leak_scan: another directory whose name merely starts the same is not a leak", K.leaks(lhome, [("lk4", "t1")], [W]), [])
rollout("lk5", [{"turn": "t1", "answer": None, "tools": [tool("function_call", "ls /scratch")]},
                {"turn": "t2", "answer": None, "tools": [tool("function_call", "ls " + W)]}])
is_("leak_scan: only the named turns are read", K.leaks(lhome, [("lk5", "t1")], [W]), [])
is_("leak_scan: ... and a named turn that leaked is found", K.leaks(lhome, [("lk5", "t1"), ("lk5", "t2")], [W]), [W + " in t2"])
house = os.path.expanduser("~")
rollout("lk6", [{"turn": "t1", "answer": None, "tools": [tool("custom_tool_call", "cat ~/Code/Org/repo/x")]}])
is_("leak_scan: the ~ spelling of a path under $HOME is a leak", K.leaks(lhome, [("lk6", "t1")], [house + "/Code/Org/repo/.git"]), ["~/Code/Org/repo in t1"])
is_("leak_scan: a thread with no rollout reads as clean", K.leaks(lhome, [("nothing", "t1")], [W]), [])
w = World("leakround")
home = replay_home("leakround")
stub = stub_for("leakround", home, {"default": {"answer": ans(), "tools": [tool("custom_tool_call", "cat {}/src/a.py".format(w.workdir))]}})
out = w.round(home)
ok("leak_scan: a round whose turn read the original checkout is void, with its tokens", set(out) == {"leak", "tokens", "thread", "turns"} and out["tokens"] == 1000 and out["leak"], out)
w = World("cleanround")
home = replay_home("cleanround")
stub = stub_for("cleanround", home, {"default": {"answer": ans(), "tools": [tool("custom_tool_call", "cat src/a.py")]}})
ok("leak_scan: a round that read only the scratch repository is a review", w.round(home).get("kind") == "codex")

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
