"""The files a judge is shown, and how a long one is cut (spec 14.2).

A file of up to FILE_CAP characters is shown whole. A longer one is shown as windows of CONTEXT lines either side of each anchor, each
headed `[lines <a>-<b> of <n>]`, with windows that overlap or touch merged; it shows no diff and no mark of what changed. The anchors
are the lines of the defect's repair in the tree the judge sees, and the finding's own line. A long file in which no anchor falls
keeps the cut from the top, and the input is recorded as cut:

  cuts/judge-present/<question id>.json   {site, files}, written only when a file was cut from the top for want of an anchor

Lines are counted as git counts them, on "\\n" alone.
"""
import os

from . import common as C
from . import patches as P

FILE_CAP, TOTAL_CAP, CONTEXT = 60000, 150000, 150
SITES = ("presence", "validation", "revalidation")
CUTS = os.path.join("cuts", "judge-present")


def paths_of(d):
    """The files a judge sees for a defect: the finding's file, then the files its fix changes."""
    names = []
    for n in [C.norm(d.get("file"))] + list(d.get("files") or []):
        if n and n not in names:
            names.append(n)
    return names


def reader(work, rev):
    """`read(path)` for files_input: the text of `path` in the tree at `rev` of `work`, or None when it is absent there."""
    def read(path):
        try:
            return C.git(work, "show", "{}:{}".format(rev, path), raw=True).decode("utf-8", "replace")
        except C.Failed:
            return None
    return read


def _line(n):
    return isinstance(n, int) and not isinstance(n, bool) and n >= 1


def anchors(finding, hunks):
    """{path: [(start, end)]}: each hunk of the repair under its file, and the finding's line under the finding's file."""
    out = {}
    for h in hunks:
        out.setdefault(h["file"], []).append((h["start"], h["end"]))
    path = C.norm(finding.get("file"))
    if path and _line(finding.get("line")):
        out.setdefault(path, []).append((finding["line"], finding["line"]))
    return out


def located(repo, rev, patch):
    """[{file, start, end}]: where each file of `patch` sits in the tree at `rev`. A file's section is located on its own, so a section
    that does not apply there adds nothing and the others stand."""
    secs = P.parse_patch(patch)
    out = []
    for si in range(len(secs)):
        chosen = set(item for item in P.item_list(secs) if item[0] == si)
        hunks, _ = P.locate(repo, rev, P.select(secs, chosen))
        out += [{"file": h["file"], "start": h["start"], "end": h["end"]} for h in hunks or []]
    return out


def windows(text, marks):
    """`text` as the windows around `marks` [(start, end)], or None when no mark falls within the file's lines."""
    parts = text.split("\n")
    if parts[-1] == "":
        parts.pop()
        rows = [p + "\n" for p in parts]
    else:
        rows = [p + "\n" for p in parts[:-1]] + parts[-1:]
    n = len(rows)
    spans = sorted((max(1, s - CONTEXT), min(n, e + CONTEXT)) for s, e in marks if e >= 1 and s <= n)
    merged = []
    for a, b in spans:
        if merged and a <= merged[-1][1] + 1:
            merged[-1][1] = max(merged[-1][1], b)
        else:
            merged.append([a, b])
    if not merged:
        return None
    return "".join("[lines {}-{} of {}]\n{}".format(a, b, n, "".join(rows[a - 1:b])) for a, b in merged)


def files_input(names, read, marks):
    """([{path, text}], cut): the files of `names` that `read(path)` gives, in order, and those cut from the top for want of an anchor.
    A file of up to FILE_CAP characters is whole, a longer one is its windows around `marks` {path: [(start, end)]}, and TOTAL_CAP
    bounds the lot."""
    out, cut, room = [], [], TOTAL_CAP
    for n in names:
        if room <= 0:
            break
        text = read(n)
        if text is None:
            continue
        shown = windows(text, marks.get(n, [])) if len(text) > FILE_CAP else None
        if shown is not None:
            text = C.cap(shown, room)
        else:
            if len(text) > FILE_CAP:
                cut.append(n)
            text = C.cap(text, min(FILE_CAP, room))
        room -= len(text)
        out.append({"path": n, "text": text})
    return out, cut


def note_cut(state, jid, site, cut):
    """Record that the question `jid` at `site` showed `cut` from the top for want of an anchor. The record is keyed by `jid`, so what it
    counts depends on the id: a validation id is keyed by the input's content, so each round's cut input keeps its own record; a presence id
    (an inventory input rewritten in place) and a revalidation id (a loop question) name one input at a time, so the latest input replaces the
    record, and one with nothing cut removes it."""
    path = os.path.join(state, CUTS, jid + ".json")
    if cut:
        C.jsave(path, {"site": site, "files": list(cut)})
    elif os.path.exists(path):
        os.unlink(path)


def count_cuts(state):
    """{site: inputs} for each site: the records of questions that had a file cut from the top. Validation counts every round's cut input
    (content-digest ids, so a replaced input keeps its record). Presence and revalidation count the latest input per id: the record is
    rewritten in place, and an input later shown in windows removes it. The sites therefore do not count alike."""
    out = dict((s, 0) for s in SITES)
    folder = os.path.join(state, CUTS)
    for name in sorted(os.listdir(folder)) if os.path.isdir(folder) else []:
        if name.endswith(".json"):
            doc = C.jload(os.path.join(folder, name))
            if isinstance(doc, dict) and doc.get("site") in out:
                out[doc["site"]] += 1
    return out
