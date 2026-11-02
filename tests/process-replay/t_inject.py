import collections
import contextlib
import io
import json
import os
import re
import shutil
import stat
import sys
from argparse import Namespace

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import helpers
from helpers import git, git_ok, is_, ok, put

helpers.setup()
from process_replay import common as C  # noqa: E402
from process_replay import inject as INJ  # noqa: E402

ROOT = helpers.tmp_root()
NO_SNAPSHOT = os.path.join(ROOT, "no-snapshot")
PLAN = "docs/superpowers/plans/p.md"


class dated(object):
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


def cm(repo, when, files, msg):
    for path, text in files.items():
        put(repo, path, text)
    with dated(when):
        return helpers.commit(repo, msg)


def world(name):
    """A fresh state directory and a fresh XDG_STATE_HOME (the alias symlinks go there)."""
    base = os.path.join(ROOT, name)
    os.environ["XDG_STATE_HOME"] = os.path.join(base, "xdg")
    os.makedirs(os.environ["XDG_STATE_HOME"])
    return os.path.join(base, "state")


def dfx(did, cls, sev, fixes, file, files=None):
    return {"id": did, "class": cls, "severity": sev, "counted": sev in ("P0", "P1", "P2"), "summary": "defect " + did, "file": file, "line": 2,
            "failure_scenario": "when " + did, "fixes": [list(f) for f in fixes], "files": files or [file], "at": "2026-10-01T00:00:00Z"}


def rec_branch(bid, repo, name, base, tip, plan, at="2026-10-20T10:00:00.000000Z", merged="2026-10-25T10:00:00Z", opened=True):
    return {"id": bid, "repo": os.path.join(repo, ".git"), "objects": None, "view": "", "dest": "main", "dest_ref": "main", "branch": name,
            "base": base, "rounds": [{"k": 1, "nonce": "n" + bid, "tip": tip, "base": base, "thread": "t", "turns": [], "at": at, "verdict": "approve"}],
            "round1_tip": tip, "final_tip": tip, "plan_commit": plan, "groups": [], "joined": [], "candidate": True, "opened": opened, "why": None,
            "merged": {"how": "ancestry", "commit": tip, "at": merged}, "unresolved_ranges": 0, "off_branch_ranges": 0, "skipped_rounds": []}


def setup_state(name, branches, inventories):
    state = world(name)
    C.jsave(os.path.join(state, "branches.json"), {"branches": branches})
    for bid, defects in inventories.items():
        C.jsave(os.path.join(state, "inventory", bid + ".json"), {"branch": bid, "defects": defects, "dropped": []})
    return state


def args(state, dry=False):
    return Namespace(state=state, dry_run=dry, snapshot_root=NO_SNAPSHOT, budget=3600, open=16)


def run(state, dry=False):
    buf = io.StringIO()
    with contextlib.redirect_stdout(buf):
        rc = INJ.cmd_inject(args(state, dry))
    return rc, buf.getvalue()


def answer(state, kind, jid, doc):
    C.jsave(os.path.join(state, kind, jid + ".answer.json"), doc)


def inj(state, bid):
    return C.jload(os.path.join(state, "injected", bid + ".json"))


def cases(state):
    return C.jload(os.path.join(state, "cases.json"))


def show(work, commit, path):
    return git(work, "show", "{}:{}".format(commit, path))


def has(work, commit, path):
    return git_ok(work, "cat-file", "-e", "{}:{}".format(commit, path))


def inputs(state, kind):
    d = os.path.join(state, kind)
    return sorted(n[:-5] for n in os.listdir(d) if n.endswith(".json") and not n.endswith(".answer.json") and n != "needed.json") if os.path.isdir(d) else []


def examined(state, bid):
    return [e for e in cases(state)["examined"] if e["branch"] == bid][0]


def of(name):
    """The defect a judge input is about: its id is <defect>-<digest of the input>."""
    return name.split("-")[0]


def unanswered(state, kind):
    return [n for n in inputs(state, kind) if not os.path.exists(os.path.join(state, kind, n + ".answer.json"))]


def judged(state, kind, did):
    """The questions of `kind` asked about `did`."""
    return [n for n in inputs(state, kind) if of(n) == did]


def say(state, did, ans, kind="judge-present"):
    """Answer every question about `did` that waits; the questions answered."""
    names = [n for n in unanswered(state, kind) if of(n) == did]
    for n in names:
        answer(state, kind, n, {"answer": ans})
    return names


def only(state, did, kind="judge-present"):
    """The input of the one question about `did`."""
    names = judged(state, kind, did)
    assert len(names) == 1, (did, names)
    return C.jload(os.path.join(state, kind, names[0] + ".json"))


def yes_all(state, ids, kind="judge-present"):
    for i in ids:
        say(state, i, "yes", kind)


# ================================================================ the main fixture
R = helpers.make_repo(ROOT, "mainrepo")
BASE = cm(R, "2026-09-20T10:00:00Z", {"README.md": "r\n"}, "base")
git(R, "checkout", "-q", "-b", "feat")
T1 = cm(R, "2026-10-01T09:00:00Z", {
    "src/a.py": "def a():\n    return 1  # bug A\n", "src/b.py": "def b():\n    return 1  # bug B\n",
    "src/c.py": "def c():\n    return 1  # bug C\n", PLAN: "plan v1\n"}, "task 1")
FA = cm(R, "2026-10-01T10:00:00Z", {"src/a.py": "def a():\n    return 2  # fixed A\n", "tests/test_a.py": "assert a() == 2\n"}, "fix A")
FBC = cm(R, "2026-10-01T11:00:00Z", {
    "src/b.py": "def b():\n    return 2  # fixed B\n", "src/c.py": "def c():\n    return 2  # fixed C\n", PLAN: "plan v2 done\n",
    "tests/test_b.py": "assert b() == 2\n", "tests/test_c.py": "assert c() == 2\n",
    "docs/superpowers/specs/late.md": "late\n"}, "fix B and C")
LATER = cm(R, "2026-10-02T09:00:00Z", {"src/d.py": "def d():\n    return 1  # bug D\n"}, "later work")
FD = cm(R, "2026-10-02T10:00:00Z", {"src/d.py": "def d():\n    return 2  # fixed D\n"}, "pre-merge fix")
git(R, "checkout", "-q", "main")
DA = dfx("d0000000a", "task", "P1", [(T1, FA)], "src/a.py")
DB = dfx("d0000000b", "task", "P2", [(FA, FBC)], "src/b.py")
DC = dfx("d0000000c", "task", "P2", [(FA, FBC)], "src/c.py")
DD = dfx("d0000000d", "pre", "P1", [(LATER, FD)], "src/d.py")
MAIN = rec_branch("bmain0001", R, "feat", BASE, FD, T1)
IDS = [d["id"] for d in (DA, DB, DC, DD)]


def main_state(name, defects=None, branch=None):
    return setup_state(name, [branch or MAIN], {"bmain0001": defects or [DA, DB, DC, DD]})


def split_input(state):
    names = inputs(state, "judge-split")
    return names, [C.jload(os.path.join(state, "judge-split", n + ".json")) for n in names]


def split_answer(state, first, second):
    names, docs = split_input(state)
    d = docs[0]
    by_summary = dict((x["summary"], x["index"]) for x in d["defects"])
    files = dict((h["file"], h["index"]) for h in d["hunks"])
    out = [{"index": files["src/b.py"], "defect": first(by_summary)}, {"index": files["tests/test_b.py"], "defect": first(by_summary)},
           {"index": files["src/c.py"], "defect": second(by_summary)}, {"index": files["tests/test_c.py"], "defect": second(by_summary)}]
    answer(state, "judge-split", names[0], {"hunks": out})


# ---- the split judge, then the injected tree
S1 = main_state("w-main")
rc, out = run(S1)
is_("exits 0", rc, 0)
names, docs = split_input(S1)
is_("split_groups: one judge-split for the range two defects share", len(names), 1)
d0 = docs[0]
is_("split_groups: its hunks are the code and test hunks only, one per file, with fresh indices", [(h["index"], h["file"]) for h in d0["hunks"]],
    [(0, "src/b.py"), (1, "src/c.py"), (2, "tests/test_b.py"), (3, "tests/test_c.py")])
is_("split_groups: its defects are the two that share the range", sorted(x["summary"] for x in d0["defects"]), ["defect d0000000b", "defect d0000000c"])
is_("split_groups: input keys", (sorted(d0), sorted(d0["defects"][0])), (["defects", "hunks"], ["file", "index", "line", "summary"]))
ok("split_groups: nothing is built while the split judge has not answered", not os.path.exists(os.path.join(S1, "work")) and not os.path.exists(os.path.join(S1, "injected")))
ok("split_groups: and the branch is waiting in cases.json", examined(S1, "bmain0001")["qualified"] is False and cases(S1)["cases"] == [])
split_answer(S1, lambda m: m["defect d0000000b"], lambda m: m["defect d0000000c"])
rc, out = run(S1)
r1 = inj(S1, "bmain0001")
W, WC = r1["work"], r1["work_commit"]
is_("revert_whole_with_tests: the work repository is private to the state", W, os.path.join(S1, "work", "bmain0001"))
ok("revert_whole_with_tests: the injected tree has bug A's code", "bug A" in show(W, WC, "src/a.py"), show(W, WC, "src/a.py"))
ok("revert_whole_with_tests: and lacks fix A's test change", not has(W, WC, "tests/test_a.py"))
ok("split_groups: B and C are reverted by their own hunks", "bug B" in show(W, WC, "src/b.py") and "bug C" in show(W, WC, "src/c.py"))
ok("split_groups: and their regression tests are reverted with them", not has(W, WC, "tests/test_b.py") and not has(W, WC, "tests/test_c.py"))
ok("revert_whole_with_tests: the pre-merge defect is reverted too", "bug D" in show(W, WC, "src/d.py"))
is_("docs_pinned: docs/superpowers equals the plan commit's", show(W, WC, PLAN), "plan v1")
ok("docs_pinned: files added to docs/superpowers later are gone", not has(W, WC, "docs/superpowers/specs/late.md"))
is_("docs_pinned: the record names the plan commit", r1["plan_commit"], T1)
is_("revert_whole_with_tests: the injected commit's parent is the final tree's commit", git(W, "rev-parse", WC + "~1"), r1["final_commit"])
is_("revert_whole_with_tests: the final tree's commit holds the branch's final tree", git(W, "rev-parse", r1["final_commit"] + "^{tree}"),
    git(R, "rev-parse", FD + "^{tree}"))
is_("validation: a judge-present per reverted defect is waiting", sorted(of(n) for n in unanswered(S1, "judge-present")), sorted(IDS))
ok("validation: each is a question keyed by its input: <defect>-<12 hex>", all(re.match(r"\Ad[0-9a-f]{8}-[0-9a-f]{12}\Z", n) for n in inputs(S1, "judge-present")),
   inputs(S1, "judge-present"))
pi = only(S1, "d0000000a")
is_("validation: its input is the finding and the files, as a list", (sorted(pi), sorted(pi["finding"]), [f["path"] for f in pi["files"]]),
    (["files", "finding"], ["failure_scenario", "file", "line", "severity", "summary"], ["src/a.py"]))
ok("validation: the file is the injected tree's, bug included", "bug A" in pi["files"][0]["text"])
is_("revert_whole_with_tests: nothing is complete before the validations answer", r1["complete"], False)
for d in IDS:
    p = os.path.join(S1, "repairs", d + ".patch")
    ok("repairs: no repair patch before the defect is shown present ({})".format(d), not os.path.exists(p))

# ---- present, repairs, hunks, the case
yes_all(S1, IDS)
rc, out = run(S1)
r2 = inj(S1, "bmain0001")
is_("validation: judge-present yes makes every defect present", sorted((k, v["status"]) for k, v in r2["defects"].items()), sorted((i, "present") for i in IDS))
is_("revert_whole_with_tests: the work commit did not move", (r2["work_commit"], r2["complete"]), (WC, True))
rep = dict((i, open(os.path.join(S1, "repairs", i + ".patch")).read()) for i in IDS)
ok("revert_whole_with_tests: A's repair holds its code and its test", "src/a.py" in rep["d0000000a"] and "tests/test_a.py" in rep["d0000000a"])
ok("split_groups: B's repair holds B's hunk only", "src/b.py" in rep["d0000000b"] and "src/c.py" not in rep["d0000000b"], rep["d0000000b"])
ok("split_groups: and C's holds C's only", "src/c.py" in rep["d0000000c"] and "src/b.py" not in rep["d0000000c"])
ok("split_groups: each repair holds its own regression test", "tests/test_b.py" in rep["d0000000b"] and "tests/test_c.py" not in rep["d0000000b"]
   and "tests/test_c.py" in rep["d0000000c"] and "tests/test_b.py" not in rep["d0000000c"])
ok("docs_pinned: no repair patch names a docs/superpowers path", all("docs/superpowers" not in t for t in rep.values()))
is_("split_groups: split defects are groups of their own", (r2["defects"]["d0000000b"]["group"], r2["defects"]["d0000000c"]["group"]),
    ("d0000000b", "d0000000c"))
is_("revert_whole_with_tests: a defect record's fields", sorted(r2["defects"]["d0000000a"]), ["group", "hunks", "reason", "repair", "status"])
is_("revert_whole_with_tests: its repair is the patch file", r2["defects"]["d0000000a"]["repair"], os.path.join(S1, "repairs", "d0000000a.patch"))
is_("hunks: a defect's hunks locate its change in the finished injected tree (and in the repaired one)", r2["defects"]["d0000000a"]["hunks"],
    [{"file": "src/a.py", "start": 1, "end": 2, "new_start": 1, "new_end": 2}, {"file": "tests/test_a.py", "start": 1, "end": 1, "new_start": 1, "new_end": 1}])
p = C.git_run(W, ["apply", "--check", os.path.join(S1, "repairs", "d0000000a.patch")])
is_("revert_whole_with_tests: the repair applies to the injected tree", p.returncode, 0)
cs = cases(S1)
is_("qualify: the branch is a case with every present defect", [(c["branch"], sorted(c["defects"]), c["work_commit"], c["original_rounds"], c["repo"])
                                                          for c in cs["cases"]], [("bmain0001", sorted(IDS), WC, 1, MAIN["repo"])])
is_("qualify: the case id", cs["cases"][0]["id"], "cmain0001")
is_("qualify: examined and coverage", (examined(S1, "bmain0001")["qualified"], examined(S1, "bmain0001")["why"], cs["coverage"]),
    (True, None, {"unassessable_task": []}))
# idempotent
before = (open(os.path.join(S1, "injected", "bmain0001.json")).read(), open(os.path.join(S1, "cases.json")).read())
run(S1)
is_("idempotent: a run with no new answer changes nothing", (open(os.path.join(S1, "injected", "bmain0001.json")).read(), open(os.path.join(S1, "cases.json")).read()), before)

# ---- the invariant: the tree holds nothing the repairs do not undo
r1c = inj(S1, "bmain0001")
steps = [(i, open(os.path.join(S1, "repairs", i + ".patch")).read()) for i in ("d0000000a", "d0000000b", "d0000000c", "d0000000d")]
try:
    INJ.check_invariant(MAIN, r1c["work"], r1c["final_commit"], r1c["work_commit"], steps)
    got = "holds"
except C.Failed as e:
    got = str(e)
is_("invariant: re-applying every repair, oldest fix first, and restoring docs/superpowers gives the final tree", got, "holds")
try:
    INJ.check_invariant(MAIN, r1c["work"], r1c["final_commit"], r1c["work_commit"], [x for x in steps if x[0] != "d0000000c"])
    got = "holds"
except C.Failed as e:
    got = str(e)
ok("invariant: an edit no repair undoes (here: one repair left out) fails it, naming the branch and the file", "bmain0001" in got and "src/c.py" in got, got)

# ---- an unsure split makes one group, one patch
S2 = main_state("w-unsure")
run(S2)
split_answer(S2, lambda m: "unsure", lambda m: m["defect d0000000c"])
run(S2)
yes_all(S2, IDS)
run(S2)
r = inj(S2, "bmain0001")
g = set(r["defects"][i]["group"] for i in ("d0000000b", "d0000000c"))
is_("split_groups: unsure on one hunk makes B and C one group", len(g), 1)
pb, pc = (open(os.path.join(S2, "repairs", i + ".patch")).read() for i in ("d0000000b", "d0000000c"))
ok("split_groups: with one patch holding both hunks", pb == pc and "src/b.py" in pb and "src/c.py" in pb, pb)
ok("split_groups: and docs still out of it", "docs/superpowers" not in pb)
w2 = r["work"]
ok("split_groups: both are reverted in the tree", "bug B" in show(w2, r["work_commit"], "src/b.py") and "bug C" in show(w2, r["work_commit"], "src/c.py"))
is_("split_groups: the record has both members' hunks for the group", r["defects"]["d0000000b"]["hunks"], r["defects"]["d0000000c"]["hunks"])

# a hunk the judge gives to none stays in the tree; a missing answer entry counts as unsure
S2b = main_state("w-null")
run(S2b)
names, docs = split_input(S2b)
fb = dict((h["file"], h["index"]) for h in docs[0]["hunks"])
bi = dict((x["summary"], x["index"]) for x in docs[0]["defects"])["defect d0000000b"]
answer(S2b, "judge-split", names[0], {"hunks": [{"index": fb["src/b.py"], "defect": bi}, {"index": fb["tests/test_b.py"], "defect": bi},
                                                {"index": fb["src/c.py"], "defect": None}, {"index": fb["tests/test_c.py"], "defect": None}]})
run(S2b)
r = inj(S2b, "bmain0001")
ok("split_groups: a hunk given to none is not reverted", "fixed C" in show(r["work"], r["work_commit"], "src/c.py") and "bug B" in show(r["work"], r["work_commit"], "src/b.py"))
ok("split_groups: and the defect with no hunk left is dropped-revert", r["defects"]["d0000000c"]["status"] == "dropped-revert", r["defects"]["d0000000c"])

# ---- validation: yes, no, unclear
S3 = main_state("w-valid")
run(S3)
split_answer(S3, lambda m: m["defect d0000000b"], lambda m: m["defect d0000000c"])
run(S3)
say(S3, "d0000000a", "yes")
say(S3, "d0000000b", "no")
say(S3, "d0000000c", "unclear")
say(S3, "d0000000d", "yes")
run(S3)
r = inj(S3, "bmain0001")
is_("validation: yes is present; no and unclear are not-present", dict((k, v["status"]) for k, v in r["defects"].items()),
    {"d0000000a": "present", "d0000000b": "not-present", "d0000000c": "not-present", "d0000000d": "present"})
ok("validation: a not-present defect has no repair patch", not os.path.exists(os.path.join(S3, "repairs", "d0000000b.patch")))
ok("coverage_gate: the not-present per-task defects get a recreation brief", inputs(S3, "recreate") == ["d0000000b", "d0000000c"], inputs(S3, "recreate"))

# ---- a pre-merge P1 not shown present disqualifies; a P2 only counts
S3b = main_state("w-p1")
run(S3b)
split_answer(S3b, lambda m: m["defect d0000000b"], lambda m: m["defect d0000000c"])
run(S3b)
yes_all(S3b, IDS[:3])
say(S3b, "d0000000d", "no")
run(S3b)
e = examined(S3b, "bmain0001")
ok("qualify: a pre-merge P1 that is not shown present disqualifies the branch", e["qualified"] is False and "P1" in e["why"] and cases(S3b)["cases"] == [], e)
ok("coverage_gate: nothing to recreate while every per-task defect is assessable", inputs(S3b, "recreate") == [] and cases(S3b)["coverage"] == {"unassessable_task": []})
DD2 = dict(DD, severity="P2")
S3c = main_state("w-p2", [DA, DB, DC, DD2])
run(S3c)
split_answer(S3c, lambda m: m["defect d0000000b"], lambda m: m["defect d0000000c"])
run(S3c)
yes_all(S3c, IDS[:3])
say(S3c, "d0000000d", "no")
run(S3c)
cs = cases(S3c)
ok("qualify: an unassessable pre-merge P2 is counted, not disqualifying", len(cs["cases"]) == 1 and sorted(cs["cases"][0]["defects"]) == sorted(IDS[:3]), cs)
is_("qualify: and examined counts it", examined(S3c, "bmain0001")["counts"].get("not-present"), 1)

# ---- no plan commit
S3d = main_state("w-noplan", branch=dict(MAIN, plan_commit=None))
run(S3d)
ok("docs_pinned: a branch with no plan commit cannot be pinned and does not qualify", examined(S3d, "bmain0001")["qualified"] is False
   and "plan" in examined(S3d, "bmain0001")["why"] and not os.path.exists(os.path.join(S3d, "work")), examined(S3d, "bmain0001"))

# ---- dry run writes judge inputs and briefs only
S4 = main_state("w-dry")
rc, out = run(S4, dry=True)
is_("dry_run: exits 0", rc, 0)
written = sorted(os.path.relpath(os.path.join(d, f), S4) for d, _s, fs in os.walk(S4) for f in fs)
ok("dry_run: nothing but judge inputs and briefs (and the files the run was given)", bool(written) and all(
    w.startswith(("judge", "views" + os.sep, "inventory" + os.sep)) or w in ("alias", "branches.json") for w in written), written)
ok("dry_run: no work repository, no injected record, no cases.json", not any(os.path.exists(os.path.join(S4, x)) for x in ("work", "injected", "cases.json", "repairs")))
is_("dry_run: the judge-split input is written", len(inputs(S4, "judge-split")), 1)

# ================================================================ a fix whose context a later commit rewrote; the coverage gate
RC = helpers.make_repo(ROOT, "confrepo")
BC = cm(RC, "2026-09-20T10:00:00Z", {"README.md": "r\n"}, "base")
git(RC, "checkout", "-q", "-b", "feat")
TC = cm(RC, "2026-10-01T09:00:00Z", {"src/e.py": "line1\nline2 bug E\nline3\n", "src/f.py": "def f():\n    return 1  # bug F\n", PLAN: "plan\n"}, "task 1")
FE = cm(RC, "2026-10-01T10:00:00Z", {"src/e.py": "line1\nline2 fixed E\nline3\n"}, "fix E")
FF = cm(RC, "2026-10-01T11:00:00Z", {"src/f.py": "def f():\n    return 2  # fixed F\n"}, "fix F")
LC = cm(RC, "2026-10-02T09:00:00Z", {"src/e.py": "line1\nline2 rewritten\nline3\n"}, "rewrite")
git(RC, "checkout", "-q", "main")
DE = dfx("d0000000e", "task", "P1", [(TC, FE)], "src/e.py")
DF = dfx("d0000000f", "task", "P2", [(FE, FF)], "src/f.py")
CONF = rec_branch("bconf0001", RC, "feat", BC, LC, TC)
FINAL_E = "line1\nline2 rewritten\nline3\n"


def conf_state(name, de=DE, df=DF):
    return setup_state(name, [CONF], {"bconf0001": [de, df]})


S5 = conf_state("w-conf")
run(S5)
r = inj(S5, "bconf0001")
is_("revert_conflict_dropped: a fix whose context was rewritten is dropped-revert", r["defects"]["d0000000e"]["status"], "dropped-revert")
ok("revert_conflict_dropped: with a reason", bool(r["defects"]["d0000000e"]["reason"]), r["defects"]["d0000000e"])
ok("revert_conflict_dropped: the others still revert", "bug F" in show(r["work"], r["work_commit"], "src/f.py") and
   show(r["work"], r["work_commit"], "src/e.py") + "\n" == FINAL_E)
is_("revert_conflict_dropped: the drop is counted in examined", examined(S5, "bconf0001")["counts"].get("dropped-revert"), 1)
is_("validation: only the reverted defect is sent to a judge", [of(n) for n in inputs(S5, "judge-present")], ["d0000000f"])
is_("coverage_gate: a per-task defect that leaves the tree gets its recreation request at once: it never comes back by its revert", inputs(S5, "recreate"),
    ["d0000000e"])
yes_all(S5, ["d0000000f"])
run(S5)
is_("coverage_gate: an unassessable per-task P1 gets a recreation brief", inputs(S5, "recreate"), ["d0000000e"])
brief = C.jload(os.path.join(S5, "recreate", "d0000000e.json"))
is_("coverage_gate: the brief is {finding, fix, tree}", sorted(brief), ["finding", "fix", "tree"])
ok("coverage_gate: the finding has no class", "class" not in brief["finding"] and brief["finding"]["summary"] == "defect d0000000e", brief["finding"])
ok("coverage_gate: the fix is the defect's fix diff", "fixed E" in brief["fix"] and "+line2 fixed E" in brief["fix"], brief["fix"])
TREE = os.path.join(S5, "recreate", "d0000000e", "tree")
is_("coverage_gate: the tree path is the state's recreate/<id>/tree, handed out under the state's alias", (os.path.realpath(brief["tree"]), brief["tree"].startswith(os.path.join(os.environ["XDG_STATE_HOME"], "review-work") + os.sep)),
    (os.path.realpath(TREE), True))
is_("coverage_gate: the tree is a plain copy of the final tree", (open(os.path.join(TREE, "src", "e.py")).read(), os.path.exists(os.path.join(TREE, ".git")),
                                                                   open(os.path.join(TREE, "src", "f.py")).read()),
    (FINAL_E, False, "def f():\n    return 2  # fixed F\n"))
is_("coverage_gate: pending lists the recreation until it is done", [(k, i) for k, i, *_ in C.pending(S5) if k == "recreate"], [("recreate", "d0000000e")])
BRIEF_MD = os.path.join(S5, "recreate", "d0000000e.brief.md")
item = [x for x in C.pending(S5) if x[0] == "recreate"][0]
is_("recreation_brief: pending hands out the recreation's own brief, under the alias", (os.path.realpath(item[4]), item[4].endswith("d0000000e.brief.md")),
    (os.path.realpath(BRIEF_MD), True))
text = open(BRIEF_MD).read()
ok("recreation_brief: it names the spec, the tree and the done file, by the paths the agent is given", brief["tree"] in text
   and C.aliased(S5, os.path.join(S5, "recreate", "d0000000e.json")) in text and C.aliased(S5, os.path.join(S5, "recreate", "d0000000e", "done")) in text, text)
ok("recreation_brief: it says what to edit, to undo the fix and nothing else, no git, and to finish with an empty done file",
   "Edit only the files under" in text and "undo what the fix did, and nothing else" in text and "Do not use git" in text and "create an empty file" in text, text)
ok("recreation_brief: and says nothing of replay, inject, removal, per-task, arm or run", not re.search(r"replay|inject|removal|per-task|\barm\b|\brun\b", text, re.I), text)
ok("recreation_brief: the brief text holds no path under the state itself", "/state/" not in text, text)


def recreate(state, edits, same, present=None):
    """Edit the tree, finish, run; answer judge-same; run; answer judge-present on the finished tree; run."""
    for path, text in edits.items():
        put(os.path.join(state, "recreate", "d0000000e", "tree"), path, text)
    run(state)
    ok("coverage_gate: nothing is judged before the agent signals it is finished", inputs(state, "judge-same") == [], inputs(state, "judge-same"))
    put(os.path.join(state, "recreate", "d0000000e"), "done", "")
    run(state)
    say(state, "d0000000e", same, "judge-same")
    run(state)
    if present:
        ok("coverage_gate: a recreation the judge accepts is judged on the tree it joins, alone", [of(n) for n in unanswered(state, "judge-present")] == ["d0000000e"],
           unanswered(state, "judge-present"))
        say(state, "d0000000e", present)
        run(state)


run(S5)
recreate(S5, {"src/e.py": "line1\nline2 BUG E recreated\nline3\n"}, "yes", "yes")
is_("revalidate: a present defect whose files the recreation did not touch is not asked again: the same input is the same question",
    len(judged(S5, "judge-present", "d0000000f")), 1)
js = only(S5, "d0000000e", "judge-same")
is_("coverage_gate: judge-same holds the original finding and fix, and the candidate patch", (sorted(js), sorted(js["original"]), sorted(js["candidate"])),
    (["candidate", "original"], ["finding", "fix"], ["patch"]))
ok("coverage_gate: the candidate patch is the agent's edit", "+line2 BUG E recreated" in js["candidate"]["patch"] and "-line2 rewritten" in js["candidate"]["patch"], js["candidate"]["patch"])
pr = only(S5, "d0000000e")
ok("coverage_gate: judge-present on the finished tree shows the recreated code", "BUG E recreated" in pr["files"][0]["text"], pr)
r = inj(S5, "bconf0001")
is_("coverage_gate: both yes make it recreated", r["defects"]["d0000000e"]["status"], "recreated")
ok("coverage_gate: the finished tree has the recreated defect and the reverted one", show(r["work"], r["work_commit"], "src/e.py") == "line1\nline2 BUG E recreated\nline3"
   and "bug F" in show(r["work"], r["work_commit"], "src/f.py"))
rp = r["defects"]["d0000000e"]["repair"]
ok("coverage_gate: its repair is the reverse patch", rp == os.path.join(S5, "repairs", "d0000000e.patch") and "+line2 rewritten" in open(rp).read(), rp)
p = C.git_run(r["work"], ["apply", "--check", rp])
is_("coverage_gate: the reverse patch applies to the finished tree", p.returncode, 0)
is_("coverage_gate: a recreated defect's hunks locate the reverse patch in the finished tree", r["defects"]["d0000000e"]["hunks"],
    [{"file": "src/e.py", "start": 1, "end": 3, "new_start": 1, "new_end": 3}])
cs = cases(S5)
is_("qualify: a recreated defect counts as assessable", (len(cs["cases"]), sorted(cs["cases"][0]["defects"]), cs["coverage"]),
    (1, ["d0000000e", "d0000000f"], {"unassessable_task": []}))

# judge-same no
S6 = conf_state("w-conf-no")
run(S6)
yes_all(S6, ["d0000000f"])
run(S6)
run(S6)
recreate(S6, {"src/e.py": "line1\nline2 something else\nline3\n"}, "no")
r = inj(S6, "bconf0001")
cs = cases(S6)
is_("coverage_gate: judge-same no leaves it unassessable", r["defects"]["d0000000e"]["status"], "unassessable")
is_("coverage_gate: listed in coverage.unassessable_task, and the branch does not qualify", (cs["coverage"], cs["cases"]),
    ({"unassessable_task": ["d0000000e"]}, []))
ok("coverage_gate: nothing is applied to the tree", show(r["work"], r["work_commit"], "src/e.py") + "\n" == FINAL_E)

# the patch does not apply to the injected tree: it touches what another revert changed
S7 = conf_state("w-conf-fail")
run(S7)
yes_all(S7, ["d0000000f"])
run(S7)
run(S7)
recreate(S7, {"src/f.py": "def f():\n    return 3  # recreated\n"}, "yes")
r = inj(S7, "bconf0001")
is_("coverage_gate: a patch that does not apply is unassessable", r["defects"]["d0000000e"]["status"], "unassessable")
is_("coverage_gate: and no judge-present was asked for it", judged(S7, "judge-present", "d0000000e"), [])
is_("coverage_gate: listed", cases(S7)["coverage"], {"unassessable_task": ["d0000000e"]})

# an untouched tree: nothing to judge
S8 = conf_state("w-conf-same")
run(S8)
yes_all(S8, ["d0000000f"])
run(S8)
run(S8)
put(os.path.join(S8, "recreate", "d0000000e"), "done", "")
run(S8)
is_("coverage_gate: a tree left as it was is unassessable without a judge", (inj(S8, "bconf0001")["defects"]["d0000000e"]["status"], inputs(S8, "judge-same")),
    ("unassessable", []))

# a P2 per-task defect that stays unassessable leaves one assessable per-task defect: not enough
DE2 = dict(DE, severity="P2")
S9 = conf_state("w-conf-p2", de=DE2)
run(S9)
yes_all(S9, ["d0000000f"])
run(S9)
run(S9)
recreate(S9, {"src/e.py": "line1\nline2 something else\nline3\n"}, "no")
e = examined(S9, "bconf0001")
ok("qualify: fewer than two assessable per-task defects disqualifies, though no P0/P1 is lost", e["qualified"] is False and "two" in e["why"] and cases(S9)["cases"] == [], e)
is_("coverage_gate: a P2 is listed too", cases(S9)["coverage"], {"unassessable_task": ["d0000000e"]})

# a group whose second piece does not revert leaves the tree as it found it
DX = dfx("d00000011", "task", "P1", [(TC, FE), (FE, FF)], "src/f.py", files=["src/e.py", "src/f.py"])
S10b = setup_state("w-partial", [CONF], {"bconf0001": [DX, dfx("d00000012", "task", "P2", [(BC, TC)], "src/f.py")]})
run(S10b)
r = inj(S10b, "bconf0001")
ok("revert_conflict_dropped: a defect with two fix ranges, one of which does not revert, is dropped whole and the tree is as the final one",
   r["defects"]["d00000011"]["status"] == "dropped-revert" and "fixed F" in show(r["work"], r["work_commit"], "src/f.py")
   and show(r["work"], r["work_commit"], "src/e.py") + "\n" == FINAL_E, r["defects"]["d00000011"])

# fewer than two per-task defects: not even built
S10 = setup_state("w-thin", [CONF], {"bconf0001": [DE, dfx("d00000010", "pre", "P1", [(FE, FF)], "src/f.py")]})
run(S10)
ok("qualify: a branch with fewer than two per-task defects is not built", not os.path.exists(os.path.join(S10, "work")) and examined(S10, "bconf0001")["qualified"] is False)

# ================================================================ coherence
RS = helpers.make_repo(ROOT, "shrepo")
BS = cm(RS, "2026-09-20T10:00:00Z", {"README.md": "r\n"}, "base")
git(RS, "checkout", "-q", "-b", "feat")
TS = cm(RS, "2026-10-01T09:00:00Z", {"x.sh": "echo hi\nif true; then\n  echo a\n", "y.py": "y = 1  # bug Y\n", PLAN: "plan\n"}, "task 1")
FX = cm(RS, "2026-10-01T10:00:00Z", {"x.sh": "echo hi\nif true; then\n  echo a\nfi\n"}, "fix x")
FY = cm(RS, "2026-10-01T11:00:00Z", {"y.py": "y = 2  # fixed Y\n"}, "fix y")
git(RS, "checkout", "-q", "main")
DX = dfx("d00000020", "task", "P1", [(TS, FX)], "x.sh")
DY = dfx("d00000021", "task", "P2", [(FX, FY)], "y.py")
SH = rec_branch("bsh000001", RS, "feat", BS, FY, TS)
S11 = setup_state("w-sh", [SH], {"bsh000001": [DX, DY]})
run(S11)
r = inj(S11, "bsh000001")
is_("coherence_undo: a revert that breaks bash -n on a .sh file is undone: incoherent", r["defects"]["d00000020"]["status"], "incoherent")
ok("coherence_undo: with the file and the reason", "x.sh" in r["defects"]["d00000020"]["reason"], r["defects"]["d00000020"])
is_("coherence_undo: the tree keeps the fixed script", show(r["work"], r["work_commit"], "x.sh"), "echo hi\nif true; then\n  echo a\nfi")
ok("coherence_undo: the other defect is reverted", "bug Y" in show(r["work"], r["work_commit"], "y.py"))
is_("coherence_undo: counted", examined(S11, "bsh000001")["counts"].get("incoherent"), 1)

# cargo
RG = helpers.make_repo(ROOT, "cargorepo")
BG = cm(RG, "2026-09-20T10:00:00Z", {"README.md": "r\n"}, "base")
git(RG, "checkout", "-q", "-b", "feat")
TG = cm(RG, "2026-10-01T09:00:00Z", {"Cargo.toml": "[package]\nname = \"x\"\nversion = \"0.1.0\"\n", "src/r1.rs": "fn r1() {} // MARK1\n",
                                      "src/r2.rs": "fn r2() {} // MARK2\n", "src/r3.rs": "fn r3() {} // MARK3\n", PLAN: "plan\n"}, "task 1")
G1 = cm(RG, "2026-10-01T10:00:00Z", {"src/r1.rs": "fn r1() {} // ok1\n"}, "fix 1")
G2 = cm(RG, "2026-10-01T11:00:00Z", {"src/r2.rs": "fn r2() {} // ok2\n"}, "fix 2")
G3 = cm(RG, "2026-10-01T12:00:00Z", {"src/r3.rs": "fn r3() {} // ok3\n"}, "fix 3")
git(RG, "checkout", "-q", "main")
DG = [dfx("d00000031", "task", "P1", [(TG, G1)], "src/r1.rs"), dfx("d00000032", "task", "P2", [(G1, G2)], "src/r2.rs"),
      dfx("d00000033", "task", "P2", [(G2, G3)], "src/r3.rs")]
CG = rec_branch("bcargo001", RG, "feat", BG, G3, TG)
STUB = os.path.join(ROOT, "stub")
os.makedirs(STUB)
LOG = os.path.join(ROOT, "cargo.log")
put(STUB, "cargo", "#!/bin/sh\necho \"$CARGO_TARGET_DIR|$*|$(pwd)\" >> {}\nif grep -q MARK2 src/r2.rs; then exit 1; fi\nexit 0\n".format(LOG))
os.chmod(os.path.join(STUB, "cargo"), 0o755)
old_path = os.environ["PATH"]
os.environ["PATH"] = STUB + os.pathsep + old_path
S12 = setup_state("w-cargo", [CG], {"bcargo001": DG})
run(S12)
os.environ["PATH"] = old_path
r = inj(S12, "bcargo001")
st = dict((k, v["status"]) for k, v in r["defects"].items())
is_("coherence_undo: cargo check failing after the last revert undoes reverts latest first until it passes",
    st, {"d00000031": "reverted", "d00000032": "incoherent", "d00000033": "incoherent"})
calls = [line.split("|") for line in open(LOG).read().splitlines()]
is_("coherence_undo: cargo check ran once at first and once after each undo", len(calls), 3)
is_("coherence_undo: offline, all targets, in the work repository, with a target dir of its own per repository",
    (calls[0][1], os.path.realpath(calls[0][2]), calls[0][0]), ("check --offline --all-targets", os.path.realpath(r["work"]), os.path.join(S12, "cargo", "cargorepo")))
ok("coherence_undo: the finished tree has the kept revert and the undone ones restored", "MARK1" in show(r["work"], r["work_commit"], "src/r1.rs")
   and "ok2" in show(r["work"], r["work_commit"], "src/r2.rs") and "ok3" in show(r["work"], r["work_commit"], "src/r3.rs"))
os.environ["PATH"] = STUB + os.pathsep + old_path
put(STUB, "cargo", "#!/bin/sh\necho x >> {}\nexit 0\n".format(LOG + "2"))
S12b = setup_state("w-cargo-ok", [CG], {"bcargo001": DG})
run(S12b)
os.environ["PATH"] = old_path
ok("coherence_undo: a cargo check that passes undoes nothing", all(v["status"] == "reverted" for v in inj(S12b, "bcargo001")["defects"].values()))

# ================================================================ order by position, committer date for a head that is not on the branch
RO = helpers.make_repo(ROOT, "orderrepo")
BO = cm(RO, "2026-09-20T10:00:00Z", {"README.md": "r\n"}, "base")
git(RO, "checkout", "-q", "-b", "feat")
TO = cm(RO, "2026-10-01T09:00:00Z", {"o.txt": "l1\nvalue 0\nl3\n", "p.py": "p = 1  # bug P\n", PLAN: "plan\n"}, "task 1")
O1 = cm(RO, "2026-10-02T09:00:00Z", {"o.txt": "l1\nvalue 1\nl3\n"}, "fix 1")
git(RO, "checkout", "-q", "-b", "orig", O1)
O2X = cm(RO, "2026-10-03T09:00:00Z", {"o.txt": "l1\nvalue 2\nl3\n"}, "fix 2 (the original, rewritten away)")
git(RO, "checkout", "-q", "feat")
OF = cm(RO, "2026-10-04T09:00:00Z", {"o.txt": "l1\nvalue 2\nl3\n"}, "fix 2 (the copy on the branch)")
OP = cm(RO, "2026-10-04T10:00:00Z", {"p.py": "p = 2  # fixed P\n"}, "fix P")
git(RO, "checkout", "-q", "main")
ok("order: control: the original fix 2 is not an ancestor of the final tip", not git_ok(RO, "merge-base", "--is-ancestor", O2X, OP))
DO = [dfx("d00000041", "task", "P1", [(TO, O1)], "o.txt"), dfx("d00000042", "task", "P2", [(O1, O2X)], "o.txt"), dfx("d00000043", "task", "P2", [(OF, OP)], "p.py")]
OB = rec_branch("border001", RO, "feat", BO, OP, TO)
S13 = setup_state("w-order", [OB], {"border001": DO})
run(S13)
r = inj(S13, "border001")
ok("order: two fixes of one line revert latest first, the head off the branch placed by its committer date",
   show(r["work"], r["work_commit"], "o.txt") == "l1\nvalue 0\nl3" and all(v["status"] == "reverted" for v in r["defects"].values()),
   (show(r["work"], r["work_commit"], "o.txt"), r["defects"]))

# ================================================================ overlapping fix ranges are one change
RV = helpers.make_repo(ROOT, "ovlrepo")
BV = cm(RV, "2026-09-20T10:00:00Z", {"README.md": "r\n"}, "base")
git(RV, "checkout", "-q", "-b", "feat")
TV = cm(RV, "2026-10-01T09:00:00Z", {"p.py": "p = 1  # bug P\n", "q.py": "q = 1  # bug Q\n", "r.py": "r = 1  # bug R\n", PLAN: "plan\n"}, "task 1")
V1 = cm(RV, "2026-10-01T10:00:00Z", {"p.py": "p = 2  # fixed P\n"}, "fix p")
V2 = cm(RV, "2026-10-01T11:00:00Z", {"q.py": "q = 2  # fixed Q\n"}, "fix q")
V3 = cm(RV, "2026-10-01T12:00:00Z", {"r.py": "r = 2  # fixed R\n"}, "fix r")
git(RV, "checkout", "-q", "main")
DP = dfx("d00000061", "task", "P1", [(TV, V2)], "p.py")
DQ = dfx("d00000062", "task", "P2", [(V1, V3)], "r.py")
OV = rec_branch("bovl00001", RV, "feat", BV, V3, TV)
S18 = setup_state("w-overlap", [OV], {"bovl00001": [DP, DQ]})
run(S18)
names, docs = split_input(S18)
is_("overlap: two defects whose ranges share a commit go through one judge-split over the combined range", (len(names), [h["file"] for h in docs[0]["hunks"]]),
    (1, ["p.py", "q.py", "r.py"]))
by = dict((x["summary"], x["index"]) for x in docs[0]["defects"])
fi = dict((h["file"], h["index"]) for h in docs[0]["hunks"])
answer(S18, "judge-split", names[0], {"hunks": [{"index": fi["p.py"], "defect": by["defect d00000061"]}, {"index": fi["q.py"], "defect": by["defect d00000061"]},
                                              {"index": fi["r.py"], "defect": by["defect d00000062"]}]})
run(S18)
r = inj(S18, "bovl00001")
ok("overlap: the shared commit is reverted once: every bug is back and both defects are reverted",
   all("bug" in show(r["work"], r["work_commit"], f) for f in ("p.py", "q.py", "r.py")) and r["defects"]["d00000061"]["status"] == "reverted"
   and r["defects"]["d00000062"]["status"] == "reverted", r["defects"])
yes_all(S18, ["d00000061", "d00000062"])
run(S18)
r = inj(S18, "bovl00001")
rp = dict((i, open(os.path.join(S18, "repairs", i + ".patch")).read()) for i in ("d00000061", "d00000062"))
ok("overlap: each defect's repair holds its own files", "p.py" in rp["d00000061"] and "q.py" in rp["d00000061"] and "r.py" not in rp["d00000061"]
   and "r.py" in rp["d00000062"] and "p.py" not in rp["d00000062"], rp)
is_("overlap: both are present and the branch qualifies", (sorted(v["status"] for v in r["defects"].values()), len(cases(S18)["cases"])), (["present", "present"], 1))

# ================================================================ the coverage gate covers a branch that already cannot qualify
DPRE = dfx("d00000071", "pre", "P1", [(FF, LC)], "src/e.py")
S19 = setup_state("w-hopeless", [CONF], {"bconf0001": [DE, DF, DPRE]})
run(S19)
yes_all(S19, ["d0000000f"])
run(S19)
ok("coverage_gate: a branch failing a pre-merge P1 still gets the recreation brief for its per-task defect",
   inputs(S19, "recreate") == ["d0000000e"] and os.path.isfile(os.path.join(S19, "recreate", "d0000000e.brief.md")), inputs(S19, "recreate"))
e = examined(S19, "bconf0001")
ok("coverage_gate: and says why it cannot qualify while it waits for the recreation", e["qualified"] is False and "P1" in e["why"] and "recreation" in e["why"], e)
recreate(S19, {"src/e.py": "line1\nline2 something else\nline3\n"}, "no")
cs = cases(S19)
is_("coverage_gate: the outcome is counted in coverage.unassessable_task although the branch cannot qualify", (cs["coverage"], cs["cases"]),
    ({"unassessable_task": ["d0000000e"]}, []))
ok("coverage_gate: and the branch ends disqualified for the pre-merge P1", "not shown present" in examined(S19, "bconf0001")["why"], examined(S19, "bconf0001"))

# ================================================================ lines another revert shifted; a recreation that breaks a repair
RH = helpers.make_repo(ROOT, "shiftrepo")
BH = cm(RH, "2026-09-20T10:00:00Z", {"README.md": "r\n"}, "base")
git(RH, "checkout", "-q", "-b", "feat")
LINES = ["l{}".format(i) for i in range(1, 13)]
LINES[7] = "N bad"
SS = lambda lines: "".join(x + "\n" for x in lines)
TH = cm(RH, "2026-10-01T09:00:00Z", {"s.txt": SS(LINES), "z.py": "z1\nz bug\nz3\n", PLAN: "plan\n"}, "task 1")
HM = cm(RH, "2026-10-01T10:00:00Z", {"s.txt": SS(["m1", "m2", "m3"] + LINES)}, "fix M")
LINES_N = ["m1", "m2", "m3"] + LINES
LINES_N[10] = "N good"
HN = cm(RH, "2026-10-01T11:00:00Z", {"s.txt": SS(LINES_N)}, "fix N")
HZ = cm(RH, "2026-10-01T12:00:00Z", {"z.py": "z1\nz fixed\nz3\n"}, "fix Z")
HL = cm(RH, "2026-10-02T09:00:00Z", {"z.py": "z1\nz rewritten\nz3\n"}, "rewrite Z")
git(RH, "checkout", "-q", "main")
DM = dfx("d00000051", "task", "P2", [(TH, HM)], "s.txt")
DN = dfx("d00000052", "task", "P2", [(HM, HN)], "s.txt")
DZ = dfx("d00000053", "task", "P1", [(HN, HZ)], "z.py")
SH2 = rec_branch("bshift001", RH, "feat", BH, HL, TH)


def shift_state(name):
    st = setup_state(name, [SH2], {"bshift001": [DM, DN, DZ]})
    run(st)
    yes_all(st, ["d00000051", "d00000052"])
    run(st)
    return st


S21 = shift_state("w-shift")
r = inj(S21, "bshift001")
is_("hunks: the dropped defect is waiting for its recreation", (r["defects"]["d00000053"]["status"], inputs(S21, "recreate")), ("dropped-revert", ["d00000053"]))


def shift_recreate(st, mv, nv):
    put(os.path.join(st, "recreate", "d00000053", "tree"), "s.txt", SS(["m1", "m2", "m3"] + [("l4X" if x == "l4" else x) for x in LINES_N[3:]]))
    put(os.path.join(st, "recreate", "d00000053"), "done", "")
    run(st)
    say(st, "d00000053", "yes", "judge-same")
    run(st)
    say(st, "d00000053", "yes")
    run(st)
    say(st, "d00000051", mv)
    say(st, "d00000052", nv)
    run(st)
    return inj(st, "bshift001")


r = shift_recreate(S21, "yes", "yes")
is_("revalidate: once the recreation joins, each present defect in a file it touched is judged again on that tree",
    [len(judged(S21, "judge-present", d)) for d in ("d00000051", "d00000052")], [2, 2])
ok("revalidate: and that question shows the tree with the recreation", any("l4X" in C.jload(os.path.join(S21, "judge-present", n + ".json"))["files"][0]["text"]
                                                                          for n in judged(S21, "judge-present", "d00000052")))
is_("revalidate: each stays present when the judge still finds it, and the recreated one is recreated",
    sorted((k, v["status"]) for k, v in r["defects"].items()), [("d00000051", "present"), ("d00000052", "present"), ("d00000053", "recreated")])
is_("hunks: a defect whose lines another revert shifted is located where it is in the finished tree, not where its patch was made",
    r["defects"]["d00000052"]["hunks"], [{"file": "s.txt", "start": 5, "end": 11, "new_start": 5, "new_end": 11}])
ok("hunks: control: the patch itself was made 3 lines lower", "@@ -8,7 +8,7 @@" in open(os.path.join(S21, "repairs", "d00000052.patch")).read(),
   open(os.path.join(S21, "repairs", "d00000052.patch")).read())
is_("hunks: and the first change, which sits above, is at the top", r["defects"]["d00000051"]["hunks"],
    [{"file": "s.txt", "start": 1, "end": 3, "new_start": 1, "new_end": 6}])
cs = cases(S21)
is_("revalidate: the branch qualifies with all three", ([sorted(c["defects"]) for c in cs["cases"]], cs["coverage"]),
    ([["d00000051", "d00000052", "d00000053"]], {"unassessable_task": []}))
S22 = shift_state("w-shift-no")
r = shift_recreate(S22, "no", "no")
is_("revalidate: a present defect the judge no longer finds is not-present", [(r["defects"][i]["status"], r["defects"][i]["repair"]) for i in ("d00000051", "d00000052")],
    [("not-present", None)] * 2)
ok("revalidate: and the branch, left with one assessable per-task defect, does not qualify", cases(S22)["cases"] == [] and not os.path.exists(os.path.join(S22, "repairs", "d00000052.patch")))

# a repair that no longer applies to the finished tree: two fixes a line apart, the earlier one made with the later one's lines in place
RJ = helpers.make_repo(ROOT, "adjrepo")
BJ = cm(RJ, "2026-09-20T10:00:00Z", {"README.md": "r\n"}, "base")
git(RJ, "checkout", "-q", "-b", "feat")
AL = ["l{}".format(i) for i in range(1, 11)]
AL[4], AL[6] = "P bad", "Q bad"
TJ = cm(RJ, "2026-10-01T09:00:00Z", {"a.txt": SS(AL), PLAN: "plan\n"}, "task 1")
AL[4] = "P good"
JP = cm(RJ, "2026-10-01T10:00:00Z", {"a.txt": SS(AL)}, "fix P")
AL[6] = "Q good"
JQ = cm(RJ, "2026-10-01T11:00:00Z", {"a.txt": SS(AL)}, "fix Q")
git(RJ, "checkout", "-q", "main")
DJP = dfx("d00000081", "task", "P1", [(TJ, JP)], "a.txt")
DJQ = dfx("d00000082", "task", "P2", [(JP, JQ)], "a.txt")
S24 = setup_state("w-adjacent", [rec_branch("badj00001", RJ, "feat", BJ, JQ, TJ)], {"badj00001": [DJP, DJQ]})
run(S24)
yes_all(S24, ["d00000081", "d00000082"])
run(S24)
r = inj(S24, "badj00001")
tx = show(r["work"], r["work_commit"], "a.txt")
ok("adjacent: both fixes are reverted in the tree (they are one change)", "P bad" in tx and "Q bad" in tx, tx)
is_("adjacent: of two fixes a line apart whose repairs cannot be told apart, both stay assessable, as members of one group",
    (r["defects"]["d00000081"]["status"], r["defects"]["d00000082"]["status"], r["defects"]["d00000081"]["group"] == r["defects"]["d00000082"]["group"]),
    ("present", "present", True))
pa, pb = (open(os.path.join(S24, "repairs", i + ".patch")).read() for i in ("d00000081", "d00000082"))
ok("adjacent: with one repair holding both, the older fix first", pa == pb and pa.count("diff --git") == 2, pa)
is_("adjacent: and one location for the group", r["defects"]["d00000081"]["hunks"], [{"file": "a.txt", "start": 2, "end": 10, "new_start": 2, "new_end": 10}])
is_("adjacent: the branch is not disqualified for it", (len(cases(S24)["cases"]), cases(S24)["coverage"]), (1, {"unassessable_task": []}))
INJ.check_invariant(rec_branch("badj00001", RJ, "feat", BJ, JQ, TJ), r["work"], r["final_commit"], r["work_commit"], [("d00000081", pa)])

# the later fix not found: the two are one group, reverted while the older is present; the later one leaves and gets its recreation
S24b = setup_state("w-adjacent-no", [rec_branch("badj00001", RJ, "feat", BJ, JQ, TJ)], {"badj00001": [DJP, DJQ]})
run(S24b)
say(S24b, "d00000081", "yes")
say(S24b, "d00000082", "no")
run(S24b)
r = inj(S24b, "badj00001")
is_("adjacent: a member the judge does not find leaves; the group stays reverted while another member is in, and the one that left gets its recreation",
    (r["defects"]["d00000081"]["status"], r["defects"]["d00000082"]["status"], r["defects"]["d00000081"]["group"] == r["defects"]["d00000082"]["group"],
     "Q bad" in show(r["work"], r["work_commit"], "a.txt"), inputs(S24b, "recreate")), ("present", "not-present", True, True, ["d00000082"]))
put(os.path.join(S24b, "recreate", "d00000082", "tree"), "a.txt", "something else\n")
put(os.path.join(S24b, "recreate", "d00000082"), "done", "")
run(S24b)
say(S24b, "d00000082", "no", "judge-same")
run(S24b)
r = inj(S24b, "badj00001")
is_("coverage_gate: unrecreated, it is unassessable and listed; the other is present",
    (r["defects"]["d00000081"]["status"], r["defects"]["d00000082"]["status"], cases(S24b)["coverage"]), ("present", "unassessable", {"unassessable_task": ["d00000082"]}))

# ================================================================ a missing cargo is recorded, not silent
EMPTY = os.path.join(ROOT, "nobin")
os.makedirs(EMPTY)
nocargo = EMPTY + os.pathsep + "/usr/bin" + os.pathsep + "/bin"
import shutil as _sh
if _sh.which("cargo", path=nocargo) is None:
    S23 = setup_state("w-nocargo", [CG], {"bcargo001": DG})
    os.environ["PATH"] = nocargo
    try:
        rc, out = run(S23)
    finally:
        os.environ["PATH"] = old_path
    is_("build_check: a Rust repository without cargo records the skip in the injected record", inj(S23, "bcargo001")["build_check"], "skipped: cargo not found")
    is_("build_check: and in the examined entry of cases.json", examined(S23, "bcargo001")["build_check"], "skipped: cargo not found")
    ok("build_check: and warns", "warning: branch bcargo001: the build check was skipped: cargo not found" in out, out)
    ok("build_check: the reverts are all kept", all(v["status"] == "reverted" for v in inj(S23, "bcargo001")["defects"].values()))
else:
    print("  FAIL: build_check: control: cargo is on the bare PATH, the skip cannot be tested")
is_("build_check: a repository without Cargo.toml records none", inj(S11, "bsh000001")["build_check"], None)
is_("build_check: and a passing check says so", inj(S12b, "bcargo001")["build_check"], "passed")

# ================================================================ qualification: limits, order, opening more


def simple(repo, base, name, tag, day, pre=False):
    git(repo, "checkout", "-q", "-b", name, base)
    files = {"p_{}.py".format(tag): "x = 1  # bug X\n", "q_{}.py".format(tag): "y = 1  # bug Y\n", PLAN: "plan\n"}
    if pre:
        files["r_{}.py".format(tag)] = "z = 1  # bug Z\n"
    t = cm(repo, "2026-10-{:02d}T09:00:00Z".format(day), files, name + " task")
    f1 = cm(repo, "2026-10-{:02d}T10:00:00Z".format(day), {"p_{}.py".format(tag): "x = 2  # fixed X\n"}, name + " fix X")
    f2 = cm(repo, "2026-10-{:02d}T11:00:00Z".format(day), {"q_{}.py".format(tag): "y = 2  # fixed Y\n"}, name + " fix Y")
    tip = f2
    defects = [dfx("dx" + tag, "task", "P1", [(t, f1)], "p_{}.py".format(tag)), dfx("dy" + tag, "task", "P2", [(f1, f2)], "q_{}.py".format(tag))]
    if pre:
        tip = cm(repo, "2026-10-{:02d}T12:00:00Z".format(day), {"r_{}.py".format(tag): "z = 2  # fixed Z\n"}, name + " fix Z")
        defects.append(dfx("dz" + tag, "pre", "P1", [(f2, tip)], "r_{}.py".format(tag)))
    git(repo, "checkout", "-q", "main")
    return t, tip, defects


QR = helpers.make_repo(ROOT, "qrepo")
BQR = cm(QR, "2026-09-20T10:00:00Z", {"README.md": "r\n"}, "base")
QS = helpers.make_repo(ROOT, "qsrepo")
BQS = cm(QS, "2026-09-20T10:00:00Z", {"README.md": "r\n"}, "base")
Q = {}
for repo, base, name, tag, day, pre, at in ((QR, BQR, "qr1", "r1", 5, False, "2026-10-30T10:00:00.000000Z"), (QR, BQR, "qr2", "r2", 6, True, "2026-10-29T10:00:00.000000Z"),
                                            (QR, BQR, "qr3", "r3", 7, False, "2026-10-28T10:00:00.000000Z"), (QS, BQS, "qs1", "s1", 8, False, "2026-10-27T10:00:00.000000Z"),
                                            (QR, BQR, "qr4", "r4", 9, False, "2026-10-26T10:00:00.000000Z")):
    t, tip, defects = simple(repo, base, name, tag, day, pre)
    Q[name] = (rec_branch("b" + name, repo, name, base, tip, t, at=at), defects)
old_limits = (INJ.MAX_CASES, INJ.PER_REPO)
INJ.MAX_CASES, INJ.PER_REPO = 3, 2
S14 = setup_state("w-qual", [Q[n][0] for n in ("qr4", "qs1", "qr1", "qr3", "qr2")], dict(("b" + n, Q[n][1]) for n in Q))
rc, out = run(S14)
ok("qualify: at most 2 per repository (here), most recent final round first: the third of a repository is not even built",
   os.path.exists(os.path.join(S14, "work", "bqr1")) and os.path.exists(os.path.join(S14, "work", "bqr2")) and os.path.exists(os.path.join(S14, "work", "bqs1"))
   and not os.path.exists(os.path.join(S14, "work", "bqr3")), sorted(os.listdir(os.path.join(S14, "work"))))
ok("qualify: and not past the total either", not os.path.exists(os.path.join(S14, "work", "bqr4")))
ok("qualify: no opening hint while candidates are still in the limits", "cases --open" not in out, out)
for n in ("qr1", "qs1"):
    yes_all(S14, [d["id"] for d in Q[n][1]])
yes_all(S14, ["dxr2", "dyr2"])
say(S14, "dzr2", "no")
run(S14)
ok("qualify: a branch that loses a pre-merge P1 frees its place: the next candidate opens", os.path.exists(os.path.join(S14, "work", "bqr3")))
is_("qualify: and the one that qualified are cases, so far", [c["branch"] for c in cases(S14)["cases"]], ["bqr1", "bqs1"])
ok("qualify: the disqualified branch says why", examined(S14, "bqr2")["qualified"] is False and "P1" in examined(S14, "bqr2")["why"])
ok("qualify: and the waiting one is not qualified yet", examined(S14, "bqr3")["qualified"] is False and "waiting" in examined(S14, "bqr3")["why"], examined(S14, "bqr3"))
ok("qualify: nor is the one beyond the limits", "limit" in examined(S14, "bqr4")["why"], examined(S14, "bqr4"))
yes_all(S14, ["dxr3", "dyr3"])
run(S14)
is_("qualify: most recent final round first", [c["branch"] for c in cases(S14)["cases"]], ["bqr1", "bqr3", "bqs1"])
INJ.MAX_CASES, INJ.PER_REPO = old_limits

# opening more: three opened candidates, room for five, unopened ones behind them
INJ.MAX_CASES, INJ.PER_REPO = 5, 2
unopened = [dict(rec_branch("bu" + str(i), "/nowhere/" + repo, "u" + str(i), "0" * 40, "1" * 40, "2" * 40, at="2026-10-1{}T10:00:00.000000Z".format(i),
                            merged="2026-10-{}T10:00:00Z".format(12 - i), opened=False), repo=path)
            for i, (repo, path) in enumerate((("qrepo", Q["qr1"][0]["repo"]), ("qsrepo", Q["qs1"][0]["repo"]), ("other", "/nowhere/other/.git")))]
S15 = setup_state("w-more", [Q["qr1"][0], Q["qr2"][0], Q["qs1"][0]] + unopened, dict(("b" + n, Q[n][1]) for n in ("qr1", "qr2", "qs1")))
rc, out = run(S15)
ok("qualify: fewer slots used than there are, and candidates left: it says exactly how to open more", "process-replay.py cases --open 6" in out, out)
INJ.MAX_CASES, INJ.PER_REPO = old_limits
S16 = setup_state("w-pending", [Q["qr1"][0], dict(Q["qr2"][0], opened=True)], {"bqr1": Q["qr1"][1]})
rc, out = run(S16)
ok("qualify: an opened candidate whose inventory is not in yet waits, and is listed", "waiting" in examined(S16, "bqr2")["why"] and "inventory" in examined(S16, "bqr2")["why"], examined(S16, "bqr2"))
S17 = setup_state("w-notcand", [dict(Q["qr1"][0], candidate=False, why="merged outside the window", opened=False)], {})
run(S17)
is_("qualify: a chain that is not a candidate is examined with its reason", examined(S17, "bqr1"), {"branch": "bqr1", "qualified": False, "why": "merged outside the window", "counts": {}})
try:
    INJ.cmd_inject(args(world("w-empty")))
    got = "returned"
except C.Failed as e:
    got = "failed: " + str(e)
ok("exits: without branches.json it fails and says to run cases", got.startswith("failed") and "cases" in got, got)

# such a branch holds no place while it waits
CONF2 = rec_branch("bconf0002", RC, "feat", BC, LC, TC, at="2026-10-31T10:00:00.000000Z")
D2 = [dfx("d000000e2", "task", "P1", [(TC, FE)], "src/e.py"), dfx("d000000f2", "task", "P2", [(FE, FF)], "src/f.py"), dfx("d00000072", "pre", "P1", [(FF, LC)], "src/e.py")]
old_limits = (INJ.MAX_CASES, INJ.PER_REPO)
INJ.MAX_CASES = 1
t, tip, dq = simple(QR, BQR, "qh1", "h1", 12)
QH = rec_branch("bqh1", QR, "qh1", BQR, tip, t, at="2026-10-20T10:00:00.000000Z")
S20 = setup_state("w-place", [CONF2, QH], {"bconf0002": D2, "bqh1": dq})
run(S20)
ok("waiting: a branch that waits says on what: a judge answer and a recreation", "1 judge answer(s) and 1 recreation(s)" in examined(S20, "bconf0002")["why"],
   examined(S20, "bconf0002"))
yes_all(S20, ["d000000f2"])
run(S20)
ok("coverage_gate: a branch that cannot qualify (its pre-merge P1 fails) and waits for its recreation holds no place: the next candidate is built within a limit of one",
   examined(S20, "bconf0002")["qualified"] is False and "recreation" in examined(S20, "bconf0002")["why"] and os.path.exists(os.path.join(S20, "work", "bqh1")),
   (examined(S20, "bconf0002"), os.listdir(os.path.join(S20, "work"))))
# a branch that can no longer have two assessable per-task defects holds no place while it waits either
S20b = setup_state("w-place-few", [rec_branch("bconf0003", RC, "feat", BC, LC, TC, at="2026-10-31T10:00:00.000000Z"), QH], {"bconf0003": [DE2, DF], "bqh1": dq})
run(S20b)
ok("place: control: while its recreation may still succeed, the branch holds the one place", not os.path.exists(os.path.join(S20b, "work", "bqh1")))
put(os.path.join(S20b, "recreate", "d0000000e"), "done", "")
run(S20b)
e = examined(S20b, "bconf0003")
ok("place: once a per-task defect is out for good and too few can still be assessed, it gives up its place while its judge still waits",
   "fewer than two" in e["why"] and "judge answer" in e["why"] and os.path.exists(os.path.join(S20b, "work", "bqh1")), (e, os.listdir(os.path.join(S20b, "work"))))
INJ.MAX_CASES = old_limits[0]


# ================================================================ the untracked edit: the invariant raises
real_pin = INJ.pin_docs


def stray(work, view, plan):
    real_pin(work, view, plan)
    put(work, "README.md", "an edit nobody tracks\n")
    git(work, "add", "README.md")


INJ.pin_docs = stray
S30 = setup_state("w-stray", [Q["qr1"][0]], {"bqr1": Q["qr1"][1]})
run(S30)
yes_all(S30, [d["id"] for d in Q["qr1"][1]])
try:
    run(S30)
    got = "returned"
except C.Failed as e:
    got = str(e)
INJ.pin_docs = real_pin
ok("invariant: a tree with an edit the harness does not track makes inject fail, naming the branch", "branch bqr1" in got and "README.md" in got, got)

# ================================================================ a defect the judge does not find is reverted no more: its recreation applies
RN = helpers.make_repo(ROOT, "notrepo")
BN = cm(RN, "2026-09-20T10:00:00Z", {"README.md": "r\n"}, "base")
git(RN, "checkout", "-q", "-b", "feat")
TN = cm(RN, "2026-10-01T09:00:00Z", {"a.py": "a = 1  # bug A\n", "b.py": "b = 1  # bug B\n", "e.py": "l1\ne bug\nl3\n", "tests/test_b.py": "pass\n", PLAN: "plan\n"}, "task 1")
NA = cm(RN, "2026-10-01T10:00:00Z", {"a.py": "a = 2  # fixed A\n"}, "fix A")
NB = cm(RN, "2026-10-01T11:00:00Z", {"b.py": "b = 2  # fixed B\n", "tests/test_b.py": "assert b == 2\n"}, "fix B")
NE = cm(RN, "2026-10-01T12:00:00Z", {"e.py": "l1\ne fixed\nl3\n"}, "fix E")
NL = cm(RN, "2026-10-02T12:00:00Z", {"e.py": "l1\ne rewritten\nl3\n"}, "rewrite E")
git(RN, "checkout", "-q", "main")
DNA = dfx("d000000a1", "task", "P1", [(TN, NA)], "a.py")
DNB = dfx("d000000b1", "task", "P1", [(NA, NB)], "b.py", files=["b.py", "e.py"])
DNE = dfx("d000000e1", "task", "P2", [(NB, NE)], "e.py")
NBR = rec_branch("bnot00001", RN, "feat", BN, NL, TN)

# not-present: its revert is not in the tree, so its recreation (made against the final tree) applies
S31 = setup_state("w-not", [NBR], {"bnot00001": [DNA, DNB]})
run(S31)
say(S31, "d000000a1", "yes")
say(S31, "d000000b1", "no")
run(S31)
r = inj(S31, "bnot00001")
ok("untracked: a defect the judge does not find is not reverted in the tree a case ships", "fixed B" in show(r["work"], r["work_commit"], "b.py")
   and has(r["work"], r["work_commit"], "tests/test_b.py") and "bug A" in show(r["work"], r["work_commit"], "a.py"), r["defects"])
is_("untracked: and its recreation is requested", inputs(S31, "recreate"), ["d000000b1"])
put(os.path.join(S31, "recreate", "d000000b1", "tree"), "b.py", "b = 0  # bug B, by hand\n")
put(os.path.join(S31, "recreate", "d000000b1", "tree"), "tests/test_b.py", "pass\n")
put(os.path.join(S31, "recreate", "d000000b1"), "done", "")
run(S31)
say(S31, "d000000b1", "yes", "judge-same")
run(S31)
say(S31, "d000000b1", "yes")
run(S31)
r = inj(S31, "bnot00001")
is_("untracked: a not-present per-task P1 goes through recreation to recreated", r["defects"]["d000000b1"]["status"], "recreated")
ok("untracked: and the case holds the recreated defect and the reverted one", len(cases(S31)["cases"]) == 1 and "bug B, by hand" in show(r["work"], r["work_commit"], "b.py")
   and "bug A" in show(r["work"], r["work_commit"], "a.py"), cases(S31))

# a recreation that gives back a tree the judge has seen asks nothing new: that question was answered
S31b = setup_state("w-not-again", [NBR], {"bnot00001": [DNA, DNB]})
run(S31b)
say(S31b, "d000000a1", "yes")
say(S31b, "d000000b1", "no")
run(S31b)
put(os.path.join(S31b, "recreate", "d000000b1", "tree"), "b.py", "b = 1  # bug B\n")
put(os.path.join(S31b, "recreate", "d000000b1"), "done", "")
run(S31b)
say(S31b, "d000000b1", "yes", "judge-same")
run(S31b)
r = inj(S31b, "bnot00001")
is_("content-addressed: a recreation that rebuilds the very files the judge found the defect absent from is that question again: no new one, the same answer",
    (r["defects"]["d000000b1"]["status"], r["defects"]["d000000b1"]["reason"], len(judged(S31b, "judge-present", "d000000b1")), unanswered(S31b, "judge-present")),
    ("unassessable", "the judge answered no on the injected tree", 1, []))

# a recreation the judge rejects on the finished tree is not in the tree, and feeds nothing
S32 = setup_state("w-rejected", [NBR], {"bnot00001": [DNA, DNB, DNE]})
run(S32)
yes_all(S32, ["d000000a1", "d000000b1"])
run(S32)
put(os.path.join(S32, "recreate", "d000000e1", "tree"), "e.py", "l1\ne BROKEN differently\nl3\n")
put(os.path.join(S32, "recreate", "d000000e1"), "done", "")
run(S32)
say(S32, "d000000e1", "yes", "judge-same")
run(S32)
say(S32, "d000000e1", "no")
run(S32)
r = inj(S32, "bnot00001")
is_("rejected: a recreation the judge rejects on the finished tree is unassessable", r["defects"]["d000000e1"]["status"], "unassessable")
is_("rejected: and is not in the tree a case ships", show(r["work"], r["work_commit"], "e.py"), "l1\ne rewritten\nl3")
is_("rejected: nor is another present defect judged on a tree with it, though its files are among theirs", [len(judged(S32, "judge-present", d)) for d in ("d000000a1", "d000000b1")],
    [1, 1])

# ================================================================ an uncounted defect's hunks stay applied
DC3 = dict(dfx("d0000000c", "task", "P3", [(FA, FBC)], "src/c.py"), counted=False)
S33 = main_state("w-p3", [DA, DB, DC3, DD])
run(S33)
names, docs = split_input(S33)
is_("uncounted: a range a counted and an uncounted defect share goes to the judge, both listed", sorted(x["summary"] for x in docs[0]["defects"]), ["defect d0000000b", "defect d0000000c"])
split_answer(S33, lambda m: m["defect d0000000b"], lambda m: m["defect d0000000c"])
run(S33)
yes_all(S33, ["d0000000a", "d0000000b", "d0000000d"])
run(S33)
r = inj(S33, "bmain0001")
ok("uncounted: the uncounted defect's fix and test stay applied", "fixed C" in show(r["work"], r["work_commit"], "src/c.py") and has(r["work"], r["work_commit"], "tests/test_c.py")
   and "bug B" in show(r["work"], r["work_commit"], "src/b.py"), r["defects"])
is_("uncounted: and it is not among the defects", sorted(r["defects"]), ["d0000000a", "d0000000b", "d0000000d"])

# ================================================================ a revert that leaves a name in use
RH2 = helpers.make_repo(ROOT, "helperrepo")
BH2 = cm(RH2, "2026-09-20T10:00:00Z", {"README.md": "r\n"}, "base")
git(RH2, "checkout", "-q", "-b", "feat")
TH2 = cm(RH2, "2026-10-01T09:00:00Z", {"a.py": "a = 1  # bug A\n", "b.py": "b = 1  # bug B\n", PLAN: "plan\n"}, "task 1")
HA = cm(RH2, "2026-10-01T10:00:00Z", {"a.py": "a = 2  # fixed A\n", "helper.py": "def helper():\n    return 2\n"}, "fix A, with a helper")
HB = cm(RH2, "2026-10-01T11:00:00Z", {"b.py": "b = 2  # fixed B\n"}, "fix B")
HLATER = cm(RH2, "2026-10-02T09:00:00Z", {"d.py": "from helper import helper\n\ndef d():\n    return helper()\n"}, "later work uses the helper")
git(RH2, "checkout", "-q", "main")
DHA = dfx("d00000091", "task", "P1", [(TH2, HA)], "a.py", files=["a.py", "helper.py"])
DHB = dfx("d00000092", "task", "P2", [(HA, HB)], "b.py")
S34 = setup_state("w-helper", [rec_branch("bhelp0001", RH2, "feat", BH2, HLATER, TH2)], {"bhelp0001": [DHA, DHB]})
run(S34)
r = inj(S34, "bhelp0001")
is_("coherence_undo: a revert that removes a name another file still uses is undone: incoherent, with the name and the file",
    (r["defects"]["d00000091"]["status"], "helper is still used by d.py" in r["defects"]["d00000091"]["reason"]), ("incoherent", True))
ok("coherence_undo: and the helper stays in the tree", has(r["work"], r["work_commit"], "helper.py") and "bug B" in show(r["work"], r["work_commit"], "b.py"))

# ================================================================ rank by merge date; a cargo that times out
INJ.MAX_CASES, INJ.PER_REPO = 12, 1
t1_, tip1, d1 = simple(QR, BQR, "qm1", "m1", 13)
t2_, tip2, d2 = simple(QR, BQR, "qm2", "m2", 14)
older_merge_later_round = rec_branch("bqm1", QR, "qm1", BQR, tip1, t1_, at="2026-10-31T10:00:00.000000Z", merged="2026-10-20T10:00:00Z")
newer_merge_earlier_round = rec_branch("bqm2", QR, "qm2", BQR, tip2, t2_, at="2026-10-21T10:00:00.000000Z", merged="2026-10-26T10:00:00Z")
S35 = setup_state("w-mergerank", [older_merge_later_round, newer_merge_earlier_round], {"bqm1": d1, "bqm2": d2})
run(S35)
ok("rank: candidates are ranked by merge date, as `cases --open` does: the later merge keeps the one place of its repository",
   os.path.exists(os.path.join(S35, "work", "bqm2")) and not os.path.exists(os.path.join(S35, "work", "bqm1")), os.listdir(os.path.join(S35, "work")))
INJ.MAX_CASES, INJ.PER_REPO = old_limits

# a timeout of cargo is recorded like a missing cargo: its result is unknown, and the reverts stay
put(STUB, "cargo", "#!/bin/sh\nexec sleep 5\n")
S36 = setup_state("w-cargo-timeout", [CG], {"bcargo001": DG})
os.environ["PATH"] = STUB + os.pathsep + old_path
try:
    buf = io.StringIO()
    with contextlib.redirect_stdout(buf):
        INJ.cmd_inject(Namespace(state=S36, dry_run=False, snapshot_root=NO_SNAPSHOT, budget=1, open=16))
finally:
    os.environ["PATH"] = old_path
r = inj(S36, "bcargo001")
ok("build_check: a cargo check that times out is recorded and warned, leaves the reverts in (its result is unknown, as with no cargo), and inject carries on",
   r["build_check"].startswith("timed out") and all(v["status"] == "reverted" for v in r["defects"].values()) and "warning: branch bcargo001: the build check was timed out" in buf.getvalue(),
   (r["build_check"], r["defects"], buf.getvalue()))

# the judge briefs say what the inputs hold
ok("briefs: judge-present describes files as a list of {path, text}", '"files": [{"path", "text"}]' in C.BRIEFS["judge-present"])
ok("briefs: judge-split places a test with the defect it tests, null only for a rename or an unrelated edit",
   "changes a test belongs to the" in C.BRIEFS["judge-split"].replace("\n", " ") and "a test, a rename" not in C.BRIEFS["judge-split"])

# ================================================================ a defect is judged again when its files are not as it was judged
RA = helpers.make_repo(ROOT, "judgedrepo")
BA = cm(RA, "2026-09-20T10:00:00Z", {"README.md": "r\n"}, "base")
git(RA, "checkout", "-q", "-b", "feat")
body = lambda x, y: "".join("l%d\n" % i for i in range(1, 6)) + x + "\n" + "".join("m%d\n" % i for i in range(1, 12)) + y + "\n"
TA = cm(RA, "2026-10-01T09:00:00Z", {"s.txt": body("X bug", "Y bug"), "a.py": "a = 1\n", PLAN: "plan\n"}, "task 1")
AFA = cm(RA, "2026-10-01T09:30:00Z", {"a.py": "a = 2\n"}, "fa")
AFX = cm(RA, "2026-10-01T10:00:00Z", {"s.txt": body("X fixed", "Y bug")}, "fx")
AFY = cm(RA, "2026-10-01T11:00:00Z", {"s.txt": body("X fixed", "Y fixed")}, "fy")
git(RA, "checkout", "-q", "main")
DAA = dfx("d000000a1", "task", "P2", [(TA, AFA)], "a.py")
DAC1 = dfx("d000000c1", "task", "P2", [(AFA, AFX)], "s.txt")
DAC2 = dfx("d000000c2", "pre", "P2", [(AFX, AFY)], "s.txt")
S40 = setup_state("w-judged", [rec_branch("bjudg0001", RA, "feat", BA, AFY, TA)], {"bjudg0001": [DAA, DAC1, DAC2]})
run(S40)
say(S40, "d000000a1", "yes")
say(S40, "d000000c1", "yes")
say(S40, "d000000c2", "no")
run(S40)
r = inj(S40, "bjudg0001")
waits = unanswered(S40, "judge-present")
vin = C.jload(os.path.join(S40, "judge-present", waits[0] + ".json")) if [of(n) for n in waits] == ["d000000c1"] else None
ok("revalidate: a present defect judged with a neighbour's revert in place, shipped without it, is judged again on the shipped tree",
   vin is not None and "Y fixed" in vin["files"][0]["text"] and "Y bug" not in vin["files"][0]["text"], vin)
is_("revalidate: and the branch waits for that answer; the other defects are not asked again", (r["complete"], [len(judged(S40, "judge-present", d)) for d in ("d000000a1", "d000000c1", "d000000c2")]),
    (False, [1, 2, 1]))
say(S40, "d000000c1", "yes")
run(S40)
r = inj(S40, "bjudg0001")
is_("revalidate: yes keeps it; a defect whose files did not change is not asked", (r["defects"]["d000000c1"]["status"], r["complete"], len(cases(S40)["cases"])), ("present", True, 1))
S41 = setup_state("w-judged-no", [rec_branch("bjudg0001", RA, "feat", BA, AFY, TA)], {"bjudg0001": [DAA, DAC1, DAC2]})
run(S41)
yes_all(S41, ["d000000a1", "d000000c1"])
say(S41, "d000000c2", "no")
run(S41)
say(S41, "d000000c1", "no")
run(S41)
r = inj(S41, "bjudg0001")
is_("revalidate: no drops it, and the tree is rebuilt without it", (r["defects"]["d000000c1"]["status"], "X fixed" in show(r["work"], r["work_commit"], "s.txt")),
    ("not-present", True))

# a recreation still being made does not hold up the answers that are in: a defect found absent leaves, and the rest are judged again
DZ9 = dfx("d000000f9", "task", "P2", [], "a.py")
S41b = setup_state("w-judged-busy", [rec_branch("bjudg0001", RA, "feat", BA, AFY, TA)], {"bjudg0001": [DAA, DAC1, DAC2, DZ9]})
run(S41b)
ok("waiting: a defect with no fix range is out from the start and its recreation is requested", inputs(S41b, "recreate") == ["d000000f9"], inputs(S41b, "recreate"))
yes_all(S41b, ["d000000a1", "d000000c1"])
say(S41b, "d000000c2", "no")
run(S41b)
r = inj(S41b, "bjudg0001")
is_("waiting: while that recreation is unfinished, the no is acted on: the tree is rebuilt and the defect whose file changed is asked again",
    ([of(n) for n in unanswered(S41b, "judge-present")], r["defects"]["d000000c2"]["status"], "Y fixed" in show(r["work"], r["work_commit"], "s.txt"),
     sorted(r["waiting"])), (["d000000c1"], "not-present", True, ["judge-present", "recreate"]))

# ================================================================ a defect that leaves in a later round gets its recreation then
RP = helpers.make_repo(ROOT, "passrepo")
BP = cm(RP, "2026-09-20T10:00:00Z", {"README.md": "r\n"}, "base")
git(RP, "checkout", "-q", "-b", "feat")
EL = ["e{}".format(i) for i in range(1, 31)]
EL[2] = "e3 bug"
TP = cm(RP, "2026-10-01T09:00:00Z", {"a.py": "a = 1\n", "e.txt": SS(EL), "z.py": "z1\nz bug\nz3\n", PLAN: "plan\n"}, "task 1")
PG = cm(RP, "2026-10-01T10:00:00Z", {"a.py": "a = 2\n", "helper.py": "def helper():\n    return 2\n"}, "fix G, with a helper")
EL[2] = "e3 fixed"
PH = cm(RP, "2026-10-01T11:00:00Z", {"e.txt": SS(EL), "d.py": "from helper import helper\n\ndef d():\n    return helper()\n"}, "fix H, which uses it")
PZ = cm(RP, "2026-10-01T12:00:00Z", {"z.py": "z1\nz fixed\nz3\n"}, "fix Z")
PL = cm(RP, "2026-10-02T09:00:00Z", {"z.py": "z1\nz rewritten\nz3\n"}, "rewrite Z")
git(RP, "checkout", "-q", "main")
DPG = dfx("d00000a01", "task", "P1", [(TP, PG)], "a.py", files=["a.py", "helper.py"])
DPH = dfx("d00000a02", "task", "P2", [(PG, PH)], "e.txt", files=["e.txt", "d.py"])
DPZ = dfx("d00000a03", "task", "P2", [(PH, PZ)], "z.py")
S42 = setup_state("w-passes", [rec_branch("bpass0001", RP, "feat", BP, PL, TP)], {"bpass0001": [DPG, DPH, DPZ]})
run(S42)
yes_all(S42, ["d00000a01", "d00000a02"])
run(S42)
is_("passes: the first pass asks for the one defect that failed", inputs(S42, "recreate"), ["d00000a03"])
EL2 = list(EL)
EL2[24] = "e25 touched by the recreation"
put(os.path.join(S42, "recreate", "d00000a03", "tree"), "e.txt", SS(EL2))
put(os.path.join(S42, "recreate", "d00000a03"), "done", "")
run(S42)
say(S42, "d00000a03", "yes", "judge-same")
run(S42)
say(S42, "d00000a03", "yes")
run(S42)
is_("passes: the recreation changed a file of the fix of H, so H alone is judged again on the tree it joined", [of(n) for n in unanswered(S42, "judge-present")], ["d00000a02"])
say(S42, "d00000a02", "no")
run(S42)
r = inj(S42, "bpass0001")
ok("passes: H no longer found, G's revert is rebuilt without H's and is incoherent (its helper is in use), with the real status and reason",
   r["defects"]["d00000a01"]["status"] == "incoherent" and "helper is still used by d.py" in r["defects"]["d00000a01"]["reason"], r["defects"]["d00000a01"])
is_("passes: both newly failing per-task defects get their second attempt", inputs(S42, "recreate"), ["d00000a01", "d00000a02", "d00000a03"])
for did in ("d00000a01", "d00000a02"):
    put(os.path.join(S42, "recreate", did, "tree"), "a.py", "a = 9\n")
    put(os.path.join(S42, "recreate", did), "done", "")
run(S42)
say(S42, "d00000a01", "no", "judge-same")
say(S42, "d00000a02", "no", "judge-same")
run(S42)
r = inj(S42, "bpass0001")
is_("passes: and what still fails is unassessable and listed in coverage; each had one recreation",
    (r["defects"]["d00000a01"]["status"], r["defects"]["d00000a02"]["status"], r["defects"]["d00000a03"]["status"], cases(S42)["coverage"], r["complete"]),
    ("unassessable", "unassessable", "recreated", {"unassessable_task": ["d00000a01", "d00000a02"]}, True))

# ================================================================ a range of uncounted defects only is not sent to a judge
DU1 = dict(dfx("d0000000b", "task", "P3", [(FA, FBC)], "src/b.py"), counted=False)
DU2 = dict(dfx("d0000000c", "task", "P3", [(FA, FBC)], "src/c.py"), counted=False)
S43 = main_state("w-uncounted-only", [DA, DU1, DU2, dfx("d0000000e", "task", "P2", [(LATER, FD)], "src/d.py")])
run(S43)
is_("uncounted: a range only uncounted defects share needs no judge-split", inputs(S43, "judge-split"), [])

# ================================================================ a later tree's cargo check that times out is recorded, not a failure
put(STUB, "cargo", "#!/bin/sh\nif [ -e {0} ]; then exec sleep 5; fi\ntouch {0}\nexit 0\n".format(os.path.join(ROOT, "cargo-ran-once")))
DG2 = [DG[0], DG[1], dfx("d00000033", "pre", "P2", DG[2]["fixes"], "src/r3.rs")]
S44 = setup_state("w-cargo-final", [CG], {"bcargo001": DG2})
os.environ["PATH"] = STUB + os.pathsep + old_path
try:
    for n in range(2):
        with contextlib.redirect_stdout(io.StringIO()):
            INJ.cmd_inject(Namespace(state=S44, dry_run=False, snapshot_root=NO_SNAPSHOT, budget=1, open=16))
        if n == 0:
            yes_all(S44, ["d00000031", "d00000032"])
            say(S44, "d00000033", "no")
finally:
    os.environ["PATH"] = old_path
ok("build_check: a timeout of the shipped tree's cargo check (the first tree's passed) is recorded as a timeout and the branch still qualifies",
   inj(S44, "bcargo001")["build_check"].startswith("timed out") and len(cases(S44)["cases"]) == 1, (inj(S44, "bcargo001")["build_check"], cases(S44)))


# ================================================================ the fixpoint: each question once, nothing alternates, it ends
def drive(state, rule, limit=40, edit=None):
    """Run inject and do what `pending` hands out, as the driver does, until it hands out nothing: judges by rule(kind, defect, how many
    of its questions of that kind were answered before, input), recreations by edit(defect, tree dir) and then done. The number of
    runs, or None past `limit`."""
    for n in range(1, limit + 1):
        run(state)
        items = C.pending(state)
        for kind, name, inp, _ans, _brief in items:
            if kind == "recreate":
                if edit:
                    edit(name, os.path.join(state, "recreate", name, "tree"))
                put(os.path.join(state, "recreate", name), "done", "")
                continue
            did = of(name)
            before = len([x for x in inputs(state, kind) if of(x) == did]) - len([x for x in unanswered(state, kind) if of(x) == did])
            answer(state, kind, name, {"answer": rule(kind, did, before, C.jload(inp))})
        if not items:
            return n
    return None


def stale(state):
    return sorted(n for kind in ("judge-present", "judge-same") if os.path.isdir(os.path.join(state, kind))
                  for n in os.listdir(os.path.join(state, kind)) if ".stale-" in n)


def snapshot(state):
    out = {}
    for d, _s, fs in os.walk(state):
        for f in fs:
            p = os.path.join(d, f)
            if not os.path.islink(p) and f != "items.lock" and os.path.relpath(p, state).split(os.sep)[0] not in ("work", "views", "packs", "cargo"):
                with open(p, "rb") as h:
                    out[os.path.relpath(p, state)] = h.read()
    return out


RT = helpers.make_repo(ROOT, "twotrees")
BT = cm(RT, "2026-09-20T10:00:00Z", {"README.md": "r\n"}, "base")
git(RT, "checkout", "-q", "-b", "feat")
three = lambda x, y, z: ("".join("l%d\n" % i for i in range(1, 6)) + x + "\n" + "".join("m%d\n" % i for i in range(1, 12)) + y + "\n"
                         + "".join("n%d\n" % i for i in range(1, 12)) + z + "\n" + "".join("o%d\n" % i for i in range(1, 6)))
TT = cm(RT, "2026-10-01T09:00:00Z", {"s.txt": three("X bug", "Y bug", "Z bug"), PLAN: "plan\n"}, "task 1")
TX = cm(RT, "2026-10-01T10:00:00Z", {"s.txt": three("X fixed", "Y bug", "Z bug")}, "fix X")
TY = cm(RT, "2026-10-01T11:00:00Z", {"s.txt": three("X fixed", "Y fixed", "Z bug")}, "fix Y")
TZ = cm(RT, "2026-10-01T12:00:00Z", {"s.txt": three("X fixed", "Y fixed", "Z fixed")}, "fix Z")
git(RT, "checkout", "-q", "main")
TWO = rec_branch("btwo00001", RT, "feat", BT, TZ, TT)
DT = [dfx("d00000c01", "task", "P2", [(TT, TX)], "s.txt"), dfx("d00000c02", "pre", "P2", [(TX, TY)], "s.txt"), dfx("d00000c03", "task", "P2", [(TY, TZ)], "s.txt")]
S50 = setup_state("w-twotrees", [TWO], {"btwo00001": DT})
script = {"d00000c01": ["yes", "yes", "yes", "yes"], "d00000c02": ["no"], "d00000c03": ["yes", "no"]}
runs = drive(S50, lambda kind, did, k, doc: script[did][k] if kind == "judge-present" else "no")
r = inj(S50, "btwo00001")
ok("fixpoint (F1): a defect judged on a second and a third tree in one branch settles: it ends", runs is not None and r["complete"], (runs, r and r.get("complete")))
is_("fixpoint (F1): no answer is ever set aside: another tree is another question", stale(S50), [])
is_("fixpoint (F1): X is asked once per tree it was in (all three reverts, X and Z, X alone), Y once, Z on two trees",
    sorted((d, len([n for n in inputs(S50, "judge-present") if of(n) == d])) for d in ("d00000c01", "d00000c02", "d00000c03")),
    [("d00000c01", 3), ("d00000c02", 1), ("d00000c03", 2)])
is_("fixpoint (F1): X is present, Y and Z are not", dict((k, v["status"]) for k, v in r["defects"].items()),
    {"d00000c01": "present", "d00000c02": "not-present", "d00000c03": "unassessable"})
ok("fixpoint (F1): the shipped tree has X's bug alone", "X bug" in show(r["work"], r["work_commit"], "s.txt") and "Y fixed" in show(r["work"], r["work_commit"], "s.txt")
   and "Z fixed" in show(r["work"], r["work_commit"], "s.txt"))
before = snapshot(S50)
for _ in range(3):
    run(S50)
is_("fixpoint (F1): more runs with no new answer change no file (no alternation)", sorted(k for k in set(before) | set(snapshot(S50)) if before.get(k) != snapshot(S50).get(k)), [])

# a judge driven by what it sees: whatever it answers, the fixpoint ends within its bound and asks no question twice
RW = helpers.make_repo(ROOT, "wobble")
BW = cm(RW, "2026-09-20T10:00:00Z", {"README.md": "r\n"}, "base")
git(RW, "checkout", "-q", "-b", "feat")
REG = ["A", "B", "C", "D", "E"]
wob = lambda fixed: "".join("".join("{}{}\n".format(r.lower(), i) for i in range(1, 9)) + ("{} fixed\n".format(r) if r in fixed else "{} bug\n".format(r)) for r in REG)
TWb = cm(RW, "2026-10-01T09:00:00Z", {"w.txt": wob(""), "v.txt": "v1\nv bug\nv3\n", PLAN: "plan\n"}, "task 1")
heads, prev, done_ = [], TWb, ""
for i, reg in enumerate(REG):
    done_ += reg
    files = {"w.txt": wob(done_)}
    if reg == "C":
        files["v.txt"] = "v1\nv fixed\nv3\n"
    prev2 = cm(RW, "2026-10-01T1{}:00:00Z".format(i), files, "fix " + reg)
    heads.append((prev, prev2))
    prev = prev2
git(RW, "checkout", "-q", "main")
WOB = rec_branch("bwob00001", RW, "feat", BW, prev, TWb)
classes = [("task", "P1"), ("task", "P2"), ("pre", "P2"), ("task", "P2"), ("pre", "P2")]
DW = [dfx("d00000e0" + str(i), cls, sev, [heads[i]], "w.txt", files=["w.txt", "v.txt"] if REG[i] == "C" else ["w.txt"]) for i, (cls, sev) in enumerate(classes)]
bound = 4 * len(DW) + len(DW) + 2
import hashlib as _hl
for seed in range(6):
    st = setup_state("w-wobble-{}".format(seed), [WOB], {"bwob00001": DW})
    pick = lambda kind, did, k, doc, seed=seed: ("yes", "no", "unclear")[int(_hl.sha256((str(seed) + json.dumps(doc, sort_keys=True)).encode()).hexdigest(), 16) % 3] \
        if kind == "judge-present" else ("yes" if int(_hl.sha256((str(seed) + did).encode()).hexdigest(), 16) % 2 else "no")
    edit = lambda did, tree: put(tree, "w.txt", open(os.path.join(tree, "w.txt")).read() + "recreated " + did + "\n")
    runs = drive(st, pick, limit=bound + 1, edit=edit)
    r = inj(st, "bwob00001")
    ok("fixpoint: seed {}: whatever the judge answers, the branch settles within its bound of rounds".format(seed), runs is not None and r["complete"], (runs, r and r.get("complete")))
    is_("fixpoint: seed {}: no answer was set aside".format(seed), stale(st), [])
    shipped = dict((p, show(r["work"], r["work_commit"], p)) for p in ("w.txt", "v.txt"))
    for did, rec in sorted(r["defects"].items()):
        if rec["status"] in ("present", "recreated"):
            d = [x for x in DW if x["id"] == did][0]
            seen = [C.jload(os.path.join(st, "judge-present", n + ".json")) for n in inputs(st, "judge-present") if of(n) == did]
            here = [doc for doc in seen if all(f["text"].rstrip("\n") == shipped[f["path"]] for f in doc["files"])]
            ok("fixpoint: seed {}: {} counts only once a judge saw the shipped tree and said yes".format(seed, did), len(here) == 1 and pick("judge-present", did, 0, here[0]) == "yes", (len(here), rec))
    before = snapshot(st)
    run(st)
    is_("fixpoint: seed {}: a further run changes nothing".format(seed), sorted(k for k in set(before) | set(snapshot(st)) if before.get(k) != snapshot(st).get(k)), [])

# cargo is asked once per tree, however the groups were arrived at (M1: a merge changes the groups, not the tree)
RK = helpers.make_repo(ROOT, "adjcargo")
BK = cm(RK, "2026-09-20T10:00:00Z", {"README.md": "r\n"}, "base")
git(RK, "checkout", "-q", "-b", "feat")
KL = ["l{}".format(i) for i in range(1, 11)]
KL[4], KL[6] = "P bad", "Q bad"
TK = cm(RK, "2026-10-01T09:00:00Z", {"a.txt": SS(KL), "Cargo.toml": "[package]\nname = \"k\"\n", PLAN: "plan\n"}, "task 1")
KL[4] = "P good"
KP = cm(RK, "2026-10-01T10:00:00Z", {"a.txt": SS(KL)}, "fix P")
KL[6] = "Q good"
KQ = cm(RK, "2026-10-01T11:00:00Z", {"a.txt": SS(KL)}, "fix Q")
git(RK, "checkout", "-q", "main")
KLOG = os.path.join(ROOT, "cargo-k.log")
put(STUB, "cargo", "#!/bin/sh\ngit write-tree >> {}\nexit 0\n".format(KLOG))
S52 = setup_state("w-adjcargo", [rec_branch("badjk0001", RK, "feat", BK, KQ, TK)], {"badjk0001": [dfx("d00000k01", "task", "P1", [(TK, KP)], "a.txt"),
                                                                                         dfx("d00000k02", "task", "P2", [(KP, KQ)], "a.txt")]})
os.environ["PATH"] = STUB + os.pathsep + old_path
try:
    runs = drive(S52, lambda kind, did, k, doc: "yes")
finally:
    os.environ["PATH"] = old_path
r = inj(S52, "badjk0001")
trees = open(KLOG).read().split()
is_("cargo (M1): the adjacent fixes are one group and both present", (sorted(v["status"] for v in r["defects"].values()), r["defects"]["d00000k01"]["group"] == r["defects"]["d00000k02"]["group"]),
    (["present", "present"], True))
is_("cargo (M1): cargo checked each tree once, over every run, though the groups changed", (len(trees), len(set(trees))), (1, 1))

# a cargo check that fails once a recreation joins takes out the recreation on trial, not a revert
put(STUB, "cargo", "#!/bin/sh\ngit write-tree >> {}\nif grep -rq RECREATED src; then echo 'error: recreated' >&2; exit 1; fi\nexit 0\n".format(LOG + "3"))
S37 = setup_state("w-cargo-trial", [CG], {"bcargo001": DG + [dfx("d00000034", "task", "P2", [], "src/r4.rs")]})
os.environ["PATH"] = STUB + os.pathsep + old_path
try:
    runs = drive(S37, lambda kind, did, k, doc: "yes", edit=lambda did, tree: put(tree, "src/rec.rs", "// RECREATED\n"))
finally:
    os.environ["PATH"] = old_path
r = inj(S37, "bcargo001")
is_("build_check: a cargo failure on the tree a recreation joins undoes the recreation, newest first, and keeps the reverts",
    (sorted((k, v["status"]) for k, v in r["defects"].items()), r["defects"]["d00000034"]["reason"].startswith("cargo check failed"), r["build_check"]),
    ([("d00000031", "present"), ("d00000032", "present"), ("d00000033", "present"), ("d00000034", "unassessable")], True, "passed after undoing 1 step(s)"))
is_("build_check: two trees, two cargo checks, over every run", len(open(LOG + "3").read().split()), 2)

# a repair that stops applying while recreations are on trial is theirs to answer for (a unit test: no fixture reaches it)
FX = INJ.Fixpoint(Namespace(state=ROOT), {"id": "bunit0001"}, None, None, None,
                  {"groups": [{"id": "d1", "members": ["d1"], "pieces": [{"rank": 0.0, "text": ""}], "patch": "", "files": ["a"]}], "bad": {"d2": "no fix range"}},
                  [dfx("d1", "task", "P1", [], "a"), dfx("d2", "task", "P2", [], "b")], {}, collections.Counter(), {}, INJ.Questions())
FX.out.pop("d2")
FX.tried.add("d2")
FX.mode["d2"], FX.rec["d2"] = "trial", ("patch", "reverse")
FX.resolve("HEAD", FX.groups[0], "does not apply")
is_("trial: a group whose repair stops applying in a trial round keeps its place; the recreation on trial leaves, unassessable",
    (FX.mode, FX.out), ({"d1": "revert"}, {"d2": ("unassessable", "on trial, it stopped the repair of another defect from applying")}))

# ================================================================ a question the fixpoint no longer needs is not handed out
S53 = setup_state("w-obsolete", [CONF], {"bconf0001": [DE, DF]})
run(S53)
OTHER = "aaaa1111-0-d0000000f"
C.judge_write(S53, "judge-present", OTHER, {"finding": {"summary": "a question another module asks"}, "files": []})
pend = lambda: sorted(p[1] for p in C.pending(S53) if p[0] == "judge-present")
first = judged(S53, "judge-present", "d0000000f")
is_("needed: the question the fixpoint waits on is pending, beside another module's", pend(), sorted(first + [OTHER]))
C.jsave(os.path.join(S53, "inventory", "bconf0001.json"), {"branch": "bconf0001", "defects": [DE, dict(DF, summary="defect d0000000f, reworded")], "dropped": []})
run(S53)
now = [n for n in judged(S53, "judge-present", "d0000000f") if n not in first]
is_("needed: once the inventory changes the finding, the old question is no longer pending; the new one and the other module's are",
    (len(now), pend()), (1, sorted(now + [OTHER])))
is_("needed: the manifest owns both questions and needs the new one; it knows nothing of the other module's",
    C.jload(os.path.join(S53, "judge-present", "needed.json")), {"owned": sorted(first + now), "needed": now})
say(S53, "d0000000f", "yes")
run(S53)
is_("needed: answered, nothing of inject's is needed: only the other module's question and the recreation are handed out",
    sorted((p[0], p[1]) for p in C.pending(S53)), [("judge-present", OTHER), ("recreate", "d0000000e")])
