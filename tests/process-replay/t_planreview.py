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


def pre_receipt(nonce, at, wt, base, tip, plans_from):
    return {"v": 2, "kind": "receipt", "checkpoint": "pre-merge", "nonce": nonce, "dispatched_at": at, "verdict": "approve",
            "thread": "thx", "turn": "tx", "clean": True,
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
helpers.write_ledger(os.environ["XDG_STATE_HOME"], WT, [
    # r1 carries no plan_blobs: derived from git, as old receipts are
    plan_receipt("n1", "2026-10-10T10:00:00.000000Z", T1, "t1", WT, BASE, C1),
    plan_receipt("n2", "2026-10-10T10:30:00.000000Z", T1, "t2", WT, C1, C2, {PLAN_B: B1B}),
    plan_receipt("n3", "2026-10-10T11:00:00.000000Z", T1, "t3", WT, BASE, C3, {PLAN_A: A2B, PLAN_B: B1B}),
    plan_receipt("n4", "2026-10-10T11:30:00.000000Z", T1, "t4", WT, BASE, C4, {PLAN_A: A2B, PLAN_B: B2B}, verdict="approve"),
    # outside October: not rounds
    plan_receipt("n6", "2026-11-01T00:00:00.000000Z", "th-out", "x1", WT, BASE, C1, {PLAN_A: A1B}),
    plan_receipt("n7", "2026-09-30T23:59:59.000000Z", "th-out", "x0", WT, BASE, C1, {PLAN_A: A1B}),
    pre_receipt("p1", "2026-10-15T10:00:00.000000Z", WT, BASE, C4,
                [{"path": PLAN_A, "nonce": "n4", "blob": A2B}, {"path": PLAN_B, "nonce": "n4", "blob": B1B}]),
    pre_receipt("p2", "2026-10-20T10:00:00.000000Z", WT, BASE, C4, [{"path": PLAN_A, "nonce": "n4", "blob": A2B}]),
    pre_receipt("p3", "2026-10-21T10:00:00.000000Z", WT, BASE, C4, []),
    pre_receipt("p4", "2026-11-02T00:00:00.000000Z", WT, BASE, C4, [{"path": PLAN_A, "nonce": "n4", "blob": A2B}]),
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
is_("judge_inputs: the case is the round's nonce", k1["case"], "n1")
is_("judge_inputs: P0-P2 findings only, with fresh indices", [(f["index"], f["severity"], f["line"]) for f in k1["findings"]],
    [(0, "P1", 50), (1, "P2", None)])
ok("judge_inputs: the interdiff is the plan's change from tip to next tip", "+a-050 +1" in k1["interdiff"] and "-a-050\n" in k1["interdiff"], k1["interdiff"][:300])
ok("judge_inputs: and leaves out the other plan, added between the two tips", "b-001" not in k1["interdiff"] and PLAN_B not in k1["interdiff"], k1["interdiff"][:300])
k2 = C.jload(os.path.join(STATE, "judge-known", "plan-n2.json"))
ok("judge_inputs: r2's interdiff holds plan B's change, not plan A's from the commit between",
   "+b-005 +1" in k2["interdiff"] and PLAN_A not in k2["interdiff"], k2["interdiff"][:300])
is_("judge_inputs: no class inputs before the answers", [k for k, _j in kinds if k == "judge-class"], [])
answers(STATE, "judge-known", "plan-n1", {"verdicts": [{"index": 0, "answer": "yes"}, {"index": 1, "answer": "yes"}]})
answers(STATE, "judge-known", "plan-n2", {"verdicts": [{"index": 0, "answer": "yes"}]})
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
is_("report_section: before the class answers, nothing is classified", (rep["known"], rep["classified"], rep["pending"]), (3, 0, 3))
is_("report_section: so no design P0/P1, and inconclusive, never remove", (rep["design_p0p1"], rep["recommendation"]), (0, "inconclusive"))
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
is_("report_section: from 3 October pre-merge receipts, 2 listing plans", (rep["premerge_receipts"], rep["premerge_with_plans"]), (3, 2))
is_("report_section: a design-class P0/P1 means keep", rep["recommendation"], "keep")
text = "\n".join(lines_)
ok("report_section: the text states the recommendation, the cost and the lost saving",
   "keep" in text and "516" in text and "11.0" in text and "5500" in text, text)
ok("report_section: lists the plans", PLAN_A in text and PLAN_B in text, text)
by_plan = {(p["plan"]): p for p in rep["plans"]}
is_("report_section: per plan, rounds", (by_plan[PLAN_A]["rounds"], by_plan[PLAN_B]["rounds"]), (3, 3))
is_("report_section: per plan, design P0/P1", (by_plan[PLAN_A]["design_p0p1"], by_plan[PLAN_B]["design_p0p1"]), (1, 1))

answers(STATE, "judge-class", "plan-n1-0", {"class": "plan-only"})
answers(STATE, "judge-class", "plan-n2-0", {"class": "diff-visible"})
_l, rep2 = P.report_section(STATE)
is_("report_section: with no design-class P0/P1 the recommendation is inconclusive, never remove",
    (rep2["design_p0p1"], rep2["recommendation"], rep2["minutes_per_design"], rep2["tokens_per_design"]), (0, "inconclusive", None, None))
answers(STATE, "judge-class", "plan-n2-0", {"class": "design"})
answers(STATE, "judge-class", "plan-n1-0", {"class": "bogus"})
_l, rep3 = P.report_section(STATE)
is_("report_section: an answer outside the three classes stays pending", (rep3["classified"], rep3["pending"], rep3["design_p0p1"]), (2, 1, 1))
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
    plan_receipt("s1", "2026-10-12T10:00:00.000000Z", T3, "u1", ORIG, BASE, C1, {PLAN_A: A1B}),
    plan_receipt("s2", "2026-10-12T11:00:00.000000Z", T3, "u2", ORIG, BASE, C3, {PLAN_A: A2B}, verdict="approve"),
    pre_receipt("sp", "2026-10-13T10:00:00.000000Z", ORIG, BASE, C3, [{"path": PLAN_A, "nonce": "s2", "blob": A2B}])])
P.plan_cases(args(STATE3, root=SNAP))
ks = C.jload(os.path.join(STATE3, "judge-known", "plan-s1.json"))
ok("snapshot_only: the interdiff is read through the snapshot view", ks and "+a-050 +1" in ks["interdiff"], ks)
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
    plan_receipt("g2", "2026-10-12T11:00:00.000000Z", T4, "v2", WT, BASE, gone, {PLAN_A: A2B}, verdict="approve")])
P.plan_cases(args(STATE4))
ok("missing_commits: no judge input is written for a round whose next tip cannot be read", not C.pending(STATE4), C.pending(STATE4))
d4 = C.jload(os.path.join(STATE4, "plan-cases.json"))
is_("missing_commits: it is counted as skipped", d4["skipped"], 1)
