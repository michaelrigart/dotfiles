"""Merge evidence (R3): whether, and when, the destination's current tip brought a branch in.

The destination's tip is read from the ORIGINAL repository's refs (read only), then walked through the
reader's private view. A tip the view does not have (the destination has moved on since the snapshot) is
replaced by the newest commit of its first-parent history that the view has. A branch is never assumed merged.

`repo` is a common.Reader: .gitdir (the original), .view, .has_commit(), .is_ancestor().
"""
import time

from . import common as C
from .common import Failed

SKEW = 3 * 86400                       # how far before the final tip's date a merge commit is still looked for
WALK = 20000                           # first-parent commits of the original looked at for a tip the view has


def _iso(sec):
    return time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(sec))


def _first_true(items, pred):
    """The index of the first item for which `pred` holds, when it holds from there on to the last."""
    lo, hi = 0, len(items) - 1
    while lo < hi:
        mid = (lo + hi) // 2
        if pred(items[mid]):
            hi = mid
        else:
            lo = mid + 1
    return lo


def _applied(repo, dest_tip, base, final_tip):
    """Every commit of base..final_tip has an equivalent in dest_tip (git cherry marks each `-`)."""
    try:
        lines = C.git(repo.view, "cherry", dest_tip, final_tip, base).splitlines()
    except Failed:
        return False
    return bool(lines) and all(line.startswith("- ") for line in lines)


def _squashed(repo, commit, base, final_tip):
    """Merging the branch into the commit's first parent gives the commit's own tree."""
    p = C.git_run(repo.view, ["merge-tree", "--write-tree", "--merge-base=" + base, commit + "^", final_tip])
    if p.returncode != 0:
        return False
    tree = p.stdout.decode("utf-8", "replace").split("\n", 1)[0].strip()
    try:
        return bool(tree) and tree == C.git(repo.view, "rev-parse", commit + "^{tree}")
    except Failed:
        return False


def _parent(repo, commit):
    try:
        return C.git(repo.view, "rev-parse", "--verify", "--quiet", commit + "^1^{commit}") or None
    except Failed:
        return None


def _brought_in(repo, dest_tip, base, final_tip):
    try:
        born = int(C.git(repo.view, "log", "-1", "--format=%ct", final_tip))
        rows = C.git(repo.view, "log", "--first-parent", "--format=%H %ct", "--max-age={}".format(born - SKEW), dest_tip)
        old = [(s, int(t)) for s, t in (line.split() for line in rows.splitlines())][::-1]
    except (Failed, ValueError):
        return None
    if not old:
        return None

    def found(how, row, before):
        return {"how": how, "commit": row[0], "at": _iso(row[1]), "before": before}

    if repo.is_ancestor(final_tip, old[-1][0]):
        row = old[_first_true(old, lambda r: repo.is_ancestor(final_tip, r[0]))]
        return found("ancestry", row, None if row[0] == final_tip else _parent(repo, row[0]))
    if _applied(repo, old[-1][0], base, final_tip):
        return found("rebase", old[_first_true(old, lambda r: _applied(repo, r[0], base, final_tip))], None)
    for row in old:
        if _squashed(repo, row[0], base, final_tip):
            return found("squash", row, _parent(repo, row[0]))
    return None


def dest_tips(repo, dest):
    """([tip], refs exist): the destination's tips the view can read, origin's branch first, then the local one.
    A ref whose tip the view lacks gives the newest commit of its first-parent history that the view has."""
    tips, exist = [], False
    for ref in ("refs/remotes/origin/" + dest, "refs/heads/" + dest):
        try:
            tip = C.git(repo.gitdir, "rev-parse", "--verify", "--quiet", ref + "^{commit}")
        except Failed:
            continue
        if not tip:
            continue
        exist = True
        if not repo.has_commit(tip):
            try:
                walk = C.git(repo.gitdir, "rev-list", "--first-parent", "--max-count={}".format(WALK), tip).split()
                out = C.git(repo.view, "cat-file", "--batch-check=%(objectname) %(objecttype)", input=("\n".join(walk) + "\n").encode())
            except Failed:
                continue
            tip = next((line.split()[0] for line in out.splitlines() if line.endswith(" commit")), None)
        if tip and tip not in tips:
            tips.append(tip)
    return tips, exist


def merge_evidence(repo, dest, base, final_tip, tips=None):
    """{how: ancestry|rebase|squash, commit, at, before} when the destination's current tip brings the branch
    in, else None. `at` is the committer date of the first-parent commit of that tip that does; `before` is
    that commit's first parent when the branch's own commits are not its ancestors (a merge or a squash), else
    None. A rebase merge is `git cherry` marking every branch commit `-`; a squash merge is a first-parent
    commit equal to its parent plus the branch (`git merge-tree`). The tips are tried in order."""
    for tip in dest_tips(repo, dest)[0] if tips is None else tips:
        found = _brought_in(repo, tip, base, final_tip)
        if found:
            return found
    return None
