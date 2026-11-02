import calendar
import json
import os
import sys
import time
from argparse import Namespace

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import helpers
from helpers import git, is_, ok, put

helpers.setup()
from process_replay import common as C  # noqa: E402
from process_replay import planreview as P  # noqa: E402

ROOT = helpers.tmp_root()
PLAN_A = "docs/superpowers/plans/2026-10-a.md"
PLAN_B = "docs/superpowers/plans/2026-10-b.md"


def lines(prefix, n=100):
    return "".join("{}-{:03d}\n".format(prefix, i) for i in range(1, n + 1))


A1 = lines("a")
A2 = A1.replace("a-050\n", "a-050 +1\n")       # three bytes longer
B1 = lines("b")
B2 = B1.replace("b-005\n", "b-005 +1\n")


def stamp(base, offset):
    return calendar.timegm(time.strptime(base, "%Y-%m-%dT%H:%M:%S")) + offset


def iso(sec):
    return time.strftime("%Y-%m-%dT%H:%M:%S", time.gmtime(sec)) + ".{:03d}Z".format(int(round((sec % 1) * 1000)))


def timed_rollout(thread, turns):
    """A rollout whose records carry timestamps, as Codex's do: each turn dict is a helpers.rollout_lines
    turn plus start and end (epoch seconds); its records are spread evenly from start to end."""
    recs, total = [], 0
    for t in turns:
        more, total = helpers.rollout_lines(t, total)
        n = len(more)
        for i, r in enumerate(more):
            r["timestamp"] = iso(t["start"] + (t["end"] - t["start"]) * i / max(n - 1, 1))
        recs += more
    path = helpers.rollout_file(os.environ["CODEX_HOME"], thread)
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w") as f:
        f.write("".join(json.dumps(r) + "\n" for r in recs))


def finding(sev, file, line, summary):
    return {"severity": sev, "file": file, "line": line, "summary": summary, "failure_scenario": "when " + summary}


def answer(verdict, findings):
    return {"verdict": verdict, "findings": findings, "reviewed_files": []}


def plan_receipt(nonce, at, thread, turn, wt, base, tip, blobs=None, verdict="changes", branch=None):
    target = {"repo": wt, "branch": branch, "base": base, "tip": tip}
    if blobs is not None:
        target["plan_blobs"] = blobs
    return {"v": 2, "kind": "receipt", "checkpoint": "plan", "nonce": nonce, "dispatched_at": at, "verdict": verdict,
            "thread": thread, "turn": turn, "targets": [target], "clean": True}


def pre_receipt(nonce, at, wt, base, tip, plans_from, thread="thx", turn="tx"):
    return {"v": 2, "kind": "receipt", "checkpoint": "pre-merge", "nonce": nonce, "dispatched_at": at, "verdict": "approve",
            "thread": thread, "turn": turn, "clean": True,
            "targets": [{"repo": wt, "branch": "feat", "base": base, "tip": tip, "full": True, "dest": "main",
                         "plans_from": plans_from}]}


def blob(wt, rev, path):
    return git(wt, "rev-parse", "{}:{}".format(rev, path))


def world(name):
    """Fresh ledger home, Codex home and state, so a scenario sees only its own ledgers."""
    base = os.path.join(ROOT, name)
    os.environ["XDG_STATE_HOME"] = os.path.join(base, "xdg")
    os.environ["CODEX_HOME"] = os.path.join(base, "codex")
    os.makedirs(os.environ["XDG_STATE_HOME"])
    os.makedirs(os.environ["CODEX_HOME"])
    return os.path.join(base, "state")


def args(state, dry=False, root=None):
    return Namespace(state=state, dry_run=dry, snapshot_root=root or os.path.join(ROOT, "no-snapshot"))


def answers(state, kind, jid, doc):
    C.jsave(os.path.join(state, kind, jid + ".answer.json"), doc)


# ---------------------------------------------------------------- the repository
WT = helpers.make_repo(ROOT, "planrepo")
put(WT, "README.md", "readme\n")
BASE = helpers.commit(WT, "base")
put(WT, PLAN_A, A1)
C1 = helpers.commit(WT, "plan a")
put(WT, PLAN_B, B1)
C2 = helpers.commit(WT, "plan b")
put(WT, PLAN_A, A2)
C3 = helpers.commit(WT, "plan a, round 2")
put(WT, PLAN_B, B2)
C4 = helpers.commit(WT, "plan b, round 2")
A1B, A2B, B1B, B2B = (blob(WT, C1, PLAN_A), blob(WT, C3, PLAN_A), blob(WT, C2, PLAN_B), blob(WT, C4, PLAN_B))

# ---------------------------------------------------------------- scenario 1: one thread, two plans, null branch
STATE = world("w1")
T1 = "th-plan-1"
t0 = stamp("2026-10-10T10:00:00", 0)
timed_rollout(T1, [
    {"turn": "t1", "start": t0, "end": t0 + 600, "tokens": 5000, "answer": answer("changes", [
        finding("P1", PLAN_A, 50, "task 3 needs the helper that task 5 creates"),
        finding("P3", PLAN_A, 2, "typo"),
        finding("P2", "./" + PLAN_A, None, "no task covers the migration")])},
    {"turn": "t2", "start": t0 + 1800, "end": t0 + 2160, "tokens": 3000, "answer": answer("changes", [
        finding("P0", "b/" + PLAN_B, 5, "the plan cannot be satisfied as written"),
        finding("P3", PLAN_B, 9, "wording")])},
    {"turn": "t3", "start": t0 + 3600, "end": t0 + 3840, "tokens": 2000, "answer": answer("changes", [
        finding("P3", PLAN_A, 7, "style")])},
    {"turn": "t4", "start": t0 + 5400, "end": t0 + 5520, "tokens": 1000, "answer": answer("approve", [])},
])
timed_rollout("th-pre", [
    {"turn": "tx1", "start": t0, "end": t0 + 60, "tokens": 10000, "answer": answer("approve", [])},
    {"turn": "tx2", "start": t0 + 120, "end": t0 + 180, "tokens": 30000, "answer": answer("approve", [])},
    {"turn": "tx3", "start": t0 + 240, "end": t0 + 300, "tokens": 5000, "answer": answer("approve", [])},
    {"turn": "tx4", "start": t0 + 360, "end": t0 + 420, "tokens": 70000, "answer": answer("approve", [])}])
timed_rollout("th-pre-slices", [
    {"turn": "sl1", "start": t0, "end": t0 + 60, "tokens": 2000, "answer": answer("approve", [])},
    {"turn": "sl2", "start": t0 + 120, "end": t0 + 180, "tokens": 1000, "answer": answer("approve", [])}])
PRE2 = pre_receipt("p2", "2026-10-20T10:00:00.000000Z", WT, BASE, C4, [{"path": PLAN_A, "nonce": "n4", "blob": A2B}], "th-pre", "tx2")
# a sliced round: the receipt's turn and each slice's turn (one of them the receipt's own again)
PRE2["slice_turns"] = [{"thread": "th-pre", "turn": "tx2", "compacted": False}, {"thread": "th-pre-slices", "turn": "sl1", "compacted": False},
                       {"thread": "th-pre-slices", "turn": "sl2", "compacted": False}]
PRE1 = pre_receipt("p1", "2026-10-15T10:00:00.000000Z", WT, BASE, C4,
                   [{"path": PLAN_A, "nonce": "n4", "blob": A2B}, {"path": PLAN_B, "nonce": "n4", "blob": B1B}], "th-pre", "tx1")
helpers.write_ledger(os.environ["XDG_STATE_HOME"], WT, [
    # r1 carries no plan_blobs: derived from git, as old receipts are
    plan_receipt("n1", "2026-10-10T10:00:00.000000Z", T1, "t1", WT, BASE, C1),
    plan_receipt("n2", "2026-10-10T10:30:00.000000Z", T1, "t2", WT, C1, C2, {PLAN_B: B1B}),
    plan_receipt("n3", "2026-10-10T11:00:00.000000Z", T1, "t3", WT, BASE, C3, {PLAN_A: A2B, PLAN_B: B1B}),
    plan_receipt("n4", "2026-10-10T11:30:00.000000Z", T1, "t4", WT, BASE, C4, {PLAN_A: A2B, PLAN_B: B2B}, verdict="approve"),
    # outside October: not rounds
    plan_receipt("n6", "2026-11-01T00:00:00.000000Z", "th-out", "x1", WT, BASE, C1, {PLAN_A: A1B}),
    plan_receipt("n7", "2026-09-30T23:59:59.000000Z", "th-out", "x0", WT, BASE, C1, {PLAN_A: A1B}),
    PRE1,
    dict(PRE1),     # the same receipt twice: counted once
    PRE2,
    pre_receipt("p3", "2026-10-21T10:00:00.000000Z", WT, BASE, C4, [], "th-pre", "tx3"),
    pre_receipt("p4", "2026-11-02T00:00:00.000000Z", WT, BASE, C4, [{"path": PLAN_A, "nonce": "n4", "blob": A2B}], "th-pre", "tx4"),
])

ok("control: the fixture's A and B really differ by the sizes the totals below rest on",
   (len(A2), len(B1)) == (603, 600) and (2 * len(A2) + len(B1)) / 3.5 == 516.0)

# ---- dry run: judge inputs and briefs only
DRY = os.path.join(ROOT, "w1", "dry")
os.environ["XDG_STATE_HOME"], os.environ["CODEX_HOME"] = os.path.join(ROOT, "w1", "xdg"), os.path.join(ROOT, "w1", "codex")
is_("dry_run: returns 0", P.plan_cases(args(DRY, dry=True)), 0)
written = sorted(os.path.relpath(os.path.join(d, f), DRY) for d, _s, fs in os.walk(DRY) for f in fs
                 if not os.sep + "views" + os.sep in os.path.join(d, f) and not f.endswith("alias"))
ok("dry_run: nothing but judge inputs and briefs", bool(written) and all(w.startswith("judge") for w in written), written)
ok("dry_run: no plan-cases.json", not os.path.exists(os.path.join(DRY, "plan-cases.json")))
ok("dry_run: the briefs include judge-class's", os.path.isfile(os.path.join(DRY, "judges", "judge-class.md")))
is_("dry_run: no judge-class input before any answer", [w for w in written if w.startswith("judge-class")], [])
dry_known = C.jload(os.path.join(DRY, "judge-known", "plan-n1.json"))

# ---- rounds_per_plan_file
is_("rounds_per_plan_file: plan_cases returns 0", P.plan_cases(args(STATE)), 0)
doc = C.jload(os.path.join(STATE, "plan-cases.json"))
by = {r["nonce"]: r for r in doc["rounds"]}
is_("rounds_per_plan_file: the four October rounds are the rounds (the Nov 1 and Sep 30 receipts are not)", sorted(by), ["n1", "n2", "n3", "n4"])
is_("rounds_per_plan_file: r1 (plan A) goes to r3, the next round that changes A, not to r2 (plan B)", by["n1"]["next"], "n3")
is_("rounds_per_plan_file: r2 (plan B) goes to r4: r3 lists B unchanged, so it does not change B", by["n2"]["next"], "n4")
is_("rounds_per_plan_file: r3 changes B at r4", by["n3"]["next"], "n4")
is_("rounds_per_plan_file: the last round has none", by["n4"]["next"], None)
is_("rounds_per_plan_file: r1's plan_blobs were derived from git", by["n1"]["plans"], [PLAN_A])
is_("rounds_per_plan_file: r3 lists both plans", by["n3"]["plans"], [PLAN_A, PLAN_B])

# ---- judge_inputs
kinds = sorted((k, j) for k, j, *_ in C.pending(STATE))
is_("judge_inputs: one judge-known per round that has a next round and a P0-P2 finding (r3 has only P3, r4 no next)", kinds,
    [("judge-known", "plan-n1"), ("judge-known", "plan-n2")])
k1 = C.jload(os.path.join(STATE, "judge-known", "plan-n1.json"))
is_("dry_run: a dry run's judge-known input is the real run's, content for content", dry_known, k1)
is_("judge_inputs: the case is the round's nonce", k1["case"], "n1")
ok("judge_inputs: each finding has exactly xreview-replay's keys (no plan mapping leaks to the judge)",
   all(set(f) == {"index", "severity", "file", "line", "summary", "failure_scenario"} for f in k1["findings"]), k1["findings"])
is_("judge_inputs: P0-P2 findings only, with fresh indices", [(f["index"], f["severity"], f["line"]) for f in k1["findings"]],
    [(0, "P1", 50), (1, "P2", None)])
ok("judge_inputs: the interdiff is the plan's change from tip to next tip", "+a-050 +1" in k1["interdiff"] and "-a-050\n" in k1["interdiff"], k1["interdiff"][:300])
ok("judge_inputs: and leaves out the other plan, added between the two tips", "b-001" not in k1["interdiff"] and PLAN_B not in k1["interdiff"], k1["interdiff"][:300])
k2 = C.jload(os.path.join(STATE, "judge-known", "plan-n2.json"))
ok("judge_inputs: r2's interdiff holds plan B's change, not plan A's from the commit between",
   "+b-005 +1" in k2["interdiff"] and PLAN_A not in k2["interdiff"], k2["interdiff"][:300])
is_("judge_inputs: no class inputs before the answers", [k for k, _j in kinds if k == "judge-class"], [])

# ---- stale_results: the report reads the judges' answers live, and says what is missing
lines0, rep0 = P.report_section(STATE)
is_("stale_results: two rounds await judge-known, nothing is known yet", (rep0["pending_known"], rep0["known"], rep0["incomplete"]), (2, 0, True))
ok("stale_results: the recommendation is incomplete, never the no-design wording",
   "  recommendation: inconclusive (classification incomplete)" in lines0 and not any("no design-class" in l for l in lines0), lines0)
ok("stale_results: the pending line counts what waits", any("2 round(s) awaiting judge-known" in l for l in lines0), lines0)
answers(STATE, "judge-known", "plan-n1", {"verdicts": [{"index": 0, "answer": "yes"}, {"index": 1, "answer": "yes"}]})
answers(STATE, "judge-known", "plan-n2", {"verdicts": [{"index": 0, "answer": "yes"}]})
lines1, rep1 = P.report_section(STATE)
is_("stale_results: after the answers, without cases --plans again: known 3, none has a class input",
    (rep1["pending_known"], rep1["known"], rep1["no_input"], rep1["classified"], rep1["incomplete"]), (0, 3, 3, 0, True))
ok("stale_results: still incomplete, and it says to run cases --plans again",
   "  recommendation: inconclusive (classification incomplete)" in lines1 and any("without a judge-class input" in l for l in lines1), lines1)
P.plan_cases(args(STATE))
cls = sorted(j for k, j, *_ in C.pending(STATE) if k == "judge-class")
is_("judge_inputs: after yes answers, one judge-class per known-real finding", cls, ["plan-n1-0", "plan-n1-1", "plan-n2-0"])
c0 = C.jload(os.path.join(STATE, "judge-class", "plan-n1-0.json"))
is_("judge_inputs: the excerpt is 40 lines either side of line 50, from the plan the round reviewed",
    c0["plan_excerpt"], "".join(A1.splitlines(True)[9:90]))
ok("judge_inputs: the finding is carried, without the judge's own bookkeeping",
   c0["finding"]["summary"] == "task 3 needs the helper that task 5 creates" and c0["finding"]["line"] == 50 and set(c0) == {"finding", "plan_excerpt", "fix"}, c0)
ok("judge_inputs: the fix is that plan's change", "+a-050 +1" in c0["fix"] and PLAN_B not in c0["fix"], c0["fix"][:200])
c1 = C.jload(os.path.join(STATE, "judge-class", "plan-n1-1.json"))
is_("judge_inputs: line null gives the whole plan (the finding's path written ./x still finds it)", c1["plan_excerpt"], A1)
c2 = C.jload(os.path.join(STATE, "judge-class", "plan-n2-0.json"))
is_("judge_inputs: near the top the excerpt starts at line 1 (a path written b/x too)", c2["plan_excerpt"], "".join(B1.splitlines(True)[0:45]))
ok("judge_inputs: r2's fix is plan B's change", "+b-005 +1" in c2["fix"] and PLAN_A not in c2["fix"], c2["fix"][:200])
ok("judge_inputs: each answer's input is a plain judge file, written through judge_write",
   all(os.path.isfile(os.path.join(STATE, "judge-class", j + ".json")) for j in cls))

# ---- report_section
lines_, rep = P.report_section(STATE)
is_("report_section: before the class answers, nothing is classified", (rep["known"], rep["classified"], rep["pending"], rep["pending_class"]), (3, 0, 3, 3))
is_("report_section: so no design P0/P1, and inconclusive, never remove", (rep["design_p0p1"], rep["recommendation"], rep["incomplete"]), (0, "inconclusive", True))
answers(STATE, "judge-class", "plan-n1-0", {"class": "design"})
answers(STATE, "judge-class", "plan-n1-1", {"class": "diff-visible"})
answers(STATE, "judge-class", "plan-n2-0", {"class": "design"})
lines_, rep = P.report_section(STATE)
is_("report_section: rounds", rep["rounds"], 4)
is_("report_section: wall minutes, first to last record of each round's turn", rep["wall_minutes"], 22.0)
is_("report_section: Codex tokens", rep["tokens"], 11000)
is_("report_section: known-real findings, all classified", (rep["known"], rep["classified"], rep["pending"]), (3, 3, 0))
is_("report_section: findings by class and severity", rep["classes"],
    {"diff-visible": {"P0": 0, "P1": 0, "P2": 1}, "design": {"P0": 1, "P1": 1, "P2": 0}, "plan-only": {"P0": 0, "P1": 0, "P2": 0}})
is_("report_section: design-class P0/P1", rep["design_p0p1"], 2)
is_("report_section: wall minutes per design-class P0/P1", rep["minutes_per_design"], 11.0)
is_("report_section: Codex tokens per design-class P0/P1", rep["tokens_per_design"], 5500.0)
is_("report_section: the lost omit_plans saving is the in-October plans_from blob bytes over 3.5", rep["lost_saving_tokens"], 516.0)
is_("report_section: (b) packets 9's measure: 19% of the tokens of every turn of the pre-merge rounds that omitted a plan "
    "(10000 + 30000 + the slices' 2000 and 1000; the repeated tx2 and the duplicate receipt count once)",
    (rep["premerge_omit_tokens"], rep["lost_saving_measured_tokens"]), (43000, 8170.0))
is_("report_section: net of plan review (11000 tokens), by (a) and by (b)", (rep["net_tokens_lower"], rep["net_tokens_measured"]), (10484.0, 2830.0))
is_("report_section: from 3 October pre-merge receipts (the repeated one counted once), 2 listing plans",
    (rep["premerge_receipts"], rep["premerge_with_plans"]), (3, 2))
is_("report_section: complete when every answer is in", rep["incomplete"], False)
is_("report_section: a design-class P0/P1 means keep", rep["recommendation"], "keep")
text = "\n".join(lines_)
ok("report_section: the text states the recommendation, the cost and the lost saving",
   "keep" in text and "516" in text and "11.0" in text and "5500" in text, text)
ok("report_section: gives both estimates and their nets", "(a) lower bound" in text and "(b) packets 9" in text and "10484" in text
   and "2830" in text and "8170" in text and "plan-review wall minutes 22.0" in text, text)
ok("report_section: warns that per-plan rows can sum above the totals", "credited to every plan it lists" in text, text)
ok("report_section: lists the plans", PLAN_A in text and PLAN_B in text, text)
by_plan = {(p["plan"]): p for p in rep["plans"]}
is_("report_section: per plan, rounds", (by_plan[PLAN_A]["rounds"], by_plan[PLAN_B]["rounds"]), (3, 3))
is_("report_section: per plan, design P0/P1", (by_plan[PLAN_A]["design_p0p1"], by_plan[PLAN_B]["design_p0p1"]), (1, 1))
is_("report_section: per plan, findings by class and severity",
    (by_plan[PLAN_A]["classes"], by_plan[PLAN_B]["classes"]),
    ({"diff-visible": {"P0": 0, "P1": 0, "P2": 1}, "design": {"P0": 0, "P1": 1, "P2": 0}, "plan-only": {"P0": 0, "P1": 0, "P2": 0}},
     {"diff-visible": {"P0": 0, "P1": 0, "P2": 0}, "design": {"P0": 1, "P1": 0, "P2": 0}, "plan-only": {"P0": 0, "P1": 0, "P2": 0}}))
is_("report_section: per plan, cost per design-class P0/P1 (A: 16 min and 8000 tokens over 1; B: 12 min and 6000 over 1)",
    (by_plan[PLAN_A]["minutes_per_design"], by_plan[PLAN_A]["tokens_per_design"], by_plan[PLAN_B]["minutes_per_design"], by_plan[PLAN_B]["tokens_per_design"]),
    (16.0, 8000.0, 12.0, 6000.0))

answers(STATE, "judge-class", "plan-n1-0", {"class": "plan-only"})
answers(STATE, "judge-class", "plan-n2-0", {"class": "diff-visible"})
_l, rep2 = P.report_section(STATE)
is_("report_section: with no design-class P0/P1 the recommendation is inconclusive, never remove",
    (rep2["design_p0p1"], rep2["recommendation"], rep2["minutes_per_design"], rep2["tokens_per_design"]), (0, "inconclusive", None, None))
ok("report_section: and, with everything classified, says why (the no-design wording appears only now)",
   any("inconclusive (no design-class P0/P1" in l for l in _l) and not rep2["incomplete"], _l)
answers(STATE, "judge-class", "plan-n2-0", {"class": "design"})
answers(STATE, "judge-class", "plan-n1-0", {"class": "bogus"})
_l, rep3 = P.report_section(STATE)
is_("report_section: an answer outside the three classes stays pending", (rep3["classified"], rep3["pending"], rep3["design_p0p1"]), (2, 1, 1))
ok("report_section: and a design P0/P1 already found still says keep, noting the rest is incomplete",
   rep3["recommendation"] == "keep" and rep3["incomplete"] and any("keep" in l and "incomplete" in l for l in _l), _l)
is_("report_section: no state, no output", P.report_section(os.path.join(ROOT, "nowhere")), ([], {}))

# ---------------------------------------------------------------- scenario 2: no plan rounds at all
STATE2 = world("w2")
helpers.write_ledger(os.environ["XDG_STATE_HOME"], WT, [pre_receipt("q1", "2026-10-15T10:00:00.000000Z", WT, BASE, C4, [])])
P.plan_cases(args(STATE2))
is_("no_plan_cases: nothing to report", P.report_section(STATE2), ([], {}))
ok("no_plan_cases: no judge input", not C.pending(STATE2))

# ---------------------------------------------------------------- scenario 3: commits that survive only in the snapshot
STATE3 = world("w3")
SNAP = os.path.join(ROOT, "w3", "snapshot")
os.makedirs(os.path.join(SNAP, "planrepo"))
import shutil  # noqa: E402
shutil.copytree(os.path.join(WT, ".git", "objects"), os.path.join(SNAP, "planrepo", "objects"))
EMPTY_PARENT = os.path.join(ROOT, "w3", "orig")
os.makedirs(EMPTY_PARENT)
ORIG = helpers.make_repo(EMPTY_PARENT, "planrepo")   # same name, no commits of the plan
put(ORIG, "README.md", "readme\n")
helpers.commit(ORIG, "unrelated")
ok("snapshot_only: control: the original does not have the plan commits", not helpers.git_ok(ORIG, "cat-file", "-e", C3))
T3 = "th-plan-3"
timed_rollout(T3, [
    {"turn": "u1", "start": t0, "end": t0 + 60, "answer": answer("changes", [finding("P1", PLAN_A, 50, "snap finding")])},
    {"turn": "u2", "start": t0 + 120, "end": t0 + 180, "answer": answer("approve", [])}])
helpers.write_ledger(os.environ["XDG_STATE_HOME"], ORIG, [
    plan_receipt("s1", "2026-10-12T10:00:00.000000Z", T3, "u1", ORIG, BASE, C1),   # no plan_blobs: derived through the snapshot view
    plan_receipt("s2", "2026-10-12T11:00:00.000000Z", T3, "u2", ORIG, BASE, C3, {PLAN_A: A2B}, verdict="approve"),
    pre_receipt("sp", "2026-10-13T10:00:00.000000Z", ORIG, BASE, C3, [{"path": PLAN_A, "nonce": "s2", "blob": A2B}])])
P.plan_cases(args(STATE3, root=SNAP))
ks = C.jload(os.path.join(STATE3, "judge-known", "plan-s1.json"))
ok("snapshot_only: a receipt without plan_blobs gets them from the snapshot (its next round is found), the interdiff too",
   ks and "+a-050 +1" in ks["interdiff"], ks)
is_("snapshot_only: nothing skipped", C.jload(os.path.join(STATE3, "plan-cases.json"))["skips"], [])
answers(STATE3, "judge-known", "plan-s1", {"verdicts": [{"index": 0, "answer": "yes"}]})
P.plan_cases(args(STATE3, root=SNAP))
cs = C.jload(os.path.join(STATE3, "judge-class", "plan-s1-0.json"))
ok("snapshot_only: and so is the plan text", cs and cs["plan_excerpt"] == "".join(A1.splitlines(True)[9:90]), cs)
_l, rs = P.report_section(STATE3)
is_("snapshot_only: the lost saving counts the blob read through the view", rs["lost_saving_tokens"], 603 / 3.5)

# ---------------------------------------------------------------- scenario 4: a round whose commits are gone is skipped, not guessed
STATE4 = world("w4")
T4 = "th-plan-4"
timed_rollout(T4, [
    {"turn": "v1", "start": t0, "end": t0 + 60, "answer": answer("changes", [finding("P1", PLAN_A, 50, "lost")])},
    {"turn": "v2", "start": t0 + 120, "end": t0 + 180, "answer": answer("approve", [])}])
gone = "f" * 40
helpers.write_ledger(os.environ["XDG_STATE_HOME"], WT, [
    plan_receipt("g1", "2026-10-12T10:00:00.000000Z", T4, "v1", WT, BASE, C1, {PLAN_A: A1B}),
    plan_receipt("g2", "2026-10-12T11:00:00.000000Z", T4, "v2", WT, BASE, gone, {PLAN_A: A2B}, verdict="approve"),
    # no plan_blobs and a tip that cannot be read: the derivation fails
    plan_receipt("g3", "2026-10-12T12:00:00.000000Z", "th-plan-4b", "w1", WT, BASE, gone)])
P.plan_cases(args(STATE4))
ok("missing_commits: no judge input is written for a round whose next tip cannot be read", not C.pending(STATE4), C.pending(STATE4))
d4 = C.jload(os.path.join(STATE4, "plan-cases.json"))
is_("missing_commits: both are skipped as rounds, each with its reason",
    sorted((s["kind"], s["nonce"], s["reason"].split(":")[0]) for s in d4["skips"]),
    [("round", "g1", "the next round's tip cannot be read, or does not follow this tip"), ("round", "g3", "plan blobs not derivable")])
ln4, rep4 = P.report_section(STATE4)
is_("missing_commits: the report counts skipped rounds apart from findings, and is incomplete",
    (rep4["skipped_rounds"], rep4["skipped_findings"], rep4["incomplete"]), (2, 0, True))
ok("missing_commits: and prints each skip with its reason", sum(1 for l in ln4 if l.startswith("  skipped round")) == 2, ln4)

# ---------------------------------------------------------------- scenario 5: a next round after October; a finding naming no plan
STATE5 = world("w5")
T5 = "th-plan-5"
timed_rollout(T5, [
    {"turn": "m1", "start": t0, "end": t0 + 300, "tokens": 700, "answer": answer("changes", [finding("P1", "src/x.py", 3, "names no plan")])},
    {"turn": "m2", "start": t0 + 600, "end": t0 + 660, "tokens": 100, "answer": answer("approve", [])}])
helpers.write_ledger(os.environ["XDG_STATE_HOME"], WT, [
    plan_receipt("m1", "2026-10-31T23:00:00.000000Z", T5, "m1", WT, BASE, C3, {PLAN_A: A2B, PLAN_B: B1B}),
    plan_receipt("m2", "2026-11-03T10:00:00.000000Z", T5, "m2", WT, BASE, C4, {PLAN_A: A2B, PLAN_B: B2B}, verdict="approve")])
P.plan_cases(args(STATE5))
d5 = C.jload(os.path.join(STATE5, "plan-cases.json"))
is_("next_after_october: only the October round is a round, and its next round may be in November",
    [(r["nonce"], r["next"]) for r in d5["rounds"]], [("m1", "m2")])
answers(STATE5, "judge-known", "plan-m1", {"verdicts": [{"index": 0, "answer": "yes"}]})
P.plan_cases(args(STATE5))
c5 = C.jload(os.path.join(STATE5, "judge-class", "plan-m1-0.json"))
ok("unattributed: a file that names neither plan of a two-plan round gets both, labelled",
   c5["plan_excerpt"].startswith("== {} ==\n".format(PLAN_A)) and "== {} ==\n".format(PLAN_B) in c5["plan_excerpt"], c5["plan_excerpt"][:120])
answers(STATE5, "judge-class", "plan-m1-0", {"class": "design"})
_l, rep5 = P.report_section(STATE5)
is_("unattributed: credited to an (unattributed) row, not to the alphabetically first plan",
    sorted((p["plan"], p["known"], p["design_p0p1"]) for p in rep5["plans"]),
    sorted([(PLAN_A, 0, 0), (PLAN_B, 0, 0), ("(unattributed)", 1, 1)]))
un = next(p for p in rep5["plans"] if p["plan"] == "(unattributed)")
is_("unattributed: it has no rounds, so its cost per design-class P0/P1 is n/a, not a free catch",
    (un["rounds"], un["design_p0p1"], un["minutes_per_design"], un["tokens_per_design"]), (0, 1, None, None))
ok("unattributed: and the report prints n/a for it", any("(unattributed)" in l and "per one: n/a min, n/a tokens" in l for l in _l), _l)
is_("next_after_october: the November round costs nothing here", (rep5["rounds"], rep5["tokens"]), (1, 700))

# ---------------------------------------------------------------- scenario 6: a known finding whose plan text cannot be read
STATE6 = world("w6")
T6 = "th-plan-6"
timed_rollout(T6, [
    {"turn": "k1", "start": t0, "end": t0 + 60, "answer": answer("changes", [finding("P1", PLAN_A, 50, "plan blob missing")])},
    {"turn": "k2", "start": t0 + 120, "end": t0 + 180, "answer": answer("approve", [])}])
helpers.write_ledger(os.environ["XDG_STATE_HOME"], WT, [
    plan_receipt("k1", "2026-10-12T10:00:00.000000Z", T6, "k1", WT, BASE, C1, {PLAN_A: "e" * 40}),
    plan_receipt("k2", "2026-10-12T11:00:00.000000Z", T6, "k2", WT, BASE, C3, {PLAN_A: A2B}, verdict="approve")])
P.plan_cases(args(STATE6))
answers(STATE6, "judge-known", "plan-k1", {"verdicts": [{"index": 0, "answer": "yes"}]})
P.plan_cases(args(STATE6))
d6 = C.jload(os.path.join(STATE6, "plan-cases.json"))
is_("unreadable_plan: the finding is skipped as a finding, with a reason, and no judge-class input is written",
    ([(s["kind"], s["nonce"], s["index"], s["reason"]) for s in d6["skips"]], os.path.exists(os.path.join(STATE6, "judge-class"))),
    ([("finding", "k1", 0, "the plan text cannot be read")], False))
ln6, rep6 = P.report_section(STATE6)
is_("unreadable_plan: the report calls it not sent to a judge, not an unanswered one",
    (rep6["known"], rep6["unclassifiable"], rep6["pending_class"], rep6["no_input"], rep6["skipped_findings"], rep6["skipped_rounds"], rep6["incomplete"]),
    (1, 1, 0, 0, 1, 0, True))
ok("unreadable_plan: and so says the pending line", any("1 not sent to a judge" in l and "0 awaiting a class" in l for l in ln6), ln6)

# ---------------------------------------------------------------- scenario 7: a single-plan round credits a finding that names no plan to that plan
STATE7 = world("w7")
T7 = "th-plan-7"
timed_rollout(T7, [
    {"turn": "j1", "start": t0, "end": t0 + 60, "tokens": 100, "answer": answer("changes", [finding("P1", "src/x.py", 3, "names no plan")])},
    {"turn": "j2", "start": t0 + 120, "end": t0 + 180, "tokens": 100, "answer": answer("approve", [])}])
helpers.write_ledger(os.environ["XDG_STATE_HOME"], WT, [
    plan_receipt("j1", "2026-10-12T10:00:00.000000Z", T7, "j1", WT, BASE, C1, {PLAN_A: A1B}),
    plan_receipt("j2", "2026-10-12T11:00:00.000000Z", T7, "j2", WT, BASE, C3, {PLAN_A: A2B}, verdict="approve")])
P.plan_cases(args(STATE7))
answers(STATE7, "judge-known", "plan-j1", {"verdicts": [{"index": 0, "answer": "yes"}]})
P.plan_cases(args(STATE7))
c7 = C.jload(os.path.join(STATE7, "judge-class", "plan-j1-0.json"))
is_("single_plan: the excerpt is the round's only plan (line 3 of it)", c7["plan_excerpt"], "".join(A1.splitlines(True)[0:43]))
answers(STATE7, "judge-class", "plan-j1-0", {"class": "design"})
_l, rep7 = P.report_section(STATE7)
is_("single_plan: the finding is credited to that plan, not to (unattributed)",
    [(p["plan"], p["known"], p["design_p0p1"]) for p in rep7["plans"]], [(PLAN_A, 1, 1)])
