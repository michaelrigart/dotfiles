"""Judging a defect, and the coverage gate (spec 4.3).

Every judge-present and judge-same question is keyed by what the judge sees: its id is <defect>-<the first 12 hex digits of the
sha256 of its input>. A question about a given state of the files is asked once; its answer serves every run and every round that
asks the same; and no input is ever rewritten, or its answer set aside, by a later question, which has another id.

The coverage gate: a per-task defect that leaves the injected tree gets one hand re-creation.

  recreate/<defect>.json, recreate/<defect>.brief.md   the finding, the fix and a plain copy of the final tree, and what to do with it
  recreate/<defect>/done                               the agent's signal that it has edited recreate/<defect>/tree
  recreated/<defect>.patch, .repair.patch              the final tree against the edited copy, and back
  judge-same/<defect>-<digest>                         is the edit the same defect
"""
import hashlib
import json
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


def question_id(prefix, doc):
    """<prefix>-<12 hex>: the id of the question whose input is `doc`."""
    return "{}-{}".format(prefix, hashlib.sha256(json.dumps(doc, sort_keys=True).encode("utf-8")).hexdigest()[:12])


def ask(state, kind, prefix, doc, counts):
    """(id, answer document or None) of the question `doc` about `prefix`. Its input is written the first time it is asked."""
    jid = question_id(prefix, doc)
    if not os.path.exists(os.path.join(state, kind, jid + ".json")):
        C.judge_write(state, kind, jid, doc)
        counts[kind] += 1
    return jid, C.judge_answer(state, kind, jid)


def _verdict(ans):
    if not isinstance(ans, dict):
        return None
    return ans.get("answer") if ans.get("answer") in ("yes", "no", "unclear") else "unclear"


def validate(state, work, rev, d, counts):
    """(question id, answer): can the defect's failure scenario happen in the tree at `rev`. The answer is "yes", "no" or "unclear", or
    None until the judge answers."""
    jid, ans = ask(state, "judge-present", d["id"], {"finding": finding(d), "files": files_input(work, rev, d)}, counts)
    return jid, _verdict(ans)


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
    """The one second attempt of a per-task defect: {kind, why, patch, reverse, wait, same}. kind is "agent" (the recreation is not
    finished; wait: the defect), "judge" (judge-same has not answered; wait: its id), "unassessable", or "candidate" (patch: the final
    tree against the edit; reverse: the patch that undoes it). same: the id of the judge-same question, once it is asked."""
    state = a.state

    def out(kind, why, patch=None, reverse=None, wait=None, same=None):
        return {"kind": kind, "why": why, "patch": patch, "reverse": reverse, "wait": wait, "same": same}

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
        return out("agent", "the recreation is not finished", wait=d["id"])
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
        return out("unassessable", "the recreation changed nothing")
    jid, ans = ask(state, "judge-same", d["id"], {"original": {"finding": finding(d), "fix": C.cap(P.judge_text(fix_text), XR.MAX_INTERDIFF)},
                                                  "candidate": {"patch": C.cap(P.judge_text(patch), XR.MAX_INTERDIFF)}}, counts)
    verdict = _verdict(ans)
    if verdict is None:
        return out("judge", "judge-same has not answered", wait=jid, same=jid)
    if verdict != "yes":
        return out("unassessable", "the judge did not find the same defect ({})".format(verdict), same=jid)
    return out("candidate", "", patch, reverse, same=jid)
