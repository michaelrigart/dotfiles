"""The coverage gate (spec 4.3): a per-task defect that did not revert or validate gets one hand re-creation.

  recreate/<defect>.json, recreate/<defect>.brief.md   the finding, the fix and a plain copy of the final tree, and what to do with it
  recreate/<defect>/done                               the agent's signal that it has edited recreate/<defect>/tree
  judge-same/<defect>                                  is the edit the same defect (the patch is the final tree against the edited copy)
  judge-present/<defect>-r                             is it present in the finished tree (validate, below, asks every such question)
"""
import os
import shutil
import subprocess
import tempfile

from . import common as C
from . import inventory as I
from . import patches as P
from . import scratch
from .common import Failed

XR = C.XR

FILE_CAP, FILES_CAP = 60000, 150000

RECREATE_BRIEF = """Read {spec}. It holds a reported defect (finding), the change that fixed it (fix) and the path of a copy of the code (tree).

Edit only the files under {tree} so that the defect described is present again: undo what the fix did, and nothing else.
Do not use git. Leave every other file as it is.

When you have finished, create an empty file at {done}.
"""


def finding(d):
    """The part of an inventory defect a judge or an agent sees: no class."""
    return dict((k, d.get(k)) for k in I.KEYS)


def paths_of(d):
    """The files a judge sees for a defect: the finding's file, then the files its fix changes."""
    names = []
    for n in [C.norm(d.get("file"))] + list(d.get("files") or []):
        if n and n not in names:
            names.append(n)
    return names


def differs(work, a, b, paths):
    """Does any of `paths` have other content at commit a than at commit b."""
    return a != b and bool(paths) and not C.git_ok(work, "diff", "--quiet", a, b, "--", *[":(top,literal)" + n for n in paths])


def files_input(work, rev, d):
    """[{path, text}]: the finding's file, then the files its fix changes, as `rev` has them (60000 characters each, 150000 in all)."""
    out, room = [], FILES_CAP
    for n in paths_of(d):
        if room <= 0:
            break
        try:
            data = C.git(work, "show", "{}:{}".format(rev, n), raw=True)
        except Failed:
            continue
        text = C.cap(data.decode("utf-8", "replace"), min(FILE_CAP, room))
        room -= len(text)
        out.append({"path": n, "text": text})
    return out


def validate(state, work, rev, d, jid, counts):
    """The judge's answer ("yes", "no", "unclear") to: can the defect's failure scenario happen in the tree at `rev`. None until it answers."""
    I._put(state, "judge-present", jid, {"finding": finding(d), "files": files_input(work, rev, d)}, counts)
    ans = C.judge_answer(state, "judge-present", jid)
    if not isinstance(ans, dict):
        return None
    return ans.get("answer") if ans.get("answer") in ("yes", "no", "unclear") else "unclear"


def tree_patches(work, final, tree_dir):
    """(patch, reverse patch) between the final tree and the edited copy of it, outside docs/superpowers."""
    tmp = tempfile.mkdtemp(prefix="inject-index.")
    try:
        gd = os.path.join(work, ".git")
        env = C.git_env({"GIT_INDEX_FILE": os.path.join(tmp, "index")})
        base = ["git", "--git-dir", gd, "--work-tree", tree_dir] + scratch.NEUTRAL
        for argv in (["add", "-A", "-f", "--", "."], ["write-tree"]):
            p = subprocess.run(base + argv, cwd=tree_dir, env=env, capture_output=True)
            if p.returncode != 0:
                raise Failed("cannot read {}: {}".format(tree_dir, p.stderr.decode("utf-8", "replace").strip()))
        edited = p.stdout.decode().strip()
    finally:
        shutil.rmtree(tmp, ignore_errors=True)
    old = C.git(work, "rev-parse", final + "^{tree}")
    return P.diff(work, old, edited), P.diff(work, edited, old)


def recreation(a, work, final, d, fix_text, counts):
    """(kind, why, patch, reverse) for one per-task defect that did not revert or validate. kind: "agent" (the recreation is not finished),
    "judge" (judge-same has not answered), "unassessable" or "candidate" (patch, and reverse: the patch that undoes it)."""
    state = a.state
    brief = os.path.join(state, "recreate", d["id"] + ".json")
    tree = os.path.join(state, "recreate", d["id"], "tree")
    if not os.path.exists(brief):
        if not os.path.isdir(tree):
            scratch.export(os.path.join(work, ".git", "objects"), final, tree)
        C.jsave(brief, {"finding": finding(d), "fix": C.cap(P.judge_text(fix_text), I.REPORT_CAP * 2), "tree": C.aliased(state, tree)})
    text = os.path.join(state, "recreate", d["id"] + ".brief.md")
    if not os.path.exists(text):
        C.jsave(text, RECREATE_BRIEF.format(spec=C.aliased(state, brief), tree=C.aliased(state, tree),
                                            done=C.aliased(state, os.path.join(state, "recreate", d["id"], "done"))))
    if not os.path.exists(os.path.join(state, "recreate", d["id"], "done")):
        return "agent", "the recreation is not finished", None, None
    mine = os.path.join(state, "recreated", d["id"])
    if not os.path.exists(mine + ".patch"):
        patch, reverse = tree_patches(work, final, tree)
        os.makedirs(os.path.dirname(mine), exist_ok=True)
        for suffix, body in ((".repair.patch", reverse), (".patch", patch)):
            with open(mine + suffix, "wb") as f:
                f.write(P.to_bytes(body))
    with open(mine + ".patch", "rb") as f:
        patch = f.read().decode("utf-8", "surrogateescape")
    with open(mine + ".repair.patch", "rb") as f:
        reverse = f.read().decode("utf-8", "surrogateescape")
    if not patch.strip():
        return "unassessable", "the recreation changed nothing", None, None
    I._put(state, "judge-same", d["id"], {"original": {"finding": finding(d), "fix": C.cap(P.judge_text(fix_text), XR.MAX_INTERDIFF)},
                                          "candidate": {"patch": C.cap(P.judge_text(patch), XR.MAX_INTERDIFF)}}, counts)
    ans = C.judge_answer(state, "judge-same", d["id"])
    if not isinstance(ans, dict):
        return "judge", "judge-same has not answered", None, None
    if ans.get("answer") != "yes":
        return "unassessable", "the judge did not find the same defect ({})".format(ans.get("answer")), None, None
    return "candidate", "", patch, reverse
