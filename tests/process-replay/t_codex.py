import json
import os
import shutil
import subprocess
import sys
import tempfile
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

    def peek(self, home, **kw):
        """A round whose outcome is not applied to the run (and so not charged): it leaves the flight as soon as it returns."""
        a = args(**kw)
        out = K.codex_round(a, self.run, self.case, self.branch, home)
        with K.settling(a, self.run):
            pass
        return out

    def round(self, home, **kw):
        a = args(**kw)
        out = K.codex_round(a, self.run, self.case, self.branch, home)
        with K.settling(a, self.run):          # as the loop does: the outcome is charged and the round leaves the flight in one step
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

# ---- ledger_receipts_once: the run's ledger holds each receipt once, and none whose nonce two receipts share with different content
def second_ledger(w, entries):
    """Another ledger file that names the world's repository (a ledger copied, as the harness meets them)."""
    d = os.path.join(os.environ["XDG_STATE_HOME"], "xreview", "ledgers", "second-" + w.name)
    os.makedirs(d)
    with open(os.path.join(d, "reviews.jsonl"), "w") as f:
        f.write("".join(json.dumps(e) + "\n" for e in entries))
    with open(os.path.join(d, "repo"), "w") as f:
        f.write(w.common + "\n")


def prepared_nonces(w):
    led = K.prepare_ledger(args(), w.run, w.case, w.branch)
    return [e["nonce"] for e in L.read_entries(os.path.join(led, "xreview", "ledgers", L.ledger_key(w.scratch + "/.git"), "reviews.jsonl"))]


def plan_entry_of(w):
    return next(e for e in L.read_entries(os.path.join(os.environ["XDG_STATE_HOME"], "xreview", "ledgers", L.ledger_key(w.common), "reviews.jsonl"))
                if e["checkpoint"] == "plan")


w = World("ledgerdup", prepare=False)
second_ledger(w, [plan_entry_of(w), plan_entry_of(w)])
is_("ledger_receipts_once: a plan receipt held by two ledgers of the repository (one of them twice) is in the run's ledger once",
    prepared_nonces(w), ["pn-ledgerdup"])
w = World("ledgerclash", prepare=False)
second_ledger(w, [dict(plan_entry_of(w), verdict="changes")])
is_("ledger_receipts_once: two plan receipts of one nonce that differ are neither in the run's ledger (neither is picked)", prepared_nonces(w), [])

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
is_("weekly_pause: 79.9% does not pause", "paused" in w.peek(home), False)
home = limits({"used_percent": 99, "window_minutes": 10080}, None, "wk4", resets=int(time.time()) - 5)
is_("weekly_pause: a window that has reset does not pause", "paused" in w.peek(home), False)
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
is_("forbidden: the roots, by the path they are reported as: the checkout, the state, review-work, the snapshot home, the running harness, October's answers, xreview, cxh",
    [r.label for r in fwall.roots],
    [house + "/Code/Org/repo", FSTATE, os.path.join(XSH, "review-work"), os.path.join(XSH, "process-replay", "snapshot"), helpers.SRC, house + "/.codex",
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
                    ("the snapshot root", "ls $XDG_STATE_HOME/process-replay/snapshot/2026-11-02"), ("October's codex sessions", "rg -n x ~/.codex/sessions/2026"),
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
                    ("a cd inside its own scratch", "cd src && cat a.py ./b.py"),
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
    sorted("{} in t1".format(x) for x in (house + "/Code/Org/repo",)))

# ---- the snapshot's home, every harness export, and beneath (spec 14.3 a, R4)
EXPORT = os.path.join(XSH, "process-replay", "harness-abc1234")
put(EXPORT, "dot_claude/x", "x\n")
ewall = K.forbidden(FSTATE, BRANCH, [OWN])
is_("exports_forbidden: a harness export under $XDG_STATE_HOME/process-replay is a root, after the running harness",
    [r.label for r in ewall.roots if r.label in (EXPORT, helpers.SRC)], [helpers.SRC, EXPORT])
is_("exports_forbidden: reading a file in it is a leak labelled that directory", forbid("cat {}/dot_claude/x".format(EXPORT), wall=ewall), [EXPORT + " in t1"])
is_("exports_forbidden: ... and reading the running harness's own root is a leak", forbid("cat {}/.scripts/process-replay.py".format(helpers.SRC)), [helpers.SRC + " in t1"])
is_("exports_forbidden: ... but a file that is no export, beside them, is not", forbid("cat {}/process-replay/other/x".format(XSH), wall=ewall), [])
EXPORT0 = os.path.join(XSH, "process-replay", "harness-0000000")
put(EXPORT0, "x", "x\n")
put(os.path.join(XSH, "process-replay"), "harness-file", "not a directory\n")
is_("exports_sorted_dirs_only: the running harness first, then the harness-* directories in sorted order, and no plain file named harness-*",
    K.exports(), [helpers.SRC, EXPORT0, EXPORT])
_glob = K.glob.glob
K.glob.glob = lambda *a_, **k_: sorted(_glob(*a_, **k_), reverse=True)      # a filesystem need not list in order
try:
    is_("exports_sorted_dirs_only: ... whatever order the filesystem lists them in", K.exports(), [helpers.SRC, EXPORT0, EXPORT])
finally:
    K.glob.glob = _glob
shutil.rmtree(EXPORT0)
os.remove(os.path.join(XSH, "process-replay", "harness-file"))
shutil.rmtree(EXPORT)
is_("snapshot_new_home: the snapshot under $XDG_STATE_HOME/process-replay is a leak", forbid("ls $XDG_STATE_HOME/process-replay/snapshot/2026-11-02"),
    [os.path.join(XSH, "process-replay", "snapshot") + " in t1"])
is_("old_home_no_root: ~/Code/.replay/snapshot, where the snapshot used to live, is no root", forbid("ls ~/Code/.replay/snapshot"), [])
is_("beneath_cwd: from the state home it names review-work, the snapshot home, xreview and cxh",
    sorted(K.beneath(XSH, fwall)), sorted(os.path.join(XSH, x) for x in ("review-work", "process-replay/snapshot", "xreview", "cxh")))
is_("beneath_cwd: from a fresh empty directory it names nothing", K.beneath(tempfile.mkdtemp(dir=ROOT), fwall), [])
is_("beneath_cwd: a root at the working directory counts", K.beneath(FSTATE, fwall), [FSTATE])
is_("beneath_cwd: from the home directory it names the checkout, ~/.codex and ~/.claude",
    sorted(K.beneath(house, fwall)), sorted([house + "/Code/Org/repo", house + "/.codex", house + "/.claude"]))
is_("beneath_cwd: a directory inside a root names nothing (the root is above it, not beneath)", K.beneath(os.path.join(FSTATE, "x"), fwall), [])
is_("beneath_cwd: an unresolvable cwd names every root", K.beneath("x\0y", fwall), [r.label for r in fwall.roots])

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
for label, cmd in (("a spaced number before a redirection is an option's value, not an fd (rg -C 2 >)", "rg -C 2 >/tmp/o foo ~/.codex/memories"),
                   ("... (grep -m 1 >)", "grep -rn -m 1 >/tmp/o foo ~/.codex/memories"),
                   ("... beside a glued fd redirection", "rg -C 2 2>/dev/null foo ~/.codex/memories")):
    is_("redirections: {} (N-1)".format(label), forbid(cmd), [CX + " in t1"])
is_("redirections: a glued fd redirection from its own scratch is clean", forbid("rg -n x 2>/dev/null; grep -rn -m 1 x 2>&1"), [])
for label, cmd in (("a $( ) inside a grep pattern", 'rg -n "$(head -1 ~/.codex/memories/MEMORY.md)" src'),
                   ("a backtick inside a grep pattern", 'rg -n "`head -1 ~/.codex/memories/MEMORY.md`" src')):
    is_("substitutions: {} still runs (M-2)".format(label), forbid(cmd), [CX + " in t1"])
for label, cmd, want in (("a cd to a computed directory does not go to $HOME", "cd $(git rev-parse --show-toplevel) && rg -n foo", []),
                         ("... nor with backticks", "cd `git rev-parse --show-toplevel` && rg -n foo", []),
                         ("$PWD is the tracked directory", 'rg foo "$PWD"; rg foo ${PWD}/src', []),
                         ("$(pwd) is the tracked directory", 'rg foo "$(pwd)"; cat `pwd`/src/a.py', [])):
    is_("cwd: {} (M-3)".format(label), forbid(cmd), want)
ABOVE = sorted("{} in t1".format(x) for x in (house + "/Code/Org/repo", CX, CL))
is_("cwd: a cd - after a cd above a root keeps that directory too, so the search walks it", forbid("cd ~ && cd - && rg foo"), ABOVE)
is_("cwd: ... and a second cd - as well", forbid("cd ~ && cd - && cd - && rg foo"), ABOVE)
is_("cwd: $PWD after a cd above a root is that directory", forbid('cd ~ && rg foo "$PWD"'), ABOVE)
is_("cwd: ... and so is $(pwd)", forbid('cd ~ && rg foo "$(pwd)"'), ABOVE)
is_("cwd: a subshell's cd and a cd - keep every directory (N-2)", forbid("cd ~ && cd /usr && (cd /var) && cd - && rg x"), ABOVE)
# ---- the cd tracker is monotone within a call, as an assignment is (spec 14.3 c): a cd adds every directory it may lead to, wherever it stands,
# nothing removes one, and every command after it is judged from all of them, the starting directory included
for cmd in ("false && cd /usr; cat .codex/x", "cd /usr || true; cat .codex/x", "if true; then cd /usr; fi; cat .codex/x",
            "(cd /usr); cat .codex/x", "cd /usr || cat .codex/x", "true && cd /usr || cat .codex/x", "true || cd /usr\ncat .codex/x", "true && (cd /usr); cat .codex/x",
            "if true; then cd /usr; else cat .codex/x; fi", "if false; then true; elif true; then cd /usr; else cat .codex/x; fi", "case x in a) cd /usr;; b) cat .codex/x;; esac",
            "for d in a; do cd /usr; done; cat .codex/x", "while false; do cd /usr; done; cat .codex/x", "until true; do cd /usr; done; cat .codex/x",
            "if true; then if true; then cd /usr; fi; fi; cat .codex/x", "true && cd /usr && cd /var; cat .codex/x", "echo $(true && cd /usr; cat .codex/x)",
            "sh -c 'false && cd /usr; cat .codex/x'",
            "cd /nonexistent; cat .codex/x", "cd /usr; cat .codex/x", "cd /usr\ncat .codex/x", "cd /usr | cat .codex/x", "(cd /usr; cat .codex/x)",
            "if true; then cd /usr; cat .codex/x; fi", "cd /usr && cd /var; cat .codex/x", "cd /usr; cd /var; cat .codex/x",
            "cd /nonexistent && true; cat .codex/x", "cd /usr && git log; cat .codex/x", "cd /usr && cat a\ncat .codex/x"):
    is_("cd_monotone: {!r} still reads from the starting directory (I1)".format(cmd), forbid(cmd, cwd=house), [CX + " in t1"])
# ---- what && joins to a cd runs only if the cd succeeded: it is judged from where the cd leads alone (the ruling on round 2's concern 1)
for cmd in ("cd /usr && cat .codex/x", "cd /tmp && cat .codex/x", "true && cd /usr && cat .codex/x", "(cd /usr && cat .codex/x)", "cd /usr && cd /var && cat .codex/x",
            "for d in a; do cd /usr && cat .codex/x; done", "case x in a) cd /usr && cat .codex/x;; esac", "cd /usr && cat .codex/x || true",
            "cd /usr && cat a && cat .codex/x", "cd /usr && cat a | cat .codex/x", "if cd /usr && cat .codex/x; then :; fi", "{ cd /usr && cat .codex/x; }",
            "true | true && cd /usr && cat .codex/x", "false || true && cd /usr && cat .codex/x", "builtin cd /usr && cat .codex/x", "command cd /usr && cat .codex/x",
            "D=1 cd /usr && cat .codex/x", "cd -P /usr && cat .codex/x", "cd -- /usr && cat .codex/x", "cd /usr 2>/dev/null && cat .codex/x",
            ">/dev/null cd /usr && cat .codex/x", "cd /usr && cat \"$PWD/.codex/x\"", "cd /usr && echo $(cat .codex/x)", "cd /usr && sh -c 'cat .codex/x'"):
    is_("cd_and: {!r} from ~ is judged from where the cd leads alone".format(cmd), forbid(cmd, cwd=house), [])
is_("cd_and: ... and a recursive search joined to it walks only there", forbid("cd /usr && ls -R .", cwd=house), [])
is_("cd_and: cd src && cat ../README.md from a scratch's root reads the scratch's own README", forbid("cd src && cat ../README.md"), [])
is_("cd_and: a cd joined to it by && narrows again from there", forbid("cd ~/Code && cd Org && cat repo/x", cwd=OWN), [house + "/Code/Org/repo in t1"])
is_("cd_and: what follows ; after the chain may start where the first cd failed, so ../ from the scratch's root lands in review-work",
    forbid("cd src && cat a.py; cd ../tests && cat b.py"), [os.path.join(XSH, "review-work") + " in t1"])
is_("cd_and: cd ~ && false || cat .codex/sessions/x from the scratch names ~/.codex (the || branch sees every directory)",
    forbid("cd ~ && false || cat .codex/sessions/x"), [CX + " in t1"])
for cmd in ("cd /usr && false || cat .codex/x", "cd /usr && cat a & cat .codex/x", "cd /usr && cat a\ncat .codex/x", "cd /usr && cat a;; cat .codex/x",
            "cd /usr && cat a || cd /var && cat .codex/x"):
    is_("cd_and: {!r} from ~ ends the chain, so what follows sees every directory".format(cmd), forbid(cmd, cwd=house), [CX + " in t1"])
for cmd in ("! cd /usr && cat .codex/x", "env cd /usr && cat .codex/x", "sudo cd /usr && cat .codex/x", "nohup cd /usr && cat .codex/x", "time cd /usr && cat .codex/x",
            "timeout 5 cd /usr && cat .codex/x", "command -p cd /usr && cat .codex/x", "cd() { :; }; cd /usr && cat .codex/x",
            "function cd { :; }; cd /usr && cat .codex/x", "true | cd /usr && cat .codex/x", "true || cd /usr && cat .codex/x",
            "cd /usr x && cat .codex/x", "pushd -n /usr && cat .codex/x", 'cd "$D" && cat .codex/x', 'cd "$(echo /usr)" && cat .codex/x',
            "cd `echo /usr` && cat .codex/x", "(cd /usr) && cat .codex/x", "(cd /usr && true) && cat .codex/x", "{ cd /usr; true; } && cat .codex/x",
            "f() { cd ~; }; cd /usr && f && cat .codex/x", "function f { cd ~; }; cd /usr && f && cat .codex/x", "cd /usr && source x.sh && cat .codex/x",
            "cd /usr && . ./x && cat .codex/x", 'cd /usr && eval "$X" && cat .codex/x', "cd /tmp && cd - && cat .codex/x", "pushd /tmp && popd && cat .codex/x",
            "pushd /tmp && pushd && cat .codex/x", "pushd /tmp && pushd +1 && cat .codex/x", "cd /tmp && cd -1 && cat .codex/x",
            'cd /tmp && cd "$D" && cat .codex/x', "cd /tmp && cd $(x) && cat .codex/x", "cd /tmp && cd a b && cat .codex/x",
            "cd() { builtin cd \"$@\"; }; builtin cd /tmp && cd ~ && cat .codex/x"):
    is_("cd_and: {!r} from ~ may run where it started, so it is judged from there too".format(cmd), forbid(cmd, cwd=house), [CX + " in t1"])
for cmd in ("cd /usr && true | cd ~ && cat .codex/sessions/x", "cd /usr && { cd ~; } && cat .codex/sessions/x", "cd /usr && x=$(cd ~) && cat .codex/sessions/x",
            "cd /usr && if true; then cd ~; fi && cat .codex/sessions/x"):
    is_("cd_and: {!r} keeps a cd made inside the chain for what follows in it".format(cmd), forbid(cmd), [CX + " in t1"])
# ---- round 3: stack entries and ~- in any cd (Codex P2, cold I2), loop conditions on a narrowed view (I1), eval and run-time command words (I2)
RW = os.path.join(XSH, "review-work") + " in t1"
is_("stack_entry: pushd /usr && cd +1 && cat ../other000/answer.json goes back to the scratch in zsh, beside another scratch (Codex P2)",
    forbid("pushd /usr && cd +1 && cat ../other000/answer.json"), [RW])
for cmd in ("cd /usr && cd +1 && cat .codex/x", "cd /usr && cd -1 && cat .codex/x", "cd /usr && cd ~+1 && cat .codex/x", "cd /usr && cd ~-1 && cat .codex/x",
            "cd /usr && cd ~- && cat .codex/x", "cd /usr && cd ~-/ && cat .codex/x", "cd /usr && cd $OLDPWD && cat .codex/x"):
    is_("stack_entry: {!r} from ~ may go back there".format(cmd), forbid(cmd, cwd=house), [CX + " in t1"])
is_("stack_entry: ... and bash's cd +1 is a directory named +1, which it adds", forbid("cd +1; cat ../../.codex/x", cwd=house + "/w"), [CX + " in t1"])
is_("stack_entry: cd ~; cd /usr; cd ~- && cat .codex/sessions/x from the scratch reads ~/.codex (cold I2)", forbid("cd ~; cd /usr; cd ~- && cat .codex/sessions/x"),
    [CX + " in t1"])
is_("tilde_pwd: ~- in a path is any directory the tracker holds", forbid("cd ~ && cd /usr && cat ~-/.codex/sessions/x"), [CX + " in t1"])
is_("tilde_pwd: ~+ is $PWD, in a path and in a cd that narrows", (forbid("cat ~+/.codex/x", cwd=house), forbid("cd ~/Code && cd ~+/Org && cat repo/x"),
    forbid("cd /usr && cd ~+/lib && cat .codex/x", cwd=house)), ([CX + " in t1"], [house + "/Code/Org/repo in t1"], []))
for cmd in ("cd /usr && while cat .codex/x; do cd ~; done", "cd /usr && until ! cat .codex/x; do cd ~; done", "cd /usr && while cat .codex/x; do cd -; done",
            "cd /usr && for f in a; do cat .codex/x; cd ~; done", "f() { cd ~; }; cd /usr && while cat .codex/x; do f; done"):
    is_("loop_narrowed: {!r} from ~ runs its condition again where the body went (cold I1)".format(cmd), forbid(cmd, cwd=house), [CX + " in t1"])
is_("loop_narrowed: ... while a loop that never moves stays where the chain led", forbid("cd /usr && while cat .codex/x; do true; done", cwd=house), [])
for cmd in ("cd /usr && $(echo cd) && cat .codex/x", "cd /usr && `echo cd` && cat .codex/x", "C=cd; cd /usr && $C && cat .codex/x",
            "cd /usr && ${X:-cd} && cat .codex/x", 'cd /usr && "$C" && cat .codex/x'):
    is_("runtime_command: {!r} from ~ may be a cd back there (cold I2)".format(cmd), forbid(cmd, cwd=house), [CX + " in t1"])
for cmd in ('eval "cd ~" && cat .codex/sessions/x', "eval cd ~; cat .codex/sessions/x", "cd /usr && eval cd ~ && cat .codex/sessions/x",
            "eval 'D=~/.codex'; cat $D/sessions/x", "eval 'cd ~'; ls -R ."):
    ok("eval_script: {!r} runs its arguments in this shell (cold I2)".format(cmd), CX + " in t1" in forbid(cmd), forbid(cmd))
is_("eval_script: ... and they are still words, so a pattern in them still counts (the docstring's limit)", forbid("eval 'rg ~/.codex/x src'"), [CX + " in t1"])
is_("cd_monotone_cost: for d in a b; do cd $d && ls; cd ..; done from a scratch's root names review-work (M4, accepted: the second pass starts at ..)",
    forbid("for d in a b; do cd $d && ls; cd ..; done"), [RW])
# ---- round 4: a loop's baseline is taken before its condition runs (Codex P2), and a cd holds where the system resolves it too (Codex P2)
SECRET_A = K.wall([], ["/a/secret"])
for cmd in ("while cd ..; do cat secret; done", "until ! cd ..; do cat secret; done", "while cd .. && true; do cat secret; done",
            "while true; cd ..; do cat secret; done", "for d in $(cd ..; cd ..; pwd); do cat secret; done"):
    is_("loop_baseline: {!r} from /a/b/c reads /a/secret on a later iteration".format(cmd), forbid(cmd, cwd="/a/b/c", wall=SECRET_A), ["/a/secret in t1"])
for cmd in ("while cd ..; do :; done", "while true; do cat secret; done"):
    is_("loop_baseline: ... while {!r} reads no secret".format(cmd), forbid(cmd, cwd="/a/b/c", wall=SECRET_A), [])
for cmd in ("cd /usr && while eval 'cat .codex/x'; do cd ~; done", "cd /usr && while $CHK .codex/x; do cd ~; done", "cd /usr && while source .codex/x; do cd ~; done"):
    is_("loop_baseline: {!r} from ~ is a loop that opened narrowed, though its widening condition ran first (cold check of ba1ec51)".format(cmd),
        forbid(cmd, cwd=house), [CX + " in t1"])
SIDE = house + "/Code/Org/side"
os.makedirs(SIDE, exist_ok=True)
os.symlink(SIDE, os.path.join(OWN, "side"))
for cmd in ("cd -P side/.. && cat repo/answers", "cd side/.. && cat repo/answers", "cd -P side/.. ; cat repo/answers", "cd side && cd .. && cat repo/answers"):
    is_("cd_physical: {!r} from the scratch, side a link beside the original, may read the original (Codex P2)".format(cmd), forbid(cmd),
        [house + "/Code/Org/repo in t1"])
if os.path.realpath("/var") == "/private/var":
    is_("cd_physical: cd -P /var/.. && cat secret/answer.json reads /private/secret (macOS: /var is a link)",
        forbid("cd -P /var/.. && cat secret/answer.json", wall=K.wall([], ["/private/secret"])), ["/private/secret in t1"])
probe = K._Scan(K.wall([], ["/nothing"]), K._values())
probe.script("cd src && cd lib; cd ..; cd ../tests", [OWN])
S0 = os.path.dirname(OWN)
is_("cd_physical: a tree with no link before .. adds no second form (and stays within MAX_CWDS)", (probe.union, sorted(probe.found)),
    ([OWN, OWN + "/src", OWN + "/src/lib", S0, S0 + "/tests", OWN + "/tests", OWN + "/src/tests", os.path.dirname(S0) + "/tests"], []))
probe = K._Scan(K.wall([], ["/nothing"]), K._values())
probe.script("cd -P /var/..", [OWN])
if os.path.realpath("/var") == "/private/var":
    is_("cd_physical: ... and cd /var/.. holds / and /private", probe.union, [OWN, "/", "/private"])
is_("cd_monotone_cost: a subshell's cd outlives it", forbid("(cd ~/Code/Org) && cat repo/x"), [house + "/Code/Org/repo in t1"])
is_("cd_monotone: a recursive search after a cd that may not run walks the starting directory", forbid("test -d /usr && cd /usr; ls -R .", cwd=house), ABOVE)
is_("cd_monotone: cds that stay inside the scratch leave its own directories all it can be in", forbid("cd src; cat a.py; cd nosuch; cat b.py"), [])
is_("cd_monotone: a cd that may not run still adds the new directory (what it reaches from there is judged)", forbid("false && cd ~/.codex; cat x", cwd=OWN), [CX + " in t1"])
for cmd in ("if cd ~ && false; then :; else cat .codex/sessions/x; fi", "if cd ~; false; then :; else cat .codex/sessions/x; fi",
            "if cd ~; then if false; then :; else cat .codex/sessions/x; fi; fi", "if false; then :; elif cd ~ && false; then :; else cat .codex/sessions/x; fi",
            "while true; do if cd ~ && false; then :; else cat .codex/sessions/x; fi; done", "for d in a; do if cd ~; then if false; then :; else cat .codex/sessions/x; fi; fi; done",
            "if true; then cd ~ && { if false; then :; else cat .codex/sessions/x; fi; }; fi", "if true; then cd ~ && time if false; then :; else cat .codex/sessions/x; fi; fi",
            "case y in y) cd ~ && { case x in z) :;; *) cat .codex/sessions/x;; esac; };; esac", "case y in y) cd ~ && ! case x in z) :;; *) cat .codex/sessions/x;; esac;; esac",
            "if cd ~ && false\nthen :\nelse cat .codex/sessions/x\nfi"):
    is_("cd_monotone: {!r} is judged from where the cd before its else or ;; led (C1)".format(cmd), forbid(cmd), [CX + " in t1"])
for cmd in ("pushd ~ && pushd /usr && popd && cat .codex/sessions/x", "cd ~ && popd; cat .codex/sessions/x", "cd ~ && cd -; cat .codex/sessions/x",
            "pushd ~ && popd && cat .codex/sessions/x", "pushd ~ && pushd +1 && cat .codex/sessions/x", "cd -P ~ && cat .codex/sessions/x", "cd -- ~ && cat .codex/sessions/x",
            "builtin cd ~ && cat .codex/sessions/x", "command cd ~ && cat .codex/sessions/x", "f() { cd ~; }; f; cat .codex/sessions/x",
            "echo $(cd ~) && cat .codex/sessions/x", "echo $(cd ~; (true)) && cat .codex/sessions/x", "sh -c 'cd ~' && cat .codex/sessions/x",
            "x=`cd ~; pwd`; cat .codex/sessions/x"):
    is_("cd_monotone: {!r} keeps ~ for what follows (M1)".format(cmd), forbid(cmd), [CX + " in t1"])
is_("cd_monotone: a case pattern's ) closes no subshell (M3)", forbid("(cd ~ && case x in a) cat .codex/sessions/x;; esac)"), [CX + " in t1"])
for cmd in ("cd - && rg foo", "cd -- - && rg foo", "cd -P - && rg foo", "cd -1 && rg foo", "popd && rg foo", "popd +1 && rg foo", "pushd +1 && rg foo", "pushd -0 && rg foo"):
    is_("cd_monotone: {!r} goes back to a directory the tracker holds, so it searches only its own scratch".format(cmd), forbid(cmd), [])
    is_("cd_monotone: ... and is no directory of that name either ({!r})".format(cmd), forbid(cmd.replace("rg foo", "cat ../../.codex/x"), cwd=house + "/w"), [])
is_("cd_monotone: pushd with no operand is a cd ~ (zsh's, with one directory on the stack), as a bare cd is", (forbid("pushd && rg foo"), forbid("cd && rg foo")), (ABOVE, ABOVE))
# ---- a loop is scanned twice when its pass added a directory or a value, so a read before the cd or assignment is judged as the next iteration makes it (M2, R11)
for cmd in ("for i in 1 2; do cat .codex/sessions/x; cd ~; done", "while cat .codex/sessions/x; do cd ~; done", "until cat .codex/sessions/x; do cd ~; done",
            "select x in a; do cat .codex/sessions/x; cd ~; done", "for i in 1 2\ndo\n  cat .codex/sessions/x\n  cd ~\ndone",
            "for i in 1 2; do cat $D/sessions/x; D=~/.codex; done", "for i in 1 2; do for j in 1 2; do cat .codex/sessions/x; done; cd ~; done",
            "if true; then for i in 1 2; do cat .codex/sessions/x; cd ~; done; fi", "for i in 1 2; do { cat .codex/sessions/x; cd ~; }; done",
            "for i in 1 2; do (cat .codex/sessions/x); cd ~ || break; done", "true | while read x; do cat .codex/sessions/x; cd ~; done",
            "echo $(for i in 1 2; do cat .codex/sessions/x; cd ~; done)"):
    is_("loop_twice: {!r} reads from where the loop's earlier iteration went".format(cmd), forbid(cmd), [CX + " in t1"])
is_("loop_twice: a third iteration is not followed (a limit the docstring names)", forbid("for i in 1 2 3; do cat .codex/x; cd ..; done", cwd=house + "/w/x"), [])
is_("loop_twice: ... while what follows the loop is judged from every directory it reached", forbid("for i in 1 2 3; do cd ..; done; cat .codex/x", cwd=house + "/w/x"), [CX + " in t1"])
is_("loop_twice: a loop that adds nothing is not scanned again, and its reads stay where they are", forbid("for i in 1 2; do cat .codex/sessions/x; done"), [])
start = time.time()
for cmd in ("done; done; cat x", "for i in a; do cat x", "for i in a; do " * 40 + "cd ..; " + "done; " * 40, "while true; do cd ~; done; " * 60,
            "for i in a; do HOME=~/x; done; " * 20):
    ok("loop_twice: {!r} ends".format(cmd[:40]), isinstance(forbid(cmd), list))
ok("loop_twice: ... and quickly", time.time() - start < 30, time.time() - start)
many = "; ".join("cd /d{}".format(n) for n in range(K.MAX_CWDS)) + "; cat x"
got = forbid(many, cwd=house)
ok("cd_monotone: more directories than MAX_CWDS is the TOO_MANY leak, not a silent cut", got and all("more values than the scan expands" in x for x in got), got)
is_("cd_monotone: MAX_CWDS directories are followed, none lost", forbid("; ".join("cd /d{}".format(n) for n in range(K.MAX_CWDS - 2)) + "; cd ~; cat .codex/x", cwd=OWN),
    [CX + " in t1"])
for cmd in ("cd src && rg x; cd ../tests && rg y; cd .. && git status", "cd /tmp && ls; cd /usr && ls; cd /var && ls; cd ~/Code && ls",
            "cd a; cd b; cd c; ls"):
    ok("cd_monotone: an ordinary multi-cd call ({!r}) stays within MAX_CWDS".format(cmd), not any("more values" in x for x in forbid(cmd)), forbid(cmd))
# ---- redirections stand anywhere among a simple command's words: the assignments and the command are read without them, their targets as paths (P2)
SECRET = K.wall([], ["/secret"])
for cmd in ("< /dev/null D=/; cat ${D}secret/x", "2>/dev/null D=/; cat ${D}secret/x", "E=/ <f D=/; cat ${D}secret/x", ">f D=/ 2>&1; cat ${D}secret/x",
            "&>f D=/; cat ${D}secret/x", "<<< x D=/; cat ${D}secret/x", "< /dev/null export D=/; cat ${D}secret/x", "2>/dev/null declare -x D=/; cat ${D}secret/x",
            "< /dev/null D=/ sh -c 'cat ${D}secret/x'"):
    is_("redirect_first: {!r} gives D its value (P2)".format(cmd), forbid(cmd, cwd="/safe", wall=SECRET), ["/secret in t1"])
for cmd in (">/dev/null cd ~; cat .codex/sessions/x", "2>/dev/null builtin cd ~ && cat .codex/sessions/x", "< /dev/null command cd ~ && cat .codex/sessions/x",
            "2>&1 bash -c 'cd ~ && cat .codex/sessions/x'", "</dev/null sudo sh -c 'cd ~; cat .codex/sessions/x'"):
    is_("redirect_first: {!r} is the cd or shell it runs".format(cmd), forbid(cmd), [CX + " in t1"])
for cmd in (">/dev/null command rg foo", "2>/dev/null env rg foo", "< /dev/null exec rg foo", "2>/dev/null time rg foo", ">/dev/null nohup grep -rn foo",
            "2>/dev/null timeout 5 rg foo", ">/dev/null xargs rg foo"):
    is_("redirect_first: {!r} from ~ walks it".format(cmd), forbid(cmd, cwd=house), ABOVE)
is_("redirect_first: a redirection's target is still read", (forbid("< ~/.codex/x D=/; true"), forbid(">~/.codex/x env true")), ([CX + " in t1"],) * 2)
for cmd in ("2>/dev/null rg -n ~/.codex/memories src", "2>/dev/null env rg -n ~/.codex/memories src", "> f command grep -e ~/.codex/memories src",
            "< f sudo git log -S ~/.codex/memories"):
    is_("redirect_first: {!r} still has a pattern, not a path, behind its redirection and wrapper".format(cmd), forbid(cmd), [])
is_("cd_monotone: each command of a call is a shell of its own, and the call's other fields start at its workdir",
    sorted(K.named(fwall, OWN, ["cd ~", "cat .codex/x"], [".codex/y"], [".codex/z"], searches=["."])), [])
is_("cd_monotone: after --, cd -x goes to the directory -x", forbid("cd -- -x && cat ../.codex/y", cwd=house), [CX + " in t1"])
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
out = w.peek(home, state=STATE2, max_tokens=1000)
ok("token_stop: caller 100 + another run's 500 is below 1000: the run's own file (99999) is not counted", out.get("kind") == "codex", out)
w.run["reviews"], w.run["thread"] = [], None
out = w.peek(home, state=STATE2, max_tokens=600)
ok("token_stop: ... and 100 + 500 does stop at 600", set(out) == {"stopped"}, out)

# ---- isolation: in-process calls read fixtures, never the account's own ~/.codex
import pwd  # noqa: E402
real_home = os.path.realpath(pwd.getpwuid(os.getuid()).pw_dir)
fixture_home = os.path.realpath(os.path.expanduser("~"))
ok("isolation: ~ is a fixture, not the account's home, and CODEX_HOME is not the account's ~/.codex",
   fixture_home != real_home and os.path.realpath(os.environ["CODEX_HOME"]) != os.path.join(real_home, ".codex")
   and fixture_home.startswith(os.path.realpath(ROOT).rsplit("/", 1)[0]), (fixture_home, os.environ["CODEX_HOME"]))
iso_empty = os.path.join(ROOT, "cxh", "iso-empty")
os.makedirs(iso_empty, exist_ok=True)
HOT_ISO = {"primary": {"used_percent": 85, "window_minutes": 10080, "resets_at": FUTURE}}
live_env = os.environ["CODEX_HOME"]
is_("isolation: with fixtures only, in-process weekly() and weekly_hold() find nothing", (K.weekly(iso_empty), K.weekly_hold(iso_empty)), (None, None))
hot = helpers.write_rollout(live_env, "iso-hot-env", [{"turn": "h1", "answer": None, "rate_limits": HOT_ISO}])
ok("isolation: a fixture live home (CODEX_HOME) at 85% makes weekly_hold hold", (K.weekly_hold(iso_empty) or {}).get("resets_at") == FUTURE, K.weekly_hold(iso_empty))
os.unlink(hot)
del os.environ["CODEX_HOME"]
try:
    is_("isolation: without CODEX_HOME the live home is the fixture's ~/.codex, which is empty", K.weekly_hold(iso_empty), None)
    hot = helpers.write_rollout(os.path.join(fixture_home, ".codex"), "iso-hot-home", [{"turn": "h1", "answer": None, "rate_limits": HOT_ISO}])
    ok("isolation: ... and a rollout there at 85% makes it hold (so ~/.codex is read through the fixture HOME)", (K.weekly_hold(iso_empty) or {}).get("resets_at") == FUTURE, K.weekly_hold(iso_empty))
    os.unlink(hot)
finally:
    os.environ["CODEX_HOME"] = live_env

# ---- mid_round: a limit crossed by one packet's turn stops the round before the next packet's
def turns_started(stub):
    return len([e for e in log(stub) if e["cmd"] == "turn-start"])


HOT = {"primary": {"used_percent": 85, "window_minutes": 10080, "resets_at": FUTURE}}
SLICE = {"answer": ans("approve", ()), "tokens": 1000, "window": 110000}      # the window of the home's newest rollout decides the packets
w = World("midpause", big=True)
home = replay_home("midpause", window=110000)
stub = stub_for("midpause", home, {"turns": [dict(SLICE, rate_limits=HOT)], "default": SLICE})
out = w.round(home)
n_packets = len(XR.jload(os.path.join(STATE, "runs", "cmidpause", "lab1", "codex-1", "decision.json"))["packets"])
ok("mid_round: the decision has several packets (the test means something)", n_packets >= 2, n_packets)
ok("mid_round: a pause that appears after packet 1 stops the round, naming the reset", "paused" in out and out["resets_at"] == FUTURE and str(FUTURE) in out["paused"], out)
is_("mid_round: ... no packet after it started (one turn, one thread)", (turns_started(stub), sum(1 for e in log(stub) if e["cmd"] == "thread-start")), (1, 1))
is_("mid_round: ... the turn that ran is charged", out.get("tokens"), 1000)
ok("mid_round: ... and the round is no review: the run has none", w.run["reviews"] == [] and "kind" not in out, (w.run["reviews"], out))
stub = stub_for("midpause2", replay_home("midpause2", window=110000), {"default": SLICE})
redo = w.round(replay_home("midpause2", window=110000))
is_("mid_round: after the reset the whole round is redone, from packet 1", (redo.get("kind"), redo.get("k"), len(redo["turns"])), ("codex", 1, n_packets))

w = World("midstop", big=True)
home = replay_home("midstop", window=110000)
stub = stub_for("midstop", home, {"default": SLICE})
STATE_MID = os.path.join(ROOT, "state-mid")        # no other run's tokens
out = w.round(home, max_tokens=1000, state=STATE_MID)
ok("mid_round: the round's own tokens count against the token stop: packet 1 reaches 1000, packet 2 does not start",
   "stopped" in out and "paused" not in out and out.get("tokens") == 1000 and turns_started(stub) == 1 and "1000 tokens spent" in out["stopped"], (out, turns_started(stub)))
ok("mid_round: ... the round is no review", w.run["reviews"] == [], w.run["reviews"])
w.run["tokens"] += out["tokens"]
out = w.round(home, max_tokens=1000, state=STATE_MID)
ok("mid_round: charged to the run, the stop holds before any turn of the next attempt", set(out) == {"stopped"} and turns_started(stub) == 1, (out, turns_started(stub)))
w.run["tokens"] = 0
redo = w.round(home, max_tokens=10 ** 9, state=STATE_MID)
is_("mid_round: with the stop raised the round is redone whole", (redo.get("kind"), redo.get("k"), len(redo["turns"])), ("codex", 1, n_packets))
w = World("midnone", big=True)
home = replay_home("midnone", window=110000)
stub = stub_for("midnone", home, {"default": SLICE})
out = w.round(home, max_tokens=n_packets * 1000 + 1, state=STATE_MID)
ok("mid_round: below the stop every packet runs", out.get("kind") == "codex" and len(out["turns"]) == n_packets, out)

# a limit crossed by the last packet changes nothing: the round is complete, and its review is kept
w = World("midlast", big=True)
home = replay_home("midlast", window=110000)
stub = stub_for("midlast", home, {"turns": [SLICE] * (n_packets - 1) + [dict(SLICE, rate_limits=HOT)], "default": SLICE})
out = w.round(home)
ok("mid_round: a limit crossed by the last packet is a finished round", out.get("kind") == "codex" and len(out["turns"]) == n_packets, out)

# a partial round is still leak-scanned: a leak voids it, as ever
w = World("midleak", big=True)
home = replay_home("midleak", window=110000)
stub = stub_for("midleak", home, {"turns": [dict(SLICE, rate_limits=HOT, tools=[tool("custom_tool_call", "cat {}/src/a.py".format(w.workdir))])], "default": SLICE})
out = w.round(home)
ok("mid_round: the turns that ran are leak-scanned; a leak voids the round even though it stopped", set(out) == {"leak", "tokens", "thread", "turns"} and out["tokens"] == 1000 and out["leak"]
   and turns_started(stub) == 1, out)

# ---- shared_tally: the token stop counts every job's completed turns, so a round starts no turn after another job's turn crossed it
STATE_SH = os.path.join(ROOT, "state-shared")
os.makedirs(STATE_SH)


class Tape(object):
    """Fake turns for two interleaved rounds: every turn completes with 1000 tokens; `during` runs while the first turn of the first round is
    in progress (after it started, before its tokens are known)."""

    def __init__(self):
        self.started, self.during, self.fired = [], None, False

    def one_turn(self, thread, packet_file, schema, cwd, budget, box):
        self.started.append(cwd)
        box["turn"] = "tu-%d" % len(self.started)
        if self.during and not self.fired:
            self.fired = True
            self.during()
        return {"verdict": "approve", "findings": [], "reviewed_files": []}, False


def interleave(a_name, b_name, max_tokens):
    """Round A's first turn is in progress while round B runs whole; then A's turn completes. Returns (A's outcome, B's outcome, the tape,
    the two worlds)."""
    wa, wb = World(a_name, big=True), World(b_name, big=True)
    ha = hb = replay_home(a_name, window=110000)            # one replay home: rounds on two homes cannot share a process
    tape, box = Tape(), {}
    counter = {"n": 0}

    def start(a, cwd):
        counter["n"] += 1
        return "th-%d" % counter["n"]
    saved = (XR.one_turn, XR.turn_usage, K._start, K.leaks)
    XR.one_turn, K._start, K.leaks = tape.one_turn, start, lambda *x, **y: []
    XR.turn_usage = lambda thread, turn: {"tokens": 1000, "model": "m", "effort": "high"}
    kw = {"state": STATE_SH, "max_tokens": max_tokens}
    try:
        tape.during = lambda: box.__setitem__("b", K.codex_round(args(**kw), wb.run, wb.case, wb.branch, hb))
        box["a"] = K.codex_round(args(**kw), wa.run, wa.case, wa.branch, ha)
    finally:
        XR.one_turn, XR.turn_usage, K._start, K.leaks = saved
    return box["a"], box["b"], tape, (wa, wb)


out_a, out_b, tape, (wa, wb) = interleave("shra", "shrb", 2500)
ok("shared_tally: job B's round, run while A's first turn was in progress, stopped at the line (3 turns of 1000, the 4th not started)",
   "stopped" in out_b and out_b.get("tokens") == 3000, out_b)
ok("shared_tally: job A's first turn completed after B's crossed the line: A starts no further packet and says what was spent",
   "stopped" in out_a and out_a.get("tokens") == 1000 and len(tape.started) == 4 and "4000 tokens spent" in out_a["stopped"], (out_a, len(tape.started)))
a_sh = args(state=STATE_SH, max_tokens=2500)
is_("shared_tally: both rounds' turns are counted once while they are uncharged", K.spent_now(a_sh, wa.run), 4000)
for w_, o_ in ((wa, out_a), (wb, out_b)):
    with K.settling(a_sh, w_.run):
        w_.run["tokens"] += o_["tokens"]
        XR.jsave(os.path.join(STATE_SH, "runs", w_.run["case"], w_.run["label"], "state.json"), w_.run)
is_("shared_tally: charged to their runs (and saved) the total is the same, not doubled", (K.spent_now(a_sh, wa.run), K.spent_now(a_sh, wb.run)), (4000, 4000))
is_("shared_tally: a settled round leaves nothing in flight", (K.in_flight(a_sh, wa.run), K.in_flight(a_sh, wb.run)), (0, 0))

out_a, out_b, tape, _ws = interleave("shrc", "shrd", 10 ** 9)
ok("shared_tally: below the stop both rounds run every packet", out_a.get("kind") == "codex" and out_b.get("kind") == "codex"
   and len(out_a["turns"]) == len(out_b["turns"]) and len(tape.started) == 2 * len(out_a["turns"]), (len(tape.started), out_a.get("kind"), out_b.get("kind")))

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
for cmd in ("2>/dev/null env chezmoi diff", "< /dev/null command chezmoi diff", ">/dev/null exec chezmoi diff", "2>&1 time chezmoi diff", "&>/dev/null nohup chezmoi diff",
            "</dev/null sudo chezmoi diff", "2>/dev/null A=1 env chezmoi diff", "<<< x builtin chezmoi diff", "2>/dev/null xargs chezmoi diff",
            "if >/dev/null chezmoi diff; then :; fi", "< /dev/null SRC=x chezmoi diff"):
    is_("redirect_first: {} runs chezmoi (a redirection before the command is no command word)".format(cmd), leaked(fc(cmd), CHZ), CHZN)
is_("redirect_first: ... and a lookup after one is still a lookup", (leaked(fc("2>/dev/null command -v chezmoi"), CHZ), leaked(fc(">/dev/null which chezmoi"), CHZ)), ([], []))
is_("redirect_first: a chezmoi call with a redirection among its flags reads its paths", (leaked(fc("chezmoi -S {0} 2>/dev/null -D {0}/h managed".format(SCR)), CHZ),
    leaked(fc("< /dev/null chezmoi -S {0} -D {0}/h managed".format(SCR)), CHZ)), ([], []))
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
is_("tool_words: a backtick inside a quoted string runs (N-3)", leaked(fc('echo "`chezmoi diff`"'), CHZ), CHZN)
is_("tool_words: a heredoc body is not run, but a path in it is read", leaked(fc("sh <<'EOF'\ncat ~/.local/share/chezmoi/AGENTS.md\nEOF"), CHZ), CHZN)

# ---- assignments: a literal assignment adds a value for later uses in the same call (spec 14.3 c)
for label, cmd in (("a bare assignment", "D=~/.local/share; cat $D/chezmoi/AGENTS.md"), ("export", "export D=~/.local/share; cat $D/chezmoi/AGENTS.md"),
                   ("a prefix assignment", "D=~/.local/share sh -c 'cat $D/chezmoi/x'"), ("env NAME=value", "env D=~/.local/share sh -c 'cat $D/chezmoi/x'"),
                   ("inside a substitution", "echo $(D=~/.local/share; cat $D/chezmoi/x)"),
                   ("a later command of the call", "D=~/.local/share; ls; cd /tmp && cat ${D}/chezmoi/x"),
                   ("a heredoc body, scanned last", "sh <<'EOF'\ncat $D/chezmoi/x\nEOF\nD=~/.local/share"),
                   ("a second assignment of the same name", "D=/a; D=~/.local/share; cat $D/chezmoi/x")):
    is_("assignment_within_call: {} gives the variable its value".format(label), leaked(fc(cmd), CHZ), CHZN)
is_("assignment_within_call: a value with $ is not literal and adds nothing", leaked(fc("D='$HOME/.local/share'; cat $D/chezmoi/x"), CHZ), [])
is_("assignment_within_call: a use before its assignment is not affected", leaked(fc("cat $D/chezmoi/x; D=~/.local/share"), CHZ), [])
is_("assignment_within_call: a known variable keeps its values and gains the literal",
    leaked(fc("HOME=/tmp; cat $HOME/.local/share/chezmoi/x"), CHZ), CHZN)
is_("assignment_within_call: ... a literal that is the dangerous one is found too", leaked(fc("HOME=~/.local; cat $HOME/share/chezmoi/x"), CHZ), CHZN)
is_("assignment_within_call: PWD gains the literal as well", leaked(fc("PWD=~/.local/share; cat $PWD/chezmoi/x"), CHZ), CHZN)
is_("assignment_within_call: a cd to an assigned variable is followed", leaked(fc("D=~/.local/share; cd $D && cat chezmoi/x"), CHZ), CHZN)

n_lk[0] += 1
rollout("lx{}".format(n_lk[0]), [{"turn": "t1", "answer": None, "tools": [tool("function_call", fc("D=~/.local/share")), tool("function_call", fc("cat $D/chezmoi/AGENTS.md"))]}])
is_("assignment_not_across_calls: an assignment in one call gives nothing to the next call of the turn",
    K.leaks(lhome, [("lx{}".format(n_lk[0]), "t1")], K.wall(list(CHZ)), SCR), [])

is_("assignment_never_hides: an assignment that may not run still leaves the real value", leaked(fc('false && HOME=/tmp; cat "$HOME/.codex/x"'), CHZ + [house + "/.codex"]),
    [house + "/.codex in t1"])
FW = lambda cmd: forbid(fc(cmd))
is_("assignment_never_hides: a subshell's assignment does not hide HOME", FW("(HOME=/tmp); cat $HOME/.codex/x"), [house + "/.codex in t1"])
is_("assignment_never_hides: ... nor XDG_STATE_HOME", FW("XDG_STATE_HOME=/tmp; cat $XDG_STATE_HOME/xreview/x"), [os.path.join(XSH, "xreview") + " in t1"])
is_("assignment_never_hides: ... nor a prefix assignment's", FW("HOME=/tmp sh -c 'cat $HOME/.codex/x'"), [house + "/.codex in t1"])
is_("assignment_never_hides: ... nor export", FW("export HOME=/tmp; cat $HOME/.codex/x"), [house + "/.codex in t1"])
is_("assignment_never_hides: the assigned literal is found too", FW("HOME=/tmp; D=~/.codex; cat $D/x"), [house + "/.codex in t1"])

is_("unknown_keeps_spelling: an unknown variable that gained a value keeps its spelling", (lambda r: (sorted(r[0]), r[1]))(K._expand("$D/x", {"D": [K.LITERAL, "/a"]})),
    (["$D/x", "/a/x"], True))
is_("unknown_keeps_spelling: ... in any position", sorted(K._expand("$D/$E", {"D": [K.LITERAL, "/a"], "E": [K.LITERAL, "b"]})[0]),
    sorted(["$D/$E", "$D/b", "/a/$E", "/a/b"]))
is_("unknown_keeps_spelling: _expand without a literal is as it was, and complete", K._expand("$HOME/x", {"HOME": ["/h"]}), (["/h/x"], True))
is_("unknown_keeps_spelling: ... and reports a use that exceeds the expansions", K._expand("$D/x", {"D": ["/a%d" % i for i in range(17)]})[1], False)

many = "; ".join("A=/a{}".format(i) for i in range(1, 18))
is_("too_many_values: a use with more values than the scan expands is a leak", leaked(fc(many + "; cat $A/x"), CHZ), ["$A/x (more values than the scan expands) in t1"])
is_("too_many_values: sixteen values are expanded, none is lost", leaked(fc("; ".join("A=/a{}".format(i) for i in range(1, 16)) + "; cat $A/x"), CHZ), [])
is_("too_many_values: a cd to more directories than the scan follows is a leak",
    leaked(fc("; ".join("D=/d{}".format(n) for n in range(K.MAX_CWDS)) + "; cd $D && ls"), CHZ), ["$D (more values than the scan expands) in t1"])

# ---- assignments, fix round 1
OWNWALL = CHZ + [house + "/.codex"]
for label, cmd in (("a backtick value", "T=`mktemp -d`; rg -n foo $T/"), ("a backtick value, searched by find", "T=`mktemp -d`; find $T/ -name x"),
                   ("a $( ) value", "T=$(mktemp -d); rg -n foo $T/"), ("a quoted $( ) value", 'T="$(mktemp -d)"; rg -n foo $T/'),
                   ("an exported backtick value", "export T=`mktemp -d`; rg -n foo $T/"), ("a local $( ) value", "local T=$(mktemp -d); rg -n foo $T/"),
                   ("a backtick glued after ~/", "T=~/`date +%F`; rg -n foo $T"), ("... searched by find", "T=~/`date +%F`; find $T -name x"),
                   ("a backtick glued after ./", "T=./`date +%F`; rg -n foo $T"), ("a $( ) glued after ~/", "T=~/$(date +%F); rg -n foo $T"),
                   ("a backtick inside double quotes", 'T="`mktemp -d`"; rg -n foo $T/'), ("a backtick glued inside double quotes", 'T="~/`date`"; rg -n foo $T'),
                   ("a prefix backtick value", "T=`mktemp -d` sh -c 'rg -n foo $T/'"), ("a backtick glued before text", "T=`date`/x; rg -n foo $T")):
    is_("backtick_value_adds_nothing: {} is not a literal and leaves the variable unknown".format(label), leaked(fc(cmd), OWNWALL, cwd=house), [])

for label, cmd in (("an assignment that runs", "D=/tmp; cat $D/../.codex/x"), ("one that may not run", "false && D=/tmp; cat $D/../.codex/x"),
                   ("export", "export D=/tmp; cat $D/../.codex/x"), ("a prefix assignment", "D=/tmp sh -c 'cat $D/../.codex/x'")):
    is_("assignment_keeps_spelling: {} does not hide the unknown variable's spelling".format(label), forbid(fc(cmd), cwd=house), [house + "/.codex in t1"])

CHZH = "HOME=~/.local/share"
for label, cmd in (("a ~/ path", CHZH + "; cat ~/chezmoi/x"), ("a bare cd, then a relative path", CHZH + "; cd; cat chezmoi/x"),
                   ("cd ~/path", CHZH + "; cd ~/chezmoi && ls"), ("export, a recursive search", "export " + CHZH + "; ls -R ~/chezmoi"),
                   ("a prefix assignment", CHZH + " sh -c 'cat ~/chezmoi/x'"), ("a $HOME path", CHZH + "; cat $HOME/chezmoi/x"),
                   ("a second assignment built on the first", CHZH + "; HOME=~/chezmoi; cat ~/x")):
    is_("tilde_sees_home: {}".format(label), leaked(fc(cmd), CHZ), CHZN)
is_("tilde_sees_home: ~ without an assignment is as before", (leaked(fc("cat ~/.local/share/chezmoi/x"), CHZ), leaked(fc("cat ~/other"), CHZ)), (CHZN, []))
is_("tilde_sees_home: _expand without HOME in its values takes the user's home", K._expand("~/x", {}), ([os.path.expanduser("~/x")], True))
is_("tilde_sees_home: ... with it, ~/x takes every value of $HOME", sorted(K._expand("~/x", {"HOME": ["/a", "/b"]})[0]), ["/a/x", "/b/x"])

for word in ("declare", "local", "typeset", "readonly", "export"):
    is_("assignment_builtins: {} NAME=value gives the variable its value".format(word),
        leaked(fc("{} D=~/.local/share; cat $D/chezmoi/x".format(word)), CHZ), CHZN)
is_("assignment_builtins: declare -x NAME=value too", leaked(fc("declare -x D=~/.local/share; cat $D/chezmoi/x"), CHZ), CHZN)

is_("backtick_value_adds_nothing: a glued backtick is glued in the logical line", K._logical("T=~/`date`; ls"), "T=~/$(date ) ; ls")
is_("backtick_value_adds_nothing: a spaced backtick keeps its space", K._logical("echo `pwd`"), "echo  $( pwd ) ")
empty = K._Scan(fwall, {})
empty.script("T= $(cmd)", [SCR])
is_("backtick_value_adds_nothing: an empty prefix assignment on a substitution's output gains the empty value (T= $(cmd))", empty.values, {"T": [K.LITERAL, ""]})
for label, cmd in (("a value built from an assigned HOME through a variable", "HOME=~/.local/share; D=~; cat $D/chezmoi/x"),
                   ("a ~/.. path after HOME was assigned twice", "HOME=~/.local/share; HOME=~/x; cat ~/../chezmoi/y")):
    is_("tilde_sees_home: {} (the assignment side)".format(label), leaked(fc(cmd), CHZ), CHZN)

# ---- glued substitutions keep their word and their command whole (fix round 3)
CXN, CHN = house + "/.codex in t1", house + "/.local/share/chezmoi in t1"
for cmd, want in (("cat ~/.codex%s", [CXN]), ("cat ~/.local/share/chezmoi%s", [CHN]), ("rg --max-count=%s foo ~/.local/share", [CHN]),
                  ("grep -rn --include=%s foo ~", [CXN, CHN]), ("ls -R --color=%s ~", [CXN, CHN]), ("tree -I=%s ~/.local/share", [CHN]),
                  ("cd ~/.local/share && cat chezmoi%s/x", [CHN]), ("env A=b%s rg foo ~", [CXN, CHN]), ("A=b%s rg foo ~", [CXN, CHN]),
                  ("echo a%s", [])):
    for form, sub in (("backtick", "`printf /x`"), ("$( )", "$(printf /x)")):
        is_("glued_substitution: {} with a {} glued to its word".format(cmd % "<sub>", form), leaked(fc(cmd % sub), OWNWALL, cwd="/work/s"), want)
is_("glued_substitution: the inner command of a glued substitution is scanned (backtick)", leaked(fc("echo a`cat ~/.codex/x`c"), OWNWALL, cwd="/work/s"), [CXN])
is_("glued_substitution: ... and of a glued $( ) nested in another", leaked(fc("echo a$(echo b$(cat ~/.codex/x))"), OWNWALL, cwd="/work/s"), [CXN])
is_("glued_substitution: a glued tool word still runs it (_runs)", (leaked(fc("chezmoi`true` diff"), CHZ), leaked(fc("echo a$(chezmoi diff)"), CHZ), leaked(fc("echo a`chezmoi diff`"), CHZ)), (CHZN,) * 3)
quoted = K._Scan(fwall, {})
quoted.script('T="`date`"', [SCR])
is_("backtick_value_adds_nothing: a backtick that stays inside double quotes adds no value", quoted.values, {})

# ---- fix round 4: past MAX_DEPTH the scan fails closed; an unquoted parenthesis is a token of its own
DEEP = " (nested deeper than the scan follows) in t1"
for label, cmd in (("five deep, glued", "echo a$(b$(c$(d$(e$(cat ~/.codex/x)))))"),
                   ("six deep, not glued", "echo $(echo $(echo $(echo $(echo $(echo $(cat ~/.codex/x))))))"),
                   ("five deep, a search only the innermost scan sees", "echo $(echo $(echo $(echo $(echo $(rg foo ~)))))"),
                   ("sh -c, then four deep", "sh -c 'echo $(echo $(echo $(echo $(rg foo ~))))'")):
    got = leaked(fc(cmd), OWNWALL, cwd="/work/s")
    ok("depth_fails_closed: {} is a leak ({})".format(label, cmd), any(x.endswith(DEEP) for x in got), got)
for label, cmd, want in (("four deep, glued", "echo a$(b$(c$(d$(cat ~/.codex/x))))", [CXN]),
                         ("four deep, not glued", "echo $(echo $(echo $(echo $(cat ~/.codex/x))))", [CXN]),
                         ("four deep, a search", "echo $(echo $(echo $(echo $(rg foo ~))))", [CXN, CHN])):
    is_("depth_fails_closed: {} resolves to its real hit only".format(label), leaked(fc(cmd), OWNWALL, cwd="/work/s"), want)

for glued, spaced, want in (("echo a$(b);rg foo ~", "echo a$(b) ; rg foo ~", [CXN, CHN]), ("echo a$(b)|rg foo ~", "echo a$(b) | rg foo ~", [CXN, CHN]),
                            ("echo a$(b)&&rg foo ~", "echo a$(b) && rg foo ~", [CXN, CHN]),
                            ("x=a$(b);cd ~/.local/share; cat chezmoi/x", "x=a$(b) ; cd ~/.local/share; cat chezmoi/x", [CHN]),
                            ("echo a$(b)|&rg foo ~", "echo a$(b) |& rg foo ~", [CXN, CHN]), ("echo a$(b)||rg foo ~", "echo a$(b) || rg foo ~", [CXN, CHN]),
                            ("echo a$(b$(c));rg foo ~", "echo a$(b$(c) ) ; rg foo ~", [CXN, CHN]),
                            ("cat ~/.codex/x $(echo $(b))", "cat ~/.codex/x $(echo $(b) )", [CXN]), ("(true)&&rg foo ~", "(true) && rg foo ~", [CXN, CHN])):
    is_("closing_paren: {} names what its spaced twin {} names".format(glued, spaced),
        (leaked(fc(glued), OWNWALL, cwd="/work/s"), leaked(fc(spaced), OWNWALL, cwd="/work/s")), (want, want))
is_("closing_paren: the command after a glued ); runs (_runs)", (leaked(fc("echo a$(b);chezmoi diff"), CHZ), leaked(fc("(true)&&chezmoi diff"), CHZ)), (CHZN, CHZN))
for cmd in ("true;(cd ~/.local/share; cat chezmoi/x)", "true|(cd ~/.local/share; cat chezmoi/x)", "true&&(cd ~/.local/share; cat chezmoi/x)",
            "diff <(cd ~/.local/share; cat chezmoi/x) y"):
    is_("opening_paren: {} names what `true ; (cd ...)` names".format(cmd), leaked(fc(cmd), OWNWALL, cwd="/work/s"), [CHN])
is_("opening_paren: a subshell glued to ; runs its command (_runs)", leaked(fc("true;(chezmoi diff)"), CHZ), CHZN)
for cmd in ('rg ");" ~', "grep -r ');' ~", 'rg "))" ~'):
    is_("closing_paren: a quoted {} stays a search pattern, not an operator".format(cmd), leaked(fc(cmd), OWNWALL, cwd="/work/s"), [CXN, CHN])
is_("closing_paren: an unquoted parenthesis is a token of its own", K._tokens(K._logical("echo a$(b)|&rg ~;(x))")),
    ["echo", "a$", "(", "b", ")", "|&", "rg", "~", ";", "(", "x", ")", ")"])
is_("closing_paren: ... a quoted one stays in its word", K._tokens(K._logical('rg ");" "(x" ~')), ["rg", ");", "(x", "~"])
for cmd, want in (('cat ~/.codex/x $(echo "(")', [CXN]), ("cat ~/.codex/x a$(b", [CXN]), ('rg foo ~ $(echo "(")', [CXN, CHN])):
    is_("unclosed_substitution: {} still scans the command around it".format(cmd), leaked(fc(cmd), OWNWALL, cwd="/work/s"), want)

# ---- fix round 5: a quoted or escaped operator is a word; a function body is read where it is defined; a TOO_DEEP label is short
twin = leaked(fc("rg x ~"), OWNWALL, cwd="/work/s")
is_("quoted_operator: the unquoted-pattern twin rg x ~ names both roots", twin, [CXN, CHN])
for sep in K.SEPARATORS:
    for form in ("rg '{}' ~", 'rg "{}" ~', "rg -F '{}' ~"):
        is_("quoted_operator: {} names what rg x ~ names".format(form.format(sep)), leaked(fc(form.format(sep)), OWNWALL, cwd="/work/s"), twin)
    is_("quoted_operator: a real cd after rg '{}' is followed".format(sep),
        leaked(fc("rg '{}' x && cd ~/.local/share && cat chezmoi/x".format(sep)), OWNWALL, cwd="/work/s"), [CHN])
for op in K.REDIRECTS:
    is_("quoted_operator: a quoted redirection rg '{}' ~ names what rg x ~ names".format(op), leaked(fc("rg '{}' ~".format(op)), OWNWALL, cwd="/work/s"), twin)
for op in "|;&()$<>":
    is_("quoted_operator: an escaped rg \\{} ~ names what rg x ~ names".format(op), leaked(fc("rg \\{} ~".format(op)), OWNWALL, cwd="/work/s"), twin)
is_("quoted_operator: two quoted halves of && are one word", leaked(fc('rg "&""&" ~'), OWNWALL, cwd="/work/s"), twin)
is_("quoted_operator: a # after an escaped | is no comment, so the next command is scanned", leaked(fc("echo \\|#x; rg foo ~"), OWNWALL, cwd="/work/s"), twin)
for label, cmd in (("&&", "echo x&&rg foo ~"), ("||", "echo x||rg foo ~"), (";", "echo x;rg foo ~"), ("|", "echo x|rg foo ~"), ("|&", "echo x|&rg foo ~"),
                   ("&", "echo x&rg foo ~"), ("( )", "(rg foo ~)"), ("$( )", "echo $(rg foo ~)"), (";;", "case x in a) rg foo ~;; esac"),
                   ("a redirection", "rg foo ~ >out 2>&1")):
    is_("quoted_operator: an unquoted {} still splits ({})".format(label, cmd), leaked(fc(cmd), OWNWALL, cwd="/work/s"), [CXN, CHN])
is_("quoted_operator: find's escaped and quoted ( open a group, not a root (it walks .)",
    (leaked(fc("find \\( -name x \\)"), OWNWALL, cwd=house), leaked(fc("find '(' -name x ')'"), OWNWALL, cwd=house)), ([CXN, CHN],) * 2)
is_("quoted_operator: find -exec ... \; keeps its root", leaked(fc("find ~/.local/share -name x -exec cat {} \;"), OWNWALL, cwd="/work/s"), [CHN])
is_("quoted_operator: a quoted ; inside a longer sh -c word still separates the inner commands",
    leaked(fc("bash -c \"cd /tmp\"';'\"rg foo ~\""), OWNWALL, cwd="/work/s"), [CXN, CHN])
is_("quoted_operator: an escaped $ inside an unquoted sh -c word still expands in the inner shell", leaked(fc("bash -lc cat\\ \\$HOME/.codex/x"), OWNWALL, cwd="/work/s"), [CXN])
is_("quoted_operator: only a word that reads as an operator keeps the mark", K._tokens(K._logical("rg '|' \; \"&\"\"&\" a|b x';'y")),
    ["rg", "|" + K.OP_MARK, ";" + K.OP_MARK, "&&" + K.OP_MARK, "a", "|", "b", "x;y"])
is_("function_body: an assignment in a body that never runs is read where it is defined",
    leaked(fc("f() { local D=~/.local/share; }; cat $D/chezmoi/x"), CHZ), CHZN)
got = leaked(fc("echo " + "$(" * 300 + "cat ~/.codex/x" + ")" * 300), OWNWALL, cwd="/work/s")
ok("deep_label: a 300-deep command is still a leak, and its label is short", any(x.endswith(DEEP) for x in got) and max(len(x) for x in got) <= 200, got)
deep = K._Scan(fwall, {})
deep.script(["cat", "x"], [SCR], depth=K.MAX_DEPTH + 1)
deep.script("a\n" + "b" * 500, [SCR], depth=K.MAX_DEPTH + 1)
is_("deep_label: a list command is quoted as its words, not a repr, and a long one is cut to one line",
    sorted(deep.found), sorted(["cat x (nested deeper than the scan follows)", "a " + "b" * (K.EXCERPT - 2) + "... (nested deeper than the scan follows)"]))
for cmd in ("echo a#b; cat ~/.codex/x", "curl http://h/p#frag; cat ~/.codex/x", "git log --format=%h#%s; cat ~/.codex/x", "cat ~/.codex/x; echo a#b"):
    is_("mid_word_hash: a # inside a word is text, so the rest of the line is scanned ({})".format(cmd), leaked(fc(cmd), OWNWALL, cwd="/work/s"), [CXN])
is_("mid_word_hash: a comment that starts a word still ends the line", leaked(fc("ls # cat ~/.codex/x"), OWNWALL, cwd="/work/s"), [])
is_("quoted_operator: an argv word that reads as an operator is a word (a list command has no shell operators)",
    (leaked(fc(["rg", ">", "~"]), OWNWALL, cwd="/work/s"), leaked(fc(["rg", "|", "~"]), OWNWALL, cwd="/work/s")), (twin, twin))
is_("quoted_operator: ... and an argv ( still opens find's group (it walks .)", leaked(fc(["find", "(", "-name", "x", ")"]), OWNWALL, cwd=house), [CXN, CHN])
for cmd in ("echo $(rg foo > out)", "echo $(rg foo < /dev/null)", "echo $(rg foo 2>/dev/null)", "echo a$(rg foo >out)", "x=$(grep -r foo > /dev/null); ls"):
    is_("quoted_operator: a real redirection inside $( ) stays one, so the search still walks . ({})".format(cmd), leaked(fc(cmd), OWNWALL, cwd=house), [CXN, CHN])

# ---- chezmoi is judged by the paths it names (spec 14.3 b, Task 4; R3: no subcommand is exempt from reading the destination)
CHW = CHZ + [house + "/.claude"]
CLN = house + "/.claude in t1"
for cmd in ("chezmoi --version", "chezmoi help", "chezmoi help diff", "chezmoi --source ~ --version", "chezmoi --color on help diff", "chezmoi -vn help"):
    is_("version_and_help: {} reads nothing".format(cmd), leaked(fc(cmd), CHZ), [])
is_("version_and_help: --version after the subcommand is no exemption", leaked(fc("chezmoi diff --version"), CHZ), CHZN)
is_("version_and_help: help as the value of a flag is no subcommand", leaked(fc("chezmoi --config help diff"), CHZ), CHZN)
is_("version_and_help: help after an unknown option cannot be told from its value", leaked(fc("chezmoi --frob help"), CHZ), CHZN)
is_("version_and_help: --version after an unknown option is no exemption", leaked(fc("chezmoi --frob=1 --version"), CHZ), CHZN)
for cmd in ("chezmoi --source {SCR} managed", "chezmoi -S {SCR} managed", "chezmoi --source={SCR} source-path x", "chezmoi -S. managed",
            'SRC={SCR}; chezmoi --source "$SRC" managed', "export SRC={SCR}; chezmoi -S $SRC managed", "chezmoi -S={SCR} managed", "chezmoi -vS {SCR} managed",
            "chezmoi -nS{SCR} managed", "chezmoi --no-tty --no-pager --source {SCR} --config {SCR}/c.toml --cache {SCR}/k --persistent-state {SCR}/p managed",
            "chezmoi --refresh-externals --source {SCR} managed", "chezmoi --refresh-externals=always --source {SCR} managed",
            "chezmoi --source {SCR} --destination ~ managed", "chezmoi --source {SCR} managed --path-style absolute",
            "sh -c 'chezmoi --source {SCR} managed'", "echo $(chezmoi --source {SCR} managed)", "echo `chezmoi -S {SCR} managed`",
            "cd {SCR} && chezmoi -S . managed", "env A=1 chezmoi --source {SCR} managed", "xargs chezmoi --source {SCR} source-path < list"):
    is_("source_into_scratch_managed: {} reads the original through the default destination (R3)".format(cmd), leaked(fc(cmd.format(SCR=SCR)), CHZ), CHZN)
is_("source_into_scratch_managed: an argv list is read the same", leaked(fc(["chezmoi", "--source", SCR, "managed"]), CHZ), CHZN)
for cmd in ("chezmoi --source {SCR} --destination {SCR}/h managed", "chezmoi -S {SCR} -D {SCR}/h managed", "chezmoi --source={SCR} --destination={SCR}/h source-path x",
            "chezmoi -S. -D. managed", "chezmoi -S={SCR} -D={SCR}/h managed", "chezmoi -vS {SCR} -D {SCR}/h managed", "sh -c 'chezmoi --source {SCR} --destination {SCR}/h managed'",
            "echo $(chezmoi --source {SCR} -D {SCR}/h managed)", "echo `chezmoi -S {SCR} -D {SCR}/h managed`", "cd {SCR} && chezmoi -S . -D . managed",
            "env A=1 chezmoi --source {SCR} -D {SCR}/h managed", "xargs chezmoi --source {SCR} -D {SCR}/h source-path < list",
            "chezmoi managed --source {SCR} --destination {SCR}/h", "chezmoi --source {SCR} --destination ~ -D {SCR}/h managed",
            "chezmoi --no-tty --no-pager --source {SCR} --destination {SCR}/h --config {SCR}/c.toml --cache {SCR}/k --persistent-state {SCR}/p managed",
            "chezmoi --refresh-externals --source {SCR} -D {SCR}/h managed", "chezmoi --color on --source {SCR} -D {SCR}/h managed"):
    is_("source_into_scratch_managed: {} reads only the scratch".format(cmd), leaked(fc(cmd.format(SCR=SCR)), CHZ), [])
is_("source_into_scratch_managed: an argv list with a scratch destination is clean", leaked(fc(["chezmoi", "--source", SCR, "-D", SCR + "/h", "managed"]), CHZ), [])
for cmd in ("chezmoi --source {SCR} diff", "chezmoi -S {SCR} status", "chezmoi --source {SCR} apply --dry-run", "chezmoi --source {SCR} --destination {SCR}/h --destination ~ diff"):
    is_("default_destination_search_root: {} reads ~ and so the original".format(cmd), leaked(fc(cmd.format(SCR=SCR)), CHZ), CHZN)
for cmd in ("chezmoi --source {SCR} --destination {SCR}/home diff", "chezmoi -S {SCR} -D{SCR}/home diff", "chezmoi -S {SCR} -D {SCR}/home status",
            "chezmoi --source {SCR} --destination ~ --destination {SCR}/home diff", "chezmoi --source {SCR} --destination={SCR}/home diff"):
    is_("default_destination_search_root: {} names no original".format(cmd), leaked(fc(cmd.format(SCR=SCR)), CHZ), [])
for cmd in ("chezmoi --source ~/.local/share/chezmoi managed", "chezmoi --source ~ managed", "chezmoi -S ~/.local/share managed", "chezmoi --source={SCR} --source ~ managed",
            "chezmoi --source ~ -D {SCR}/h managed"):
    is_("source_judged: {} reads the original".format(cmd), leaked(fc(cmd.format(SCR=SCR)), CHZ, cwd=house + "/.local/state/review-work/scratch/x"), CHZN)
for cmd in ("chezmoi managed", "chezmoi --destination {SCR} managed", "chezmoi source-path", "chezmoi -D{SCR} managed", "chezmoi --source '' managed", "chezmoi --source",
            "chezmoi managed -S", "chezmoi --source-path managed", "chezmoi --config {SCR}/c.toml managed"):
    is_("no_source_reads_original: {} reads the original".format(cmd), leaked(fc(cmd.format(SCR=SCR)), CHZ), CHZN)
for cmd in ("chezmoi --frobnicate --source {SCR} managed", "chezmoi -x --source {SCR} managed", "chezmoi --source {SCR} --frobnicate managed",
            "chezmoi --frobnicate --source {SCR} --destination {SCR}/h managed", "chezmoi -x --source {SCR} -D {SCR}/h managed"):
    is_("unknown_option: {} reads the original (an unknown option may take the next word, a source flag, as its value)".format(cmd), leaked(fc(cmd.format(SCR=SCR)), CHZ), CHZN)
for cmd in ("chezmoi --source {SCR} -D {SCR}/h --frobnicate managed", "chezmoi --source {SCR} -D {SCR}/h managed --frobnicate", "chezmoi --frobnicate=1 --source {SCR} -D {SCR}/h managed",
            "chezmoi --color on --source {SCR} -D {SCR}/h managed", "chezmoi --source {SCR} -D {SCR}/h diff --include dirs"):
    is_("unknown_option: {} names no original (the unknown option's next word is no source flag)".format(cmd), leaked(fc(cmd.format(SCR=SCR)), CHZ), [])
for cmd in ("chezmoi --pager --version diff -D {SCR}", "chezmoi diff --pager --source {SCR} -D {SCR}", "chezmoi --pager --source diff -D {SCR}",
            "chezmoi --pager -S {SCR} -D {SCR}/h diff", "chezmoi --pager --destination {SCR}/h -S {SCR} diff", "chezmoi -x --version", "chezmoi -x -S {SCR} -D {SCR}/h diff",
            "chezmoi -xS {SCR} -D {SCR}/h diff", "chezmoi -xD{SCR}/h -S {SCR} diff", "chezmoi diff -x --source-path -D {SCR}"):
    is_("unknown_swallows_a_flag: {} reads the original (the unknown option may have taken the flag as its value)".format(cmd), leaked(fc(cmd.format(SCR=SCR)), CHZ), CHZN)
for cmd in ("chezmoi diff --no-pager --pager -vS {SCR} -D {SCR}", "chezmoi --pager -vS {SCR} -D {SCR}/h diff", "chezmoi diff --pager -nD {SCR}/h -S {SCR}",
            "chezmoi diff --pager -vS {SCR} -D {SCR}/h", "chezmoi -x -vS {SCR} -D {SCR}/h diff",
            "chezmoi -x -nD {SCR}/h -S {SCR} diff", "chezmoi diff --pager -vS{SCR} -D {SCR}/h", "chezmoi diff --pager -nD{SCR}/h -S {SCR}",
            "chezmoi diff --pager -vS={SCR} -D {SCR}/h", "chezmoi --pager -vnS {SCR} -D {SCR}/h diff", "chezmoi diff -x -vSD {SCR}"):
    is_("unknown_swallows_a_cluster: {} reads the original (the unknown option may have taken the short cluster as its value)".format(cmd),
        leaked(fc(cmd.format(SCR=SCR)), CHZ), CHZN)
for cmd in ("chezmoi --pager -v -S {SCR} -D {SCR}/h diff", "chezmoi --pager=less --source {SCR} -D {SCR}/h diff", "chezmoi --pager less --source {SCR} -D {SCR}/h diff",
            "chezmoi diff --pager -nv -S {SCR} -D {SCR}/h", "chezmoi diff --pager -nv --source {SCR} -D {SCR}/h", "chezmoi -x -v -S {SCR} -D {SCR}/h diff"):
    is_("unknown_swallows_a_cluster: {} names no original (the next word is no source or destination flag)".format(cmd), leaked(fc(cmd.format(SCR=SCR)), CHZ), [])
for cmd in ("chezmoi -S {SCR} -D \"$D\" diff", "chezmoi -S {SCR} -D $TMPDIR/h diff", "chezmoi -S {SCR} -D \"$(echo ~)\" diff", "chezmoi -S {SCR} -D `echo ~` diff",
            "chezmoi -S \"$S\" -D {SCR}/h managed", "chezmoi -S \"$S\" managed", "chezmoi --source=$S --destination={SCR}/h managed", "D=$(echo {SCR}/h); chezmoi -S {SCR} -D \"$D\" diff",
            "chezmoi -S {SCR}/$X -D {SCR}/h managed"):
    is_("unexpanded_path: {} reads the original (a value the scan cannot expand)".format(cmd), leaked(fc(cmd.format(SCR=SCR)), CHZ), CHZN)
for cmd in ("chezmoi -S {SCR} -D \"$PWD/h\" diff", "chezmoi -S {SCR} -D \"$(pwd)/h\" diff", "cd {SCR} && chezmoi -S . -D \"$PWD/h\" diff",
            "chezmoi -S {SCR} -D \"$HOME/h\" diff"):
    is_("unexpanded_path: {} is expanded, so it names the scratch only".format(cmd), leaked(fc(cmd.format(SCR=SCR)), CHZ), [])
for cmd in ("false && SRC={SCR}; chezmoi -S \"$SRC\" -D {SCR}/h managed", "SRC={SCR}; chezmoi -S \"$SRC\" -D {SCR}/h diff", "SRC={SCR}; chezmoi --source \"$SRC\" --destination \"$SRC/h\" managed",
            "export SRC={SCR}; chezmoi -S $SRC -D$SRC/h managed", "D={SCR}/h; chezmoi -S {SCR} -D \"$D\" diff", "export S={SCR}; chezmoi -S \"$S\" -D \"${{S}}/h\" managed",
            "true || D={SCR}/h; chezmoi -S {SCR} -D \"$D\" diff", "if false; then D={SCR}/h; fi; chezmoi -S {SCR} -D \"$D\" managed"):
    is_("conditional_assignment: {} reads the original (an unknown variable keeps its spelling, an assignment adds a value and never hides one, spec 14.3 c)".format(cmd),
        leaked(fc(cmd.format(SCR=SCR)), CHZ), CHZN)
is_("conditional_assignment: ... as it is without the assignment (the variable the reviewer inherited)", leaked(fc('chezmoi -S "$SRC" -D {}/h managed'.format(SCR)), CHZ), CHZN)
for cmd in ("chezmoi --source {SCR} source-path ~/.local/share/chezmoi/dot_x", "chezmoi --source {SCR} -D {SCR}/h managed ~/.local/share/chezmoi",
            "chezmoi --source {SCR} -D {SCR}/h --config ~/.local/share/chezmoi/c.toml managed", "chezmoi --source {SCR} -D {SCR}/h --cache ~/.local/share/chezmoi managed",
            "chezmoi --source {SCR} -D {SCR}/h --persistent-state ~/.local/share/chezmoi/p managed"):
    is_("source_judged: {} names the original in another word".format(cmd), leaked(fc(cmd.format(SCR=SCR)), CHZ), CHZN)
is_("source_judged: --config into ~/.claude is a read of it", leaked(fc("chezmoi --source {0} -D {0}/h --config ~/.claude/c.toml managed".format(SCR)), CHW), [CLN])
is_("records_2026_11_03: 7f3b624a's calls: --version is clean, a source in the scratch reads ~, and so the original and ~/.claude (R3)",
    (leaked(fc("chezmoi --version"), CHW), leaked(fc("chezmoi --source {} managed".format(SCR)), CHW)), ([], [CLN, CHN]))
is_("records_2026_11_03: 3819843a's calls, git -C on the original and ls of ~/.claude/skills, still leak",
    (leaked(fc("git -C ~/.local/share/chezmoi log"), CHW), leaked(fc("ls ~/.claude/skills"), CHW)), (CHZN, [CLN]))
is_("flags_after_subcommand: managed --source <scratch> reads the original through ~ (R3)", leaked(fc("chezmoi managed --source {}".format(SCR)), CHZ), CHZN)
is_("flags_after_subcommand: managed --source <scratch> -D <scratch>/h reads only the scratch", leaked(fc("chezmoi managed --source {0} -D {0}/h".format(SCR)), CHZ), [])
is_("flags_after_subcommand: diff -S <scratch> still reads ~", leaked(fc("chezmoi diff -S {}".format(SCR)), CHZ), CHZN)
is_("flags_after_subcommand: managed -S <scratch> --destination ~ reads ~", leaked(fc("chezmoi managed -S {} --destination ~".format(SCR)), CHZ), CHZN)
is_("flags_after_subcommand: diff --source <scratch> -D <scratch>/h reads neither", leaked(fc("chezmoi diff --source {0} -D {0}/h".format(SCR)), CHZ), [])
for cmd in ("ls x$(cd /tmp) chezmoi", "echo chezmoi$(true) x$(true) chezmoi diff", "ls a`true` chezmoi diff"):
    is_("glued_word_not_a_command: {} does not run chezmoi".format(cmd), leaked(fc(cmd), CHZ), [])
is_("glued_word_not_a_command: ... while a cd inside the substitution adds its directory, so the word is judged from there too (cd_monotone)",
    leaked(fc("ls x$(cd ~/.local/share) chezmoi"), CHZ), CHZN)
is_("glued_word_not_a_command: ... a tool word with a glued substitution is still the command", leaked(fc("chezmoi$(true) --source {0} -D {0}/h managed".format(SCR)), CHZ), [])
is_("glued_word_not_a_command: ... it reads ~ by default, and the original without a source", (leaked(fc("chezmoi$(true) --source {} managed".format(SCR)), CHZ), leaked(fc("chezmoi$(true) managed"), CHZ)), (CHZN, CHZN))
is_("heredoc_not_run: a heredoc body is not run", leaked(fc("cat <<EOF\nchezmoi diff\nEOF"), CHZ), [])
is_("heredoc_not_run: ... sh -c inside it is not run either", leaked(fc("cat <<EOF\nsh -c 'chezmoi diff'\nEOF"), CHZ), [])
for cmd in ("cat <<EOF\n$(chezmoi diff)\nEOF", "cat <<EOF\n`chezmoi diff`\nEOF", "cat <<-EOF\n\tx $(chezmoi diff) y\n\tEOF", "cat <<EOF\na\nb $(echo $(chezmoi diff))\nEOF",
            "sh -c 'cat <<EOF\n$(chezmoi diff)\nEOF'", "cat <<EOF > out\n$(chezmoi diff)\nEOF\nls"):
    is_("heredoc_unquoted: {!r} runs the substitution of an unquoted body".format(cmd), leaked(fc(cmd), CHZ), CHZN)
for cmd in ("cat <<'EOF'\n$(chezmoi diff)\nEOF", 'cat <<"EOF"\n$(chezmoi diff)\nEOF', "cat <<'EOF'\n`chezmoi diff`\nEOF", "cat <<EOF\n$(chezmoi --source {0} -D {0}/h managed)\nEOF".format(SCR),
            "cat <<EOF\nchezmoi diff $(true)\nEOF"):
    is_("heredoc_unquoted: {!r} reads nothing (a quoted body is text; an unquoted one runs only its substitutions)".format(cmd), leaked(fc(cmd), CHZ), [])
is_("heredoc_unquoted: a path in an unquoted body is still read", leaked(fc("cat <<EOF\n$(echo hi) ~/.local/share/chezmoi/x\nEOF"), CHZ), CHZN)
is_("running_passes_down: sh -c and $( ) run it", (leaked(fc("sh -c 'echo $(chezmoi diff)'"), CHZ), leaked(fc("echo $(sh -c 'chezmoi diff')"), CHZ)), (CHZN, CHZN))
is_("running_passes_down: _Scan.script(running=False) runs no tool word, even inside sh -c and $( )",
    [sorted(s.found) for s in [K._Scan(K.wall(CHZ), {})] for _ in [s.script("sh -c 'echo $(chezmoi diff)'; chezmoi diff", [SCR], running=False)]], [[]])
is_("runs_is_gone: the old command-position scan has no caller left", hasattr(K, "_runs"), False)
is_("source_only_is_gone: no subcommand is exempt from the destination (R3), so no constant says otherwise", hasattr(K, "SOURCE_ONLY"), False)


# ---- real_chezmoi_source_only: the evidence for R3. Spec 14.3 b exempted a subcommand from reading the destination only if a real chezmoi, run on a
# source, reads none. A source with a .chezmoiremove (the repo's own has had one since 93cbf67) makes managed and source-path read it, so the test shows they do.
def real_chezmoi_source_only():
    binary = shutil.which("chezmoi")
    if not binary:
        ok("real_chezmoi_source_only: a chezmoi is on PATH, so R3 is shown", False, "no chezmoi on PATH: the exemption is not shown")
        return
    work = tempfile.mkdtemp(prefix="chezmoi-probe-", dir=ROOT)
    dest = os.path.join(work, "dest")
    try:
        cfg, cache, state = (os.path.join(work, x) for x in ("chezmoi.toml", "cache", "state.boltdb"))
        put(dest, ".bashrc", "export A=1\n")
        os.makedirs(cache)
        open(cfg, "w").close()
        env = dict(os.environ, HOME=os.path.join(work, "home"), XDG_CONFIG_HOME=os.path.join(work, "xdg"), XDG_CACHE_HOME=os.path.join(work, "xcache"))
        env.pop("CHEZMOI_SOURCE_DIR", None)
        os.makedirs(env["HOME"])
        version = subprocess.run([binary, "--version"], capture_output=True, text=True, env=env, timeout=60).stdout.strip()
        probes = {"managed": [], "source-path": [dest + "/.bashrc"], "status": []}
        ok("real_chezmoi_source_only: the chezmoi probed is {}".format(version), version.startswith("chezmoi version"), version)
        sources = {}
        for name, removes in (("an exact entry under a directory", ".claude/subagent-statusline.sh\n"), ("a dir/** glob", ".foo/**\n")):
            src = os.path.join(work, "src{}".format(len(sources)))
            put(src, "dot_bashrc", "export A=1\n")
            put(src, "private_dot_config/app/settings.toml", "k = 1\n")
            put(src, ".chezmoiremove", removes)
            sources[name] = src

        def run(src, sub):
            cmd = [binary, "--source", src, "--destination", dest, "--config", cfg, "--cache", cache, "--persistent-state", state, "--no-tty", "--no-pager", sub]
            p = subprocess.run(cmd + probes[sub], capture_output=True, text=True, env=env, timeout=60)
            return p.returncode, p.stdout, p.stderr

        def twice(src, sub):
            readable = run(src, sub)
            os.chmod(dest, 0)
            try:
                return readable, run(src, sub)
            finally:
                os.chmod(dest, 0o755)

        for name, src in sources.items():
            for sub in ("managed", "source-path"):
                a, b = twice(src, sub)
                ok("real_chezmoi_source_only: {} reads the destination with {} in .chezmoiremove: its run at mode 000 differs. "
                   "If this FAILS, chezmoi no longer reads it there and the exemption for {} may be restored (R3)".format(sub, name, sub),
                   a[0] == 0 and a != b, (a, b))
            a, b = twice(src, "status")
            ok("real_chezmoi_source_only: the control (status) differs at mode 000 with {}, so the probe can see a read".format(name), a[0] == 0 and a != b, (a, b))
    finally:
        if os.path.isdir(dest):
            os.chmod(dest, 0o755)
        shutil.rmtree(work, ignore_errors=True)


real_chezmoi_source_only()


# ---- carried from Task 3: a TOO_DEEP label holds no internal mark
marked = leaked(fc("echo $(echo $(echo $(echo $(echo $(rg '|' ~ 2>/dev/null)))))"), OWNWALL, cwd="/work/s")
ok("deep_label: a TOO_DEEP label holds neither OP_MARK nor FD_MARK", any(x.endswith(DEEP) for x in marked) and not any(c in x for x in marked for c in (K.OP_MARK, K.FD_MARK)), marked)
is_("deep_label: ... and _excerpt drops them from a command rebuilt from tokens", K._excerpt("rg '|" + K.OP_MARK + "' 2" + K.FD_MARK + " > /dev/null"), "rg '|' 2 > /dev/null")
is_("counted_not_read: ls >#x cat ~/.codex/y (a syntax error in bash) is still scanned, as the docstring says", (leaked(fc("ls >#x cat ~/.codex/y"), OWNWALL, cwd="/work/s"), leaked(fc("ls 2>#x cat ~/.codex/y"), OWNWALL, cwd="/work/s")), ([CXN], [CXN]))
