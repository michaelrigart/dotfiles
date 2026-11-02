"""Patch text: reading a git diff by file and hunk, choosing hunks, and finding where a patch's change sits in a tree.

A patch here is the text of `git diff` (binary files included), always outside docs/superpowers. A patch is split into items, each
hunk of a file or a file section that has none (binary, mode change, empty file), so a judge can place them and `select` can write
a patch of the chosen ones, with the new-side line numbers of the hunks left out above them taken off.
"""
import os
import re
import shutil
import tempfile

from . import common as C
from . import scratch
from .common import Failed

L = C.L

DOCS = "docs/superpowers"
_HUNK = re.compile(r"\A@@ -(\d+(?:,\d+)?) \+(\d+)((?:,\d+)?) @@(.*)\Z", re.S)


def to_bytes(text):
    return text.encode("utf-8", "surrogateescape")


def judge_text(text):
    """Patch text as a judge input holds it: valid UTF-8."""
    return to_bytes(text).decode("utf-8", "replace")


def diff(repo, a, b):
    """`git diff a b` outside docs/superpowers, as text that applies as it stands (binary files included)."""
    out = C.git(repo, *(["diff", "--no-color", "--binary", "--full-index"] + L.DIFF_FLAGS + L.DIFF_PREFIXES
                        + [a, b, "--", ":(top)", ":(top,exclude)" + DOCS]), raw=True)
    return out.decode("utf-8", "surrogateescape")


def fix_patch(view, a, b):
    """The change from commit a to commit b, read through `view`, without docs/superpowers."""
    return diff(view, a, b)


def _file_of(line):
    rest = line[len("diff --git "):]
    m = re.match(r"a/(.*) b/\1\Z", rest, re.S)
    return m.group(1) if m else rest


def parse_patch(text):
    """[{file, head: [line], hunks: [{old, ns, nlraw, nl, ol, tail, header, lines}]}], one per file of a git diff.
    A file with no hunk (binary, mode change, empty file) has `hunks: []`; its whole section is its head."""
    lines = text.split("\n")
    if lines and lines[-1] == "":
        lines.pop()
    sections = []
    for line in lines:
        if line.startswith("diff --git "):
            sections.append({"file": _file_of(line), "head": [line], "hunks": []})
            continue
        if not sections:
            raise Failed("not a git diff: {!r}".format(line[:60]))
        sec = sections[-1]
        m = _HUNK.match(line)
        if m:
            old, ns, nlraw, tail = m.groups()
            ol = int(old.split(",")[1]) if "," in old else 1
            sec["hunks"].append({"old": old, "ns": int(ns), "nlraw": nlraw, "nl": int(nlraw[1:]) if nlraw else 1, "ol": ol, "tail": tail,
                                 "header": line, "lines": []})
        elif sec["hunks"]:
            sec["hunks"][-1]["lines"].append(line)
        else:
            sec["head"].append(line)
    return sections


def files_of(text):
    return sorted(set(sec["file"] for sec in parse_patch(text)))


def item_list(sections):
    """The units a judge places: each hunk, or a file section that has none. [(section, hunk or None)]."""
    return [(si, hi) for si, sec in enumerate(sections) for hi in (range(len(sec["hunks"])) if sec["hunks"] else [None])]


def item_text(sections, item):
    si, hi = item
    sec = sections[si]
    if hi is None:
        return "\n".join(sec["head"]) + "\n"
    h = sec["hunks"][hi]
    return "\n".join(sec["head"] + [h["header"]] + h["lines"]) + "\n"


def select(sections, chosen):
    """The patch of the chosen items. A hunk's new-side start drops by what the hunks left out above it changed."""
    out = []
    for si, sec in enumerate(sections):
        if not sec["hunks"]:
            if (si, None) in chosen:
                out += sec["head"]
            continue
        keep = [hi for hi in range(len(sec["hunks"])) if (si, hi) in chosen]
        if not keep:
            continue
        out += sec["head"]
        left_out = 0
        for hi, h in enumerate(sec["hunks"]):
            if hi not in keep:
                left_out += h["nl"] - h["ol"]
                continue
            out.append("@@ -{} +{}{} @@{}".format(h["old"], h["ns"] - left_out, h["nlraw"], h["tail"]))
            out += h["lines"]
    return "\n".join(out) + "\n" if out else ""


def locate(work, head, text):
    """(hunks, why): where a repair's change sits in the tree at `head`, found by applying the repair to a temporary index of that tree
    and reading the diff. [{file, start, end, new_start, new_end}]: start and end are lines of the tree as it is (a pure insertion is
    the line it follows), new_start and new_end lines once repaired. None and the reason when the repair does not apply there."""
    tmp = tempfile.mkdtemp(prefix="inject-locate.")
    try:
        env = {"GIT_INDEX_FILE": os.path.join(tmp, "index")}
        C.git(work, "read-tree", head, env=env)
        p = C.git_run(work, scratch.NEUTRAL + ["apply", "--cached", "--whitespace=nowarn", "-"], input=to_bytes(text), env=env)
        if p.returncode != 0:
            return None, (p.stderr.decode("utf-8", "replace").strip().splitlines() or ["git apply failed"])[0]
        patch = diff(work, head + "^{tree}", C.git(work, "write-tree", env=env))
    finally:
        shutil.rmtree(tmp, ignore_errors=True)
    out = []
    for sec in parse_patch(patch):
        for h in sec["hunks"]:
            first = max(int(h["old"].split(",")[0]), 1)
            out.append({"file": sec["file"], "start": first, "end": first + max(h["ol"], 1) - 1, "new_start": h["ns"],
                        "new_end": h["ns"] + max(h["nl"], 1) - 1})
    return out, ""
