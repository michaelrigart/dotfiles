import hashlib
import json
import os
import shutil
import subprocess
import sys
from argparse import Namespace

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import helpers
from helpers import git, is_, ok, put

helpers.setup()
from process_replay import common as C  # noqa: E402
from process_replay import inventory as I  # noqa: E402
from process_replay import planreview as P  # noqa: E402

ROOT = helpers.tmp_root()
NO_SNAPSHOT = os.path.join(ROOT, "no-snapshot")


class dated(object):
    """Commits made inside get this author and committer date."""

    def __init__(self, when):
        self.when = when

    def __enter__(self):
        self.old = dict((k, os.environ.get(k)) for k in ("GIT_AUTHOR_DATE", "GIT_COMMITTER_DATE"))
        os.environ["GIT_AUTHOR_DATE"] = os.environ["GIT_COMMITTER_DATE"] = self.when

    def __exit__(self, *exc):
        for k, v in self.old.items():
            if v is None:
                os.environ.pop(k, None)
            else:
                os.environ[k] = v


def world(name):
    """Fresh ledger home, Codex home and state, so a scenario sees only its own ledgers."""
    base = os.path.join(ROOT, name)
    os.environ["XDG_STATE_HOME"] = os.path.join(base, "xdg")
    os.environ["CODEX_HOME"] = os.path.join(base, "codex")
    os.makedirs(os.environ["XDG_STATE_HOME"])
    os.makedirs(os.environ["CODEX_HOME"])
    return os.path.join(base, "state")


def args(state, dry=False, root=None, plans=False, open=None):
    a = Namespace(state=state, dry_run=dry, snapshot_root=root or NO_SNAPSHOT, plans=plans)
    if open is not None:
        a.open = open
    return a


def answers(state, kind, jid, doc):
    C.jsave(os.path.join(state, kind, jid + ".answer.json"), doc)


def make_branch(repo, name, base, steps):
    """steps: [(committer date, {path: text}, message)]; returns the commit ids. Leaves main checked out."""
    git(repo, "checkout", "-q", "-b", name, base)
    out = []
    for when, files, msg in steps:
        for path, text in files.items():
            put(repo, path, text)
        with dated(when):
            out.append(helpers.commit(repo, msg))
    git(repo, "checkout", "-q", "main")
    return out


def merge(repo, name, when):
    with dated(when):
        git(repo, "merge", "--no-ff", "-q", "-m", "merge " + name, name)


def main_tip(repo):
    return git(repo, "rev-parse", "main")


# ---- ledger and reviews.json records
def receipt(nonce, at, thread, turn, gitdir, branch, base, tip, full=True, verdict="approve", slices=None, dest="main"):
    e = {"v": 2, "kind": "receipt", "checkpoint": "pre-merge", "nonce": nonce, "dispatched_at": at, "verdict": verdict,
         "thread": thread, "turn": turn, "clean": True,
         "targets": [{"repo": gitdir, "dest": dest, "dest_ref": dest, "branch": branch, "range": dest + "..." + str(branch),
                      "base": base, "tip": tip, "full": full}]}
    if slices is not None:
        e["slice_turns"] = [{"thread": t, "turn": u, "compacted": False} for t, u in slices]
    return e


def review(kind, start, ranges=(), head=None, commits=(), prompt="", report="a report"):
    return {"agent": "a" + start, "kind": kind, "description": "d", "start": start, "end": start, "prompt": prompt, "report": report,
            "ranges": [list(r) for r in ranges], "reviewed_head": head, "reviewed_commits": list(commits), "tokens": 1, "model": "m",
            "transcript": "t"}


def group(gid, gitdir, reviews, task=1):
    return {"id": gid, "project": "p", "session": "s", "cwd": gitdir, "repo": gitdir, "prefix": "", "task": task, "reviews": reviews}


def run_cases(state, gs, **kw):
    C.jsave(os.path.join(state, "reviews.json"), {"groups": gs})
    return I.cmd_cases(args(state, **kw))


def branches(state):
    doc = C.jload(os.path.join(state, "branches.json"))
    return doc, dict((b["branch"], b) for b in doc["branches"])


def finding(sev, file, line, summary):
    return {"severity": sev, "file": file, "line": line, "summary": summary, "failure_scenario": "when " + summary}


def codex_answer(verdict, findings):
    return {"verdict": verdict, "findings": findings, "reviewed_files": []}


# ================================================================ chains and round_findings
CHAIN_ENTRIES = [
    receipt("n2", "2026-10-02T10:00:00.000000Z", "t", "u2", "R", "feat", "b", "t2"),
    receipt("n1", "2026-10-01T10:00:00.000000Z", "t", "u1", "R", "feat", "b", "t1"),
    receipt("n1", "2026-10-01T10:00:00.000000Z", "t", "u1", "R", "feat", "b", "t1"),
    receipt("n3", "2026-10-02T11:00:00.000000Z", "t", "u3", "R", "feat", "b", "t3", dest="release"),
    receipt("n4", "2026-10-02T12:00:00.000000Z", "t2", "u4", "R", "other", "b", "t4"),
    {"v": 2, "kind": "receipt", "checkpoint": "plan", "nonce": "np", "dispatched_at": "2026-10-01T09:00:00.000000Z", "thread": "t",
     "turn": "u0", "targets": [{"repo": "R", "base": "b", "tip": "t0"}]},
]
cs = sorted([[(r["nonce"], r["k"]) for r in c] for c in I.chains(CHAIN_ENTRIES, "R")])
is_("chains: one chain per (repo, branch, dest), ascending by dispatched_at, a nonce once, plan receipts left out",
    cs, [[("n1", 1), ("n2", 2)], [("n3", 1)], [("n4", 1)]])
is_("chains: with no repo given the target's own is the key", len(I.chains(CHAIN_ENTRIES)), 3)

RW = helpers.make_repo(ROOT, "rwrepo")
put(RW, "x", "x\n")
helpers.commit(RW, "x")
SW = world("w-slice")
helpers.write_rollout(os.environ["CODEX_HOME"], "th-sl-a", [
    {"turn": "ta1", "answer": codex_answer("changes", [finding("P1", "src/x.py", 1, "slice one"), finding("P3", "src/x.py", 2, "nit")])},
    {"turn": "ta2", "answer": codex_answer("changes", [finding("P0", "src/y.py", 4, "receipt turn")])}])
helpers.write_rollout(os.environ["CODEX_HOME"], "th-sl-b", [
    {"turn": "tb1", "answer": codex_answer("changes", [finding("P1", "src/z.py", 9, "slice two"), finding("P2", "src/z.py", 10, "slice two b")])}])
RND = {"turns": [["th-sl-a", "ta2"], ["th-sl-a", "ta1"], ["th-sl-b", "tb1"], ["th-sl-a", "ta2"]]}
fs = I.round_findings(RND)
is_("sliced_round_union: the receipt turn's and every slice's P0-P2 findings, a turn once, P3 left out",
    [(f["index"], f["severity"], f["summary"]) for f in fs],
    [(0, "P0", "receipt turn"), (1, "P1", "slice one"), (2, "P1", "slice two"), (3, "P2", "slice two b")])
is_("sliced_round_union: a finding carries the keys a judge-known input names",
    sorted(fs[0]), sorted(["index", "severity", "file", "line", "summary", "failure_scenario"]))
is_("sliced_round_union: a thread with no rollout gives none", I.round_findings({"turns": [["th-none", "tx"]]}), [])
is_("sliced_round_union: a round with no turns gives none", I.round_findings({"turns": []}), [])

# ================================================================ candidate_static
CR = helpers.make_repo(ROOT, "crepo")
with dated("2026-09-20T10:00:00Z"):
    put(CR, "README.md", "readme\n")
    C0 = helpers.commit(CR, "base")
PLAN = "docs/superpowers/plans/p.md"
BR = {}
BR["ok"] = make_branch(CR, "ok", C0, [("2026-09-24T10:00:00Z", {PLAN: "plan\n"}, "plan"), ("2026-09-25T10:00:00Z", {"ok1.txt": "1\n"}, "ok1"),
                                       ("2026-09-26T10:00:00Z", {"ok2.txt": "2\n"}, "ok2")])
for name in ("early", "slice", "nogroup", "nomerge", "gone", "thin", "open", "edge", "late"):
    BR[name] = make_branch(CR, name, C0, [("2026-09-28T10:00:00Z", {name + ".txt": name + "\n"}, name + "1")]
                           + ([("2026-09-28T11:00:00Z", {name + "2.txt": name + "\n"}, name + "2")] if name == "edge" else []))
MERGED = (("early", "2026-09-30T23:59:59Z"), ("ok", "2026-10-05T10:00:00Z"), ("slice", "2026-10-06T10:00:00Z"),
          ("nogroup", "2026-10-07T10:00:00Z"), ("gone", "2026-10-08T10:00:00Z"), ("thin", "2026-10-08T11:00:00Z"), ("open", "2026-10-09T10:00:00Z"),
          ("edge", "2026-11-01T23:30:00Z"), ("late", "2026-11-03T10:00:00Z"))
for name, when in MERGED:
    merge(CR, name, when)
CSTATE = world("w-static")
CG = C.L.common_dir(CR)
LEDGER = []
for name in ("early", "slice", "nogroup", "nomerge", "late", "open", "edge", "thin"):
    LEDGER.append(receipt("xr-" + name, "2026-09-29T10:00:00.000000Z", "th-" + name, "tu-" + name, CG, name, C0, BR[name][-1],
                          full=name != "slice", verdict="changes" if name == "open" else "approve"))
LEDGER.append(receipt("xr-gone", "2026-09-29T10:00:00.000000Z", "th-gone", "tu-gone", CG, "gone", C0, "e" * 40))
OK_R1 = receipt("xr-ok-1", "2026-09-27T10:00:00.000000Z", "th-ok", "tu-ok1", CG, "ok", C0, BR["ok"][1], verdict="changes")
OK_R2 = receipt("xr-ok-2", "2026-09-28T10:00:00.000000Z", "th-ok", "tu-ok2", CG, "ok", C0, BR["ok"][2])
LEDGER += [OK_R1, OK_R2]
helpers.write_ledger(os.environ["XDG_STATE_HOME"], CR, LEDGER)
# the same pre-merge receipt in a second ledger file: it counts once, and does not make a second chain
dup = os.path.join(os.environ["XDG_STATE_HOME"], "xreview", "ledgers", "dup")
os.makedirs(dup)
with open(os.path.join(dup, "reviews.jsonl"), "w") as f:
    f.write(json.dumps(OK_R2) + "\n")
with open(os.path.join(dup, "repo"), "w") as f:
    f.write(CG + "\n")
GROUPS = [group("g-" + n, CG, [review("review", "2026-09-28T10:30:00.000Z", [(C0, BR[n][-1])], BR[n][-1])])
          for n in ("early", "slice", "nomerge", "late", "gone", "open")]
GROUPS.append(group("g-ok", CG, [review("review", "2026-09-25T10:00:00.000Z", [(C0, BR["ok"][1])], BR["ok"][1]),
                                 review("re-review", "2026-09-25T11:00:00.000Z", [(C0, BR["ok"][1])], BR["ok"][1]),
                                 review("re-review", "2026-09-26T11:00:00.000Z", [(BR["ok"][1], BR["ok"][2])], BR["ok"][2])]))
GROUPS.append(group("g-edge", CG, [review("review", "2026-09-28T10:30:00.000Z", [(C0, BR["edge"][0])], BR["edge"][0]),
                                   review("re-review", "2026-09-28T10:40:00.000Z", [(C0, BR["edge"][0])], BR["edge"][0]),
                                   review("re-review", "2026-09-28T11:30:00.000Z", [(BR["edge"][0], BR["edge"][1])], BR["edge"][1])]))
GROUPS.append(group("g-thin", CG, [review("review", "2026-09-28T10:30:00.000Z", [(C0, BR["thin"][0])], BR["thin"][0]),
                                   review("re-review", "2026-09-28T10:40:00.000Z", [(C0, BR["thin"][0])], BR["thin"][0])]))
is_("cases: exits 0", run_cases(CSTATE, GROUPS), 0)
doc, by = branches(CSTATE)
WHY = {n: by[n]["why"] for n in by}
ok("candidate_static: a full-branch round 1, an approving last round, a merge in the window and a task group make a candidate",
   by["ok"]["candidate"] and by["ok"]["why"] is None, by["ok"])
is_("candidate_static: its September rounds are in, whatever their date (nonce once across ledgers)",
    [(r["k"], r["nonce"], r["at"][:10]) for r in by["ok"]["rounds"]], [(1, "xr-ok-1", "2026-09-27"), (2, "xr-ok-2", "2026-09-28")])
is_("candidate_static: one record per chain, the duplicate ledger made no second chain", sum(1 for b in doc["branches"] if b["branch"] == "ok"), 1)
is_("candidate_static: round 1 not full", WHY["slice"], "round 1 is not a full-branch review")
is_("candidate_static: merged after the window", WHY["late"], "merged outside the window")
is_("candidate_static: merged before the window", WHY["early"], "merged outside the window")
ok("candidate_static: merged on the window's last day is a candidate", by["edge"]["candidate"], by["edge"])
is_("candidate_static: no task group", WHY["nogroup"], "no task review joined")
is_("candidate_static: a joined group with one fix range cannot reach two per-task defects", WHY["thin"], "fewer than two task-review fix ranges")
ok("candidate_static: and it is not opened, so no judge input is spent on it",
   not by["thin"]["opened"] and not os.path.exists(os.path.join(CSTATE, "judge-task", "g-thin-" + by["thin"]["id"] + ".json")))
ok("candidate_static: while a branch with two fix ranges is opened and gets one", by["edge"]["opened"] and os.path.exists(
    os.path.join(CSTATE, "judge-task", "g-edge-" + by["edge"]["id"] + ".json")))
is_("candidate_static: never merged", WHY["nomerge"], "no merge evidence")
is_("candidate_static: a round tip nowhere", WHY["gone"], "a round tip is gone")
is_("candidate_static: the last round asked for changes", WHY["open"], "the last round did not approve")
is_("candidate_static: the Branch record's fields", sorted(by["ok"]), sorted([
    "id", "repo", "objects", "view", "dest", "dest_ref", "branch", "base", "rounds", "round1_tip", "final_tip", "plan_commit", "groups",
    "joined", "candidate", "opened", "why", "merged", "unresolved_ranges", "off_branch_ranges", "skipped_rounds"]))
is_("candidate_static: base, round-1 tip and final tip", (by["ok"]["base"], by["ok"]["round1_tip"], by["ok"]["final_tip"]),
    (C0, BR["ok"][1], BR["ok"][2]))
is_("candidate_static: a round's fields", sorted(by["ok"]["rounds"][0]), sorted(["k", "nonce", "tip", "base", "thread", "turns", "at", "verdict"]))
is_("candidate_static: merged how and when", (by["ok"]["merged"]["how"], by["ok"]["merged"]["at"]), ("ancestry", "2026-10-05T10:00:00Z"))
is_("candidate_static: no plan receipt: the last commit touching the plans before the first task review began",
    by["ok"]["plan_commit"], BR["ok"][0])
is_("candidate_static: joined groups", by["ok"]["groups"], ["g-ok"])
ok("candidate_static: the destination's own name and ref are carried", (by["ok"]["dest"], by["ok"]["dest_ref"]) == ("main", "main"), by["ok"])
ok("candidate_static: branches.json holds the view path and a null objects without a snapshot",
   by["ok"]["view"].endswith("views/crepo.git") and by["ok"]["objects"] is None, (by["ok"]["view"], by["ok"]["objects"]))

# ---- a round tip that survives only in the snapshot
SR = helpers.make_repo(ROOT, "srepo")
with dated("2026-09-20T10:00:00Z"):
    put(SR, "README.md", "readme\n")
    S0 = helpers.commit(SR, "base")
TMP_TIP = make_branch(SR, "tmp", S0, [("2026-09-27T10:00:00Z", {"t.txt": "t\n"}, "dangling")])[0]
SB = make_branch(SR, "sb", S0, [("2026-09-28T10:00:00Z", {"s.txt": "s\n"}, "s1"), ("2026-09-28T11:00:00Z", {"s2.txt": "s\n"}, "s2")])
merge(SR, "sb", "2026-10-03T10:00:00Z")
SNAP = os.path.join(ROOT, "snap")
shutil.copytree(os.path.join(SR, ".git", "objects"), os.path.join(SNAP, "srepo", "objects"))
git(SR, "branch", "-q", "-D", "tmp")
git(SR, "reflog", "expire", "--expire=now", "--all")
git(SR, "gc", "-q", "--prune=now")
ok("snapshot_only: control: the original no longer has the dangling commit", not helpers.git_ok(SR, "cat-file", "-e", TMP_TIP + "^{commit}"))
SSTATE = world("w-snap")
SG = C.L.common_dir(SR)
helpers.write_ledger(os.environ["XDG_STATE_HOME"], SR, [
    receipt("xr-s1", "2026-09-29T10:00:00.000000Z", "th-s", "tu-s1", SG, "sb", S0, TMP_TIP, verdict="changes"),
    receipt("xr-s2", "2026-09-30T10:00:00.000000Z", "th-s", "tu-s2", SG, "sb", S0, SB[1])])
SGROUPS = [group("g-s", SG, [review("review", "2026-09-28T10:30:00.000Z", [(S0, SB[0])], SB[0]),
                             review("re-review", "2026-09-28T10:40:00.000Z", [(S0, SB[0])], SB[0]),
                             review("re-review", "2026-09-28T11:30:00.000Z", [(SB[0], SB[1])], SB[1])])]
run_cases(SSTATE, SGROUPS)
_d, sb = branches(SSTATE)
is_("snapshot_only: without the snapshot the dangling round tip is gone", sb["sb"]["why"], "a round tip is gone")
run_cases(SSTATE, SGROUPS, root=SNAP)
_d, sb = branches(SSTATE)
ok("snapshot_only: with the snapshot the same branch is a candidate", sb["sb"]["candidate"], sb["sb"])
is_("snapshot_only: and records where the snapshot's objects are", sb["sb"]["objects"], os.path.join(SNAP, "srepo", "objects"))

# ---- the plan handoff and a missing snapshot of transcripts
called = []
real_plan_cases = P.plan_cases
P.plan_cases = lambda a: called.append(a) or 7
is_("cases --plans hands over to planreview.plan_cases and returns its result", I.cmd_cases(args(CSTATE, plans=True)), 7)
P.plan_cases = real_plan_cases
is_("cases --plans: the handed-over arguments are the command's", len(called), 1)
try:
    I.cmd_cases(args(os.path.join(ROOT, "empty-state")))
    got = "returned"
except C.Failed as e:
    got = "failed: " + str(e)
ok("cases without reviews.json fails and says to run snapshot", got.startswith("failed") and "snapshot" in got, got)

# ================================================================ the rich branch: groups, judges, inventory
RR = helpers.make_repo(ROOT, "rrepo")
with dated("2026-09-20T10:00:00Z"):
    put(RR, "README.md", "readme\n")
    R0 = helpers.commit(RR, "base")
X1 = make_branch(RR, "other", R0, [("2026-09-30T10:00:00Z", {"other.py": "x = 1\n"}, "x1")])[0]
SRC = {"src/a.py": "def a():\n    return 1  # bug A\n", "src/b.py": "def b():\n    return 1  # bug B\n",
       "src/e.py": "def e(n):\n    return n - 1  # bug E\n", "src/g.py": "def g(x):\n    return x  # bug G\n"}
RICH = make_branch(RR, "rich", R0, [
    ("2026-10-01T09:00:00Z", SRC, "task 1"),
    ("2026-10-01T10:00:00Z", {"src/a.py": "def a():\n    return 2  # fixed A\n"}, "fix A"),
    ("2026-10-01T11:00:00Z", {"src/b.py": "def b():\n    return 2  # fixed B\n", "docs/superpowers/plans/x.md": "status: in progress\n"}, "fix B"),
    ("2026-10-02T09:00:00Z", {"src/c.py": "def c():\n    return 1  # bug C\n"}, "task 2"),
    ("2026-10-02T10:00:00Z", {"src/c.py": "def c():\n    return 2  # fixed C\n"}, "fix C"),
    ("2026-10-03T09:00:00Z", {"src/e.py": "def e(n):\n    return n  # fixed E\n", "src/h.py": "def h():\n    return 1  # new in p1\n"}, "pre-merge fix 1"),
    ("2026-10-04T07:00:00Z", {"src/g.py": "def g(x):\n    return x or 0  # fixed G\n", "src/h.py": "def h():\n    return 2  # fixed H\n"}, "pre-merge fix 2"),
])
T1, F1, F2, T2, F3, P1, P2 = RICH
merge(RR, "rich", "2026-10-10T10:00:00Z")
AMBIG = None


def ambiguous_pair(repo):
    """Two commit objects whose ids share their first seven hex digits, written into repo; returns (prefix, ids)."""
    tree = "4b825dc642cb6eb9a060e54bf8d69288fbee4904"
    seen, i = {}, 0
    while True:
        body = "tree {}\nauthor t <t@t> 1000000000 +0000\ncommitter t <t@t> 1000000000 +0000\n\ncollide {}\n".format(tree, i).encode()
        sha = hashlib.sha1(b"commit %d\0" % len(body) + body).hexdigest()
        if sha[:7] in seen:
            break
        seen[sha[:7]] = (sha, body)
        i += 1
    a, b = seen[sha[:7]], (sha, body)
    for _sha, text in (a, b):
        p = subprocess.run(["git", "-C", repo, "hash-object", "-t", "commit", "-w", "--stdin"], input=text, capture_output=True)
        assert p.returncode == 0, p.stderr
    return sha[:7], (a[0], b[0])


AMBIG, _ids = ambiguous_pair(RR)
GS = world("w-rich")
RG = C.L.common_dir(RR)
helpers.write_rollout(os.environ["CODEX_HOME"], "th-rich", [
    {"turn": "tr1", "answer": codex_answer("changes", [
        finding("P2", "src/e.py", 2, "e: the bound is off by one"), finding("P2", "src/g.py", 2, "g: unchecked input (round 1 wording)"),
        finding("P3", "src/e.py", 1, "e: naming")])},
    {"turn": "tr2", "answer": codex_answer("changes", [finding("P2", "src/h.py", 2, "h: returns the wrong value")])},
    {"turn": "tr3", "answer": codex_answer("approve", [])}])
helpers.write_rollout(os.environ["CODEX_HOME"], "th-rich-s", [
    {"turn": "ts1", "answer": codex_answer("changes", [finding("P1", "src/g.py", 2, "g: an unchecked input returns None")])}])
PLAN_RECEIPTS = []
for nonce, at, verdict, tip, clean in (("pl1", "2026-09-30T10:00:00.000000Z", "approve", T1, True), ("pl2", "2026-10-01T05:00:00.000000Z", "changes", F1, True),
                                       ("pl3", "2026-10-02T05:00:00.000000Z", "approve", F2, False)):
    PLAN_RECEIPTS.append({"v": 2, "kind": "receipt", "checkpoint": "plan", "nonce": nonce, "dispatched_at": at, "verdict": verdict, "thread": "thp",
                          "turn": "tp", "clean": clean, "targets": [{"repo": RG, "branch": "rich", "base": R0, "tip": tip}]})
helpers.write_ledger(os.environ["XDG_STATE_HOME"], RR, PLAN_RECEIPTS + [
    receipt("xr-rich-1", "2026-10-03T08:00:00.000000Z", "th-rich", "tr1", RG, "rich", R0, F3, verdict="changes"),
    receipt("xr-rich-2", "2026-10-03T12:00:00.000000Z", "th-rich", "tr2", RG, "rich", R0, P1, verdict="changes",
            slices=[("th-rich-s", "ts1"), ("th-rich", "tr2")]),
    receipt("xr-rich-3", "2026-10-04T08:00:00.000000Z", "th-rich", "tr3", RG, "rich", R0, P2)])
F2_DOCS = "Finding under verification (Important): B leaks when the flag is off."
RGROUPS = [
    group("gmulti", RG, [review("review", "2026-10-01T08:00:00.000Z", head=None, commits=[T1[:8], F1[:8]], report="multi")]),
    group("g1", RG, [
        review("review", "2026-10-01T09:30:00.000Z", [(R0, T1)], T1, report="Task 1: A and B are wrong."),
        review("re-review", "2026-10-01T10:30:00.000Z", [(T1[:9], F1[:9])], F1[:9], report="A is fixed.",
               prompt="Re-review.\nFinding under verification (Critical): A is ignored.\nFix base " + T1[:9] + ", head " + F1[:9] + "\n"),
        review("re-review", "2026-10-02T09:30:00.000Z", [], F2, report="B is fixed.", prompt="Re-review.\n" + F2_DOCS + "\nNo range here.\n")]),
    group("g2", RG, [
        review("review", "2026-10-02T09:30:00.000Z", [(F2, T2)], T2, report="Task 2: fine."),
        review("re-review", "2026-10-02T10:30:00.000Z", [(T2, F3)], F3, report="C was already wrong in the task; fixed.",
               prompt="Re-review.\nFinding under verification (Critical): c breaks.\n")], task=2),
    group("gamb", RG, [
        review("review", "2026-10-02T12:00:00.000Z", [(F2, T2)], T2, report="Task 3."),
        review("re-review", "2026-10-02T13:00:00.000Z", [(T2, AMBIG)], AMBIG, report="x")], task=3),
    group("gother", RG, [review("review", "2026-10-01T09:00:00.000Z", [(R0, X1)], X1), review("re-review", "2026-10-01T10:00:00.000Z", [(R0, X1)], X1)], task=4),
    group("ginc", RG, [review("review", "2026-10-01T09:00:00.000Z", head=None, commits=[T1, X1])], task=5),
    group("gbase", RG, [review("review", "2026-09-20T10:00:00.000Z", head=R0)], task=6),
]
ok("control: the ambiguous prefix really is ambiguous in the repository", helpers.git_ok(RR, "rev-parse", "--verify", "--quiet", AMBIG + "^{commit}") is False)

# ---- dry run first, in its own state: judge inputs and briefs, nothing else
DRY = os.path.join(ROOT, "w-rich", "dry")
is_("dry_run: exits 0", run_cases(DRY, RGROUPS, dry=True), 0)
written = sorted(os.path.relpath(os.path.join(d, f), DRY) for d, _s, fs_ in os.walk(DRY) for f in fs_
                 if os.sep + "views" + os.sep not in os.path.join(d, f) and not f.endswith("alias") and f != "reviews.json")
ok("dry_run: nothing but judge inputs and briefs", bool(written) and all(w.startswith("judge") for w in written), written)
ok("dry_run: no branches.json and no inventory", not os.path.exists(os.path.join(DRY, "branches.json")) and not os.path.exists(os.path.join(DRY, "inventory")))

# ---- the real run
is_("cases: exits 0", run_cases(GS, RGROUPS), 0)
doc, by = branches(GS)
rich = by["rich"]
BID = rich["id"]
dry_task = C.jload(os.path.join(DRY, "judge-task", "g1-" + BID + ".json"))
joined = dict((j["group"], j) for j in rich["joined"])
ok("branch id: b + 8 hex", len(BID) == 9 and BID[0] == "b" and all(c in "0123456789abcdef" for c in BID[1:]), BID)
ok("candidate_static: the rich branch is a candidate", rich["candidate"], rich)
is_("task_join: groups whose reviewed commit is on the branch join it, ordered by their first review; another branch's, an "
    "incomparable pair's and the base's do not",
    rich["groups"], ["gmulti", "g1", "g2", "gamb"])
is_("task_join: a short sha and a head found among several commits (the newest by ancestry) both join", "gmulti" in rich["groups"], True)
is_("plan_commit: the newest approved, clean plan receipt on the branch (not the one asking for changes, not the unclean one)",
    rich["plan_commit"], T1)
is_("ambiguous_sha_skipped: the ambiguous range is dropped and counted, per branch and in branches.json",
    (rich["unresolved_ranges"], doc["unresolved_ranges"]), (1, 1))
is_("task_join: branches.json lists each branch's own changes per group: g1 has the named range and the derived one",
    joined["g1"]["changes"], [[T1, F1], [F1, F2]])
is_("fix_range_unnamed: a re-review with no range gets (the commit the earlier review looked at, the re-review's own named fix commit "
    "when it descends from that), not the last commit made before it began (that would be task 2's)",
    joined["g1"]["changes"][1], [F1, F2])
is_("ambiguous_sha_skipped: the group with the ambiguous range has no change left, and says why", (joined["gamb"]["changes"], [
    (u["kind"], u["review"]) for u in joined["gamb"]["unjoined"]]), ([], [("unresolved", 1)]))
ok("ambiguous_sha_skipped: and so no judge-task input", not os.path.exists(os.path.join(GS, "judge-task", "gamb-" + BID + ".json")))
is_("judge_inputs: one judge-task per (group, branch) with a report and a fix range",
    sorted(n[:-5] for n in os.listdir(os.path.join(GS, "judge-task")) if n.endswith(".json")), ["g1-" + BID, "g2-" + BID])
t1 = C.jload(os.path.join(GS, "judge-task", "g1-" + BID + ".json"))
is_("judge_inputs: judge-task holds every report in order, with fresh indices", t1["reports"], [
    {"index": 0, "text": "Task 1: A and B are wrong."}, {"index": 1, "text": "A is fixed."}, {"index": 2, "text": "B is fixed."}])
is_("judge_inputs: judge-task's changes are the fix ranges, the re-review prompt's 'Finding under verification' lines as the note",
    [(c["index"], c["note"]) for c in t1["changes"]], [(0, "Finding under verification (Critical): A is ignored."), (1, F2_DOCS)])
ok("judge_inputs: each change carries its diff", "+    return 2  # fixed A" in t1["changes"][0]["diff"] and "-    return 1  # bug A" in t1["changes"][0]["diff"],
   t1["changes"][0]["diff"])
is_("judge_inputs: the dry run wrote the same judge-task input", dry_task, t1)
is_("judge_inputs: judge-task keys", sorted(t1), ["changes", "reports"])
rn = dict((r["k"], r["nonce"]) for r in rich["rounds"])
is_("judge_inputs: one judge-known per round that has a next round and a finding (round 3 has none)",
    sorted(n[:-5] for n in os.listdir(os.path.join(GS, "judge-known")) if n.endswith(".json")), ["xr-rich-1", "xr-rich-2"])
k1 = C.jload(os.path.join(GS, "judge-known", "xr-rich-1.json"))
is_("judge_inputs: judge-known is xreview-replay's shape", sorted(k1), ["case", "findings", "interdiff"])
is_("judge_inputs: judge-known holds the P0-P2 findings only", [(f["index"], f["severity"]) for f in k1["findings"]], [(0, "P2"), (1, "P2")])
ok("judge_inputs: its interdiff is the change between this tip and the next", "+    return n  # fixed E" in k1["interdiff"], k1["interdiff"][:200])
k2 = C.jload(os.path.join(GS, "judge-known", "xr-rich-2.json"))
is_("sliced_round_union: round 2's findings are the receipt turn's and the slice's (the slice thread's alone would hide h)",
    [f["summary"] for f in k2["findings"]], ["h: returns the wrong value", "g: an unchecked input returns None"])
is_("judge_inputs: no judge-present before judge-known has answered", os.path.isdir(os.path.join(GS, "judge-present")), False)
ok("inventory: none while judges are pending", not os.path.exists(os.path.join(GS, "inventory", BID + ".json")))

# ---- answers, phase one: judge-task and judge-known
answers(GS, "judge-task", "g1-" + BID, {"findings": [
    {"index": 0, "report": 0, "summary": "A is ignored", "file": "src/a.py", "line": 2, "failure_scenario": "when a runs", "severity": "P1",
     "introduced_by": None, "fixed_by": [0], "answer": "yes"},
    {"index": 1, "report": 0, "summary": "B leaks", "file": "src/b.py", "line": 2, "failure_scenario": "when the flag is off", "severity": "P3",
     "introduced_by": None, "fixed_by": [1], "answer": "yes"},
    {"index": 2, "report": 0, "summary": "X is wrong", "file": "src/a.py", "line": 1, "failure_scenario": "x", "severity": "P2",
     "introduced_by": None, "fixed_by": [0], "answer": "no"},
    {"index": 3, "report": 1, "summary": "Y came in with the fix", "file": "src/a.py", "line": 2, "failure_scenario": "y", "severity": "P1",
     "introduced_by": 0, "fixed_by": [1], "answer": "yes"}]})
answers(GS, "judge-task", "g2-" + BID, {"findings": [
    {"index": 0, "report": 1, "summary": "C was wrong from the start", "file": "src/c.py", "line": 2, "failure_scenario": "when c runs",
     "severity": "P2", "introduced_by": None, "fixed_by": [0], "answer": "yes"},
    {"index": 1, "report": 1, "summary": "Z is unclear", "file": "src/c.py", "line": 1, "failure_scenario": "z", "severity": "P2",
     "introduced_by": None, "fixed_by": [0], "answer": "unclear"}]})
answers(GS, "judge-known", "xr-rich-1", {"verdicts": [{"index": 0, "answer": "yes"}, {"index": 1, "answer": "no"}]})
answers(GS, "judge-known", "xr-rich-2", {"verdicts": [{"index": 0, "answer": "yes"}, {"index": 1, "answer": "yes"}]})
run_cases(GS, RGROUPS)
is_("judge_inputs: one judge-present per known-real finding of a round k >= 2 (round 1's known-real needs none)",
    sorted(n[:-5] for n in os.listdir(os.path.join(GS, "judge-present")) if n.endswith(".json")), ["xr-rich-2-0", "xr-rich-2-1"])
ph = C.jload(os.path.join(GS, "judge-present", "xr-rich-2-0.json"))
pg = C.jload(os.path.join(GS, "judge-present", "xr-rich-2-1.json"))
is_("judge_inputs: judge-present holds the finding and the round-1 tip's text of the file it names",
    (pg["finding"]["summary"], pg["files"]), ("g: an unchecked input returns None", [{"path": "src/g.py", "text": SRC["src/g.py"]}]))
is_("judge_inputs: a file the round-1 tip does not have is an empty list, not a guess", (ph["finding"]["file"], ph["files"]), ("src/h.py", []))
is_("judge_inputs: judge-present keys", sorted(pg), ["files", "finding"])
ok("inventory: still none while judge-present has not answered", not os.path.exists(os.path.join(GS, "inventory", BID + ".json")))
answers(GS, "judge-present", "xr-rich-2-0", {"answer": "no"})
answers(GS, "judge-present", "xr-rich-2-1", {"answer": "yes"})
run_cases(GS, RGROUPS)
dd = C.jload(os.path.join(GS, "judge-dedup", BID + ".json"))
ok("inventory: the dedup judge runs once per branch, after the others, over every known-real defect", dd is not None and len(dd["defects"]) == 5,
   dd)
ok("inventory: and no inventory before its answer", not os.path.exists(os.path.join(GS, "inventory", BID + ".json")))
is_("judge_inputs: judge-dedup entries", sorted(dd["defects"][0]), ["failure_scenario", "file", "index", "line", "summary"])
idx = dict((d["summary"], d["index"]) for d in dd["defects"])
is_("judge_inputs: the dedup indices are fresh, in order: task defects, then pre-merge", sorted(idx.values()), [0, 1, 2, 3, 4])
sev = idx["B leaks"], idx["g: an unchecked input returns None"]
answers(GS, "judge-dedup", BID, {"groups": [[sev[0], sev[1]]] + [[i] for i in sorted(set(range(5)) - set(sev))]})
run_cases(GS, RGROUPS)
inv = C.jload(os.path.join(GS, "inventory", BID + ".json"))
ok("inventory_after_answers: inventory/<branch>.json is written", inv is not None)
dfx = dict((d["summary"], d) for d in inv["defects"])
is_("inventory_after_answers: the file's fields", sorted(inv), ["branch", "defects", "dropped"])
is_("inventory_after_answers: four defects after merging two", len(inv["defects"]), 4)
is_("inventory_after_answers: the Defect record's fields", sorted(dfx["A is ignored"]), sorted([
    "id", "class", "severity", "counted", "summary", "file", "line", "failure_scenario", "fixes", "files", "at"]))
a_ = dfx["A is ignored"]
is_("inventory_after_answers: a per-task yes P1 is a counted task defect with its fix range and files",
    (a_["class"], a_["severity"], a_["counted"], a_["fixes"], a_["files"]), ("task", "P1", True, [[T1, F1]], ["src/a.py"]))
ok("inventory_after_answers: its id is d + 8 hex and its time is the report that raised it",
   len(a_["id"]) == 9 and a_["id"][0] == "d" and a_["at"] == "2026-10-01T09:30:00.000Z", a_)
c_ = dfx["C was wrong from the start"]
is_("re_review_findings: a defect first raised by a re-review, in code no change introduced, is a task defect fixed by the later change",
    (c_["class"], c_["severity"], c_["fixes"], c_["at"]), ("task", "P2", [[T2, F3]], "2026-10-02T10:30:00.000Z"))
e_ = dfx["e: the bound is off by one"]
is_("inventory_after_answers: a round-1 known-real P2 is a pre-merge defect fixed between the round-1 tip and round 2's",
    (e_["class"], e_["severity"], e_["counted"], e_["fixes"], e_["files"], e_["at"]),
    ("pre", "P2", True, [[F3, P1]], ["src/e.py", "src/h.py"], "2026-10-03T08:00:00.000000Z"))
m_ = dfx["g: an unchecked input returns None"]
is_("inventory_after_answers: a dedup answer merges two defects: the higher severity, counted by it, both fix ranges (docs left out of files)",
    (m_["severity"], m_["counted"], m_["fixes"], m_["files"]),
    ("P1", True, [[F1, F2], [P1, P2]], ["src/b.py", "src/g.py", "src/h.py"]))
is_("inventory_after_answers: the merged defect is a task defect when one of its members is", m_["class"], "task")
ok("inventory_after_answers: the per-task P3 is listed but not counted unless merged: 'B leaks' became part of the P1 defect",
   "B leaks" not in dfx, sorted(dfx))
is_("inventory_after_answers: dropped records say why",
    sorted((d["summary"], d["why"]) for d in inv["dropped"]), sorted([
        ("X is wrong", "the judge found the report wrong"), ("Y came in with the fix", "introduced by a fix"),
        ("Z is unclear", "the judge could not settle it"), ("h: returns the wrong value", "introduced after round 1")]))

# ---- the same answers with the P3 left alone: not counted
answers(GS, "judge-dedup", BID, {"groups": [[i] for i in range(5)]})
run_cases(GS, RGROUPS)
inv2 = C.jload(os.path.join(GS, "inventory", BID + ".json"))
b2 = dict((d["summary"], d) for d in inv2["defects"])
is_("inventory_after_answers: a per-task P3 is a defect with counted false", (b2["B leaks"]["severity"], b2["B leaks"]["counted"], b2["B leaks"]["class"]),
    ("P3", False, "task"))
is_("inventory_after_answers: the pre-merge round-2 defect, present at round 1, is its own defect with the fix [tip 2, tip 3]",
    (b2["g: an unchecked input returns None"]["class"], b2["g: an unchecked input returns None"]["fixes"]), ("pre", [[P1, P2]]))
is_("inventory_after_answers: five defects with no merge", len(inv2["defects"]), 5)

# ---- a malformed dedup answer is not taken
answers(GS, "judge-dedup", BID, {"groups": [[0, 1]]})
os.unlink(os.path.join(GS, "inventory", BID + ".json"))
run_cases(GS, RGROUPS)
ok("inventory_after_answers: a dedup answer that is not a partition of the defects leaves the inventory unwritten",
   not os.path.exists(os.path.join(GS, "inventory", BID + ".json")))
ok("inventory_after_answers: and it is set aside, so the judge-dedup is pending again rather than stuck on an answer that is never used",
   os.path.isfile(os.path.join(GS, "judge-dedup", BID + ".rejected-1.answer.json")) and ("judge-dedup", BID) in [p[:2] for p in C.pending(GS)])

# ---- judges_blind
bad = []
FORBIDDEN = set(C.BLIND_KEYS) | set(b["id"] for b in doc["branches"])


def keys(x, path):
    if isinstance(x, dict):
        for k, v in x.items():
            if k in FORBIDDEN or "pre-merge" in k.lower() or "premerge" in k.lower():
                bad.append((path, k))
            keys(v, path + "." + k)
    elif isinstance(x, list):
        for i, v in enumerate(x):
            keys(v, path)


seen_inputs = 0
for kind in ("judge-task", "judge-known", "judge-present", "judge-dedup"):
    for n in sorted(os.listdir(os.path.join(GS, kind))):
        if n.endswith(".json") and not n.endswith(".answer.json"):
            seen_inputs += 1
            keys(C.jload(os.path.join(GS, kind, n)), kind + "/" + n)
ok("judges_blind: no judge input names a class, a run, an arm, a label, a purpose, a branch id or pre-merge as a key", seen_inputs == 7 and not bad, (seen_inputs, bad))
try:
    C.judge_write(GS, "judge-task", "zz", {"class": "task"})
    refused = False
except C.Failed:
    refused = True
ok("judges_blind: control: judge_write does refuse a document with a class key", refused)

# ---- re-run is stable: the same inputs, and the same defect ids
ids1 = sorted(d["id"] for d in inv2["defects"])
answers(GS, "judge-dedup", BID, {"groups": [[i] for i in range(5)]})
run_cases(GS, RGROUPS)
is_("cases: a re-run gives the same defect ids", sorted(d["id"] for d in C.jload(os.path.join(GS, "inventory", BID + ".json"))["defects"]), ids1)


# ================================================================ rewritten commits join by patch id; --open stages the candidates
OR = helpers.make_repo(ROOT, "orepo")
with dated("2026-09-20T10:00:00Z"):
    put(OR, "README.md", "readme\n")
    O0 = helpers.commit(OR, "base")
PL = make_branch(OR, "plain", O0, [("2026-10-01T09:00:00Z", {"p.txt": "p1\n"}, "p1"), ("2026-10-01T10:00:00Z", {"p.txt": "p2\n"}, "p2")])
WORK = make_branch(OR, "work", O0, [("2026-10-01T09:00:00Z", {"a.txt": "a1\n"}, "w1"), ("2026-10-01T10:00:00Z", {"a.txt": "a2\n"}, "w2")])
STRAY = make_branch(OR, "stray", O0, [("2026-10-01T09:00:00Z", {"z.txt": "z\n"}, "s1")])
git(OR, "checkout", "-q", "-b", "final", O0)
FIN = []
for when, c in (("2026-10-02T09:00:00Z", WORK[0]), ("2026-10-02T10:00:00Z", WORK[1])):
    with dated(when):
        git(OR, "cherry-pick", c)                                    # the rewrite: new ids, the same patches
    FIN.append(git(OR, "rev-parse", "HEAD"))
put(OR, "c.txt", "own\n")
with dated("2026-10-02T12:00:00Z"):
    FIN.append(helpers.commit(OR, "own commit"))
git(OR, "checkout", "-q", "main")
merge(OR, "plain", "2026-10-05T10:00:00Z")
merge(OR, "final", "2026-10-06T10:00:00Z")
OSTATE = world("w-open")
OG = C.L.common_dir(OR)
helpers.write_ledger(os.environ["XDG_STATE_HOME"], OR, [
    receipt("xr-plain", "2026-10-04T10:00:00.000000Z", "th-pl", "tu-pl", OG, "plain", O0, PL[-1]),
    receipt("xr-final", "2026-10-03T10:00:00.000000Z", "th-fi", "tu-fi", OG, "final", O0, FIN[-1])])
OGROUPS = [
    group("gplain", OG, [review("review", "2026-10-01T09:30:00.000Z", [(O0, PL[0])], PL[0], report="plain review"),
                         review("re-review", "2026-10-01T10:20:00.000Z", [(O0, PL[0])], PL[0], report="plain fixed first"),
                         review("re-review", "2026-10-01T10:30:00.000Z", [(PL[0], PL[1])], PL[1], report="plain fixed")]),
    group("gwork", OG, [review("review", "2026-10-01T09:30:00.000Z", [(O0, WORK[0])], WORK[0], report="work review"),
                        review("re-review", "2026-10-01T10:30:00.000Z", [(WORK[0], WORK[1])], WORK[1], report="work fixed")]),
    group("gwork2", OG, [review("review", "2026-10-01T09:30:00.000Z", [(O0, WORK[0])], WORK[0], report="work review again"),
                         review("re-review", "2026-10-02T10:30:00.000Z", [], None, report="work fixed, no commit named")], task=2),
    group("gstray", OG, [review("review", "2026-10-01T09:30:00.000Z", [(O0, STRAY[0])], STRAY[0]),
                         review("re-review", "2026-10-01T10:30:00.000Z", [(STRAY[0], STRAY[0])], STRAY[0])], task=3)]
ok("patch_id_join: control: the reviewed commits are not ancestors of the rewritten branch's tip",
   not helpers.git_ok(OR, "merge-base", "--is-ancestor", WORK[0], FIN[-1]) and not helpers.git_ok(OR, "merge-base", "--is-ancestor", WORK[1], FIN[-1]))
run_cases(OSTATE, OGROUPS, open=1)
doc, by = branches(OSTATE)
is_("patch_id_join: a group whose commits survive on the branch only as rewritten copies joins it; a stray commit's group does not",
    by["final"]["groups"], ["gwork", "gwork2"])
jn = lambda b: dict((j["group"], j["changes"]) for j in b["joined"])
FID, PID = by["final"]["id"], by["plain"]["id"]
is_("patch_id_join: the group's fix range is the branch's own copy of it, named, or derived for a re-review that names no commit "
    "(the last own commit made before it began)", (jn(by["final"])["gwork"], jn(by["final"])["gwork2"]), ([[FIN[0], FIN[1]]], [[FIN[0], FIN[1]]]))
is_("patch_id_join: an ancestry join is unchanged", (by["plain"]["groups"], jn(by["plain"])["gplain"]), (["gplain"], [[O0, PL[0]], [PL[0], PL[1]]]))

# ---- --open: the first N candidates by merge date, most recent first
is_("open: only the most recently merged candidate is opened", (by["final"]["opened"], by["plain"]["opened"]), (True, False))
inputs = lambda: sorted(n[:-5] for n in os.listdir(os.path.join(OSTATE, "judge-task")) if n.endswith(".json"))
is_("open: and only its judge inputs are written", inputs(), ["gwork-" + FID, "gwork2-" + FID])
ok("open: the diff of a rewritten group's change is the branch copy's", "+a2" in C.jload(os.path.join(OSTATE, "judge-task", "gwork-" + FID + ".json"))["changes"][0]["diff"])
os.utime(os.path.join(OSTATE, "judge-task", "gwork-" + FID + ".json"), (1000000000, 1000000000))
before = os.stat(os.path.join(OSTATE, "judge-task", "gwork-" + FID + ".json")).st_mtime_ns
run_cases(OSTATE, OGROUPS, open=2)
doc, by = branches(OSTATE)
is_("open: a larger N opens the next candidate", (by["final"]["opened"], by["plain"]["opened"]), (True, True))
is_("open: and writes its inputs", inputs(), ["gplain-" + PID, "gwork-" + FID, "gwork2-" + FID])
is_("open: an input that already exists is not rewritten", os.stat(os.path.join(OSTATE, "judge-task", "gwork-" + FID + ".json")).st_mtime_ns, before)
run_cases(OSTATE, OGROUPS, open=0)
doc, by = branches(OSTATE)
is_("open: N of 0 opens none", (by["final"]["opened"], by["plain"]["opened"]), (False, False))
run_cases(OSTATE, OGROUPS)
doc, by = branches(OSTATE)
is_("open: the default opens up to 16", (by["final"]["opened"], by["plain"]["opened"]), (True, True))


# ================================================================ a review joins the one branch whose own commits hold it
XP = helpers.make_repo(ROOT, "xrepo")
with dated("2026-09-10T10:00:00Z"):
    put(XP, "prev.txt", "prev\n")
    XPREV = helpers.commit(XP, "before the base")
with dated("2026-09-20T10:00:00Z"):
    put(XP, "README.md", "readme\n")
    X0 = helpers.commit(XP, "base")
ONE = make_branch(XP, "one", X0, [("2026-10-01T09:00:00Z", {"a.txt": "a1\n"}, "o1"), ("2026-10-01T10:00:00Z", {"a.txt": "a2\n"}, "o2")])
TWO = make_branch(XP, "two", X0, [("2026-10-02T09:00:00Z", {"b.txt": "b1\n"}, "t1"), ("2026-10-02T10:00:00Z", {"b.txt": "b2\n"}, "t2")])
RB = make_branch(XP, "rb", X0, [("2026-10-07T09:00:00Z", {"r1.txt": "r1\n"}, "rb1"), ("2026-10-07T10:00:00Z", {"r2.txt": "r2\n"}, "rb2")])
WK = make_branch(XP, "wk", X0, [("2026-10-08T09:00:00Z", {"z.txt": "z\n"}, "z on a work branch")])
CP1 = make_branch(XP, "cp1", X0, [("2026-10-08T10:00:00Z", {"z.txt": "z\n"}, "z, copy one")])
CP2 = make_branch(XP, "cp2", X0, [("2026-10-08T11:00:00Z", {"z.txt": "z\n"}, "z, copy two")])
merge(XP, "one", "2026-10-05T10:00:00Z")
merge(XP, "two", "2026-10-06T10:00:00Z")
put(XP, "mm.txt", "main moved\n")
with dated("2026-10-07T08:00:00Z"):
    helpers.commit(XP, "main moves on")
MMTIP = git(XP, "rev-parse", "main")
git(XP, "checkout", "-q", "rb")
with dated("2026-10-07T12:00:00Z"):
    git(XP, "rebase", "-q", "main")                                     # rb is rebased between its rounds
git(XP, "checkout", "-q", "main")
RB2 = [git(XP, "rev-parse", "rb~1"), git(XP, "rev-parse", "rb")]
merge(XP, "cp1", "2026-10-08T12:00:00Z")
merge(XP, "cp2", "2026-10-08T13:00:00Z")
merge(XP, "rb", "2026-10-09T10:00:00Z")
# a branch that merged main into itself: main's commits it took in are not its own
MG0 = git(XP, "rev-parse", "main")
MGB = make_branch(XP, "mg", MG0, [("2026-10-10T09:00:00Z", {"m.txt": "m\n"}, "mg1"), ("2026-10-10T10:00:00Z", {"m2.txt": "m\n"}, "mg2")])
put(XP, "side.txt", "side\n")
with dated("2026-10-10T12:00:00Z"):
    SIDE = helpers.commit(XP, "side work on main")
git(XP, "checkout", "-q", "mg")
with dated("2026-10-11T09:00:00Z"):
    git(XP, "merge", "-q", "-m", "update from main", "main")
git(XP, "checkout", "-q", "main")
MGTIP = git(XP, "rev-parse", "mg")
merge(XP, "mg", "2026-10-12T10:00:00Z")
XAMB, _ids = ambiguous_pair(XP)
XSTATE = world("w-x")
XG = C.L.common_dir(XP)
helpers.write_rollout(os.environ["CODEX_HOME"], "th-rb", [
    {"turn": "tr-rb1", "answer": codex_answer("changes", [finding("P1", "r1.txt", 1, "r1: wrong before the rebase")])},
    {"turn": "tr-rb2", "answer": codex_answer("approve", [])}])
helpers.write_ledger(os.environ["XDG_STATE_HOME"], XP, [
    receipt("xr-one", "2026-10-04T10:00:00.000000Z", "th-one", "tu-one", XG, "one", X0, ONE[-1]),
    receipt("xr-two", "2026-10-04T11:00:00.000000Z", "th-two", "tu-two", XG, "two", X0, TWO[-1]),
    receipt("xr-cp1", "2026-10-08T10:30:00.000000Z", "th-cp1", "tu-cp1", XG, "cp1", X0, CP1[-1]),
    receipt("xr-cp2", "2026-10-08T11:30:00.000000Z", "th-cp2", "tu-cp2", XG, "cp2", X0, CP2[-1]),
    receipt("xr-rb-1", "2026-10-07T11:00:00.000000Z", "th-rb", "tr-rb1", XG, "rb", X0, RB[-1], verdict="changes"),
    receipt("xr-rb-2", "2026-10-08T09:00:00.000000Z", "th-rb", "tr-rb2", XG, "rb", MMTIP, RB2[-1]),
    receipt("xr-mg", "2026-10-11T10:00:00.000000Z", "th-mg", "tu-mg", XG, "mg", MG0, MGTIP)])
XGROUPS = [
    group("gone1", XG, [review("review", "2026-10-01T09:30:00.000Z", [(X0, ONE[0])], ONE[0], report="one: review"),
                        review("re-review", "2026-10-01T10:30:00.000Z", [(ONE[0], ONE[1])], ONE[1], report="one: fixed"),
                        review("re-review", "2026-10-01T10:35:00.000Z", [(X0, ONE[0])], ONE[0], report="one: fixed again")]),
    group("gtask2", XG, [review("review", "2026-10-01T10:45:00.000Z", [(ONE[0], ONE[1])], ONE[1], report="task 2: on branch one"),
                         review("re-review", "2026-10-02T10:30:00.000Z", [(TWO[0], TWO[1])], TWO[1], report="task 2: on branch two"),
                         review("re-review", "2026-10-03T10:30:00.000Z", [], None, report="task 2: names no commit")], task=2),
    group("goff", XG, [review("review", "2026-10-01T09:40:00.000Z", [(X0, ONE[0])], ONE[0], report="off: review"),
                       review("re-review", "2026-10-01T10:40:00.000Z", [(XPREV, ONE[1])], ONE[1], report="off: fixed")], task=3),
    group("gh", XG, [review("review", "2026-10-02T09:30:00.000Z", [(X0, TWO[0])], TWO[0], report="h: review"),
                     review("re-review", "2026-10-02T10:20:00.000Z", [(TWO[0], XAMB)], XAMB, report="h: fixed"),
                     review("re-review", "2026-10-02T10:40:00.000Z", [], None, report="h: fixed again")], task=4),
    group("gtwo", XG, [review("review", "2026-10-02T11:30:00.000Z", [(X0, TWO[0])], TWO[0], report="two: review"),
                       review("re-review", "2026-10-02T11:40:00.000Z", [(X0, TWO[0])], TWO[0], report="two: fixed")], task=9),
    group("grb", XG, [review("review", "2026-10-07T09:30:00.000Z", [(X0, RB[0])], RB[0], report="rb: review"),
                      review("re-review", "2026-10-07T10:20:00.000Z", [(X0, RB[0])], RB[0], report="rb: fixed first"),
                      review("re-review", "2026-10-07T10:30:00.000Z", [(RB[0], RB[1])], RB[1], report="rb: fixed")], task=5),
    group("gmg", XG, [review("review", "2026-10-10T09:30:00.000Z", [(MG0, MGB[0])], MGB[0], report="mg: review"),
                      review("re-review", "2026-10-10T10:30:00.000Z", [(MG0, MGB[0])], MGB[0], report="mg: fixed"),
                      review("re-review", "2026-10-10T10:40:00.000Z", [(MGB[0], MGB[1])], MGB[1], report="mg: fixed again")], task=7),
    group("gside", XG, [review("review", "2026-10-10T13:00:00.000Z", [(MG0, SIDE)], SIDE, report="the commit main took meanwhile")], task=8),
    group("gdup", XG, [review("review", "2026-10-08T09:30:00.000Z", [(X0, WK[0])], WK[0], report="a patch two branches carry")], task=6),
]
is_("cases: exits 0", run_cases(XSTATE, XGROUPS), 0)
doc, by = branches(XSTATE)
ONEID, TWOID, RBID = by["one"]["id"], by["two"]["id"], by["rb"]["id"]
J = lambda b: dict((j["group"], j) for j in by[b]["joined"])
is_("rebased_between_rounds: the branch's base is the last full round's, so main's commits in between are not its own",
    (by["rb"]["base"], by["rb"]["round1_tip"] == RB[-1], by["rb"]["final_tip"]), (MMTIP, True, RB2[-1]))
is_("rebased_between_rounds: a review of the pre-rebase commits joins the rebased branch by patch id; the merged branches' own commits "
    "stay with their branches (no review is claimed twice)", (by["rb"]["groups"], doc["ambiguous_reviews"] and [a["group"] for a in doc["ambiguous_reviews"]]),
    (["grb"], ["gdup"]))
is_("merged_main_in: a branch that merged main into itself owns the merge and its own commit, not main's commits it took in (the group "
    "of such a commit joins no branch)", (by["mg"]["groups"], [g for b in by.values() for g in b["groups"] if g == "gside"]), (["gmg"], []))
is_("rebased_between_rounds: its fix ranges are the rebased copies, and a base that was the branch's old base stands for its new one",
    J("rb")["grb"]["changes"], [[MMTIP, RB2[0]], [RB2[0], RB2[1]]])
is_("two_branches_one_patch: a review whose commit's patch two branches carry joins neither, and is listed",
    ([sorted(a["branches"]) for a in doc["ambiguous_reviews"]], by["cp1"]["why"], by["cp2"]["why"]),
    ([sorted([by["cp1"]["id"], by["cp2"]["id"]])], "no task review joined", "no task review joined"))
is_("task_spans_branches: one task's reviews go to the branches their commits are on", (by["one"]["groups"], by["two"]["groups"]),
    (["gone1", "goff", "gtask2"], ["gh", "gtask2", "gtwo"]))
is_("task_spans_branches: by review: the first goes to one; the second, and the third that names no commit, to two",
    (J("one")["gtask2"]["reviews"], J("two")["gtask2"]["reviews"]), ([0], [1, 2]))
is_("task_spans_branches: a judge-task input per (group, branch), with only that branch's reviews",
    sorted(n[:-5] for n in os.listdir(os.path.join(XSTATE, "judge-task")) if n.endswith(".json")),
    sorted(["gone1-" + ONEID, "gtask2-" + TWOID, "gtwo-" + TWOID, "grb-" + RBID, "gmg-" + by["mg"]["id"]]))
is_("task_spans_branches: and its reports are those reviews' (the third names no commit and no range: nothing to compare)",
    [r["text"] for r in C.jload(os.path.join(XSTATE, "judge-task", "gtask2-" + TWOID + ".json"))["reports"]],
    ["task 2: on branch two", "task 2: names no commit"])
is_("task_spans_branches: its change is branch two's own range (the third review's derived range is empty)", J("two")["gtask2"]["changes"], [[TWO[0], TWO[1]]])
is_("off_branch_range: a range some of whose commits are not the branch's own is dropped, counted and says why",
    ([(u["kind"], u["review"], u["range"]) for u in J("one")["goff"]["unjoined"]], J("one")["goff"]["changes"], by["one"]["off_branch_ranges"]),
    ([("off-branch", 1, [XPREV, ONE[1]])], [], 1))
is_("unresolved_earlier_commit: a range-less re-review is not given an older review's commit when the nearer one does not resolve",
    ([(u["kind"], u["review"]) for u in J("two")["gh"]["unjoined"]], J("two")["gh"]["changes"], by["two"]["unresolved_ranges"]),
    ([("unresolved", 1), ("unresolved", 2)], [], 2))
ok("unresolved_earlier_commit: and it says which commit it could not use", "does not resolve" in J("two")["gh"]["unjoined"][1]["why"], J("two")["gh"]["unjoined"])
is_("branches.json totals", (doc["unresolved_ranges"], doc["off_branch_ranges"]), (2, 1))

# ---- skipped rounds: round 1's tip is not an ancestor of round 2's, because rb was rebased
is_("skipped_rounds: recorded in branches.json with a reason", [(s["k"], s["why"].startswith("round 1 not judged")) for s in by["rb"]["skipped_rounds"]], [(1, True)])
answers(XSTATE, "judge-task", "grb-" + RBID, {"findings": []})
run_cases(XSTATE, XGROUPS)
inv = C.jload(os.path.join(XSTATE, "inventory", RBID + ".json"))
is_("skipped_rounds: and in the inventory's dropped, one entry per finding of the round", [(d["summary"], d["why"].startswith("round 1 not judged")) for d in inv["dropped"]],
    [("r1: wrong before the rebase", True)])

# ---- stale inputs: an input whose content changed does not keep its old answer
SID = "gone1-" + ONEID
tp = os.path.join(XSTATE, "judge-task", SID)
answers(XSTATE, "judge-task", SID, {"findings": []})
run_cases(XSTATE, XGROUPS)
ok("stale_input: an answer to unchanged content is kept", os.path.exists(tp + ".answer.json"))
ok("stale_input: a digest sits beside the input", os.path.isfile(tp + ".digest") and len(open(tp + ".digest").read().strip()) == 64)
edited = [dict(g) for g in XGROUPS]
edited[0] = group("gone1", XG, [review("review", "2026-10-01T09:30:00.000Z", [(X0, ONE[0])], ONE[0], report="one: review"),
                                review("re-review", "2026-10-01T10:30:00.000Z", [(ONE[0], ONE[1])], ONE[1], report="one: fixed, edited"),
                                review("re-review", "2026-10-01T10:35:00.000Z", [(X0, ONE[0])], ONE[0], report="one: fixed again")])
run_cases(XSTATE, edited)
ok("stale_input: changed content rewrites the input", "one: fixed, edited" in open(tp + ".json").read())
ok("stale_input: and sets the old answer aside, under a name that is not an answer",
   not os.path.exists(tp + ".answer.json") and any(n.startswith(SID + ".stale-") and n.endswith(".answer.json") for n in os.listdir(os.path.dirname(tp))))
ok("stale_input: so it shows as pending again", ("judge-task", SID) in [(k, j) for k, j, *_ in C.pending(XSTATE)])

# ---- the destination's history is not in the snapshot at all
os.makedirs(os.path.join(ROOT, "no-main-snap", "xrepo", "objects"))
run_cases(os.path.join(ROOT, "w-x", "state2"), XGROUPS, root=os.path.join(ROOT, "no-main-snap"))
_d, byx = branches(os.path.join(ROOT, "w-x", "state2"))
is_("dest_tip_missing: a repository whose destination the snapshot lacks says so", byx["one"]["why"], "destination tip not in the snapshot")


# ================================================================ a range must be the branch's own, base to head
def scope_of(repo, base, tip, exclude=(), bases=None):
    rows = repo.commits(base, tip, list(exclude))
    return {"repo": repo, "base": base, "tip": tip, "exclude": list(exclude), "rows": rows, "own": set(s for s, _t in rows), "copies": None,
            "bases": bases or {base}}


# ---- a derived range starts on this branch, not on another branch's commit
DR = helpers.make_repo(ROOT, "derivrepo")
with dated("2026-09-01T10:00:00Z"):
    put(DR, "root.txt", "r\n")
    helpers.commit(DR, "root")
with dated("2026-09-02T10:00:00Z"):
    put(DR, "main.txt", "v0\n")
    D0 = helpers.commit(DR, "x0")
DO = make_branch(DR, "one", D0, [("2026-10-01T09:00:00Z", {"one.txt": "o1\n"}, "o1")])
DT = make_branch(DR, "two", D0, [("2026-10-02T09:00:00Z", {"two.txt": "t1\n"}, "t1"), ("2026-10-02T10:00:00Z", {"two.txt": "t2\n"}, "t2")])
DEST = world("w-deriv")
drepo = I.Repo(DEST, C.L.common_dir(DR), NO_SNAPSHOT)
dscope = scope_of(drepo, D0, DT[-1])
dgroup = {"id": "gx", "reviews": [
    review("review", "2026-10-01T09:30:00.000Z", [(D0, DO[0])], DO[0]),
    review("re-review", "2026-10-02T10:30:00.000Z", [], DT[1])]}
dres = I.resolve_group(drepo, dgroup)
pair, why = I.derive(drepo, dscope, dres, 1, dgroup["reviews"][1], [1])
is_("derive_own_branch: an earlier review that belongs to another branch is not the base", (pair, why[:44]),
    (None, "no earlier review of the task on this branch"))
pair, why = I.derive(drepo, dscope, dres, 1, dgroup["reviews"][1], [0, 1])
is_("derive_own_branch: control: were it this branch's, it would be the base", (pair and pair[0], why), (DO[0], None))
# changes_of hands derive the indices of this branch's reviews: the nearer review on another branch is not the base
cgroup = group("gy", C.L.common_dir(DR), [
    review("review", "2026-10-02T09:30:00.000Z", [(D0, DT[0])], DT[0]),
    review("review", "2026-10-02T09:40:00.000Z", [(D0, DO[0])], DO[0]),
    review("re-review", "2026-10-02T10:30:00.000Z", [], DT[1])])
cres = I.resolve_group(drepo, cgroup)
chs, gone = I.changes_of(drepo, dscope, cgroup, cres, [0, 2])
is_("changes_of_own_reviews: a range-less re-review of branch two takes the earlier review of branch two as its base, not the nearer review of branch one",
    ([c["range"] for c in chs], gone), ([(DT[0], DT[1])], []))
is_("fix_range_ancestry: a range whose base is not an ancestor of its head is not kept even when b..h are all the branch's own",
    (all(s in dscope["own"] for s, _t in drepo.commits(DO[0], DT[1])), I.fix_range(drepo, dscope, DO[0], DT[1])), (True, None))
ok("fix_range_ancestry: control: an ordinary own range is kept", I.fix_range(drepo, dscope, DT[0], DT[1]) == (DT[0], DT[1]))

# ---- a branch that merged main into itself keeps a valid range as it was
MRE = helpers.make_repo(ROOT, "mergedinrepo")
with dated("2026-09-01T10:00:00Z"):
    put(MRE, "root.txt", "r\n")
    helpers.commit(MRE, "root")
with dated("2026-09-02T10:00:00Z"):
    put(MRE, "main.txt", "v0\n")
    N0 = helpers.commit(MRE, "x0")
FA1 = make_branch(MRE, "feat", N0, [("2026-10-01T09:00:00Z", {"a.txt": "a1\n"}, "a1")])[0]
put(MRE, "main.txt", "v1 main moved\n")
with dated("2026-10-01T10:00:00Z"):
    N1 = helpers.commit(MRE, "m1")
git(MRE, "checkout", "-q", "feat")
with dated("2026-10-01T11:00:00Z"):
    git(MRE, "merge", "-q", "--no-edit", "main")
put(MRE, "a.txt", "a2\n")
with dated("2026-10-01T12:00:00Z"):
    FA2 = helpers.commit(MRE, "a2")
git(MRE, "checkout", "-q", "main")
mrepo2 = I.Repo(world("w-mergedin"), C.L.common_dir(MRE), NO_SNAPSHOT)
mscope = scope_of(mrepo2, N1, FA2, [N1], {N0, N1})
rng = I.fix_range(mrepo2, mscope, N0, FA1)
is_("fix_range_old_base: a valid (old base, head) stays as it was; main's change is not reverted in it", rng, (N0, FA1))
ok("fix_range_old_base: its patch is the branch's commit only", "main.txt" not in mrepo2.patch(*rng) and "+a1" in mrepo2.patch(*rng))
is_("fix_range_old_base: the substitution still happens when the range fails as written (a rebased branch: see rebased_between_rounds)",
    I.fix_range(mrepo2, mscope, N0, FA2), (N1, FA2))

# ---- an inventory goes when its answers do: pending, not opened, no longer a candidate
os.environ["XDG_STATE_HOME"], os.environ["CODEX_HOME"] = os.path.join(ROOT, "w-x", "xdg"), os.path.join(ROOT, "w-x", "codex")
RBINV = os.path.join(XSTATE, "inventory", RBID + ".json")
ok("stale_inventory: control: rb's inventory is there", os.path.exists(RBINV))
edited2 = [dict(g) for g in edited]
k = [g["id"] for g in edited2].index("grb")
edited2[k] = group("grb", XG, [dict(r, report=r["report"] + ", edited") if r["kind"] == "re-review" else r for r in XGROUPS[k]["reviews"]], task=5)
run_cases(XSTATE, edited2)
ok("stale_inventory: a changed input makes its branch pending, and its old inventory goes", not os.path.exists(RBINV))
answers(XSTATE, "judge-task", "grb-" + RBID, {"findings": []})
run_cases(XSTATE, edited2)
ok("stale_inventory: answered again, it is written again", os.path.exists(RBINV))
run_cases(XSTATE, edited2, open=0)
ok("stale_inventory: a branch no longer opened loses its inventory", not os.path.exists(RBINV))
C.jsave(os.path.join(XSTATE, "inventory", "bdeadbeef.json"), {"branch": "bdeadbeef", "defects": [], "dropped": []})
run_cases(XSTATE, edited2)
ok("stale_inventory: opened again it is back, and one for a branch that is no longer examined is removed",
   os.path.exists(RBINV) and not os.path.exists(os.path.join(XSTATE, "inventory", "bdeadbeef.json")))
run_cases(XSTATE, edited2, dry=True, open=0)
ok("stale_inventory: a dry run removes nothing", os.path.exists(RBINV))
