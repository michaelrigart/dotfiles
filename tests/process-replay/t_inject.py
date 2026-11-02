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
    return sorted(n[:-5] for n in os.listdir(d) if n.endswith(".json") and not n.endswith(".answer.json")) if os.path.isdir(d) else []


def examined(state, bid):
    return [e for e in cases(state)["examined"] if e["branch"] == bid][0]


def yes_all(state, ids, kind="judge-present"):
    for i in ids:
        answer(state, kind, i, {"answer": "yes"})


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
    out = [{"index": files["src/b.py"], "defect": first(by_summary)}, {"index": files["src/c.py"], "defect": second(by_summary)}]
    answer(state, "judge-split", names[0], {"hunks": out})


# ---- fix_patch
V = C.view(world("w-view"), os.path.join(R, ".git"), NO_SNAPSHOT)
fp = INJ.fix_patch(V, FA, FBC)
ok("docs_pinned: fix_patch holds the code of the range and no docs/superpowers path", "src/b.py" in fp and "src/c.py" in fp and "docs/superpowers" not in fp, fp)
ok("revert_whole_with_tests: fix_patch holds the fix's test files", "tests/test_a.py" in INJ.fix_patch(V, T1, FA))

# ---- the split judge, then the injected tree
S1 = main_state("w-main")
rc, out = run(S1)
is_("exits 0", rc, 0)
names, docs = split_input(S1)
is_("split_groups: one judge-split for the range two defects share", len(names), 1)
d0 = docs[0]
is_("split_groups: its hunks are the code hunks only, one per file, with fresh indices", [(h["index"], h["file"]) for h in d0["hunks"]],
    [(0, "src/b.py"), (1, "src/c.py")])
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
ok("revert_whole_with_tests: the pre-merge defect is reverted too", "bug D" in show(W, WC, "src/d.py"))
is_("docs_pinned: docs/superpowers equals the plan commit's", show(W, WC, PLAN), "plan v1")
ok("docs_pinned: files added to docs/superpowers later are gone", not has(W, WC, "docs/superpowers/specs/late.md"))
is_("docs_pinned: the record names the plan commit", r1["plan_commit"], T1)
is_("revert_whole_with_tests: the injected commit's parent is the final tree's commit", git(W, "rev-parse", WC + "~1"), r1["final_commit"])
is_("revert_whole_with_tests: the final tree's commit holds the branch's final tree", git(W, "rev-parse", r1["final_commit"] + "^{tree}"),
    git(R, "rev-parse", FD + "^{tree}"))
is_("validation: a judge-present per reverted defect is waiting", inputs(S1, "judge-present"), sorted(IDS))
pi = C.jload(os.path.join(S1, "judge-present", "d0000000a.json"))
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
answer(S2b, "judge-split", names[0], {"hunks": [{"index": fb["src/b.py"], "defect": bi}, {"index": fb["src/c.py"], "defect": None}]})
run(S2b)
r = inj(S2b, "bmain0001")
ok("split_groups: a hunk given to none is not reverted", "fixed C" in show(r["work"], r["work_commit"], "src/c.py") and "bug B" in show(r["work"], r["work_commit"], "src/b.py"))
ok("split_groups: and the defect with no hunk left is dropped-revert", r["defects"]["d0000000c"]["status"] == "dropped-revert", r["defects"]["d0000000c"])

# ---- validation: yes, no, unclear
S3 = main_state("w-valid")
run(S3)
split_answer(S3, lambda m: m["defect d0000000b"], lambda m: m["defect d0000000c"])
run(S3)
answer(S3, "judge-present", "d0000000a", {"answer": "yes"})
answer(S3, "judge-present", "d0000000b", {"answer": "no"})
answer(S3, "judge-present", "d0000000c", {"answer": "unclear"})
answer(S3, "judge-present", "d0000000d", {"answer": "yes"})
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
answer(S3b, "judge-present", "d0000000d", {"answer": "no"})
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
answer(S3c, "judge-present", "d0000000d", {"answer": "no"})
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
is_("validation: only the reverted defect is sent to a judge", inputs(S5, "judge-present"), ["d0000000f"])
is_("coverage_gate: no recreation before the validations are in", inputs(S5, "recreate"), [])
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
    answer(state, "judge-same", "d0000000e", {"answer": same})
    run(state)
    if present:
        answer(state, "judge-present", "d0000000e-r", {"answer": present})
        run(state)


run(S5)
recreate(S5, {"src/e.py": "line1\nline2 BUG E recreated\nline3\n"}, "yes", "yes")
ok("revalidate: a present defect whose files the recreation did not touch is not asked again", "d0000000f-v" not in inputs(S5, "judge-present"), inputs(S5, "judge-present"))
js = C.jload(os.path.join(S5, "judge-same", "d0000000e.json"))
is_("coverage_gate: judge-same holds the original finding and fix, and the candidate patch", (sorted(js), sorted(js["original"]), sorted(js["candidate"])),
    (["candidate", "original"], ["finding", "fix"], ["patch"]))
ok("coverage_gate: the candidate patch is the agent's edit", "+line2 BUG E recreated" in js["candidate"]["patch"] and "-line2 rewritten" in js["candidate"]["patch"], js["candidate"]["patch"])
pr = C.jload(os.path.join(S5, "judge-present", "d0000000e-r.json"))
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
ok("coverage_gate: and no judge-present was asked for it", "d0000000e-r" not in inputs(S7, "judge-present"), inputs(S7, "judge-present"))
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

# coherent() on its own
CO = os.path.join(ROOT, "coh")
for path, text in {"ok.sh": "echo a\n", "bad.sh": "if true; then\n", "ok.py": "x = 1\n", "bad.py": "def (:\n", "ok.json": "{}\n", "bad.json": "{\n",
                   "shebang": "#!/bin/bash\nif true; then\n", "zshbang": "#!/usr/bin/env zsh\nfor x in 1; do\n", "dot_config/zsh/functions/fn": "f() {\n",
                   "plain.txt": "if true; then\n", "gone/ok": "x\n"}.items():
    put(CO, path, text)
is_("coherent: a good .sh file", INJ.coherent(CO, ["ok.sh"]), (True, ""))
b = INJ.coherent(CO, ["bad.sh"])
ok("coherent: bash -n on a .sh file", b[0] is False and "bad.sh" in b[1], b)
b = INJ.coherent(CO, ["shebang"])
ok("coherent: bash -n on a bash shebang", b[0] is False, b)
b = INJ.coherent(CO, ["zshbang"])
ok("coherent: zsh -n on a zsh shebang", b[0] is False, b)
b = INJ.coherent(CO, ["dot_config/zsh/functions/fn"])
ok("coherent: zsh -n on a file under zsh/functions", b[0] is False, b)
b = INJ.coherent(CO, ["bad.py"])
ok("coherent: a Python syntax error", b[0] is False and "bad.py" in b[1], b)
is_("coherent: a good .py and .json", INJ.coherent(CO, ["ok.py", "ok.json"]), (True, ""))
b = INJ.coherent(CO, ["bad.json"])
ok("coherent: a JSON parse error", b[0] is False and "bad.json" in b[1], b)
is_("coherent: a file of no known kind, and a path that is gone, are fine", INJ.coherent(CO, ["plain.txt", "nothere.sh"]), (True, ""))

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
   all("bug" in show(r["work"], r["work_commit"], f) for f in ("p.py", "q.py", "r.py")) and r["stage1"]["groups"]["d00000061"]["status"] == "reverted"
   and r["stage1"]["groups"]["d00000062"]["status"] == "reverted", r["stage1"]["groups"])
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
is_("hunks: a defect whose lines another revert shifted is located where it is in the finished tree, not where its patch was made",
    r["defects"]["d00000052"]["hunks"], [{"file": "s.txt", "start": 5, "end": 11, "new_start": 5, "new_end": 11}])
ok("hunks: control: the patch itself was made 3 lines lower", "@@ -8,7 +8,7 @@" in open(os.path.join(S21, "repairs", "d00000052.patch")).read(),
   open(os.path.join(S21, "repairs", "d00000052.patch")).read())
is_("hunks: and the first change, which sits above, is at the top", r["defects"]["d00000051"]["hunks"],
    [{"file": "s.txt", "start": 1, "end": 3, "new_start": 1, "new_end": 6}])
is_("hunks: the dropped defect is waiting for its recreation", (r["defects"]["d00000053"]["status"], inputs(S21, "recreate")), ("dropped-revert", ["d00000053"]))


def shift_recreate(st, mv, nv):
    put(os.path.join(st, "recreate", "d00000053", "tree"), "s.txt", SS(["m1", "m2", "m3"] + [("l4X" if x == "l4" else x) for x in LINES_N[3:]]))
    put(os.path.join(st, "recreate", "d00000053"), "done", "")
    run(st)
    answer(st, "judge-same", "d00000053", {"answer": "yes"})
    run(st)
    answer(st, "judge-present", "d00000053-r", {"answer": "yes"})
    answer(st, "judge-present", "d00000051-v", {"answer": mv})
    answer(st, "judge-present", "d00000052-v", {"answer": nv})
    run(st)
    return inj(st, "bshift001")


r = shift_recreate(S21, "yes", "yes")
is_("revalidate: after the recreation is applied, each present defect in a file it touched is validated again on the finished tree",
    sorted(n for n in inputs(S21, "judge-present") if n.endswith("-v")), ["d00000051-v", "d00000052-v"])
ok("revalidate: and that input shows the finished tree", "l4X" in C.jload(os.path.join(S21, "judge-present", "d00000052-v.json"))["files"][0]["text"])
is_("revalidate: each stays present when the judge still finds it, and the recreated one is recreated",
    sorted((k, v["status"]) for k, v in r["defects"].items()), [("d00000051", "present"), ("d00000052", "present"), ("d00000053", "recreated")])
is_("revalidate: the hunks of a defect are located in the finished tree, recreation included", r["defects"]["d00000052"]["hunks"],
    [{"file": "s.txt", "start": 5, "end": 11, "new_start": 5, "new_end": 11}])
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
ok("hunks: control: both are reverted in the tree", "P bad" in show(r["work"], r["work_commit"], "a.txt") and "Q bad" in show(r["work"], r["work_commit"], "a.txt"))
is_("hunks: a repair made with the other fix's lines in place does not apply to the finished tree: unassessable, with the reason, and no repair file",
    (r["defects"]["d00000082"]["status"], "does not apply" in r["defects"]["d00000082"]["reason"], r["defects"]["d00000082"]["repair"],
     os.path.exists(os.path.join(S24, "repairs", "d00000082.patch"))), ("unassessable", True, None, False))
is_("hunks: the other one applies and is located", (r["defects"]["d00000081"]["status"], r["defects"]["d00000081"]["hunks"]),
    ("present", [{"file": "a.txt", "start": 2, "end": 8, "new_start": 2, "new_end": 8}]))
is_("hunks: the demoted per-task defect is listed in coverage", cases(S24)["coverage"], {"unassessable_task": ["d00000082"]})

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
answer(S14, "judge-present", "dzr2", {"answer": "no"})
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
ok("coverage_gate: a branch that cannot qualify (its pre-merge P1 fails) and waits for its recreation holds no place: the next candidate is built within a limit of one",
   examined(S20, "bconf0002")["qualified"] is False and "recreation" in examined(S20, "bconf0002")["why"] and os.path.exists(os.path.join(S20, "work", "bqh1")),
   (examined(S20, "bconf0002"), os.listdir(os.path.join(S20, "work"))))
INJ.MAX_CASES = old_limits[0]
