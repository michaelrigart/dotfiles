import json
import os
import shutil
import sys
from argparse import Namespace

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import helpers
from helpers import is_, ok

helpers.setup()
from process_replay import bar  # noqa: E402
from process_replay import common as C  # noqa: E402

ROOT = helpers.tmp_root()


# ------------------------------------------------------------------ fixtures
def case(cid, task=(), pre=(), uncounted=(), rounds=2):
    """A case with its defects' inventory records attached as bar() expects (case["info"]).
    task, pre: [(id, severity)]; uncounted: [(id, severity)] per-task defects that are not counted (P3)."""
    info = {}
    for klass, items, counted in (("task", task, True), ("pre", pre, True), ("task", uncounted, False)):
        for did, sev in items:
            info[did] = {"id": did, "class": klass, "severity": sev, "counted": counted, "summary": "what " + did, "file": "f.py", "line": 1}
    return {"id": cid, "branch": "b" + cid, "repo": "/repo/" + cid, "defects": [d for d, i in info.items() if i["counted"]],
            "original_rounds": rounds, "work_commit": "w", "info": info, "digest": "digest-" + cid}


def run(cid, label, states, end="approve", codex=2, **more):
    reviews = [{"id": label + "-0", "kind": "final", "k": 0, "findings": [], "verdict": "report", "tokens": 0, "turns": 0, "model": None, "effort": None}]
    reviews += [{"id": "{}-{}".format(label, k), "kind": "codex", "k": k, "findings": [], "verdict": "revise", "tokens": 1000, "turns": 1,
                 "model": "gpt-x", "effort": "high"} for k in range(1, codex + 1)]
    r = {"case": cid, "label": label, "scratch": "/s", "thread": "t", "round": codex, "step": "done", "reviews": reviews, "defects": dict(states),
         "rejected": [], "addressed": [], "outside": [], "ledger": None, "end": end, "voids": 0, "tokens": 1000 * codex, "case_digest": "digest-" + cid}
    r.update(more)
    return r


def sts(**kw):
    return dict((k, {"r": "recovered", "u": "unrecovered", "c": "censored", "p": "present"}[v]) for k, v in kw.items())


NONE = {"unassessable_task": []}
HELD = {"unassessable_task": ["dgone"]}


def two(cid, a, b=None, **more):
    return [run(cid, cid + "a", a, **more), run(cid, cid + "b", b if b is not None else a, **more)]


# the base case: per-task t1 P1, t2 P2; pre-merge q1 P1, q2 P2
BASE = case("c1", task=[("t1", "P1"), ("t2", "P2")], pre=[("q1", "P1"), ("q2", "P2")])
ALL_R = sts(t1="r", t2="r", q1="r", q2="r")
# five pre-merge defects make one miss assessable (4/5 = 80%); four per-task defects allow one censored
BIG = case("c2", task=[("t1", "P1"), ("t2", "P2"), ("t3", "P2"), ("t4", "P2")], pre=[("q1", "P1")] + [("q%d" % i, "P2") for i in range(2, 6)])
NOPRE = case("cn", task=[("t1", "P1"), ("t2", "P2")])
BIG_R = dict((d, "recovered") for d in BIG["defects"])

# ---- the table: (name, cases, runs, coverage, status)
TABLE = [
    ("pass_all_recovered", [BASE], two("c1", ALL_R), NONE, "pass"),
    ("fail_task_p1: assessable, per-task P1 unrecovered, every pre-merge P0/P1 recovered", [BASE],
     two("c1", sts(t1="u", t2="r", q1="r", q2="r")), NONE, "fail"),
    ("fail in one run only is a fail", [BASE], [run("c1", "a", ALL_R), run("c1", "b", sts(t1="u", t2="r", q1="r", q2="r"))], NONE, "fail"),
    ("not_fail_when_pre_p1_missed: the same with a pre-merge P1 unrecovered", [BIG],
     two("c2", dict(BIG_R, t1="unrecovered", q1="unrecovered")), NONE, "inconclusive"),
    ("pre-merge P1 censored is not recovered: not a fail", [BIG], two("c2", dict(BIG_R, t1="unrecovered", q1="censored")), NONE, "inconclusive"),
    ("a pre-merge P2 unrecovered does not shield a per-task P1 miss: still a fail", [BIG],
     two("c2", dict(BIG_R, t1="unrecovered", q5="unrecovered")), NONE, "fail"),
    ("an unassessable run's per-task P1 miss is no fail (half its per-task defects censored)", [BIG],
     two("c2", dict(BIG_R, t1="unrecovered", t2="censored", t3="censored")), NONE, "inconclusive"),
    ("an unassessable run's per-task P1 miss is no fail (pre-merge recall 3/5)", [BIG],
     two("c2", dict(BIG_R, t1="unrecovered", q4="unrecovered", q5="unrecovered")), NONE, "inconclusive"),
    ("censoring_blocks_pass: a censored per-task defect is not recovered", [BASE], two("c1", sts(t1="r", t2="c", q1="r", q2="r")), NONE, "inconclusive"),
    ("task_p2_unrecovered_inconclusive", [BASE], two("c1", sts(t1="r", t2="u", q1="r", q2="r")), NONE, "inconclusive"),
    ("coverage_gate: unassessable per-task defects make a pass inconclusive", [BASE], two("c1", ALL_R), HELD, "inconclusive"),
    ("coverage_gate_override_inconclusive: a fail under a failing gate is inconclusive", [BASE], two("c1", sts(t1="u", t2="r", q1="r", q2="r")), HELD, "inconclusive"),
    ("coverage_waiting: every run passing, a branch still waiting: inconclusive", [BASE], two("c1", ALL_R), {"unassessable_task": [], "waiting": ["bx"]}, "inconclusive"),
    ("coverage_waiting: an empty waiting list is a settled gate: pass", [BASE], two("c1", ALL_R), {"unassessable_task": [], "waiting": []}, "pass"),
    ("coverage_waiting_override_inconclusive: a fail under an unsettled gate is inconclusive", [BASE], two("c1", sts(t1="u", t2="r", q1="r", q2="r")),
     {"unassessable_task": [], "waiting": ["bx"]}, "inconclusive"),
    ("coverage_waiting_settled: the same runs with nothing waiting are a fail", [BASE], two("c1", sts(t1="u", t2="r", q1="r", q2="r")),
     {"unassessable_task": [], "waiting": []}, "fail"),
    ("a void run with no replacement is not assessable: no pass", [BASE], [run("c1", "a", ALL_R), run("c1", "b", sts(t1="p", t2="p", q1="p", q2="p"), end="void", voids=2)],
     NONE, "inconclusive"),
    ("an errored run is not assessable: no pass", [BASE], [run("c1", "a", ALL_R), run("c1", "b", ALL_R, end="error")], NONE, "inconclusive"),
    ("a run still going is not assessable", [BASE], [run("c1", "a", ALL_R), run("c1", "b", sts(t1="p", t2="p", q1="p", q2="p"), end=None, step="codex")], NONE, "inconclusive"),
    ("a case with one run of two is incomplete: no pass", [BASE], [run("c1", "a", ALL_R)], NONE, "inconclusive"),
    ("a voided run replaced by a re-run counts the re-run only", [BASE],
     [run("c1", "a", ALL_R), run("c1", "b", sts(t1="p", t2="p", q1="p", q2="p"), end="void", voids=1, replaced_by="b2", leak=["x"]),
      run("c1", "b2", ALL_R, voids=1, replaces="b")], NONE, "pass"),
    ("no cases: inconclusive", [], [], NONE, "inconclusive"),
    ("per-run, not pooled: one run misses a per-task P1, the other a pre-merge P1: fail", [BIG],
     [run("c2", "a", dict(BIG_R, t1="unrecovered")), run("c2", "b", dict(BIG_R, q1="unrecovered"))], NONE, "fail"),
    ("per-run, not pooled: one run misses both, the other recovers all: inconclusive", [BIG],
     [run("c2", "a", dict(BIG_R, t1="unrecovered", q1="unrecovered")), run("c2", "b", BIG_R)], NONE, "inconclusive"),
    ("a case with no pre-merge defects: a per-task P1 miss is no fail", [NOPRE],
     two("cn", sts(t1="u", t2="r")), NONE, "inconclusive"),
    ("a case with no pre-merge defects cannot support a pass", [NOPRE], two("cn", sts(t1="r", t2="r")), NONE, "inconclusive"),
    ("a case with no pre-merge defects blocks a pass of the others", [BASE, NOPRE], two("c1", ALL_R) + two("cn", sts(t1="r", t2="r")), NONE, "inconclusive"),
    ("p3_not_counted: a per-task P3 left unrecovered is listed, not counted", [case("c1", task=[("t1", "P1"), ("t2", "P2")], pre=[("q1", "P1")], uncounted=[("t3", "P3")])],
     two("c1", sts(t1="r", t2="r", q1="r")), NONE, "pass"),
    ("a second case missing a run blocks the pass", [BASE, case("c2", task=[("u1", "P1")], pre=[("w1", "P1")])],
     two("c1", ALL_R) + [run("c2", "x", sts(u1="r", w1="r"))], NONE, "inconclusive"),
    ("a second case failing makes the whole a fail", [BASE, case("c2", task=[("u1", "P1")], pre=[("w1", "P1")])],
     two("c1", ALL_R) + two("c2", sts(u1="u", w1="r")), NONE, "fail"),
]
for name, cases, runs, coverage, want in TABLE:
    got = bar.bar(cases, runs, coverage)
    is_(name, got["status"], want)
    ok(name + " (reasons are strings, one at least)", got["reasons"] and all(isinstance(r, str) for r in got["reasons"]), got["reasons"])

# ---- coverage_gate_override_inconclusive: the fail's reasons stay in the report, ahead of the gate's
got = bar.bar([BASE], two("c1", sts(t1="u", t2="r", q1="r", q2="r")), HELD)
fail_at = [i for i, r in enumerate(got["reasons"]) if "unrecovered while every pre-merge P0/P1 was recovered" in r]
gate_at = [i for i, r in enumerate(got["reasons"]) if r.startswith("coverage gate:")]
ok("coverage_gate_override_inconclusive: the reasons hold the fail (both runs) before the coverage gate's",
   len(fail_at) == 2 and len(gate_at) == 1 and max(fail_at) < gate_at[0], got["reasons"])

got = bar.bar([BASE], two("c1", ALL_R), {"unassessable_task": [], "waiting": ["bx", "by"]})
ok("coverage_waiting: the reasons say the gate is not settled and name the waiting branches", any(r.startswith("coverage gate: not settled") and "bx, by" in r for r in got["reasons"]), got["reasons"])

got = bar.bar([BASE], two("c1", sts(t1="u", t2="r", q1="r", q2="r")), {"unassessable_task": [], "waiting": ["bx"]})
fail_at = [i for i, r in enumerate(got["reasons"]) if "unrecovered while every pre-merge P0/P1 was recovered" in r]
wait_at = [i for i, r in enumerate(got["reasons"]) if r.startswith("coverage gate: not settled")]
ok("coverage_waiting_override_inconclusive: the reasons hold the fail (both runs) before the not-settled reason",
   len(fail_at) == 2 and len(wait_at) == 1 and max(fail_at) < wait_at[0], got["reasons"])

# ---- runs_per_case: report expects as many runs as `run` makes; the count lives in common.RUNS and nowhere else
C.RUNS = 3
try:
    got = bar.bar([BASE], two("c1", ALL_R), NONE)
finally:
    C.RUNS = 2
ok("runs_per_case: a case with two runs of the three common.RUNS asks for is incomplete, and says 2 of 3",
   got["status"] == "inconclusive" and "case c1: 2 of 3 runs" in got["reasons"], got["reasons"])

# ---- assessable_edges
def sized(npre, rec_pre, ntask, cens_task, rec_pre_state="recovered"):
    pre = [("p%03d" % i, "P2") for i in range(npre)]
    task = [("t%03d" % i, "P2") for i in range(ntask)]
    c = case("ce", task=task, pre=pre)
    states = {}
    for i, (d, _s) in enumerate(pre):
        states[d] = "recovered" if i < rec_pre else "unrecovered"
    for i, (d, _s) in enumerate(task):
        states[d] = "censored" if i < cens_task else "recovered"
    return c, states


for name, args, want in (
    ("assessable_edges: pre-merge recall 4/5 = 0.8 is assessable", (5, 4, 4, 0), True),
    ("assessable_edges: pre-merge recall 80/100 = 0.8 is assessable", (100, 80, 4, 0), True),
    ("assessable_edges: pre-merge recall 79/100 = 0.79 is not", (100, 79, 4, 0), False),
    ("assessable_edges: pre-merge recall 3/4 is not", (4, 3, 4, 0), False),
    ("assessable_edges: per-task censored 1/4 = 25% is assessable", (5, 5, 4, 1), True),
    ("assessable_edges: per-task censored 25/100 is assessable", (5, 5, 100, 25), True),
    ("assessable_edges: per-task censored 26/100 = 26% is not", (5, 5, 100, 26), False),
    ("assessable_edges: per-task censored 2/4 is not", (5, 5, 4, 2), False),
):
    c, states = sized(*args)
    got = bar.bar([c], two("ce", states), NONE)
    is_(name, got["assessable"], {"cea": want, "ceb": want})
for end in ("void", "error", None):
    c, states = sized(5, 5, 4, 0)
    got = bar.bar([c], [run("ce", "r1", states, end=end, voids=2)], NONE)
    is_("assessable_edges: a run that ended {!r} is not assessable".format(end), got["assessable"], {"r1": False})
c, states = sized(5, 5, 4, 0)
got = bar.bar([c], [run("ce", "ok", states)] + [run("ce", "old", states, end="void", voids=1, replaced_by="new"), run("ce", "new", states, voids=1, replaces="old")], NONE)
is_("assessable_edges: a replaced void run is left out of the assessable map", sorted(got["assessable"]), ["new", "ok"])

got = bar.bar([NOPRE], two("cn", sts(t1="u", t2="r")), NONE)
is_("no pre-merge class: no run is assessable", got["assessable"], {"cna": False, "cnb": False})
ok("no pre-merge class: the reason says why", any("no pre-merge defects to calibrate against" in r for r in got["reasons"]), got["reasons"])
is_("no pre-merge class: the case is listed", got["no_pre_cases"], ["cn"])
is_("no pre-merge class: the case with pre-merge defects is not", bar.bar([BASE], two("c1", ALL_R), NONE)["no_pre_cases"], [])
got = bar.bar([BIG], [run("c2", "a", dict(BIG_R, t1="unrecovered")), run("c2", "b", dict(BIG_R, q1="unrecovered"))], NONE)
is_("per-run: both runs are assessable (recall 4/5)", got["assessable"], {"a": True, "b": True})

# a defect of a run missing from the inventory is a Failed naming the case and the defect, never a KeyError
try:
    bar.bar([dict(BASE, defects=["t1", "t2", "q1", "q2", "ghost"])], [], NONE)
    ok("bar: a case defect missing from the inventory raises Failed", False, "returned")
except C.Failed as e:
    ok("bar: a case defect missing from the inventory raises Failed naming the case and the defect", "c1" in str(e) and "ghost" in str(e), str(e))
try:
    bar.bar([BASE], two("c1", dict(ALL_R, ghost="recovered")), NONE)
    ok("bar: a run defect missing from the inventory raises Failed", False, "returned")
except C.Failed as e:
    ok("bar: a run defect missing from the inventory raises Failed naming the case and the defect", "c1" in str(e) and "ghost" in str(e), str(e))

# ---- unrecovered_task
got = bar.bar([BASE], [run("c1", "a", sts(t1="u", t2="u", q1="r", q2="r")), run("c1", "b", sts(t1="r", t2="c", q1="r", q2="r"))], NONE)
is_("unrecovered_task: each unrecovered per-task defect with run, severity and summary",
    sorted((u["case"], u["run"], u["severity"], u["summary"]) for u in got["unrecovered_task"]),
    [("c1", "a", "P1", "what t1"), ("c1", "a", "P2", "what t2")])
c3 = case("c1", task=[("t1", "P1")], pre=[("q1", "P1")], uncounted=[("t3", "P3"), ("t4", "P3")])
got = bar.bar([c3], two("c1", sts(t1="r", q1="r")), NONE)
is_("p3_not_counted: per-task P3 defects are listed on their own", sorted((u["case"], u["severity"], u["summary"]) for u in got["uncounted_task"]),
    [("c1", "P3", "what t3"), ("c1", "P3", "what t4")])
is_("p3_not_counted: and not in unrecovered_task", got["unrecovered_task"], [])

# ---- report_contents: a state directory
STATE = os.path.join(ROOT, "state")
INV = {"branch": "bc1", "dropped": [{"summary": "x", "why": "introduced by a fix"}, {"summary": "y", "why": "introduced by a fix"}, {"summary": "z", "why": "no severity"}],
       "defects": [dict(i) for i in BASE["info"].values()]
       + [{"id": "t3", "class": "task", "severity": "P3", "counted": False, "summary": "a minor thing", "file": "f.py", "line": 3},
          {"id": "q3", "class": "pre", "severity": "P2", "counted": True, "summary": "pre p2 lost", "file": "f.py", "line": 4}]}
INJ = {"defects": {"t1": {"status": "present", "reason": ""}, "t2": {"status": "recreated", "reason": ""}, "q1": {"status": "present", "reason": ""},
                   "q2": {"status": "present", "reason": ""},
                   "q3": {"status": "unassessable", "reason": "the judge answered no on the finished tree"},
                   "q4": {"status": "dropped-revert", "reason": "does not revert cleanly"},
                   "q5": {"status": "dropped-revert", "reason": "does not revert cleanly"}}}
INV["defects"] += [{"id": "q4", "class": "pre", "severity": "P2", "counted": True, "summary": "q4", "file": "f.py", "line": 5},
                   {"id": "q5", "class": "pre", "severity": "P1", "counted": True, "summary": "q5", "file": "f.py", "line": 6}]
case_rec = dict((k, v) for k, v in BASE.items() if k != "info")
C.jsave(os.path.join(STATE, "cases.json"), {"cases": [case_rec], "examined": [
    {"branch": "bc1", "qualified": True, "why": None, "counts": {}},
    {"branch": "bx9", "qualified": False, "why": "fewer than two per-task defects (P0-P2)", "counts": {}},
    {"branch": "by8", "qualified": False, "why": "merged outside the window", "counts": {}}],
    "coverage": {"unassessable_task": []}})
C.jsave(os.path.join(STATE, "branches.json"), {"branches": [
    {"id": "bc1", "repo": "/repo/c1", "branch": "feat-one", "rounds": [{"k": 1}, {"k": 2}], "joined": [
        {"id": "g1-bc1", "group": "g1", "reviews": [0, 1], "changes": [], "unjoined": []},
        {"id": "g2-bc1", "group": "g2", "reviews": [0], "changes": [], "unjoined": []}]},
    {"id": "bx9", "repo": "/repo/x", "branch": "feat-x", "rounds": []}, {"id": "by8", "repo": "/repo/y", "branch": "feat-y", "rounds": []}]})
C.jsave(os.path.join(STATE, "inventory", "bc1.json"), INV)
C.jsave(os.path.join(STATE, "injected", "bc1.json"), INJ)
C.jsave(os.path.join(STATE, "reviews.json"), {"groups": [
    {"id": "g1", "task": 3, "prefix": "W1", "repo": "/repo/c1", "reviews": [
        {"agent": "a1", "kind": "sp-reviewer", "start": "2026-10-20T10:00:00.000Z", "end": "2026-10-20T10:06:00.000Z", "tokens": 4000},
        {"agent": "a2", "kind": "sp-reviewer", "start": "2026-10-20T11:00:00.000Z", "end": "2026-10-20T11:03:00.000Z", "tokens": 2500}]},
    {"id": "g2", "task": 4, "prefix": "W1", "repo": "/repo/c1", "reviews": [
        {"agent": "a3", "kind": "sp-architect", "start": "2026-10-21T10:00:00.000Z", "end": "2026-10-21T10:10:00.000Z", "tokens": 9000}]}]})
RUNS = [
    run("c1", "alpha", sts(t1="u", t2="r", q1="r", q2="r"), end="rounds", codex=4),
    run("c1", "beta", sts(t1="r", t2="c", q1="r", q2="r"), end="stalled", codex=3),
    run("c1", "gamma", sts(t1="p", t2="p", q1="p", q2="p"), end="void", voids=1, replaced_by="delta", leak=["/orig"]),
    run("c1", "delta", ALL_R, codex=2, voids=1, replaces="gamma"),
]
def stamp(state, runs):
    """The digest each case has in `state`, set as the case_digest of the runs of it (what `run` records when it makes a run)."""
    cases = bar._load(Namespace(state=state))[1]
    digests = dict((c["id"], c["digest"]) for c in cases)
    for r in runs:
        r["case_digest"] = digests[r["case"]]
    return runs


for r in stamp(STATE, RUNS):
    C.jsave(os.path.join(STATE, "runs", r["case"], r["label"], "state.json"), r)
args = Namespace(state=STATE, dry_run=False)
is_("report: cmd_report returns 0", bar.cmd_report(args), 0)
md = open(os.path.join(STATE, "report.md")).read()
rep = C.jload(os.path.join(STATE, "report.json"))
is_("report.json: the status", rep["bar"]["status"], "fail")
is_("report.json: the replaced void run is not in the assessable map", sorted(rep["bar"]["assessable"]), ["alpha", "beta", "delta"])
ok("report.md: the status", "FAIL" in md.upper() and "status" in md.lower(), md[:300])
for what, needle in (
        ("each case", "c1"), ("each run", "alpha"), ("another run", "beta"), ("the re-run", "delta"),
        ("the unrecovered per-task defect's summary", "what t1"), ("its severity", "P1"),
        ("the P3 per-task defect, listed", "a minor thing"),
        ("the original round count beside the simulated one", "original 2"),
        ("extra rounds, simulated minus original (4 - 2)", "+2"),
        ("an extra of +1 (beta: 3 Codex rounds against 2)", "extra +1"),
        ("an extra of zero (delta: 2 Codex rounds against 2)", "extra +0"),
        ("Codex tokens of the run", "4000"),
        ("model and effort", "gpt-x"),
        ("the effort", "high"),
        ("the end of a run", "stalled"),
        ("a void and its re-run", "gamma"),
        ("the extra rounds and Codex tokens over the assessable runs", "over the 2 assessable run(s): +2; Codex tokens: 6000"),
        ("and over the runs that are not assessable, apart", "over the 1 run(s) that are not assessable"),
        ("the October dispatches of task 3", "dispatches 2"),
        ("the October tokens of task 3", "6500"),
        ("the October wall minutes of task 3", "9.0"),
        ("the October tokens of task 4", "9000"),
        ("an examined branch that never became a case", "bx9"),
        ("its reason", "fewer than two per-task defects"),
        ("the other examined branch's reason", "merged outside the window"),
        ("a drop by reason", "does not revert cleanly: 2"),
        ("an unassessable pre-merge P2, counted", "unassessable pre-merge P2"),
        ("an inventory drop by reason", "introduced by a fix: 2"),
):
    ok("report_contents: report.md lists " + what, needle in md, needle + " not in report.md")
is_("report.json: October cost of the case's tasks", [(t["task"], t["dispatches"], t["tokens"], t["minutes"]) for t in rep["cases"][0]["october"]["tasks"]],
    [(3, 2, 6500, 9.0), (4, 1, 9000, 10.0)])
is_("report.json: October totals", (rep["cases"][0]["october"]["dispatches"], rep["cases"][0]["october"]["tokens"], rep["cases"][0]["october"]["minutes"]), (3, 15500, 19.0))
alpha = [r for r in rep["cases"][0]["runs"] if r["label"] == "alpha"][0]
is_("report.json: a run's codex rounds, original and extra", (alpha["codex_rounds"], alpha["original_rounds"], alpha["extra_rounds"]), (4, 2, 2))
is_("report.json: a run's per-class counts", (alpha["task"], alpha["pre"]),
    ({"recovered": 1, "unrecovered": 1, "censored": 0}, {"recovered": 2, "unrecovered": 0, "censored": 0}))
is_("report.json: the unassessable pre-merge P2 count", rep["drops"]["unassessable_pre_p2"], 2)
is_("report.json: the drops by status and reason", rep["drops"]["injected"]["dropped-revert"], {"does not revert cleanly": 2})
is_("report.json: the not-a-case branches", sorted(e["branch"] for e in rep["examined_not_cases"]), ["bx9", "by8"])
is_("report.json: no plan section without plan cases", rep.get("planreview"), None)
ok("report.md: the unassessable runs' extra rounds and tokens are kept apart", "(error, final void, unfinished, too much censored or missed, or no pre-merge class): +1; Codex tokens: 3000" in md, md)
ok("report.md: cases with no pre-merge defects: none", "Cases with no pre-merge defects, so no run of them is assessable (no pre-merge defects to calibrate against): none" in md, md)
delta = [r for r in rep["cases"][0]["runs"] if r["label"] == "delta"][0]
is_("report.json: an extra of zero", delta["extra_rounds"], 0)
ok("report.md: no plan section without plan cases", "Plan-review checkpoint" not in md)

# ---- report_counts_cut_inputs
is_("report_counts_cut_inputs: no record is all zeros, in the report and in report.json", (rep["cut_inputs"], "judge-present inputs cut from the top (no anchor located): 0 (presence 0, validation 0, revalidation 0)" in md),
    ({"presence": 0, "validation": 0, "revalidation": 0}, True))
S1c = os.path.join(ROOT, "state-cuts")
shutil.copytree(STATE, S1c)
for jid, site, files in (("x1-0", "presence", ["a.py"]), ("x1-1", "presence", ["b.py", "c.py"]), ("alpha-0-t1", "revalidation", ["a.py"])):
    C.jsave(os.path.join(S1c, "cuts", "judge-present", jid + ".json"), {"site": site, "files": files})
bar.cmd_report(Namespace(state=S1c, dry_run=False))
mdc = open(os.path.join(S1c, "report.md")).read()
repc = C.jload(os.path.join(S1c, "report.json"))
ok("report_counts_cut_inputs: two presence inputs and one revalidation input are three, by site", "judge-present inputs cut from the top (no anchor located): 3 (presence 2, validation 0, revalidation 1)" in mdc, mdc[:600])
is_("report_counts_cut_inputs: and report.json holds the same", repc["cut_inputs"], {"presence": 2, "validation": 0, "revalidation": 1})

# ---- a case branch missing from branches.json, a run with fewer rounds than the original, a case with no pre-merge class
S2 = os.path.join(ROOT, "state2")
NP = case("cn", task=[("t1", "P1"), ("t2", "P2")], rounds=3)
C.jsave(os.path.join(S2, "cases.json"), {"cases": [dict((k, v) for k, v in NP.items() if k != "info")], "examined": [], "coverage": {"unassessable_task": []}})
C.jsave(os.path.join(S2, "branches.json"), {"branches": []})
C.jsave(os.path.join(S2, "inventory", "bcn.json"), {"branch": "bcn", "dropped": [], "defects": list(NP["info"].values())})
C.jsave(os.path.join(S2, "reviews.json"), {"groups": []})
for r in stamp(S2, two("cn", sts(t1="r", t2="r"), codex=1)):
    C.jsave(os.path.join(S2, "runs", "cn", r["label"], "state.json"), r)
bar.cmd_report(Namespace(state=S2, dry_run=False))
md2 = open(os.path.join(S2, "report.md")).read()
rep2 = C.jload(os.path.join(S2, "report.json"))
ok("report.md: a branch missing from branches.json is unknown, and named", "case cn: unknown, branch bcn is not in branches.json" in md2, md2)
ok("report.md: and not counted as zero in the totals", "all cases: dispatches 0, tokens 0, wall minutes 0.0 (1 case(s) unknown, not included)" in md2, md2)
is_("report.json: its October cost is null with the reason", (rep2["cases"][0]["october"], rep2["cases"][0]["october_unknown"]), (None, "branch bcn is not in branches.json"))
ok("report.md: a negative extra is shown with its sign", "extra -2" in md2, md2)
ok("report.md: a case with no pre-merge defects is listed with the reason", "(no pre-merge defects to calibrate against): cn" in md2, md2)
is_("report.json: and its runs are not assessable", rep2["bar"]["assessable"], {"cna": False, "cnb": False})
is_("report.json: negative extra rounds", [r["extra_rounds"] for r in rep2["cases"][0]["runs"]], [-2, -2])
S3 = os.path.join(ROOT, "state3")
C.jsave(os.path.join(S3, "cases.json"), {"cases": [dict((k, v) for k, v in BASE.items() if k != "info")], "examined": [], "coverage": {}})
C.jsave(os.path.join(S3, "inventory", "bc1.json"), {"branch": "bc1", "dropped": [], "defects": [d for d in BASE["info"].values() if d["id"] != "q2"]})
try:
    bar.cmd_report(Namespace(state=S3, dry_run=False))
    ok("cmd_report: an inventory missing a case's defect is an error", False, "returned")
except C.Failed as e:
    ok("cmd_report: an inventory missing a case's defect raises Failed naming the case and the defect", "c1" in str(e) and "q2" in str(e), str(e))

# ---- the plan-checkpoint section, when plan-cases.json has a round
C.jsave(os.path.join(STATE, "plan-cases.json"), {"rounds": [
    {"nonce": "n1", "at": "2026-10-10T10:00:00Z", "repo": "/repo/c1", "plans": ["docs/superpowers/plans/p.md"], "thread": "th", "turn": "tu", "verdict": "revise",
     "minutes": 12.0, "tokens": 7777, "next": None, "asked": False, "plan_of": {}, "findings": []}], "skips": [], "lost_saving": {}})
bar.cmd_report(args)
md = open(os.path.join(STATE, "report.md")).read()
rep = C.jload(os.path.join(STATE, "report.json"))
ok("report.md: the plan-checkpoint section is included when there are rounds", "Plan-review checkpoint" in md and "7777" in md, md[-600:])
ok("report.json: and its data", isinstance(rep.get("planreview"), dict) and rep["planreview"]["rounds"] == 1, rep.get("planreview"))

# ---- superseded_runs: a run counts only for the inputs of its case as they are now
OLD = dict(case("c1", task=[("t1", "P1"), ("t2", "P2")], pre=[("q1", "P1")]), digest="digest-old")
NEW = dict(case("c1", task=[("t1", "P1"), ("t2", "P2"), ("t3", "P2")], pre=[("q1", "P1")]), digest="digest-new")      # inject added an assessable defect
gone = two("c1", sts(t1="r", t2="r", q1="r"), case_digest="digest-old")
got = bar.bar([OLD], gone, NONE)
is_("superseded_runs: control: the runs and the case have one digest: pass", got["status"], "pass")
got = bar.bar([NEW], gone, NONE)
is_("superseded_runs: two runs that recovered t1, t2 and q1 do not make a pass for a case now holding t1, t2, t3 and q1 (neither tested t3)", got["status"], "inconclusive")
ok("superseded_runs: the case needs runs, and the reason says how many were set aside", "case c1: 0 of 2 runs (2 more set aside as superseded" in " ".join(got["reasons"]), got["reasons"])
is_("superseded_runs: neither run is assessable or tallied", (got["assessable"], got["unrecovered_task"]), ({}, []))
is_("superseded_runs: the labels set aside are listed per case", got["superseded"], {"c1": ["c1a", "c1b"]})
fresh_ = two("c1", sts(t1="r", t2="r", t3="r", q1="r"), case_digest="digest-new")
fresh_ = [dict(r, label=r["label"] + "n") for r in fresh_]
got = bar.bar([NEW], gone + fresh_, NONE)
is_("superseded_runs: with two runs of the current inputs beside the old, only those count and the bar passes", (got["status"], sorted(got["assessable"])), ("pass", ["c1an", "c1bn"]))
is_("superseded_runs: and the old ones are still listed as set aside", got["superseded"], {"c1": ["c1a", "c1b"]})
got = bar.bar([NEW], [dict(r, superseded="digest-new") for r in fresh_], NONE)
is_("superseded_runs: a run marked superseded does not count even when its digest is the case's", (got["status"], got["assessable"]), ("inconclusive", {}))
got = bar.bar([NEW], [dict((k, v) for k, v in r.items() if k != "case_digest") for r in fresh_], NONE)
is_("superseded_runs: a run that recorded no digest does not count", (got["status"], got["assessable"]), ("inconclusive", {}))

# the same through report: a state whose case gained a defect after its runs
S5 = os.path.join(ROOT, "state5")
shutil.copytree(STATE, S5, ignore=shutil.ignore_patterns("report.*"))
C.jsave(os.path.join(S5, "injected", "bc1.json"), dict(INJ, rounds=[{"k": 1}], build_check="ran again"))        # what a re-run of inject rewrites without changing an input
bar.cmd_report(Namespace(state=S5, dry_run=False))
same = C.jload(os.path.join(S5, "report.json"))
is_("superseded_runs: control: an injected record rewritten with the same inputs leaves the runs counted", (same["bar"]["status"], same["bar"]["superseded"]), ("fail", {}))
inv5 = C.jload(os.path.join(S5, "inventory", "bc1.json"))
inv5["defects"].append({"id": "t9", "class": "task", "severity": "P1", "counted": True, "summary": "a new per-task defect", "file": "f.py", "line": 9})
C.jsave(os.path.join(S5, "inventory", "bc1.json"), inv5)
cases5 = C.jload(os.path.join(S5, "cases.json"))
cases5["cases"][0]["defects"].append("t9")
C.jsave(os.path.join(S5, "cases.json"), cases5)
inj5 = C.jload(os.path.join(S5, "injected", "bc1.json"))
inj5["defects"]["t9"] = {"status": "present", "reason": ""}
C.jsave(os.path.join(S5, "injected", "bc1.json"), inj5)
bar.cmd_report(Namespace(state=S5, dry_run=False))
moved = C.jload(os.path.join(S5, "report.json"))
md5 = open(os.path.join(S5, "report.md")).read()
is_("superseded_runs: report: a case that gained an assessable defect after its runs is not judged by them", moved["bar"]["status"], "inconclusive")
is_("superseded_runs: report: the runs counted are none, and the report.json lists those set aside", (moved["cases"][0]["runs"], moved["cases"][0]["superseded"]),
    ([], ["alpha", "beta", "delta", "gamma"]))
ok("superseded_runs: report.md says how many runs were set aside, and which", "4 run(s) set aside as superseded, not counted" in md5 and "alpha, beta, delta, gamma" in md5
   and "case c1: 0 of 2 runs (4 more set aside" in md5, md5[:900])

# ---- failures
EMPTY = os.path.join(ROOT, "empty")
os.makedirs(EMPTY)
try:
    bar.cmd_report(Namespace(state=EMPTY, dry_run=False))
    ok("cmd_report: no cases.json is an error", False, "returned")
except C.Failed as e:
    ok("cmd_report: no cases.json is an error naming inject", "inject" in str(e), str(e))
