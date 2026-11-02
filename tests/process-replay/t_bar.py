import json
import os
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
            "original_rounds": rounds, "work_commit": "w", "info": info}


def run(cid, label, states, end="approve", codex=2, **more):
    reviews = [{"id": label + "-0", "kind": "final", "k": 0, "findings": [], "verdict": "report", "tokens": 0, "turns": 0, "model": None, "effort": None}]
    reviews += [{"id": "{}-{}".format(label, k), "kind": "codex", "k": k, "findings": [], "verdict": "revise", "tokens": 1000, "turns": 1,
                 "model": "gpt-x", "effort": "high"} for k in range(1, codex + 1)]
    r = {"case": cid, "label": label, "scratch": "/s", "thread": "t", "round": codex, "step": "done", "reviews": reviews, "defects": dict(states),
         "rejected": [], "addressed": [], "outside": [], "ledger": None, "end": end, "voids": 0, "tokens": 1000 * codex}
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
    ("coverage_gate: a fail stays a fail", [BASE], two("c1", sts(t1="u", t2="r", q1="r", q2="r")), HELD, "fail"),
    ("a void run with no replacement is not assessable: no pass", [BASE], [run("c1", "a", ALL_R), run("c1", "b", sts(t1="p", t2="p", q1="p", q2="p"), end="void", voids=2)],
     NONE, "inconclusive"),
    ("an errored run is not assessable: no pass", [BASE], [run("c1", "a", ALL_R), run("c1", "b", ALL_R, end="error")], NONE, "inconclusive"),
    ("a run still going is not assessable", [BASE], [run("c1", "a", ALL_R), run("c1", "b", sts(t1="p", t2="p", q1="p", q2="p"), end=None, step="codex")], NONE, "inconclusive"),
    ("a case with one run of two is incomplete: no pass", [BASE], [run("c1", "a", ALL_R)], NONE, "inconclusive"),
    ("a voided run replaced by a re-run counts the re-run only", [BASE],
     [run("c1", "a", ALL_R), run("c1", "b", sts(t1="p", t2="p", q1="p", q2="p"), end="void", voids=1, replaced_by="b2", leak=["x"]),
      run("c1", "b2", ALL_R, voids=1, replaces="b")], NONE, "pass"),
    ("no cases: inconclusive", [], [], NONE, "inconclusive"),
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
for r in RUNS:
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
        ("a negative or zero extra", "+1"),
        ("Codex tokens of the run", "4000"),
        ("model and effort", "gpt-x"),
        ("the effort", "high"),
        ("the end of a run", "stalled"),
        ("a void and its re-run", "gamma"),
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
ok("report.md: no plan section without plan cases", "Plan-review checkpoint" not in md)

# ---- the plan-checkpoint section, when plan-cases.json has a round
C.jsave(os.path.join(STATE, "plan-cases.json"), {"rounds": [
    {"nonce": "n1", "at": "2026-10-10T10:00:00Z", "repo": "/repo/c1", "plans": ["docs/superpowers/plans/p.md"], "thread": "th", "turn": "tu", "verdict": "revise",
     "minutes": 12.0, "tokens": 7777, "next": None, "asked": False, "plan_of": {}, "findings": []}], "skips": [], "lost_saving": {}})
bar.cmd_report(args)
md = open(os.path.join(STATE, "report.md")).read()
rep = C.jload(os.path.join(STATE, "report.json"))
ok("report.md: the plan-checkpoint section is included when there are rounds", "Plan-review checkpoint" in md and "7777" in md, md[-600:])
ok("report.json: and its data", isinstance(rep.get("planreview"), dict) and rep["planreview"]["rounds"] == 1, rep.get("planreview"))

# ---- failures
EMPTY = os.path.join(ROOT, "empty")
os.makedirs(EMPTY)
try:
    bar.cmd_report(Namespace(state=EMPTY, dry_run=False))
    ok("cmd_report: no cases.json is an error", False, "returned")
except C.Failed as e:
    ok("cmd_report: no cases.json is an error naming inject", "inject" in str(e), str(e))
