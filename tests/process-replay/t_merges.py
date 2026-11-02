import os
import shutil
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import helpers
from helpers import git, is_, ok, put

helpers.setup()
from process_replay import common as C  # noqa: E402
from process_replay import merges as M  # noqa: E402

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


def make_branch(repo, name, base, steps):
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


STATE = os.path.join(ROOT, "state")
MR = helpers.make_repo(ROOT, "mrepo")
with dated("2026-09-01T10:00:00Z"):
    put(MR, "base.txt", "base\n")
    M0 = helpers.commit(MR, "base")
FA = make_branch(MR, "fa", M0, [("2026-09-10T10:00:00Z", {"a1.txt": "1\n"}, "a1"), ("2026-09-11T10:00:00Z", {"a2.txt": "2\n"}, "a2")])
FB = make_branch(MR, "fb", M0, [("2026-09-12T10:00:00Z", {"b1.txt": "1\n"}, "b1"), ("2026-09-13T10:00:00Z", {"b2.txt": "2\n"}, "b2")])
FC = make_branch(MR, "fc", M0, [("2026-09-14T10:00:00Z", {"c1.txt": "1\n"}, "c1"), ("2026-09-15T10:00:00Z", {"c2.txt": "2\n"}, "c2")])
FD = make_branch(MR, "fd", M0, [("2026-09-16T10:00:00Z", {"d1.txt": "1\n"}, "d1")])
BEFORE_A = git(MR, "rev-parse", "main")
merge(MR, "fa", "2026-10-10T12:00:00Z")                                        # (a) a merge commit
MERGE_A = git(MR, "rev-parse", "main")
with dated("2026-10-12T12:00:00Z"):
    git(MR, "cherry-pick", FB[0], FB[1])                                        # (b) a rebase merge
BEFORE_C = git(MR, "rev-parse", "main")
git(MR, "merge", "--squash", "-q", "fc")                                       # (c) a squash merge
with dated("2026-10-15T12:00:00Z"):
    git(MR, "commit", "-q", "-m", "squash c")
SQUASH_C = git(MR, "rev-parse", "main")
put(MR, "later.txt", "later\n")
with dated("2026-10-20T12:00:00Z"):
    helpers.commit(MR, "later")
MG = C.L.common_dir(MR)
repo = C.Reader(STATE, MG, NO_SNAPSHOT)
for name, tips, how, when in (("a", FA, "ancestry", "2026-10-10T12:00:00Z"), ("b", FB, "rebase", "2026-10-12T12:00:00Z"),
                              ("c", FC, "squash", "2026-10-15T12:00:00Z")):
    ev = M.merge_evidence(repo, "main", M0, tips[-1])
    is_("merge_evidence ({}): {} merge, dated by the first-parent commit that brings the branch in".format(name, how), (ev or {}).get("how"), how)
    is_("merge_evidence ({}): at that commit's committer date".format(name), (ev or {}).get("at"), when)
ev = M.merge_evidence(repo, "main", M0, FA[-1])
is_("merge_evidence (a): the commit is the merge commit, not the branch tip, and `before` is main as it stood", (ev["commit"], ev["before"]), (MERGE_A, BEFORE_A))
ev = M.merge_evidence(repo, "main", M0, FC[-1])
is_("merge_evidence (c): the commit is the squash and `before` its parent", (ev["commit"], ev["before"]), (SQUASH_C, BEFORE_C))
ev = M.merge_evidence(repo, "main", M0, FB[-1])
is_("merge_evidence (b): a rebase merge has no `before` (its copies are not the branch's ancestors)", ev["before"], None)
is_("merge_evidence (none): an unmerged branch has no evidence", M.merge_evidence(repo, "main", M0, FD[-1]), None)
is_("merge_evidence: a one-commit branch that was never merged is not a squash of the others", M.merge_evidence(repo, "main", M0, FD[0]), None)

# a branch fast-forwarded into main: the tip itself brings it in, and nothing precedes it that is not its own
FF = make_branch(MR, "ff", git(MR, "rev-parse", "main"), [("2026-10-22T10:00:00Z", {"f1.txt": "1\n"}, "f1"), ("2026-10-22T11:00:00Z", {"f2.txt": "2\n"}, "f2")])
git(MR, "merge", "--ff-only", "-q", "ff")
ev = M.merge_evidence(C.Reader(STATE, MG, NO_SNAPSHOT), "main", FA[-1], FF[-1])
is_("merge_evidence: a fast-forward is ancestry, dated by the tip's own commit, with no `before`", (ev["how"], ev["commit"], ev["at"], ev["before"]),
    ("ancestry", FF[-1], "2026-10-22T11:00:00Z", None))

# origin's branch wins over a stale local one
git(MR, "update-ref", "refs/remotes/origin/main", git(MR, "rev-parse", "main"))
git(MR, "update-ref", "refs/heads/main", M0)
is_("merge_evidence: the destination's tip is origin's, ahead of a stale local branch",
    (M.merge_evidence(C.Reader(STATE, MG, NO_SNAPSHOT), "main", M0, FC[-1]) or {}).get("how"), "squash")
git(MR, "update-ref", "-d", "refs/remotes/origin/main")
is_("merge_evidence: without origin's ref, the stale local branch has no evidence",
    M.merge_evidence(C.Reader(STATE, MG, NO_SNAPSHOT), "main", M0, FC[-1]), None)
git(MR, "update-ref", "refs/heads/main", FF[-1])

# ---- dest_tips: a destination that moved past the snapshot
SNAP = os.path.join(ROOT, "snap")
shutil.copytree(os.path.join(MR, ".git", "objects"), os.path.join(SNAP, "mrepo", "objects"))
put(MR, "after.txt", "after the snapshot\n")
with dated("2026-10-25T10:00:00Z"):
    AFTER = helpers.commit(MR, "after")
put(MR, "after2.txt", "and again\n")
with dated("2026-10-26T10:00:00Z"):
    AFTER2 = helpers.commit(MR, "after again")
snap = C.Reader(STATE + "-snap", MG, SNAP)
ok("dest_tips: control: main's tip is not in the snapshot's view", not snap.has_commit(AFTER2) and not snap.has_commit(AFTER))
tips, exist = M.dest_tips(snap, "main")
is_("dest_tips: the newest first-parent commit of main that the view has stands in for a tip it lacks", (tips, exist), ([FF[-1]], True))
is_("merge_evidence: and is walked as the tip, so a merge made before the snapshot is still found",
    (M.merge_evidence(snap, "main", M0, FC[-1], tips) or {}).get("how"), "squash")
is_("merge_evidence: with no tips given they are read the same way", (M.merge_evidence(snap, "main", M0, FA[-1]) or {}).get("how"), "ancestry")
is_("dest_tips: a destination with no ref is ([], False)", M.dest_tips(snap, "nope"), ([], False))
os.makedirs(os.path.join(ROOT, "empty-snap", "mrepo", "objects"))
empty = C.Reader(STATE + "-empty", MG, os.path.join(ROOT, "empty-snap"))
is_("dest_tips: a snapshot that has nothing of the destination's history gives no tip, though the ref exists",
    M.dest_tips(empty, "main"), ([], True))
is_("merge_evidence: and so no evidence", M.merge_evidence(empty, "main", M0, FA[-1]), None)
