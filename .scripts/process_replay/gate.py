"""Judging a defect, and the coverage gate (spec 4.3).

Every judge-present and judge-same question is keyed by what the judge sees: its id is <defect>-<the first 12 hex digits of the
sha256 of its input>. A judge-present input shows each file whole, or as windows around the repair's hunks (excerpts.py). A question
about a given state of the files is asked once; its answer serves every run and every round that asks the same; and no input is ever
rewritten, or its answer set aside, by a later question, which has another id.

The coverage gate: a per-task defect that leaves the injected tree gets one hand re-creation, made against the round's injected tree (the
final tree with every other active group reverted and docs/superpowers pinned: its base). Its id is <defect>-<the first 12 hex digits of its
base's tree id>, so a recreation made against another tree is another one, and a replay asks for the same.

  recreate/<id>.json, recreate/<id>.brief.md   the finding, the fix and a plain copy of the base tree, and what to do with it
  recreate/<id>/done                           the agent's signal that it has edited recreate/<id>/tree
  recreated/<id>.patch, .repair.patch          the base tree against the edited copy, and back
  judge-same/<defect>-<digest>                 is the edit the same defect
"""
import hashlib
import json
import os
import shutil
import subprocess
import tempfile

from . import common as C
from . import excerpts as E
from . import inventory as I
from . import patches as P
from . import scratch
from .common import Failed

XR = C.XR

RECREATE_BRIEF = """Read {spec}. It holds a reported defect (finding), the change that fixed it (fix) and the path of a copy of the code (tree).

Edit only the files under {tree} so that the defect described is present again: undo what the fix did, and nothing else.
Do not use git. Leave every other file as it is.

When you have finished, create an empty file at {done}.
"""


def finding(d):
    """The part of an inventory defect a judge or an agent sees: no class."""
    return dict((k, d.get(k)) for k in I.KEYS)


def files_input(work, rev, d, hunks):
    """([{path, text}], cut): the finding's file, then the files its fix changes, as `rev` has them, shown by excerpts.files_input around
    the repair's `hunks` (located in that tree) and the finding's line; `cut` names the files cut from the top for want of an anchor."""
    def read(path):
        try:
            return C.git(work, "show", "{}:{}".format(rev, path), raw=True).decode("utf-8", "replace")
        except Failed:
            return None
    return E.files_input(E.paths_of(d), read, E.anchors(finding(d), hunks))


def question_id(prefix, doc):
    """<prefix>-<12 hex>: the id of the question whose input is `doc`."""
    return "{}-{}".format(prefix, hashlib.sha256(json.dumps(doc, sort_keys=True).encode("utf-8")).hexdigest()[:12])


def ask(state, kind, prefix, doc, counts):
    """(id, answer document or None) of the question `doc` about `prefix`. Its input is written the first time it is asked."""
    jid = question_id(prefix, doc)
    if not os.path.exists(os.path.join(state, kind, jid + ".json")):
        C.judge_write(state, kind, jid, doc)
        counts[kind] += 1
    return jid, C.accepted_answer(state, kind, jid)


def _verdict(ans):
    return ans.get("answer") if isinstance(ans, dict) else None       # an accepted answer holds yes, no or unclear


def validate(state, work, rev, d, hunks, counts):
    """(question id, answer): can the defect's failure scenario happen in the tree at `rev`, where its repair's `hunks` lie. The answer is
    "yes", "no" or "unclear", or None until the judge answers. A file cut from the top for want of an anchor is recorded under the question."""
    files, cut = files_input(work, rev, d, hunks)
    jid, ans = ask(state, "judge-present", d["id"], {"finding": finding(d), "files": files}, counts)
    E.note_cut(state, jid, "validation", cut)
    return jid, _verdict(ans)


def tree_patches(work, base, tree_dir):
    """(patch, reverse patch) between the tree of commit `base` and the edited copy of it, outside docs/superpowers."""
    tmp = tempfile.mkdtemp(prefix="inject-index.")
    try:
        gd = os.path.join(work, ".git")
        env = C.git_env({"GIT_INDEX_FILE": os.path.join(tmp, "index")})
        git = ["git", "--git-dir", gd, "--work-tree", tree_dir] + scratch.NEUTRAL
        for argv in (["add", "-A", "-f", "--", "."], ["write-tree"]):
            p = subprocess.run(git + argv, cwd=tree_dir, env=env, capture_output=True)
            if p.returncode != 0:
                raise Failed("cannot read {}: {}".format(tree_dir, p.stderr.decode("utf-8", "replace").strip()))
        edited = p.stdout.decode().strip()
    finally:
        shutil.rmtree(tmp, ignore_errors=True)
    old = C.git(work, "rev-parse", base + "^{tree}")
    return P.diff(work, old, edited), P.diff(work, edited, old)


def recreation_id(did, tree):
    """<defect>-<the first 12 hex digits of the tree id>: the recreation of `did` made against that tree."""
    return "{}-{}".format(did, tree[:12])


def recreation(a, work, base, d, fix_text, counts):
    """The one second attempt of a per-task defect, made against commit `base` of `work`: {kind, why, patch, reverse, wait, same, rid}. kind
    is "agent" (the recreation is not finished; wait: the defect), "judge" (judge-same has not answered; wait: its id), "unassessable", or
    "candidate" (patch: base's tree against the edit; reverse: the patch that undoes it). same: the id of the judge-same question, once it
    is asked. rid: the id of the recreation's files."""
    state = a.state
    rid = recreation_id(d["id"], C.git(work, "rev-parse", base + "^{tree}"))

    def out(kind, why, patch=None, reverse=None, wait=None, same=None):
        return {"kind": kind, "why": why, "patch": patch, "reverse": reverse, "wait": wait, "same": same, "rid": rid}

    brief = os.path.join(state, "recreate", rid + ".json")
    tree = os.path.join(state, "recreate", rid, "tree")
    if not os.path.exists(brief):
        if not os.path.isdir(tree):
            scratch.export(os.path.join(work, ".git", "objects"), base, tree)
        C.jsave(brief, {"finding": finding(d), "fix": C.cap(P.judge_text(fix_text), I.REPORT_CAP * 2), "tree": C.aliased(state, tree)})
    text = os.path.join(state, "recreate", rid + ".brief.md")
    if not os.path.exists(text):
        C.jsave(text, RECREATE_BRIEF.format(spec=C.aliased(state, brief), tree=C.aliased(state, tree),
                                            done=C.aliased(state, os.path.join(state, "recreate", rid, "done"))))
    if not os.path.exists(os.path.join(state, "recreate", rid, "done")):
        return out("agent", "the recreation is not finished", wait=d["id"])
    mine = os.path.join(state, "recreated", rid)
    if not os.path.exists(mine + ".patch"):
        patch, reverse = tree_patches(work, base, tree)
        os.makedirs(os.path.dirname(mine), exist_ok=True)
        for suffix, body in ((".repair.patch", reverse), (".patch", patch)):     # each whole or absent: .patch existing means both are made
            C._write_if_changed(mine + suffix, P.to_bytes(body))
    with open(mine + ".patch", "rb") as f:
        patch = f.read().decode("utf-8", "surrogateescape")
    with open(mine + ".repair.patch", "rb") as f:
        reverse = f.read().decode("utf-8", "surrogateescape")
    if not patch.strip():
        return out("unassessable", "the recreation changed nothing")
    jid, ans = ask(state, "judge-same", d["id"], {"original": {"finding": finding(d), "fix": C.cap(P.judge_text(fix_text), XR.MAX_INTERDIFF)},
                                                  "candidate": {"patch": C.cap(P.judge_text(patch), XR.MAX_INTERDIFF)}}, counts)
    verdict = _verdict(ans)
    if verdict is None:
        return out("judge", "judge-same has not answered", wait=jid, same=jid)
    if verdict != "yes":
        return out("unassessable", "the judge did not find the same defect ({})".format(verdict), same=jid)
    return out("candidate", "", patch, reverse, same=jid)
